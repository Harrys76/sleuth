@TestOn('vm')
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/tools.dart' show builtInTools;
import 'package:test/test.dart';

void main() {
  // Bind every bridge to the current test isolate — siblings in the host
  // VM don't have our registered extensions.
  final currentIsolateId = developer.Service.getIsolateId(Isolate.current);

  test(
    'wire round-trip: real Service.controlWebServer + double-decode',
    () async {
      developer.registerExtension('ext.test.sleuth_echo', (method, args) async {
        return developer.ServiceExtensionResponse.result(jsonEncode({
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'wire-test-uuid',
          'data': {'echoedArgs': args, 'echoMethod': method},
        }));
      });
      developer.registerExtension('ext.sleuth.diagnose', (method, args) async {
        return developer.ServiceExtensionResponse.result(jsonEncode({
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'wire-test-uuid',
          // Literal — interpolating sleuthPackageVersionPin would let a typo
          // in the production const silently pass the fixture check.
          'data': {'packageVersion': '0.33.0'},
        }));
      });

      final info = await developer.Service.controlWebServer(
        enable: true,
        silenceOutput: true,
      );
      final wsUri = info.serverWebSocketUri;
      if (wsUri == null) {
        markTestSkipped('VM service not available');
        return;
      }

      final bridge = RealVmBridge(
        callTimeout: const Duration(seconds: 5),
        targetIsolateIdOverride: currentIsolateId,
      );
      await bridge.connect(wsUri);

      final envelope = await bridge.callExtension(
        'ext.test.sleuth_echo',
        args: const {'hello': 'world'},
      );
      expect(envelope['sessionUuid'], 'wire-test-uuid');
      expect(envelope['schemaVersion'], 1);
      final data = envelope['data'] as Map<String, Object?>;
      expect(data['echoMethod'], 'ext.test.sleuth_echo');
      expect(data['echoedArgs'], isA<Map<String, Object?>>());

      await bridge.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'extension error surfaces as VmBridgeException, not transport-close',
    () async {
      developer.registerExtension('ext.test.always_error',
          (method, args) async {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          'synthetic extension failure',
        );
      });
      final info = await developer.Service.controlWebServer(
        enable: true,
        silenceOutput: true,
      );
      final wsUri = info.serverWebSocketUri;
      if (wsUri == null) {
        markTestSkipped('VM service not available');
        return;
      }
      final bridge = RealVmBridge(
        callTimeout: const Duration(seconds: 5),
        targetIsolateIdOverride: currentIsolateId,
      );
      await bridge.connect(wsUri);
      try {
        await bridge.callExtension('ext.test.always_error');
        fail('expected VmBridgeException');
      } on VmBridgeException catch (e) {
        expect(e.message, contains('rejected'));
      } finally {
        await bridge.disconnect();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'routeHealth shim normalises inline v0.32-shape envelope end-to-end',
    () async {
      // Registers an `ext.sleuth.routeHealth` handler that emits the
      // pre-v0.33 inline RouteSession shape (data == session JSON, no
      // `route` wrapper). The sidecar tool layer must wrap it before
      // surfacing — this end-to-end test crosses the real vm_service
      // round-trip plus the tool handler.
      //
      // `ext.sleuth.diagnose` is registered by the first test in this
      // file — `registerExtension` throws on re-register so we rely on
      // that prior registration here.
      developer.registerExtension('ext.sleuth.routeHealth',
          (method, args) async {
        return developer.ServiceExtensionResponse.result(jsonEncode({
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'wire-test-uuid',
          // Inline v0.32 shape — RouteSession.toJson() directly as data.
          'data': {'routeName': 'home', 'sessionId': 'sess-1'},
        }));
      });

      final info = await developer.Service.controlWebServer(
        enable: true,
        silenceOutput: true,
      );
      final wsUri = info.serverWebSocketUri;
      if (wsUri == null) {
        markTestSkipped('VM service not available');
        return;
      }
      final bridge = RealVmBridge(
        callTimeout: const Duration(seconds: 5),
        targetIsolateIdOverride: currentIsolateId,
      );
      await bridge.connect(wsUri);
      try {
        final handler = builtInTools['get_route_health']!.handler;
        final result =
            await handler(bridge, {'route': 'home'}) as Map<String, Object?>;
        final data = result['data'] as Map<String, Object?>;
        expect(data.containsKey('route'), isTrue,
            reason: 'tool layer must wrap inline shape under `route` so the '
                'sidecar always surfaces the canonical v0.33 contract');
        final routeMap = data['route'] as Map<String, Object?>;
        expect(routeMap['routeName'], 'home');
        expect(routeMap['sessionId'], 'sess-1');
      } finally {
        await bridge.disconnect();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
