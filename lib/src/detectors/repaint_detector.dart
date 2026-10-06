import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/phase_event.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/monotonic_clock.dart';
import '../utils/rate_hysteresis.dart';
import '../utils/widget_location.dart';
import '../vm/timeline_parser.dart';

/// Detects expensive repainting using VM Timeline PAINT scopes or debug
/// callback paint counts.
///
/// **Hybrid Detector** — the VM timeline measures the share of UI-thread
/// wall time spent inside PAINT scopes over each ~1 s window
/// (`excessive_repaint`, confirmed confidence). Debug callbacks provide
/// per-widget likely repaint origins (`repaint_debug_<type>`, likely
/// confidence) and an aggregate paint rate fallback
/// (`excessive_repaint_debug`, likely confidence).
///
/// Data sources accumulate into staging fields; the single [_evaluate]
/// method is the ONLY writer of [_issues]. Called from [scanTree] (scan
/// tick) and [evaluateNow] (timeline tick).
class RepaintDetector extends BaseDetector with DetectorMetadataProvider {
  RepaintDetector({
    this.paintFrequencyThreshold = 30,
    this.paintTimePercentThreshold = 10,
    bool captureMode = false,
    DateTime Function()? clock,
  }) : assert(
         paintTimePercentThreshold > 0 && paintTimePercentThreshold <= 100,
         'paintTimePercentThreshold must be above 0 and at most 100.',
       ),
       _captureMode = captureMode,
       _clock = clock ?? monotonicClock(),
       super(
         type: DetectorType.repaint,
         lifecycle: DetectorLifecycle.hybrid,
         name: 'Repaint',
         description:
             'Detects paint work above 10% of UI-thread time (VM) or '
             'widgets that start more than 30 repaints per second (debug)',
       ) {
    _windowStart = _clock();
  }

  /// Per-widget origin rate (repaints per second one instance started)
  /// and debug-aggregate paints per second above which the debug-callback
  /// paths fire; critical above 2×. Does not gate the VM time-share axis.
  final int paintFrequencyThreshold;

  /// A per-widget origin rate above this many times
  /// [paintFrequencyThreshold] is critical.
  static const int debugCriticalMultiplier = 2;

  /// Share of UI-thread wall time, in percent, spent inside PAINT scopes
  /// over a ~1 s window above which `excessive_repaint` fires. Critical
  /// above 3× this value. Default mirrors
  /// `DetectorThresholds.paintTimePercentThreshold`.
  final double paintTimePercentThreshold;
  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];

  /// Capture mode reports each VM window as measured: no display hold, so
  /// a leg's issues never outlast it.
  final bool _captureMode;

  /// Issues from the held per-widget types, else the latest snapshot's
  /// debug aggregate, rebuilt with each snapshot. Snapshots arrive with
  /// each scan (every 1-5 s) and VM windows every ~1 s, so each source's
  /// issues are kept between its own updates and [_issues] is rebuilt
  /// from both on every evaluation.
  final List<PerformanceIssue> _debugIssues = [];

  /// The VM share's issue on display, if any ([_vmHeld]).
  final List<PerformanceIssue> _vmIssues = [];

  /// Per-widget origin rates (the busiest instance of each type), held
  /// across scans so a widget repainting at the threshold does not flip
  /// on and off.
  final RateHysteresis _perWidget = RateHysteresis();

  /// Gate B for the latest snapshot: every paint in it, framework paints
  /// included, was animation-owned, so the VM share is not shown.
  bool _debugAllOwned = false;

  /// The last `excessive_repaint` issue, shown until the paint share
  /// stays under [vmExitFactor] times the threshold for two windows
  /// (never in capture mode). Every window above the threshold emits a
  /// new issue.
  PerformanceIssue? _vmHeld;
  int _vmQuietWindows = 0;
  int _vmBelowCriticalWindows = 0;

  /// Fraction of [paintTimePercentThreshold] the paint share must stay
  /// under for two windows before a shown `excessive_repaint` clears.
  static const double vmExitFactor = 0.8;

  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  /// PAINT scope time accumulated in the open window, in microseconds.
  int _paintTimeUs = 0;
  late DateTime _windowStart;

  /// Paint-time share of the most recently closed window (or the partial
  /// window closed by [flushPaintEvaluation]), refreshed before the
  /// threshold gate so a sub-threshold leg's exported magnitude reflects
  /// what the detector measured, not the operator's plan.
  double _lastObservedPaintPercent = 0;

  /// Peak paint-time share since the last [resetCaptureState]. Moves only
  /// on the natural window-close path (elapsed ≥ 1 s), the same value the
  /// emission stamps as `observedPaintPercent`.
  double _peakObservedPaintPercent = 0;

  /// Share of UI-thread wall time, in percent, spent inside PAINT scopes
  /// in the most recently closed window. Capture-mode operators export
  /// this for sub-threshold legs where no `excessive_repaint` issue fires.
  double get lastObservedPaintPercent => _lastObservedPaintPercent;

  /// Highest paint-time share seen across naturally closed ~1 s windows
  /// since the last [resetCaptureState]. Use for capture-mode magnitude
  /// export so the value matches the audit gate's `'max'` axis reduction.
  /// Returns 0 if no window has closed since reset.
  double get peakObservedPaintPercent => _peakObservedPaintPercent;

  // -- Staging fields (nullable = no fresh data) --

  /// Paint-time share (percent) of the most recently closed VM window.
  /// null = no VM window completed since last evaluate.
  double? _pendingVmWindowPercent;

  /// null = no new snapshot delivered since last evaluate.
  DebugSnapshot? _pendingDebugSnapshot;

  /// Staged debug snapshot not yet consumed by a scan (for testing).
  @visibleForTesting
  DebugSnapshot? get pendingDebugSnapshotForTest => _pendingDebugSnapshot;

  /// Dirty RenderObject count from enriched timeline args, accumulating
  /// across timeline ticks until the next 1s window completes.
  int _pendingEnrichedDirtyTotal = 0;

  /// Enriched dirty count staged atomically with [_pendingVmWindowPercent].
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
      _paintTimeUs = 0;
      _pendingVmWindowPercent = null;
      _vmHeld = null;
      _vmQuietWindows = 0;
      _vmBelowCriticalWindows = 0;
      _vmIssues.clear();
      // Nothing else recomposes without debug snapshots, so the VM card
      // would outlive the connection.
      if (wasConnected) _compose();
      _pendingEnrichedDirtyTotal = 0;
      _stagedEnrichedDirtyTotal = null;
      // Capture-mode observables also clear on disconnect so a leg
      // straddling a VM disconnect cannot export a stale peak from
      // before the drop. Reconnected post-disconnect runs accumulate
      // a fresh peak from the new windows.
      _lastObservedPaintPercent = 0;
      _peakObservedPaintPercent = 0;
    } else if (!wasConnected) {
      // Reconnect: stage a fresh-zero so the next _evaluate() flushes
      // stale debug issues that are incompatible with VM mode. The window
      // restarts so its elapsed time excludes the disconnect.
      _pendingVmWindowPercent = 0;
      _windowStart = _clock();
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

  /// Process VM timeline data for PAINT scope time.
  ///
  /// Accumulates PAINT scope durations and enriched dirty totals into
  /// pending buffers. When at least 1 s has elapsed on the detector clock,
  /// the window closes: its paint time divided by the measured elapsed
  /// time (windows close at poll arrival and can run 1.0–1.5 s) is staged
  /// with the enrichment atomically for [_evaluate].
  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    _paintTimeUs += data.totalFlushPaintUs;

    // Accumulate enriched dirty counts from this batch
    for (final event in data.phaseEvents) {
      if (event.phase == TimelinePhase.paint && event.dirtyCount != null) {
        _pendingEnrichedDirtyTotal += event.dirtyCount!;
      }
    }

    final now = _clock();
    final elapsedUs = now.difference(_windowStart).inMicroseconds;
    if (elapsedUs >= Duration.microsecondsPerSecond) {
      // Clamped: a mis-paired or nested scope could otherwise credit more
      // phase time than the window holds.
      final percent = (_paintTimeUs / elapsedUs * 100).clamp(0.0, 100.0);
      _pendingVmWindowPercent = percent;
      // Refresh capture-mode observables on every window close — before
      // _evaluateVmData's threshold guard so sub-threshold legs still
      // expose a measurement. The emission for this window stamps the
      // same value as `observedPaintPercent`.
      _lastObservedPaintPercent = percent;
      if (percent > _peakObservedPaintPercent) {
        _peakObservedPaintPercent = percent;
      }
      // Stage enrichment atomically with the window share
      _stagedEnrichedDirtyTotal = _pendingEnrichedDirtyTotal > 0
          ? _pendingEnrichedDirtyTotal
          : null;
      _pendingEnrichedDirtyTotal = 0;
      _paintTimeUs = 0;
      _windowStart = now;
    }
  }

  /// Forces an immediate close of the in-flight VM window so capture
  /// tooling can read [lastObservedPaintPercent] without waiting for the
  /// window timer. The partial window's share is its paint time over its
  /// own elapsed time. Idempotent — re-running with no new paint time
  /// preserves the prior values. Pure observable refresh; does not emit
  /// issues (issue emission is owned by [_evaluateVmData], reached via
  /// [_evaluate], which only runs from the scan pipeline).
  ///
  /// Updates only [lastObservedPaintPercent], never
  /// [peakObservedPaintPercent]. The peak is restricted to naturally
  /// closed windows (elapsed ≥ 1 s), the ones whose value is stamped on
  /// an emission as `observedPaintPercent`, so a short partial tail can
  /// never become the exported magnitude and the audit gate's `'max'`
  /// cross-check on emission records stays honest.
  void flushPaintEvaluation() {
    if (_paintTimeUs <= 0) return;
    final now = _clock();
    final elapsedUs = now.difference(_windowStart).inMicroseconds;
    if (elapsedUs <= 0) return;
    // The partial window refreshes the observable only; it is never
    // staged for evaluation, so no emission can carry a value the peak
    // did not see.
    _lastObservedPaintPercent = (_paintTimeUs / elapsedUs * 100).clamp(
      0.0,
      100.0,
    );
    _pendingEnrichedDirtyTotal = 0;
    _paintTimeUs = 0;
    _windowStart = now;
  }

  /// Clears all per-leg accumulator state so capture screens can
  /// re-enter a fresh below/at/above leg without leakage from the
  /// prior leg's paint time, debug snapshot, or pending issues, and
  /// restarts the window clock. `_vmConnected` is owned by the
  /// controller and intentionally left untouched.
  void resetCaptureState() {
    _paintTimeUs = 0;
    _pendingVmWindowPercent = null;
    _lastObservedPaintPercent = 0;
    _peakObservedPaintPercent = 0;
    _pendingEnrichedDirtyTotal = 0;
    _stagedEnrichedDirtyTotal = null;
    _pendingDebugSnapshot = null;
    _windowStart = _clock();
    _issues.clear();
    _clearHeld();
    _highlights.clear();
    _hotInstances.clear();
  }

  /// The origin instances to outline in this scan: the busiest instances
  /// of each held type, with their own rate in the snapshot window.
  final Map<Element, ({String type, double rate, bool critical})>
  _hotInstances = {};

  @override
  void prepareScan(BuildContext context) {
    _highlights.clear();
    _hotInstances.clear();

    // Hot instances come from the held types, the same set the issues
    // use, so the boxes don't blink while the cards stay. Only the
    // instances that started the repaints are outlined, never other
    // instances of the type that happen to be in the tree.
    final snapshot = _pendingDebugSnapshot;
    if (snapshot == null) return;
    final seconds =
        snapshot.elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    for (final MapEntry(key: type, value: held) in _perWidget.held.entries) {
      final origins = snapshot.paintOrigins[type];
      if (origins == null) continue;
      for (final instance in origins.busiest) {
        final element = instance.element;
        if (element == null || !element.mounted) continue;
        _hotInstances[element] = (
          type: type,
          rate: seconds > 0 ? instance.count / seconds : held.rate,
          critical: held.critical,
        );
      }
    }
  }

  @override
  void checkElement(Element element) {
    if (_hotInstances.isEmpty) return;
    final hot = _hotInstances[element];
    if (hot == null) return;
    final ro = element.renderObject;
    if (ro == null) return;
    final rect = getGlobalRect(ro);
    if (rect == null) return;
    _highlights.add(
      WidgetHighlight(
        rect: rect,
        renderObject: ro,
        widgetName: hot.type,
        severity: hot.critical ? IssueSeverity.critical : IssueSeverity.warning,
        detectorName: 'Repaint',
        detail: 'likely repaint origin, ${hot.rate.round()}/sec',
      ),
    );
  }

  @override
  void finalizeScan() {
    _evaluate();
  }

  @override
  void updateDebugSnapshot(DebugSnapshot snapshot) {
    _pendingDebugSnapshot = snapshot;
    final us = snapshot.elapsed.inMicroseconds;
    // Gate A: a type's rate is its busiest instance's origin count, which
    // already leaves out frames an animation owner drove. Instances are
    // never summed, so forty widgets of one type at 10/sec each read as
    // 10/sec.
    _perWidget.update(
      counts: {
        for (final MapEntry(key: type, value: origins)
            in snapshot.paintOrigins.entries)
          if (origins.maxCount > 0) type: origins.maxCount,
      },
      elapsedUs: us,
      capped: snapshot.paintOriginTypesCapped,
      thresholdFor: (_) => paintFrequencyThreshold.toDouble(),
      criticalMultiplier: debugCriticalMultiplier.toDouble(),
    );
    // Gate B — the VM share is not shown while *every* paint in the
    // window, framework paints included, was animation-owned. The
    // per-widget maps hold only user widgets, so they cannot tell.
    _debugAllOwned =
        _perWidget.held.isEmpty &&
        snapshot.totalPaintCount > 0 &&
        snapshot.totalAnimationOwnedPaintCount >= snapshot.totalPaintCount;
  }

  /// Starts over at a route change or hot reload: drops the held debug
  /// types and VM issue and restarts the open VM window, so evidence from
  /// the previous screen is neither shown nor mixed into the next window.
  void markRouteEpoch() {
    _paintTimeUs = 0;
    _pendingVmWindowPercent = null;
    _pendingEnrichedDirtyTotal = 0;
    _stagedEnrichedDirtyTotal = null;
    _pendingDebugSnapshot = null;
    _windowStart = _clock();
    _clearHeld();
    _compose();
  }

  /// Drops the held debug types, for a scan that could not run: the
  /// counts it drained are gone, and the types held from earlier scans
  /// belong to a page that may no longer be shown.
  void discardDebugEvidence() {
    _pendingDebugSnapshot = null;
    _perWidget.reset();
    _debugIssues.clear();
    _debugAllOwned = false;
    _compose();
  }

  @override
  void evaluateNow() => _evaluate();

  /// The ONLY method that writes [_issues] from fresh data.
  ///
  /// Priority: debug per-widget > VM aggregate > debug aggregate.
  /// Per-widget paint attribution is more actionable than aggregate counts.
  /// A fresh debug snapshot rebuilds [_debugIssues] from the held types
  /// (else the aggregate), every fresh VM window is evaluated into
  /// [_vmIssues], and [_compose] picks what is shown, so a tick of one
  /// source keeps the other source's issues. All staging is consumed so a
  /// window or snapshot is evaluated once.
  void _evaluate() {
    final vmWindowPercent = _pendingVmWindowPercent;
    final debugSnapshot = _pendingDebugSnapshot;
    final enrichedDirtyTotal = _stagedEnrichedDirtyTotal;

    final hasFreshVm = _vmConnected && vmWindowPercent != null;
    final hasFreshDebug = debugSnapshot != null;

    if (!hasFreshVm && !hasFreshDebug) return;

    // Clear ALL staging regardless of which branch wins.
    _pendingVmWindowPercent = null;
    _pendingDebugSnapshot = null;
    // Unconditional clear — prevents enrichment leaking across branches.
    _stagedEnrichedDirtyTotal = null;

    if (hasFreshDebug) {
      _debugIssues.clear();
      if (_perWidget.held.isNotEmpty) {
        _debugIssues.addAll(_perWidgetIssues(debugSnapshot));
      } else if (debugSnapshot.totalPaintCount > 0) {
        // The debug aggregate is shown only without a VM connection.
        final aggregate = _evaluateDebugData(debugSnapshot);
        if (aggregate != null) _debugIssues.add(aggregate);
      }
    }

    if (hasFreshVm) {
      // Every window is evaluated, so emissions follow the measurement
      // whatever is on display.
      final emitted = vmWindowPercent > 0
          ? _evaluateVmData(vmWindowPercent, enrichedDirtyTotal)
          : null;
      if (vmWindowPercent >= paintTimePercentThreshold * 3 * vmExitFactor) {
        _vmBelowCriticalWindows = 0;
      } else {
        _vmBelowCriticalWindows++;
      }
      if (emitted != null) {
        // A critical card stays critical until the share is under
        // [vmExitFactor] of the critical boundary for two windows; the
        // emission itself keeps its measured severity.
        final holdCritical =
            !_captureMode &&
            _vmHeld?.severity == IssueSeverity.critical &&
            emitted.severity == IssueSeverity.warning &&
            _vmBelowCriticalWindows < 2;
        _vmHeld = holdCritical
            ? emitted.copyWith(severity: IssueSeverity.critical)
            : emitted;
        _vmQuietWindows = 0;
      } else if (_vmHeld != null) {
        if (_captureMode) {
          _vmHeld = null;
        } else if (vmWindowPercent < paintTimePercentThreshold * vmExitFactor) {
          if (++_vmQuietWindows >= 2) _vmHeld = null;
        } else {
          _vmQuietWindows = 0;
        }
      }
      _vmIssues
        ..clear()
        ..addAll([?_vmHeld]);
    }

    _compose();
  }

  /// Rebuilds [_issues]: held per-widget issues win, then the VM share
  /// while connected (unless Gate B holds), then the debug aggregate.
  void _compose() {
    _issues.clear();
    if (_perWidget.held.isNotEmpty) {
      _issues.addAll(_debugIssues);
    } else if (_vmConnected) {
      if (!_debugAllOwned) _issues.addAll(_vmIssues);
    } else {
      _issues.addAll(_debugIssues);
    }
  }

  void _clearHeld() {
    _perWidget.reset();
    _debugIssues.clear();
    _debugAllOwned = false;
    _vmHeld = null;
    _vmQuietWindows = 0;
    _vmBelowCriticalWindows = 0;
    _vmIssues.clear();
  }

  /// VM timeline path — share of UI-thread time inside PAINT scopes.
  ///
  /// When [enrichedDirtyTotal] is available (from timeline enrichment args),
  /// appends dirty RenderObject count to the issue detail.
  PerformanceIssue? _evaluateVmData(double percent, [int? enrichedDirtyTotal]) {
    if (percent <= paintTimePercentThreshold) return null;

    final detailSuffix = enrichedDirtyTotal != null && enrichedDirtyTotal > 0
        ? '\n$enrichedDirtyTotal dirty RenderObjects '
              '(from timeline enrichment).'
        : '';

    final formatted = percent.toStringAsFixed(1);
    final (hint, effort) = FixHintBuilder.excessiveRepaintVm(
      paintPercent: percent,
    );

    final threshold = _formatPercent(paintTimePercentThreshold);
    final detectedAt = DateTime.now();
    return PerformanceIssue(
      stableId: 'excessive_repaint',
      severity: percent > paintTimePercentThreshold * 3
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.paint,
      confidence: IssueConfidence.confirmed,
      title: 'Excessive Repainting: paint phase $formatted% of UI time',
      detail:
          'Painting (PAINT scopes on the UI thread) took $formatted% of '
          'wall time in the last window of about 1 s (threshold '
          '$threshold%).'
          '$detailSuffix',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: detectedAt,
      // Audit gate cross-checks `expectedMagnitude.observed` against
      // this detector-side measurement so a regression in window
      // accounting cannot certify the wrong magnitude.
      dedupIdentityMicros: detectedAt.microsecondsSinceEpoch,
      extraTraceArgs: {'observedPaintPercent': formatted},
      confidenceReason: 'Measured directly from VM timeline PAINT durations',
    );
  }

  static String _formatPercent(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

  /// Debug callback path: per-widget likely repaint origins.
  ///
  /// The coordinator reads, in each frame, which painted render objects
  /// were marked as needing paint and credits the deepest marked one of
  /// each layer to the nearest widget the app created
  /// ([DebugSnapshot.paintOrigins]). Widgets that repaint only because
  /// they share that layer are not counted, so one animating painter
  /// yields one card, not one per widget around it.
  ///
  /// **Gate A: animation-owned origins.** Each origin is judged on its
  /// live element for an active animation owner; owned frames are left
  /// out of the instance counts and disclosed in the detail line.
  ///
  /// The held types come from [RateHysteresis] over the busiest
  /// instance's count; the instance count and owned share in the detail
  /// are the latest window's.
  List<PerformanceIssue> _perWidgetIssues(DebugSnapshot snapshot) => [
    for (final MapEntry(key: typeName, value: held) in _perWidget.held.entries)
      _perWidgetIssue(typeName, held, snapshot),
  ];

  PerformanceIssue _perWidgetIssue(
    String typeName,
    HeldRate held,
    DebugSnapshot snapshot,
  ) {
    final rate = held.rate;
    final origins = snapshot.paintOrigins[typeName];
    final instances = origins?.instanceCount ?? 1;
    final ownedCount = origins?.animationOwnedCount ?? 0;
    final chain = origins?.ancestorChain ?? snapshot.ancestorChains[typeName];
    final (hint, effort) = FixHintBuilder.repaintDebugType(
      typeName: typeName,
      rate: rate.round(),
      ancestorChain: chain,
    );
    final instanceNote = instances > 1
        ? ' (the busiest of $instances instances)'
        : '';
    final ownedSuffix = ownedCount > 0
        ? ' Excludes $ownedCount animation-owned repaint'
              '${ownedCount == 1 ? '' : 's'} in the last window.'
        : '';
    return PerformanceIssue(
      stableId: 'repaint_debug_$typeName',
      severity: held.critical ? IssueSeverity.critical : IssueSeverity.warning,
      category: IssueCategory.paint,
      // Whether the widget repainted is observed, but naming it as the
      // origin is a heuristic: the deepest node marked as needing paint
      // is where a repaint likely started, and an ancestor that marked
      // itself in the same frame cannot be told apart from one its child
      // marked. So the card is likely, not confirmed.
      confidence: IssueConfidence.likely,
      title: 'Likely Repaint Origin: $typeName (${rate.round()}/sec)',
      detail:
          '$typeName$instanceNote was the likely origin of '
          '${held.count} repaints in ${held.seconds.toStringAsFixed(1)}s '
          '(${rate.round()}/sec). It was the deepest widget marked as '
          'needing paint in its layer. The count leaves out widgets that '
          'only repainted because they share that layer.$ownedSuffix',
      fixHint: hint,
      fixEffort: effort,
      widgetName: typeName,
      ancestorChain: chain,
      observationSource: ObservationSource.debugCallback,
      detectedAt: DateTime.now(),
      confidenceReason: ownedCount > 0
          ? 'Debug paint callbacks name the deepest widget marked as '
                'needing paint in its layer, a likely origin rather than a '
                'measured cause (animation-owned repaints excluded)'
          : 'Debug paint callbacks name the deepest widget marked as '
                'needing paint in its layer, a likely origin rather than a '
                'measured cause',
    );
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
  PerformanceIssue? _evaluateDebugData(DebugSnapshot snapshot) {
    final ownedCount = snapshot.totalAnimationOwnedPaintCount;
    final residualCount = snapshot.totalPaintCount - ownedCount;
    if (residualCount <= 0) return null;

    final us = snapshot.elapsed.inMicroseconds;
    if (us == 0) return null;
    final residualRate = residualCount / (us / Duration.microsecondsPerSecond);
    if (residualRate < paintFrequencyThreshold) return null;

    final elapsedSec = us / Duration.microsecondsPerSecond;
    final (hint, effort) = FixHintBuilder.excessiveRepaintDebug();

    final ownedSuffix = ownedCount > 0
        ? ' Excludes $ownedCount animation-owned paints.'
        : '';

    return PerformanceIssue(
      stableId: 'excessive_repaint_debug',
      severity: residualRate > paintFrequencyThreshold * debugCriticalMultiplier
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.paint,
      confidence: IssueConfidence.likely,
      title: 'Excessive Repainting: ~${residualRate.round()} paints/sec',
      detail:
          '$residualCount paint calls in '
          '${elapsedSec.toStringAsFixed(1)}s '
          '(about ${residualRate.round()}/sec, from the aggregate debug '
          'callback count).'
          '$ownedSuffix',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.debugCallback,
      detectedAt: DateTime.now(),
      confidenceReason:
          'Aggregate debug callback count and a structural scan '
          '(animation-owned paints excluded)',
    );
  }

  @override
  void dispose() {
    _issues.clear();
    _clearHeld();
    _highlights.clear();
    _pendingEnrichedDirtyTotal = 0;
    _stagedEnrichedDirtyTotal = null;
    _pendingDebugSnapshot = null;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hybrid detector. The reproducer pins all three families. '
        '`excessive_repaint` measures the share of UI-thread wall time '
        'spent inside VM-timeline PAINT scopes over each window of about 1 '
        's, normalised by the measured window length. It warns above '
        '`paintTimePercentThreshold` (default 10 %) and is critical above 3 '
        'times that (30 %). `excessive_repaint_debug` is the debug-callback '
        'aggregate paint rate, with animation-owned paints excluded. The '
        'parametric `repaint_debug_<typeName>` family compares per-instance '
        'likely-origin repaints/sec against `paintFrequencyThreshold`. The '
        'likely origin is the deepest node marked as needing paint in each '
        'layer, credited to the nearest app-created widget. The family is '
        'declared via `parametricFamilies`, so a concrete '
        '`repaint_debug_CustomPaint` credits the family through the `_` '
        'separator matcher. A cross-harness reproducer exercises the '
        'boundary from the VM through TimelineParser to the detector (raw '
        '`List<TimelineEvent>` through `parseAndAssertShape`, and a real '
        '`pumpWidget` for the debug and structural legs). A broad '
        '`expect(issues, isEmpty)` pins animation-owner Gate B suppression, '
        'so a regression cannot leak through any of the three emission '
        'paths. `excessive_repaint.warning` is runtimeVerified via three '
        'iPhone 12, iOS 17.5, Flutter 3.47.x captures. Their workload '
        'varies paint cost per frame with 32 distinct CustomPainter types '
        'that repaint through a shared per-frame notifier, so BUILD stays '
        'flat and the per-widget debug gate stays below its threshold. A '
        'calibration pre-pass scales the paint operations to the leg '
        'target. `peakObservedPaintPercent` moves only when a window closes '
        'on its own and populates `expectedMagnitude.observed`, so the '
        'audit-gate `\'max\'` axis reduction matches the emitted '
        '`observedPaintPercent`. atTolerance 0.5 and observedAxisTolerance '
        '0.25 absorb thermal drift in paint duration across a leg. '
        '`excessive_repaint_debug` and `repaint_debug_<typeName>` remain '
        'reproducerOnly, because there are no per-widget debug-path '
        'captures. While a screen reader is on, the debug paint counts '
        'leave out the framework\'s semantics-only widgets (`Semantics`, '
        '`MergeSemantics`, `_GestureSemantics`, ...), which repaint as '
        'pass-throughs. The VM PAINT axis is unchanged.',
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
    bracketThreshold: 10,
    bracketUnit: 'percent',
    bracketStableId: 'excessive_repaint',
    bracketSeverityLabel: 'warning',
    bracketAtTolerance: 0.5,
    aboveCeilingMultiplier: 2.7,
    observedAxisArgKey: 'observedPaintPercent',
    observedAxisTolerance: 0.25,
    observedAxisReduction: 'max',
  );
}
