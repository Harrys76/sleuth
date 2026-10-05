import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

import 'package:example/fake_ai_adapter.dart';

void main() {
  group('demo tiles', () {
    test('every subtitle fits in 40 characters', () {
      final source = File('lib/main.dart').readAsStringSync();
      final subtitles = RegExp(
        r"subtitle: '([^']*)'",
      ).allMatches(source).map((m) => m.group(1)!).toList();
      expect(subtitles, isNotEmpty);
      // One subtitle per demo, so none is missed by the pattern.
      final demos = RegExp(
        r'^\s*_DemoRoute\(',
        multiLine: true,
      ).allMatches(source).length;
      expect(subtitles, hasLength(demos));
      final long = [
        for (final s in subtitles)
          if (s.length > 40) '$s (${s.length})',
      ];
      expect(long, isEmpty);
    });
  });

  group('FakeAiChatAdapter', () {
    const request = AiChatRequest(
      systemPrompt: 'prompt',
      history: [AiChatMessage(role: AiChatRole.user, text: 'Why?')],
    );
    const fast = Duration(milliseconds: 1);

    test('forMode names the six modes and nothing else', () {
      for (final mode in FakeAiMode.values) {
        expect(FakeAiChatAdapter.forMode(mode.name)?.mode, mode);
      }
      expect(FakeAiChatAdapter.forMode(''), isNull);
      expect(FakeAiChatAdapter.forMode('nope'), isNull);
    });

    test('ok streams three sentences and ends', () async {
      final tokens = await FakeAiChatAdapter(
        FakeAiMode.ok,
        tokenInterval: fast,
      ).sendMessage(request).toList();
      expect(tokens, hasLength(3));
      expect(tokens.join(), contains('You asked: "Why?"'));
    });

    test('fail errors with an HTTP 503 and no tokens', () async {
      final tokens = <String>[];
      Object? error;
      await FakeAiChatAdapter(FakeAiMode.fail, tokenInterval: fast)
          .sendMessage(request)
          .handleError((Object e) => error = e)
          .forEach(tokens.add);
      expect(tokens, isEmpty);
      expect(error, isA<HttpException>());
      expect('$error', contains('503'));
    });

    test('partial sends two tokens, then errors', () async {
      final tokens = <String>[];
      Object? error;
      await FakeAiChatAdapter(FakeAiMode.partial, tokenInterval: fast)
          .sendMessage(request)
          .handleError((Object e) => error = e)
          .forEach(tokens.add);
      expect(tokens, hasLength(2));
      expect(error, isNotNull);
    });

    test('slow waits for its first token, then streams', () async {
      final adapter = FakeAiChatAdapter(
        FakeAiMode.slow,
        tokenInterval: fast,
        slowFirstToken: const Duration(milliseconds: 80),
      );
      final tokens = <String>[];
      final done = Completer<void>();
      adapter.sendMessage(request).listen(tokens.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(tokens, isEmpty);
      await done.future;
      expect(tokens, hasLength(3));
    });

    test('empty ends without a token or an error', () async {
      final tokens = await FakeAiChatAdapter(
        FakeAiMode.empty,
        tokenInterval: fast,
      ).sendMessage(request).toList();
      expect(tokens, isEmpty);
    });

    test('stall sends one token and stays open until cancelled', () async {
      final tokens = <String>[];
      var done = false;
      final sub = FakeAiChatAdapter(
        FakeAiMode.stall,
        tokenInterval: fast,
      ).sendMessage(request).listen(tokens.add, onDone: () => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(tokens, hasLength(1));
      expect(done, isFalse);
      await sub.cancel();
    });
  });
}
