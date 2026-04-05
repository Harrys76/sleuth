import '../ai/ai_providers.dart';

/// Role in an AI chat conversation.
enum AiChatRole {
  /// Message from the developer.
  user,

  /// Response from the AI provider.
  assistant,
}

/// A single message in an AI chat conversation.
class AiChatMessage {
  const AiChatMessage({required this.role, required this.text});

  /// Who sent this message.
  final AiChatRole role;

  /// The message content.
  final String text;
}

/// Request sent to the AI provider via [AiChatAdapter.sendMessage].
///
/// The [systemPrompt] is automatically built by the package from rich issue
/// context (metrics, encyclopedia knowledge, causal graph). The [history]
/// contains all prior messages in the conversation.
class AiChatRequest {
  const AiChatRequest({required this.systemPrompt, required this.history});

  /// System prompt with issue context, built by the package.
  final String systemPrompt;

  /// Conversation history (user + assistant messages).
  final List<AiChatMessage> history;
}

/// Provider-agnostic AI chat adapter.
///
/// **Quick setup** — use a built-in factory for zero-config streaming:
/// ```dart
/// AiChatAdapter.anthropic(apiKey: myKey)
/// AiChatAdapter.openAi(apiKey: myKey)
/// AiChatAdapter.google(apiKey: myKey)
/// ```
///
/// **Custom backend** — implement [sendMessage] directly:
/// ```dart
/// AiChatAdapter(
///   sendMessage: (request) async* {
///     final stream = openai.chat.completions.createStream(
///       model: 'gpt-4o',
///       messages: [
///         {'role': 'system', 'content': request.systemPrompt},
///         ...request.history.map((m) =>
///             {'role': m.role.name, 'content': m.text}),
///       ],
///     );
///     await for (final chunk in stream) {
///       yield chunk.choices.first.delta.content ?? '';
///     }
///   },
/// )
/// ```
class AiChatAdapter {
  const AiChatAdapter({
    required this.sendMessage,
    this.networkExcludePatterns,
  });

  /// Creates an adapter for the Anthropic Messages API.
  ///
  /// Streams tokens from Claude models via SSE. The [model] defaults to
  /// `claude-sonnet-4-20250514` but can be any Anthropic model ID.
  ///
  /// Network monitoring is automatically excluded for `api.anthropic.com`.
  factory AiChatAdapter.anthropic({
    required String apiKey,
    String model = 'claude-sonnet-4-20250514',
    int maxTokens = 4096,
  }) {
    return AiChatAdapter(
      sendMessage: createAnthropicStream(
        apiKey: apiKey,
        model: model,
        maxTokens: maxTokens,
      ),
      networkExcludePatterns: const ['api.anthropic.com'],
    );
  }

  /// Creates an adapter for the OpenAI Chat Completions API.
  ///
  /// Streams tokens from GPT models via SSE. The [baseUrl] parameter
  /// supports OpenAI-compatible APIs (Azure, local proxies, etc.).
  ///
  /// Network monitoring is automatically excluded for the provider host.
  factory AiChatAdapter.openAi({
    required String apiKey,
    String model = 'gpt-4o',
    int maxTokens = 4096,
    String baseUrl = 'https://api.openai.com',
  }) {
    final host = Uri.parse(baseUrl).host;
    return AiChatAdapter(
      sendMessage: createOpenAiStream(
        apiKey: apiKey,
        model: model,
        maxTokens: maxTokens,
        baseUrl: baseUrl,
      ),
      networkExcludePatterns: [host],
    );
  }

  /// Creates an adapter for the Google Gemini API.
  ///
  /// Streams tokens from Gemini models via SSE. The API key is sent via
  /// the `x-goog-api-key` header (not a URL query parameter) to prevent
  /// leakage into network monitoring records.
  ///
  /// Network monitoring is automatically excluded for
  /// `generativelanguage.googleapis.com`.
  factory AiChatAdapter.google({
    required String apiKey,
    String model = 'gemini-2.0-flash',
  }) {
    return AiChatAdapter(
      sendMessage: createGoogleStream(
        apiKey: apiKey,
        model: model,
      ),
      networkExcludePatterns: const ['generativelanguage.googleapis.com'],
    );
  }

  /// Sends a chat request and returns a stream of text tokens.
  ///
  /// The stream should yield incremental text chunks for streaming display.
  /// Each chunk is appended to the previous ones to build the full response.
  ///
  /// Cancelling the stream subscription (e.g. when the user navigates away)
  /// should stop the underlying HTTP request if possible.
  final Stream<String> Function(AiChatRequest request) sendMessage;

  /// URL patterns the adapter's provider uses, auto-merged with
  /// [SleuthConfig.networkExcludePatterns] so the network monitor
  /// ignores AI API traffic.
  ///
  /// Built-in factory constructors set this automatically. Custom adapters
  /// can set it manually or rely on the host app adding patterns to
  /// [SleuthConfig.networkExcludePatterns] directly.
  final List<String>? networkExcludePatterns;
}
