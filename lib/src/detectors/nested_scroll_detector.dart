import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/type_name_cache.dart';
import '../utils/widget_location.dart';

/// Detects SingleChildScrollView wrapping Column with many children.
///
/// **Structural Detector** — this pattern means all children are built
/// even when offscreen, defeating virtualization.
class NestedScrollDetector extends BaseDetector
    with DetectorMetadataProvider {
  NestedScrollDetector({this.childThreshold = 50})
      : super(
          type: DetectorType.nestedScroll,
          lifecycle: DetectorLifecycle.structural,
          name: 'Nested Scroll',
          description: 'Detects SingleChildScrollView + Column >50 children',
        );

  final int childThreshold;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  /// Stack tracking the propagated scroll axis through the tree.
  /// Initialized with a null sentinel for the root level.
  final List<Axis?> _scrollAxisStack = [null];

  /// Depth counter: >0 when inside a [NestedScrollView] subtree.
  /// Inner scrollables are intentional in NestedScrollView — suppress flagging.
  int _insideNestedScrollView = 0;

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
    _scrollAxisStack
      ..clear()
      ..add(null);
    _insideNestedScrollView = 0;
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    // NestedScrollView is the framework's dedicated solution for coordinated
    // nested scrolling. Its inner scrollables are intentional — suppress
    // nesting warnings for all descendants.
    if (widget is NestedScrollView) {
      _insideNestedScrollView++;
    }

    final scrollAxis = _scrollAxis(widget);
    final parentAxis = _scrollAxisStack.last;

    // Detect scroll-inside-scroll (same axis only).
    // Skip when inside NestedScrollView — inner scrollables are intentional.
    if (_insideNestedScrollView == 0 &&
        scrollAxis != null &&
        parentAxis != null) {
      if (scrollAxis == parentAxis) {
        // NeverScrollableScrollPhysics means the inner widget intentionally
        // delegates scrolling to the parent — standard Flutter pattern.
        // Walks the full ScrollPhysics.parent chain to catch wrapped cases
        // like ClampingScrollPhysics(parent: NeverScrollableScrollPhysics()).
        if (!_hasNeverScrollablePhysics(widget)) {
          _checkNestedScroll(element, widget);
        }
      }
      // Cross-axis nesting is a standard pattern (e.g. horizontal
      // ListView inside vertical ScrollView) — suppress.
    }

    // Push: propagate axis to children
    _scrollAxisStack.add(parentAxis ?? scrollAxis);
  }

  @override
  void afterElement(Element element) {
    _scrollAxisStack.removeLast();
    if (element.widget is NestedScrollView) {
      _insideNestedScrollView--;
    }
  }

  /// Extract scroll axis from a scrollable widget, or null if not scrollable.
  static Axis? _scrollAxis(Widget widget) {
    if (widget is SingleChildScrollView) return widget.scrollDirection;
    if (widget is ListView) return widget.scrollDirection;
    if (widget is GridView) return widget.scrollDirection;
    if (widget is CustomScrollView) return widget.scrollDirection;
    return null;
  }

  static bool _hasNeverScrollablePhysics(Widget widget) {
    ScrollPhysics? physics;
    if (widget is ScrollView) {
      physics = widget.physics;
    } else if (widget is SingleChildScrollView) {
      physics = widget.physics;
    }
    return _physicsChainContainsNever(physics);
  }

  /// Walk the [ScrollPhysics.parent] chain looking for
  /// [NeverScrollableScrollPhysics] at any level.
  static bool _physicsChainContainsNever(ScrollPhysics? physics) {
    ScrollPhysics? p = physics;
    while (p != null) {
      if (p is NeverScrollableScrollPhysics) return true;
      p = p.parent;
    }
    return false;
  }

  void _checkNestedScroll(Element element, Widget widget) {
    final location = buildAncestorChain(element);
    final widgetTypeName = typeNameCache.lookup(widget);

    if (widget is SingleChildScrollView) {
      int childCount = 0;
      void findFlex(Element el) {
        if (el.widget is Column || el.widget is Row) {
          el.visitChildren((_) => childCount++);
          return;
        }
        el.visitChildren(findFlex);
      }

      element.visitChildren(findFlex);

      if (childCount > childThreshold) {
        final severity = childCount > childThreshold * 2
            ? IssueSeverity.critical
            : IssueSeverity.warning;
        final (hint1, effort1) = FixHintBuilder.nestedScrollChildren(
          childCount: childCount,
          widgetName: 'SingleChildScrollView',
          ancestorChain: location,
        );
        _issues.add(
          PerformanceIssue(
            stableId: 'nested_scroll',
            severity: severity,
            category: IssueCategory.build,
            confidence: IssueConfidence.possible,
            title: 'Nested Scroll: $childCount children inside parent scroll',
            detail: 'A SingleChildScrollView with $childCount children is '
                'nested inside another scrollable. This defeats '
                'virtualization.\n\n  • $location',
            fixHint: hint1,
            fixEffort: effort1,
            widgetName: 'SingleChildScrollView',
            ancestorChain: location,
            observationSource: ObservationSource.structural,
            confidenceReason:
                'Structural scan only — scroll-inside-scroll pattern found',
            detectedAt: DateTime.now(),
          ),
        );
        _addHighlight(element, 'SingleChildScrollView', severity,
            '$childCount children inside parent scroll');
        return;
      }
    }

    // Generic nested scrollable warning
    final (hint2, effort2) = FixHintBuilder.nestedScrollGeneric(
      widgetName: widgetTypeName,
      ancestorChain: location,
    );
    _issues.add(
      PerformanceIssue(
        stableId: 'nested_scroll_same_axis',
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Nested Scroll: $widgetTypeName inside scrollable',
        detail: '$widgetTypeName is nested inside another scrollable '
            'widget. This can cause scroll conflicts and performance '
            'issues.\n\n  • $location',
        fixHint: hint2,
        fixEffort: effort2,
        widgetName: widgetTypeName,
        ancestorChain: location,
        observationSource: ObservationSource.structural,
        confidenceReason:
            'Structural scan only — scroll-inside-scroll pattern found',
        detectedAt: DateTime.now(),
      ),
    );
    _addHighlight(element, widgetTypeName, IssueSeverity.warning,
        '$widgetTypeName inside scrollable');
  }

  void _addHighlight(
    Element element,
    String widgetName,
    IssueSeverity severity,
    String detail,
  ) {
    final ro = element.renderObject;
    if (ro == null) return;
    final rect = getGlobalRect(ro);
    if (rect == null) return;
    _highlights.add(WidgetHighlight(
      rect: rect,
      widgetName: widgetName,
      severity: severity,
      detectorName: 'Nested Scroll',
      detail: detail,
    ));
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.unvalidated,
        rationale:
            'NestedScrollView-with-inner-scrollable structural '
            'heuristic. Not runtime-verified or externally cited.',
      );
}
