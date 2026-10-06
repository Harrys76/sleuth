@TestOn('vm')
library;

import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

class _Run {
  _Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
}

Future<_Run> _check(
  List<String> argv, {
  VmBridge Function()? bridgeFactory,
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await runCheckCommand(
    argv,
    out: out,
    err: err,
    bridgeFactory: bridgeFactory ?? defaultFakeBridge,
  );
  return _Run(code, out.toString(), err.toString());
}

FakeVmBridge _bridgeWithSnapshot({required bool isVmConnected}) =>
    defaultFakeBridge()..setEnvelope(
      'ext.sleuth.snapshot',
      fakeSnapshotEnvelope(isVmConnected: isVmConnected),
    );

/// A bridge whose connect fails the way a dead VM service port does.
class _RefusingBridge extends FakeVmBridge {
  @override
  Future<bool> connect(Uri wsUri) async =>
      throw VmBridgeException('failed to connect: Connection refused');
}

void main() {
  group('usage errors exit 64', () {
    for (final (label, argv, needle) in <(String, List<String>, String)>[
      ('no --uri', <String>[], '--uri'),
      ('empty --uri', ['--uri', ''], '--uri'),
      ('unsupported scheme', ['--uri', 'ftp://127.0.0.1:1/x=/'], '--uri'),
      ('unknown option', ['--uri', 'ws://h:1/x=/ws', '--bogus'], 'bogus'),
      (
        'non-numeric --min-fps',
        ['--uri', 'ws://h:1/x=/ws', '--min-fps', 'fast'],
        '--min-fps',
      ),
      (
        'negative --max-issues',
        ['--uri', 'ws://h:1/x=/ws', '--max-issues', '-1'],
        '--max-issues',
      ),
      (
        'non-integer --max-critical-issues',
        ['--uri', 'ws://h:1/x=/ws', '--max-critical-issues', '1.5'],
        '--max-critical-issues',
      ),
      ('stray positional', ['--uri', 'ws://h:1/x=/ws', 'extra'], 'extra'),
    ]) {
      test(label, () async {
        final run = await _check(argv);
        expect(run.code, checkExitUsage);
        expect(run.code, 64);
        expect(run.err, contains(needle));
        expect(run.err, contains('--min-fps'), reason: 'prints the usage');
      });
    }
  });

  test('--help exits 0 and lists the exit codes', () async {
    final run = await _check(['--help']);
    expect(run.code, checkExitPass);
    expect(run.out, contains('64 on a bad command line'));
  });

  test('a passing budget exits 0', () async {
    final run = await _check([
      '--uri',
      'http://127.0.0.1:5/x=/',
      '--max-critical-issues',
      '5',
    ], bridgeFactory: () => _bridgeWithSnapshot(isVmConnected: true));
    expect(run.code, checkExitPass, reason: run.err);
    expect(run.out, contains('budgets: PASS'));
  });

  test('a violated budget exits 1', () async {
    // The fake snapshot holds one critical issue; the default allows none.
    final run = await _check([
      '--uri',
      'ws://127.0.0.1:5/x=/ws',
      '--json',
    ], bridgeFactory: () => _bridgeWithSnapshot(isVmConnected: true));
    expect(run.code, checkExitViolation, reason: run.err);
    expect(run.out, contains('"passed":false'));
  });

  test(
    'asks only for the sections the budgets read, with no issue cap',
    () async {
      final bridge = defaultFakeBridge()
        ..setResponder(
          'ext.sleuth.snapshot',
          projectingSnapshotResponder(fullFakeSnapshotData()),
        );
      final run = await _check([
        '--uri',
        'ws://127.0.0.1:5/x=/ws',
        '--max-critical-issues',
        '5',
      ], bridgeFactory: () => bridge);
      expect(run.code, checkExitPass, reason: run.err);
      final sent = bridge.callLog
          .lastWhere((c) => c.method == 'ext.sleuth.snapshot')
          .args;
      expect(sent, {'sections': 'currentIssues,frameStatsSummary'});
    },
  );

  test('coverage_degraded exits 2', () async {
    final run = await _check([
      '--uri',
      'ws://127.0.0.1:5/x=/ws',
    ], bridgeFactory: () => _bridgeWithSnapshot(isVmConnected: false));
    expect(run.code, checkExitNotRun);
    expect(run.err, contains('coverage_degraded'));
  });

  test('a connect failure exits 2', () async {
    final run = await _check([
      '--uri',
      'ws://127.0.0.1:5/x=/ws',
    ], bridgeFactory: _RefusingBridge.new);
    expect(run.code, checkExitNotRun);
    expect(run.err, contains('connect failed'));
  });

  test('the sleuth_check binary exits 64 without --uri', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/sleuth_check.dart',
    ], workingDirectory: Directory.current.path);
    expect(result.exitCode, 64, reason: '${result.stderr}');
    expect('${result.stderr}', contains('Missing required option --uri.'));
    expect('${result.stderr}', isNot(contains('ArgumentError')));
  }, timeout: const Timeout(Duration(seconds: 120)));
}
