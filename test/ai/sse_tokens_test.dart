import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/ai/ai_providers.dart';

void main() {
  group('sseTokens', () {
    test('[DONE] ends the stream and stops reading the response', () async {
      var cancelled = false;
      final chunks = StreamController<String>(onCancel: () => cancelled = true);
      final tokens = <String>[];
      final done = Completer<void>();
      sseTokens(
        chunks.stream,
        extractOpenAiToken,
      ).listen(tokens.add, onDone: done.complete);

      chunks.add(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': 'Hi'},
            },
          ],
        })}\n\n',
      );
      chunks.add('data: [DONE]\n\n');
      // The connection stays open; the stream must not wait for it.
      await done.future.timeout(const Duration(seconds: 1));

      expect(tokens, ['Hi']);
      expect(cancelled, isTrue);
    });

    test('an Anthropic error frame becomes a stream error', () async {
      const body =
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":0,'
          '"delta":{"type":"text_delta","text":"Part"}}\n'
          '\n'
          'event: error\n'
          'data: {"type":"error","error":{"type":"overloaded_error",'
          '"message":"Overloaded"}}\n'
          '\n';
      final tokens = <String>[];
      Object? error;
      await sseTokens(
        Stream.value(body),
        extractAnthropicToken,
      ).handleError((Object e) => error = e).forEach(tokens.add);

      expect(tokens, ['Part']);
      expect(error, isA<AiProviderException>());
      final failure = error! as AiProviderException;
      expect(failure.message, 'Overloaded');
      expect(failure.statusCode, 529);
    });

    test('an OpenAI-style error payload becomes a stream error', () async {
      Object? error;
      await sseTokens(
        Stream.value(
          'data: {"error":{"message":"Rate limit reached","code":429}}\n',
        ),
        extractOpenAiToken,
      ).handleError((Object e) => error = e).drain<void>();

      expect(error, isA<AiProviderException>());
      expect((error! as AiProviderException).statusCode, 429);
    });

    test('data lines without a space after the colon are read', () async {
      final tokens = await sseTokens(
        Stream.value(
          'data:{"choices":[{"delta":{"content":"A"}}]}\n'
          'data: {"choices":[{"delta":{"content":"B"}}]}\n',
        ),
        extractOpenAiToken,
      ).toList();
      expect(tokens, ['A', 'B']);
    });

    test('ordinary payloads are not errors', () {
      expect(
        extractStreamError(
          '{"type":"content_block_delta","delta":{"text":"x"}}',
        ),
        isNull,
      );
      expect(extractStreamError('{"choices":[]}'), isNull);
      expect(extractStreamError('not json'), isNull);
      expect(extractStreamError('[1, 2]'), isNull);
    });

    test('an empty or false error field is not an error', () {
      expect(extractStreamError('{"error":false,"choices":[]}'), isNull);
      expect(extractStreamError('{"error":{},"choices":[]}'), isNull);
      expect(extractStreamError('{"error":"","choices":[]}'), isNull);
      expect(extractStreamError('{"error":null}'), isNull);
      expect(extractStreamError('{"error":"Bad key"}')?.message, 'Bad key');
      // A typed error frame raises whatever its error field holds.
      expect(extractStreamError('{"type":"error","error":{}}'), isNotNull);
    });

    test('a payload with "error": false still yields its token', () async {
      final tokens = await sseTokens(
        Stream.value(
          'data: {"error":false,"choices":[{"delta":{"content":"ok"}}]}\n',
        ),
        extractOpenAiToken,
      ).toList();
      expect(tokens, ['ok']);
    });

    test('a byte order mark before the first line is dropped', () async {
      final tokens = await sseTokens(
        Stream.fromIterable([
          '\uFEFFdata: {"choices":[{"delta":{"content":"A"}}]}\n',
          'data: {"choices":[{"delta":{"content":"B"}}]}\n',
        ]),
        extractOpenAiToken,
      ).toList();
      expect(tokens, ['A', 'B']);
    });
  });

  group('sseTokens event framing', () {
    /// Runs [chunks] through [sseTokens]; returns the tokens and the
    /// stream error, if any.
    Future<(List<String>, Object?)> read(
      List<String> chunks,
      String Function(String) extract,
    ) async {
      final tokens = <String>[];
      Object? error;
      await sseTokens(
        Stream.fromIterable(chunks),
        extract,
      ).handleError((Object e) => error = e).forEach(tokens.add);
      return (tokens, error);
    }

    test('data lines of one event are joined before parsing', () async {
      final (tokens, error) = await read([
        'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n',
        'data: {"choices":[{"delta":\n',
        'data: {"content":"lo"}}]}\n',
        '\n',
        'data: [DONE]\n\n',
      ], extractOpenAiToken);
      expect(tokens, ['Hel', 'lo']);
      expect(error, isNull);
    });

    test('a multi-line Anthropic error event becomes a stream error', () async {
      final (tokens, error) = await read([
        'event: content_block_delta\n'
            'data: {"type":"content_block_delta","index":0,'
            '"delta":{"type":"text_delta","text":"Part"}}\n'
            '\n',
        'event: error\n'
            'data: {"type":"error",\n'
            'data:  "error":{"type":"overloaded_error",\n'
            'data:   "message":"Overloaded"}}\n'
            '\n',
      ], extractAnthropicToken);
      expect(tokens, ['Part']);
      expect(error, isA<AiProviderException>());
      final failure = error! as AiProviderException;
      expect(failure.message, 'Overloaded');
      expect(failure.statusCode, 529);
    });

    test('a multi-line OpenAI error event becomes a stream error', () async {
      final (tokens, error) = await read([
        'data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n',
        'data: {"error": {\n'
            'data:   "message": "Rate limit reached for gpt-4o",\n'
            'data:   "type": "tokens",\n'
            'data:   "param": null,\n'
            'data:   "code": "rate_limit_exceeded"\n'
            'data: }}\n'
            '\n',
      ], extractOpenAiToken);
      expect(tokens, ['Hi']);
      expect((error! as AiProviderException).statusCode, 429);
      expect(error.toString(), contains('Rate limit reached'));
    });

    test('comments, other fields, CRLF and chunk splits mix with '
        'multi-line events', () async {
      final (tokens, error) = await read([
        ': keep-alive\r\n\r\n',
        'event: message\r\nid: 1\r\nretry: 1000\r\n',
        'data: {"choices":[{"delta":{"content":"A"}}]}\r\n\r\n',
        'data: {"choices":[{"del',
        'ta":\r\ndata: {"content":"B"}}]}\r',
        '\n\r\n: comment between events\r\n',
        'data:{"choices":[{"delta":{"content":"C"}}]}\r\n\r\n',
        'data: [DONE]\r\n\r\n',
      ], extractOpenAiToken);
      expect(tokens, ['A', 'B', 'C']);
      expect(error, isNull);
    });

    test('an event the stream ends in without a blank line is read', () async {
      final (tokens, error) = await read([
        'data: {"choices":[{"delta":{"content":"A"}}]}\n\n',
        'data: {"choices":[{"delta":\n',
        // No newline and no blank line: the connection closed.
        'data: {"content":"end"}}]}',
      ], extractOpenAiToken);
      expect(tokens, ['A', 'end']);
      expect(error, isNull);
    });

    test(
      'an error event the stream ends in without a blank line is raised',
      () async {
        final (tokens, error) = await read([
          'data: {"type":"content_block_delta",'
              '"delta":{"type":"text_delta","text":"Part"}}\n\n',
          'data: {"type":"error",\n'
              'data: "error":{"type":"api_error","message":"Internal"}}',
        ], extractAnthropicToken);
        expect(tokens, ['Part']);
        expect((error! as AiProviderException).statusCode, 500);
      },
    );

    test('a bare JSON error body sent with status 200 is an error', () async {
      final (tokens, error) = await read([
        '{"error":{"message":"Incorrect API key provided: sk-proj-****",'
            '"type":"invalid_request_error","param":null,'
            '"code":"invalid_api_key"}}',
      ], extractOpenAiToken);
      expect(tokens, isEmpty);
      expect(error, isA<AiProviderException>());
      final failure = error! as AiProviderException;
      expect(failure.statusCode, 401);
      expect(failure.message, startsWith('Incorrect API key provided'));
    });

    test('a pretty-printed JSON error body is an error', () async {
      final (_, error) = await read([
        '{\n  "type": "error",\n  "error": {\n',
        '    "type": "rate_limit_error",\n    "message": "Slow down"\n',
        '  }\n}\n',
      ], extractAnthropicToken);
      expect((error! as AiProviderException).statusCode, 429);
      expect((error as AiProviderException).message, 'Slow down');
    });

    test('a body that is not an event stream is an error', () async {
      final (tokens, error) = await read([
        '<!DOCTYPE html>\n<html><body>Sign in to the network</body></html>\n',
      ], extractOpenAiToken);
      expect(tokens, isEmpty);
      expect(error, isA<AiProviderException>());
      final failure = error! as AiProviderException;
      expect(failure.statusCode, isNull);
      expect(failure.message, contains('not send an event stream'));
      expect(failure.message, contains('Sign in to the network'));
    });

    test('an event stream with no data ends quietly', () async {
      final (tokens, error) = await read([
        ': keep-alive\n\n',
        'event: ping\n\n',
      ], extractOpenAiToken);
      expect(tokens, isEmpty);
      expect(error, isNull);
    });

    test('data with no JSON in it yields nothing', () async {
      final (tokens, error) = await read([
        'data: not json\ndata: either\n\n',
        'data: {"choices":[{"delta":{"content":"A"}}]}\n\n',
      ], extractOpenAiToken);
      expect(tokens, ['A']);
      expect(error, isNull);
    });
  });

  group('extractStreamError status', () {
    int? status(String json) => extractStreamError(json)?.statusCode;

    test('OpenAI error codes and types', () {
      // Rate limit: the code says it, the type names the limit.
      expect(
        status(
          '{"error":{"message":"Rate limit reached for gpt-4o in '
          'organization org-abc on tokens per min (TPM)","type":"tokens",'
          '"param":null,"code":"rate_limit_exceeded"}}',
        ),
        429,
      );
      expect(
        status(
          '{"error":{"message":"You exceeded your current quota",'
          '"type":"insufficient_quota","param":null,'
          '"code":"insufficient_quota"}}',
        ),
        429,
      );
      // The code wins over the request-error type.
      expect(
        status(
          '{"error":{"message":"Incorrect API key provided",'
          '"type":"invalid_request_error","param":null,'
          '"code":"invalid_api_key"}}',
        ),
        401,
      );
      expect(
        status(
          '{"error":{"message":"The server had an error while processing '
          'your request. Sorry about that!","type":"server_error",'
          '"param":null,"code":null}}',
        ),
        500,
      );
      expect(
        status(
          '{"error":{"message":"This model\'s maximum context length is '
          '128000 tokens","type":"invalid_request_error","param":"messages",'
          '"code":"context_length_exceeded"}}',
        ),
        400,
      );
    });

    test('Anthropic error types', () {
      String frame(String type) =>
          '{"type":"error","error":{"type":"$type","message":"m"}}';
      expect(status(frame('authentication_error')), 401);
      expect(status(frame('permission_error')), 403);
      expect(status(frame('rate_limit_error')), 429);
      expect(status(frame('api_error')), 500);
      expect(status(frame('overloaded_error')), 529);
    });

    test('numeric codes, as numbers or strings', () {
      expect(status('{"error":{"message":"m","code":429}}'), 429);
      // Azure OpenAI sends the status as a string.
      expect(
        status(
          '{"error":{"code":"429","message":"Requests to the '
          'ChatCompletions_Create Operation have exceeded call rate limit"}}',
        ),
        429,
      );
      expect(
        status(
          '{"error":{"code":503,"message":"The model is overloaded.",'
          '"status":"UNAVAILABLE"}}',
        ),
        503,
      );
      // A number that is not an HTTP status falls through to the type.
      expect(
        status('{"error":{"message":"m","code":42,"type":"server_error"}}'),
        500,
      );
    });

    test('Gemini status names', () {
      expect(
        status('{"error":{"message":"m","status":"RESOURCE_EXHAUSTED"}}'),
        429,
      );
      expect(
        status('{"error":{"message":"m","status":"UNAUTHENTICATED"}}'),
        401,
      );
      expect(status('{"error":{"message":"m","status":"INTERNAL"}}'), 500);
    });

    test('unknown identifiers carry no status', () {
      expect(
        status('{"error":{"message":"m","type":"odd","code":"weird"}}'),
        isNull,
      );
      expect(status('{"error":{"message":"m","code":true}}'), isNull);
      expect(status('{"error":"Bad key"}'), isNull);
    });
  });
}
