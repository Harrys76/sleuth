import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimum `Process` impl for driving `DaemonSession` against scripted
/// daemon NDJSON output and capturing what was written to stdin.
class FakeFlutterProcess implements Process {
  FakeFlutterProcess({this.pid = 9999});

  final _stdoutCtrl = StreamController<List<int>>();
  final _stderrCtrl = StreamController<List<int>>();
  final _stdinSink = _CapturingIOSink();
  final _exitCompleter = Completer<int>();

  @override
  final int pid;

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  IOSink get stdin => _stdinSink;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  bool _killed = false;
  bool get killed => _killed;
  ProcessSignal? lastSignal;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    _killed = true;
    lastSignal = signal;
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(-1);
    }
    return true;
  }

  /// Emit a single NDJSON frame to stdout (newline appended).
  void emit(String frame) {
    _stdoutCtrl.add(utf8.encode('$frame\n'));
  }

  /// Convenience: emit a `[{event, params}]` frame.
  void emitEvent(String event, Map<String, Object?> params) {
    emit(jsonEncode([
      {'event': event, 'params': params},
    ]));
  }

  /// Convenience: emit `[{id, result}]` or `[{id, error}]`.
  void emitRpcResponse(int id, {Object? result, Map<String, Object?>? error}) {
    final m = <String, Object?>{'id': id};
    if (error != null) {
      m['error'] = error;
    } else {
      m['result'] = result;
    }
    emit(jsonEncode([m]));
  }

  void completeExit(int code) {
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(code);
  }

  Future<void> close() async {
    await _stdoutCtrl.close();
    await _stderrCtrl.close();
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(0);
  }

  /// Bytes written to stdin by the unit-under-test (one entry per `add`).
  List<String> get stdinFrames {
    final raw = utf8.decode(_stdinSink._bytes);
    return raw.split('\n').where((s) => s.isNotEmpty).toList(growable: false);
  }
}

class _CapturingIOSink implements IOSink {
  final List<int> _bytes = [];

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => _bytes.addAll(data);
  @override
  void write(Object? obj) => add(utf8.encode(obj.toString()));
  @override
  void writeln([Object? obj = '']) => write('$obj\n');
  @override
  void writeAll(Iterable<dynamic> objs, [String sep = '']) =>
      write(objs.join(sep));
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? st]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done => Future.value();
}
