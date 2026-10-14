import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
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
/// After each check the detector keeps the calls of the last 2 s of event
/// time, so a check sees the whole of a poll that covers more than 2 s. It
/// keeps at most [maxRetainedCalls]; above about 2,000 calls/s it drops the
/// oldest and the count reads low.
///
/// **Retention.** Windows are 1 s long. After an emission the issue is
/// re-added for 3 cooldown windows (same identity, so a sustained overload
/// records one trace event), then stays in [issues] until
/// [emissionPersistence] has passed since the emission, so a short burst
/// remains visible long enough to read. Another overload after the
/// cooldown emits a fresh issue with a new identity.
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

  /// How far behind the newest call begin, in event time, calls are kept.
  static const int _retainUs = 2000000;

  static const int _spanUs = 1000000;

  /// Reads the controller's interaction state at emission so a
  /// cooldown-retained issue keeps the context it fired in.
  final InteractionContext Function()? _interactionContextProvider;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  int _recentCallCount = 0;
  final List<int> _callDurationsUs = [];
  late DateTime _windowStart;

  // Call begins sorted by event time, and completed calls by begin time,
  // both kept for [_retainUs] of event time behind the newest begin.
  final List<_ChannelBegin> _begins = [];
  final List<PlatformChannelCall> _calls = [];
  int _arrivalSeq = 0;
  // Begins with a sequence number at or above this arrived since the last
  // window check.
  int _checkSeq = 0;
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

  bool? _vmConnected;

  /// A reconnect resets the VM client's timeline cursors, so its first poll
  /// repeats events this detector already holds. A connection change drops
  /// the held calls and ignores later begins at or before the newest one
  /// seen.
  @override
  set vmConnected(bool value) {
    if (_vmConnected == value) return;
    _vmConnected = value;
    _dropRetained();
  }

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
      // more than 2 s of event time (a delayed poll) before its early calls
      // go.
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
      final horizon = _horizonUs;
      if (horizon != null && ts <= horizon) continue;
      final method =
          (json!['args'] as Map<String, dynamic>?)?['method'] as String? ??
          json['name'] as String? ??
          'unknown';
      if (previousUs != null && ts < previousUs) outOfOrder = true;
      previousUs = ts;
      _begins.add(_ChannelBegin(ts, method, _arrivalSeq++));
      final newest = _newestBeginUs;
      if (newest == null || ts > newest) _newestBeginUs = ts;
      _recentCallCount++;
    }
    if (outOfOrder) _begins.sort((a, b) => a.ts.compareTo(b.ts));
    for (final call in data.platformChannelCalls) {
      final horizon = _horizonUs;
      if (horizon != null && call.beginTs <= horizon) continue;
      _callDurationsUs.add(call.durationUs);
      _calls.add(call);
    }
    _prune(byTime: false);
  }

  /// Keeps at most [maxRetainedCalls] begins and calls and, with [byTime],
  /// drops those more than 2 s of event time behind the newest begin.
  void _prune({required bool byTime}) {
    if (_calls.length > maxRetainedCalls) {
      _calls.removeRange(0, _calls.length - maxRetainedCalls);
    }
    if (_begins.length > maxRetainedCalls) {
      _begins.removeRange(0, _begins.length - maxRetainedCalls);
    }
    final newest = _newestBeginUs;
    if (!byTime || newest == null) return;
    final cutoff = newest - _retainUs;
    var drop = 0;
    while (drop < _begins.length && _begins[drop].ts < cutoff) {
      drop++;
    }
    if (drop > 0) _begins.removeRange(0, drop);
    _calls.removeWhere((c) => c.beginTs < cutoff);
  }

  /// Drops the held calls and ignores later begins at or before the newest
  /// one seen, or at or before [horizonUs] when that is later.
  void _dropRetained({int? horizonUs}) {
    var horizon = _newestBeginUs;
    if (horizonUs != null && (horizon == null || horizonUs > horizon)) {
      horizon = horizonUs;
    }
    if (horizon != null) _horizonUs = horizon;
    _begins.clear();
    _calls.clear();
    _recentCallCount = 0;
    _callDurationsUs.clear();
    _checkSeq = _arrivalSeq;
  }

  /// The busiest half-open 1 s span of event time that holds at least one
  /// begin received since the last check, as `(first, last)` indexes into
  /// [_begins]; null when no begin arrived since then.
  (int, int)? _busiestNewSpan() {
    if (_begins.isEmpty) return null;
    // newBefore[i] counts the begins received since the last check among
    // the first i.
    final newBefore = List<int>.filled(_begins.length + 1, 0);
    for (var i = 0; i < _begins.length; i++) {
      newBefore[i + 1] = newBefore[i] + (_begins[i].seq >= _checkSeq ? 1 : 0);
    }
    if (newBefore.last == 0) return null;
    (int, int)? best;
    var right = 0;
    for (var left = 0; left < _begins.length; left++) {
      if (right < left) right = left;
      while (right + 1 < _begins.length &&
          _begins[right + 1].ts < _begins[left].ts + _spanUs) {
        right++;
      }
      final hasNew = newBefore[right + 1] - newBefore[left] > 0;
      if (hasNew && (best == null || right - left > best.$2 - best.$1)) {
        best = (left, right);
      }
    }
    return best;
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

  /// Stats of the most recently evaluated 1 s window; null before the
  /// first evaluation and after [reset].
  PlatformChannelWindowStats? get lastWindowStats => _lastWindowStats;
  PlatformChannelWindowStats? _lastWindowStats;

  static String _ms(int us) =>
      us % 1000 == 0 ? '${us ~/ 1000}' : (us / 1000).toStringAsFixed(1);

  void _evaluateWindow() {
    // Every number the issue shows comes from one span, so the title, the
    // method counts, the durations and the trace args describe the same
    // calls.
    final span = _busiestNewSpan();
    var count = 0;
    final methodCounts = <String, int>{};
    final durationsUs = <int>[];
    if (span != null) {
      final (first, last) = span;
      count = last - first + 1;
      for (var i = first; i <= last; i++) {
        final method = _begins[i].method;
        methodCounts[method] = (methodCounts[method] ?? 0) + 1;
      }
      final startUs = _begins[first].ts;
      for (final call in _calls) {
        if (call.beginTs >= startUs && call.beginTs < startUs + _spanUs) {
          durationsUs.add(call.durationUs);
        }
      }
    }
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
    if (count > callsPerSecThreshold) {
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
    _lastWindowStats = null;
    _issues.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    // Only the warning tier has a capture bracket; the per-family raise
    // with a severity-aware `effectiveTierFor` keeps critical at the base.
    perStableIdTier: {'platform_channel_traffic': EvidenceTier.runtimeVerified},
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
        'each leg still records exactly one trace event. The critical tier '
        'at 2 times the threshold (41 calls/sec) is reproducer-pinned: the '
        'base tier is reproducerOnly, `perStableIdTier` raises the family, '
        'and only `platform_channel_traffic.warning` has a bracket, so '
        '`effectiveTierFor` with severity `critical` reads reproducerOnly. '
        'The '
        'aboveCeilingMultiplier is 1.95, which puts the above-band ceiling '
        'at 39 calls/sec, under the 41-call critical-escalation boundary, '
        'so the above leg cannot reach the critical tier by accident.',
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
    coveredThresholds: {'platform_channel_traffic.warning'},
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

/// A platform channel call begin kept for span counting.
class _ChannelBegin {
  const _ChannelBegin(this.ts, this.method, this.seq);

  /// Event time in microseconds.
  final int ts;
  final String method;

  /// Arrival order.
  final int seq;
}
