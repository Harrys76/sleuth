@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/bridge/app_log_stream.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_service.dart';

final Uri _uriA = Uri.parse('ws://127.0.0.1:50001/a=/ws');
final Uri _uriB = Uri.parse('ws://127.0.0.1:50002/b=/ws');

Map<String, Object?> _envelope(
  String uuid, {
  String packageVersion = '0.37.0',
  Map<String, Object?> data = const {},
}) => {
  'connectionMode': 'basic',
  'schemaVersion': 1,
  'sessionUuid': uuid,
  'data': {'packageVersion': packageVersion, ...data},
};

/// Registers the sleuth extensions the tests call on [isolateId], as
/// `Sleuth.track()` does when the app starts.
void _registerSleuth(
  FakeVmServiceBackend backend,
  String isolateId,
  String uuid, {
  String packageVersion = '0.37.0',
}) {
  backend
    ..registerExtension(
      isolateId,
      'ext.sleuth.diagnose',
      (_) => _envelope(uuid, packageVersion: packageVersion),
    )
    ..registerExtension(
      isolateId,
      'ext.sleuth.issues',
      (_) => _envelope(uuid, data: {'issues': <Object?>[]}),
    );
}

/// A backend with one main isolate running sleuth session [uuid].
FakeVmServiceBackend _app(String isolateId, String uuid) {
  final backend = FakeVmServiceBackend()..addIsolate(isolateId);
  _registerSleuth(backend, isolateId, uuid);
  return backend;
}

String? _versionCheck(Map<String, Object?> envelope) {
  final data = envelope['data'] as Map<String, Object?>?;
  return data?['packageVersion'] == '0.37.0'
      ? null
      : 'version_skew_major: synthetic';
}

RealVmBridge _bridge(
  FakeVmServiceBackend backend, {
  Duration callTimeout = const Duration(seconds: 2),
  Duration? isolateFollowTimeout,
  VersionSkewValidator? versionSkewValidator,
}) => RealVmBridge(
  callTimeout: callTimeout,
  isolateFollowTimeout: isolateFollowTimeout,
  versionSkewValidator: versionSkewValidator,
  serviceConnector: backend.connect,
);

/// Simulates a hot restart: the old isolate exits and a new one starts.
/// The new isolate registers sleuth after [registerAfter], or never when
/// it is null.
void _hotRestart(
  FakeVmServiceBackend backend, {
  required String from,
  required String to,
  required String uuid,
  Duration? registerAfter = const Duration(milliseconds: 200),
  String packageVersion = '0.37.0',
}) {
  backend
    ..removeIsolate(from)
    ..addIsolate(to);
  if (registerAfter != null) {
    Timer(
      registerAfter,
      () => _registerSleuth(backend, to, uuid, packageVersion: packageVersion),
    );
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 3)) {
      fail('condition not met within 3 s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Map<String, Object?> _stdout(String text) => {
  'type': 'Event',
  'kind': 'WriteEvent',
  'timestamp': 1700000000000,
  'bytes': base64.encode(utf8.encode(text)),
};

void main() {
  group('hot restart that replaces the isolate', () {
    test('is reported once as session_changed, then the bridge follows the '
        'new isolate', () async {
      final backend = _app('isolates/1', 'session-A');
      final bridge = _bridge(backend);
      await bridge.connect(_uriA);
      final before = await bridge.callExtension('ext.sleuth.issues');
      expect(before['sessionUuid'], 'session-A');

      _hotRestart(
        backend,
        from: 'isolates/1',
        to: 'isolates/2',
        uuid: 'session-B',
      );
      await expectLater(
        bridge.callExtension('ext.sleuth.issues'),
        throwsA(
          isA<SessionChangedException>()
              .having((e) => e.baseline, 'baseline', 'session-A')
              .having((e) => e.current, 'current', 'session-B')
              .having((e) => e.followed, 'followed', isTrue),
        ),
      );
      expect(bridge.isConnected, isTrue);
      expect(bridge.baselineSessionUuid, 'session-B');
      expect(bridge.lastDiagnoseEnvelope?['sessionUuid'], 'session-B');
      // The bridge waited for the extension instead of calling diagnose on
      // the new isolate before Sleuth.track() registered it.
      expect(
        backend.requests.where((r) => r == 'ext.sleuth.diagnose isolates/2'),
        hasLength(1),
      );

      final after = await bridge.callExtension('ext.sleuth.issues');
      expect(after['sessionUuid'], 'session-B');
      await bridge.disconnect();
    });

    test('concurrent calls report the change once; the others read the new '
        'isolate', () async {
      final backend = _app('isolates/1', 'session-A');
      final bridge = _bridge(backend);
      await bridge.connect(_uriA);
      _hotRestart(
        backend,
        from: 'isolates/1',
        to: 'isolates/2',
        uuid: 'session-B',
        registerAfter: const Duration(milliseconds: 100),
      );
      final outcomes = await Future.wait([
        for (var i = 0; i < 3; i++)
          bridge
              .callExtension('ext.sleuth.issues')
              .then<String>(
                (envelope) => 'read ${envelope['sessionUuid']}',
                onError: (Object e) =>
                    e is SessionChangedException ? 'changed' : 'failed $e',
              ),
      ]);
      expect(outcomes.where((o) => o == 'changed'), hasLength(1));
      expect(outcomes.where((o) => o == 'read session-B'), hasLength(2));
      await bridge.disconnect();
    });

    test('a new isolate that never registers sleuth fails with a next step, '
        'not as an uninitialized app', () async {
      final backend = _app('isolates/1', 'session-A');
      final bridge = _bridge(
        backend,
        isolateFollowTimeout: const Duration(milliseconds: 300),
      );
      await bridge.connect(_uriA);
      _hotRestart(
        backend,
        from: 'isolates/1',
        to: 'isolates/2',
        uuid: 'session-B',
        registerAfter: null,
      );
      await expectLater(
        bridge.callExtension('ext.sleuth.issues'),
        throwsA(
          isA<VmBridgeException>()
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('no new isolate registered ext.sleuth.diagnose'),
                  contains('call the tool again'),
                  contains('connect or attach_app'),
                ),
              )
              .having(
                (e) => e.message,
                'message',
                isNot(contains('not initialized')),
              ),
        ),
      );
      expect(
        backend.requests,
        isNot(contains('ext.sleuth.diagnose isolates/2')),
        reason: 'diagnose waits for the extension to register',
      );

      // Once the app registers sleuth, the next call follows it.
      _registerSleuth(backend, 'isolates/2', 'session-B');
      await expectLater(
        bridge.callExtension('ext.sleuth.issues'),
        throwsA(
          isA<SessionChangedException>().having(
            (e) => e.followed,
            'followed',
            isTrue,
          ),
        ),
      );
      expect(
        (await bridge.callExtension('ext.sleuth.issues'))['sessionUuid'],
        'session-B',
      );
      await bridge.disconnect();
    });

    test(
      'a restart into a refused version disconnects with the refusal',
      () async {
        final backend = _app('isolates/1', 'session-A');
        final bridge = _bridge(
          backend,
          versionSkewValidator: (envelope) async {
            return _versionCheck(envelope);
          },
        );
        await bridge.connect(_uriA);
        _hotRestart(
          backend,
          from: 'isolates/1',
          to: 'isolates/2',
          uuid: 'session-B',
          packageVersion: '0.99.0',
          registerAfter: Duration.zero,
        );
        await expectLater(
          bridge.callExtension('ext.sleuth.issues'),
          throwsA(
            isA<VmBridgeException>()
                .having((e) => e.kind, 'kind', VmBridgeErrorKind.refused)
                .having(
                  (e) => e.message,
                  'message',
                  startsWith('version_skew_'),
                ),
          ),
        );
        expect(bridge.isConnected, isFalse);
      },
    );

    test(
      'a disconnect stops a follow that waits for the new isolate',
      () async {
        final backend = _app('isolates/1', 'session-A');
        final bridge = _bridge(
          backend,
          isolateFollowTimeout: const Duration(seconds: 20),
        );
        await bridge.connect(_uriA);
        _hotRestart(
          backend,
          from: 'isolates/1',
          to: 'isolates/2',
          uuid: 'session-B',
          registerAfter: null,
        );
        final call = bridge.callExtension('ext.sleuth.issues');
        await _waitFor(
          () => backend.requests.contains('getIsolate isolates/2'),
        );
        final failed = expectLater(
          call,
          throwsA(
            isA<VmBridgeException>().having(
              (e) => e.kind,
              'kind',
              VmBridgeErrorKind.notConnected,
            ),
          ),
        );
        final watch = Stopwatch()..start();
        await bridge.disconnect().timeout(const Duration(seconds: 2));
        await failed;
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(bridge.isConnected, isFalse);
      },
    );
  });

  group('session follow outcome', () {
    test('a follow that cannot read the new session reports followed: false '
        'and keeps the old baseline; the next call follows', () async {
      var diagnoseUuid = 'session-A';
      var echoUuid = 'session-A';
      final backend = FakeVmServiceBackend()..addIsolate('isolates/1');
      backend
        ..registerExtension(
          'isolates/1',
          'ext.sleuth.diagnose',
          (_) => _envelope(diagnoseUuid),
        )
        ..registerExtension(
          'isolates/1',
          'ext.test.echo',
          (_) => _envelope(echoUuid),
        );
      final bridge = _bridge(backend);
      await bridge.connect(_uriA);

      // The app answers from a new session, but its diagnose fails.
      echoUuid = 'session-B';
      backend.failNext(
        'ext.sleuth.diagnose',
        code: -32000,
        message: 'diagnose failed',
      );
      await expectLater(
        bridge.callExtension('ext.test.echo'),
        throwsA(
          isA<SessionChangedException>()
              .having((e) => e.current, 'current', 'session-B')
              .having((e) => e.followed, 'followed', isFalse),
        ),
      );
      expect(bridge.isConnected, isTrue);
      expect(bridge.baselineSessionUuid, 'session-A');

      // A malformed diagnose envelope does not move the baseline either.
      backend.registerExtension(
        'isolates/1',
        'ext.sleuth.diagnose',
        (_) => {'schemaVersion': 1},
      );
      await expectLater(
        bridge.callExtension('ext.test.echo'),
        throwsA(
          isA<SessionChangedException>().having(
            (e) => e.followed,
            'followed',
            isFalse,
          ),
        ),
      );
      expect(bridge.baselineSessionUuid, 'session-A');

      diagnoseUuid = 'session-B';
      backend.registerExtension(
        'isolates/1',
        'ext.sleuth.diagnose',
        (_) => _envelope(diagnoseUuid),
      );
      await expectLater(
        bridge.callExtension('ext.test.echo'),
        throwsA(
          isA<SessionChangedException>()
              .having((e) => e.baseline, 'baseline', 'session-A')
              .having((e) => e.followed, 'followed', isTrue),
        ),
      );
      expect(bridge.baselineSessionUuid, 'session-B');
      expect(
        (await bridge.callExtension('ext.test.echo'))['sessionUuid'],
        'session-B',
      );
      await bridge.disconnect();
    });

    test('a reconnect that finds a new session reports followed: false and '
        'disconnects', () async {
      var uuid = 'session-A';
      final backend = FakeVmServiceBackend()..addIsolate('isolates/1');
      backend.registerExtension(
        'isolates/1',
        'ext.sleuth.diagnose',
        (_) => _envelope(uuid),
      );
      final bridge = _bridge(backend);
      await bridge.connect(_uriA);
      uuid = 'session-B';
      await expectLater(
        bridge.debugSimulateReconnect(),
        throwsA(
          isA<SessionChangedException>().having(
            (e) => e.followed,
            'followed',
            isFalse,
          ),
        ),
      );
      expect(bridge.isConnected, isFalse);
    });
  });

  group('reconnect after a transport close', () {
    test('a reconnect queued behind an explicit disconnect gives up', () async {
      final backend = _app('isolates/1', 'session-A');
      backend.registerExtension(
        'isolates/1',
        'ext.test.slow',
        (_) => _envelope('session-A'),
      );
      final bridge = _bridge(backend);
      await bridge.connect(_uriA);
      expect(backend.connectCount, 1);

      // A slow call is in flight; it will fail as a closed transport.
      final slowAnswer = backend.hold('ext.test.slow');
      backend.failNext(
        'ext.test.slow',
        code: -32000,
        message: 'Service connection disposed',
      );
      final slow = expectLater(
        bridge.callExtension('ext.test.slow'),
        throwsA(
          isA<VmBridgeException>().having(
            (e) => e.kind,
            'kind',
            VmBridgeErrorKind.notConnected,
          ),
        ),
      );
      await pumpEventQueue();

      // A refresh holds the connect lock, and detach_app queues a
      // disconnect behind it.
      final diagnoseAnswer = backend.hold('ext.sleuth.diagnose');
      final refresh = bridge.refreshBaseline();
      await pumpEventQueue();
      final disconnect = bridge.disconnect();

      // The slow call now sees the transport close, and its reconnect
      // waits for the lock behind the disconnect.
      slowAnswer.complete();
      await pumpEventQueue();
      diagnoseAnswer.complete();
      await refresh;
      await disconnect;
      await slow;
      expect(bridge.isConnected, isFalse);
      expect(backend.connectCount, 1, reason: 'no reconnect after detach');
    });

    test(
      'a reconnect queued behind a connect to another app gives up',
      () async {
        final appA = _app('isolates/1', 'session-A');
        appA.registerExtension(
          'isolates/1',
          'ext.test.slow',
          (_) => _envelope('session-A'),
        );
        final appB = _app('isolates/5', 'session-B');
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 2),
          serviceConnector: (uri) =>
              (uri == _uriA.toString() ? appA : appB).connect(uri),
        );
        await bridge.connect(_uriA);
        final slowAnswer = appA.hold('ext.test.slow');
        appA.failNext(
          'ext.test.slow',
          code: -32000,
          message: 'Service connection disposed',
        );
        final slow = expectLater(
          bridge.callExtension('ext.test.slow'),
          throwsA(isA<VmBridgeException>()),
        );
        await pumpEventQueue();
        final diagnoseAnswer = appA.hold('ext.sleuth.diagnose');
        final refresh = bridge.refreshBaseline();
        await pumpEventQueue();
        final connectB = bridge.connect(_uriB);
        slowAnswer.complete();
        await pumpEventQueue();
        diagnoseAnswer.complete();
        await refresh;
        await connectB;
        await slow;
        expect(bridge.isConnected, isTrue);
        expect(bridge.baselineSessionUuid, 'session-B');
        expect(appA.connectCount, 1, reason: 'app A is not reconnected');
        expect(appB.connectCount, 1, reason: 'app B keeps its connection');
      },
    );
  });

  group('app log lines', () {
    test('a dart:developer message longer than the read stays marked '
        'truncated', () async {
      final backend = _app('isolates/1', 'session-A');
      backend
        ..objects['objects/long'] = fakeStringObject('objects/long', 'L' * 5000)
        ..objects['objects/short'] = fakeStringObject(
          'objects/short',
          'S' * 1500,
        );
      final bridge = _bridge(backend);
      final lines = <AppLogLine>[];
      final subscription = bridge.appLogLines.listen(lines.add);
      await bridge.connect(_uriA);
      await _waitFor(() => bridge.appLogStreamsActive);

      backend
        ..sendEvent(
          'Logging',
          fakeCutLogEvent(
            isolateId: 'isolates/1',
            messageId: 'objects/long',
            shown: 'L' * 128,
            length: 5000,
          ),
        )
        ..sendEvent(
          'Logging',
          fakeCutLogEvent(
            isolateId: 'isolates/1',
            messageId: 'objects/short',
            shown: 'S' * 128,
            length: 1500,
          ),
        );
      await _waitFor(() => lines.length == 2);
      expect(lines.first.text, 'L' * maxAppLogLineLength);
      expect(lines.first.truncated, isTrue);
      expect(lines.last.text, 'S' * 1500);
      expect(lines.last.truncated, isFalse);
      await subscription.cancel();
      await bridge.disconnect();
    });

    test('a message still being read when detach_app runs never reaches '
        'get_logs', () async {
      final backend = _app('isolates/1', 'session-A');
      backend.objects['objects/7'] = fakeStringObject('objects/7', 'Z' * 300);
      final bridge = _bridge(backend);
      final session = DaemonSession(
        bridge: bridge,
        server: McpServer(bridge: bridge),
      );
      await bridge.connect(_uriA);
      await _waitFor(() => bridge.appLogStreamsActive);
      backend.sendEvent('Stdout', _stdout('before detach\n'));
      await _waitFor(() => session.appLogs.length == 1);

      final read = backend.hold('getObject');
      backend.sendEvent(
        'Logging',
        fakeCutLogEvent(
          isolateId: 'isolates/1',
          messageId: 'objects/7',
          shown: 'Z' * 128,
          length: 300,
        ),
      );
      await _waitFor(() => backend.requests.contains('getObject isolates/1'));
      await session.detach();
      read.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(session.appLogs.length, 0);
      expect(session.appLogs.query(maxLines: 10).lines, isEmpty);
    });

    test('connecting to another app drops the first app\'s lines', () async {
      final appA = _app('isolates/1', 'session-A');
      final appB = _app('isolates/5', 'session-B');
      final bridge = RealVmBridge(
        callTimeout: const Duration(seconds: 2),
        serviceConnector: (uri) =>
            (uri == _uriA.toString() ? appA : appB).connect(uri),
      );
      final session = DaemonSession(
        bridge: bridge,
        server: McpServer(bridge: bridge),
      );
      await bridge.connect(_uriA);
      await _waitFor(() => bridge.appLogStreamsActive);
      appA.sendEvent('Stdout', _stdout('from A\n'));
      await _waitFor(() => session.appLogs.length == 1);

      await bridge.connect(_uriB);
      expect(session.appLogs.query(maxLines: 10).lines, isEmpty);
      await _waitFor(() => bridge.appLogStreamsActive);
      appB.sendEvent('Stdout', _stdout('from B\n'));
      await _waitFor(() => session.appLogs.length == 1);
      expect(session.appLogs.query(maxLines: 10).lines.map((l) => l.text), [
        'from B',
      ]);
      await bridge.disconnect();
    });

    test('a connect to the same URI keeps the app\'s lines', () async {
      final backend = _app('isolates/1', 'session-A');
      final bridge = _bridge(backend);
      final session = DaemonSession(
        bridge: bridge,
        server: McpServer(bridge: bridge),
      );
      await bridge.connect(_uriA);
      await _waitFor(() => bridge.appLogStreamsActive);
      backend.sendEvent('Stdout', _stdout('before\n'));
      await _waitFor(() => session.appLogs.length == 1);

      await bridge.connect(_uriA);
      await _waitFor(() => bridge.appLogStreamsActive);
      backend.sendEvent('Stdout', _stdout('after\n'));
      await _waitFor(() => session.appLogs.length == 2);
      expect(session.appLogs.query(maxLines: 10).lines.map((l) => l.text), [
        'before',
        'after',
      ]);
      await bridge.disconnect();
    });
  });
}
