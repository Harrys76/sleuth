import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/phase_event.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/type_name_cache.dart';
import '../utils/widget_location.dart';
import '../vm/timeline_parser.dart';

/// Detects excessive repainting using VM Timeline Paint events or debug
/// callback aggregate paint counts.
///
/// **Hybrid Detector** — VM Timeline provides exact paint event data
/// (confirmed confidence). Debug callbacks provide aggregate paint count
/// fallback (likely confidence, no per-widget attribution).
///
/// Data sources accumulate into staging fields; the single [_evaluate]
/// method is the ONLY writer of [_issues]. Called from [scanTree] (scan
/// tick) and [evaluateNow] (timeline tick).
class RepaintDetector extends BaseDetector with DetectorMetadataProvider {
  RepaintDetector({
    this.paintFrequencyThreshold = 30,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _windowStart = (clock ?? DateTime.now)(),
        super(
          type: DetectorType.repaint,
          lifecycle: DetectorLifecycle.hybrid,
          name: 'Repaint',
          description: 'Detects excessive repainting (>30 paints/sec)',
        );

  final int paintFrequencyThreshold;
  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  static const int _maxHighlightsPerType = 3;
  bool _isEnabled = true;

  /// Returns the per-widget animation-owned paint count for [typeName],
  /// as attributed by the coordinator's per-paint walk. Defaults to 0
  /// when the type has no owned paints in this snapshot.
  static int _ownedPaintsFor(DebugSnapshot snapshot, String typeName) =>
      snapshot.animationOwnedPaintCounts[typeName] ?? 0;

  /// Returns true iff every non-zero entry in [snapshot.paintCounts] has
  /// been fully attributed to an animation owner. Used by Gate B to
  /// suppress the VM aggregate fallback when all per-widget activity
  /// belongs to known animation drivers.
  ///
  /// Returns false when there's no per-widget data — without per-paint
  /// attribution we MUST NOT silently mask a real bug, so we let the
  /// VM gate fire normally.
  bool _allPaintsAnimationOwned(DebugSnapshot snapshot) {
    if (snapshot.paintCounts.isEmpty) return false;
    for (final entry in snapshot.paintCounts.entries) {
      if (entry.value <= 0) continue;
      final owned = _ownedPaintsFor(snapshot, entry.key);
      // Per-paint attribution: every individual paint of this typeName
      // was owned by an animation driver. (Subset relation: owned <=
      // total is an invariant maintained by the coordinator.)
      if (owned < entry.value) return false;
    }
    return true;
  }

  int _paintEventCount = 0;
  DateTime _windowStart;

  /// Last completed-window aggregate paint count, refreshed every time
  /// the 1s VM window closes regardless of whether the count crossed
  /// [paintFrequencyThreshold]. Capture-mode tooling reads this so a
  /// sub-threshold leg's exported magnitude reflects what the detector
  /// measured, not the operator's plan.
  // Window-completion writes this on every tick; resetCaptureState
  // zeroes it on per-leg boundaries; cannot be final.
  // ignore: prefer_final_fields
  int _lastObservedPaintCount = 0;

  /// Peak window aggregate paint count seen since the last
  /// [resetCaptureState] call. Capture-mode operators export this as
  /// the leg's magnitude so the value matches the audit gate's
  /// `'max'` axis reduction across in-span emissions. Without peak
  /// tracking, [_lastObservedPaintCount] alone reads the most-recent
  /// (post-workload, near-idle) window and the exported magnitude
  /// diverges from what the detector actually emitted.
  // Updated at every window close on a >= comparison; reset at per-leg
  // boundaries; cannot be final.
  // ignore: prefer_final_fields
  int _peakObservedPaintCount = 0;

  /// Detector-measured paint count from the most recent completed 1s
  /// window. Capture-mode operators export this for sub-threshold legs
  /// where no `excessive_repaint` issue fires.
  int get lastObservedPaintCount => _lastObservedPaintCount;

  /// Peak detector-measured paint count seen across all 1s VM windows
  /// since the last [resetCaptureState] call. Use for capture-mode
  /// magnitude export so the value matches the audit gate's `'max'`
  /// axis reduction. Returns 0 if no window has completed since reset.
  int get peakObservedPaintCount => _peakObservedPaintCount;

  // -- Staging fields (nullable = no fresh data) --

  /// null = no VM window completed since last evaluate.
  int? _pendingVmWindowCount;

  /// null = no new snapshot delivered since last evaluate.
  DebugSnapshot? _pendingDebugSnapshot;

  /// Dirty RenderObject count from enriched timeline args, accumulating
  /// across timeline ticks until the next 1s window completes.
  int _pendingEnrichedDirtyTotal = 0;

  /// Enriched dirty count staged atomically with [_pendingVmWindowCount].
  /// Consumed by [_evaluateVmData] and cleared unconditionally in [_evaluate].
  int? _stagedEnrichedDirtyTotal;

  bool _vmConnected = false;

  /// Current VM connectivity — set by the controller.
  bool get vmConnected => _vmConnected;
  @override
  set vmConnected(bool value) {
    final wasConnected = _vmConnected;
    _vmConnected = value;
    if (!value) {
      _paintEventCount = 0;
      _pendingVmWindowCount = null;
      _pendingEnrichedDirtyTotal = 0;
      _stagedEnrichedDirtyTotal = null;
      // Capture-mode observables also clear on disconnect so a leg
      // straddling a VM disconnect cannot export a stale peak from
      // before the drop. Reconnected post-disconnect runs accumulate
      // a fresh peak from the new windows.
      _lastObservedPaintCount = 0;
      _peakObservedPaintCount = 0;
    } else if (!wasConnected) {
      // Reconnect: stage a fresh-zero so the next _evaluate() flushes
      // stale debug issues that are incompatible with VM mode.
      _pendingVmWindowCount = 0;
    }
  }

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  List<WidgetHighlight> get highlights => List.unmodifiable(_highlights);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Process VM timeline data for paint event counts.
  ///
  /// Accumulates counts and enriched dirty totals into pending buffers.
  /// On 1s window completion, stages count + enrichment atomically
  /// for [_evaluate].
  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    _paintEventCount += data.flushPaintDurations.length;

    // Accumulate enriched dirty counts from this batch
    for (final event in data.phaseEvents) {
      if (event.phase == TimelinePhase.paint && event.dirtyCount != null) {
        _pendingEnrichedDirtyTotal += event.dirtyCount!;
      }
    }

    final now = _clock();
    if (now.difference(_windowStart).inMilliseconds >= 1000) {
      _pendingVmWindowCount = _paintEventCount;
      // Refresh capture-mode observable on every window close — captured
      // BEFORE _evaluateVmData's threshold guard so sub-threshold legs
      // still expose a measurement to flushPaintEvaluation()/getter.
      _lastObservedPaintCount = _paintEventCount;
      if (_paintEventCount > _peakObservedPaintCount) {
        _peakObservedPaintCount = _paintEventCount;
      }
      // Stage enrichment atomically with the window count
      _stagedEnrichedDirtyTotal =
          _pendingEnrichedDirtyTotal > 0 ? _pendingEnrichedDirtyTotal : null;
      _pendingEnrichedDirtyTotal = 0;
      _paintEventCount = 0;
      _windowStart = now;
    }
  }

  /// Forces an immediate close of the in-flight 1s VM window so capture
  /// tooling can read [lastObservedPaintCount] without waiting for the
  /// elapsed timer. Idempotent — re-running with no new paint events
  /// preserves the prior values. Pure observable refresh; does NOT emit
  /// issues (issue emission is owned by [_evaluateVmData], reached via
  /// [_evaluate], which only runs from the scan pipeline).
  ///
  /// Updates only [_lastObservedPaintCount] — does NOT update
  /// [_peakObservedPaintCount]. The peak observable is restricted to
  /// counts from naturally-completed windows (those that flow through
  /// [processTimelineData]'s window-close path AND therefore through
  /// [_evaluate] → [_evaluateVmData] for issue emission). A capture
  /// screen reading [peakObservedPaintCount] is guaranteed to read a
  /// value that has a matching `extraTraceArgs.observedPaintCount` arg
  /// on at least one in-span emission record (modulo threshold-gate
  /// suppression for sub-threshold peaks). This keeps the audit-gate's
  /// `observedAxisReduction: 'max'` cross-check on emission records
  /// honest — the exported `expectedMagnitude.observed` cannot exceed
  /// every emission's `observedPaintCount` arg.
  void flushPaintEvaluation() {
    if (_paintEventCount > 0) {
      _pendingVmWindowCount = _paintEventCount;
      _lastObservedPaintCount = _paintEventCount;
      _stagedEnrichedDirtyTotal =
          _pendingEnrichedDirtyTotal > 0 ? _pendingEnrichedDirtyTotal : null;
      _pendingEnrichedDirtyTotal = 0;
      _paintEventCount = 0;
      _windowStart = _clock();
    }
  }

  /// Clears all per-leg accumulator state so capture screens can
  /// re-enter a fresh below/at/above leg without leakage from the
  /// prior leg's paint counts, debug snapshot, or pending issues.
  /// `_vmConnected` is owned by the controller and intentionally left
  /// untouched.
  void resetCaptureState() {
    _paintEventCount = 0;
    _pendingVmWindowCount = null;
    _lastObservedPaintCount = 0;
    _peakObservedPaintCount = 0;
    _pendingEnrichedDirtyTotal = 0;
    _stagedEnrichedDirtyTotal = null;
    _pendingDebugSnapshot = null;
    _windowStart = _clock();
    _issues.clear();
    _highlights.clear();
    _hotTypes = const {};
    _hotCounts.clear();
  }

  Map<String, double> _hotTypes = const {};
  final Map<String, int> _hotCounts = {};

  @override
  void prepareScan(BuildContext context) {
    _highlights.clear();
    _hotCounts.clear();

    // Compute hot types from per-widget debug paint data, using the
    // residual (total - animation-owned) so the overlay doesn't draw a
    // red box around a `CircularProgressIndicator` whose paints are
    // fully owned. Mirrors the per-widget gate in
    // `_evaluateDebugDataPerWidget` so highlights and issues stay in
    // sync.
    _hotTypes = const {};
    final snapshot = _pendingDebugSnapshot;
    if (snapshot != null && snapshot.paintCounts.isNotEmpty) {
      final us = snapshot.elapsed.inMicroseconds;
      if (us > 0) {
        final types = <String, double>{};
        for (final entry in snapshot.paintCounts.entries) {
          final ownedCount = _ownedPaintsFor(snapshot, entry.key);
          final residualCount = entry.value - ownedCount;
          if (residualCount <= 0) continue;
          final rate = residualCount / (us / Duration.microsecondsPerSecond);
          if (rate >= paintFrequencyThreshold) {
            types[entry.key] = rate;
          }
        }
        if (types.isNotEmpty) _hotTypes = types;
      }
    }
  }

  @override
  void checkElement(Element element) {
    if (_hotTypes.isEmpty) return;

    final name = typeNameCache.lookup(element.widget);
    final rate = _hotTypes[name];
    if (rate != null) {
      final count = _hotCounts[name] ?? 0;
      if (count < _maxHighlightsPerType) {
        final ro = element.renderObject;
        if (ro != null) {
          final rect = getGlobalRect(ro);
          if (rect != null) {
            _highlights.add(WidgetHighlight(
              rect: rect,
              widgetName: name,
              severity: rate > paintFrequencyThreshold * 2
                  ? IssueSeverity.critical
                  : IssueSeverity.warning,
              detectorName: 'Repaint',
              detail: '${rate.round()} repaints/sec',
            ));
            _hotCounts[name] = count + 1;
          }
        }
      }
    }
  }

  @override
  void finalizeScan() {
    _evaluate();
  }

  @override
  void updateDebugSnapshot(DebugSnapshot snapshot) {
    _pendingDebugSnapshot = snapshot;
  }

  @override
  void evaluateNow() => _evaluate();

  /// The ONLY method that writes [_issues].
  ///
  /// Priority: debug per-widget > VM aggregate > debug aggregate.
  /// Per-widget paint attribution is more actionable than aggregate counts.
  /// All staging is cleared up front to prevent stale data from a
  /// lower-priority source from overwriting on the next scan tick.
  void _evaluate() {
    final vmWindowCount = _pendingVmWindowCount;
    final debugSnapshot = _pendingDebugSnapshot;
    final enrichedDirtyTotal = _stagedEnrichedDirtyTotal;

    final hasFreshVm = _vmConnected && vmWindowCount != null;
    final hasFreshDebug = debugSnapshot != null;

    if (!hasFreshVm && !hasFreshDebug) return;

    _issues.clear();

    // Clear ALL staging regardless of which branch wins.
    _pendingVmWindowCount = null;
    _pendingDebugSnapshot = null;
    // Unconditional clear — prevents enrichment leaking across branches.
    _stagedEnrichedDirtyTotal = null;

    if (hasFreshDebug && debugSnapshot.paintCounts.isNotEmpty) {
      // Per-widget debug path — best attribution.
      // If no individual type crosses the threshold, fall through.
      _evaluateDebugDataPerWidget(debugSnapshot);
      if (_issues.isEmpty && hasFreshVm && vmWindowCount > 0) {
        // Gate B — suppress VM aggregate fallback when *every* per-widget
        // paint is animation-owned. Without this guard, an animation that
        // doesn't trip Gate A (sub-threshold per-widget rate but high
        // aggregate) would still light up `excessive_repaint`.
        if (_allPaintsAnimationOwned(debugSnapshot)) {
          // Suppressed — all known activity is intentional animation work.
        } else {
          _evaluateVmData(vmWindowCount, enrichedDirtyTotal);
        }
      } else if (_issues.isEmpty && debugSnapshot.totalPaintCount > 0) {
        _evaluateDebugData(debugSnapshot);
      }
    } else if (hasFreshVm) {
      if (vmWindowCount > 0) {
        _evaluateVmData(vmWindowCount, enrichedDirtyTotal);
      }
    } else if (hasFreshDebug) {
      if (debugSnapshot.totalPaintCount > 0) {
        _evaluateDebugData(debugSnapshot);
      }
    }
  }

  /// VM timeline path — exact paint event data.
  ///
  /// When [enrichedDirtyTotal] is available (from timeline enrichment args),
  /// appends dirty RenderObject count to the issue detail.
  void _evaluateVmData(int paintCount, [int? enrichedDirtyTotal]) {
    if (paintCount <= paintFrequencyThreshold) return;

    final detailSuffix = enrichedDirtyTotal != null && enrichedDirtyTotal > 0
        ? '\n$enrichedDirtyTotal dirty RenderObjects '
            '(from timeline enrichment).'
        : '';

    final (hint, effort) = FixHintBuilder.excessiveRepaintVm();

    final detectedAt = DateTime.now();
    _issues.add(PerformanceIssue(
      stableId: 'excessive_repaint',
      severity: paintCount > paintFrequencyThreshold * 2
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.paint,
      confidence: IssueConfidence.confirmed,
      title: 'Excessive Repainting: $paintCount paints/sec',
      detail: '$paintCount paint events detected in 1 second. '
          'Threshold: $paintFrequencyThreshold/sec.$detailSuffix',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: detectedAt,
      // Audit gate cross-checks `expectedMagnitude.observed` against
      // this detector-side measurement so a regression in window
      // accounting cannot certify the wrong magnitude.
      dedupIdentityMicros: detectedAt.microsecondsSinceEpoch,
      extraTraceArgs: {'observedPaintCount': paintCount.toString()},
      confidenceReason: 'Measured directly from VM timeline paint events',
    ));
  }

  /// Debug callback path — per-widget paint attribution.
  ///
  /// **Gate A — per-widget residual subtraction.**
  /// Earlier (v0.15.3 M1) this gate did `if (_isAnimationOwned(...))
  /// continue;` — a binary skip-or-fire on the cached ancestor chain.
  /// That behaved correctly for monomorphic typeNames, but for
  /// polymorphic keys like `'CustomPaint'` (where one widget's paints
  /// are 100% owned by `CircularProgressIndicator` and another's are
  /// not owned at all), the chain belonged to whoever was seen first
  /// and the gate either fully suppressed the chart's bug or fully
  /// fired on the indicator's spinner.
  ///
  /// The fix: the coordinator now does per-paint attribution and the
  /// snapshot carries a per-widget owned-count subset. Each paint is
  /// judged on its live element; the totals come back here as
  /// `paintCounts[typeName] = total` and
  /// `animationOwnedPaintCounts[typeName] = owned`. We compute the
  /// residual (`total - owned`), recompute the rate from the residual,
  /// and compare *that* against the threshold. Mixed-ownership widgets
  /// fire on their unowned subset and surface the owned subset as a
  /// disclosure suffix in the detail line.
  void _evaluateDebugDataPerWidget(DebugSnapshot snapshot) {
    final us = snapshot.elapsed.inMicroseconds;
    if (us == 0) return;

    for (final entry in snapshot.paintCounts.entries) {
      final typeName = entry.key;
      final totalCount = entry.value;
      final ownedCount = _ownedPaintsFor(snapshot, typeName);
      final residualCount = totalCount - ownedCount;
      if (residualCount <= 0) continue;

      final residualRate =
          residualCount / (us / Duration.microsecondsPerSecond);
      if (residualRate < paintFrequencyThreshold) continue;

      final elapsedSec = us / Duration.microsecondsPerSecond;

      final (hint, effort) = FixHintBuilder.repaintDebugType(
        typeName: typeName,
        rate: residualRate.round(),
        ancestorChain: snapshot.ancestorChains[typeName],
      );

      final ownedSuffix = ownedCount > 0
          ? ' Excludes $ownedCount animation-owned paint'
              '${ownedCount == 1 ? '' : 's'}.'
          : '';

      _issues.add(PerformanceIssue(
        stableId: 'repaint_debug_$typeName',
        severity: residualRate > paintFrequencyThreshold * 2
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.paint,
        confidence: IssueConfidence.confirmed,
        title: 'Excessive Repainting: $typeName '
            '(${residualRate.round()}/sec)',
        detail: '$typeName: $residualCount repaints in '
            '${elapsedSec.toStringAsFixed(1)}s '
            '(${residualRate.round()}/sec).$ownedSuffix',
        fixHint: hint,
        fixEffort: effort,
        widgetName: typeName,
        ancestorChain: snapshot.ancestorChains[typeName],
        observationSource: ObservationSource.debugCallback,
        detectedAt: DateTime.now(),
        confidenceReason: ownedCount > 0
            ? 'Measured directly from debug callback paint counter '
                '(animation-owned paints excluded)'
            : 'Measured directly from debug callback paint counter',
      ));
    }
  }

  /// Debug callback path — aggregate paint count (no per-widget attribution).
  ///
  /// Gate C — subtract animation-owned paints from the aggregate before
  /// computing the rate. When the residual rate falls
  /// below threshold, the issue is suppressed: the aggregate "noise" was
  /// fully accounted for by intentional animations.
  ///
  /// Reads [DebugSnapshot.totalAnimationOwnedPaintCount] which the
  /// coordinator increments per-paint via [isAnimationOwnedPaint]
  /// (chain + bounded descendant walk). Note that paints dropped by
  /// the coordinator's 200-type cap or those without a `DebugCreator`
  /// still increment `totalPaintCount` but are NOT counted as owned —
  /// they fall into the residual, which is the conservative direction
  /// (we'd rather over-fire on the aggregate than silently mask).
  void _evaluateDebugData(DebugSnapshot snapshot) {
    final ownedCount = snapshot.totalAnimationOwnedPaintCount;
    final residualCount = snapshot.totalPaintCount - ownedCount;
    if (residualCount <= 0) return;

    final us = snapshot.elapsed.inMicroseconds;
    if (us == 0) return;
    final residualRate = residualCount / (us / Duration.microsecondsPerSecond);
    if (residualRate < paintFrequencyThreshold) return;

    final elapsedSec = us / Duration.microsecondsPerSecond;
    final (hint, effort) = FixHintBuilder.excessiveRepaintDebug();

    final ownedSuffix =
        ownedCount > 0 ? ' Excludes $ownedCount animation-owned paints.' : '';

    _issues.add(PerformanceIssue(
      stableId: 'excessive_repaint_debug',
      severity: residualRate > paintFrequencyThreshold * 2
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.paint,
      confidence: IssueConfidence.likely,
      title: 'Excessive Repainting: ~${residualRate.round()} paints/sec',
      detail: '$residualCount paint calls in '
          '${elapsedSec.toStringAsFixed(1)}s '
          '(~${residualRate.round()}/sec, aggregate debug callback count).'
          '$ownedSuffix',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.debugCallback,
      detectedAt: DateTime.now(),
      confidenceReason: 'Aggregate debug callback count + structural scan '
          '(animation-owned paints excluded)',
    ));
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _pendingEnrichedDirtyTotal = 0;
    _stagedEnrichedDirtyTotal = null;
    _pendingDebugSnapshot = null;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Hybrid detector. All three families pinned: '
            '`excessive_repaint` (>30 paints/sec aggregate), '
            '`excessive_repaint_debug` (debug-callback corroborated '
            'residual), and parametric `repaint_debug_<typeName>` '
            '(per-widget attribution, declared via `parametricFamilies` '
            'since v0.17.3 — concrete `repaint_debug_CustomPaint` credits '
            'the family via the `_` separator matcher). VM → '
            'TimelineParser → detector boundary exercised via '
            'cross-harness reproducer (raw `List<TimelineEvent>` through '
            '`parseAndAssertShape` + real `pumpWidget` for the debug + '
            'structural legs). Animation-owner Gate B suppression pinned '
            'with broad `expect(issues, isEmpty)` so a regression cannot '
            'leak through any of the three emission paths. The VM-path '
            '`excessive_repaint.warning` family is runtime-verified via '
            '`additionalBrackets[0]` with three iPhone 12 / iOS 17.5 / '
            'Flutter 3.41.4 captures driven by 32 distinct CustomPainter '
            'types so the per-widget debug gate stays sub-threshold and '
            'emission flows through the VM aggregate path; `peakObserved'
            'PaintCount` populates `expectedMagnitude.observed` so the '
            'audit-gate `\'max\'` axis reduction matches the emitted '
            'observedPaintCount. atTolerance 0.50 (at-band [30, 45]) '
            'absorbs iOS animation-tick scheduler jitter at 60 Hz '
            'mirroring the request_frequency tolerance. '
            '`excessive_repaint_debug` and `repaint_debug_<typeName>` '
            'remain reproducerOnly — no per-widget debug-path captures.',
        reproducerPath: 'test/validation/repaint_reproducer_test.dart',
        coveredStableIds: {'excessive_repaint', 'excessive_repaint_debug'},
        parametricFamilies: {'repaint_debug'},
        perStableIdTier: {'excessive_repaint': EvidenceTier.runtimeVerified},
        coveredThresholds: {'excessive_repaint.warning'},
        profileCapturePaths: [
          'test/validation/captures/repaint/excessive_repaint_below.json',
          'test/validation/captures/repaint/excessive_repaint_at.json',
          'test/validation/captures/repaint/excessive_repaint_above.json',
        ],
        bracketThreshold: 30,
        bracketUnit: 'paints',
        bracketStableId: 'excessive_repaint',
        bracketSeverityLabel: 'warning',
        bracketAtTolerance: 0.50,
        aboveCeilingMultiplier: 2.0,
        observedAxisArgKey: 'observedPaintCount',
        observedAxisTolerance: 0.15,
        observedAxisReduction: 'max',
      );
}
