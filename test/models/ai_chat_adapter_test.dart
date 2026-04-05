import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/models/ai_chat_adapter.dart';

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
      expect(
        adapter.networkExcludePatterns,
        ['generativelanguage.googleapis.com'],
      );
      expect(adapter.sendMessage, isNotNull);
    });
  });
}
