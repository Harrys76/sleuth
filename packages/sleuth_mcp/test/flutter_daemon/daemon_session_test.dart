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
