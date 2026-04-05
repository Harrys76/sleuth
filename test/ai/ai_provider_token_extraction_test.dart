import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/ai/ai_providers.dart';

void main() {
  group('extractAnthropicToken', () {
    test('valid content_block_delta returns text', () {
      final json = jsonEncode({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'Hello'},
      });
      expect(extractAnthropicToken(json), 'Hello');
    });

    test('non-delta event type returns empty string', () {
      final json = jsonEncode({
        'type': 'message_start',
        'message': {'id': 'msg_123'},
      });
      expect(extractAnthropicToken(json), '');
    });

    test('malformed JSON returns empty string', () {
      expect(extractAnthropicToken('not json at all'), '');
    });

    test('missing delta field returns empty string', () {
      final json = jsonEncode({
        'type': 'content_block_delta',
        'index': 0,
      });
      expect(extractAnthropicToken(json), '');
    });
  });

  group('extractOpenAiToken', () {
    test('valid delta content returns text', () {
      final json = jsonEncode({
        'id': 'chatcmpl-123',
        'choices': [
          {
            'index': 0,
            'delta': {'content': 'World'},
          }
        ],
      });
      expect(extractOpenAiToken(json), 'World');
    });

    test('role-only delta returns empty string', () {
      final json = jsonEncode({
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant'},
          }
        ],
      });
      expect(extractOpenAiToken(json), '');
    });

    test('empty choices returns empty string', () {
      final json = jsonEncode({'choices': <dynamic>[]});
      expect(extractOpenAiToken(json), '');
    });

    test('malformed JSON returns empty string', () {
      expect(extractOpenAiToken('{invalid'), '');
    });
  });

  group('extractGoogleToken', () {
    test('valid candidates returns text', () {
      final json = jsonEncode({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'Gemini'},
              ],
              'role': 'model',
            },
          }
        ],
      });
      expect(extractGoogleToken(json), 'Gemini');
    });

    test('empty parts returns empty string', () {
      final json = jsonEncode({
        'candidates': [
          {
            'content': {
              'parts': <dynamic>[],
              'role': 'model',
            },
          }
        ],
      });
      expect(extractGoogleToken(json), '');
    });

    test('missing content returns empty string', () {
      final json = jsonEncode({
        'candidates': [
          {'finishReason': 'STOP'},
        ],
      });
      expect(extractGoogleToken(json), '');
    });

    test('malformed JSON returns empty string', () {
      expect(extractGoogleToken('%%%'), '');
    });
  });
}
