import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Per-window platform channel call stats. Durations are in
/// microseconds and cover calls that completed in the window.
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
             'Detects excessive platform channel calls (>20/sec; opt in '
             'with SleuthConfig(profilePlatformChannels: true))',
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

  /// Reads the controller's interaction state at emission so a
  /// cooldown-retained issue keeps the context it fired in.
  final InteractionContext Function()? _interactionContextProvider;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  int _recentCallCount = 0;
  final List<int> _callDurationsUs = [];
  final Map<String, int> _methodCounts = {};
  late DateTime _windowStart;
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

    // Reset window every second
    if (windowDuration.inMilliseconds >= 1000) {
      _evaluateWindow();
      _recentCallCount = 0;
      _callDurationsUs.clear();
      _methodCounts.clear();
      _windowStart = now;
    }

    _recentCallCount += data.platformChannelEvents.length;
    for (final call in data.platformChannelCalls) {
      _callDurationsUs.add(call.durationUs);
    }

    for (final event in data.platformChannelEvents) {
      final json = event.json;
      if (json != null) {
        final method =
            (json['args'] as Map<String, dynamic>?)?['method'] as String? ??
            json['name'] as String? ??
            'unknown';
        _methodCounts[method] = (_methodCounts[method] ?? 0) + 1;
      }
    }
  }

  /// Longest completed call in the current window (µs); 0 when none.
  int get maxCallDurationUs => _callDurationsUs.isEmpty
      ? 0
      : _callDurationsUs.reduce((a, b) => a > b ? a : b);

  /// Nearest-rank 95th-percentile call duration in the current window
  /// (µs); 0 when no call completed.
  int get p95CallDurationUs {
    if (_callDurationsUs.isEmpty) return 0;
    final sorted = [..._callDurationsUs]..sort();
    final rank = (sorted.length * 95 + 99) ~/ 100;
    return sorted[rank - 1];
  }

  /// Completed calls in the current window longer than
  /// [durationThresholdUs].
  int get callsOverThreshold =>
      _callDurationsUs.where((d) => d > durationThresholdUs).length;

  /// Count of call begins in the current window.
  int get windowCallCount => _recentCallCount;

  /// Stats of the most recently evaluated 1 s window; null before the
  /// first evaluation and after [reset].
  PlatformChannelWindowStats? get lastWindowStats => _lastWindowStats;
  PlatformChannelWindowStats? _lastWindowStats;

  static String _ms(int us) =>
      us % 1000 == 0 ? '${us ~/ 1000}' : (us / 1000).toStringAsFixed(1);

  void _evaluateWindow() {
    _lastWindowStats = (
      callCount: _recentCallCount,
      maxCallDurationUs: maxCallDurationUs,
      p95CallDurationUs: p95CallDurationUs,
      callsOverThreshold: callsOverThreshold,
    );
    // Emission is count-only; call durations annotate the issue.
    if (_recentCallCount > callsPerSecThreshold) {
      final wouldBeCritical =
          _recentCallCount > callsPerSecThreshold * criticalMultiplier;
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
      final timing = _callDurationsUs.isEmpty
          ? 'no call durations observed'
          : 'max call ${_ms(maxUs)} ms, p95 ${_ms(p95Us)} ms, '
                '$overCount ${overCount == 1 ? 'call' : 'calls'} over '
                '${_ms(durationThresholdUs)} ms';
      final topMethods = _methodCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final methodSummary = topMethods
          .take(3)
          .map((e) => '${e.key}: ${e.value}×')
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
        title: 'High Platform Channel Traffic: $_recentCallCount calls/sec',
        detail:
            '$_recentCallCount calls in the last second ($timing).'
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
        // the detector at fire time. iOS coalescing or dropped `b`
        // events can produce a gap between sent and observed counts;
        // without this cross-check, a future capture mislabeled `at`
        // while the detector saw an above-band count (or vice versa)
        // would still satisfy the schema as long as severity matches.
        // Stringified per Timeline arg-encoding contract.
        extraTraceArgs: {
          'observedCount': _recentCallCount.toString(),
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
    _methodCounts.clear();
    _callDurationsUs.clear();
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
  void reset() {
    _recentCallCount = 0;
    _callDurationsUs.clear();
    _methodCounts.clear();
    _windowStart = _clock();
    _cooldownCyclesRemaining = 0;
    _lastEmittedIssue = null;
    _lastEmittedAt = null;
    _lastWindowStats = null;
    _issues.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.runtimeVerified,
    rationale:
        'VM-only detector. The emission axis is call count per 1s '
        'window, pinned by hermetic reproducer feeding events through '
        '`TimelineParser.parse()` into the detector: >20/sec '
        '(strict, 2× critical at 41 calls; 40 calls held at warning '
        'to pin critical-escalation inequality). Call duration is '
        'observational: async `\'b\'`/`\'e\'` pairs matched by `id` '
        '(and sync `\'X\'` events) yield per-call durations, stamped '
        'as `maxCallDurationUs` / `p95CallDurationUs` / '
        '`callsOverThreshold` (calls over 8 ms) but never gating '
        'emission. Two '
        'parser-accepted phase+name shapes covered: lowercase async '
        '`\'b\'` with `Platform Channel send ` prefix (real '
        '`debugProfilePlatformChannels` output via TimelineTask) and '
        'sync `\'X\'` with `MethodChannel` name. Parser allowlist '
        'accepts 9 shapes total (6 sync names + 3 async-prefix '
        'casings); the 7 untested shapes (`PlatformChannel`, '
        '`platformchannel`, `Platform_Channel`, `platform_channel`, '
        '`methodchannel`, `Platform Channel Send ` prefix, `platform '
        'channel send ` prefix) are implicitly uncovered at this '
        'tier. Uppercase sync `\'B\'` '
        'async-shaped events are silently dropped by the parser '
        'and asserted non-emitting — the canonical format-boundary '
        'trap for channel observers. The runtimeVerified tier is '
        'backed by three on-device captures (iPhone 12 / iOS 17.5 '
        '/ Flutter 3.41.x) that bracket the 20 calls/sec warning '
        'threshold via `Sleuth.markScenarioBegin/End` + '
        '`flushTimelineNow` driving synchronous emission inside '
        'the scenario span. The capture screen sets '
        '`debugProfilePlatformChannels = true` per leg (restored '
        'in `finally`) so real `MethodChannel.invokeMethod` calls '
        'flow through the `TimelineTask` lowercase async '
        '`\'b\'`/`\'e\'` path the parser already accepts. '
        'Captures recorded under v0.19.4 producer-side dedup '
        '(stable per-window `dedupIdentityMicros` derived from '
        '`_windowStart.microsecondsSinceEpoch`) so the strong '
        'uniqueness invariant '
        '(`requireUniqueDetectedAtMicros: true`) protects against '
        'capture replay forgery. The bracket is the count axis; '
        'replaying the captures through the parser shows nonzero '
        'per-call durations on every leg with the below leg still '
        'silent. After the 3-window cooldown the issue is retained '
        'until `emissionPersistence` (10 s) has passed since the '
        'emission without re-emitting, so each leg still records '
        'exactly one trace event. The 2× critical '
        'tier at 41 calls/sec also remains implicitly '
        'reproducer-pinned in this metadata — '
        '`DetectorMetadata` carries one `tier` per detector '
        'instance, so this declaration covers '
        '`platform_channel_traffic.warning` only; the '
        'aboveCeilingMultiplier is set to 1.95 → above-band '
        'ceiling 39 calls/sec, strictly under the 41-call '
        'critical-escalation boundary so the above-leg cannot '
        'ambiently bracket the critical tier.',
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
    // Detector exports `_recentCallCount` into the trace event
    // args via PerformanceIssue.extraTraceArgs. The audit gate
    // cross-checks this against `expectedMagnitude.observed`
    // (operator's send-side estimate) within ±25% so iOS
    // coalescing can absorb measurement variance, but a
    // mislabeled-leg capture (operator reports at-band rate while
    // detector saw above-band count, or vice versa) is rejected.
    // Backward compatible: pre-v0.19.5 captures recorded before
    // the field was added skip the cross-check at the
    // per-record-arg level (no arg, no check).
    observedAxisArgKey: 'observedCount',
    observedAxisTolerance: 0.25,
  );
}
