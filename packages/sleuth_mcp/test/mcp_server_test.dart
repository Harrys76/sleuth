import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import 'helpers/fake_vm_bridge.dart';

JsonRpcMessage _req(String method,
        {Map<String, Object?> params = const {}, Object? id = 1}) =>
    JsonRpcMessage(method: method, params: params, id: id);

JsonRpcMessage _notif(String method) =>
    JsonRpcMessage(method: method, params: const {}, id: null);

void main() {
  group('McpServer', () {
    late FakeVmBridge bridge;
    late McpServer server;

    setUp(() {
      bridge = defaultFakeBridge();
      server = McpServer(bridge: bridge)..registerDefaults();
    });

    test('initialize returns protocolVersion + serverInfo', () async {
      final resp = await server.handleForTest(
        _req('initialize', params: {'protocolVersion': mcpProtocolVersion}),
      );
      expect(resp, isNotNull);
      final result = resp!.result as Map<String, Object?>;
      expect(result['protocolVersion'], mcpProtocolVersion);
      final info = result['serverInfo'] as Map<String, Object?>;
      expect(info['name'], 'sleuth_mcp');
      expect(info['version'], sleuthMcpVersion);
    });

    test('tools/list returns 14 tools with inputSchema', () async {
      await server.handleForTest(_req('initialize'));
      final resp = await server.handleForTest(_req('tools/list', id: 2));
      final result = resp!.result as Map<String, Object?>;
      final tools = result['tools'] as List;
      // 8 diagnostic + 6 lifecycle (attach/detach/status/list_devices/hot_*).
      expect(tools, hasLength(13));
      for (final t in tools) {
        final tool = t as Map<String, Object?>;
        expect(tool['name'], isA<String>());
        expect(tool['description'], isA<String>());
        final schema = tool['inputSchema'] as Map<String, Object?>;
        expect(schema['type'], 'object');
        expect(schema.containsKey('properties'), isTrue);
        expect(schema.containsKey('required'), isTrue);
      }
    });

    test('non-ping before initialize returns -32002', () async {
      final resp = await server.handleForTest(_req('tools/list'));
      expect(resp!.isError, isTrue);
      expect(resp.error!.code, JsonRpcError.serverNotInitialized);
    });

    test('ping works before initialize', () async {
      final resp = await server.handleForTest(_req('ping'));
      expect(resp!.isError, isFalse);
    });

    test('unknown method returns -32601', () async {
      await server.handleForTest(_req('initialize'));
      final resp = await server.handleForTest(_req('bogus_method', id: 2));
      expect(resp!.isError, isTrue);
      expect(resp.error!.code, JsonRpcError.methodNotFound);
    });

    test('unknown tool returns isError content', () async {
      await server.handleForTest(_req('initialize'));
      final resp = await server.handleForTest(_req(
        'tools/call',
        params: {'name': 'bogus_tool', 'arguments': <String, Object?>{}},
        id: 2,
      ));
      expect(resp!.isError, isFalse);
      final result = resp.result as Map<String, Object?>;
      expect(result['isError'], true);
    });

    test('missing required arg returns isError content', () async {
      await server.handleForTest(_req('initialize'));
      final resp = await server.handleForTest(_req(
        'tools/call',
        params: {
          'name': 'explain_issue',
          'arguments': <String, Object?>{},
        },
        id: 2,
      ));
      final result = resp!.result as Map<String, Object?>;
      expect(result['isError'], true);
    });

    test('notification returns null', () async {
      final resp =
          await server.handleForTest(_notif('notifications/initialized'));
      expect(resp, isNull);
    });

    test('initialize echoes client protocolVersion when supported', () async {
      final resp = await server.handleForTest(
        _req('initialize', params: {'protocolVersion': '2025-06-18'}),
      );
      final result = resp!.result as Map<String, Object?>;
      expect(result['protocolVersion'], '2025-06-18');
    });

    test('initialize falls back to server pin on unsupported version',
        () async {
      final resp = await server.handleForTest(
        _req('initialize', params: {'protocolVersion': '1999-01-01'}),
      );
      final result = resp!.result as Map<String, Object?>;
      expect(result['protocolVersion'], mcpProtocolVersion);
    });

    test('tools/call rejects non-object arguments', () async {
      await server.handleForTest(_req('initialize'));
      final resp = await server.handleForTest(_req(
        'tools/call',
        params: {
          'name': 'connect',
          'arguments': [1, 2, 3]
        },
        id: 2,
      ));
      final result = resp!.result as Map<String, Object?>;
      expect(result['isError'], true);
      final content = (result['content'] as List).first as Map<String, Object?>;
      expect((content['text'] as String).toLowerCase(), contains('object'));
    });

    test('tools/call rejects unknown arg keys (typo guard)', () async {
      await server.handleForTest(_req('initialize'));
      final resp = await server.handleForTest(_req(
        'tools/call',
        params: {
          'name': 'attach_app',
          // typo: `deviceId` should be `device`. Pre-fix the typo was
          // silently accepted and attach proceeded device-less.
          'arguments': {'deviceId': 'iPhone 12'},
        },
        id: 2,
      ));
      final result = resp!.result as Map<String, Object?>;
      expect(result['isError'], true);
      final content = (result['content'] as List).first as Map<String, Object?>;
      expect((content['text'] as String), contains('arg_unknown'));
    });

    test('tools/call rejects enum-violation arg', () async {
      await server.handleForTest(_req('initialize'));
      final resp = await server.handleForTest(_req(
        'tools/call',
        params: {
          'name': 'get_issues',
          'arguments': {'severityAtLeast': 'bogus'},
        },
        id: 2,
      ));
      final result = resp!.result as Map<String, Object?>;
      expect(result['isError'], true);
      final content = (result['content'] as List).first as Map<String, Object?>;
      expect(
        (content['text'] as String),
        contains('arg_enum_violation'),
      );
    });

    test('tools/call rejects minLength violation', () async {
      await server.handleForTest(_req('initialize'));
      final resp = await server.handleForTest(_req(
        'tools/call',
        params: {
          'name': 'explain_issue',
          'arguments': {'stableId': ''},
        },
        id: 2,
      ));
      final result = resp!.result as Map<String, Object?>;
      expect(result['isError'], true);
    });

    test('re-initialize invalidates resource caches', () async {
      // Resources hit the bridge; connect first so the canned envelope
      // path works.
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      await server.handleForTest(_req('initialize'));
      // Prime encyclopedia cache.
      final first = await server.handleForTest(_req(
        'resources/read',
        params: {'uri': 'sleuth://encyclopedia'},
        id: 2,
      ));
      expect(first!.isError, isFalse);
      // Swap the canned envelope, then re-init — the cache should drop and
      // the next read should fetch the new payload.
      bridge.setEnvelope('ext.sleuth.encyclopedia', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'fake-uuid',
        'data': {'count': 99, 'entries': <String, Object?>{}},
      });
      await server.handleForTest(_req('initialize', id: 3));
      final second = await server.handleForTest(_req(
        'resources/read',
        params: {'uri': 'sleuth://encyclopedia'},
        id: 4,
      ));
      final result = second!.result as Map<String, Object?>;
      final contents =
          (result['contents'] as List).first as Map<String, Object?>;
      expect((contents['text'] as String), contains('"count":99'));
    });
  });
}
