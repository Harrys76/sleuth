import 'dart:async';
import 'dart:convert';

import 'mcp_types.dart';

/// JSON-RPC 2.0 stdio codec. Newline-delimited JSON, UTF-8.
class McpProtocolCodec {
  McpProtocolCodec();

  /// Decode a stream of stdin bytes into JSON-RPC messages. Malformed
  /// requests (with `id`) surface as `_DecodeError`; malformed notifications
  /// drop silently.
  Stream<Object> decode(Stream<List<int>> stdin) async* {
    // allowMalformed so a stray byte on stdin doesn't kill the stream.
    final lines = stdin
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map<String, Object?>) {
          yield _DecodeError(
            id: null,
            code: JsonRpcError.invalidRequest,
            message: 'Request must be a JSON object',
          );
          continue;
        }
        final method = decoded['method'];
        if (method is! String) {
          yield _DecodeError(
            id: decoded['id'],
            code: JsonRpcError.invalidRequest,
            message: 'Missing or non-string method',
          );
          continue;
        }
        final rawParams = decoded['params'];
        final params =
            rawParams is Map<String, Object?> ? rawParams : <String, Object?>{};
        yield JsonRpcMessage(
          method: method,
          params: params,
          id: decoded['id'],
        );
      } catch (_) {
        // Malformed JSON. Without a parseable id we can't address the
        // response, so surface a parse error with id=null. Spec says
        // notifications (no id) with parse errors should be silently
        // dropped, but we can't distinguish — let the server decide.
        yield _DecodeError(
          id: null,
          code: JsonRpcError.parseError,
          message: 'Parse error',
        );
      }
    }
  }

  /// Encode a JSON-RPC response as a single line + LF. Explicit `\n` so
  /// Windows doesn't insert CRLF via `writeln`.
  String encode(JsonRpcResponse response) {
    return '${jsonEncode(response.toJson())}\n';
  }
}

class _DecodeError {
  _DecodeError({
    required this.id,
    required this.code,
    required this.message,
  });
  final Object? id;
  final int code;
  final String message;
}

/// Surfaced by [McpProtocolCodec.decode] when a frame failed to parse.
/// The server treats requests (id != null) by emitting a JSON-RPC error
/// response; notifications (id == null) drop silently.
typedef DecodeError = _DecodeError;
