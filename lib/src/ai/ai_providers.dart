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
    final content = (candidates[0] as Map<String, dynamic>)['content']
        as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) return '';
    return ((parts[0] as Map<String, dynamic>)['text'] as String?) ?? '';
  } catch (_) {
    return '';
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
        throw HttpException(
          'AI provider returned ${response.statusCode}: $responseBody',
          uri: uri,
        );
      }

      final parser = SseLineParser();
      await for (final chunk in response.transform(utf8.decoder)) {
        if (controller.isClosed) break;
        for (final line in parser.addChunk(chunk)) {
          if (line.startsWith('data: ')) {
            final data = line.substring(6);
            if (data == '[DONE]') break;
            final token = extractToken(data);
            if (token.isNotEmpty) {
              controller.add(token);
            }
          }
        }
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
          {'text': m.text}
        ],
      };
    }).toList();

    return _streamSse(
      uri: Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:streamGenerateContent?alt=sse',
      ),
      headers: {
        'x-goog-api-key': apiKey,
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'system_instruction': {
          'parts': [
            {'text': request.systemPrompt}
          ],
        },
        'contents': contents,
      }),
      extractToken: extractGoogleToken,
    );
  };
}
