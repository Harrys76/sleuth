import 'dart:async';
import 'dart:convert';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import '../helpers/fake_flutter_process.dart';
import '../helpers/fake_vm_bridge.dart';

JsonRpcMessage _toolCall(String name, Map<String, Object?> args, {int id = 1}) {
  return JsonRpcMessage(
    method: 'tools/call',
    params: {'name': name, 'arguments': args},
    id: id,
  );
}

Map<String, Object?> _decodeJsonText(Map<String, Object?> result) {
  final content = (result['content'] as List).first as Map<String, Object?>;
  expect(content['type'], 'text');
  return jsonDecode(content['text'] as String) as Map<String, Object?>;
}

Future<({McpServer server, FakeVmBridge bridge, DaemonSession session})>
    _setup() async {
  final bridge = defaultFakeBridge();
  final server = McpServer(bridge: bridge)..registerDefaults();
  await server
      .handleForTest(JsonRpcMessage(method: 'initialize', id: 0, params: {
    'protocolVersion': '2024-11-05',
  }));
  final session = DaemonSession(
    bridge: bridge,
    server: server,
    processFactory: (_, __,
            {String? workingDirectory,
            Map<String, String>? environment}) async =>
        throw StateError('no process factory bound for this test'),
  );
  server.setDaemonSession(session);
  return (server: server, bridge: bridge, session: session);
}

void main() {
  group('attach_app tool', () {
    test('debugUrl path → returns ready status', () async {
      final ctx = await _setup();
      final resp = await ctx.server.handleForTest(_toolCall(
        'attach_app',
        {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
      ));
      final status = _decodeJsonText(resp!.result as Map<String, Object?>);
      expect(status['state'], 'ready');
      expect(status['attached'], isTrue);
    });

    test(
      'lifecycle tool running longer than the generic tool timeout still '
      'succeeds + does NOT disconnect the bridge',
      () async {
        // Lifecycle tools own their own deadlines; the generic _toolTimeout
        // must not disconnect the bridge mid-operation.
        final inner = defaultFakeBridge();
        final bridge = _SlowConnectBridge(
          inner,
          delay: const Duration(milliseconds: 300),
        );
        final server = McpServer(
          bridge: bridge,
          toolTimeout: const Duration(milliseconds: 100),
        )..registerDefaults();
        await server.handleForTest(JsonRpcMessage(
            method: 'initialize',
            id: 0,
            params: {'protocolVersion': '2024-11-05'}));
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory: (_, __,
                  {String? workingDirectory,
                  Map<String, String>? environment}) async =>
              throw StateError('debugUrl path bypasses spawn'),
        );
        server.setDaemonSession(session);
        final resp = await server.handleForTest(_toolCall(
          'attach_app',
          {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
        ));
        final result = resp!.result as Map<String, Object?>;
        expect(result['isError'], isNot(isTrue));
        expect(bridge.isConnected, isTrue);
      },
    );
  });

  group('hot_reload / hot_restart tools', () {
    test('hot_reload refuses when not attached', () async {
      final ctx = await _setup();
      final resp = await ctx.server.handleForTest(_toolCall(
        'hot_reload',
        const <String, Object?>{},
      ));
      final result = resp!.result as Map<String, Object?>;
      expect(result['isError'], isTrue);
    });

    test('hot_reload happy path via daemon path', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      await server
          .handleForTest(JsonRpcMessage(method: 'initialize', id: 0, params: {
        'protocolVersion': '2024-11-05',
      }));
      final fake = FakeFlutterProcess();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            fake,
        attachTimeout: const Duration(seconds: 2),
        hotReloadTimeout: const Duration(seconds: 2),
      );
      server.setDaemonSession(session);

      final attachFuture = server.handleForTest(_toolCall(
        'attach_app',
        const <String, Object?>{},
      ));
      await Future<void>.delayed(Duration.zero);
      fake.emitEvent('daemon.connected', {'version': '0.6.1', 'pid': 100});
      await Future<void>.delayed(Duration.zero);
      fake.emitEvent('app.start', {
        'appId': 'A',
        'deviceId': 'iphone-12',
        'launchMode': 'attach',
        'mode': 'profile',
      });
      await Future<void>.delayed(Duration.zero);
      fake.emitEvent('app.debugPort', {
        'appId': 'A',
        'port': 4242,
        'wsUri': 'ws://127.0.0.1:4242/tok/ws',
      });
      final attached = await attachFuture;
      final attachedStatus =
          _decodeJsonText(attached!.result as Map<String, Object?>);
      expect(attachedStatus['state'], 'ready');
      final genBefore = bridge.baselineGeneration;

      final reloadFuture = server.handleForTest(_toolCall(
        'hot_reload',
        const <String, Object?>{},
        id: 2,
      ));
      await Future<void>.delayed(Duration.zero);
      final reqFrame = jsonDecode(fake.stdinFrames.last) as List;
      final rpcId = (reqFrame.first as Map)['id'] as int;
      fake.emitRpcResponse(rpcId, result: {'code': 0});

      final resp = await reloadFuture.timeout(const Duration(seconds: 5));
      final status = _decodeJsonText(resp!.result as Map<String, Object?>);
      expect(status['state'], 'ready');
      expect(bridge.baselineGeneration, greaterThan(genBefore));
      await fake.close();
    });
  });
}

/// Forwards every VmBridge call to [inner] but adds [delay] to connect()
/// so a lifecycle handler exceeds the dispatcher's tool timeout.
class _SlowConnectBridge implements VmBridge {
  _SlowConnectBridge(this.inner, {required this.delay});

  final FakeVmBridge inner;
  final Duration delay;

  @override
  String? get baselineSessionUuid => inner.baselineSessionUuid;
  @override
  Map<String, Object?>? get lastDiagnoseEnvelope => inner.lastDiagnoseEnvelope;
  @override
  int get baselineGeneration => inner.baselineGeneration;
  @override
  bool get isConnected => inner.isConnected;

  @override
  Future<bool> connect(Uri wsUri) async {
    await Future<void>.delayed(delay);
    return inner.connect(wsUri);
  }

  @override
  Future<void> refreshBaseline({bool acceptSessionRotation = false}) =>
      inner.refreshBaseline(acceptSessionRotation: acceptSessionRotation);

  @override
  Future<Map<String, Object?>> callExtension(String method,
          {Map<String, dynamic> args = const <String, dynamic>{}}) =>
      inner.callExtension(method, args: args);

  @override
  Future<void> disconnect() => inner.disconnect();
}
