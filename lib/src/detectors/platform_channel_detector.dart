import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Detects excessive platform channel calls.
///
/// **VM-Only Detector** — monitors platform channel timeline events for >20 calls/sec.
class PlatformChannelDetector extends BaseDetector
    with DetectorMetadataProvider {
  PlatformChannelDetector({
    this.callsPerSecThreshold = 20,
    this.durationThresholdUs = 8000,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        super(
          type: DetectorType.platformChannel,
          lifecycle: DetectorLifecycle.vmOnly,
          name: 'Platform Channel',
          description: 'Detects excessive platform channel calls (>20/sec)',
        ) {
    _windowStart = _clock();
  }

  final int callsPerSecThreshold;

  /// Cumulative duration threshold per window (microseconds). Default 8ms.
  final int durationThresholdUs;
  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  int _recentCallCount = 0;
  int _cumulativeDurationUs = 0;
  final Map<String, int> _methodCounts = {};
  late DateTime _windowStart;
  int _cooldownCyclesRemaining = 0;
  PerformanceIssue? _lastEmittedIssue;

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
      _cumulativeDurationUs = 0;
      _methodCounts.clear();
      _windowStart = now;
    }

    _recentCallCount += data.platformChannelEvents.length;

    for (final event in data.platformChannelEvents) {
      final json = event.json;
      if (json != null) {
        _cumulativeDurationUs += (json['dur'] as int?) ?? 0;
        final method =
            (json['args'] as Map<String, dynamic>?)?['method'] as String? ??
                json['name'] as String? ??
                'unknown';
        _methodCounts[method] = (_methodCounts[method] ?? 0) + 1;
      }
    }
  }

  void _evaluateWindow() {
    final frequencyExceeded = _recentCallCount > callsPerSecThreshold;
    final durationExceeded = _cumulativeDurationUs > durationThresholdUs;

    if (frequencyExceeded || durationExceeded) {
      final wouldBeCritical = (frequencyExceeded &&
              _recentCallCount > callsPerSecThreshold * 2) ||
          (durationExceeded && _cumulativeDurationUs > durationThresholdUs * 2);
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
        final currentSeverity =
            wouldBeCritical ? IssueSeverity.critical : IssueSeverity.warning;
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
      final durationMs = _cumulativeDurationUs / 1000;
      final topMethods = _methodCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final methodSummary =
          topMethods.take(3).map((e) => '${e.key}: ${e.value}×').join(', ');

      final topMethod = topMethods.isNotEmpty ? topMethods.first.key : null;
      final (hint, effort) =
          FixHintBuilder.platformChannelTraffic(topMethod: topMethod);
      _lastEmittedIssue = PerformanceIssue(
        stableId: 'platform_channel_traffic',
        severity:
            wouldBeCritical ? IssueSeverity.critical : IssueSeverity.warning,
        category: IssueCategory.channel,
        confidence: IssueConfidence.confirmed,
        title: durationExceeded && !frequencyExceeded
            ? 'Slow Platform Channels: ${durationMs.toStringAsFixed(1)}ms total'
            : 'High Platform Channel Traffic: $_recentCallCount calls/sec',
        detail:
            '$_recentCallCount calls (${durationMs.toStringAsFixed(1)}ms total) '
            'in the last second.'
            '${methodSummary.isNotEmpty ? '\nTop methods: $methodSummary' : ''}'
            '\nThresholds: $callsPerSecThreshold calls/sec, '
            '${durationThresholdUs ~/ 1000}ms cumulative.',
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
          'cumulativeDurationUs': _cumulativeDurationUs.toString(),
        },
        confidenceReason:
            'Measured directly from VM timeline platform channel events',
      );
      _issues
        ..clear()
        ..add(_lastEmittedIssue!);
    } else if (_cooldownCyclesRemaining > 0) {
      _cooldownCyclesRemaining--;
      _issues.clear();
      if (_lastEmittedIssue != null) _issues.add(_lastEmittedIssue!);
    } else {
      _issues.clear();
      _lastEmittedIssue = null;
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _methodCounts.clear();
    _cooldownCyclesRemaining = 0;
    _lastEmittedIssue = null;
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
    _cumulativeDurationUs = 0;
    _methodCounts.clear();
    _windowStart = _clock();
    _cooldownCyclesRemaining = 0;
    _lastEmittedIssue = null;
    _issues.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.runtimeVerified,
        rationale: 'VM-only detector. Both emission axes pinned by '
            'hermetic reproducer feeding events through '
            '`TimelineParser.parse()` into the detector: (a) >20/sec '
            'frequency (strict, 2× critical at 41 calls; 40 calls held '
            'at warning to pin critical-escalation inequality), and '
            '(b) >8000µs cumulative per 1s window (strict, tested at '
            '7998/8000/8001µs via sync `\'X\'` events with 3 calls — '
            'isolates duration axis from frequency axis). Two '
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
            'capture replay forgery. Frequency axis only; the '
            '8 ms cumulative-duration axis remains reproducer-pinned '
            '(no checked-in capture brackets it). The 2× critical '
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
