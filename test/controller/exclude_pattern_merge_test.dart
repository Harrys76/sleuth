import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/ai_chat_adapter.dart';

/// Tests for the exclude-pattern merge logic between
/// [SleuthConfig.networkExcludePatterns] and
/// [AiChatAdapter.networkExcludePatterns].
///
/// The merge function in SleuthController is private, so we replicate it
/// here as a pure function to validate the algorithm. The integration test
/// would require a full SleuthController which is tested elsewhere.
List<String>? mergedExcludePatterns({
  List<String>? userPatterns,
  AiChatAdapter? aiChat,
}) {
  final adapterPatterns = aiChat?.networkExcludePatterns;
  if (userPatterns == null && adapterPatterns == null) return null;
  if (userPatterns == null) return adapterPatterns;
  if (adapterPatterns == null) return userPatterns;
  return {...userPatterns, ...adapterPatterns}.toList();
}

void main() {
  group('exclude pattern merge', () {
    test('both null returns null', () {
      expect(mergedExcludePatterns(), isNull);
    });

    test('user patterns only returns user patterns', () {
      final result = mergedExcludePatterns(
        userPatterns: ['analytics.com', 'tracking.io'],
      );
      expect(result, ['analytics.com', 'tracking.io']);
    });

    test('adapter patterns only returns adapter patterns', () {
      final result = mergedExcludePatterns(
        aiChat: AiChatAdapter.anthropic(apiKey: 'sk-test'),
      );
      expect(result, ['api.anthropic.com']);
    });

    test('both present merges without duplicates', () {
      final result = mergedExcludePatterns(
        userPatterns: ['analytics.com', 'api.anthropic.com'],
        aiChat: AiChatAdapter.anthropic(apiKey: 'sk-test'),
      );
      expect(result, hasLength(2));
      expect(result, containsAll(['analytics.com', 'api.anthropic.com']));
    });

    test('disjoint patterns are all present', () {
      final result = mergedExcludePatterns(
        userPatterns: ['analytics.com'],
        aiChat: AiChatAdapter.google(apiKey: 'AIza-test'),
      );
      expect(result, hasLength(2));
      expect(result, contains('analytics.com'));
      expect(result, contains('generativelanguage.googleapis.com'));
    });

    test('empty user list with adapter patterns returns adapter patterns', () {
      final result = mergedExcludePatterns(
        userPatterns: [],
        aiChat: AiChatAdapter.openAi(apiKey: 'sk-test'),
      );
      expect(result, hasLength(1));
      expect(result, contains('api.openai.com'));
    });

    test('adapter with null patterns returns user patterns only', () {
      final result = mergedExcludePatterns(
        userPatterns: ['my-domain.com'],
        aiChat: AiChatAdapter(
          sendMessage: (_) => Stream.value('token'),
        ),
      );
      expect(result, ['my-domain.com']);
    });
  });
}
