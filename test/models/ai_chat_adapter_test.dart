import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart' show AiProviderException;
import 'package:sleuth/src/models/ai_chat_adapter.dart';

void main() {
  group('AiChatMessage', () {
    test('stores role and text', () {
      const msg = AiChatMessage(role: AiChatRole.user, text: 'Hello');
      expect(msg.role, AiChatRole.user);
      expect(msg.text, 'Hello');
    });

    test('assistant role', () {
      const msg = AiChatMessage(role: AiChatRole.assistant, text: 'Hi there');
      expect(msg.role, AiChatRole.assistant);
      expect(msg.text, 'Hi there');
    });

    test('is not stopped unless marked', () {
      const msg = AiChatMessage(role: AiChatRole.assistant, text: 'Hi');
      expect(msg.stopped, isFalse);
      const stopped = AiChatMessage(
        role: AiChatRole.assistant,
        text: 'Ha',
        stopped: true,
      );
      expect(stopped.text, 'Ha');
      expect(stopped.stopped, isTrue);
    });
  });

  group('AiChatRequest', () {
    test('stores systemPrompt and history', () {
      const request = AiChatRequest(
        systemPrompt: 'You are helpful',
        history: [
          AiChatMessage(role: AiChatRole.user, text: 'Q'),
          AiChatMessage(role: AiChatRole.assistant, text: 'A'),
        ],
      );
      expect(request.systemPrompt, 'You are helpful');
      expect(request.history, hasLength(2));
      expect(request.history[0].role, AiChatRole.user);
      expect(request.history[1].role, AiChatRole.assistant);
    });
  });

  group('AiChatAdapter', () {
    test('stores sendMessage callback', () {
      final adapter = AiChatAdapter(
        sendMessage: (request) => Stream.value('token'),
      );
      expect(adapter.sendMessage, isNotNull);
    });

    test('sendMessage returns stream', () async {
      final adapter = AiChatAdapter(
        sendMessage: (request) => Stream.fromIterable(['Hello', ' ', 'world']),
      );

      final request = const AiChatRequest(
        systemPrompt: 'test',
        history: [AiChatMessage(role: AiChatRole.user, text: 'hi')],
      );

      final tokens = await adapter.sendMessage(request).toList();
      expect(tokens, ['Hello', ' ', 'world']);
    });

    test('networkExcludePatterns defaults to null', () {
      final adapter = AiChatAdapter(
        sendMessage: (request) => Stream.value('token'),
      );
      expect(adapter.networkExcludePatterns, isNull);
    });

    test('networkExcludePatterns can be set explicitly', () {
      final adapter = AiChatAdapter(
        sendMessage: (request) => Stream.value('token'),
        networkExcludePatterns: ['example.com'],
      );
      expect(adapter.networkExcludePatterns, ['example.com']);
    });
  });

  group('AiChatAdapter factory constructors', () {
    test('.anthropic() sets networkExcludePatterns', () {
      final adapter = AiChatAdapter.anthropic(apiKey: 'sk-test');
      expect(adapter.networkExcludePatterns, ['api.anthropic.com']);
      expect(adapter.sendMessage, isNotNull);
    });

    test('.openAi() sets networkExcludePatterns from default host', () {
      final adapter = AiChatAdapter.openAi(apiKey: 'sk-test');
      expect(adapter.networkExcludePatterns, ['api.openai.com']);
      expect(adapter.sendMessage, isNotNull);
    });

    test('.openAi() custom baseUrl extracts correct host', () {
      final adapter = AiChatAdapter.openAi(
        apiKey: 'sk-test',
        baseUrl: 'https://my-proxy.example.com',
      );
      expect(adapter.networkExcludePatterns, ['my-proxy.example.com']);
    });

    test('.google() sets networkExcludePatterns', () {
      final adapter = AiChatAdapter.google(apiKey: 'AIza-test');
      expect(adapter.networkExcludePatterns, [
        'generativelanguage.googleapis.com',
      ]);
      expect(adapter.sendMessage, isNotNull);
    });
  });

  group('AiChatAdapter timeouts', () {
    Stream<String> reply(AiChatRequest request) => Stream.value('ok');

    test('default to 30 s for the first text and 15 s between texts', () {
      expect(
        AiChatAdapter.defaultFirstTokenTimeout,
        const Duration(seconds: 30),
      );
      expect(AiChatAdapter.defaultStallTimeout, const Duration(seconds: 15));
      final adapters = [
        AiChatAdapter(sendMessage: reply),
        AiChatAdapter.anthropic(apiKey: 'k'),
        AiChatAdapter.openAi(apiKey: 'k'),
        AiChatAdapter.google(apiKey: 'k'),
      ];
      for (final adapter in adapters) {
        expect(adapter.firstTokenTimeout, const Duration(seconds: 30));
        expect(adapter.stallTimeout, const Duration(seconds: 15));
      }
    });

    test('are set, or turned off with null, on every constructor', () {
      const first = Duration(minutes: 2);
      const stall = Duration(seconds: 45);
      final adapters = [
        AiChatAdapter(
          sendMessage: reply,
          firstTokenTimeout: first,
          stallTimeout: stall,
        ),
        AiChatAdapter.anthropic(
          apiKey: 'k',
          firstTokenTimeout: first,
          stallTimeout: stall,
        ),
        AiChatAdapter.openAi(
          apiKey: 'k',
          firstTokenTimeout: first,
          stallTimeout: stall,
        ),
        AiChatAdapter.google(
          apiKey: 'k',
          firstTokenTimeout: first,
          stallTimeout: stall,
        ),
      ];
      for (final adapter in adapters) {
        expect(adapter.firstTokenTimeout, first);
        expect(adapter.stallTimeout, stall);
      }
      final off = AiChatAdapter.openAi(
        apiKey: 'k',
        firstTokenTimeout: null,
        stallTimeout: null,
      );
      expect(off.firstTokenTimeout, isNull);
      expect(off.stallTimeout, isNull);
    });
  });

  test('AiProviderException is public for custom adapters', () {
    const error = AiProviderException('limit', statusCode: 429);
    expect(error.statusCode, 429);
    expect(error.toString(), 'AiProviderException (429): limit');
  });
}
