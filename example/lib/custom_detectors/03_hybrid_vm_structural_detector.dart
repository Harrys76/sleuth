// ignore_for_file: file_names
// The cookbook files are numbered to suggest a reading order. See
// `01_simple_structural_detector.dart` for the full rationale.

import 'package:flutter/widgets.dart';
import 'package:sleuth/sleuth.dart';

/// Cookbook 03 — The hybrid VM + structural detector.
///
/// Combines VM timeline data with a tree walk. When the raster thread
/// exceeds a millisecond budget, the detector walks the current tree to
/// find [Stack] widgets with many children, which are a common source of
/// raster pressure. The emitted issue reports both the VM measurement and
/// the structural candidates.
///
/// This is the most complex custom-detector shape. It uses all four
/// [BaseDetector] lifecycle methods plus [processTimelineData]:
///
/// ```
///   VM batch arrives ─▶ processTimelineData ─▶ stash raster budget
///
///                       scan tick
///                         │
///                         ▼
///                       prepareScan ─▶ checkElement (×N) ─▶ finalizeScan
///                         │                 │                    │
///                    clear state      tally Stacks         publish issues
///                                     if raster > budget
/// ```
///
/// Shape highlights to note when you copy this file:
///
/// 1. **`DetectorLifecycle.hybrid`** — declares that this detector needs
///    BOTH VM data and the structural walk. The controller automatically
///    degrades to "structural only" behaviour when the VM service is not
///    connected; see [vmConnected] for the degradation hook.
/// 2. **Cross-method state** — `_lastRasterUs` is written in
///    [processTimelineData] (called on VM batches, off the scan loop) and
///    read in [checkElement]. Guard every cross-method field against stale
///    state; see [vmConnected].
/// 3. **Lazy work in `checkElement`** — the per-element tally only runs
///    when the VM batch said "raster is hot". On cold scans we return
///    immediately after the type check so the walk stays allocation-free.
/// 4. **Confidence downgrade on VM disconnect** — when VM data is
///    unavailable, the finding is still useful but less certain, so the
///    emitted issue uses [IssueConfidence.possible] instead of `likely`.
///
/// Use this shape when:
///
/// - Your detector is strongest when VM + structural signals agree.
/// - You want graceful degradation when the VM service isn't connected.
/// - You need to correlate "what the timeline says" with "what the tree
///   looks like right now".
class RasterHotSpotDetector extends BaseDetector {
  RasterHotSpotDetector({this.rasterBudgetMs = 8, this.stackChildLimit = 8})
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.hybrid,
        name: 'Raster Hot Spot',
        description:
            'Flags wide Stack subtrees when raster thread exceeds '
            '$rasterBudgetMs ms',
        key: 'raster_hot_spot',
      );

  /// If the latest VM batch reported raster time above this threshold,
  /// the structural walk activates. 8 ms leaves half a 16.67 ms budget
  /// for the UI thread.
  final int rasterBudgetMs;

  /// Stacks with this many or more children are considered "wide" and
  /// become a candidate for the raster hot-spot report.
  final int stackChildLimit;

  final List<PerformanceIssue> _issues = [];
  final List<_WideStack> _candidates = [];
  bool _isEnabled = true;
  bool _vmConnected = false;
  int _lastRasterUs = 0;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Clear VM-derived state when the VM service disconnects, and make
  /// sure the issues emitted on the next scan reflect the new confidence
  /// level ("possible" instead of "likely").
  @override
  set vmConnected(bool value) {
    _vmConnected = value;
    if (!value) {
      _lastRasterUs = 0;
    }
  }

  /// VM batch consumer. Called off the scan loop whenever a timeline
  /// batch arrives from vm_service. Do NOT do tree work here — there is
  /// no context and the element tree may be mid-frame.
  ///
  /// We track the **peak** (max) raster duration in the batch, not the
  /// sum. A batch typically contains ~10 frames of data; summing them
  /// would compare "total raster time across 10 frames" against a
  /// per-frame budget, which trips at ~10× the intended threshold and
  /// produces a flood of false positives on perfectly healthy apps.
  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;
    if (data.rasterDurations.isEmpty) return;
    _lastRasterUs = data.rasterDurations.fold<int>(
      0,
      (peak, current) => current > peak ? current : peak,
    );
  }

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _candidates.clear();
  }

  /// Per-element inspection. Runs once per element in depth-first order
  /// during the unified tree walk. Keep this fast — it's on the hot path.
  @override
  void checkElement(Element element) {
    if (!_isEnabled) return;
    if (element.widget is! Stack) return;

    // Count direct children of the Stack. We use visitChildElements
    // (not recursive descent) so we only count the Stack's own layers,
    // not the entire transitive subtree.
    var childCount = 0;
    element.visitChildElements((_) => childCount++);
    if (childCount < stackChildLimit) return;

    _candidates.add(_WideStack(childCount: childCount));
  }

  @override
  void finalizeScan() {
    if (!_isEnabled) return;
    if (_candidates.isEmpty) return;

    // VM data is authoritative when available. If raster was cheap in
    // the latest batch, this scan's structural candidates don't rise to
    // the level of a reported issue.
    final rasterMs = _lastRasterUs ~/ 1000;
    final rasterIsHot = _vmConnected && rasterMs >= rasterBudgetMs;
    if (_vmConnected && !rasterIsHot) return;

    final worst = _candidates
        .map((c) => c.childCount)
        .fold<int>(0, (max, current) => current > max ? current : max);

    final confidence = _vmConnected
        // VM saw raster pressure AND the structural walk found candidates.
        ? IssueConfidence.likely
        // No VM — structural-only evidence is the best we can offer.
        : IssueConfidence.possible;

    _issues.add(
      PerformanceIssue(
        stableId: 'raster_hot_spot',
        severity: IssueSeverity.warning,
        category: IssueCategory.raster,
        confidence: confidence,
        title:
            '${_candidates.length} wide Stack subtree'
            '${_candidates.length == 1 ? '' : 's'} '
            '(worst: $worst children)',
        detail: _vmConnected
            ? 'Raster thread used ${rasterMs}ms in the latest timeline '
                  'batch (budget: ${rasterBudgetMs}ms) and ${_candidates.length} '
                  'Stack widget${_candidates.length == 1 ? '' : 's'} with '
                  '$stackChildLimit+ children were found in the current '
                  'frame.'
            : 'VM timeline not connected — reporting structural evidence '
                  'only. ${_candidates.length} Stack widget'
                  '${_candidates.length == 1 ? '' : 's'} with '
                  '$stackChildLimit+ children were found in the current '
                  'frame. Connect the VM service for raster confirmation.',
        fixHint:
            'Wide Stack subtrees force the GPU to composite many layers. '
            'Consider flattening into a single Container with a '
            'BackdropFilter, or use RepaintBoundary on the stable '
            'children so the raster cache can reuse them.',
        observationSource: _vmConnected
            ? ObservationSource.vmTimeline
            : ObservationSource.structural,
        detectedAt: DateTime.now(),
      ),
    );
  }

  @override
  void dispose() {
    _issues.clear();
    _candidates.clear();
  }
}

/// Intermediate struct used during the tree walk so we don't allocate
/// [PerformanceIssue] instances for Stacks that turn out to be cheap.
class _WideStack {
  const _WideStack({required this.childCount});
  final int childCount;
}
