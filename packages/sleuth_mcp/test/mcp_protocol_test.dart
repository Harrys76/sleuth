import 'dart:async';
import 'dart:convert';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/mcp/mcp_protocol.dart';
import 'package:test/test.dart';

Stream<List<int>> _lines(List<String> messages) async* {
  for (final m in messages) {
    yield utf8.encode('$m\n');
  }
}

void main() {
  group('McpProtocolCodec.decode', () {
    test('parses well-formed request with int id', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(_lines([
            '{"jsonrpc":"2.0","method":"ping","params":{},"id":1}',
          ]))
          .toList();
      expect(events, hasLength(1));
      final msg = events.first as JsonRpcMessage;
      expect(msg.method, 'ping');
      expect(msg.id, 1);
      expect(msg.isNotification, isFalse);
    });

    test('parses string id', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(_lines([
            '{"jsonrpc":"2.0","method":"ping","id":"abc"}',
          ]))
          .toList();
      final msg = events.first as JsonRpcMessage;
      expect(msg.id, 'abc');
    });

    test('parses null id (notification)', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(_lines([
            '{"jsonrpc":"2.0","method":"notifications/initialized"}',
          ]))
          .toList();
      final msg = events.first as JsonRpcMessage;
      expect(msg.id, isNull);
      expect(msg.isNotification, isTrue);
    });

    test('normalizes missing params to {}', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(_lines([
            '{"jsonrpc":"2.0","method":"tools/list","id":1}',
          ]))
          .toList();
      final msg = events.first as JsonRpcMessage;
      expect(msg.params, <String, Object?>{});
    });

    test('normalizes params: null to {}', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(_lines([
            '{"jsonrpc":"2.0","method":"tools/list","params":null,"id":1}',
          ]))
          .toList();
      final msg = events.first as JsonRpcMessage;
      expect(msg.params, <String, Object?>{});
    });

    test('malformed JSON surfaces DecodeError', () async {
      final codec = McpProtocolCodec();
      final events = await codec.decode(_lines(['not json'])).toList();
      expect(events, hasLength(1));
      expect(events.first, isA<DecodeError>());
      expect((events.first as DecodeError).code, JsonRpcError.parseError);
    });

    test('UTF-8 emoji round-trips', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(_lines([
            '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"🎯"},"id":1}',
          ]))
          .toList();
      final msg = events.first as JsonRpcMessage;
      expect(msg.params['name'], '🎯');
    });

    test('malformed UTF-8 byte does not abort the stream', () async {
      final codec = McpProtocolCodec();
      Stream<List<int>> source() async* {
        // Invalid lead byte (0xC0 is never legal in UTF-8) followed by a
        // newline, then a valid frame. The decoder should drop the bad
        // byte (allowMalformed) and the valid frame should still parse.
        yield <int>[0xC0, 0x0A];
        yield utf8.encode('{"jsonrpc":"2.0","method":"ping","id":1}\n');
      }

      final events = await codec.decode(source()).toList();
      // Bad frame surfaces as a DecodeError (parse error on the replacement
      // character line) and the good frame parses normally.
      final messages = events.whereType<JsonRpcMessage>().toList();
      expect(messages, hasLength(1));
      expect(messages.first.method, 'ping');
    });
  });

  group('McpProtocolCodec.encode', () {
    test('appends single LF', () {
      final codec = McpProtocolCodec();
      final out = codec.encode(
        JsonRpcResponse.result(id: 1, result: const {'ok': true}),
      );
      expect(out.endsWith('\n'), isTrue);
      expect(out.endsWith('\r\n'), isFalse);
    });
  });
}
