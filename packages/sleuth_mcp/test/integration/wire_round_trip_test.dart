@TestOn('vm')
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:sleuth_mcp/sleuth_mcp.dart';
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
          'data': {'packageVersion': '0.32.0'},
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
}
