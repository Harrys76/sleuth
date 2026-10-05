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
  const AiChatMessage({
    required this.role,
    required this.text,
    this.stopped = false,
  });

  /// Who sent this message.
  final AiChatRole role;

  /// The message content.
  final String text;

  /// The user stopped this reply before it finished; [text] is what had
  /// arrived. The chat shows the reply marked "(stopped)".
  ///
  /// In an [AiChatRequest] the text of a stopped reply already ends with
  /// a line of its own saying it was stopped, after any code fence left
  /// open is closed, so an adapter sends [text] as it is.
  final bool stopped;
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
///
/// **Errors** — a failed reply shows a short reason in the chat ("API key
/// rejected", "Rate limited", "Provider error", "Offline", "Can't reach
/// the provider", else "Reply failed"); the full error text, with API
/// keys and tokens masked, is offered through Copy error. A custom
/// backend can throw, or add to its stream, an [AiProviderException]
/// carrying the HTTP `statusCode` so the reason is exact; otherwise the
/// status is read from the error text where it can be ("returned 401",
/// "status code of 429", "statusCode: 503").
///
/// **Timeouts** — a reply fails when no text arrives within
/// [firstTokenTimeout], or when the text stops for longer than
/// [stallTimeout]. A slow model (a local model loading, a reasoning
/// model thinking before it writes) needs longer values, or none. An
/// empty chunk on the stream restarts the current timeout without adding
/// text, so an adapter can keep a slow reply alive by yielding `''`.
class AiChatAdapter {
  const AiChatAdapter({
    required this.sendMessage,
    this.networkExcludePatterns,
    this.firstTokenTimeout = defaultFirstTokenTimeout,
    this.stallTimeout = defaultStallTimeout,
  });

  /// Default [firstTokenTimeout].
  static const Duration defaultFirstTokenTimeout = Duration(seconds: 30);

  /// Default [stallTimeout].
  static const Duration defaultStallTimeout = Duration(seconds: 15);

  /// Creates an adapter for the Anthropic Messages API.
  ///
  /// Streams tokens from Claude models via SSE. The [model] defaults to
  /// `claude-sonnet-4-20250514` but can be any Anthropic model ID.
  ///
  /// Network monitoring is automatically excluded for `api.anthropic.com`.
  /// [firstTokenTimeout] and [stallTimeout] are as on [AiChatAdapter.new].
  factory AiChatAdapter.anthropic({
    required String apiKey,
    String model = 'claude-sonnet-4-20250514',
    int maxTokens = 4096,
    Duration? firstTokenTimeout = defaultFirstTokenTimeout,
    Duration? stallTimeout = defaultStallTimeout,
  }) {
    return AiChatAdapter(
      sendMessage: createAnthropicStream(
        apiKey: apiKey,
        model: model,
        maxTokens: maxTokens,
      ),
      networkExcludePatterns: const ['api.anthropic.com'],
      firstTokenTimeout: firstTokenTimeout,
      stallTimeout: stallTimeout,
    );
  }

  /// Creates an adapter for the OpenAI Chat Completions API.
  ///
  /// Streams tokens from GPT models via SSE. The [baseUrl] parameter
  /// supports OpenAI-compatible APIs (Azure, local proxies, etc.).
  ///
  /// Network monitoring is automatically excluded for the provider host.
  /// [firstTokenTimeout] and [stallTimeout] are as on [AiChatAdapter.new];
  /// a local model that loads on its first request may need a longer
  /// [firstTokenTimeout].
  factory AiChatAdapter.openAi({
    required String apiKey,
    String model = 'gpt-4o',
    int maxTokens = 4096,
    String baseUrl = 'https://api.openai.com',
    Duration? firstTokenTimeout = defaultFirstTokenTimeout,
    Duration? stallTimeout = defaultStallTimeout,
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
      firstTokenTimeout: firstTokenTimeout,
      stallTimeout: stallTimeout,
    );
  }

  /// Creates an adapter for the Google Gemini API.
  ///
  /// Streams tokens from Gemini models via SSE. The API key is sent via
  /// the `x-goog-api-key` header (not a URL query parameter) to prevent
  /// leakage into network monitoring records.
  ///
  /// Network monitoring is automatically excluded for
  /// `generativelanguage.googleapis.com`. [firstTokenTimeout] and
  /// [stallTimeout] are as on [AiChatAdapter.new].
  factory AiChatAdapter.google({
    required String apiKey,
    String model = 'gemini-2.0-flash',
    Duration? firstTokenTimeout = defaultFirstTokenTimeout,
    Duration? stallTimeout = defaultStallTimeout,
  }) {
    return AiChatAdapter(
      sendMessage: createGoogleStream(apiKey: apiKey, model: model),
      networkExcludePatterns: const ['generativelanguage.googleapis.com'],
      firstTokenTimeout: firstTokenTimeout,
      stallTimeout: stallTimeout,
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

  /// Longest wait from sending a message to the first text of the reply;
  /// the reply then fails with "No reply in …" and offers Retry.
  ///
  /// Defaults to [defaultFirstTokenTimeout] (30 s). Null, zero or a
  /// negative duration waits for as long as the stream stays open (Stop
  /// still ends it).
  final Duration? firstTokenTimeout;

  /// Longest gap between two pieces of text once a reply is streaming;
  /// the reply then fails with "Reply stalled", the text so far kept on
  /// screen.
  ///
  /// Defaults to [defaultStallTimeout] (15 s). Null, zero or a negative
  /// duration waits for as long as the stream stays open.
  final Duration? stallTimeout;
}
