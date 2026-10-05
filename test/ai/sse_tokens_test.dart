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
}
