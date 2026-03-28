import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../utils/widget_location.dart';

/// Detects SingleChildScrollView wrapping Column with many children.
///
/// **Structural Detector** — this pattern means all children are built
/// even when offscreen, defeating virtualization.
class NestedScrollDetector extends BaseDetector {
  NestedScrollDetector({this.childThreshold = 20})
      : super(
          type: DetectorType.nestedScroll,
          lifecycle: DetectorLifecycle.structural,
          name: 'Nested Scroll',
          description: 'Detects SingleChildScrollView + Column >20 children',
        );

  final int childThreshold;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  @override
  void scanTree(BuildContext context) {
    if (!_isEnabled) return;
    _issues.clear();

    void visitor(Element element, bool insideScroll) {
      final widget = element.widget;

      final isScrollable = widget is SingleChildScrollView ||
          widget is ListView ||
          widget is GridView ||
          widget is CustomScrollView;

      // Detect scroll-inside-scroll
      if (isScrollable && insideScroll) {
        _checkNestedScroll(element, widget);
      }

      element.visitChildren(
        (child) => visitor(child, insideScroll || isScrollable),
      );
    }

    try {
      context.visitChildElements((child) => visitor(child, false));
    } catch (_) {}
  }

  void _checkNestedScroll(Element element, Widget widget) {
    final location = buildAncestorChain(element);

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
        _issues.add(
          PerformanceIssue(
            stableId: 'nested_scroll',
            severity: childCount > childThreshold * 2
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            category: IssueCategory.build,
            confidence: IssueConfidence.possible,
            title: 'Nested Scroll: $childCount children inside parent scroll',
            detail: 'A SingleChildScrollView with $childCount children is '
                'nested inside another scrollable. This defeats '
                'virtualization.\n\n  • $location',
            fixHint: 'Use CustomScrollView with slivers, or '
                'NestedScrollView to coordinate scrolling.',
            widgetName: 'SingleChildScrollView',
            ancestorChain: location,
            observationSource: ObservationSource.structural,
            detectedAt: DateTime.now(),
          ),
        );
        return;
      }
    }

    // Generic nested scrollable warning
    _issues.add(
      PerformanceIssue(
        stableId: 'nested_scroll',
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Nested Scroll: ${widget.runtimeType} inside scrollable',
        detail: '${widget.runtimeType} is nested inside another scrollable '
            'widget. This can cause scroll conflicts and performance '
            'issues.\n\n  • $location',
        fixHint: 'Use CustomScrollView with slivers, or set '
            'physics: NeverScrollableScrollPhysics() on the inner scroll.',
        widgetName: widget.runtimeType.toString(),
        ancestorChain: location,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
      ),
    );
  }

  @override
  void dispose() => _issues.clear();
}
