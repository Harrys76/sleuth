import 'dart:convert';

import 'package:vm_service/vm_service.dart' as vm;

/// One line of app output: a `print` or stderr write, a `dart:developer`
/// log record, or a flutter daemon `app.log` line.
class AppLogLine {
  AppLogLine({
    required this.time,
    required this.source,
    required this.text,
    this.level,
    this.logger,
    this.truncated = false,
  });

  /// When the line was written, from the VM event when it carries a
  /// timestamp, else when the sidecar received it.
  final DateTime time;

  /// Where the line came from: `stdout`, `stderr`, `logging` (the VM
  /// service `Logging` stream) or `daemon` (flutter daemon `app.log`).
  final String source;

  final String text;

  /// `dart:developer` log level (0 to 2000). Set on `logging` lines only.
  final int? level;

  /// `dart:developer` logger name. Set on `logging` lines that name one.
  final String? logger;

  /// True when the text was cut, by the VM service or by the sidecar's
  /// per-line cap.
  final bool truncated;

  /// This line with its text cut to [maxLength] characters.
  AppLogLine capped(int maxLength) {
    if (text.length <= maxLength) return this;
    return AppLogLine(
      time: time,
      source: source,
      text: text.substring(0, maxLength),
      level: level,
      logger: logger,
      truncated: true,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'time': time.toUtc().toIso8601String(),
    'source': source,
    'text': text,
    if (level != null) 'level': level,
    if (logger != null && logger!.isNotEmpty) 'logger': logger,
    if (truncated) 'truncated': true,
  };
}

/// A bridge that forwards the app's output from the VM service `Stdout`,
/// `Stderr` and `Logging` streams.
abstract interface class AppLogSource {
  /// Broadcast stream of app output lines. Lines arrive while the bridge
  /// is connected; each new connection listens to the streams again.
  Stream<AppLogLine> get appLogLines;

  /// True while the bridge is connected and listens to the app's `Stdout`
  /// stream on that connection.
  bool get appLogStreamsActive;
}

/// Turns VM service stream events into [AppLogLine]s. Write events can
/// carry part of a line or several lines, so each output stream keeps the
/// unfinished tail until its newline arrives. One decoder serves one VM
/// service connection.
class VmLogEventDecoder {
  VmLogEventDecoder(this._emit, {this.maxPendingLength = 4096});

  final void Function(AppLogLine line) _emit;

  /// A tail longer than this is emitted as a line of its own, so a writer
  /// that never prints a newline cannot grow the buffer without bound.
  final int maxPendingLength;

  final Map<String, String> _pending = <String, String>{};

  /// Handles a `WriteEvent` from the `Stdout` or `Stderr` stream. [source]
  /// is `stdout` or `stderr`.
  void onWrite(String source, vm.Event event) {
    final bytes = event.bytes;
    if (bytes == null || bytes.isEmpty) return;
    final String chunk;
    try {
      chunk = utf8.decode(base64.decode(bytes), allowMalformed: true);
    } on FormatException {
      return;
    }
    final time = _timeOf(event.timestamp);
    var text = (_pending.remove(source) ?? '') + chunk;
    while (true) {
      final newline = text.indexOf('\n');
      if (newline < 0) break;
      var line = text.substring(0, newline);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      _emit(AppLogLine(time: time, source: source, text: line));
      text = text.substring(newline + 1);
    }
    if (text.isEmpty) return;
    if (text.length > maxPendingLength) {
      _emit(AppLogLine(time: time, source: source, text: text));
      return;
    }
    _pending[source] = text;
  }

  /// Handles a `Logging` event (a `dart:developer` log record).
  void onLogging(vm.Event event) {
    final record = event.logRecord;
    if (record == null) return;
    final message = record.message;
    final text = message?.valueAsString ?? '';
    final loggerName = record.loggerName?.valueAsString;
    final recordTime = record.time;
    _emit(
      AppLogLine(
        time: _timeOf(
          recordTime != null && recordTime > 0 ? recordTime : event.timestamp,
        ),
        source: 'logging',
        text: text,
        level: record.level != null && record.level! >= 0 ? record.level : null,
        logger: loggerName,
        truncated: message?.valueAsStringIsTruncated == true,
      ),
    );
  }

  static DateTime _timeOf(int? millis) => millis != null && millis > 0
      ? DateTime.fromMillisecondsSinceEpoch(millis)
      : DateTime.now();
}
