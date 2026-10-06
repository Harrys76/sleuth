import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';

/// [DaemonSessionLifecycle] that counts detach calls. [hang] makes detach
/// never finish; [fail] makes it throw.
class CountingSession implements DaemonSessionLifecycle {
  CountingSession({this.hang = false, this.fail = false});

  final bool hang;
  final bool fail;
  int detachCalls = 0;

  @override
  Future<void> detach() {
    detachCalls++;
    if (hang) return Completer<void>().future;
    if (fail) return Future<void>.error(StateError('detach failed'));
    return Future<void>.value();
  }
}

/// [IOSink] that keeps every line written to it.
class LineSink implements IOSink {
  final List<String> lines = [];
  final StringBuffer _partial = StringBuffer();

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? obj) {
    _partial.write(obj);
    final text = _partial.toString();
    final parts = text.split('\n');
    lines.addAll(parts.take(parts.length - 1));
    _partial
      ..clear()
      ..write(parts.last);
  }

  @override
  Future<void> flush() async {}

  @override
  void writeln([Object? obj = '']) => write('$obj\n');

  @override
  void writeAll(Iterable<dynamic> objs, [String sep = '']) =>
      write(objs.join(sep));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void add(List<int> data) => write(utf8.decode(data));

  @override
  void addError(Object error, [StackTrace? st]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}
