import 'package:meta/meta.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/phase_event.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Detects heavy computation blocking the UI thread.
///
/// **VM-Only Detector** — detects slow widget build passes (>8 ms warning,
/// >16 ms critical at 60 Hz) from VM timeline BUILD-scope durations. With
/// [autoThreshold], [updateFrameBudget] moves the warning threshold to half
/// the resolved frame budget (critical stays 2x).
///
/// ## Persistence contract
///
/// Heavy compute is one-shot: a single BUILD scope produces one event,
/// which is observed in one VM batch and absent from the next. To keep
/// the issue visible past the user's tap-to-open delay, fresh emissions
/// stay in [issues] for [emissionPersistence] (default 10s) wall-clock,
/// measured by a monotonic [Stopwatch] (immune to system clock changes,
/// DST, NTP sync). Fresh emissions reset the window and replace the
/// stale issue immediately.
///
/// **Source-route binding.** Detectors that retain issues across batches
/// MUST stamp [PerformanceIssue.sourceRoute] at emission time so a
/// post-emission navigation does not reattribute the issue to the new
/// route via the controller's aggregate-cycle route stamp. Pass
/// [sourceRouteProvider] from the controller to read the active route
/// at emission. Returning null is acceptable when the controller has no
/// active route (e.g. during pre-routing scans). Future detectors that
/// adopt persistence should follow the same pattern — see
/// [PlatformChannelDetector] for the cooldown-suppression variant.
class HeavyComputeDetector extends BaseDetector with DetectorMetadataProvider {
  HeavyComputeDetector({
    this.lagThresholdMs = 8,
    this.autoThreshold = false,
    this.emissionPersistence = const Duration(seconds: 10),
    String? Function()? sourceRouteProvider,
    InteractionContext Function()? interactionContextProvider,
    @visibleForTesting Stopwatch? testStopwatch,
  }) : _lagThresholdUs = lagThresholdMs * 1000,
       _sourceRouteProvider = sourceRouteProvider ?? (() => null),
       _interactionContextProvider = interactionContextProvider,
       _emissionStopwatch = testStopwatch ?? Stopwatch(),
       super(
         type: DetectorType.heavyCompute,
         lifecycle: DetectorLifecycle.vmOnly,
         name: 'Heavy Compute',
         description:
             'Detects slow widget build passes (>8 ms warning, >16 ms '
             'critical at 60 Hz; scales with the measured frame rate)',
       );

  /// Warning threshold in milliseconds (critical is 2x). Used as-is unless
  /// [autoThreshold] is true and a frame budget has been applied.
  final int lagThresholdMs;

  /// When true, [updateFrameBudget] sets the warning threshold to half the
  /// resolved frame budget. When false, [lagThresholdMs] always applies.
  final bool autoThreshold;

  int _lagThresholdUs;

  /// Warning threshold in effect, in microseconds.
  int get effectiveLagThresholdUs => _lagThresholdUs;

  /// Sets the warning threshold to half of [budgetUs] when [autoThreshold]
  /// is true. Called by `SleuthController` when the resolved frame budget
  /// changes.
  void updateFrameBudget(int budgetUs) {
    if (!autoThreshold || budgetUs <= 0) return;
    _lagThresholdUs = budgetUs ~/ 2;
  }

  /// Restores the [lagThresholdMs] threshold.
  void resetFrameBudget() {
    _lagThresholdUs = lagThresholdMs * 1000;
  }

  /// Wall-clock duration a previously-emitted `heavy_compute` issue
  /// persists before being cleared. Heavy compute is one-shot (a
  /// single BUILD scope produces one event); without persistence the
  /// issue is visible for ~1 VM batch only. iOS profile-mode VM
  /// service can poll multiple times per second, so a batch-count
  /// TTL would expire faster than the user's tap-to-open window. A
  /// [Stopwatch]-measured wall-clock duration is independent of poll
  /// cadence AND immune to system clock jumps (DST, NTP sync).
  final Duration emissionPersistence;

  final String? Function() _sourceRouteProvider;

  /// A build longer than this many times the threshold is critical.
  static const int criticalMultiplier = 2;

  /// Reads the controller's interaction state at emission so a retained
  /// issue keeps the context it fired in (e.g. `navigating`) rather than
  /// the context of a later aggregate.
  final InteractionContext Function()? _interactionContextProvider;
  final Stopwatch _emissionStopwatch;

  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) {
    _isEnabled = value;
    if (!value) _clearRetainedState();
  }

  @override
  set vmConnected(bool value) {
    if (!value) _clearRetainedState();
  }

  void _clearRetainedState() {
    _issues.clear();
    _emissionStopwatch
      ..stop()
      ..reset();
  }

  /// Process timeline data looking for long-running Dart events.
  ///
  /// Prefers [PhaseEvent]s (which carry optional enrichment from timeline
  /// args like dirty widget names). Falls back to raw [buildScopeDurations]
  /// when no build phaseEvents exist (backward compat for direct construction).
  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    // One issue per batch: the longest BUILD over threshold, with the
    // count of others in the detail. Every emission shares the
    // `heavy_compute` stable id, so one card per slow build would stack
    // identical cards in the overlay.
    final fresh = <PerformanceIssue>[];
    final buildPhaseEvents = data.phaseEvents
        .where((e) => e.phase == TimelinePhase.build)
        .toList();

    if (buildPhaseEvents.isNotEmpty) {
      PhaseEvent? worst;
      var over = 0;
      for (final event in buildPhaseEvents) {
        if (event.durationUs <= _lagThresholdUs) continue;
        over++;
        if (worst == null || event.durationUs > worst.durationUs) {
          worst = event;
        }
      }
      if (worst != null) {
        fresh.add(_createIssue(worst.durationUs, worst, batchCount: over));
      }
    } else {
      // Fallback: raw durations only (no phaseEvents available)
      var worstUs = 0;
      var over = 0;
      for (final durationUs in data.buildScopeDurations) {
        if (durationUs <= _lagThresholdUs) continue;
        over++;
        if (durationUs > worstUs) worstUs = durationUs;
      }
      if (over > 0) {
        fresh.add(
          _createGenericIssue(
            worstUs,
            batchCount: over,
            batchMaxTimestampUs: data.maxTimestampUs,
          ),
        );
      }
    }

    if (fresh.isNotEmpty) {
      // Fresh emission replaces any stale issue and resets the
      // monotonic persistence window.
      _issues
        ..clear()
        ..addAll(fresh);
      _emissionStopwatch
        ..reset()
        ..start();
    } else if (_emissionStopwatch.isRunning &&
        _emissionStopwatch.elapsed < emissionPersistence) {
      // Idle batch but persistence window still open — keep showing
      // the prior issue so it stays observable past the user's
      // tap-to-open delay regardless of VM poll cadence.
    } else {
      _issues.clear();
      _emissionStopwatch
        ..stop()
        ..reset();
    }
  }

  PerformanceIssue _createIssue(
    int durationUs,
    PhaseEvent event, {
    int batchCount = 1,
  }) {
    final ms = durationUs / 1000;
    final dirtyWidgets = event.dirtyList;
    final enriched =
        event.hasEnrichment && dirtyWidgets != null && dirtyWidgets.isNotEmpty;

    final (hint, effort) = FixHintBuilder.heavyCompute(
      durationMs: ms,
      dirtyWidgets: enriched ? dirtyWidgets : null,
    );
    return PerformanceIssue(
      stableId: 'heavy_compute',
      severity: durationUs > _lagThresholdUs * criticalMultiplier
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: enriched
          ? 'Heavy Build: ${ms.toStringAsFixed(1)}ms '
                '(${_summarizeWidgets(dirtyWidgets)})'
          : 'Heavy Computation: ${ms.toStringAsFixed(1)}ms',
      detail: _buildDetail(ms, event) + _batchNote(batchCount),
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
      sourceRoute: _sourceRouteProvider(),
      interactionContext: _interactionContextProvider?.call(),
    );
  }

  /// Issue for a batch that carries build durations without timestamps.
  /// The batch's newest event timestamp (when known) identifies it for
  /// capture-mode dedup.
  PerformanceIssue _createGenericIssue(
    int durationUs, {
    int batchCount = 1,
    int batchMaxTimestampUs = -1,
  }) {
    final ms = durationUs / 1000;
    final (hint, effort) = FixHintBuilder.heavyCompute(durationMs: ms);
    return PerformanceIssue(
      stableId: 'heavy_compute',
      severity: durationUs > _lagThresholdUs * criticalMultiplier
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Heavy Computation: ${ms.toStringAsFixed(1)}ms',
      detail:
          'Long-running operation detected on UI thread '
          '(${ms.toStringAsFixed(1)}ms). This blocks frame rendering.'
          '${_batchNote(batchCount)}',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: DateTime.now(),
      dedupIdentityMicros: batchMaxTimestampUs >= 0
          ? batchMaxTimestampUs
          : null,
      // Same observed-axis stamping as the enriched path so the audit
      // gate's cross-check applies to fallback emissions too.
      extraTraceArgs: {'observedDurationMs': ms.toString()},
      confidenceReason:
          'Measured directly from VM timeline long UI-thread event',
      sourceRoute: _sourceRouteProvider(),
      interactionContext: _interactionContextProvider?.call(),
    );
  }

  /// Suffix naming the other over-threshold builds of the same batch.
  static String _batchNote(int batchCount) => batchCount > 1
      ? ' $batchCount builds exceeded the threshold in this batch; the '
            'longest is shown.'
      : '';

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
  void dispose() {
    _issues.clear();
    _emissionStopwatch
      ..stop()
      ..reset();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.runtimeVerified,
    rationale:
        'VM-only detector. Frame-blocking compute-gap threshold '
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
        'capture replay forgery on both brackets. Issue lifetime: '
        'heavy_compute is one-shot per BUILD scope. Emitted issues '
        'persist for `emissionPersistence` wall-clock duration '
        '(default 10s, monotonic Stopwatch) so a one-shot compute '
        'event stays observable past the tap-to-open delay on the '
        'FloatingIssuesCard. Wall-clock semantics are independent '
        'of VM poll cadence — iOS profile-mode batches arrive '
        'multiple times per second. Fresh emissions reset the '
        'persistence window and replace the stale issue '
        'immediately. Persisted issues stamp `sourceRoute` at '
        'emission so post-emission navigation does not reattribute '
        'the issue via the controller aggregate stamp.',
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
    coveredThresholds: {'heavy_compute.warning', 'heavy_compute.critical'},
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
