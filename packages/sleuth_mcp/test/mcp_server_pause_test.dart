import 'dart:async';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import 'helpers/fake_vm_bridge.dart';

JsonRpcMessage _req(String method,
        {Map<String, Object?> params = const {}, Object? id = 1}) =>
    JsonRpcMessage(method: method, params: params, id: id);

void main() {
  group('McpServer pause/resume', () {
    test(
      'shutdown calls daemon session detach with bounded timeout',
      () async {
        final bridge = defaultFakeBridge();
        final server = McpServer(bridge: bridge)..registerDefaults();
        final fake = _FakeSession();
        server.setDaemonSession(fake);
        server.shutdown();
        // Give the unawaited detach future a microtask to fire.
        await Future<void>.delayed(Duration.zero);
        expect(fake.detachCalls, 1);
      },
    );

    test('lifecycle tools return sessionMissing when no session bound',
        () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      await server.handleForTest(_req('initialize'));
      final resp = await server.handleForTest(_req(
        'tools/call',
        params: {
          'name': 'app_status',
          'arguments': const <String, Object?>{},
        },
        id: 2,
      ));
      final result = resp!.result as Map<String, Object?>;
      expect(result['isError'], isTrue);
      final text = ((result['content'] as List).first
          as Map<String, Object?>)['text'] as String;
      expect(text, contains('daemon session not initialized'));
    });
  });
}

class _FakeSession implements DaemonSessionLifecycle {
  int detachCalls = 0;
  @override
  Future<void> detach() async {
    detachCalls++;
  }
}
