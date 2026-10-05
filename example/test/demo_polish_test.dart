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

    test('forMode names the four modes and nothing else', () {
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
