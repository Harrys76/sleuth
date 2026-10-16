import 'dart:async' show scheduleMicrotask;
import 'dart:developer' show Timeline;

/// Recent intervals in which Sleuth itself kept the UI isolate busy, in
/// `Timeline.now` microseconds.
///
/// A frame whose build starts late because Sleuth was scanning the tree or
/// decoding a VM response is late because of Sleuth, not the app.
/// `FrameTimingDetector` subtracts the part of each frame's start delay
/// that these intervals cover. `FrameTiming` timestamps and `Timeline.now`
/// share the monotonic clock (the frame/timeline correlator already relies
/// on it).
///
/// Spans are synchronous, with two exceptions. A span around an `await`
/// would also cover whatever the app ran while Sleuth waited, and that
/// time would be taken off the app's own jank. The exceptions are VM
/// requests during which the VM itself holds the UI thread, which no Dart
/// timer can see: the poll's timeline request (the VM's timeline lock) and
/// a `getCpuSamples` request (the profile is built on the UI isolate).
/// [open] and [close] log them, and a cap bounds each one.
///
/// The log keeps spans by time, not by count. It keeps every span that
/// ended within [retainUs] of the newest span, at most [maxSpans]. A burst
/// of VM messages (each one's decode is a span) cannot push out the span
/// that delayed a frame or a timer before that frame's timings or that
/// timer's event arrive.
class OwnWorkLog {
  /// Creates a log that keeps spans ending within [retainUs] of the newest
  /// span, at most [maxSpans] of them.
  OwnWorkLog({this.retainUs = 10000000, this.maxSpans = 4096})
    : assert(retainUs > 0 && maxSpans > 0);

  /// How long a span is kept after the newest span's end, in
  /// microseconds. Frame timings reach the detector within a second and
  /// timer events within milliseconds; 10 s also covers long stalls.
  final int retainUs;

  /// Most spans kept; the oldest go first.
  final int maxSpans;

  final List<_Span> _spans = [];

  /// First live index in [_spans]; earlier entries were pruned.
  int _head = 0;
  int _nextId = 0;
  int _newestEndUs = 0;

  /// Current `Timeline.now` reading.
  static int now() => Timeline.now;

  /// Records the interval [startUs] to [endUs]. Ignores empty and
  /// inverted intervals.
  void record(int startUs, int endUs) {
    if (endUs <= startUs) return;
    _add(startUs, endUs);
  }

  /// Records [startUs] to [startUs] + [capUs] at once, so frames read
  /// before the span ends see it, and returns a handle for [close], or
  /// null when [capUs] is not positive.
  int? open(int startUs, int capUs) {
    if (capUs <= 0) return null;
    return _add(startUs, startUs + capUs);
  }

  /// Ends the span [handle] from [open] at [endUs] when that is before its
  /// cap. Does nothing once the span has been pruned.
  void close(int handle, int endUs) {
    for (var i = _spans.length - 1; i >= _head; i--) {
      final span = _spans[i];
      if (span.id != handle) continue;
      if (endUs < span.end) span.end = endUs > span.start ? endUs : span.start;
      return;
    }
  }

  int _add(int startUs, int endUs) {
    final id = _nextId++;
    _spans.add(_Span(id, startUs, endUs));
    if (endUs > _newestEndUs) _newestEndUs = endUs;
    _prune();
    return id;
  }

  void _prune() {
    final cutoff = _newestEndUs - retainUs;
    while (_head < _spans.length &&
        (_spans[_head].end < cutoff || _spans.length - _head > maxSpans)) {
      _head++;
    }
    if (_head > 1024 && _head * 2 > _spans.length) {
      _spans.removeRange(0, _head);
      _head = 0;
    }
  }

  /// Runs the synchronous [body] and records the time it took.
  T measure<T>(T Function() body) {
    final start = now();
    try {
      return body();
    } finally {
      record(start, now());
    }
  }

  /// Records from now until the microtask queue next runs: the rest of the
  /// current synchronous event. A synchronous `onReceive` listener calls
  /// this before `package:vm_service` decodes the message, so the span
  /// ends after the decode and before any awaited continuation runs.
  void recordUntilMicrotask() {
    final start = now();
    scheduleMicrotask(() => record(start, now()));
  }

  /// Microseconds of [fromUs] to [toUs] that logged intervals cover,
  /// counting overlapping intervals once.
  int overlapUs(int fromUs, int toUs) {
    if (toUs <= fromUs || _head >= _spans.length) return 0;
    final clipped = <(int, int)>[];
    for (var i = _head; i < _spans.length; i++) {
      final span = _spans[i];
      final start = span.start > fromUs ? span.start : fromUs;
      final end = span.end < toUs ? span.end : toUs;
      if (end > start) clipped.add((start, end));
    }
    if (clipped.isEmpty) return 0;
    clipped.sort((a, b) => a.$1.compareTo(b.$1));
    var covered = 0;
    var (runStart, runEnd) = clipped.first;
    for (final (start, end) in clipped.skip(1)) {
      if (start > runEnd) {
        covered += runEnd - runStart;
        runStart = start;
        runEnd = end;
      } else if (end > runEnd) {
        runEnd = end;
      }
    }
    return covered + (runEnd - runStart);
  }

  /// Forgets every interval.
  void clear() {
    _spans.clear();
    _head = 0;
    _newestEndUs = 0;
  }
}

class _Span {
  _Span(this.id, this.start, this.end);
  final int id;
  final int start;
  int end;
}

/// The log shared by the controller, the VM client and the frame detector.
final ownWorkLog = OwnWorkLog();
