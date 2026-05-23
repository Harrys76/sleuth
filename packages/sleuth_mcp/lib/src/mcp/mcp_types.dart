/// JSON-RPC 2.0 + MCP message types. Pure data classes; no I/O.
library;

/// Inbound JSON-RPC message after decode. Either a request (has `id`) or a
/// notification (no `id`).
class JsonRpcMessage {
  JsonRpcMessage({
    required this.method,
    required this.params,
    required this.id,
  });

  /// Method name, e.g. `tools/call`.
  final String method;

  /// Params object. Missing / `null` in the wire frame both normalize to `{}`.
  final Map<String, Object?> params;

  /// `String`, `num`, or `null`. Null means this was a notification — no
  /// response is expected.
  final Object? id;

  bool get isNotification => id == null;
}

/// JSON-RPC 2.0 response (`result` OR `error`, never both).
class JsonRpcResponse {
  JsonRpcResponse.result({required this.id, required Object? result})
      : _result = result,
        error = null;

  JsonRpcResponse.error({required this.id, required this.error})
      : _result = null;

  final Object? id;
  final Object? _result;
  final JsonRpcError? error;

  bool get isError => error != null;
  Object? get result => _result;

  Map<String, Object?> toJson() {
    if (isError) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': error!.toJson(),
      };
    }
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': _result,
    };
  }
}

/// JSON-RPC 2.0 error object.
class JsonRpcError {
  const JsonRpcError({
    required this.code,
    required this.message,
    this.data,
  });

  final int code;
  final String message;
  final Object? data;

  Map<String, Object?> toJson() => {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };

  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
  static const int serverNotInitialized = -32002;
}

/// MCP tool descriptor.
class Tool {
  const Tool({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.annotations,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final ToolAnnotations? annotations;

  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
        if (annotations != null) 'annotations': annotations!.toJson(),
      };
}

/// MCP tool `annotations`. `readOnlyHint: true` marks a tool side-effect-free
/// so annotation-aware clients can auto-approve it instead of prompting.
class ToolAnnotations {
  const ToolAnnotations({this.readOnlyHint});

  final bool? readOnlyHint;

  Map<String, Object?> toJson() => {
        if (readOnlyHint != null) 'readOnlyHint': readOnlyHint,
      };
}

/// MCP resource descriptor.
class Resource {
  const Resource({
    required this.uri,
    required this.name,
    required this.description,
    required this.mimeType,
  });

  final String uri;
  final String name;
  final String description;
  final String mimeType;

  Map<String, Object?> toJson() => {
        'uri': uri,
        'name': name,
        'description': description,
        'mimeType': mimeType,
      };
}

/// MCP prompt descriptor (`prompts/list` entry).
class Prompt {
  const Prompt({
    required this.name,
    required this.description,
    this.arguments = const [],
  });

  final String name;
  final String description;
  final List<PromptArgument> arguments;

  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'arguments': arguments.map((a) => a.toJson()).toList(),
      };
}

/// One declared argument of a [Prompt].
class PromptArgument {
  const PromptArgument({
    required this.name,
    required this.description,
    this.required = false,
  });

  final String name;
  final String description;
  final bool required;

  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'required': required,
      };
}

/// MCP `tools/call` response shape.
class ToolCallResult {
  ToolCallResult({
    required this.content,
    this.isError = false,
    this.structuredContent,
  });

  factory ToolCallResult.text(String text, {bool isError = false}) =>
      ToolCallResult(
        content: [
          {'type': 'text', 'text': text},
        ],
        isError: isError,
      );

  final List<Map<String, Object?>> content;
  final bool isError;

  /// MCP 2025-06-18 structured output: mirrors the `content` text block as a
  /// JSON object. Server sets it only on success when the negotiated protocol
  /// supports it; never on errors.
  final Map<String, Object?>? structuredContent;

  Map<String, Object?> toJson() => {
        'content': content,
        if (isError) 'isError': true,
        if (structuredContent != null) 'structuredContent': structuredContent,
      };
}
