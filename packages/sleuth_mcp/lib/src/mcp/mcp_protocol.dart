import 'dart:async';
import 'dart:convert';

import 'mcp_types.dart';

/// JSON-RPC 2.0 stdio codec. Newline-delimited JSON, UTF-8.
class McpProtocolCodec {
  McpProtocolCodec();

  /// Decode a stream of stdin bytes into JSON-RPC messages.
  ///
  /// A line that is not valid JSON, or not a valid request, surfaces as a
  /// [DecodeError]; the server answers it, with `id: null` when the id
  /// cannot be read, as JSON-RPC 2.0 requires. A batch (a JSON array) gets
  /// one Invalid Request error, because MCP 2025-06-18 removed batching. A
  /// JSON-RPC response from the client (no `method`, with `result` or
  /// `error`) is dropped: the server sends no requests, and a response must
  /// never be answered.
  Stream<Object> decode(Stream<List<int>> stdin) async* {
    // allowMalformed so a stray byte on stdin doesn't kill the stream.
    final lines = stdin
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        yield _DecodeError(
          id: null,
          code: JsonRpcError.parseError,
          message: 'Parse error: the line is not valid JSON',
        );
        continue;
      }
      if (decoded is List) {
        yield _DecodeError(
          id: null,
          code: JsonRpcError.invalidRequest,
          message:
              'Batch requests are not supported (MCP 2025-06-18 removed '
              'JSON-RPC batching); send each request as its own line',
        );
        continue;
      }
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
        if (decoded.containsKey('result') || decoded.containsKey('error')) {
          continue;
        }
        yield _DecodeError(
          id: _validId(decoded['id']),
          code: JsonRpcError.invalidRequest,
          message: 'Missing or non-string method',
        );
        continue;
      }
      final rawParams = decoded['params'];
      final params = rawParams is Map<String, Object?>
          ? rawParams
          : <String, Object?>{};
      yield JsonRpcMessage(method: method, params: params, id: decoded['id']);
    }
  }

  /// A JSON-RPC id is a string or a number. Anything else cannot be echoed
  /// back, so the error response uses null.
  static Object? _validId(Object? id) => id is String || id is num ? id : null;

  /// Encode a JSON-RPC response as a single line + LF. Explicit `\n` so
  /// Windows doesn't insert CRLF via `writeln`.
  String encode(JsonRpcResponse response) {
    return '${jsonEncode(response.toJson())}\n';
  }
}

class _DecodeError {
  _DecodeError({required this.id, required this.code, required this.message});
  final Object? id;
  final int code;
  final String message;
}

/// Surfaced by [McpProtocolCodec.decode] when a frame failed to parse or
/// is not a valid request. The server answers each one with a JSON-RPC
/// error response, using `id: null` when the id could not be read.
typedef DecodeError = _DecodeError;
