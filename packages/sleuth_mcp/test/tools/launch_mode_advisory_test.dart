import 'dart:convert';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/launch_mode_advisory.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

FakeVmBridge _bridgeWithMode(
  String connectionMode, {
  String packageVersion = '0.36.0',
  bool vmConnected = false,
}) {
  return FakeVmBridge(fakeSessionUuid: 'uuid')
    ..setEnvelope('ext.sleuth.diagnose', {
      'connectionMode': connectionMode,
      'schemaVersion': 1,
      'sessionUuid': 'uuid',
      'data': {'packageVersion': packageVersion, 'vmConnected': vmConnected},
    });
}

void main() {
  group('launchModeAdvisoryFor', () {
    test('basic is gated on vmConnected', () {
      expect(launchModeAdvisoryFor('basic', vmConnected: false),
          launchAdvisoryBasic);
      expect(
          launchModeAdvisoryFor('basic'), launchAdvisoryBasic); // conservative
      // VM connected — detectors live, no relaunch helps.
      expect(launchModeAdvisoryFor('basic', vmConnected: true), isNull);
    });
    test('warmup / disconnected always advise', () {
      expect(launchModeAdvisoryFor('warmup'), launchAdvisoryWarmup);
      expect(launchModeAdvisoryFor('disconnected'), launchAdvisoryDisconnected);
    });
    test('full / correlated / null / unknown → none', () {
      expect(launchModeAdvisoryFor('full', vmConnected: true), isNull);
      expect(launchModeAdvisoryFor('correlated', vmConnected: true), isNull);
      expect(launchModeAdvisoryFor(null), isNull);
      expect(launchModeAdvisoryFor('something-else'), isNull);
    });
  });

  group('launchModeAdvisoryForEnvelope tolerates malformed payloads', () {
    test('non-bool vmConnected / non-String connectionMode → no throw', () {
      expect(
          launchModeAdvisoryForEnvelope({
            'connectionMode': 'basic',
            'data': {'vmConnected': 'yes'}, // non-bool → unknown → conservative
          }),
          launchAdvisoryBasic);
      expect(
          launchModeAdvisoryForEnvelope({
            'connectionMode': 'basic',
            'data': {'vmConnected': true},
          }),
          isNull);
      expect(launchModeAdvisoryForEnvelope({'connectionMode': 42}), isNull);
      // No data block (disposed-controller disconnected envelope).
      expect(launchModeAdvisoryForEnvelope({'connectionMode': 'disconnected'}),
          launchAdvisoryDisconnected);
    });
  });

  group('connect', () {
    test('basic + no VM self-connect stamps the advisory', () async {
      final bridge = _bridgeWithMode('basic', vmConnected: false);
      final handler = builtInTools['connect']!.handler;
      final map = await handler(bridge, {'uri': 'ws://localhost/ws'})
          as Map<String, Object?>;
      expect(map['launchModeAdvisory'], launchAdvisoryBasic);
    });

    test('basic but VM connected omits the advisory', () async {
      final bridge = defaultFakeBridge(); // basic + vmConnected:true
      final handler = builtInTools['connect']!.handler;
      final map = await handler(bridge, {'uri': 'ws://localhost/ws'})
          as Map<String, Object?>;
      expect(map.containsKey('launchModeAdvisory'), isFalse);
    });

    test('version-skew warning and advisory coexist as distinct keys',
        () async {
      final bridge = _bridgeWithMode('basic',
          packageVersion: '0.36.99', vmConnected: false);
      final handler = builtInTools['connect']!.handler;
      final map = await handler(bridge, {'uri': 'ws://localhost/ws'})
          as Map<String, Object?>;
      expect(map['warning'], 'version_skew_minor');
      expect(map['launchModeAdvisory'], launchAdvisoryBasic);
    });
  });

  group('diagnose', () {
    test('basic + no VM self-connect stamps advisory inside data', () async {
      final bridge = _bridgeWithMode('basic', vmConnected: false);
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['diagnose']!.handler;
      final result = await handler(bridge, {}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data['launchModeAdvisory'], launchAdvisoryBasic);
    });

    test('no-data disconnected envelope still surfaces the advisory', () async {
      final bridge = FakeVmBridge(fakeSessionUuid: 'uuid')
        ..setEnvelope('ext.sleuth.diagnose', {
          'connectionMode': 'disconnected',
          'schemaVersion': 1,
          'disposed': true,
        });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['diagnose']!.handler;
      final result = await handler(bridge, {}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data['launchModeAdvisory'], launchAdvisoryDisconnected);
    });
  });

  group('attach_app', () {
    test('debugUrl attach with no VM self-connect stamps advisory on status',
        () async {
      final bridge = defaultFakeBridge()
        ..setEnvelope('ext.sleuth.diagnose', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'fake-uuid',
          'data': {'packageVersion': '0.36.0', 'vmConnected': false},
        });
      final server = McpServer(bridge: bridge)..registerDefaults();
      await server.handleForTest(JsonRpcMessage(
        method: 'initialize',
        id: 0,
        params: const {'protocolVersion': '2024-11-05'},
      ));
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            throw StateError('debugUrl path must bypass spawn'),
      );
      server.setDaemonSession(session);

      final resp = await server.handleForTest(JsonRpcMessage(
        method: 'tools/call',
        id: 1,
        params: {
          'name': 'attach_app',
          'arguments': {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
        },
      ));
      final result = resp!.result as Map<String, Object?>;
      final text = (result['content'] as List)
          .cast<Map<String, Object?>>()
          .first['text'] as String;
      final status = jsonDecode(text) as Map<String, Object?>;
      expect(status['launchModeAdvisory'], launchAdvisoryBasic);
    });
  });
}
