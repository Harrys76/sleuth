import 'dart:async';
import 'dart:convert';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/launch_mode_advisory.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

FakeVmBridge _bridgeWithMode(
  String connectionMode, {
  String packageVersion = '0.37.0',
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
      expect(
        launchModeAdvisoryFor('basic', vmConnected: false),
        launchAdvisoryBasic,
      );
      expect(
        launchModeAdvisoryFor('basic'),
        launchAdvisoryBasic,
      ); // conservative
      // VM connected — detectors live, no relaunch helps.
      expect(launchModeAdvisoryFor('basic', vmConnected: true), isNull);
    });
    test('the basic advisory names DDS as one possible cause', () {
      expect(launchAdvisoryBasic, contains('one possible cause is DDS'));
      expect(launchAdvisoryBasic, isNot(contains('DDS is holding')));
      expect(launchAdvisoryBasic, contains('--no-dds'));
      for (final text in [
        launchAdvisoryBasic,
        launchAdvisoryWarmup,
        launchAdvisoryDisconnected,
      ]) {
        // No em dash (U+2014) or en dash (U+2013) in client-facing text.
        expect(text.runes, isNot(contains(0x2014)));
        expect(text.runes, isNot(contains(0x2013)));
      }
      expect(isWarmupAdvisory(launchAdvisoryWarmup), isTrue);
      expect(isWarmupAdvisory(launchAdvisoryBasic), isFalse);
      expect(isWarmupAdvisory(null), isFalse);
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
        launchAdvisoryBasic,
      );
      expect(
        launchModeAdvisoryForEnvelope({
          'connectionMode': 'basic',
          'data': {'vmConnected': true},
        }),
        isNull,
      );
      expect(launchModeAdvisoryForEnvelope({'connectionMode': 42}), isNull);
      // No data block (disposed-controller disconnected envelope).
      expect(
        launchModeAdvisoryForEnvelope({'connectionMode': 'disconnected'}),
        launchAdvisoryDisconnected,
      );
    });
  });

  group('connect', () {
    test('basic + no VM self-connect stamps the advisory', () async {
      final bridge = _bridgeWithMode('basic', vmConnected: false);
      final handler = builtInTools['connect']!.handler;
      final map =
          await handler(bridge, {'uri': 'ws://localhost/ws'})
              as Map<String, Object?>;
      expect(map['launchModeAdvisory'], launchAdvisoryBasic);
      expect(map['vmConnected'], isFalse);
    });

    test('basic but VM connected omits the advisory', () async {
      final bridge = defaultFakeBridge(); // basic + vmConnected:true
      final handler = builtInTools['connect']!.handler;
      final map =
          await handler(bridge, {'uri': 'ws://localhost/ws'})
              as Map<String, Object?>;
      expect(map.containsKey('launchModeAdvisory'), isFalse);
      expect(map['connectionMode'], 'basic');
      expect(map['vmConnected'], isTrue);
    });

    test(
      'version-skew warning and advisory coexist as distinct keys',
      () async {
        final bridge = _bridgeWithMode(
          'basic',
          packageVersion: '0.37.99',
          vmConnected: false,
        );
        final handler = builtInTools['connect']!.handler;
        final map =
            await handler(bridge, {'uri': 'ws://localhost/ws'})
                as Map<String, Object?>;
        expect(map['warning'], 'version_skew_minor');
        expect(map['launchModeAdvisory'], launchAdvisoryBasic);
      },
    );
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
    test(
      'debugUrl attach with no VM self-connect stamps advisory on status',
      () async {
        final bridge = defaultFakeBridge()
          ..setEnvelope('ext.sleuth.diagnose', {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'fake-uuid',
            'data': {'packageVersion': '0.37.0', 'vmConnected': false},
          });
        final server = McpServer(bridge: bridge)..registerDefaults();
        await server.handleForTest(
          JsonRpcMessage(
            method: 'initialize',
            id: 0,
            params: const {'protocolVersion': '2024-11-05'},
          ),
        );
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory:
              (
                _,
                _, {
                String? workingDirectory,
                Map<String, String>? environment,
              }) async => throw StateError('debugUrl path must bypass spawn'),
        );
        server.setDaemonSession(session);

        final resp = await server.handleForTest(
          JsonRpcMessage(
            method: 'tools/call',
            id: 1,
            params: {
              'name': 'attach_app',
              'arguments': {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
            },
          ),
        );
        final result = resp!.result as Map<String, Object?>;
        final text =
            (result['content'] as List)
                    .cast<Map<String, Object?>>()
                    .first['text']
                as String;
        final status = jsonDecode(text) as Map<String, Object?>;
        expect(status['launchModeAdvisory'], launchAdvisoryBasic);
      },
    );
  });

  group('data tools warn on a degraded session', () {
    test(
      'get_snapshot stamps the advisory when basic + no VM self-connect',
      () async {
        final bridge = defaultFakeBridge(); // snapshot envelope is basic, no VM
        await bridge.connect(Uri.parse('ws://localhost/ws'));
        final handler = builtInTools['get_snapshot']!.handler;
        final result = await handler(bridge, {}) as Map<String, Object?>;
        final data = result['data'] as Map<String, Object?>;
        expect(data['launchModeAdvisory'], launchAdvisoryBasic);
      },
    );

    test('get_snapshot omits the advisory when the VM is connected', () async {
      final bridge = defaultFakeBridge()
        ..setEnvelope('ext.sleuth.snapshot', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'fake-uuid',
          'data': {
            'schemaVersion': 5,
            'isVmConnected': true, // verdict warming, detectors live
            'currentIssues': <Map<String, Object?>>[],
          },
        });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_snapshot']!.handler;
      final result = await handler(bridge, {}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data.containsKey('launchModeAdvisory'), isFalse);
    });

    test(
      'get_issues stamps the advisory when basic + no VM self-connect',
      () async {
        final bridge = defaultFakeBridge()
          ..setEnvelope('ext.sleuth.issues', {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'fake-uuid',
            'data': {'issues': fullFakeIssues(), 'vmConnected': false},
          });
        await bridge.connect(Uri.parse('ws://localhost/ws'));
        final handler = builtInTools['get_issues']!.handler;
        final result = await handler(bridge, {}) as Map<String, Object?>;
        final data = result['data'] as Map<String, Object?>;
        expect(data['launchModeAdvisory'], launchAdvisoryBasic);
      },
    );

    test('get_issues omits the advisory when basic and the VM is connected '
        '(no jank frame since connect)', () async {
      final bridge = defaultFakeBridge(); // issues: basic + vmConnected true
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_issues']!.handler;
      final result = await handler(bridge, {}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data.containsKey('launchModeAdvisory'), isFalse);
      expect(data['vmConnected'], isTrue, reason: 'the flag passes through');
    });
  });

  group('get_issues reads the VM link', () {
    test('basic + vmConnected true in the payload: no advisory and no '
        'diagnose read', () async {
      final bridge = await _issuesBridge(issuesVmConnected: true);
      final data = await _getIssuesData(bridge);
      expect(data.containsKey('launchModeAdvisory'), isFalse);
      expect(bridge.calls, ['ext.sleuth.issues']);
    });

    test('basic + vmConnected false in the payload: basic advisory', () async {
      final bridge = await _issuesBridge(
        issuesVmConnected: false,
        diagnoseVmConnected: true,
      );
      final data = await _getIssuesData(bridge);
      expect(data['launchModeAdvisory'], launchAdvisoryBasic);
      expect(bridge.calls, ['ext.sleuth.issues']);
    });

    test('warmup advises whatever the VM link', () async {
      final bridge = await _issuesBridge(
        issuesMode: 'warmup',
        issuesVmConnected: true,
      );
      final data = await _getIssuesData(bridge);
      expect(data['launchModeAdvisory'], launchAdvisoryWarmup);
    });

    test('a 0.37 payload without the flag is unknown: no advisory', () async {
      final bridge = await _issuesBridge(diagnoseVmConnected: false);
      final data = await _getIssuesData(bridge);
      expect(data.containsKey('launchModeAdvisory'), isFalse);
      expect(bridge.calls, ['ext.sleuth.issues']);
    });

    for (final (connected, expected) in <(bool, String?)>[
      (false, launchAdvisoryBasic),
      (true, null),
    ]) {
      test('a 0.36 payload without the flag falls back to diagnose '
          '(vmConnected $connected), read before the issues call', () async {
        final bridge = await _issuesBridge(
          packageVersion: '0.36.4',
          diagnoseVmConnected: connected,
        );
        final data = await _getIssuesData(bridge);
        expect(data['launchModeAdvisory'], expected);
        expect(bridge.calls, ['ext.sleuth.diagnose', 'ext.sleuth.issues']);
        expect(data['issues'], hasLength(2));
      });
    }

    for (final (label, error) in <(String, Object)>[
      (
        'a bridge timeout',
        VmBridgeException('ext.sleuth.diagnose timed out after 0:00:10'),
      ),
      ('a TimeoutException', TimeoutException('diagnose')),
      ('a transport failure', VmBridgeException('not connected')),
    ]) {
      test('$label on the fallback diagnose gives no advisory', () async {
        final bridge =
            await _issuesBridge(
                packageVersion: '0.36.4',
                diagnoseVmConnected: false,
              )
              ..diagnoseError = error;
        final data = await _getIssuesData(bridge);
        expect(data.containsKey('launchModeAdvisory'), isFalse);
        expect(data['issues'], hasLength(2));
      });
    }

    test('a fallback diagnose that never answers gives no advisory', () async {
      final bridge = await _issuesBridge(
        packageVersion: '0.36.4',
        diagnoseVmConnected: false,
      );
      bridge.gateExtension('ext.sleuth.diagnose'); // never completed
      final data = await _getIssuesData(bridge);
      expect(data.containsKey('launchModeAdvisory'), isFalse);
      expect(data['issues'], hasLength(2));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a session change during the fallback propagates', () async {
      final bridge =
          await _issuesBridge(
              packageVersion: '0.36.4',
              diagnoseVmConnected: false,
            )
            ..simulateSessionChange('restarted-uuid');
      await expectLater(
        builtInTools['get_issues']!.handler(bridge, {}),
        throwsA(isA<SessionChangedException>()),
      );
      expect(bridge.calls, ['ext.sleuth.diagnose']);
    });

    test('the client gets session_changed through tools/call', () async {
      final bridge =
          await _issuesBridge(
              packageVersion: '0.36.4',
              diagnoseVmConnected: false,
            )
            ..simulateSessionChange('restarted-uuid');
      final server = McpServer(bridge: bridge)..registerDefaults();
      await server.handleForTest(
        JsonRpcMessage(
          method: 'initialize',
          id: 0,
          params: const {'protocolVersion': '2024-11-05'},
        ),
      );
      final resp = await server.handleForTest(
        JsonRpcMessage(
          method: 'tools/call',
          id: 1,
          params: {'name': 'get_issues', 'arguments': <String, Object?>{}},
        ),
      );
      final result = resp!.result as Map<String, Object?>;
      expect(result['isError'], isTrue);
      final text =
          (result['content'] as List).cast<Map<String, Object?>>().first['text']
              as String;
      expect(text, startsWith('session_changed'));
    });

    test('issues from another session than the fallback diagnose are never '
        'paired with its flag', () async {
      final bridge = await _issuesBridge(
        packageVersion: '0.36.4',
        diagnoseVmConnected: false,
        issuesSessionUuid: 'restarted-uuid',
      );
      await expectLater(
        builtInTools['get_issues']!.handler(bridge, {}),
        throwsA(
          isA<SessionChangedException>()
              .having((e) => e.baseline, 'baseline', 'uuid')
              .having((e) => e.current, 'current', 'restarted-uuid'),
        ),
      );
    });

    test('a version refusal during the fallback propagates', () async {
      final bridge =
          await _issuesBridge(
              packageVersion: '0.36.4',
              diagnoseVmConnected: false,
            )
            ..diagnoseError = VmBridgeException(
              'version_skew_major: app=0.1.0',
            );
      await expectLater(
        builtInTools['get_issues']!.handler(bridge, {}),
        throwsA(
          isA<VmBridgeException>().having(
            (e) => e.message,
            'message',
            startsWith('version_skew_major:'),
          ),
        ),
      );
    });
  });
}

/// [FakeVmBridge] that records every extension call and can fail the next
/// `ext.sleuth.diagnose` read.
class _RecordingBridge extends FakeVmBridge {
  _RecordingBridge({super.fakeSessionUuid});

  final List<String> calls = <String>[];

  /// Thrown by the next `ext.sleuth.diagnose` call when set.
  Object? diagnoseError;

  @override
  Future<Map<String, Object?>> callExtension(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) {
    calls.add(method);
    final error = diagnoseError;
    if (method == 'ext.sleuth.diagnose' && error != null) {
      diagnoseError = null;
      return Future.error(error);
    }
    return super.callExtension(method, args: args);
  }
}

/// A connected bridge for an app at [packageVersion]. Diagnose reports
/// [diagnoseVmConnected]; the issues payload is in [issuesMode], from
/// [issuesSessionUuid], and carries `vmConnected` only when
/// [issuesVmConnected] is not null.
Future<_RecordingBridge> _issuesBridge({
  String packageVersion = '0.37.0',
  String issuesMode = 'basic',
  bool? issuesVmConnected,
  bool diagnoseVmConnected = true,
  String issuesSessionUuid = 'uuid',
}) async {
  final bridge = _RecordingBridge(fakeSessionUuid: 'uuid')
    ..setEnvelope('ext.sleuth.diagnose', {
      'connectionMode': 'basic',
      'schemaVersion': 1,
      'sessionUuid': 'uuid',
      'data': {
        'packageVersion': packageVersion,
        'vmConnected': diagnoseVmConnected,
      },
    })
    ..setEnvelope('ext.sleuth.issues', {
      'connectionMode': issuesMode,
      'schemaVersion': 1,
      'sessionUuid': issuesSessionUuid,
      'data': {'issues': fullFakeIssues(), 'vmConnected': ?issuesVmConnected},
    });
  await bridge.connect(Uri.parse('ws://localhost/ws'));
  bridge.calls.clear();
  return bridge;
}

Future<Map<String, Object?>> _getIssuesData(VmBridge bridge) async {
  final result =
      await builtInTools['get_issues']!.handler(bridge, {})
          as Map<String, Object?>;
  return result['data'] as Map<String, Object?>;
}
