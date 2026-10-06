import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Starts a child process, like `Process.start` with default options.
typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// Runs a command to completion, like `Process.run`.
typedef CommandRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

Future<Process> _startProcess(String executable, List<String> arguments) =>
    Process.start(executable, arguments);

Future<ProcessResult> _runProcess(String executable, List<String> arguments) =>
    Process.run(executable, arguments);

/// A command did not finish within its time limit. When the command ran as
/// an owned child, the child was killed first.
class CommandTimeoutException extends TimeoutException {
  CommandTimeoutException(this.executable, Duration timeout)
    : super(
        '$executable did not finish within ${timeout.inMilliseconds} ms',
        timeout,
      );

  /// The command that timed out.
  final String executable;
}

/// The caller cancelled a command before it finished. When the command ran
/// as an owned child, the child was killed first.
class CommandCancelledException implements Exception {
  CommandCancelledException(this.executable);

  /// The command that was cancelled.
  final String executable;

  @override
  String toString() => 'CommandCancelledException: $executable was cancelled';
}

/// Ends [process] and, on Windows, every process it started.
///
/// On Windows a process started with `runInShell` is `cmd.exe`, and
/// [Process.kill] ends only that shell, so a child such as flutter's
/// `dart.exe` keeps running and keeps the output pipes open. There this runs
/// `taskkill /PID <pid> /T /F`, which ends the whole tree, and waits for it
/// at most [taskkillTimeout]. When taskkill fails or takes longer, it falls
/// back to [Process.kill]. Elsewhere it sends [signal] to [process].
///
/// [isWindows] replaces the platform check and [runCommand] replaces
/// `Process.run`, so tests can follow the Windows path on any host.
Future<void> killProcessTree(
  Process process, {
  ProcessSignal signal = ProcessSignal.sigterm,
  bool? isWindows,
  CommandRunner? runCommand,
  Duration taskkillTimeout = const Duration(seconds: 2),
}) async {
  if (!(isWindows ?? Platform.isWindows)) {
    process.kill(signal);
    return;
  }
  final run = runCommand ?? _runProcess;
  try {
    final result = await run('taskkill', [
      '/PID',
      '${process.pid}',
      '/T',
      '/F',
    ]).timeout(taskkillTimeout);
    if (result.exitCode == 0) return;
  } catch (_) {
    // taskkill is missing, failed to start, or did not finish in time.
  }
  process.kill(signal);
}

/// Ends [process] with [killProcessTree] and waits for it to exit. When it
/// still runs after [grace], sends SIGKILL and waits at most [killWait]
/// more. Returns whether the process exited. A detached process has no
/// exit code to wait for, so it gets both signals and reports false.
Future<bool> killAndReap(
  Process process, {
  Duration grace = const Duration(seconds: 1),
  Duration killWait = const Duration(milliseconds: 500),
  bool? isWindows,
  CommandRunner? runCommand,
}) async {
  Future<bool> exited;
  try {
    exited = process.exitCode.then<bool>(
      (_) => true,
      onError: (Object _) => true,
    );
  } on StateError {
    exited = Completer<bool>().future;
  }
  await killProcessTree(
    process,
    isWindows: isWindows,
    runCommand: runCommand,
    taskkillTimeout: grace,
  );
  if (await _exitedWithin(exited, grace)) return true;
  process.kill(ProcessSignal.sigkill);
  return _exitedWithin(exited, killWait);
}

Future<bool> _exitedWithin(Future<bool> exited, Duration limit) =>
    exited.timeout(limit, onTimeout: () => false);

/// Waits for [done], at most [limit], and ignores its error. A process that
/// a kill did not reach, for example a grandchild on Windows, can keep an
/// output pipe open, so a wait for output after a kill must be bounded.
Future<void> waitAtMost(Future<Object?> done, Duration limit) => done
    .then<void>((_) {})
    .timeout(limit, onTimeout: () {})
    .catchError((Object _) {});

/// Runs commands and owns each child until it exits. A timeout or a cancel
/// kills the child and waits, bounded, for it to exit, where
/// `Process.run(...).timeout(...)` would only stop waiting and leave the
/// child running.
class OwnedProcessRunner {
  OwnedProcessRunner({
    ProcessStarter? start,
    this.killGrace = const Duration(seconds: 1),
    this.killWait = const Duration(milliseconds: 500),
    this.outputWait = const Duration(seconds: 1),
    this.encoding = systemEncoding,
    bool? isWindows,
    CommandRunner? runCommand,
  }) : _start = start ?? _startProcess,
       _isWindows = isWindows,
       _runCommand = runCommand;

  final ProcessStarter _start;

  /// Replace the platform check and taskkill's runner; see
  /// [killProcessTree].
  final bool? _isWindows;
  final CommandRunner? _runCommand;

  /// Decodes stdout and stderr, like `Process.run`'s encodings.
  final Encoding encoding;

  /// How long a killed child gets to exit before SIGKILL.
  final Duration killGrace;

  /// How long a child gets to exit after SIGKILL.
  final Duration killWait;

  /// How long the runner waits for the output pipes to close once the child
  /// exited or was killed.
  final Duration outputWait;

  /// Runs [executable] with [arguments] and returns its exit code and
  /// output, like `Process.run`. When [timeout] passes first, kills the
  /// child and throws [CommandTimeoutException]. When [cancel] completes
  /// first, kills the child and throws [CommandCancelledException]. A
  /// failure to start throws what `Process.start` throws.
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Duration? timeout,
    Future<void>? cancel,
  }) async {
    final process = await _start(executable, arguments);
    final out = StringBuffer();
    final err = StringBuffer();
    final outputDone = Future.wait<void>([
      process.stdout.transform<String>(encoding.decoder).forEach(out.write),
      process.stderr.transform<String>(encoding.decoder).forEach(err.write),
    ]);
    // A read error ends the output early; the exit code still decides.
    outputDone.ignore();

    final outcome = Completer<Object>();
    void settle(Object value) {
      if (!outcome.isCompleted) outcome.complete(value);
    }

    process.exitCode.then<void>(settle, onError: (Object e) => settle(e));
    final timer = timeout == null
        ? null
        : Timer(
            timeout,
            () => settle(CommandTimeoutException(executable, timeout)),
          );
    cancel?.then<void>(
      (_) => settle(CommandCancelledException(executable)),
      onError: (Object _) => settle(CommandCancelledException(executable)),
    );
    final result = await outcome.future;
    timer?.cancel();
    if (result is int) {
      await waitAtMost(outputDone, outputWait);
      return ProcessResult(process.pid, result, '$out', '$err');
    }
    if (result is CommandTimeoutException ||
        result is CommandCancelledException) {
      await killAndReap(
        process,
        grace: killGrace,
        killWait: killWait,
        isWindows: _isWindows,
        runCommand: _runCommand,
      );
      await waitAtMost(outputDone, outputWait);
    }
    throw result;
  }
}
