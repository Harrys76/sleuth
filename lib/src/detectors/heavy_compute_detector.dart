import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/phase_event.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Detects heavy computation blocking the UI thread.
///
/// **VM-Only Detector** — monitors Dart isolate event gaps >8ms.
class HeavyComputeDetector extends BaseDetector with DetectorMetadataProvider {
  HeavyComputeDetector({this.lagThresholdMs = 8})
      : super(
          type: DetectorType.heavyCompute,
          lifecycle: DetectorLifecycle.vmOnly,
          name: 'Heavy Compute',
          description: 'Detects UI thread blocking (>8ms gaps)',
        );

  final int lagThresholdMs;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Process timeline data looking for long-running Dart events.
  ///
  /// Prefers [PhaseEvent]s (which carry optional enrichment from timeline
  /// args like dirty widget names). Falls back to raw [buildScopeDurations]
  /// when no build phaseEvents exist (backward compat for direct construction).
  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;
    _issues.clear();

    final buildPhaseEvents =
        data.phaseEvents.where((e) => e.phase == TimelinePhase.build).toList();

    if (buildPhaseEvents.isNotEmpty) {
      for (final event in buildPhaseEvents) {
        final ms = event.durationUs / 1000;
        if (ms > lagThresholdMs) {
          _issues.add(_createIssue(ms, event));
        }
      }
    } else {
      // Fallback: raw durations only (no phaseEvents available)
      for (final durationUs in data.buildScopeDurations) {
        final ms = durationUs / 1000;
        if (ms > lagThresholdMs) {
          _issues.add(_createGenericIssue(ms));
        }
      }
    }
  }

  PerformanceIssue _createIssue(double ms, PhaseEvent event) {
    final dirtyWidgets = event.dirtyList;
    final enriched =
        event.hasEnrichment && dirtyWidgets != null && dirtyWidgets.isNotEmpty;

    final (hint, effort) = FixHintBuilder.heavyCompute(
      durationMs: ms,
      dirtyWidgets: enriched ? dirtyWidgets : null,
    );
    return PerformanceIssue(
      stableId: 'heavy_compute',
      severity: ms > lagThresholdMs * 2
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: enriched
          ? 'Heavy Build: ${ms.toStringAsFixed(1)}ms '
              '(${_summarizeWidgets(dirtyWidgets)})'
          : 'Heavy Computation: ${ms.toStringAsFixed(1)}ms',
      detail: _buildDetail(ms, event),
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: DateTime.now(),
      // Stable per-BUILD identifier for capture-mode dedup. Two polls
      // observing the same BUILD produce the same
      // `dedupIdentityMicros` → SleuthController._captureEmittedKeys
      // composite-key dedup collapses them to one trace record.
      // Distinct from `detectedAt` (which is wall-clock time for
      // user-facing displays and snapshot exports). `event.timestampUs`
      // is monotonic VM Timeline time — never overload `detectedAt`
      // with it (would corrupt ISO-8601 export to 1970-era dates).
      dedupIdentityMicros: event.timestampUs,
      // Detector-stamped BUILD duration in ms. The audit gate cross-
      // checks this against the capture's `expectedMagnitude.observed`
      // (operator-Stopwatch value) so a regression that mis-computes
      // BUILD `dur` cannot certify the wrong magnitude as long as the
      // operator's Stopwatch records the true wall-clock work. Stored
      // as a string per `extraTraceArgs` contract (VM timeline args are
      // string-keyed string-valued).
      extraTraceArgs: {'observedDurationMs': ms.toString()},
      confidenceReason:
          'Measured directly from VM timeline long UI-thread event',
    );
  }

  PerformanceIssue _createGenericIssue(double ms) {
    final (hint, effort) = FixHintBuilder.heavyCompute(durationMs: ms);
    return PerformanceIssue(
      stableId: 'heavy_compute',
      severity: ms > lagThresholdMs * 2
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Heavy Computation: ${ms.toStringAsFixed(1)}ms',
      detail: 'Long-running operation detected on UI thread '
          '(${ms.toStringAsFixed(1)}ms). This blocks frame rendering.',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: DateTime.now(),
      // Same observed-axis stamping as the enriched path so the audit
      // gate's cross-check applies to fallback emissions too.
      extraTraceArgs: {'observedDurationMs': ms.toString()},
      confidenceReason:
          'Measured directly from VM timeline long UI-thread event',
    );
  }

  String _buildDetail(double ms, PhaseEvent event) {
    final buf = StringBuffer(
      'Long-running operation detected on UI thread '
      '(${ms.toStringAsFixed(1)}ms). This blocks frame rendering.',
    );
    if (event.dirtyCount != null) {
      buf.write('\nDirty widget count: ${event.dirtyCount}.');
    }
    final dirtyWidgets = event.dirtyList;
    if (dirtyWidgets != null && dirtyWidgets.isNotEmpty) {
      buf.write('\nDirty widgets: ${dirtyWidgets.join(', ')}.');
    }
    if (event.scopeContext != null) {
      buf.write('\nScope context: ${event.scopeContext}.');
    }
    return buf.toString();
  }

  static String _summarizeWidgets(List<String> names) {
    if (names.length <= 3) return names.join(', ');
    return '${names.take(3).join(', ')} +${names.length - 3} more';
  }

  @override
  void dispose() => _issues.clear();

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.runtimeVerified,
        rationale: 'VM-only detector. Frame-blocking compute-gap threshold '
            '(8 ms strict warning, 16 ms strict critical = 2×) pinned '
            'by hermetic reproducer (`BUILD` events through '
            '`TimelineParser.parse()` exercising all three emission '
            'paths: enriched `_createIssue` with dirtyList, unenriched '
            '`_createIssue` with `ts`, fallback `_createGenericIssue` '
            'on raw `buildScopeDurations`). The runtimeVerified tier '
            'is backed by SIX on-device captures (iPhone 12 / iOS '
            '17.5 / Flutter 3.41.x): three bracketing the 8 ms warning '
            'threshold (canonical bracket) and three bracketing the '
            '16 ms critical threshold (additionalBrackets[0], v0.19.13 '
            'tier-stack raise). All six captures use '
            '`Sleuth.markScenarioBegin/End` + `flushTimelineNow` to '
            'drive synchronous detector emission inside the scenario '
            'span. Captures recorded under v0.18.2+ producer-side dedup '
            '(stable per-BUILD `detectedAt` derived from '
            '`event.timestampUs`) so the strong uniqueness invariant '
            '(`requireUniqueDetectedAtMicros: true`) protects against '
            'capture replay forgery on both brackets.',
        reproducerPath: 'test/validation/heavy_compute_reproducer_test.dart',
        profileCapturePaths: [
          'test/validation/captures/heavy_compute/heavy_compute_below.json',
          'test/validation/captures/heavy_compute/heavy_compute_at.json',
          'test/validation/captures/heavy_compute/heavy_compute_above.json',
        ],
        bracketThreshold: 8,
        bracketUnit: 'ms',
        bracketStableId: 'heavy_compute',
        bracketSeverityLabel: 'warning',
        // Default 1.1 atTolerance gives [8, 8.8] band — too tight for
        // iPhone CPU/thermal variance (±15-20% post-warmup). Widened
        // to 0.50 → at-band [8, 12]. Above-ceiling 1.875 → 15 ms
        // (clear of 16 ms critical so above-leg cannot ambiently
        // bracket the critical tier).
        bracketAtTolerance: 0.50,
        aboveCeilingMultiplier: 1.875,
        coveredStableIds: {'heavy_compute'},
        coveredThresholds: {
          'heavy_compute.warning',
          'heavy_compute.critical',
        },
        // Captures recorded under v0.18.2+ producer-side dedup with
        // stable per-BUILD `detectedAt`. Opt into the strong
        // uniqueness invariant so the audit gate rejects any future
        // capture whose in-span trace records share a
        // `detectedAtMicros` (forgery / replay protection).
        bracketRequireUniqueDetectedAtMicros: true,
        // Detector stamps BUILD ms into `extraTraceArgs` (key
        // `observedDurationMs`) so the audit gate cross-checks the
        // operator-Stopwatch `expectedMagnitude.observed` against the
        // detector-side measurement. Closes the certify-wrong-magnitude
        // gap a magnitudeSourceEventName='' bypass would otherwise
        // leave open. Backward-compatible: pre-arg captures lack the
        // key and the cross-check is skipped per-record.
        observedAxisArgKey: 'observedDurationMs',
        // Critical-tier bracket. atTolerance 0.60 (vs warning's 0.50) is
        // forward-compat re-record headroom, not retroactive band-fit:
        // the committed at observation (23.703 ms) fits the 0.50 band
        // [16, 24] too. The wider band gives the next operator a 1-2
        // tap convergence window instead of 4-5 retries against a near-
        // edge target. aboveCeilingMultiplier stays 1.875 → ceiling 30
        // ms; above-band (25.7, 30] keeps positive width since at-upper
        // 25.6 < ceiling 30.
        additionalBrackets: [
          BracketSpec(
            stableId: 'heavy_compute',
            severityLabel: 'critical',
            threshold: 16,
            unit: 'ms',
            coveredThresholds: {'heavy_compute.critical'},
            profileCapturePaths: [
              'test/validation/captures/heavy_compute/heavy_compute_critical_below.json',
              'test/validation/captures/heavy_compute/heavy_compute_critical_at.json',
              'test/validation/captures/heavy_compute/heavy_compute_critical_above.json',
            ],
            atTolerance: 0.60,
            aboveCeilingMultiplier: 1.875,
            requireUniqueDetectedAtMicros: true,
            requireDetectorTraceRecord: true,
            // Same observed-axis key as the canonical warning bracket.
            // Cross-spec uniqueness tuple is (stableId, severityLabel,
            // argKey) so this collides with neither: warning + critical
            // share argKey but differ on severityLabel.
            observedAxisArgKey: 'observedDurationMs',
          ),
        ],
      );
}
