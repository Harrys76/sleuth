import 'dart:async';
import 'dart:convert';

import 'package:vm_service/vm_service.dart' as vm;

/// Longest line `get_logs` keeps, in characters. Longer lines are cut
/// and marked `truncated`.
const int maxAppLogLineLength = 2000;

/// The output of one app connection.
///
/// The bridge starts an epoch when it connects to an app and ends it when it
/// disconnects or connects to an app at another VM service URI. Each line
/// read on that connection carries the epoch, so a reader can drop the
/// lines of an app the sidecar no longer reads, including lines that were
/// still on their way when the connection changed.
class AppLogEpoch {
  bool _ended = false;

  /// True once the bridge left the connection this epoch belongs to.
  bool get ended => _ended;

  /// Marks the epoch as ended. Lines that carry it are dropped from then on.
  void end() => _ended = true;
}

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
    this.epoch,
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

  /// True when the text is not the whole line or message: the VM service
  /// shortened it and the sidecar could not read the rest, or the sidecar's
  /// per-line cap cut it.
  final bool truncated;

  /// The connection the line was read on. Null for flutter daemon `app.log`
  /// lines, which belong to the attach session instead.
  final AppLogEpoch? epoch;

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
      epoch: epoch,
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

/// The text a [LogMessageResolver] read. `complete` is false when `text` is
/// still only the start of the message, for example because the message is
/// longer than the sidecar asked for.
typedef ResolvedLogMessage = ({String text, bool complete});

/// Reads the full text of a log message the VM service cut short: the
/// string instance [messageId] in isolate [isolateId]. Returns null when
/// the text cannot be read.
typedef LogMessageResolver =
    Future<ResolvedLogMessage?> Function(String isolateId, String messageId);

/// Turns VM service stream events into [AppLogLine]s. Write events can
/// carry part of a line or several lines, so each output stream keeps the
/// unfinished tail until its newline arrives. One decoder serves one VM
/// service connection.
///
/// The VM service cuts a log record's message to its first 128
/// characters. With a [resolveMessage], the decoder reads the whole
/// message before it emits the line. Lines are emitted in the order their
/// events arrived, so a line waiting for its message holds back the lines
/// behind it, for at most [resolveTimeout].
///
/// Each read is a request to the app's isolate. At most
/// [maxConcurrentResolves] run at once; a cut message that arrives while
/// that many are unanswered keeps its 128 characters, marked `truncated`,
/// and costs no request.
class VmLogEventDecoder {
  VmLogEventDecoder(
    this._emit, {
    this.maxPendingLength = 4096,
    this.resolveMessage,
    this.resolveTimeout = const Duration(seconds: 2),
    this.maxConcurrentResolves = 4,
    this.epoch,
  }) : assert(maxConcurrentResolves >= 0);

  final void Function(AppLogLine line) _emit;

  /// Reads a cut log message in full. Null leaves cut messages as they
  /// arrived, marked `truncated`.
  final LogMessageResolver? resolveMessage;

  /// Longest wait for one cut message.
  final Duration resolveTimeout;

  /// Most reads of cut messages that may wait for the app at once. A read
  /// counts until the app answers it or the connection closes, even after
  /// the decoder stopped waiting for it at [resolveTimeout].
  final int maxConcurrentResolves;

  /// The connection every emitted line is tagged with.
  final AppLogEpoch? epoch;

  Future<void> _emitChain = Future<void>.value();
  int _waiting = 0;
  int _resolving = 0;

  /// Reads of cut messages that the app has not answered yet.
  int get resolvesInFlight => _resolving;

  /// Emits [line] after every line queued before it.
  void _emitInOrder(AppLogLine line) {
    if (_waiting == 0) {
      _emit(line);
      return;
    }
    _emitChain = _emitChain.then((_) => _emit(line));
  }

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
      _emitInOrder(
        AppLogLine(time: time, source: source, text: line, epoch: epoch),
      );
      text = text.substring(newline + 1);
    }
    if (text.isEmpty) return;
    if (text.length > maxPendingLength) {
      _emitInOrder(
        AppLogLine(time: time, source: source, text: text, epoch: epoch),
      );
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
    AppLogLine lineWith(String text, {required bool truncated}) => AppLogLine(
      time: _timeOf(
        recordTime != null && recordTime > 0 ? recordTime : event.timestamp,
      ),
      source: 'logging',
      text: text,
      level: record.level != null && record.level! >= 0 ? record.level : null,
      logger: loggerName,
      truncated: truncated,
      epoch: epoch,
    );
    final cut = message?.valueAsStringIsTruncated == true;
    final resolve = resolveMessage;
    final isolateId = event.isolate?.id;
    final messageId = message?.id;
    if (!cut ||
        resolve == null ||
        isolateId == null ||
        messageId == null ||
        _resolving >= maxConcurrentResolves) {
      _emitInOrder(lineWith(text, truncated: cut));
      return;
    }
    _waiting++;
    _resolving++;
    final request = Future<ResolvedLogMessage?>.sync(
      () => resolve(isolateId, messageId),
    );
    unawaited(
      request.then<void>(
        (_) => _resolving--,
        onError: (Object _) => _resolving--,
      ),
    );
    final full = request
        .timeout(resolveTimeout)
        .then<ResolvedLogMessage?>(
          (value) => value,
          onError: (Object _) => null,
        );
    _emitChain = _emitChain.then((_) async {
      final value = await full;
      _waiting--;
      _emit(
        value != null && value.text.length >= text.length
            ? lineWith(value.text, truncated: !value.complete)
            : lineWith(text, truncated: true),
      );
    });
  }

  static DateTime _timeOf(int? millis) => millis != null && millis > 0
      ? DateTime.fromMillisecondsSinceEpoch(millis)
      : DateTime.now();
}
