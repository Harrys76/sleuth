import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/ai_chat_adapter.dart';

/// Buffered SSE line parser that handles TCP chunk boundary splits.
///
/// SSE (Server-Sent Events) delivers data as newline-delimited text, but TCP
/// can split chunks at arbitrary byte boundaries. This parser accumulates
/// partial lines across [addChunk] calls and only yields complete lines.
class SseLineParser {
  String _buffer = '';

  /// Feed a raw chunk from the HTTP response. Returns all complete lines
  /// (without trailing newline). Partial lines are buffered internally.
  List<String> addChunk(String chunk) {
    _buffer += chunk;
    final lines = <String>[];
    while (true) {
      final idx = _buffer.indexOf('\n');
      if (idx == -1) break;
      lines.add(_buffer.substring(0, idx).trimRight());
      _buffer = _buffer.substring(idx + 1);
    }
    return lines;
  }

  /// Returns the buffered text after the last newline, the stream's final
  /// line when it ended without one, and empties the buffer. Null when
  /// nothing is buffered.
  String? flush() {
    if (_buffer.isEmpty) return null;
    final line = _buffer.trimRight();
    _buffer = '';
    return line;
  }
}

// ---------------------------------------------------------------------------
// Token extractors — package-private for testability
// ---------------------------------------------------------------------------

/// Extracts the text token from an Anthropic `content_block_delta` SSE event.
///
/// Expected JSON shape:
/// ```json
/// {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}
/// ```
/// Returns empty string for non-delta events or malformed JSON.
String extractAnthropicToken(String jsonData) {
  try {
    final map = jsonDecode(jsonData) as Map<String, dynamic>;
    if (map['type'] != 'content_block_delta') return '';
    final delta = map['delta'] as Map<String, dynamic>?;
    return (delta?['text'] as String?) ?? '';
  } catch (_) {
    return '';
  }
}

/// Extracts the text token from an OpenAI streaming chunk.
///
/// Expected JSON shape:
/// ```json
/// {"choices":[{"delta":{"content":"Hello"}}]}
/// ```
/// Returns empty string for role-only deltas, finish chunks, or malformed JSON.
String extractOpenAiToken(String jsonData) {
  try {
    final map = jsonDecode(jsonData) as Map<String, dynamic>;
    final choices = map['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) return '';
    final delta =
        (choices[0] as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;
    return (delta?['content'] as String?) ?? '';
  } catch (_) {
    return '';
  }
}

/// Extracts the text token from a Google Gemini streaming chunk.
///
/// Expected JSON shape:
/// ```json
/// {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}
/// ```
/// Returns empty string for empty parts or malformed JSON.
String extractGoogleToken(String jsonData) {
  try {
    final map = jsonDecode(jsonData) as Map<String, dynamic>;
    final candidates = map['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) return '';
    final content =
        (candidates[0] as Map<String, dynamic>)['content']
            as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) return '';
    return ((parts[0] as Map<String, dynamic>)['text'] as String?) ?? '';
  } catch (_) {
    return '';
  }
}

// ---------------------------------------------------------------------------
// Stream errors
// ---------------------------------------------------------------------------

/// A failure reported by an AI provider: a non-200 response or an error
/// frame inside the event stream.
///
/// [statusCode] is the HTTP status, or the status an error frame's type
/// stands for (`rate_limit_error` is 429), or null when unknown.
class AiProviderException implements Exception {
  const AiProviderException(this.message, {this.statusCode});

  /// The provider's message (for an HTTP failure, the response body).
  final String message;

  /// HTTP status, when known.
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'AiProviderException: $message'
      : 'AiProviderException ($statusCode): $message';
}

/// HTTP status an error identifier stands for: Anthropic `error.type`
/// values, OpenAI `error.code` and `error.type` values, and the Google
/// RPC `error.status` names Gemini sends. Keys are lower case.
const Map<String, int> _errorStatus = {
  // Anthropic error types.
  'invalid_request_error': 400,
  'authentication_error': 401,
  'permission_error': 403,
  'not_found_error': 404,
  'request_too_large': 413,
  'rate_limit_error': 429,
  'api_error': 500,
  'overloaded_error': 529,
  // OpenAI error codes and types.
  'invalid_api_key': 401,
  'insufficient_quota': 429,
  'rate_limit_exceeded': 429,
  'server_error': 500,
  // Google RPC status names.
  'invalid_argument': 400,
  'unauthenticated': 401,
  'permission_denied': 403,
  'not_found': 404,
  'resource_exhausted': 429,
  'internal': 500,
  'unavailable': 503,
  'deadline_exceeded': 504,
};

/// [value] read as an HTTP status: a number from 100 to 599 (or a string
/// holding one, as Azure sends), or an identifier listed in
/// [_errorStatus]. Null otherwise.
int? _statusOf(Object? value) {
  final number = switch (value) {
    final int n => n,
    final String s => int.tryParse(s.trim()),
    _ => null,
  };
  if (number != null) return number >= 100 && number < 600 ? number : null;
  return value is String ? _errorStatus[value.trim().toLowerCase()] : null;
}

/// Returns the error carried by an SSE data payload, or null when the
/// payload is not an error.
///
/// Anthropic sends `{"type":"error","error":{"type":...,"message":...}}`
/// mid-stream; OpenAI-compatible servers send
/// `{"error":{"message":...,"type":...,"code":...}}`, where `code` is a
/// string such as `rate_limit_exceeded` or a status number; Gemini sends
/// `{"error":{"code":429,"status":"RESOURCE_EXHAUSTED",...}}`. A payload
/// is an error when its `type` is `error`, or its `error` is a non-empty
/// object or string; `"error": false`, `{}` or `""` is not.
///
/// The status is read from `error.code`, then `error.type`, then
/// `error.status` ([_statusOf]).
AiProviderException? extractStreamError(String jsonData) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonData);
  } catch (_) {
    return null;
  }
  return _errorIn(decoded, jsonData);
}

/// [extractStreamError] for a payload already decoded to [decoded];
/// [raw] is the payload text.
AiProviderException? _errorIn(Object? decoded, String raw) {
  if (decoded is! Map<String, dynamic>) return null;
  final error = decoded['error'];
  final carriesError =
      (error is Map && error.isNotEmpty) ||
      (error is String && error.isNotEmpty);
  if (decoded['type'] != 'error' && !carriesError) return null;
  if (error is String && error.isNotEmpty) return AiProviderException(error);
  if (error is! Map<String, dynamic>) return AiProviderException(raw);
  final message = error['message'];
  final status =
      _statusOf(error['code']) ??
      _statusOf(error['type']) ??
      _statusOf(error['status']);
  return AiProviderException(
    message is String ? message : raw,
    statusCode: status,
  );
}

/// One dispatched SSE event: its data, and that data decoded when it is
/// JSON ([isJson]).
typedef _SseEvent = ({String data, bool isJson, Object? json});

({bool isJson, Object? json}) _decodeJson(String data) {
  try {
    return (isJson: true, json: jsonDecode(data));
  } catch (_) {
    return (isJson: false, json: null);
  }
}

/// Groups SSE lines into events.
///
/// The `data` fields of one event are joined with a newline, and the
/// event is dispatched at the blank line that ends it or at [finish].
/// Data that is already a complete JSON value (or `[DONE]`) is dispatched
/// at once: no later data line can extend it into valid JSON, so the
/// result is the same, and a server that leaves out the blank line keeps
/// streaming. Comments and the `event`, `id` and `retry` fields are
/// skipped; any other line is kept as [otherText].
class _SseEventReader {
  /// Most text kept from lines that are not SSE fields.
  static const int _maxOtherChars = 64 * 1024;

  final List<String> _data = [];
  final StringBuffer _other = StringBuffer();
  bool _otherFull = false;

  /// Whether any `data` field arrived.
  bool sawData = false;

  /// Lines that are not SSE fields, joined with newlines (the body of a
  /// response that is not an event stream).
  String get otherText => _other.toString();

  /// Reads one line; returns the event it completes, if any.
  _SseEvent? addLine(String line) {
    if (line.isEmpty) return finish();
    if (line.startsWith(':')) return null;
    final colon = line.indexOf(':');
    final name = colon < 0 ? line : line.substring(0, colon);
    switch (name) {
      case 'data':
        sawData = true;
        var value = colon < 0 ? '' : line.substring(colon + 1);
        if (value.startsWith(' ')) value = value.substring(1);
        _data.add(value);
        final data = _data.join('\n');
        if (data == '[DONE]') {
          _data.clear();
          return (data: data, isJson: false, json: null);
        }
        final decoded = _decodeJson(data);
        if (!decoded.isJson) return null;
        _data.clear();
        return (data: data, isJson: true, json: decoded.json);
      case 'event':
      case 'id':
      case 'retry':
        return null;
      default:
        if (_otherFull) return null;
        if (_other.length + line.length >= _maxOtherChars) {
          _otherFull = true;
          return null;
        }
        if (_other.isNotEmpty) _other.write('\n');
        _other.write(line);
        return null;
    }
  }

  /// Dispatches the event being read, if it has data. Its data did not
  /// decode as JSON when its last line arrived, else it would have been
  /// dispatched then.
  _SseEvent? finish() {
    if (_data.isEmpty) return null;
    final data = _data.join('\n');
    _data.clear();
    if (data.isEmpty) return null;
    return (data: data, isJson: false, json: null);
  }
}

/// The token an [event] carries: null when it ends the stream (`[DONE]`),
/// otherwise [extractToken]'s result. An error payload is thrown.
String? _tokenOf(_SseEvent event, String Function(String data) extractToken) {
  if (event.data == '[DONE]') return null;
  if (event.isJson) {
    final error = _errorIn(event.json, event.data);
    if (error != null) throw error;
  }
  return extractToken(event.data);
}

/// The failure a response with no `data` field stands for: the error its
/// [body] carries (a bare JSON error sent with status 200), else a
/// response that was not an event stream.
AiProviderException _nonStreamFailure(String body) {
  final error = extractStreamError(body);
  if (error != null) return error;
  const maxExcerpt = 300;
  final excerpt = body.length > maxExcerpt
      ? '${body.substring(0, maxExcerpt)}\u2026'
      : body;
  return AiProviderException(
    'The provider did not send an event stream: $excerpt',
  );
}

/// Turns decoded SSE text [chunks] into text tokens.
///
/// Lines are grouped into Server-Sent Events: an event's `data` lines are
/// joined with a newline and read once the event ends (see
/// [_SseEventReader]), including an event the stream ends in without a
/// blank line or a final newline. A byte order mark at the start of the
/// stream is dropped.
///
/// Per event, `[DONE]` ends the stream (the upstream subscription is
/// cancelled, so the connection is not read to its end), data carrying an
/// error ([extractStreamError]) raises it as a stream error, and other
/// data goes to [extractToken]; empty tokens are skipped. A response
/// without any `data` field but with other text, such as a bare JSON
/// error body sent with status 200, raises an [AiProviderException] when
/// it ends instead of ending as an empty reply.
Stream<String> sseTokens(
  Stream<String> chunks,
  String Function(String data) extractToken,
) async* {
  final parser = SseLineParser();
  final reader = _SseEventReader();
  var first = true;
  await for (var chunk in chunks) {
    if (first && chunk.isNotEmpty) {
      first = false;
      // A UTF-8 byte order mark before the first field.
      if (chunk.startsWith('\uFEFF')) chunk = chunk.substring(1);
    }
    for (final line in parser.addChunk(chunk)) {
      final event = reader.addLine(line);
      if (event == null) continue;
      final token = _tokenOf(event, extractToken);
      if (token == null) return;
      if (token.isNotEmpty) yield token;
    }
  }
  // The stream ended: read a last line without a newline, then an event
  // without a closing blank line.
  final tail = parser.flush();
  final pending = [
    if (tail != null) reader.addLine(tail),
    reader.finish(),
  ].nonNulls;
  for (final event in pending) {
    final token = _tokenOf(event, extractToken);
    if (token == null) return;
    if (token.isNotEmpty) yield token;
  }
  if (!reader.sawData && reader.otherText.trim().isNotEmpty) {
    throw _nonStreamFailure(reader.otherText);
  }
}

// ---------------------------------------------------------------------------
// Shared SSE streaming helper
// ---------------------------------------------------------------------------

Stream<String> _streamSse({
  required Uri uri,
  required Map<String, String> headers,
  required String body,
  required String Function(String data) extractToken,
}) {
  late StreamController<String> controller;
  HttpClient? client;
  HttpClientRequest? activeRequest;

  controller = StreamController<String>(
    onCancel: () {
      activeRequest?.abort();
      client?.close(force: true);
    },
  );

  () async {
    client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 90);
    try {
      activeRequest = await client!.postUrl(uri);
      for (final entry in headers.entries) {
        activeRequest!.headers.set(entry.key, entry.value);
      }
      final bodyBytes = utf8.encode(body);
      activeRequest!.headers.set('content-length', '${bodyBytes.length}');
      activeRequest!.add(bodyBytes);
      final response = await activeRequest!.close();

      if (response.statusCode != 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        throw AiProviderException(
          'AI provider returned ${response.statusCode}: $responseBody',
          statusCode: response.statusCode,
        );
      }

      await for (final token in sseTokens(
        response.transform(utf8.decoder),
        extractToken,
      )) {
        if (controller.isClosed) break;
        controller.add(token);
      }
      if (!controller.isClosed) await controller.close();
    } catch (e) {
      if (!controller.isClosed) {
        controller.addError(e);
        await controller.close();
      }
    } finally {
      client?.close();
    }
  }();

  return controller.stream;
}

// ---------------------------------------------------------------------------
// Provider factory functions
// ---------------------------------------------------------------------------

/// Creates a streaming function for the Anthropic Messages API.
///
/// Uses `POST https://api.anthropic.com/v1/messages` with SSE streaming.
Stream<String> Function(AiChatRequest) createAnthropicStream({
  required String apiKey,
  required String model,
  required int maxTokens,
}) {
  return (request) {
    final messages = request.history
        .map((m) => {'role': m.role.name, 'content': m.text})
        .toList();

    return _streamSse(
      uri: Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'system': request.systemPrompt,
        'messages': messages,
        'stream': true,
      }),
      extractToken: extractAnthropicToken,
    );
  };
}

/// Creates a streaming function for the OpenAI Chat Completions API.
///
/// Uses `POST {baseUrl}/v1/chat/completions` with SSE streaming.
/// The [baseUrl] parameter supports OpenAI-compatible APIs (Azure, local).
Stream<String> Function(AiChatRequest) createOpenAiStream({
  required String apiKey,
  required String model,
  required int maxTokens,
  required String baseUrl,
}) {
  return (request) {
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': request.systemPrompt},
      ...request.history.map((m) => {'role': m.role.name, 'content': m.text}),
    ];

    return _streamSse(
      uri: Uri.parse('$baseUrl/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'messages': messages,
        'stream': true,
      }),
      extractToken: extractOpenAiToken,
    );
  };
}

/// Creates a streaming function for the Google Gemini API.
///
/// Uses `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent`
/// with SSE streaming. API key is sent via `x-goog-api-key` header (not URL
/// query parameter) to prevent leakage into network monitoring records.
Stream<String> Function(AiChatRequest) createGoogleStream({
  required String apiKey,
  required String model,
}) {
  return (request) {
    final contents = request.history.map((m) {
      return {
        'role': m.role == AiChatRole.user ? 'user' : 'model',
        'parts': [
          {'text': m.text},
        ],
      };
    }).toList();

    return _streamSse(
      uri: Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:streamGenerateContent?alt=sse',
      ),
      headers: {'x-goog-api-key': apiKey, 'content-type': 'application/json'},
      body: jsonEncode({
        'system_instruction': {
          'parts': [
            {'text': request.systemPrompt},
          ],
        },
        'contents': contents,
      }),
      extractToken: extractGoogleToken,
    );
  };
}
