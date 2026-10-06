import 'dart:async';
import 'dart:io';

import 'package:sleuth_mcp/src/util/owned_process.dart';
import 'package:test/test.dart';

import '../helpers/stubborn_process.dart';

OwnedProcessRunner _runner(
  Process process, {
  bool isWindows = false,
  CommandRunner? runCommand,
}) => OwnedProcessRunner(
  start: (_, _) async => process,
  killGrace: const Duration(milliseconds: 100),
  killWait: const Duration(milliseconds: 100),
  outputWait: const Duration(milliseconds: 100),
  isWindows: isWindows,
  runCommand: runCommand,
);

void main() {
  group('OwnedProcessRunner.run', () {
    test('returns the exit code and output of a child that exits', () async {
      final child = StubbornProcess(exitsOn: const {ProcessSignal.sigterm});
      final run = _runner(child).run('tool', const ['a']);
      await child.started;
      child.emit('out');
      child.kill();
      final result = await run;
      expect(result.exitCode, -ProcessSignal.sigterm.signalNumber);
      expect(result.stdout, 'out');
    });

    test('a timeout kills a child that never exits, then throws', () async {
      final child = StubbornProcess();
      await expectLater(
        _runner(
          child,
        ).run('devicectl', const [], timeout: const Duration(milliseconds: 50)),
        throwsA(isA<CommandTimeoutException>()),
      );
      expect(child.signals, [ProcessSignal.sigterm]);
      expect(child.exited, isTrue);
    });

    test('a cancel kills the child at once, then throws', () async {
      final child = StubbornProcess();
      final cancel = Completer<void>();
      final run = _runner(
        child,
      ).run('devicectl', const [], cancel: cancel.future);
      await child.started;
      final watch = Stopwatch()..start();
      cancel.complete();
      await expectLater(run, throwsA(isA<CommandCancelledException>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(child.signals, [ProcessSignal.sigterm]);
    });

    test('a child that ignores SIGTERM gets SIGKILL, and a child that no '
        'signal ends still lets the call return within its bounds', () async {
      final child = StubbornProcess(exitsOn: const {});
      final watch = Stopwatch()..start();
      await expectLater(
        _runner(
          child,
        ).run('devicectl', const [], timeout: const Duration(milliseconds: 50)),
        throwsA(isA<CommandTimeoutException>()),
      );
      expect(child.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      // 50 ms timeout + 100 ms grace + 100 ms after SIGKILL + 100 ms of
      // output wait, with room for a busy machine.
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('output that a grandchild keeps open is read for a bounded time '
        'only', () async {
      final child = StubbornProcess(closesOutputOnExit: false);
      final run = _runner(child).run('flutter', const ['devices']);
      await child.started;
      child.emit('[]');
      child.kill();
      final result = await run.timeout(const Duration(seconds: 2));
      expect(result.stdout, '[]');
    });
  });

  group('killProcessTree', () {
    test('POSIX sends the signal to the process itself', () async {
      final child = StubbornProcess();
      final commands = <List<String>>[];
      await killProcessTree(
        child,
        isWindows: false,
        runCommand: (exe, args) async {
          commands.add([exe, ...args]);
          return ProcessResult(1, 0, '', '');
        },
      );
      expect(commands, isEmpty);
      expect(child.signals, [ProcessSignal.sigterm]);
    });

    // The Windows path itself cannot run here: these tests only check that
    // it runs taskkill for the whole tree and falls back to Process.kill.
    test('Windows ends the whole tree with taskkill /T /F', () async {
      final child = StubbornProcess(pid: 777);
      final commands = <List<String>>[];
      await killProcessTree(
        child,
        isWindows: true,
        runCommand: (exe, args) async {
          commands.add([exe, ...args]);
          return ProcessResult(1, 0, '', '');
        },
      );
      expect(commands, [
        ['taskkill', '/PID', '777', '/T', '/F'],
      ]);
      expect(child.signals, isEmpty);
    });

    test('Windows falls back to Process.kill when taskkill fails or does not '
        'finish in time', () async {
      final failed = StubbornProcess();
      await killProcessTree(
        failed,
        isWindows: true,
        runCommand: (_, _) async => ProcessResult(1, 1, '', 'no such pid'),
      );
      expect(failed.signals, [ProcessSignal.sigterm]);

      final stalled = StubbornProcess();
      final watch = Stopwatch()..start();
      await killProcessTree(
        stalled,
        isWindows: true,
        runCommand: (_, _) => Completer<ProcessResult>().future,
        taskkillTimeout: const Duration(milliseconds: 50),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(stalled.signals, [ProcessSignal.sigterm]);
    });

    test('the owned runner kills through taskkill on Windows', () async {
      final child = StubbornProcess(pid: 778);
      final commands = <List<String>>[];
      await expectLater(
        _runner(
          child,
          isWindows: true,
          runCommand: (exe, args) async {
            commands.add([exe, ...args]);
            child.kill(ProcessSignal.sigkill);
            return ProcessResult(1, 0, '', '');
          },
        ).run('flutter', const [], timeout: const Duration(milliseconds: 50)),
        throwsA(isA<CommandTimeoutException>()),
      );
      expect(commands, [
        ['taskkill', '/PID', '778', '/T', '/F'],
      ]);
    });
  });

  test('waitAtMost returns once the limit passes and ignores errors', () async {
    final watch = Stopwatch()..start();
    await waitAtMost(
      Completer<void>().future,
      const Duration(milliseconds: 50),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    await waitAtMost(Future<void>.error(StateError('x')), Duration.zero);
  });
}
