import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/issue_measurement.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Stats of one evaluated window, which is the busiest 1 s span of event
/// time.
/// Durations are in microseconds and cover the completed calls that began
/// in that span.
typedef PlatformChannelWindowStats = ({
  int callCount,
  int maxCallDurationUs,
  int p95CallDurationUs,
  int callsOverThreshold,
});

/// Detects excessive platform channel calls.
///
/// **VM-Only Detector** — monitors platform channel timeline events for >20 calls/sec.
/// Requires the framework's `debugProfilePlatformChannels` flag; without
/// it the timeline carries no platform-channel events. Opt in with
/// `SleuthConfig(profilePlatformChannels: true)`, which sets the flag
/// once the VM connects.
///
/// **Counting.** Every second of wall time the detector checks the calls
/// received so far. The count is the largest number of call begins whose
/// event times fall in one half-open 1 s span `[t, t + 1 s)` that holds at
/// least one call received since the previous check. Counting by event
/// time keeps the rate independent of how VM polls batch the events
/// (500 ms polls put two or three batches in one wall-clock second). A
/// burst whose events arrive in two polls reads partial at one check and
/// complete at the next, so it can escalate from warning to critical.
/// After each check the detector keeps the calls of the last 10 s of event
/// time, so a check sees the whole of a poll that covers several seconds,
/// and a call that arrives late counts with the calls around it. It keeps
/// at most [maxRetainedCalls] begins; above about 400 calls/s the oldest
/// go first. When one poll brings more than that, the detector notes the
/// busiest unchecked span among the begins it drops, and the next check
/// reports that span if no kept span is busier.
///
/// **Repeats and late calls.** A reconnect makes the VM client read its
/// whole timeline buffer again, so the detector skips calls it has already
/// seen: a held call by its identity, a begin the count cap dropped by the
/// latest dropped begin time on its thread, and anything more than 10 s
/// behind the newest begin at the last check by its time. That last rule
/// also skips a call that arrives more than 10 s late.
///
/// **Retention.** Windows are 1 s long. After an emission the issue is
/// re-added for 3 cooldown windows (same identity, so a sustained overload
/// records one trace event), then stays in [issues] until
/// [emissionPersistence] has passed since the emission, so a short burst
/// remains visible long enough to read. Another overload after the
/// cooldown emits a fresh issue with a new identity. A call that arrives
/// late inside a span already reported at its severity or higher still
/// counts, but it cannot make a span emit again; other new calls in the
/// same check still can.
class PlatformChannelDetector extends BaseDetector
    with DetectorMetadataProvider {
  PlatformChannelDetector({
    this.callsPerSecThreshold = 20,
    this.durationThresholdUs = 8000,
    this.emissionPersistence = const Duration(seconds: 10),
    DateTime Function()? clock,
    String? Function()? sourceRouteProvider,
    InteractionContext Function()? interactionContextProvider,
  }) : _clock = clock ?? DateTime.now,
       _sourceRouteProvider = sourceRouteProvider ?? (() => null),
       _interactionContextProvider = interactionContextProvider,
       super(
         type: DetectorType.platformChannel,
         lifecycle: DetectorLifecycle.vmOnly,
         name: 'Platform Channel',
         description:
             'Detects excessive platform channel calls (more than '
             '20/sec). Opt in with '
             'SleuthConfig(profilePlatformChannels: true)',
       ) {
    _windowStart = _clock();
  }

  final int callsPerSecThreshold;

  /// Slow-call annotation threshold (microseconds). Default 8 ms. Calls
  /// longer than this are counted in `callsOverThreshold`; it never
  /// triggers an issue on its own.
  final int durationThresholdUs;

  /// How long an emitted issue stays in [issues], measured from the
  /// emission with the injected clock. Applies once the 3-window cooldown
  /// has drained; it never re-emits or changes the identity.
  final Duration emissionPersistence;

  final DateTime Function() _clock;
  final String? Function() _sourceRouteProvider;

  /// A window with more than this many times [callsPerSecThreshold]
  /// calls is critical.
  static const int criticalMultiplier = 2;

  /// The most call begins kept for span counting.
  static const int maxRetainedCalls = 4096;

  /// How far behind the newest call begin, in event time, calls are kept,
  /// and how late a call can arrive and still count.
  static const int _retainUs = 10000000;

  /// The most threads whose dropped-begin marks are kept.
  static const int _maxThreadMarks = 256;

  static const int _spanUs = 1000000;

  /// Reads the controller's interaction state at emission so a
  /// cooldown-retained issue keeps the context it fired in.
  final InteractionContext Function()? _interactionContextProvider;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  int _recentCallCount = 0;
  final List<int> _callDurationsUs = [];
  late DateTime _windowStart;

  // Call begins sorted by event time, and completed calls in arrival
  // order, both kept for [_retainUs] of event time behind the newest begin.
  final List<_ChannelBegin> _begins = [];
  final List<PlatformChannelCall> _calls = [];
  // Identities of the held begins and calls. A reconnect resets the VM
  // client's timeline cursors (whether or not a disconnect was reported),
  // so its first poll repeats events this detector already holds; the
  // detector skips those.
  final Set<String> _beginKeys = {};
  final Set<String> _callKeys = {};
  // For each thread, the latest begin time among the begins the count cap
  // dropped. A repeat of one is at or below its thread's mark and is
  // skipped, while a begin from another thread that arrives late is not.
  // Begins that age out by time fall below [_floorUs] instead.
  final Map<int, int> _droppedUpToByTid = {};
  // The detector skips begins and calls before this event time, which is
  // [_retainUs] behind the newest begin at the last check, and forgets
  // thread marks below it.
  int? _floorUs;
  int _arrivalSeq = 0;
  // Begins with a sequence number at or above this arrived since the last
  // window check.
  int _checkSeq = 0;
  // The busiest span, and the busiest span that may emit, among begins the
  // count cap evicted before a check saw them. The next check uses them
  // when they beat the live spans. Each keeps the call durations held at
  // the eviction, which the check merges by call key with the calls held
  // by then.
  _SpanStats? _evictedBusiest;
  _SpanStats? _evictedEmitting;
  // Event-time ranges `[start, end)` covered by the spans of fresh
  // emissions: all of them, and the critical ones. Overlapping ranges are
  // merged and ranges that leave retention are dropped. Every span starts
  // at a held begin and lasts 1 s, so each list holds at most about a
  // dozen ranges.
  final List<(int, int)> _reportedRanges = [];
  final List<(int, int)> _criticalRanges = [];
  int? _newestBeginUs;
  // [reset] sets this to the newest begin seen, and the detector drops
  // later begins at or before it, so a retained-buffer replay from before
  // a capture scenario cannot count in the scenario.
  int? _horizonUs;
  int _cooldownCyclesRemaining = 0;
  PerformanceIssue? _lastEmittedIssue;
  DateTime? _lastEmittedAt;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    final now = _clock();
    final windowDuration = now.difference(_windowStart);

    // Check once per second of wall time, before adding this batch.
    if (windowDuration.inMilliseconds >= 1000) {
      _evaluateWindow();
      _recentCallCount = 0;
      _callDurationsUs.clear();
      _checkSeq = _arrivalSeq;
      _windowStart = now;
      // Age out only after a check, so the check sees a batch that spans
      // more than 10 s of event time (a delayed poll) before its early
      // calls go.
      _prune(byTime: true);
    }

    // The VM returns events grouped by thread block, not in time order, so
    // this appends the batch and sorts once if it reached back before the
    // tail.
    final tailUs = _begins.isEmpty ? null : _begins.last.ts;
    var outOfOrder = false;
    var previousUs = tailUs;
    for (final event in data.platformChannelEvents) {
      final json = event.json;
      final ts = json?['ts'];
      // A begin without a timestamp has no place in a span.
      if (ts is! int) continue;
      final rawTid = json!['tid'];
      final tid = rawTid is int ? rawTid : 0;
      if (_skipped(ts) || _droppedBefore(ts, tid)) continue;
      final name = json['name'] as String?;
      final key = '$ts|$tid|${json['ph']}|${json['id'] ?? ''}|$name';
      if (!_beginKeys.add(key)) continue;
      final method =
          (json['args'] as Map<String, dynamic>?)?['method'] as String? ??
          name ??
          'unknown';
      if (previousUs != null && ts < previousUs) outOfOrder = true;
      previousUs = ts;
      _begins.add(_ChannelBegin(ts, tid, method, _arrivalSeq++, key));
      final newest = _newestBeginUs;
      if (newest == null || ts > newest) _newestBeginUs = ts;
      _recentCallCount++;
    }
    if (outOfOrder) _begins.sort((a, b) => a.ts.compareTo(b.ts));
    for (final call in data.platformChannelCalls) {
      // A call is not checked against the thread marks: the begin of an
      // async call the cap dropped can still end, and its duration counts.
      if (_skipped(call.beginTs)) continue;
      if (!_callKeys.add(_callKey(call))) continue;
      _callDurationsUs.add(call.durationUs);
      _calls.add(call);
    }
    _prune(byTime: false);
  }

  /// Whether an event at [ts] is before the scenario boundary or too late.
  bool _skipped(int ts) {
    final horizon = _horizonUs;
    if (horizon != null && ts <= horizon) return true;
    final floor = _floorUs;
    return floor != null && ts < floor;
  }

  /// Whether a begin at [ts] on thread [tid] repeats one the count cap
  /// dropped.
  bool _droppedBefore(int ts, int tid) {
    final droppedUpTo = _droppedUpToByTid[tid];
    return droppedUpTo != null && ts <= droppedUpTo;
  }

  static String _callKey(PlatformChannelCall call) =>
      '${call.beginTs}|${call.tid ?? 0}|${call.id ?? ''}|${call.name}';

  void _markDropped(int tid, int ts) {
    final droppedUpTo = _droppedUpToByTid[tid];
    if (droppedUpTo == null || ts > droppedUpTo) _droppedUpToByTid[tid] = ts;
  }

  void _raiseFloor(int us) {
    final floor = _floorUs;
    if (floor != null && us <= floor) return;
    _floorUs = us;
    _droppedUpToByTid.removeWhere((_, ts) => ts < us);
  }

  /// Keeps at most [maxRetainedCalls] begins and calls and, with [byTime],
  /// drops those more than 10 s of event time behind the newest begin.
  void _prune({required bool byTime}) {
    if (_begins.length > maxRetainedCalls) {
      final evicted = _begins.length - maxRetainedCalls;
      // A check may not have seen these begins yet, so the busiest
      // unchecked span that starts among them is kept for the next check.
      _keepEvictedPeak(evicted);
      _dropBegins(evicted);
    }
    if (_calls.length > maxRetainedCalls) {
      final evicted = _calls.length - maxRetainedCalls;
      for (final call in _calls.take(evicted)) {
        _callKeys.remove(_callKey(call));
      }
      _calls.removeRange(0, evicted);
    }
    final newest = _newestBeginUs;
    if (byTime && newest != null) {
      final cutoff = newest - _retainUs;
      var drop = 0;
      while (drop < _begins.length && _begins[drop].ts < cutoff) {
        drop++;
      }
      _dropBegins(drop);
      _calls.removeWhere((c) {
        final old = c.beginTs < cutoff;
        if (old) _callKeys.remove(_callKey(c));
        return old;
      });
      _raiseFloor(cutoff);
      _reportedRanges.removeWhere((r) => r.$2 <= cutoff);
      _criticalRanges.removeWhere((r) => r.$2 <= cutoff);
    }
    if (_droppedUpToByTid.length > _maxThreadMarks) {
      // Raise the floor to the oldest mark kept, which forgets the older
      // marks and still skips repeats of their begins. Late calls before
      // the new floor are skipped too.
      final marks = _droppedUpToByTid.values.toList()..sort();
      _raiseFloor(marks[marks.length - _maxThreadMarks]);
    }
  }

  void _dropBegins(int count) {
    if (count <= 0) return;
    for (final begin in _begins.take(count)) {
      _beginKeys.remove(begin.key);
      _markDropped(begin.tid, begin.ts);
    }
    _begins.removeRange(0, count);
  }

  /// Drops the held calls and ignores later begins at or before the newest
  /// one seen, or at or before [horizonUs] when that is later. The horizon
  /// only moves forward.
  void _dropRetained({int? horizonUs}) {
    for (final candidate in [_newestBeginUs, horizonUs]) {
      final horizon = _horizonUs;
      if (candidate != null && (horizon == null || candidate > horizon)) {
        _horizonUs = candidate;
      }
    }
    _begins.clear();
    _calls.clear();
    _beginKeys.clear();
    _callKeys.clear();
    _recentCallCount = 0;
    _callDurationsUs.clear();
    _checkSeq = _arrivalSeq;
    _evictedBusiest = null;
    _evictedEmitting = null;
  }

  /// Half-open 1 s spans of event time that hold at least one begin
  /// received since the last check, as `(first, last)` indexes into
  /// [_begins]. `busiest` is the one with the most begins. `emitting` is
  /// the busiest one over [callsPerSecThreshold] that holds a new begin
  /// outside every span already reported at its severity or higher, so
  /// late calls that only rejoin a reported overload cannot emit it again.
  /// Both are null when no begin arrived since the last check. With
  /// [startBefore], only spans whose first begin has an index below it
  /// count.
  ({(int, int)? busiest, (int, int)? emitting}) _bestSpans({int? startBefore}) {
    final n = _begins.length;
    // Counts over the first i begins: the begins received since the last
    // check, and those of them outside every reported span (fresh for a
    // warning) and outside every critical reported span (fresh for a
    // critical).
    final newBefore = List<int>.filled(n + 1, 0);
    final freshForWarning = List<int>.filled(n + 1, 0);
    final freshForCritical = List<int>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      final begin = _begins[i];
      final isNew = begin.seq >= _checkSeq;
      var inReported = false;
      var inCritical = false;
      if (isNew) {
        inReported = _covers(_reportedRanges, begin.ts);
        inCritical = inReported && _covers(_criticalRanges, begin.ts);
      }
      newBefore[i + 1] = newBefore[i] + (isNew ? 1 : 0);
      freshForWarning[i + 1] =
          freshForWarning[i] + (isNew && !inReported ? 1 : 0);
      freshForCritical[i + 1] =
          freshForCritical[i] + (isNew && !inCritical ? 1 : 0);
    }
    if (newBefore[n] == 0) return (busiest: null, emitting: null);
    (int, int)? busiest;
    (int, int)? emitting;
    var right = 0;
    final leftEnd = startBefore ?? n;
    for (var left = 0; left < leftEnd; left++) {
      if (right < left) right = left;
      while (right + 1 < n &&
          _begins[right + 1].ts < _begins[left].ts + _spanUs) {
        right++;
      }
      if (newBefore[right + 1] - newBefore[left] == 0) continue;
      final count = right - left + 1;
      if (busiest == null || count > busiest.$2 - busiest.$1 + 1) {
        busiest = (left, right);
      }
      if (count <= callsPerSecThreshold) continue;
      final fresh = count > callsPerSecThreshold * criticalMultiplier
          ? freshForCritical
          : freshForWarning;
      if (fresh[right + 1] - fresh[left] > 0 &&
          (emitting == null || count > emitting.$2 - emitting.$1 + 1)) {
        emitting = (left, right);
      }
    }
    return (busiest: busiest, emitting: emitting);
  }

  /// Longest call completed since the last window check (µs); 0 when
  /// none.
  int get maxCallDurationUs => _callDurationsUs.isEmpty
      ? 0
      : _callDurationsUs.reduce((a, b) => a > b ? a : b);

  /// Nearest-rank 95th-percentile duration of the calls completed since
  /// the last window check (µs); 0 when none completed.
  int get p95CallDurationUs => _p95(_callDurationsUs);

  /// Calls completed since the last window check that ran longer than
  /// [durationThresholdUs].
  int get callsOverThreshold =>
      _callDurationsUs.where((d) => d > durationThresholdUs).length;

  static int _p95(List<int> durationsUs) {
    if (durationsUs.isEmpty) return 0;
    final sorted = [...durationsUs]..sort();
    final rank = (sorted.length * 95 + 99) ~/ 100;
    return sorted[rank - 1];
  }

  /// Count of call begins received since the last window check.
  int get windowCallCount => _recentCallCount;

  /// Number of threads with a dropped-begin mark.
  @visibleForTesting
  int get threadMarkCount => _droppedUpToByTid.length;

  /// Stats of the most recently evaluated 1 s window; null before the
  /// first evaluation and after [reset].
  PlatformChannelWindowStats? get lastWindowStats => _lastWindowStats;
  PlatformChannelWindowStats? _lastWindowStats;

  static String _ms(int us) =>
      us % 1000 == 0 ? '${us ~/ 1000}' : (us / 1000).toStringAsFixed(1);

  /// The start, count and method counts of the span from index `first` to
  /// index `last` of [_begins], with [heldDurations] as the durations kept
  /// from an eviction.
  _SpanStats _spanStats(
    (int, int) span, {
    Map<String, int> heldDurations = const {},
  }) {
    final (first, last) = span;
    final methodCounts = <String, int>{};
    for (var i = first; i <= last; i++) {
      final method = _begins[i].method;
      methodCounts[method] = (methodCounts[method] ?? 0) + 1;
    }
    final startUs = _begins[first].ts;
    return (
      startUs: startUs,
      count: last - first + 1,
      methodCounts: methodCounts,
      heldDurations: heldDurations,
    );
  }

  static bool _covers(List<(int, int)> ranges, int ts) =>
      ranges.any((r) => ts >= r.$1 && ts < r.$2);

  /// Adds the 1 s span from [startUs] to [ranges], which stay sorted and
  /// disjoint: every range the span overlaps or touches merges into it.
  static void _cover(List<(int, int)> ranges, int startUs) {
    var start = startUs;
    var end = startUs + _spanUs;
    ranges.removeWhere((r) {
      if (r.$1 > end || r.$2 < start) return false;
      if (r.$1 < start) start = r.$1;
      if (r.$2 > end) end = r.$2;
      return true;
    });
    ranges
      ..add((start, end))
      ..sort((a, b) => a.$1.compareTo(b.$1));
  }

  /// The one of [a] and [b] with more begins; [a] on a tie.
  static _SpanStats? _busier(_SpanStats? a, _SpanStats? b) =>
      b != null && (a == null || b.count > a.count) ? b : a;

  /// The durations of the held calls that began in the 1 s span from
  /// [startUs], by call key.
  Map<String, int> _durationsByCall(int startUs) => {
    for (final call in _calls)
      if (call.beginTs >= startUs && call.beginTs < startUs + _spanUs)
        _callKey(call): call.durationUs,
  };

  void _keepEvictedPeak(int evicted) {
    final spans = _bestSpans(startBefore: evicted);
    _SpanStats? snapshot((int, int)? span, _SpanStats? kept) {
      if (span == null) return kept;
      final count = span.$2 - span.$1 + 1;
      if (kept != null && count <= kept.count) return kept;
      return _spanStats(
        span,
        heldDurations: _durationsByCall(_begins[span.$1].ts),
      );
    }

    _evictedBusiest = snapshot(spans.busiest, _evictedBusiest);
    _evictedEmitting = snapshot(spans.emitting, _evictedEmitting);
  }

  void _evaluateWindow() {
    // Every number the issue shows comes from one span, so the title, the
    // method counts, the durations and the trace args describe the same
    // calls.
    // The issue describes the busiest span that may emit; without one, the
    // stats describe the busiest span.
    final live = _bestSpans();
    final emitting = _busier(
      live.emitting == null ? null : _spanStats(live.emitting!),
      _evictedEmitting,
    );
    final stats =
        emitting ??
        _busier(
          live.busiest == null ? null : _spanStats(live.busiest!),
          _evictedBusiest,
        );
    _evictedBusiest = null;
    _evictedEmitting = null;
    final count = stats?.count ?? 0;
    final methodCounts = stats?.methodCounts ?? const <String, int>{};
    final durationsUs = stats == null
        ? const <int>[]
        : {
            ...stats.heldDurations,
            ..._durationsByCall(stats.startUs),
          }.values.toList();
    final maxUs = durationsUs.isEmpty
        ? 0
        : durationsUs.reduce((a, b) => a > b ? a : b);
    _lastWindowStats = (
      callCount: count,
      maxCallDurationUs: maxUs,
      p95CallDurationUs: _p95(durationsUs),
      callsOverThreshold: durationsUs
          .where((d) => d > durationThresholdUs)
          .length,
    );
    // Emission is count-only; call durations annotate the issue.
    if (emitting != null) {
      final wouldBeCritical = count > callsPerSecThreshold * criticalMultiplier;
      // Cooldown semantics: suppress fresh emissions during the
      // 3-cycle drain after a fire so sustained overload collapses
      // to a single trace record per cooldown window (composite-key
      // dedup at the controller relies on the retained issue's
      // original `dedupIdentityMicros`). Capture-mode scenario
      // brackets need this — a multi-second overload would otherwise
      // emit one trace record per detector cycle and inflate the
      // audit-gate's per-scenario count.
      //
      // Severity-mismatch exception: if the current window's severity
      // differs from the retained issue's severity (warning ↔ critical
      // in either direction), emit a fresh issue with a new dedup
      // identity. Live monitoring then surfaces both escalations
      // (warning → critical) and de-escalations (critical → warning)
      // in real time instead of holding stale severity UI for up to
      // 3 cycles. Same-severity sustained overloads stay suppressed.
      if (_cooldownCyclesRemaining > 0) {
        final retainedSeverity = _lastEmittedIssue?.severity;
        final currentSeverity = wouldBeCritical
            ? IssueSeverity.critical
            : IssueSeverity.warning;
        if (retainedSeverity == currentSeverity) {
          _cooldownCyclesRemaining--;
          _issues.clear();
          if (_lastEmittedIssue != null) _issues.add(_lastEmittedIssue!);
          return;
        }
        // Severity changed — fall through to emit a fresh issue with
        // a new identity. Cooldown is reset to 3 below.
      }
      _cooldownCyclesRemaining = 3;
      _lastEmittedAt = _clock();
      _cover(_reportedRanges, emitting.startUs);
      if (wouldBeCritical) _cover(_criticalRanges, emitting.startUs);
      final maxUs = _lastWindowStats!.maxCallDurationUs;
      final p95Us = _lastWindowStats!.p95CallDurationUs;
      final overCount = _lastWindowStats!.callsOverThreshold;
      final timing = durationsUs.isEmpty
          ? 'no call durations observed'
          : 'max call ${_ms(maxUs)} ms, p95 ${_ms(p95Us)} ms, '
                '$overCount ${overCount == 1 ? 'call' : 'calls'} over '
                '${_ms(durationThresholdUs)} ms';
      final topMethods = methodCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final methodSummary = topMethods
          .take(3)
          .map((e) => '${e.key}: ${e.value} ${e.value == 1 ? 'call' : 'calls'}')
          .join(', ');

      final topMethod = topMethods.isNotEmpty ? topMethods.first.key : null;
      final (hint, effort) = FixHintBuilder.platformChannelTraffic(
        topMethod: topMethod,
      );
      _lastEmittedIssue = PerformanceIssue(
        stableId: 'platform_channel_traffic',
        severity: wouldBeCritical
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.channel,
        confidence: IssueConfidence.confirmed,
        title: 'High Platform Channel Traffic: $count calls/sec',
        detail:
            '$count calls in one second ($timing).'
            '${methodSummary.isNotEmpty ? '\nTop methods: $methodSummary' : ''}'
            '\nThreshold: $callsPerSecThreshold calls/sec.',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.vmTimeline,
        detectedAt: _clock(),
        // Per-window identity for producer-side dedup (v0.19.4 bracket
        // captures opt into `requireUniqueDetectedAtMicros: true`).
        // `_windowStart` advances exactly once per 1s evaluation window
        // and is reset before any subsequent emission, so each fired
        // window produces a distinct `detectedAtMicros` even when two
        // back-to-back windows fire under cooldown.
        dedupIdentityMicros: _windowStart.microsecondsSinceEpoch,
        // Detector-observed axis values exported into the trace event
        // args so the audit-gate can cross-check the operator's
        // reported `magnitudeObserved` (which is a SEND-rate computed
        // by the capture screen) against what the parser actually fed
        // the detector at fire time. Dropped `b` events or a late
        // profiling flag can produce a gap between sent and observed
        // counts;
        // without this cross-check, a future capture mislabeled `at`
        // while the detector saw an above-band count (or vice versa)
        // would still satisfy the schema as long as severity matches.
        // Stringified per Timeline arg-encoding contract.
        extraTraceArgs: {
          'observedCount': count.toString(),
          'maxCallDurationUs': maxUs.toString(),
          'p95CallDurationUs': p95Us.toString(),
          'callsOverThreshold': overCount.toString(),
        },
        measurement: IssueMeasurement(
          value: count.toDouble(),
          unit: MeasurementUnit.perSecond,
          warningAt: callsPerSecThreshold.toDouble(),
          criticalAt: (callsPerSecThreshold * criticalMultiplier).toDouble(),
          strict: true,
        ),
        confidenceReason:
            'Measured directly from VM timeline platform channel events',
        // Bind active route at emission so the controller's aggregate
        // stamp does not reattribute the issue to a route the user
        // navigated to during the 3-cycle cooldown window. See
        // [HeavyComputeDetector] persistence-contract doc.
        sourceRoute: _sourceRouteProvider(),
        interactionContext: _interactionContextProvider?.call(),
      );
      _issues
        ..clear()
        ..add(_lastEmittedIssue!);
    } else if (_cooldownCyclesRemaining > 0) {
      _cooldownCyclesRemaining--;
      _issues.clear();
      if (_lastEmittedIssue != null) _issues.add(_lastEmittedIssue!);
    } else if (_lastEmittedIssue != null &&
        _lastEmittedAt != null &&
        _clock().difference(_lastEmittedAt!) < emissionPersistence) {
      // Cooldown drained but the issue is still inside its persistence
      // window: keep showing it, unchanged.
      _issues
        ..clear()
        ..add(_lastEmittedIssue!);
    } else {
      _issues.clear();
      _lastEmittedIssue = null;
      _lastEmittedAt = null;
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _recentCallCount = 0;
    _callDurationsUs.clear();
    _begins.clear();
    _calls.clear();
    _beginKeys.clear();
    _callKeys.clear();
    _droppedUpToByTid.clear();
    _evictedBusiest = null;
    _evictedEmitting = null;
    _reportedRanges.clear();
    _criticalRanges.clear();
    _cooldownCyclesRemaining = 0;
    _lastEmittedIssue = null;
    _lastEmittedAt = null;
  }

  /// Clear all per-scenario state so the next scenario starts with a
  /// fresh evaluation window and zero cooldown.
  ///
  /// Called by [SleuthController.resetCaptureState] (i.e. on every
  /// `Sleuth.markScenarioBegin`). Without this, a prior scenario's
  /// cooldown can carry into the next leg and silently suppress its
  /// first overload window — combined with the controller's
  /// composite-key dedup on the retained issue's identity, that
  /// produces zero in-span trace records for the new leg.
  ///
  /// Only the detector-internal accumulators reset here. The
  /// controller's `_captureEmittedKeys` set deliberately stays
  /// persistent across scenarios so that retained-buffer replays
  /// (under `retainTimeline: true`) cannot re-record stale issues.
  ///
  /// [horizonUs] is the scenario boundary in event time, `Timeline.now` at
  /// the reset. Begins at or before it that a later poll delivers do not
  /// count in the scenario. Without it the boundary is the newest begin
  /// seen.
  void reset({int? horizonUs}) {
    _dropRetained(horizonUs: horizonUs);
    _windowStart = _clock();
    _cooldownCyclesRemaining = 0;
    _lastEmittedIssue = null;
    _lastEmittedAt = null;
    _reportedRanges.clear();
    _criticalRanges.clear();
    _lastWindowStats = null;
    _issues.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    // Warning and critical each have a capture bracket; the per-family
    // raise with a severity-aware `effectiveTierFor` reads both.
    perStableIdTier: {'platform_channel_traffic': EvidenceTier.runtimeVerified},
    additionalBrackets: [
      // Critical fires above 40 calls (strict). atTolerance 0.5 gives the
      // at band [40, 60]; the ceiling of 2.5 (100) leaves room for a
      // 90 calls/sec above leg.
      BracketSpec(
        stableId: 'platform_channel_traffic',
        severityLabel: 'critical',
        threshold: 40,
        unit: 'events',
        coveredThresholds: {'platform_channel_traffic.critical'},
        profileCapturePaths: [
          'test/validation/captures/platform_channel/'
              'platform_channel_traffic_critical_below.json',
          'test/validation/captures/platform_channel/'
              'platform_channel_traffic_critical_at.json',
          'test/validation/captures/platform_channel/'
              'platform_channel_traffic_critical_above.json',
        ],
        atTolerance: 0.5,
        aboveCeilingMultiplier: 2.5,
        observedAxisArgKey: 'observedCount',
        observedAxisTolerance: 0.25,
        requireUniqueDetectedAtMicros: true,
        requireDetectorTraceRecord: true,
      ),
    ],
    rationale:
        'VM-only detector. The emission axis is the largest number of call '
        'begins in one 1 s span of event time, checked once per second of '
        'wall time. A hermetic reproducer pins it by feeding events through '
        '`TimelineParser.parse()` into the detector. It fires above 20/sec '
        '(strict) and is critical at 2 times that, at 41 calls. 40 calls '
        'stay at warning to pin the critical-escalation inequality. Call '
        'duration is observational. Async `\'b\'`/`\'e\'` pairs matched by '
        '`id` (and sync `\'X\'` events) yield per-call durations, stamped as '
        '`maxCallDurationUs`, `p95CallDurationUs` and `callsOverThreshold` '
        '(calls over 8 ms), but they never gate emission. The reproducer '
        'covers two parser-accepted phase and name shapes: lowercase async '
        '`\'b\'` with the `Platform Channel send ` prefix (real '
        '`debugProfilePlatformChannels` output through TimelineTask) and '
        'sync `\'X\'` with the `MethodChannel` name. The parser allowlist '
        'accepts 9 shapes in total (6 sync names and 3 async-prefix '
        'casings). The 7 untested shapes (`PlatformChannel`, '
        '`platformchannel`, `Platform_Channel`, `platform_channel`, '
        '`methodchannel`, `Platform Channel Send ` prefix, `platform '
        'channel send ` prefix) are implicitly uncovered at this tier. The '
        'parser silently drops uppercase sync `\'B\'` async-shaped events, '
        'and the reproducer asserts that they do not emit. This is the '
        'canonical format-boundary trap for channel observers. The '
        'runtimeVerified tier rests on three on-device captures (iPhone 12, '
        'iOS 17.5, Flutter 3.47.6) whose legs sit below, at and above the '
        '20 calls/sec warning threshold. They use '
        '`Sleuth.markScenarioBegin/End` and `flushTimelineNow` to drive '
        'synchronous emission inside the scenario span. The capture screen '
        'sets `debugProfilePlatformChannels = true` per leg (restored in '
        '`finally`), so real `MethodChannel.invokeMethod` calls flow through '
        'the `TimelineTask` lowercase async `\'b\'`/`\'e\'` path that the '
        'parser already accepts. The captures were recorded under the '
        'v0.19.4 producer-side dedup (a stable per-window '
        '`dedupIdentityMicros` derived from '
        '`_windowStart.microsecondsSinceEpoch`), so the strong uniqueness '
        'invariant (`requireUniqueDetectedAtMicros: true`) protects against '
        'capture replay forgery. The bracket is the count axis. Replaying '
        'the captures through the parser shows nonzero per-call durations '
        'on every leg, and the below leg stays silent. After the 3-window '
        'cooldown the detector keeps the issue, without re-emitting, until '
        '`emissionPersistence` (10 s) has passed since the emission, so '
        'each leg still records exactly one trace event. The warning '
        'aboveCeilingMultiplier is 1.95, which puts the above-band ceiling '
        'at 39 calls/sec, under the 41-call critical-escalation boundary, '
        'so the warning above leg cannot reach the critical tier by '
        'accident. The critical tier (above 40 calls/sec) has its own '
        'triad in `additionalBrackets`, with legs at 30, 50 and 90 calls '
        'per second, on the same device and Flutter version.',
    reproducerPath: 'test/validation/platform_channel_reproducer_test.dart',
    profileCapturePaths: [
      'test/validation/captures/platform_channel/'
          'platform_channel_traffic_below.json',
      'test/validation/captures/platform_channel/'
          'platform_channel_traffic_at.json',
      'test/validation/captures/platform_channel/'
          'platform_channel_traffic_above.json',
    ],
    bracketThreshold: 20,
    bracketUnit: 'events',
    bracketStableId: 'platform_channel_traffic',
    bracketSeverityLabel: 'warning',
    // Default 1.1 atTolerance gives [20, 22] — too tight for
    // iOS scheduling jitter on the platform-channel send path.
    // Widened to 0.50 → at-band [20, 30]. Above-ceiling 1.95 →
    // 39 calls/sec ceiling, strictly under the 41-call (>20×2)
    // critical-escalation boundary so the above-leg cannot
    // ambiently bracket the critical tier.
    bracketAtTolerance: 0.50,
    aboveCeilingMultiplier: 1.95,
    coveredStableIds: {'platform_channel_traffic'},
    coveredThresholds: {
      'platform_channel_traffic.warning',
      'platform_channel_traffic.critical',
    },
    // Captures recorded under v0.19.4 producer-side dedup with
    // stable per-window `dedupIdentityMicros`
    // (`_windowStart.microsecondsSinceEpoch`). Opt into the
    // strong uniqueness invariant so the audit gate rejects any
    // future capture whose in-span trace records share a
    // `detectedAtMicros` (forgery / replay protection).
    bracketRequireUniqueDetectedAtMicros: true,
    // Detector exports its span count into the trace event args via
    // PerformanceIssue.extraTraceArgs. The audit gate cross-checks it
    // against `expectedMagnitude.observed` within ±25%, which absorbs a
    // few missed events, but a
    // mislabeled-leg capture (operator reports at-band rate while
    // detector saw above-band count, or vice versa) is rejected.
    // Backward compatible: pre-v0.19.5 captures recorded before
    // the field was added skip the cross-check at the
    // per-record-arg level (no arg, no check).
    observedAxisArgKey: 'observedCount',
    observedAxisTolerance: 0.25,
  );
}

/// Start time, count and method counts of one span of call begins.
///
/// `heldDurations` holds, by call key, the durations kept when the count
/// cap evicted the span's begins; it is empty for a live span.
typedef _SpanStats = ({
  int startUs,
  int count,
  Map<String, int> methodCounts,
  Map<String, int> heldDurations,
});

/// A platform channel call begin kept for span counting.
class _ChannelBegin {
  const _ChannelBegin(this.ts, this.tid, this.method, this.seq, this.key);

  /// Event time in microseconds.
  final int ts;

  /// Thread of the begin event; 0 when the event had none.
  final int tid;
  final String method;

  /// Arrival order.
  final int seq;

  /// Identity used to skip a repeat of the same event.
  final String key;
}
