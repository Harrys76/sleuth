import 'dart:async';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import 'helpers/fake_vm_bridge.dart';
import 'helpers/mcp_wire.dart';

/// A server over in-memory pipes, initialized at 2025-06-18, whose bridge
/// is connected.
Future<({McpWire wire, McpServer server, FakeVmBridge bridge})>
_connectedWire() async {
  final bridge = defaultFakeBridge();
  await bridge.connect(Uri.parse('ws://localhost/ws'));
  final server = McpServer(bridge: bridge)..registerDefaults();
  final wire = McpWire(server);
  wire.initialize('2025-06-18');
  await wire.response(0);
  return (wire: wire, server: server, bridge: bridge);
}

int _diagnoseCalls(FakeVmBridge bridge) =>
    bridge.callLog.where((c) => c.method == 'ext.sleuth.diagnose').length;

JsonRpcMessage _req(
  String method, {
  Map<String, Object?> params = const {},
  Object? id = 1,
}) => JsonRpcMessage(method: method, params: params, id: id);

void main() {
  group('McpServer pause/resume', () {
    test('shutdown calls daemon session detach with bounded timeout', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final fake = _FakeSession();
      server.setDaemonSession(fake);
      server.shutdown();
      // Give the unawaited detach future a microtask to fire.
      await Future<void>.delayed(Duration.zero);
      expect(fake.detachCalls, 1);
    });

    test(
      'lifecycle tools return sessionMissing when no session bound',
      () async {
        final bridge = defaultFakeBridge();
        final server = McpServer(bridge: bridge)..registerDefaults();
        await server.handleForTest(_req('initialize'));
        final resp = await server.handleForTest(
          _req(
            'tools/call',
            params: {
              'name': 'app_status',
              'arguments': const <String, Object?>{},
            },
            id: 2,
          ),
        );
        final result = resp!.result as Map<String, Object?>;
        expect(result['isError'], isTrue);
        final text =
            ((result['content'] as List).first as Map<String, Object?>)['text']
                as String;
        expect(text, contains('daemon session not initialized'));
      },
    );
  });

  group('a paused dispatch', () {
    test('answers ping and the list methods, and holds tool calls, resource '
        'reads and prompts until it resumes', () async {
      final (:wire, :server, bridge: _) = await _connectedWire();
      server.pauseDispatch();
      wire.ping(1);
      wire.send({'method': 'tools/list', 'id': 2});
      wire.send({'method': 'resources/list', 'id': 3});
      wire.send({'method': 'prompts/list', 'id': 4});
      wire.call(5, 'diagnose');
      wire.send({
        'method': 'resources/read',
        'params': {'uri': 'sleuth://causal-graph'},
        'id': 6,
      });
      wire.send({
        'method': 'prompts/get',
        'params': {'name': 'triage_performance'},
        'id': 7,
      });
      for (final id in [1, 2, 3, 4]) {
        await wire.response(id, within: const Duration(seconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      for (final id in [5, 6, 7]) {
        expect(wire.hasResponse(id), isFalse, reason: 'id $id is held');
      }
      server.resumeDispatch();
      for (final id in [5, 6, 7]) {
        expect((await wire.response(id)).containsKey('error'), isFalse);
      }
      await wire.close();
    });

    test('lets a cancel reach a call that is already running', () async {
      final (:wire, :server, :bridge) = await _connectedWire();
      final gate = bridge.gateExtension('ext.sleuth.diagnose');
      wire.call(1, 'diagnose');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      server.pauseDispatch();
      wire.cancel(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      server.resumeDispatch();
      wire.ping(2);
      await wire.response(2);
      expect(wire.hasResponse(1), isFalse, reason: 'cancelled: no response');
      await wire.close();
    });

    test('drops a held call that the client cancels', () async {
      final (:wire, :server, :bridge) = await _connectedWire();
      final before = _diagnoseCalls(bridge);
      server.pauseDispatch();
      wire.call(1, 'diagnose');
      wire.cancel(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      server.resumeDispatch();
      wire.ping(2);
      await wire.response(2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(wire.hasResponse(1), isFalse);
      expect(_diagnoseCalls(bridge), before, reason: 'the call never ran');
      await wire.close();
    });

    test('holds a repeated initialize behind the calls that arrived before '
        'it', () async {
      final (:wire, :server, bridge: _) = await _connectedWire();
      server.pauseDispatch();
      wire.call(1, 'diagnose');
      wire.initialize('2024-11-05', id: 2);
      wire.ping(3);
      await wire.response(3);
      expect(wire.hasResponse(2), isFalse);
      server.resumeDispatch();
      final call = await wire.response(1);
      expect(
        (call['result'] as Map).containsKey('structuredContent'),
        isTrue,
        reason: 'the call ran under the 2025-06-18 it arrived under',
      );
      final init = await wire.response(2);
      expect((init['result'] as Map)['protocolVersion'], '2024-11-05');
      await wire.close();
    });
  });

  group('shutdown while paused', () {
    test('answers each held request with an error, and a later resume runs '
        'none of them', () async {
      final (:wire, :server, :bridge) = await _connectedWire();
      final before = _diagnoseCalls(bridge);
      server.pauseDispatch();
      wire.call(1, 'diagnose');
      wire.call(null, 'diagnose');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      server.shutdown();
      await wire.served.timeout(const Duration(seconds: 5));
      final answer = await wire.response(1);
      final error = answer['error'] as Map<String, Object?>;
      expect(error['code'], JsonRpcError.internalError);
      expect(error['message'], contains('shutting down'));

      server.resumeDispatch();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_diagnoseCalls(bridge), before, reason: 'no held call ran');
      expect(
        wire.frames.whereType<Map<String, Object?>>().where(
          (f) => f['id'] == 1,
        ),
        hasLength(1),
      );
      expect(wire.frames, hasLength(2), reason: 'initialize and id 1 only');
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
