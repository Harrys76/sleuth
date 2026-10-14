/// Whether the heap measured after idle full collections is growing.
enum HeapFloorState {
  /// Too few fresh points to tell.
  unknown,

  /// The run of collections since the last plateau grows faster than the
  /// threshold.
  growing,

  /// The newest evidence is flat, falling or slower than the threshold.
  notGrowing,
}

/// The floor leg's current verdict. [slopeBytesPerSec] is the regression
/// slope of the run (or the newest pair's slope after a plateau), null
/// while [state] is [HeapFloorState.unknown].
typedef HeapFloorVerdict = ({
  HeapFloorState state,
  double? slopeBytesPerSec,
  int runPoints,
  int runSpanMs,
  int? newestEventMs,
  int? newestBytes,
});

/// Tracks the heap level right after idle full collections.
///
/// A point is a `MarkSweep` or `MarkCompact` the VM ran during idle time:
/// reason `idle`, or one that finishes a concurrent mark started at idle
/// (`StartCMark` with reason `idle`) within [cycleGapMs]. An idle cycle
/// runs after an idle scavenge, so new-space garbage is gone and the
/// point's `new.used + old.used` is close to the live heap.
///
/// Points form a growth run. A point within [coalesceMs] of the newest
/// replaces it (the newest slides forward), unless the newest is the
/// run's only point or has slid more than [minSpanMs] since it joined the
/// run. A busy app can collect every half second for a minute, and
/// without those limits its run would hold one or two sliding points and
/// the verdict would never change. A pair whose slope is at or below half
/// the threshold (a plateau) makes the verdict
/// [HeapFloorState.notGrowing] and restarts the run at that point; a pair
/// closer than [coalesceMs] is too short to judge a slope and never
/// counts as a plateau. A pair that falls more than
/// [dropToleranceBytes] (a drop) also restarts the run but makes the
/// verdict [HeapFloorState.unknown]: on a screen that opens and closes
/// pages, a collection that runs while a page is gone reads lower than
/// the next one, so a drop alone is no evidence that growth stopped. A
/// complete run ([minPoints] points spanning
/// [minSpanMs] within [windowMs]) is [HeapFloorState.growing] when its
/// regression slope is above the threshold, and otherwise
/// [HeapFloorState.notGrowing] with a restarted run. The verdict holds
/// while the newest point is at most [freshnessMs] old, by arrival and by
/// event time.
///
/// Times are epoch milliseconds: event times are the VM's GC event
/// `timestamp`, arrival times come from the caller's clock.
class HeapFloorTracker {
  /// Creates a tracker for growth above [thresholdBytesPerSec].
  HeapFloorTracker({
    required this.thresholdBytesPerSec,
    this.cycleGapMs = 100,
    this.coalesceMs = 1000,
    this.windowMs = 60000,
    this.minPoints = 3,
    this.minSpanMs = 10000,
    this.freshnessMs = 30000,
    this.dropToleranceBytes = 64 * 1024,
  });

  /// Growth rate the run must exceed.
  final int thresholdBytesPerSec;

  /// Longest gap between an idle `StartCMark` and the collection that
  /// finishes it.
  final int cycleGapMs;

  /// A point this close to the newest one replaces it, within the limits
  /// in the class description. A pair this close never counts as a
  /// plateau.
  final int coalesceMs;

  /// Event-time span a run keeps.
  final int windowMs;

  /// Points a run needs before it decides.
  final int minPoints;

  /// Event-time span a run needs before it decides.
  final int minSpanMs;

  /// Age after which the newest point no longer supports a verdict.
  final int freshnessMs;

  /// A pair falling by more than this is a drop.
  final int dropToleranceBytes;

  int? _pendingIdleMarkStartMs;
  final List<({int eventMs, int bytes})> _run = [];
  ({int eventMs, int bytes, int arrivalMs})? _newest;
  HeapFloorState _state = HeapFloorState.unknown;
  double? _slope;
  int _notBeforeMs = 0;
  int _dropCount = 0;
  // Event time at which the newest run point joined the run.
  int _slideStartMs = 0;

  /// Drops seen since construction. [clear] does not reset it, so a
  /// reader can tell whether the heap fell since it last looked.
  int get dropCount => _dropCount;

  static const HeapFloorVerdict _unknown = (
    state: HeapFloorState.unknown,
    slopeBytesPerSec: null,
    runPoints: 0,
    runSpanMs: 0,
    newestEventMs: null,
    newestBytes: null,
  );

  /// The verdict when there is no evidence.
  static HeapFloorVerdict get unknownVerdict => _unknown;

  /// Feeds one GC event. [heapUsedBytes] is `new.used + old.used` after
  /// the collection; [eventMs] is the event's timestamp.
  void addCollection({
    required String? gcType,
    required String? reason,
    required int? heapUsedBytes,
    required int? eventMs,
    required int arrivalMs,
  }) {
    if (gcType == 'StartCMark') {
      _pendingIdleMarkStartMs = reason == 'idle' ? eventMs : null;
      return;
    }
    if (gcType != 'MarkSweep' && gcType != 'MarkCompact') return;
    final opener = _pendingIdleMarkStartMs;
    _pendingIdleMarkStartMs = null;
    if (heapUsedBytes == null || eventMs == null) return;
    final closesIdleMark =
        opener != null && eventMs >= opener && eventMs - opener <= cycleGapMs;
    if (reason != 'idle' && !closesIdleMark) return;
    _addPoint(eventMs, heapUsedBytes, arrivalMs);
  }

  void _addPoint(int eventMs, int bytes, int arrivalMs) {
    if (arrivalMs - eventMs > freshnessMs) return;
    if (eventMs < _notBeforeMs) return;
    final newest = _newest;
    if (newest != null) {
      if (eventMs <= newest.eventMs) return;
      if (arrivalMs - newest.arrivalMs > freshnessMs) {
        _run.clear();
        _state = HeapFloorState.unknown;
        _slope = null;
      }
    }
    _newest = (eventMs: eventMs, bytes: bytes, arrivalMs: arrivalMs);
    if (_run.length >= 2 &&
        eventMs - _run.last.eventMs <= coalesceMs &&
        eventMs - _slideStartMs <= minSpanMs) {
      _run.removeLast();
    } else {
      _slideStartMs = eventMs;
    }
    final point = (eventMs: eventMs, bytes: bytes);
    if (_run.isNotEmpty) {
      final last = _run.last;
      final pairMs = eventMs - last.eventMs;
      final pairSlope = (bytes - last.bytes) * 1000 / pairMs;
      if (bytes < last.bytes - dropToleranceBytes) {
        // A drop: memory was freed between the two collections. It may be
        // a flushed cache or a closed page that the next point brings
        // back, so it starts a new run without claiming the heap stopped
        // growing.
        _dropCount++;
        _state = HeapFloorState.unknown;
        _slope = null;
        _run
          ..clear()
          ..add(point);
        return;
      }
      if (pairMs > coalesceMs && pairSlope <= thresholdBytesPerSec / 2) {
        // A plateau: the heap held still between two collections.
        _state = HeapFloorState.notGrowing;
        _slope = pairSlope;
        _run
          ..clear()
          ..add(point);
        return;
      }
    }
    _run
      ..add(point)
      ..removeWhere((p) => p.eventMs < eventMs - windowMs);
    if (_run.length >= minPoints &&
        _run.last.eventMs - _run.first.eventMs >= minSpanMs) {
      final slope = _regressionSlope();
      _slope = slope;
      if (slope > thresholdBytesPerSec) {
        _state = HeapFloorState.growing;
      } else {
        _state = HeapFloorState.notGrowing;
        _run
          ..clear()
          ..add(point);
      }
    }
  }

  double _regressionSlope() {
    final n = _run.length;
    final t0 = _run.first.eventMs;
    var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumX2 = 0.0;
    for (final p in _run) {
      final x = (p.eventMs - t0) / 1000.0;
      final y = p.bytes.toDouble();
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
    }
    final denominator = n * sumX2 - sumX * sumX;
    if (denominator.abs() < 1e-10) return 0;
    return (n * sumXY - sumX * sumY) / denominator;
  }

  /// The verdict at [nowMs] on the caller's clock.
  HeapFloorVerdict verdict(int nowMs) {
    final newest = _newest;
    if (newest == null ||
        nowMs - newest.arrivalMs > freshnessMs ||
        nowMs - newest.eventMs > freshnessMs) {
      return _unknown;
    }
    return (
      state: _state,
      slopeBytesPerSec: _state == HeapFloorState.unknown ? null : _slope,
      runPoints: _run.length,
      runSpanMs: _run.isEmpty ? 0 : _run.last.eventMs - _run.first.eventMs,
      newestEventMs: newest.eventMs,
      newestBytes: newest.bytes,
    );
  }

  /// Forgets every point and ignores events before [notBeforeMs].
  void clear({required int notBeforeMs}) {
    _pendingIdleMarkStartMs = null;
    _run.clear();
    _newest = null;
    _state = HeapFloorState.unknown;
    _slope = null;
    _notBeforeMs = notBeforeMs;
  }
}
