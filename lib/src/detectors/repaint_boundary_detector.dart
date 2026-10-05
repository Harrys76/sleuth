import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/framework_painters.dart';
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

  /// Boundary-count frames, keyed by the element that pushed them.
  ///
  /// A scroll view ([CustomScrollView], [BoxScrollView]) pushes a counting
  /// frame (0). A sliver list or grid whose delegate wraps children in
  /// [RepaintBoundary] pushes a `-1` frame so those framework boundaries
  /// are never counted. A [RepaintBoundary] increments the top frame when
  /// it is counting. [afterElement] pops only the frame its element owns.
  final List<({Element owner, int count})> _boundaryFrames = [];

  /// Accumulated excessive-boundary findings for finalizeScan.
  final List<({int count, String location, int occurrenceId})>
  _excessiveFindings = [];

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
    _boundaryFrames.clear();
    _excessiveFindings.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    // Track RepaintBoundary counts inside scroll views. Sliver lists and
    // grids whose delegate adds a RepaintBoundary per child (the default)
    // push a -1 frame so framework-managed boundaries are never counted.
    if (widget is CustomScrollView || widget is BoxScrollView) {
      _boundaryFrames.add((owner: element, count: 0));
    } else if (widget is SliverMultiBoxAdaptorWidget) {
      if (_delegateAddsRepaintBoundaries(widget.delegate)) {
        _boundaryFrames.add((owner: element, count: -1));
      }
    } else if (widget is RepaintBoundary && _boundaryFrames.isNotEmpty) {
      final top = _boundaryFrames.last;
      if (top.count >= 0) {
        _boundaryFrames.last = (owner: top.owner, count: top.count + 1);
      }
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
      // Framework-owned painters and Material's own transparency clip are
      // not user widgets to wrap.
      if (widget is CustomPaint && isFrameworkPainterPaint(element)) return;
      if (widget is ClipPath && isMaterialOwnClip(element)) return;
      final ro = element.renderObject;
      if (ro != null && !_hasRepaintBoundaryAncestor(ro)) {
        _found.add(buildAncestorChain(element));
        _typeNames.add(typeNameCache.lookup(widget));
        final rect = getGlobalRect(ro);
        if (rect != null) {
          _highlights.add(
            WidgetHighlight(
              rect: rect,
              renderObject: ro,
              widgetName: typeNameCache.lookup(widget),
              severity: IssueSeverity.warning,
              detectorName: 'RepaintBoundary',
              detail: 'No RepaintBoundary within $maxAncestorDepth ancestors',
            ),
          );
        }
      }
    }
  }

  @override
  void afterElement(Element element) {
    if (_boundaryFrames.isEmpty ||
        !identical(_boundaryFrames.last.owner, element)) {
      return;
    }
    final count = _boundaryFrames.removeLast().count;
    if (count <= _excessiveBoundaryThreshold) return;
    _excessiveFindings.add((
      count: count,
      location: buildAncestorChain(element),
      occurrenceId: identityHashCode(element),
    ));
    final ro = element.renderObject;
    if (ro == null) return;
    final rect = getGlobalRect(ro);
    if (rect == null) return;
    _highlights.add(
      WidgetHighlight(
        rect: rect,
        renderObject: ro,
        widgetName: typeNameCache.lookup(element.widget),
        severity: IssueSeverity.warning,
        detectorName: 'RepaintBoundary',
        detail: '$count RepaintBoundary children — excessive GPU memory',
      ),
    );
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
        // Paint counts aggregate per widget type, so even a high rate
        // cannot be attributed to the specific unprotected instance:
        // the cap is likely.
        if (maxRate > 10) {
          confidence = IssueConfidence.likely;
          source = ObservationSource.debugCallbackAndStructural;
        }
      }

      // Determine most common widget type for fix hint context.
      final typeCounts = <String, int>{};
      for (final name in _typeNames) {
        typeCounts[name] = (typeCounts[name] ?? 0) + 1;
      }
      final dominantType = typeCounts.entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;

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
          title:
              'Missing RepaintBoundary: ${_found.length} expensive '
              'widget${_found.length == 1 ? '' : 's'} unprotected',
          detail:
              '${_found.length} GPU-expensive widget(s) found without a '
              'RepaintBoundary ancestor within $maxAncestorDepth levels. '
              'Repaints propagate up the render tree unnecessarily.'
              '\n\n$locations',
          fixHint: hint,
          fixEffort: effort,
          observationSource: source,
          confidenceReason: confidence == IssueConfidence.likely
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
          detail:
              '${finding.count} RepaintBoundary widgets inside a single '
              'scrollable. Each creates a separate compositing layer, '
              'increasing GPU memory.\n\n  • ${finding.location}',
          fixHint: exHint,
          fixEffort: exEffort,
          observationSource: ObservationSource.structural,
          confidenceReason:
              'Structural scan only — excessive boundaries in scrollable',
          detectedAt: DateTime.now(),
          occurrenceId: finding.occurrenceId,
        ),
      );
    }
  }

  /// Whether [delegate] wraps each child in a [RepaintBoundary]: the
  /// `addRepaintBoundaries` flag of the two framework delegates (true by
  /// default), and true for any other delegate, whose wrapping is unknown.
  static bool _delegateAddsRepaintBoundaries(SliverChildDelegate delegate) {
    if (delegate is SliverChildBuilderDelegate) {
      return delegate.addRepaintBoundaries;
    }
    if (delegate is SliverChildListDelegate) {
      return delegate.addRepaintBoundaries;
    }
    return true;
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
    _boundaryFrames.clear();
    _excessiveFindings.clear();
    _lastDebugSnapshot = null;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hermetic reproducer pins `missing_repaint_boundary` '
        '(Opacity 0<x<1 and ClipPath without RepaintBoundary ancestor '
        'within `maxAncestorDepth`) and `excessive_repaint_boundary` '
        '(21 user-placed RepaintBoundaries in CustomScrollView with '
        '`addRepaintBoundaries: false` cross the 20-boundary hardcoded '
        'threshold). Known narrowing: the strict-greater at-threshold '
        'boundary is NOT pinned — the framework\'s scrollable '
        'pipeline injects extra RepaintBoundary nodes the detector '
        'counter observes, so exactly-20 tests cross unpredictably '
        'across Flutter SDK versions. Boundary frames are keyed by the '
        'element that pushed them: scroll views count, and every sliver '
        'list or grid whose delegate adds per-child boundaries (the '
        'default, or any non-framework delegate) pushes a -1 frame, so '
        'default ListView, GridView, SliverList, and SliverGrid '
        'boundaries are never counted while user boundaries under '
        'SliverToBoxAdapter or an addRepaintBoundaries: false delegate '
        'count toward the enclosing scroll view. Opacity 0.0/1.0 '
        'passthrough suppression and the framework-managed sliver '
        'boundaries are pinned as negative controls. Framework '
        'toggle and scrollbar painters (ToggleablePainter, '
        'ScrollbarPainter) are not treated as user CustomPaint, nor are '
        'private framework painters matched by class name plus an owner '
        'widget within a measured hop budget (hops measured on Flutter '
        '3.32/3.47: _ShapeBorderPainter parent _ShapeBorderPaint and '
        'Material 3-4; _InputBorderPainter InputDecorator 3/4; TabBar '
        '_IndicatorPainter 3/11 fixed and 19/27 scrollable, _DividerPainter '
        '2/10; ProgressIndicator linear 4, circular 4/5, refresh 17; '
        'CupertinoActivityIndicator 2; GlowingOverscrollIndicator 3; '
        'AnimatedIcon 2; _DropdownMenu 2; Placeholder 2; GridPaper 1; '
        'budgets sit at or one above). Real Material and Cupertino '
        'widgets are pinned silent, and a user painter carrying a '
        'framework painter name outside its owner still fires. A ClipPath '
        'whose parent element is Material (the transparency-type clip '
        'Material builds itself) is skipped; a user ClipPath given as a '
        'Material child sits below that clip and stays reported. A debug '
        'paint rate above 10/sec for an unprotected type lifts confidence '
        'to likely, never confirmed: paint counts aggregate per type and '
        'cannot attribute to the specific instance. '
        'Fixtures use Opacity, not CustomPaint, to keep the '
        'missing-branch test cross-detector clean.',
    reproducerPath: 'test/validation/repaint_boundary_reproducer_test.dart',
    coveredStableIds: {
      'missing_repaint_boundary',
      'excessive_repaint_boundary',
    },
  );
}
