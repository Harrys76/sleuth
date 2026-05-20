import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import '../helpers/fake_flutter_process.dart';
import '../helpers/fake_vm_bridge.dart';

void main() {
  group('DaemonSession.attach', () {
    test('debugUrl escape hatch connects bridge directly', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory, Map<String, String>? environment}) =>
            throw StateError('should not spawn flutter for debugUrl path'),
      );
      final result = await session.attach(
        debugUrl: 'ws://127.0.0.1:1234/tok/ws',
      );
      expect(result.attached, isTrue);
      expect(result.state, 'ready');
      expect(bridge.isConnected, isTrue);
    });

    test('error if attach is called while already attached', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory, Map<String, String>? environment}) =>
            throw StateError('unused'),
      );
      await session.attach(debugUrl: 'ws://127.0.0.1:1234/tok/ws');
      expect(
        () => session.attach(debugUrl: 'ws://127.0.0.1:1234/tok/ws'),
        throwsStateError,
      );
    });

    test('daemon path: connected → app.start → app.debugPort → ready',
        () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final fake = FakeFlutterProcess();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (exec, args,
            {String? workingDirectory,
            Map<String, String>? environment}) async {
          expect(exec, 'flutter');
          expect(args, ['attach', '--machine']);
          return fake;
        },
        attachTimeout: const Duration(seconds: 2),
      );
      final attachFuture = session.attach();
      // Drive the daemon protocol forward.
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
      final status = await attachFuture;
      expect(status.attached, isTrue);
      expect(status.state, 'ready');
      expect(status.appId, 'A');
      expect(status.device, 'iphone-12');
      expect(status.mode, 'profile');
      expect(status.launchMode, 'attach');
      await fake.close();
    });

    test('unsupported daemon version → error', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final fake = FakeFlutterProcess();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            fake,
        attachTimeout: const Duration(seconds: 2),
      );
      final attachFuture = session.attach();
      await Future<void>.delayed(Duration.zero);
      fake.emitEvent('daemon.connected', {'version': '0.5.4', 'pid': 1});
      fake.completeExit(0);
      final status = await attachFuture;
      expect(status.state, 'error');
      expect(status.lastError, contains('unsupported flutter daemon'));
    });

    test('app.stop during attach → error', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final fake = FakeFlutterProcess();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            fake,
        attachTimeout: const Duration(seconds: 2),
      );
      final attachFuture = session.attach();
      await Future<void>.delayed(Duration.zero);
      fake.emitEvent('daemon.connected', {'version': '0.6.1', 'pid': 100});
      await Future<void>.delayed(Duration.zero);
      fake.emitEvent('app.stop', {'appId': 'A'});
      fake.completeExit(0);
      final status = await attachFuture;
      expect(status.state, 'error');
      expect(status.lastError, contains('app.stop'));
    });

    test('attach timeout → error', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final fake = FakeFlutterProcess();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            fake,
        attachTimeout: const Duration(milliseconds: 80),
      );
      final attachFuture = session.attach();
      // Close fake stdout so the parser's `await for` loop can exit
      // promptly when _cleanup() cancels its subscription.
      Timer(const Duration(milliseconds: 200), () => fake.close());
      final status = await attachFuture.timeout(const Duration(seconds: 5));
      expect(status.state, 'error');
      expect(status.lastError, contains('daemon.connected'));
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('DaemonSession.detach', () {
    test('idempotent when idle', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            throw StateError('unused'),
      );
      await session.detach();
      await session.detach();
      expect(session.status.state, 'idle');
    });

    test('detach disconnects bridge after a debugUrl attach', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            throw StateError('unused'),
      );
      await session.attach(debugUrl: 'ws://127.0.0.1:1/tok/ws');
      expect(bridge.isConnected, isTrue);
      await session.detach();
      expect(bridge.isConnected, isFalse);
      expect(session.status.state, 'idle');
    });
  });

  group('DaemonSession.hotReload / hotRestart', () {
    test('refuses when not ready', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            throw StateError('unused'),
      );
      expect(() => session.hotReload(), throwsStateError);
      expect(() => session.hotRestart(), throwsStateError);
    });

    test('hot restart sends fullRestart:true', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final fake = FakeFlutterProcess();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            fake,
        attachTimeout: const Duration(seconds: 2),
        hotRestartTimeout: const Duration(seconds: 2),
      );
      final attachFuture = session.attach();
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
      await attachFuture;

      final restartFuture = session.hotRestart();
      await Future<void>.delayed(Duration.zero);
      final reqFrame = jsonDecode(fake.stdinFrames.last) as List;
      expect(
          (reqFrame.first as Map)['params'], containsPair('fullRestart', true));
      final rpcId = (reqFrame.first as Map)['id'] as int;
      fake.emitRpcResponse(rpcId, result: {'code': 0});
      fake.emitEvent('app.started', {'appId': 'A'});

      final after = await restartFuture.timeout(const Duration(seconds: 15));
      expect(after.state, 'ready');
      await fake.close();
    });

    test('hot restart: app.debugPort emitted before RPC ACK is still observed',
        () async {
      // Daemon can emit `app.debugPort` in the same event-loop turn as
      // the RPC response. A lazy subscriber misses it; the armed
      // Completer in the parser listener catches it sync-on-arrival.
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final fake = FakeFlutterProcess();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            fake,
        attachTimeout: const Duration(seconds: 2),
        hotRestartTimeout: const Duration(seconds: 2),
      );
      final attachFuture = session.attach();
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
      await attachFuture;

      final sw = Stopwatch()..start();
      final restartFuture = session.hotRestart();
      await Future<void>.delayed(Duration.zero);
      final reqFrame = jsonDecode(fake.stdinFrames.last) as List;
      final rpcId = (reqFrame.first as Map)['id'] as int;
      // debugPort BEFORE RPC response — production ordering on full restart.
      fake.emitEvent('app.debugPort', {
        'appId': 'A',
        'port': 5252,
        'wsUri': 'ws://127.0.0.1:5252/tok/ws',
      });
      fake.emitRpcResponse(rpcId, result: {'code': 0});
      // Settle resolves on AppStartedEvent (new isolate ready).
      fake.emitEvent('app.started', {'appId': 'A'});

      final after = await restartFuture.timeout(const Duration(seconds: 5));
      sw.stop();
      expect(after.state, 'ready');
      // Lost event would hit the 10s settle timeout; sync-on-arrival is immediate.
      expect(sw.elapsed.inMilliseconds, lessThan(1500));
      await fake.close();
    });

    test('hot reload happy path finishes in well under 3s (no debugPort wait)',
        () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
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
      final attachFuture = session.attach();
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
      await attachFuture;
      final genBefore = bridge.baselineGeneration;

      final sw = Stopwatch()..start();
      final reloadFuture = session.hotReload();
      await Future<void>.delayed(Duration.zero);
      final reqFrame = jsonDecode(fake.stdinFrames.last) as List;
      expect((reqFrame.first as Map)['method'], 'app.restart');
      expect((reqFrame.first as Map)['params'],
          containsPair('fullRestart', false));
      final rpcId = (reqFrame.first as Map)['id'] as int;
      fake.emitRpcResponse(rpcId, result: {'code': 0});
      final after = await reloadFuture.timeout(const Duration(seconds: 2));
      sw.stop();
      expect(after.state, 'ready');
      expect(bridge.baselineGeneration, greaterThan(genBefore));
      // fullRestart:false skips the 3s debugPort wait.
      expect(sw.elapsed.inMilliseconds, lessThan(1500));
      await fake.close();
    });

    test('hot reload rpc error → error state', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
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
      final attachFuture = session.attach();
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
      await attachFuture;

      final reloadFuture = session.hotReload();
      await Future<void>.delayed(Duration.zero);
      final reqFrame = jsonDecode(fake.stdinFrames.last) as List;
      final rpcId = (reqFrame.first as Map)['id'] as int;
      fake.emitRpcResponse(rpcId,
          error: {'code': 1, 'message': 'reload-blocked'});

      final after = await reloadFuture.timeout(const Duration(seconds: 5));
      expect(after.state, 'error');
      expect(after.lastError, contains('rpc error'));
      await fake.close();
    });
  });

  group('DaemonSession.listDevices', () {
    test('parses --machine JSON output', () async {
      final fake = _FakeDevicesProcess(
          stdout: jsonEncode([
        {
          'name': 'iPhone 12',
          'id': '00008101-XYZ',
          'platform': 'ios',
          'category': 'mobile',
        },
        {
          'name': 'macOS',
          'id': 'macos',
          'platform': 'darwin',
          'category': 'desktop',
        },
      ]));
      final devices = await DaemonSession.listDevices(
        processFactory: (_, __,
                {String? workingDirectory,
                Map<String, String>? environment}) async =>
            fake,
      );
      expect(devices, hasLength(2));
      expect(devices.first['id'], '00008101-XYZ');
    });

    test('throws when flutter exits non-zero', () async {
      final fake = _FakeDevicesProcess(stdout: '', exit: 1);
      expect(
        () => DaemonSession.listDevices(
          processFactory: (_, __,
                  {String? workingDirectory,
                  Map<String, String>? environment}) async =>
              fake,
        ),
        throwsA(isA<DaemonSessionException>()),
      );
    });

    test('throws when stdout is not a JSON array', () async {
      final fake = _FakeDevicesProcess(stdout: jsonEncode({'oops': true}));
      expect(
        () => DaemonSession.listDevices(
          processFactory: (_, __,
                  {String? workingDirectory,
                  Map<String, String>? environment}) async =>
              fake,
        ),
        throwsA(isA<DaemonSessionException>()),
      );
    });
  });

  group('DaemonSession.attachViaIos stale-mDNS recovery', () {
    Future<Process> noSpawn(String e, List<String> a,
            {String? workingDirectory, Map<String, String>? environment}) =>
        throw StateError('iOS-direct attach must not spawn flutter');

    DaemonSession sessionFor(FakeVmBridge bridge) => DaemonSession(
          bridge: bridge,
          server: McpServer(bridge: bridge)..registerDefaults(),
          processFactory: noSpawn,
        );

    test(
        'Connection reset on a dead port recovers by re-resolving with the '
        'dead port excluded', () async {
      final bridge = _FlakyConnectBridge(
          failPort: 62994, failError: 'Connection reset by peer');
      final attacher = _FakeIosAttacher([_result(62994), _result(63439)]);
      final status = await sessionFor(bridge)
          .attachViaIos(udid: 'U', bundle: 'b', attacher: attacher);
      expect(status.state, 'ready');
      expect(attacher.calls, hasLength(2));
      expect(attacher.calls[0].excludePorts, isEmpty);
      expect(attacher.calls[1].excludePorts, {62994},
          reason: 'recovery must exclude the dead device port');
      expect(attacher.calls[1].forceRelaunch, isFalse,
          reason: 'recovery re-probes; it does not force a launch');
    });

    test('wireless failure (Operation not permitted) does not recover',
        () async {
      final bridge = _FlakyConnectBridge(
          failPort: 62994, failError: 'Operation not permitted');
      final attacher = _FakeIosAttacher([_result(62994)]);
      final status = await sessionFor(bridge)
          .attachViaIos(udid: 'U', bundle: 'b', attacher: attacher);
      expect(status.state, 'error');
      expect(status.lastError, contains('ios_vmservice_unreachable'));
      expect(attacher.calls, hasLength(1),
          reason: 'no retry for transport fail');
    });

    test('exhausted attach budget skips recovery', () async {
      final bridge = _FlakyConnectBridge(
          failPort: 62994, failError: 'Connection reset by peer');
      final attacher = _FakeIosAttacher([_result(62994), _result(63439)]);
      final status = await sessionFor(bridge).attachViaIos(
        udid: 'U',
        bundle: 'b',
        attacher: attacher,
        attachBudget: Duration.zero,
      );
      expect(status.state, 'error');
      expect(status.lastError, contains('ios_vmservice_busy'));
      expect(attacher.calls, hasLength(1), reason: 'budget gate blocks retry');
    });

    test(
        'recovery with no live alternative surfaces the original busy '
        'error, not the fallback bonjour timeout', () async {
      final bridge = _FlakyConnectBridge(
          failPort: 62994, failError: 'Connection reset by peer');
      // Attempt 1: dead port → reset → recover. Attempt 2: re-resolve found
      // only the (excluded) dead port → pipeline raises bonjourTimeout.
      final attacher = _FakeIosAttacher([_result(62994), null]);
      final status = await sessionFor(bridge)
          .attachViaIos(udid: 'U', bundle: 'b', attacher: attacher);
      expect(status.state, 'error');
      expect(status.lastError, startsWith('ios_vmservice_busy:'),
          reason: 'the dead-port cause is more accurate than bonjourTimeout');
      expect(attacher.calls, hasLength(2));
    });

    test('ambiguous pairings: iterates candidates, keeps the live one',
        () async {
      // Sorted order tries 'aDead' before 'zLive'.
      final bridge = _FlakyConnectBridge(
          failPort: 70001, failError: 'Connection reset by peer');
      final attacher = _AmbiguousAttacher(
        candidates: ['aDead', 'zLive'],
        portFor: (a) => a == 'aDead' ? 70001 : 70002,
      );
      final status = await sessionFor(bridge)
          .attachViaIos(udid: 'U', bundle: 'b', attacher: attacher);
      expect(status.state, 'ready');
      expect(attacher.authCalls, [null, 'aDead', 'zLive'],
          reason: 'seed (null) → dead candidate → live candidate');
    });

    test('ambiguous pairings: all candidates dead → ios_vmservice_busy',
        () async {
      final bridge = _AllDeadBridge('Connection reset by peer');
      final attacher = _AmbiguousAttacher(
        candidates: ['a', 'b'],
        portFor: (a) => a == 'a' ? 70001 : 70002,
      );
      final status = await sessionFor(bridge)
          .attachViaIos(udid: 'U', bundle: 'b', attacher: attacher);
      expect(status.state, 'error');
      expect(status.lastError, startsWith('ios_vmservice_busy:'));
      expect(attacher.authCalls, [null, 'a', 'b']);
    });

    test('ambiguous pairings: a candidate whose attach throws advances',
        () async {
      final bridge = _FlakyConnectBridge(
          failPort: 70001, failError: 'Connection reset by peer');
      final attacher = _AmbiguousAttacher(
        candidates: ['a', 'b'],
        portFor: (_) => 70002,
        throwForAuth: 'a', // 'a' attach raises noMatchingAuth → advance
      );
      final status = await sessionFor(bridge)
          .attachViaIos(udid: 'U', bundle: 'b', attacher: attacher);
      expect(status.state, 'ready');
      expect(attacher.authCalls, [null, 'a', 'b']);
    });

    test('user authOverride pins a service — no candidate iteration', () async {
      final bridge = _FlakyConnectBridge(
          failPort: 70001, failError: 'Connection reset by peer');
      final attacher = _AmbiguousAttacher(
        candidates: ['a', 'b'],
        portFor: (_) => 70002,
      );
      final status = await sessionFor(bridge).attachViaIos(
          udid: 'U', bundle: 'b', authOverride: 'pinned', attacher: attacher);
      expect(status.state, 'ready');
      expect(attacher.authCalls, ['pinned'],
          reason: 'authOverride set → single attempt, no ambiguity seed');
    });

    test('candidate version-skew failure surfaces immediately — no advance',
        () async {
      final bridge = _FlakyConnectBridge(
          failPort: 80001, failError: 'version_skew_major: 0.34 vs pin 0.35');
      final attacher = _AmbiguousAttacher(
        candidates: ['c1', 'c2'],
        portFor: (a) => a == 'c1' ? 80001 : 80002,
      );
      final status = await sessionFor(bridge)
          .attachViaIos(udid: 'U', bundle: 'b', attacher: attacher);
      expect(status.state, 'error');
      expect(status.lastError, contains('version_skew'),
          reason: 'fail-closed contract error must not be masked');
      expect(attacher.authCalls, [null, 'c1'],
          reason: 'non-stale failure must NOT advance to c2');
    });

    test('half-open candidate (connect timeout) advances to the live one',
        () async {
      final bridge = _TimeoutThenLiveBridge(80001);
      final attacher = _AmbiguousAttacher(
        candidates: ['c1', 'c2'],
        portFor: (a) => a == 'c1' ? 80001 : 80002,
      );
      final status = await sessionFor(bridge).attachViaIos(
        udid: 'U',
        bundle: 'b',
        attacher: attacher,
        bridgeConnectTimeout: const Duration(milliseconds: 150),
      );
      expect(status.state, 'ready');
      expect(attacher.authCalls, [null, 'c1', 'c2'],
          reason: 'c1 half-open (timeout) → advance to live c2');
    });
  });

  group('mapBridgeConnectErrorToLastError classifies real dart:io errors', () {
    test('SocketException(Connection reset) → ios_vmservice_busy', () {
      const e = SocketException('Connection reset by peer');
      expect(DaemonSession.mapBridgeConnectErrorToLastError('$e'),
          startsWith('ios_vmservice_busy:'));
    });

    test('HttpException(closed before full header) → ios_vmservice_busy', () {
      const e = HttpException('Connection closed before full header');
      expect(DaemonSession.mapBridgeConnectErrorToLastError('$e'),
          startsWith('ios_vmservice_busy:'));
    });

    test('SocketException(Connection refused) → device-dead unreachable', () {
      const e = SocketException('Connection refused');
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError('$e');
      expect(mapped, startsWith('ios_vmservice_unreachable:'));
      expect(mapped, contains('nothing is listening'));
    });

    test('SocketException(Operation not permitted) → wireless unreachable', () {
      const e = SocketException('Operation not permitted');
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError('$e');
      expect(mapped, startsWith('ios_vmservice_unreachable:'));
      expect(mapped, contains('wireless'));
    });

    test('refused takes precedence over a co-present wireless marker', () {
      // Classifier checks the dead-port markers before the wireless ones,
      // so a message carrying both resolves to the device-dead remedy.
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError(
          'Connection refused; Operation not permitted');
      expect(mapped, startsWith('ios_vmservice_unreachable:'));
      expect(mapped, contains('nothing is listening'));
    });
  });
}

/// One-shot fake for `flutter devices --machine`: emits a stdout payload
/// and exits with [exit] immediately.
class _FakeDevicesProcess implements Process {
  _FakeDevicesProcess({required String stdout, int exit = 0})
      : _stdoutBytes = utf8.encode(stdout),
        _exit = exit {
    scheduleMicrotask(() async {
      _stdoutCtrl.add(_stdoutBytes);
      await _stdoutCtrl.close();
      await _stderrCtrl.close();
      _exitCompleter.complete(_exit);
    });
  }

  final List<int> _stdoutBytes;
  final int _exit;
  final _stdoutCtrl = StreamController<List<int>>();
  final _stderrCtrl = StreamController<List<int>>();
  final Completer<int> _exitCompleter = Completer<int>();

  @override
  int get pid => 1;
  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;
  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;
  @override
  IOSink get stdin =>
      throw UnimplementedError('devices --machine does not read stdin');
  @override
  Future<int> get exitCode => _exitCompleter.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

/// Builds an [IosAttachResult] whose selected announcement (and wsUri)
/// carry [port], so a bridge can key its connect outcome on the port.
IosAttachResult _result(int port) {
  final ann = BonjourAnnouncement(
    interfaceIndex: 24,
    host: 'Pengen.local.',
    port: port,
    authCode: 'auth',
  );
  return IosAttachResult(
    wsUri: 'ws://127.0.0.1:$port/auth=/ws',
    transport: IosTransport.wired,
    announcements: [ann],
    selected: ann,
    hostPort: port,
    teardown: () async {},
    origin: IosAttachOrigin.probedExisting,
  );
}

/// Fake attacher returning canned results per call, recording the
/// `forceRelaunch` / `excludePorts` it was asked for.
class _FakeIosAttacher extends IosAttacher {
  _FakeIosAttacher(this._results);

  // A null entry simulates the pipeline raising bonjourTimeout (the
  // recovery re-resolve found no live port after exclusion).
  final List<IosAttachResult?> _results;
  final List<({bool forceRelaunch, Set<int> excludePorts})> calls = [];
  int _i = 0;

  @override
  Future<IosAttachResult> attach({
    required String udid,
    required String bundle,
    String? authOverride,
    int? hostPortOverride,
    IosTransport? transportOverride,
    Duration bonjourCollectFor = const Duration(seconds: 8),
    Duration bonjourTimeout = const Duration(seconds: 20),
    Duration launchSettle = const Duration(seconds: 1),
    Duration readinessWindow = const Duration(milliseconds: 300),
    String pidfileDirectory = '/tmp',
    IosAttachProgress? onProgress,
    Stream<void>? cancelSignal,
    Map<String, String>? environment,
    bool forceRelaunch = false,
    Set<int> excludePorts = const <int>{},
    Duration devicectlTimeout = const Duration(seconds: 20),
  }) async {
    calls.add((forceRelaunch: forceRelaunch, excludePorts: excludePorts));
    final r = _results[_i < _results.length ? _i : _results.length - 1];
    _i++;
    if (r == null) {
      throw IosAttachException(
          IosAttachErrorKind.bonjourTimeout, 'no Bonjour announcement seen');
    }
    return r;
  }
}

/// Bridge that throws [failError] when the wsUri targets [failPort], and
/// connects normally otherwise — models a dead device port resetting the
/// iproxy tunnel while a live port answers.
class _FlakyConnectBridge extends FakeVmBridge {
  _FlakyConnectBridge({required this.failPort, required this.failError})
      : super(fakeSessionUuid: 'u', envelopes: const {
          'ext.sleuth.diagnose': {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'u',
            'data': {'packageVersion': '0.35.0'},
          },
        });

  final int failPort;
  final String failError;

  @override
  Future<bool> connect(Uri wsUri) async {
    if (wsUri.toString().contains(':$failPort/')) {
      throw Exception(failError);
    }
    return super.connect(wsUri);
  }
}

/// Like [_result] but carries [auth] in the wsUri so a port-keyed bridge
/// distinguishes per-candidate connects.
IosAttachResult _resultAuth(int port, String auth) {
  final ann = BonjourAnnouncement(
    interfaceIndex: 24,
    host: 'Pengen.local.',
    port: port,
    authCode: auth,
  );
  return IosAttachResult(
    wsUri: 'ws://127.0.0.1:$port/$auth=/ws',
    transport: IosTransport.wired,
    announcements: [ann],
    selected: ann,
    hostPort: port,
    teardown: () async {},
    origin: IosAttachOrigin.probedExisting,
  );
}

/// Fake attacher modeling ambiguous pairings: the no-authOverride call
/// throws `ambiguousPairings` carrying [candidates]; per-candidate calls
/// return a result on `portFor(auth)` (or throw `noMatchingAuth` when the
/// auth is in [throwForAuth], modeling a vanished announcement).
class _AmbiguousAttacher extends IosAttacher {
  _AmbiguousAttacher({
    required this.candidates,
    required this.portFor,
    this.throwForAuth,
  });

  final List<String> candidates;
  final int Function(String auth) portFor;
  final String? throwForAuth;
  final List<String?> authCalls = [];

  @override
  Future<IosAttachResult> attach({
    required String udid,
    required String bundle,
    String? authOverride,
    int? hostPortOverride,
    IosTransport? transportOverride,
    Duration bonjourCollectFor = const Duration(seconds: 8),
    Duration bonjourTimeout = const Duration(seconds: 20),
    Duration launchSettle = const Duration(seconds: 1),
    Duration readinessWindow = const Duration(milliseconds: 300),
    String pidfileDirectory = '/tmp',
    IosAttachProgress? onProgress,
    Stream<void>? cancelSignal,
    Map<String, String>? environment,
    bool forceRelaunch = false,
    Set<int> excludePorts = const <int>{},
    Duration devicectlTimeout = const Duration(seconds: 20),
  }) async {
    authCalls.add(authOverride);
    if (authOverride == null) {
      throw IosAttachException(
        IosAttachErrorKind.ambiguousPairings,
        'ambiguous Bonjour pairings',
        data: <String, Object?>{'distinctAuthCodes': candidates},
      );
    }
    if (authOverride == throwForAuth) {
      throw IosAttachException(
          IosAttachErrorKind.noMatchingAuth, 'no announcement matched');
    }
    return _resultAuth(portFor(authOverride), authOverride);
  }
}

/// Bridge whose every connect fails — models all candidates dead.
class _AllDeadBridge extends FakeVmBridge {
  _AllDeadBridge(this.failError)
      : super(fakeSessionUuid: 'u', envelopes: const {
          'ext.sleuth.diagnose': {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'u',
            'data': {'packageVersion': '0.35.0'},
          },
        });

  final String failError;

  @override
  Future<bool> connect(Uri wsUri) async => throw Exception(failError);
}

/// Bridge whose connect to [timeoutPort] never completes (models a
/// half-open VM service — WS accepts, getVM hangs); other ports connect.
class _TimeoutThenLiveBridge extends FakeVmBridge {
  _TimeoutThenLiveBridge(this.timeoutPort)
      : super(fakeSessionUuid: 'u', envelopes: const {
          'ext.sleuth.diagnose': {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'u',
            'data': {'packageVersion': '0.35.0'},
          },
        });

  final int timeoutPort;

  @override
  Future<bool> connect(Uri wsUri) {
    if (wsUri.toString().contains(':$timeoutPort/')) {
      return Completer<bool>().future; // never completes → caller times out
    }
    return super.connect(wsUri);
  }
}
