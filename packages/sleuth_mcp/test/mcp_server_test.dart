import 'dart:convert';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/prompts/diagnostic_prompts.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
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

  group('structuredContent (MCP 2025-06-18)', () {
    late FakeVmBridge bridge;
    late McpServer server;

    setUp(() {
      bridge = defaultFakeBridge();
      server = McpServer(bridge: bridge)..registerDefaults();
    });

    Future<void> init(String protocol) => server.handleForTest(
          _req('initialize', params: {'protocolVersion': protocol}),
        );

    Future<Map<String, Object?>> call(
      String name,
      Map<String, Object?> args, {
      Object? id = 2,
    }) async {
      final resp = await server.handleForTest(_req(
        'tools/call',
        params: {'name': name, 'arguments': args},
        id: id,
      ));
      return resp!.result as Map<String, Object?>;
    }

    test('2025-06-18 success: structuredContent mirrors the text block',
        () async {
      await init('2025-06-18');
      final result = await call('connect', {'uri': 'ws://localhost/ws'});
      expect(result.containsKey('isError'), isFalse);
      final sc = result['structuredContent'] as Map<String, Object?>;
      final text = (result['content'] as List).first as Map<String, Object?>;
      expect(sc, jsonDecode(text['text'] as String));
      expect(sc['connected'], true);
    });

    test('2024-11-05: older client receives no structuredContent', () async {
      await init('2024-11-05');
      final result = await call('connect', {'uri': 'ws://localhost/ws'});
      expect(result.containsKey('structuredContent'), isFalse);
      final text = (result['content'] as List).first as Map<String, Object?>;
      expect((jsonDecode(text['text'] as String) as Map)['connected'], true);
    });

    test('error result never carries structuredContent (2025-06-18)', () async {
      await init('2025-06-18');
      final result = await call('connect', const <String, Object?>{});
      expect(result['isError'], true);
      expect(result.containsKey('structuredContent'), isFalse);
    });

    test('re-initialize downgrade stops structuredContent emission', () async {
      await init('2025-06-18');
      final upgraded =
          await call('connect', {'uri': 'ws://localhost/ws'}, id: 2);
      expect(upgraded.containsKey('structuredContent'), isTrue);
      // Re-init at an older protocol must revert the gate.
      await init('2024-11-05');
      final downgraded =
          await call('connect', {'uri': 'ws://localhost/ws'}, id: 3);
      expect(downgraded.containsKey('structuredContent'), isFalse);
    });

    test('passthrough success: structuredContent is the whole envelope',
        () async {
      await init('2025-06-18');
      await call('connect', {'uri': 'ws://localhost/ws'});
      final result = await call('get_snapshot', const {}, id: 3);
      final sc = result['structuredContent'] as Map<String, Object?>;
      expect(sc['sessionUuid'], 'fake-uuid');
      expect(sc.containsKey('data'), isTrue,
          reason: 'mirrors the full envelope, not just data');
    });

    test('pipelined re-init downgrade keeps SC on an in-flight call', () async {
      await init('2025-06-18');
      await call('connect', {'uri': 'ws://localhost/ws'});
      // Hold get_snapshot in-flight at the extension call, then re-init older
      // concurrently. The response must honor the protocol at request start.
      final gate = bridge.gateExtension('ext.sleuth.snapshot');
      final inflight = server.handleForTest(_req(
        'tools/call',
        params: {
          'name': 'get_snapshot',
          'arguments': const <String, Object?>{}
        },
        id: 3,
      ));
      await init('2024-11-05');
      gate.complete();
      final result = (await inflight)!.result as Map<String, Object?>;
      expect(result.containsKey('structuredContent'), isTrue,
          reason: 'call started under 2025-06-18 keeps SC despite mid-flight '
              'downgrade');
    });

    test('pipelined re-init upgrade does not add SC to an older-started call',
        () async {
      await init('2024-11-05');
      await call('connect', {'uri': 'ws://localhost/ws'});
      final gate = bridge.gateExtension('ext.sleuth.snapshot');
      final inflight = server.handleForTest(_req(
        'tools/call',
        params: {
          'name': 'get_snapshot',
          'arguments': const <String, Object?>{}
        },
        id: 3,
      ));
      await init('2025-06-18');
      gate.complete();
      final result = (await inflight)!.result as Map<String, Object?>;
      expect(result.containsKey('structuredContent'), isFalse,
          reason: 'call started under 2024-11-05 must not gain SC from a '
              'mid-flight upgrade');
    });
  });

  group('prompts', () {
    late FakeVmBridge bridge;
    late McpServer server;

    setUp(() {
      bridge = defaultFakeBridge();
      server = McpServer(bridge: bridge)..registerDefaults();
    });

    const expectedNames = {
      'triage_performance',
      'audit_memory',
      'release_check',
    };

    test('initialize advertises the prompts capability', () async {
      final resp = await server.handleForTest(_req('initialize'));
      final caps =
          (resp!.result as Map<String, Object?>)['capabilities'] as Map;
      expect(caps.containsKey('prompts'), isTrue);
    });

    test('prompts/list returns the locked set with valid descriptors',
        () async {
      await server.handleForTest(_req('initialize'));
      final resp = await server.handleForTest(_req('prompts/list', id: 2));
      final prompts =
          ((resp!.result as Map<String, Object?>)['prompts'] as List)
              .cast<Map<String, Object?>>();
      expect(prompts.map((p) => p['name']).toSet(), expectedNames);
      for (final p in prompts) {
        expect(p['name'], isA<String>());
        expect(p['description'], isA<String>());
        expect(p['arguments'], isA<List<Object?>>());
      }
    });

    test('prompts/get returns a valid user-text message per prompt', () async {
      await server.handleForTest(_req('initialize'));
      for (final name in expectedNames) {
        final resp = await server
            .handleForTest(_req('prompts/get', params: {'name': name}, id: 2));
        final res = resp!.result as Map<String, Object?>;
        expect(res['description'], isA<String>());
        final messages = (res['messages'] as List).cast<Map<String, Object?>>();
        expect(messages, isNotEmpty);
        for (final m in messages) {
          expect(m['role'], anyOf('user', 'assistant'));
          final content = m['content'] as Map<String, Object?>;
          expect(content['type'], 'text');
          expect(content['text'] as String, isNotEmpty);
        }
      }
    });

    test('prompts/get unknown name returns invalidParams', () async {
      await server.handleForTest(_req('initialize'));
      final resp = await server
          .handleForTest(_req('prompts/get', params: {'name': 'nope'}, id: 2));
      expect(resp!.isError, isTrue);
      expect(resp.error!.code, JsonRpcError.invalidParams);
    });

    test('re-initialize keeps the prompt set (static, not invalidated)',
        () async {
      await server.handleForTest(_req('initialize'));
      await server.handleForTest(_req('initialize', id: 2));
      final resp = await server.handleForTest(_req('prompts/list', id: 3));
      final prompts =
          ((resp!.result as Map<String, Object?>)['prompts'] as List)
              .cast<Map<String, Object?>>();
      expect(prompts.map((p) => p['name']).toSet(), expectedNames);
    });

    test('prompt usesTools matches registered tools + text (drift guard)', () {
      final registered = {
        ...builtInTools.keys,
        ...lifecycleTools(server).keys,
      };
      for (final prompt in builtInPrompts.values) {
        // Every declared tool exists — catches a renamed/removed tool.
        expect(prompt.usesTools.difference(registered), isEmpty,
            reason: '${prompt.descriptor.name} declares unknown tools: '
                '${prompt.usesTools.difference(registered)}');
        // Every declared tool is actually named in the text.
        for (final tool in prompt.usesTools) {
          expect(RegExp('\\b$tool\\b').hasMatch(prompt.text), isTrue,
              reason: '${prompt.descriptor.name} declares $tool but text '
                  'never names it');
        }
        // Reverse: every registered tool named in the text is declared —
        // catches text referencing a tool absent from usesTools (which would
        // escape the rename check above).
        for (final tool in registered) {
          if (RegExp('\\b$tool\\b').hasMatch(prompt.text)) {
            expect(prompt.usesTools.contains(tool), isTrue,
                reason: '${prompt.descriptor.name} text names $tool but '
                    'usesTools omits it');
          }
        }
      }
    });
  });
}
