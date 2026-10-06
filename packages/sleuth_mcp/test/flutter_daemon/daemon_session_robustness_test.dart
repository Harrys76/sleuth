import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/bridge/app_log_stream.dart';
import 'package:sleuth_mcp/src/flutter_daemon/app_log_buffer.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm;

import '../helpers/fake_flutter_process.dart';
import '../helpers/fake_vm_bridge.dart';

/// Builds a [DaemonSession] whose flutter children come from [processes],
/// one per spawn, and records every spawn.
DaemonSession _session(
  VmBridge bridge, {
  List<Process> processes = const [],
  List<List<String>>? spawns,
  Duration attachTimeout = const Duration(seconds: 30),
  Duration hotReloadTimeout = const Duration(seconds: 2),
  bool? hostIsMacOS,
  IosAttacher? iosAttacher,
  AppLogBuffer? appLogs,
}) {
  var next = 0;
  return DaemonSession(
    bridge: bridge,
    server: McpServer(bridge: bridge)..registerDefaults(),
    processFactory:
        (
          String exe,
          List<String> args, {
          String? workingDirectory,
          Map<String, String>? environment,
        }) async {
          spawns?.add(args);
          if (args.first == 'devices') {
            throw StateError('device probe not scripted');
          }
          if (next >= processes.length) {
            throw StateError('no process scripted for spawn ${next + 1}');
          }
          return processes[next++];
        },
    attachTimeout: attachTimeout,
    hotReloadTimeout: hotReloadTimeout,
    hostIsMacOS: hostIsMacOS,
    iosAttacher: iosAttacher,
    appLogs: appLogs,
  );
}

/// Drives [fake] through the daemon handshake up to `app.debugPort`.
Future<void> _driveToDebugPort(
  FakeFlutterProcess fake, {
  int port = 4242,
}) async {
  await Future<void>.delayed(Duration.zero);
  fake.emitEvent('daemon.connected', {'version': '0.6.1', 'pid': 100});
  await Future<void>.delayed(Duration.zero);
  fake.emitEvent('app.start', {
    'appId': 'A',
    'deviceId': 'pixel',
    'launchMode': 'attach',
    'mode': 'profile',
  });
  await Future<void>.delayed(Duration.zero);
  fake.emitEvent('app.debugPort', {
    'appId': 'A',
    'port': port,
    'wsUri': 'ws://127.0.0.1:$port/tok/ws',
  });
}

/// Lets queued events and microtasks run.
Future<void> _settle([int ms = 20]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Detaches [session] and answers the `app.detach` RPC it sends to [fake],
/// so the detach does not wait out the 5 second RPC timeout.
Future<void> _detach(DaemonSession session, FakeFlutterProcess fake) async {
  final sent = fake.stdinFrames.length;
  final done = session.detach();
  await _settle(5);
  final frames = fake.stdinFrames;
  if (frames.length > sent) {
    final request = (jsonDecode(frames.last) as List).first as Map;
    if (request['method'] == 'app.detach') {
      fake.emitRpcResponse(request['id'] as int, result: {'code': 0});
    }
  }
  await done.timeout(const Duration(seconds: 3));
}

void main() {
  group('daemon attach robustness', () {
    test('a detach during an attach, then a re-attach: the stale attach\'s '
        'timeout handler never touches the newer flutter child', () async {
      // The first connect hangs until the test releases it with a
      // TimeoutException, which reaches the stale attach after a detach and
      // a newer attach took over.
      final bridge = _GatedConnectBridge();
      final first = FakeFlutterProcess(pid: 1);
      final second = FakeFlutterProcess(pid: 2);
      final session = _session(bridge, processes: [first, second]);

      final staleAttach = session.attach();
      await _driveToDebugPort(first);
      await _settle();
      expect(bridge.pendingConnects, 1);

      await _detach(session, first);
      expect(first.killed, isTrue);
      expect(session.status.state, 'idle');

      final freshAttach = session.attach();
      await _settle();
      expect(session.status.state, 'attaching');

      bridge.failPending(
        TimeoutException('getVM', const Duration(seconds: 30)),
      );
      final stale = await staleAttach.timeout(const Duration(seconds: 2));
      expect(stale.attached, isFalse);
      await _settle();
      expect(second.killed, isFalse, reason: 'stale cleanup killed the child');
      expect(session.status.state, 'attaching');

      await _driveToDebugPort(second);
      final fresh = await freshAttach.timeout(const Duration(seconds: 2));
      expect(fresh.state, 'ready');
      expect(fresh.attached, isTrue);
      expect(second.killed, isFalse);
      await _detach(session, second);
    });

    test(
      'a detach while the attach waits for the daemon, then a re-attach',
      () async {
        final bridge = defaultFakeBridge();
        final first = FakeFlutterProcess(pid: 1);
        final second = FakeFlutterProcess(pid: 2);
        final session = _session(
          bridge,
          processes: [first, second],
          attachTimeout: const Duration(milliseconds: 300),
        );
        final staleAttach = session.attach();
        await _settle();
        await session.detach();
        final stale = await staleAttach.timeout(const Duration(seconds: 1));
        expect(stale.state, 'idle', reason: 'returns without its timeout');

        final freshAttach = session.attach();
        await _driveToDebugPort(second);
        expect((await freshAttach).state, 'ready');
        // Past the stale attach's 300 ms timeout: nothing of it still runs.
        await _settle(400);
        expect(second.killed, isFalse);
        expect(session.status.state, 'ready');
        await _detach(session, second);
      },
    );

    test('bridge.connect throwing something other than VmBridgeException '
        'releases the child and records the error', () async {
      final bridge = _ThrowingConnectBridge(
        vm.RPCError('getVM', -32000, 'transport closed during bootstrap'),
      );
      final fake = FakeFlutterProcess();
      final session = _session(bridge, processes: [fake]);
      final attach = session.attach();
      await _driveToDebugPort(fake);
      final status = await attach.timeout(const Duration(seconds: 3));
      expect(status.state, 'error');
      expect(status.attached, isFalse);
      expect(status.lastError, contains('attach failed'));
      expect(status.lastError, contains('transport closed during bootstrap'));
      expect(fake.killed, isTrue, reason: 'the flutter child must not leak');
      expect(session.status.state, 'error');
    });

    test('flutter exiting early ends the attach at once and quotes its '
        'last output', () async {
      final bridge = defaultFakeBridge();
      final fake = FakeFlutterProcess();
      final session = _session(bridge, processes: [fake]);
      final watch = Stopwatch()..start();
      final attach = session.attach();
      await _settle();
      fake.emitStdoutText(
        'More than one device connected; please specify a '
        'device with the -d <deviceId> flag.',
      );
      fake.emitStderr('Pixel 7 (mobile) • 1A2B\niPhone 12 (mobile) • 0000\n');
      fake.exitEarly(1);
      final status = await attach.timeout(const Duration(seconds: 3));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(status.state, 'error');
      expect(status.lastError, contains('exited with code 1'));
      expect(status.lastError, contains('More than one device connected'));
      expect(status.lastError, contains('iPhone 12 (mobile)'));
    });

    test('flutter exiting with no output names the common causes', () async {
      final bridge = defaultFakeBridge();
      final fake = FakeFlutterProcess();
      final session = _session(bridge, processes: [fake]);
      final attach = session.attach();
      await _settle();
      fake.emitEvent('daemon.connected', {'version': '0.6.1', 'pid': 100});
      await _settle();
      fake.exitEarly(2);
      final status = await attach.timeout(const Duration(seconds: 3));
      expect(status.state, 'error');
      expect(status.lastError, contains('exited with code 2'));
      expect(status.lastError, contains('more than one device is connected'));
    });

    test('an attach timeout does not wait for a silent flutter child to '
        'close its output', () async {
      final bridge = defaultFakeBridge();
      final stubborn = _SilentProcess();
      final session = _session(
        bridge,
        processes: [stubborn],
        attachTimeout: const Duration(milliseconds: 100),
      );
      final status = await session.attach().timeout(const Duration(seconds: 3));
      expect(status.state, 'error');
      expect(status.lastError, contains('daemon.connected'));
      expect(stubborn.killed, isTrue);
    });

    test('a detach while the attach waits for the daemon ends that attach '
        'without its timeout', () async {
      final bridge = defaultFakeBridge();
      final fake = FakeFlutterProcess();
      final session = _session(bridge, processes: [fake]);
      final attach = session.attach();
      await _settle();
      await session.detach();
      final status = await attach.timeout(const Duration(seconds: 2));
      expect(status.attached, isFalse);
      expect(session.status.state, 'idle');
    });

    test(
      'a cancel signal stops a daemon attach and leaves the session idle',
      () async {
        final bridge = defaultFakeBridge();
        final fake = FakeFlutterProcess();
        final session = _session(bridge, processes: [fake]);
        final cancel = StreamController<void>();
        final attach = session.attach(cancelSignal: cancel.stream);
        await _settle();
        cancel.add(null);
        final status = await attach.timeout(const Duration(seconds: 2));
        expect(status.attached, isFalse);
        expect(fake.killed, isTrue);
        expect(session.status.state, 'idle');
        await cancel.close();
      },
    );

    test('progress messages follow the daemon stages', () async {
      final bridge = defaultFakeBridge();
      final fake = FakeFlutterProcess();
      final session = _session(bridge, processes: [fake]);
      final messages = <String>[];
      final attach = session.attach(onProgress: messages.add);
      await _driveToDebugPort(fake);
      await attach.timeout(const Duration(seconds: 2));
      expect(messages, [
        'Starting flutter attach',
        'Waiting for the flutter daemon to start',
        'Flutter daemon connected; waiting for the app to report its VM '
            'service',
        'Connecting to the app VM service',
      ]);
      await _detach(session, fake);
    });

    test(
      'an attach after a failed hot reload releases the earlier child',
      () async {
        final bridge = defaultFakeBridge();
        final first = FakeFlutterProcess(pid: 1);
        final second = FakeFlutterProcess(pid: 2);
        final session = _session(
          bridge,
          processes: [first, second],
          hotReloadTimeout: const Duration(milliseconds: 50),
        );
        final attach = session.attach();
        await _driveToDebugPort(first);
        await attach;
        final reloaded = await session.hotReload();
        expect(reloaded.state, 'error', reason: 'the reload RPC timed out');
        expect(first.killed, isFalse);

        final again = session.attach();
        await _settle();
        expect(first.killed, isTrue);
        await _driveToDebugPort(second);
        expect((await again).state, 'ready');
        await _detach(session, second);
      },
    );
  });

  group('detach bounds', () {
    test('the default budget keeps a detach well inside the 10 s exit '
        'bound', () {
      const budget = DetachBudget();
      expect(budget.worstCase, lessThanOrEqualTo(const Duration(seconds: 8)));
      expect(
        budget.appDetach +
            budget.childTerm +
            budget.childKill +
            budget.bridgeDisconnect,
        lessThanOrEqualTo(budget.worstCase),
      );
    });

    test('a detach where every step stalls ends within its budget and '
        'still sends SIGKILL', () async {
      const budget = DetachBudget(
        appDetach: Duration(milliseconds: 100),
        childTerm: Duration(milliseconds: 100),
        childKill: Duration(milliseconds: 100),
        bridgeDisconnect: Duration(milliseconds: 100),
        iosTeardown: Duration(milliseconds: 100),
      );
      final bridge = _StuckDisconnectBridge();
      final child = _UnkillableProcess();
      final session = DaemonSession(
        bridge: bridge,
        server: McpServer(bridge: bridge)..registerDefaults(),
        processFactory:
            (
              String exe,
              List<String> args, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async => child,
        detachBudget: budget,
      );
      final attach = session.attach();
      await _settle();
      child.emitEvent('daemon.connected', {'version': '0.6.1', 'pid': 1});
      child.emitEvent('app.start', {
        'appId': 'A',
        'deviceId': 'pixel',
        'launchMode': 'attach',
        'mode': 'profile',
      });
      child.emitEvent('app.debugPort', {
        'appId': 'A',
        'port': 4242,
        'wsUri': 'ws://127.0.0.1:4242/tok/ws',
      });
      expect((await attach).state, 'ready');

      final watch = Stopwatch()..start();
      // The daemon never answers app.detach, the child ignores every
      // signal and the bridge never finishes disconnecting.
      await session.detach().timeout(const Duration(seconds: 3));
      expect(
        watch.elapsed,
        lessThan(budget.worstCase + const Duration(milliseconds: 400)),
      );
      expect(child.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      expect(session.status.state, 'idle');
    });
  });

  group('detach and status', () {
    test(
      'detach while idle disconnects a bridge opened with connect',
      () async {
        final bridge = defaultFakeBridge();
        final session = _session(bridge);
        await bridge.connect(Uri.parse('ws://127.0.0.1:1/tok/ws'));
        expect(session.status.state, 'idle');
        expect(session.status.connected, isTrue);
        await session.detach();
        expect(bridge.isConnected, isFalse);
        expect(session.status.connected, isFalse);
      },
    );

    test('a connect session reports connected through connect, not '
        'attached', () async {
      final bridge = defaultFakeBridge();
      final session = _session(bridge);
      await bridge.connect(Uri.parse('ws://127.0.0.1:1/tok/ws'));
      final json = session.status.toJson();
      expect(json['attached'], isFalse);
      expect(json['state'], 'idle');
      expect(json['connected'], isTrue);
      expect(json['connectedVia'], 'connect');
    });

    test('each attach route reports its connectedVia', () async {
      final bridge = defaultFakeBridge();
      final fake = FakeFlutterProcess();
      final session = _session(bridge, processes: [fake]);

      await session.attach(debugUrl: 'ws://127.0.0.1:1/tok/ws');
      expect(session.status.connectedVia, 'attach_debug_url');
      await session.detach();

      final attach = session.attach();
      await _driveToDebugPort(fake);
      await attach;
      expect(session.status.connectedVia, 'attach_device');
      await _detach(session, fake);

      final ios = _session(bridge, iosAttacher: _ScriptedIosAttacher());
      final status = await ios.attachViaIos(udid: 'U', bundle: 'b');
      expect(status.connectedVia, 'attach_ios');
      await ios.detach();
    });

    test(
      'a ready session whose bridge dropped does not report attached',
      () async {
        final bridge = defaultFakeBridge();
        final session = _session(bridge);
        await session.attach(debugUrl: 'ws://127.0.0.1:1/tok/ws');
        expect(session.status.attached, isTrue);
        await bridge.disconnect();
        final status = session.status;
        expect(status.state, 'ready');
        expect(status.attached, isFalse);
        expect(status.connected, isFalse);
        expect(status.toJson().containsKey('connectedVia'), isFalse);
      },
    );
  });

  group('hot reload', () {
    test('a debugUrl session refuses hot reload and keeps working', () async {
      final bridge = defaultFakeBridge();
      final session = _session(bridge);
      await session.attach(debugUrl: 'ws://127.0.0.1:1/tok/ws');
      await expectLater(
        session.hotReload,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            startsWith('hot_reload_unsupported:'),
          ),
        ),
      );
      expect(session.status.state, 'ready');
      expect(session.status.attached, isTrue);
      expect(bridge.isConnected, isTrue);
    });

    test(
      'a reload flutter rejects throws and keeps the session ready',
      () async {
        final bridge = defaultFakeBridge();
        final fake = FakeFlutterProcess();
        final session = _session(bridge, processes: [fake]);
        final attach = session.attach();
        await _driveToDebugPort(fake);
        await attach;

        final reload = session.hotReload();
        await _settle();
        final request = jsonDecode(fake.stdinFrames.last) as List;
        final id = (request.first as Map)['id'] as int;
        fake.emitRpcResponse(
          id,
          result: {'code': 1, 'message': 'Compilation failed'},
        );
        await expectLater(
          reload,
          throwsA(
            isA<DaemonSessionException>().having(
              (e) => e.message,
              'message',
              allOf(contains('rejected'), contains('Compilation failed')),
            ),
          ),
        );
        expect(session.status.state, 'ready');
        expect(session.status.attached, isTrue);
        await _detach(session, fake);
      },
    );
  });

  group('iOS attach robustness', () {
    test(
      'a non-IosAttachException from the pipeline sets the error state',
      () async {
        final bridge = defaultFakeBridge();
        final session = _session(bridge);
        final status = await session.attachViaIos(
          udid: 'U',
          bundle: 'b',
          attacher: _ThrowingIosAttacher(
            const ProcessException('which', ['xcrun'], 'No such file'),
          ),
        );
        expect(status.state, 'error');
        expect(status.lastError, contains('iOS attach failed'));
        expect(status.lastError, contains('No such file'));
        // The mutex was released, so a retry runs instead of being refused.
        final retry = await session.attachViaIos(
          udid: 'U',
          bundle: 'b',
          attacher: _ScriptedIosAttacher(),
        );
        expect(retry.state, 'ready');
        await session.detach();
      },
    );

    test(
      'a pidfile lock timeout does not leave the session attaching',
      () async {
        final bridge = defaultFakeBridge();
        final session = _session(bridge);
        final status = await session.attachViaIos(
          udid: 'U',
          bundle: 'b',
          attacher: _ThrowingIosAttacher(
            TimeoutException('pidfile lock', const Duration(seconds: 10)),
          ),
        );
        expect(status.state, 'error');
      },
    );

    test('a host other than macOS gets a clear missing-tool error', () async {
      final bridge = defaultFakeBridge();
      final session = _session(bridge, hostIsMacOS: false);
      await expectLater(
        session.attachViaIos(udid: 'U', bundle: 'b'),
        throwsA(
          isA<IosAttachException>()
              .having((e) => e.kind, 'kind', IosAttachErrorKind.missingTool)
              .having((e) => e.message, 'message', contains('only on macOS')),
        ),
      );
      expect(session.status.state, 'idle');
    });

    test('a cancel reaches the pipeline and detaches the session', () async {
      final bridge = defaultFakeBridge();
      final attacher = _WaitForCancelAttacher();
      final session = _session(bridge, iosAttacher: attacher);
      final cancel = StreamController<void>();
      final attach = session.attachViaIos(
        udid: 'U',
        bundle: 'b',
        cancelSignal: cancel.stream,
      );
      await _settle();
      expect(session.status.state, 'attaching');
      cancel.add(null);
      await expectLater(
        attach.timeout(const Duration(seconds: 2)),
        throwsA(
          isA<IosAttachException>().having(
            (e) => e.kind,
            'kind',
            IosAttachErrorKind.cancelled,
          ),
        ),
      );
      expect(session.status.state, 'idle');
      await cancel.close();
    });
  });

  group('app log capture', () {
    test('daemon app.log lines fill the buffer while the bridge has no VM '
        'log streams', () async {
      final bridge = defaultFakeBridge();
      final fake = FakeFlutterProcess();
      final session = _session(bridge, processes: [fake]);
      final attach = session.attach();
      await _driveToDebugPort(fake);
      await attach;
      fake.emitEvent('app.log', {'appId': 'A', 'log': 'hello\nworld'});
      await _settle();
      expect(session.logCapture, 'daemon');
      expect(session.appLogs.query(maxLines: 10).lines.map((l) => l.text), [
        'hello',
        'world',
      ]);
      expect(
        session.appLogs.query(maxLines: 10).lines.map((l) => l.source),
        everyElement('daemon'),
      );
      await _detach(session, fake);
      expect(session.appLogs.length, 0, reason: 'detach clears the buffer');
    });

    test(
      'VM log lines feed the buffer and replace the daemon fallback',
      () async {
        final bridge = _LogBridge();
        final fake = FakeFlutterProcess();
        final session = _session(bridge, processes: [fake]);
        final attach = session.attach();
        await _driveToDebugPort(fake);
        await attach;
        bridge.active = true;
        bridge.emit(
          AppLogLine(time: DateTime.now(), source: 'stdout', text: 'from vm'),
        );
        fake.emitEvent('app.log', {'appId': 'A', 'log': 'from daemon'});
        await _settle();
        expect(session.logCapture, 'vm_service');
        expect(session.appLogs.query(maxLines: 10).lines.map((l) => l.text), [
          'from vm',
        ]);
        await _detach(session, fake);
      },
    );
  });
}

/// A flutter child that exits when killed but keeps stdout open, as a real
/// child can while it shuts down.
class _SilentProcess implements Process {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool killed = false;

  @override
  int get pid => 7;
  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => _NullSink();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-15);
    return true;
  }
}

/// A flutter child that speaks the daemon protocol but never exits, even on
/// SIGKILL, and never answers RPCs.
class _UnkillableProcess implements Process {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final signals = <ProcessSignal>[];

  void emitEvent(String event, Map<String, Object?> params) {
    _stdout.add(
      utf8.encode(
        '${jsonEncode([
          {'event': event, 'params': params},
        ])}\n',
      ),
    );
  }

  @override
  int get pid => 8;
  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => _NullSink();
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    return true;
  }
}

/// Fake bridge whose disconnect never finishes.
class _StuckDisconnectBridge extends FakeVmBridge {
  _StuckDisconnectBridge()
    : super(
        fakeSessionUuid: 'u',
        envelopes: const {
          'ext.sleuth.diagnose': {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'u',
            'data': {'packageVersion': '0.37.0'},
          },
        },
      );

  @override
  Future<void> disconnect() => Completer<void>().future;
}

class _NullSink implements IOSink {
  @override
  Encoding encoding = utf8;
  @override
  void add(List<int> data) {}
  @override
  void write(Object? obj) {}
  @override
  void writeln([Object? obj = '']) {}
  @override
  void writeAll(Iterable<dynamic> objs, [String sep = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void addError(Object error, [StackTrace? st]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done => Future.value();
}

/// Fake bridge whose connect throws [error].
class _ThrowingConnectBridge extends FakeVmBridge {
  _ThrowingConnectBridge(this.error)
    : super(
        fakeSessionUuid: 'u',
        envelopes: const {
          'ext.sleuth.diagnose': {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'u',
            'data': {'packageVersion': '0.37.0'},
          },
        },
      );

  final Object error;

  @override
  Future<bool> connect(Uri wsUri) async => throw error;
}

/// Fake bridge whose first connect hangs until [failPending] fails it;
/// later connects succeed.
class _GatedConnectBridge extends FakeVmBridge {
  _GatedConnectBridge()
    : super(
        fakeSessionUuid: 'u',
        envelopes: const {
          'ext.sleuth.diagnose': {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'u',
            'data': {'packageVersion': '0.37.0'},
          },
        },
      );

  Completer<bool>? _pending;
  int pendingConnects = 0;
  var _gated = true;

  void failPending(Object error) => _pending?.completeError(error);

  @override
  Future<bool> connect(Uri wsUri) {
    if (_gated) {
      _gated = false;
      pendingConnects++;
      return (_pending = Completer<bool>()).future;
    }
    return super.connect(wsUri);
  }
}

/// Fake bridge that also forwards app log lines.
class _LogBridge extends FakeVmBridge implements AppLogSource {
  _LogBridge()
    : super(
        fakeSessionUuid: 'u',
        envelopes: const {
          'ext.sleuth.diagnose': {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'u',
            'data': {'packageVersion': '0.37.0'},
          },
        },
      );

  final StreamController<AppLogLine> _lines =
      StreamController<AppLogLine>.broadcast();
  bool active = false;

  void emit(AppLogLine line) => _lines.add(line);

  @override
  Stream<AppLogLine> get appLogLines => _lines.stream;

  @override
  bool get appLogStreamsActive => active && isConnected;
}

IosAttachResult _iosResult() {
  final announcement = BonjourAnnouncement(
    interfaceIndex: 24,
    host: 'Phone.local.',
    port: 50000,
    authCode: 'auth',
  );
  return IosAttachResult(
    wsUri: 'ws://127.0.0.1:50000/auth=/ws',
    transport: IosTransport.wired,
    announcements: [announcement],
    selected: announcement,
    hostPort: 50000,
    teardown: () async {},
    origin: IosAttachOrigin.probedExisting,
  );
}

/// iOS pipeline that succeeds at once.
class _ScriptedIosAttacher extends IosAttacher {
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
    onProgress?.call(IosAttachPhase.detectingTransport);
    onProgress?.call(IosAttachPhase.attachComplete);
    return _iosResult();
  }
}

/// iOS pipeline that throws [error], which is not an IosAttachException.
class _ThrowingIosAttacher extends IosAttacher {
  _ThrowingIosAttacher(this.error);
  final Object error;

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
  }) async => throw error;
}

/// iOS pipeline that waits until its cancel signal fires, then reports the
/// cancel the way the real pipeline does.
class _WaitForCancelAttacher extends IosAttacher {
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
    if (cancelSignal == null) {
      throw StateError('the session must forward the cancel signal');
    }
    await cancelSignal.first;
    throw IosAttachException(
      IosAttachErrorKind.cancelled,
      'attach cancelled by caller',
    );
  }
}
