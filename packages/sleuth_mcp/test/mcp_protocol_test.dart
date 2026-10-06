import 'dart:async';
import 'dart:convert';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/mcp/mcp_protocol.dart';
import 'package:test/test.dart';

import 'helpers/counting_session.dart';

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
          .decode(
            _lines(['{"jsonrpc":"2.0","method":"ping","params":{},"id":1}']),
          )
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
          .decode(_lines(['{"jsonrpc":"2.0","method":"ping","id":"abc"}']))
          .toList();
      final msg = events.first as JsonRpcMessage;
      expect(msg.id, 'abc');
    });

    test('parses null id (notification)', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(
            _lines(['{"jsonrpc":"2.0","method":"notifications/initialized"}']),
          )
          .toList();
      final msg = events.first as JsonRpcMessage;
      expect(msg.id, isNull);
      expect(msg.isNotification, isTrue);
    });

    test('normalizes missing params to {}', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(_lines(['{"jsonrpc":"2.0","method":"tools/list","id":1}']))
          .toList();
      final msg = events.first as JsonRpcMessage;
      expect(msg.params, <String, Object?>{});
    });

    test('normalizes params: null to {}', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(
            _lines([
              '{"jsonrpc":"2.0","method":"tools/list","params":null,"id":1}',
            ]),
          )
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

    test('a batch array decodes each element; client responses in it are '
        'dropped', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(
            _lines([
              '[{"jsonrpc":"2.0","method":"ping","id":1},'
                  '{"jsonrpc":"2.0","method":"notifications/initialized"},'
                  '7,'
                  '{"jsonrpc":"2.0","id":3},'
                  '{"jsonrpc":"2.0","result":{},"id":9}]',
            ]),
          )
          .toList();
      final batch = events.single as JsonRpcBatch;
      expect(batch.items, hasLength(4));
      final ping = batch.items[0] as JsonRpcMessage;
      expect(ping.method, 'ping');
      expect(ping.id, 1);
      expect((batch.items[1] as JsonRpcMessage).isNotification, isTrue);
      final notObject = batch.items[2] as DecodeError;
      expect(notObject.code, JsonRpcError.invalidRequest);
      expect(notObject.id, isNull);
      final noMethod = batch.items[3] as DecodeError;
      expect(noMethod.id, 3);
    });

    test('an empty batch is one Invalid Request error with id null', () async {
      final codec = McpProtocolCodec();
      final events = await codec.decode(_lines(['[]'])).toList();
      final error = events.single as DecodeError;
      expect(error.code, JsonRpcError.invalidRequest);
      expect(error.id, isNull);
    });

    test('a JSON-RPC response from the client is dropped', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(
            _lines([
              '{"jsonrpc":"2.0","result":{},"id":7}',
              '{"jsonrpc":"2.0","error":{"code":-1,"message":"x"},"id":8}',
              '{"jsonrpc":"2.0","method":"ping","id":9}',
            ]),
          )
          .toList();
      expect(events, hasLength(1));
      expect((events.single as JsonRpcMessage).id, 9);
    });

    test('a request without a method keeps a readable id', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(
            _lines([
              '{"jsonrpc":"2.0","id":5}',
              '{"jsonrpc":"2.0","id":{"bad":true}}',
            ]),
          )
          .toList();
      expect((events[0] as DecodeError).id, 5);
      expect((events[0] as DecodeError).code, JsonRpcError.invalidRequest);
      expect(
        (events[1] as DecodeError).id,
        isNull,
        reason: 'an object is not a valid JSON-RPC id',
      );
    });

    test('UTF-8 emoji round-trips', () async {
      final codec = McpProtocolCodec();
      final events = await codec
          .decode(
            _lines([
              '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"🎯"},"id":1}',
            ]),
          )
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

  group('McpServer over the wire', () {
    Future<List<Map<String, Object?>>> exchange(List<String> lines) async {
      final out = LineSink();
      final server = McpServer(bridge: FakeVmBridge())..registerDefaults();
      await server.serve(input: _lines(lines), output: out);
      return [for (final l in out.lines) jsonDecode(l) as Map<String, Object?>];
    }

    test('a parse error is answered with id null', () async {
      final responses = await exchange(['{not json']);
      expect(responses, hasLength(1));
      expect(responses.single.containsKey('id'), isTrue);
      expect(responses.single['id'], isNull);
      expect(
        (responses.single['error'] as Map)['code'],
        JsonRpcError.parseError,
      );
    });

    /// Every line the server wrote, decoded: a map for one response, a list
    /// for the responses to a batch.
    Future<List<Object?>> exchangeLines(List<String> lines) async {
      final out = LineSink();
      final server = McpServer(bridge: FakeVmBridge())..registerDefaults();
      await server.serve(input: _lines(lines), output: out);
      return [for (final l in out.lines) jsonDecode(l)];
    }

    String initialize(String version, {Object id = 0}) => jsonEncode({
      'jsonrpc': '2.0',
      'method': 'initialize',
      'params': {'protocolVersion': version},
      'id': id,
    });

    for (final version in ['2024-11-05', '2025-06-18', null]) {
      test(
        'a batch gets one Invalid Request error when the session '
        '${version == null ? 'has not initialized' : 'negotiated $version'}',
        () async {
          final lines = await exchangeLines([
            ?(version == null ? null : initialize(version)),
            '[{"jsonrpc":"2.0","method":"ping","id":1}]',
          ]);
          final error = lines.last as Map<String, Object?>;
          expect(error['id'], isNull);
          expect((error['error'] as Map)['code'], JsonRpcError.invalidRequest);
          expect(
            (error['error'] as Map)['message'],
            contains('only protocol 2025-03-26 has JSON-RPC batches'),
          );
          expect(lines, hasLength(version == null ? 1 : 2));
        },
      );
    }

    test('a 2025-03-26 session gets one array with a response per request '
        'in a batch', () async {
      final lines = await exchangeLines([
        initialize('2025-03-26'),
        '[{"jsonrpc":"2.0","method":"ping","id":1},'
            '{"jsonrpc":"2.0","method":"notifications/initialized"},'
            '{"jsonrpc":"2.0","method":"tools/list","id":2},'
            '7,'
            '{"jsonrpc":"2.0","result":{},"id":9},'
            '{"jsonrpc":"2.0","method":"bogus","id":"x"}]',
      ]);
      expect(lines, hasLength(2));
      final batch = (lines[1] as List).cast<Map<String, Object?>>();
      expect(batch.map((r) => r['id']), [1, 2, null, 'x']);
      expect(batch[0]['result'], <String, Object?>{});
      expect((batch[1]['result'] as Map)['tools'], hasLength(14));
      expect((batch[2]['error'] as Map)['code'], JsonRpcError.invalidRequest);
      expect((batch[3]['error'] as Map)['code'], JsonRpcError.methodNotFound);
    });

    test('a 2025-03-26 batch of notifications gets no response', () async {
      final lines = await exchangeLines([
        initialize('2025-03-26'),
        '[{"jsonrpc":"2.0","method":"notifications/initialized"},'
            '{"jsonrpc":"2.0","method":"notifications/cancelled",'
            '"params":{"requestId":5}}]',
        '{"jsonrpc":"2.0","method":"ping","id":3}',
      ]);
      expect(lines, hasLength(2));
      expect((lines[1] as Map)['id'], 3);
    });

    test('a 2025-03-26 batch runs its tool calls', () async {
      final lines = await exchangeLines([
        initialize('2025-03-26'),
        '[{"jsonrpc":"2.0","method":"tools/call","id":1,"params":'
            '{"name":"diagnose","arguments":{}}},'
            '{"jsonrpc":"2.0","method":"tools/call","id":2,"params":'
            '{"name":"bogus_tool","arguments":{}}}]',
      ]);
      final batch = (lines[1] as List).cast<Map<String, Object?>>();
      expect(batch.map((r) => r['id']), [1, 2]);
      final notConnected =
          (((batch[0]['result'] as Map)['content'] as List).first
                  as Map)['text']
              as String;
      expect(notConnected, startsWith('not_connected: '));
      expect((batch[1]['result'] as Map)['isError'], isTrue);
    });

    test('initialize inside a 2025-03-26 batch is refused', () async {
      final lines = await exchangeLines([
        initialize('2025-03-26'),
        '[${initialize('2025-06-18', id: 4)},'
            '{"jsonrpc":"2.0","method":"ping","id":5}]',
        '[{"jsonrpc":"2.0","method":"ping","id":6}]',
      ]);
      final refused = (lines[1] as List).cast<Map<String, Object?>>();
      expect(refused.map((r) => r['id']), [4, 5]);
      expect((refused[0]['error'] as Map)['code'], JsonRpcError.invalidRequest);
      expect(
        (refused[0]['error'] as Map)['message'],
        contains('must not be part of a batch'),
      );
      // The session still runs 2025-03-26, so the next batch works.
      expect((lines[2] as List).single, containsPair('id', 6));
    });

    test('a client response gets no answer, the next request does', () async {
      final responses = await exchange([
        '{"jsonrpc":"2.0","result":{},"id":7}',
        '{"jsonrpc":"2.0","method":"ping","id":8}',
      ]);
      expect(responses, hasLength(1));
      expect(responses.single['id'], 8);
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
