import 'dart:async';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

/// Long-lived fake iproxy process: stdout/stderr stay OPEN so the
/// readiness window sees no early exit and the attach proceeds.
class _FakeLiveProcess implements Process {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();

  @override
  int get pid => 4242;
  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(0);
    if (!_stdout.isClosed) _stdout.close();
    if (!_stderr.isClosed) _stderr.close();
    return true;
  }
}

String _reachedAt(int port, int iface) =>
    'svc._dartVmService._tcp.local. can be reached at 127.0.0.1:$port '
    '(interface $iface) Flags: 1';

void main() {
  group('IosAttacher.attach excludePorts', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('sleuth_attach_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test(
        'drops the excluded (dead) announcement and selects the live port — '
        'even though the dead port has the higher interface index', () async {
      // Dead port wins selectUsbAnnouncement's highest-interface-index
      // heuristic (iface 25 vs 24). Only the excludePorts filter can
      // redirect selection to the live port, so asserting the live port
      // was selected proves the filter ran.
      const deadPort = 50001;
      const livePort = 50002;
      final attacher = IosAttacher(
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(1, 0, '', ''),
        iproxyStart: (_, __) async => _FakeLiveProcess(),
        bonjourLines: (bundle, service) async* {
          yield _reachedAt(deadPort, 25);
          yield ' authCode=deadAuth=';
          yield _reachedAt(livePort, 24);
          yield ' authCode=liveAuth=';
        },
      );

      final result = await attacher.attach(
        udid: 'U',
        bundle: 'b',
        transportOverride: IosTransport.wired,
        excludePorts: const {deadPort},
        pidfileDirectory: tmp.path,
        launchSettle: Duration.zero,
        readinessWindow: const Duration(milliseconds: 50),
      );

      expect(result.selected.port, livePort);
      await result.teardown();
    });

    test('exclusion that empties the probe falls through to the launch branch',
        () async {
      const deadPort = 50001;
      const livePort = 50002;
      var launched = false;
      var resolveCall = 0;
      final attacher = IosAttacher(
        hasTool: (_) async => true,
        run: (exec, args) async {
          if (args.contains('launch')) launched = true;
          return ProcessResult(1, 0, '', '');
        },
        iproxyStart: (_, __) async => _FakeLiveProcess(),
        bonjourLines: (bundle, service) async* {
          resolveCall++;
          if (resolveCall == 1) {
            // Probe: only the dead port is announced → excluded → empty.
            yield _reachedAt(deadPort, 25);
            yield ' authCode=deadAuth=';
          } else {
            // Post-launch: the fresh live service is now announced.
            yield _reachedAt(livePort, 24);
            yield ' authCode=liveAuth=';
          }
        },
      );

      final result = await attacher.attach(
        udid: 'U',
        bundle: 'b',
        transportOverride: IosTransport.wired,
        excludePorts: const {deadPort},
        pidfileDirectory: tmp.path,
        launchSettle: Duration.zero,
        readinessWindow: const Duration(milliseconds: 50),
      );

      expect(launched, isTrue,
          reason: 'empty-after-exclusion probe must trigger devicectl launch');
      expect(result.selected.port, livePort);
      await result.teardown();
    });

    test(
        'devicectl launch timeout throws launchFailed (bounds a wedged '
        'devicectl so the attach mutex is released)', () async {
      final attacher = IosAttacher(
        hasTool: (_) async => true,
        // Never completes — models a wedged `xcrun devicectl`.
        run: (_, __) => Completer<ProcessResult>().future,
        iproxyStart: (_, __) async => _FakeLiveProcess(),
        bonjourLines: (bundle, service) async* {
          // Empty probe → launch branch → the hung run() above.
        },
      );

      expect(
        () => attacher.attach(
          udid: 'U',
          bundle: 'b',
          transportOverride: IosTransport.wired,
          pidfileDirectory: tmp.path,
          devicectlTimeout: const Duration(milliseconds: 80),
        ),
        throwsA(isA<IosAttachException>()
            .having((e) => e.kind, 'kind', IosAttachErrorKind.launchFailed)),
      );
    });
  });
}
