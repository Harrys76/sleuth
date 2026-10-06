import 'dart:async';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/util/owned_process.dart' show CommandRunner;
import 'package:test/test.dart';

import '../helpers/fake_flutter_process.dart';
import '../helpers/fake_vm_bridge.dart';
import '../helpers/stubborn_process.dart';

/// Short bounds, so a test that waits out every step still ends quickly.
const _budget = DetachBudget(
  appDetach: Duration(milliseconds: 100),
  childTerm: Duration(milliseconds: 100),
  childKill: Duration(milliseconds: 100),
  bridgeDisconnect: Duration(milliseconds: 100),
  iosTeardown: Duration(milliseconds: 100),
  attachUnwind: Duration(seconds: 2),
);

/// A [DaemonSession] whose children come from [spawn], bound to its own
/// server.
DaemonSession _session(
  VmBridge bridge, {
  required Future<Process> Function(List<String> args) spawn,
  bool hostIsWindows = false,
  CommandRunner? runCommand,
  IosAttacher? iosAttacher,
  McpServer? server,
}) {
  final session = DaemonSession(
    bridge: bridge,
    server: server ?? (McpServer(bridge: bridge)..registerDefaults()),
    processFactory:
        (
          String exe,
          List<String> args, {
          String? workingDirectory,
          Map<String, String>? environment,
        }) => spawn(args),
    hostIsWindows: hostIsWindows,
    runCommand: runCommand,
    iosAttacher: iosAttacher,
    detachBudget: _budget,
  );
  server?.setDaemonSession(session);
  return session;
}

Future<void> _settle([int ms = 20]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Drives [fake] through the daemon handshake up to `app.debugPort`.
Future<void> _driveToDebugPort(FakeFlutterProcess fake) async {
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
    'port': 4242,
    'wsUri': 'ws://127.0.0.1:4242/tok/ws',
  });
}

void main() {
  group('detach while flutter stops reading its stdin', () {
    // An unhandled error fails the test, so this also checks that closing
    // the daemon channel under a pending app.detach write raises none.
    test('ends within its budget and raises no unhandled error', () async {
      final bridge = defaultFakeBridge();
      final fake = FakeFlutterProcess(stallStdin: true);
      final session = _session(bridge, spawn: (_) async => fake);
      final attach = session.attach();
      await _driveToDebugPort(fake);
      expect((await attach).state, 'ready');

      final watch = Stopwatch()..start();
      await session.detach().timeout(const Duration(seconds: 3));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(fake.killed, isTrue);
      expect(session.status.state, 'idle');
      // Room for a late error from the closed channel to surface.
      await _settle(100);
    });
  });

  group('flutter devices check', () {
    test('a timeout returns although the killed child keeps its output '
        'open', () async {
      final devices = StubbornProcess(closesOutputOnExit: false);
      await expectLater(
        DaemonSession.listDevices(
          processFactory:
              (
                _,
                _, {
                String? workingDirectory,
                Map<String, String>? environment,
              }) async => devices,
          timeout: const Duration(milliseconds: 50),
        ).timeout(const Duration(seconds: 5)),
        throwsA(isA<DaemonSessionException>()),
      );
      expect(devices.signals.first, ProcessSignal.sigterm);
    });

    // The Windows path cannot run on this host: this checks only that it
    // is the one chosen, with the arguments that end the whole tree.
    test('on Windows a timeout ends the tree with taskkill', () async {
      final devices = StubbornProcess(pid: 31337);
      final commands = <List<String>>[];
      await expectLater(
        DaemonSession.listDevices(
          processFactory:
              (
                _,
                _, {
                String? workingDirectory,
                Map<String, String>? environment,
              }) async => devices,
          timeout: const Duration(milliseconds: 50),
          isWindows: true,
          runCommand: (exe, args) async {
            commands.add([exe, ...args]);
            devices.kill(ProcessSignal.sigkill);
            return ProcessResult(1, 0, '', '');
          },
        ).timeout(const Duration(seconds: 5)),
        throwsA(isA<DaemonSessionException>()),
      );
      expect(commands, [
        ['taskkill', '/PID', '31337', '/T', '/F'],
      ]);
    });

    test('a detach during the check kills it and ends the attach', () async {
      final bridge = defaultFakeBridge();
      final devices = StubbornProcess();
      final session = _session(
        bridge,
        spawn: (args) async {
          if (args.first == 'devices') return devices;
          throw StateError('flutter attach must not start after a detach');
        },
      );
      final attach = session.attach(device: 'pixel');
      await devices.started;
      expect(session.status.state, 'attaching');

      await session.detach().timeout(const Duration(seconds: 3));
      expect(devices.signals, [ProcessSignal.sigterm]);
      final status = await attach.timeout(const Duration(seconds: 2));
      expect(status.attached, isFalse);
      expect(session.status.state, 'idle');
    });
  });

  group('stopping the flutter child', () {
    // The Windows path cannot run on this host: these check the path
    // selection and its arguments only.
    test('on Windows the detach ends the whole tree with taskkill', () async {
      final bridge = defaultFakeBridge();
      final fake = FakeFlutterProcess(pid: 4040);
      final commands = <List<String>>[];
      final session = _session(
        bridge,
        spawn: (_) async => fake,
        hostIsWindows: true,
        runCommand: (exe, args) async {
          commands.add([exe, ...args]);
          fake.completeExit(1);
          return ProcessResult(1, 0, '', '');
        },
      );
      final attach = session.attach();
      await _driveToDebugPort(fake);
      expect((await attach).state, 'ready');

      await session.detach().timeout(const Duration(seconds: 3));
      expect(commands, [
        ['taskkill', '/PID', '4040', '/T', '/F'],
      ]);
      expect(fake.killed, isFalse, reason: 'taskkill replaced Process.kill');
      expect(session.status.state, 'idle');
    });

    test('elsewhere the detach sends SIGTERM and runs no command', () async {
      final bridge = defaultFakeBridge();
      final fake = FakeFlutterProcess();
      final commands = <List<String>>[];
      final session = _session(
        bridge,
        spawn: (_) async => fake,
        runCommand: (exe, args) async {
          commands.add([exe, ...args]);
          return ProcessResult(1, 0, '', '');
        },
      );
      final attach = session.attach();
      await _driveToDebugPort(fake);
      await attach;

      await session.detach().timeout(const Duration(seconds: 3));
      expect(commands, isEmpty);
      expect(fake.lastSignal, ProcessSignal.sigterm);
    });
  });

  group('a detach during an iOS attach', () {
    test(
      'cancels the pipeline, and the next iOS attach is not refused',
      () async {
        final bridge = defaultFakeBridge();
        final session = _session(
          bridge,
          spawn: (_) async => throw StateError('no flutter child here'),
        );
        final pipeline = _HangUntilCancelledAttacher();
        // No client cancel signal: only the detach can stop this attach.
        final attach = session.attachViaIos(
          udid: 'U',
          bundle: 'b',
          attacher: pipeline,
        );
        final outcome = expectLater(
          attach.timeout(const Duration(seconds: 3)),
          throwsA(
            isA<IosAttachException>().having(
              (e) => e.kind,
              'kind',
              IosAttachErrorKind.cancelled,
            ),
          ),
        );
        await pipeline.running;

        await session.detach().timeout(const Duration(seconds: 3));
        expect(pipeline.cancelled, isTrue);
        await outcome;
        expect(session.status.state, 'idle');

        final again = await session
            .attachViaIos(udid: 'U', bundle: 'b', attacher: _ReadyAttacher())
            .timeout(const Duration(seconds: 3));
        expect(again.state, 'ready');
        await session.detach();
      },
    );

    test('the exit path kills the devicectl child the pipeline started, and '
        'its detach waits for that', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final devicectl = StubbornProcess(exitsOn: const {ProcessSignal.sigkill});
      final started = <List<String>>[];
      final attacher = IosAttacher(
        hasTool: (_) async => true,
        start: (exe, args) async {
          started.add([exe, ...args]);
          return devicectl;
        },
        iproxyStart: (_, _) async => throw StateError('no iproxy expected'),
        bonjourLines: (_, _) => const Stream<String>.empty(),
      );
      final session = _session(
        bridge,
        spawn: (_) async => throw StateError('no flutter child here'),
        iosAttacher: attacher,
        server: server,
      );
      final attach = session.attachViaIos(
        udid: 'U',
        bundle: 'b',
        transportOverride: IosTransport.wired,
      );
      final outcome = expectLater(
        attach.timeout(const Duration(seconds: 5)),
        throwsA(isA<IosAttachException>()),
      );
      await devicectl.started;
      expect(started.single, containsAllInOrder(['xcrun', 'launch']));

      // What shutdown() and the exit path run.
      await server.detachDaemonSession().timeout(const Duration(seconds: 5));
      // The child ignored SIGTERM, so it took SIGKILL, before the detach
      // returned.
      expect(devicectl.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      expect(devicectl.exited, isTrue);
      await outcome;
    });
  });
}

/// iOS pipeline that runs until its cancel signal fires, then reports the
/// cancel the way the real pipeline does. Without a signal it never ends.
class _HangUntilCancelledAttacher extends IosAttacher {
  final Completer<void> _running = Completer<void>();
  bool cancelled = false;

  Future<void> get running => _running.future;

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
    if (!_running.isCompleted) _running.complete();
    if (cancelSignal == null) {
      await Completer<void>().future;
    } else {
      await cancelSignal.first;
    }
    cancelled = true;
    throw IosAttachException(
      IosAttachErrorKind.cancelled,
      'attach cancelled by caller',
    );
  }
}

/// iOS pipeline that succeeds at once.
class _ReadyAttacher extends IosAttacher {
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
}
