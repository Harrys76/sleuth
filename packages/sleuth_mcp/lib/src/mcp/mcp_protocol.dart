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
  /// cannot be read, as JSON-RPC 2.0 requires. A JSON array surfaces as a
  /// [JsonRpcBatch] whose items are decoded the same way, and the server
  /// decides from the negotiated protocol version whether to run it. An
  /// empty array is one Invalid Request error, as JSON-RPC 2.0 requires. A
  /// JSON-RPC response from the client (no `method`, with `result` or
  /// `error`) is dropped, alone or inside a batch: the server sends no
  /// requests, and a response must never be answered.
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
        if (decoded.isEmpty) {
          yield _DecodeError(
            id: null,
            code: JsonRpcError.invalidRequest,
            message: 'Invalid Request: the batch is empty',
          );
          continue;
        }
        yield JsonRpcBatch([
          for (final element in decoded) ?_decodeOne(element),
        ]);
        continue;
      }
      final one = _decodeOne(decoded);
      if (one != null) yield one;
    }
  }

  /// Decodes one JSON value into a [JsonRpcMessage] or a [DecodeError].
  /// Returns null for a JSON-RPC response from the client, which is dropped.
  static Object? _decodeOne(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      return _DecodeError(
        id: null,
        code: JsonRpcError.invalidRequest,
        message: 'Request must be a JSON object',
      );
    }
    final method = decoded['method'];
    if (method is! String) {
      if (decoded.containsKey('result') || decoded.containsKey('error')) {
        return null;
      }
      return _DecodeError(
        id: _validId(decoded['id']),
        code: JsonRpcError.invalidRequest,
        message: 'Missing or non-string method',
      );
    }
    final rawParams = decoded['params'];
    final params = rawParams is Map<String, Object?>
        ? rawParams
        : <String, Object?>{};
    return JsonRpcMessage(method: method, params: params, id: decoded['id']);
  }

  /// A JSON-RPC id is a string or a number. Anything else cannot be echoed
  /// back, so the error response uses null.
  static Object? _validId(Object? id) => id is String || id is num ? id : null;

  /// Encode a JSON-RPC response as a single line + LF. Explicit `\n` so
  /// Windows doesn't insert CRLF via `writeln`.
  String encode(JsonRpcResponse response) {
    return '${jsonEncode(response.toJson())}\n';
  }

  /// Encode the responses to one batch as a JSON array on a single line.
  String encodeBatch(List<JsonRpcResponse> responses) {
    return '${jsonEncode([for (final r in responses) r.toJson()])}\n';
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

/// A JSON-RPC batch: one line holding a non-empty JSON array. Each item is
/// a [JsonRpcMessage] or a [DecodeError]. Responses from the client are
/// already dropped, so [items] can be empty.
class JsonRpcBatch {
  JsonRpcBatch(this.items);

  final List<Object> items;
}
