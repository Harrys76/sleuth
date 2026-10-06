import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A child process that never exits on its own, like a `devicectl` or a
/// `dns-sd` that stalled. Only a signal in [exitsOn] ends it; an empty set
/// models a process that nothing ends. Records every signal it receives.
class StubbornProcess implements Process {
  StubbornProcess({
    this.pid = 4321,
    Set<ProcessSignal> exitsOn = const {
      ProcessSignal.sigterm,
      ProcessSignal.sigkill,
    },
    this.closesOutputOnExit = true,
  }) : _exitsOn = exitsOn;

  @override
  final int pid;
  final Set<ProcessSignal> _exitsOn;

  /// False models a grandchild that keeps the output pipes open after the
  /// process itself ended.
  final bool closesOutputOnExit;

  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _started = Completer<void>();

  /// Every signal [kill] received, in order.
  final List<ProcessSignal> signals = [];

  /// Completes once the code under test listened to stdout, which every
  /// owned runner does right after it started the process.
  Future<void> get started => _started.future;

  bool get exited => _exit.isCompleted;

  /// Writes [text] to stdout.
  void emit(String text) => _stdout.add(utf8.encode(text));

  @override
  Stream<List<int>> get stdout {
    if (!_started.isCompleted) _started.complete();
    return _stdout.stream;
  }

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => throw UnimplementedError('no stdin');

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (_exitsOn.contains(signal) && !_exit.isCompleted) {
      _exit.complete(-signal.signalNumber);
      if (closesOutputOnExit) {
        unawaited(_stdout.close());
        unawaited(_stderr.close());
      }
    }
    return true;
  }
}
