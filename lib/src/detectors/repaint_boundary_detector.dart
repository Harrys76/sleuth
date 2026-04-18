import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/type_name_cache.dart';
import '../utils/widget_location.dart';

/// Detects expensive GPU widgets without a [RepaintBoundary] ancestor.
///
/// **Structural Detector** — walks the element tree for [Opacity],
/// [ClipPath], [BackdropFilter], [ShaderMask], and [CustomPaint] widgets,
/// then checks the render tree for a [RenderRepaintBoundary] within
/// [maxAncestorDepth] parent levels. Missing boundaries allow repaints to
/// propagate up the tree unnecessarily.
class RepaintBoundaryDetector extends BaseDetector
    with DetectorMetadataProvider {
  RepaintBoundaryDetector({this.maxAncestorDepth = 5})
      : super(
          type: DetectorType.repaintBoundary,
          lifecycle: DetectorLifecycle.structural,
          name: 'RepaintBoundary',
          description: 'Detects expensive GPU widgets without RepaintBoundary',
        );

  final int maxAncestorDepth;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  final List<String> _found = [];
  final List<String> _typeNames = [];
  bool _isEnabled = true;
  DebugSnapshot? _lastDebugSnapshot;

  /// Threshold: flag when a single scrollable has more boundaries than this.
  static const _excessiveBoundaryThreshold = 20;

  /// Stack tracking RepaintBoundary counts per scrollable ancestor.
  /// Pushed on scrollable entry, popped on afterElement.
  final List<int> _scrollableBoundaryStack = [];

  /// Accumulated excessive-boundary findings for finalizeScan.
  final List<({int count, String location})> _excessiveFindings = [];

  @override
  void updateDebugSnapshot(DebugSnapshot snapshot) {
    _lastDebugSnapshot = snapshot;
  }

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  List<WidgetHighlight> get highlights => List.unmodifiable(_highlights);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _typeNames.clear();
    _scrollableBoundaryStack.clear();
    _excessiveFindings.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    // Track RepaintBoundary counts inside scrollables.
    // ListView/GridView with addRepaintBoundaries: true (the default) already
    // wrap each child in RepaintBoundary — these are framework-managed and
    // should not be flagged. Push -1 sentinel to skip counting for those.
    if (widget is BoxScrollView) {
      _scrollableBoundaryStack
          .add(_delegateAddsRepaintBoundaries(widget) ? -1 : 0);
    } else if (widget is CustomScrollView) {
      _scrollableBoundaryStack.add(0);
    } else if (widget is RepaintBoundary &&
        _scrollableBoundaryStack.isNotEmpty &&
        _scrollableBoundaryStack.last >= 0) {
      _scrollableBoundaryStack.last++;
    }

    if (widget is Opacity ||
        widget is ClipPath ||
        widget is BackdropFilter ||
        widget is ShaderMask ||
        widget is CustomPaint ||
        widget is ColorFiltered) {
      // Opacity at 1.0 (passthrough) or 0.0 (no paint) doesn't trigger
      // saveLayer — RepaintBoundary check unnecessary.
      if (widget is Opacity &&
          (widget.opacity >= 1.0 || widget.opacity <= 0.0)) {
        return;
      }
      final ro = element.renderObject;
      if (ro != null && !_hasRepaintBoundaryAncestor(ro)) {
        _found.add(buildAncestorChain(element));
        _typeNames.add(typeNameCache.lookup(widget));
        final rect = getGlobalRect(ro);
        if (rect != null) {
          _highlights.add(WidgetHighlight(
            rect: rect,
            widgetName: typeNameCache.lookup(widget),
            severity: IssueSeverity.warning,
            detectorName: 'RepaintBoundary',
            detail: 'No RepaintBoundary within $maxAncestorDepth ancestors',
          ));
        }
      }
    }
  }

  @override
  void afterElement(Element element) {
    final widget = element.widget;
    if (widget is BoxScrollView || widget is CustomScrollView) {
      final count = _scrollableBoundaryStack.removeLast();
      if (count > _excessiveBoundaryThreshold) {
        _excessiveFindings
            .add((count: count, location: buildAncestorChain(element)));
        final ro = element.renderObject;
        if (ro != null) {
          final rect = getGlobalRect(ro);
          if (rect != null) {
            _highlights.add(WidgetHighlight(
              rect: rect,
              widgetName: typeNameCache.lookup(widget),
              severity: IssueSeverity.warning,
              detectorName: 'RepaintBoundary',
              detail: '$count RepaintBoundary children — excessive GPU memory',
            ));
          }
        }
      }
    }
  }

  @override
  void finalizeScan() {
    if (_found.isNotEmpty) {
      final locations = _found.take(5).map((chain) => '  • $chain').join('\n');

      // Check debug snapshot for paint activity on the specific widget
      // types we found unprotected. Iterating `_typeNames.toSet()` (not
      // `_expensiveTypeNames`) prevents a cross-type confidence lift: a hot
      // Opacity elsewhere in the tree must not escalate confidence for a
      // cold unprotected CustomPaint. Only types actually present in
      // `_found` contribute.
      IssueConfidence confidence = IssueConfidence.possible;
      ObservationSource? source;
      final ds = _lastDebugSnapshot;
      if (ds != null && ds.paintCounts.isNotEmpty) {
        double maxRate = 0;
        for (final typeName in _typeNames.toSet()) {
          final rate = ds.paintsPerSecondForType(typeName);
          if (rate > maxRate) maxRate = rate;
        }
        if (maxRate > 30) {
          confidence = IssueConfidence.confirmed;
          source = ObservationSource.debugCallbackAndStructural;
        } else if (maxRate > 10) {
          confidence = IssueConfidence.likely;
          source = ObservationSource.debugCallbackAndStructural;
        }
      }

      // Determine most common widget type for fix hint context.
      final typeCounts = <String, int>{};
      for (final name in _typeNames) {
        typeCounts[name] = (typeCounts[name] ?? 0) + 1;
      }
      final dominantType =
          typeCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

      final (hint, effort) = FixHintBuilder.missingRepaintBoundary(
        widgetName: dominantType,
      );

      _issues.add(
        PerformanceIssue(
          stableId: 'missing_repaint_boundary',
          severity: _found.length > 3
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.paint,
          confidence: confidence,
          title: 'Missing RepaintBoundary: ${_found.length} expensive '
              'widget${_found.length == 1 ? '' : 's'} unprotected',
          detail: '${_found.length} GPU-expensive widget(s) found without a '
              'RepaintBoundary ancestor within $maxAncestorDepth levels. '
              'Repaints propagate up the render tree unnecessarily.'
              '\n\n$locations',
          fixHint: hint,
          fixEffort: effort,
          observationSource: source,
          confidenceReason: confidence == IssueConfidence.confirmed
              ? 'Debug callback paint rate for the unprotected widget types '
                  'confirms excessive repaints'
              : confidence == IssueConfidence.likely
                  ? 'Debug callback paint rate for the unprotected widget '
                      'types + structural GPU node scan'
                  : 'Structural scan only — enable debug callbacks for paint evidence',
          detectedAt: DateTime.now(),
        ),
      );
    }

    // Emit excessive RepaintBoundary issues
    for (final finding in _excessiveFindings) {
      final (exHint, exEffort) = FixHintBuilder.excessiveRepaintBoundary(
        boundaryCount: finding.count,
        ancestorChain: finding.location,
      );
      _issues.add(
        PerformanceIssue(
          stableId: 'excessive_repaint_boundary',
          severity: IssueSeverity.warning,
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
          title: 'Excessive RepaintBoundary: ${finding.count} in scrollable',
          detail: '${finding.count} RepaintBoundary widgets inside a single '
              'scrollable. Each creates a separate compositing layer, '
              'increasing GPU memory.\n\n  • ${finding.location}',
          fixHint: exHint,
          fixEffort: exEffort,
          observationSource: ObservationSource.structural,
          confidenceReason:
              'Structural scan only — excessive boundaries in scrollable',
          detectedAt: DateTime.now(),
        ),
      );
    }
  }

  /// Returns true if the [BoxScrollView]'s delegate has
  /// `addRepaintBoundaries: true` (the default). When true, the framework
  /// automatically wraps each child in [RepaintBoundary].
  static bool _delegateAddsRepaintBoundaries(BoxScrollView widget) {
    final delegate = widget is ListView
        ? widget.childrenDelegate
        : (widget as GridView).childrenDelegate;
    if (delegate is SliverChildBuilderDelegate) {
      return delegate.addRepaintBoundaries;
    }
    if (delegate is SliverChildListDelegate) {
      return delegate.addRepaintBoundaries;
    }
    return true; // Conservative default: assume framework adds them
  }

  /// Check if [ro] has a [RenderRepaintBoundary] within [maxAncestorDepth]
  /// parent levels in the render tree.
  bool _hasRepaintBoundaryAncestor(RenderObject ro) {
    RenderObject? current = ro.parent;
    for (var i = 0; i < maxAncestorDepth && current != null; i++) {
      if (current is RenderRepaintBoundary) return true;
      current = current.parent;
    }
    return false;
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _typeNames.clear();
    _scrollableBoundaryStack.clear();
    _excessiveFindings.clear();
    _lastDebugSnapshot = null;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.unvalidated,
        rationale:
            'Missing-RepaintBoundary structural heuristic around '
            'animated subtrees. Not runtime-verified or cited to Flutter '
            'repaint-boundary guidance.',
      );
}
