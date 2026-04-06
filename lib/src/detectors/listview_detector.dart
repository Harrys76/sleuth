import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// Detects non-lazy ListView/GridView with many children.
///
/// **Structural Detector** — checks for SliverChildListDelegate with >50 items.
class ListviewDetector extends BaseDetector {
  ListviewDetector({this.childThreshold = 50})
      : super(
          type: DetectorType.listview,
          lifecycle: DetectorLifecycle.structural,
          name: 'ListView',
          description: 'Detects non-lazy ListView with >50 items',
        );

  final int childThreshold;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

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
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    // Detect SingleChildScrollView + Column/Row pattern (non-lazy list)
    if (widget is SingleChildScrollView) {
      _checkForNonLazyList(element);
      return;
    }

    // Detect non-builder ListView/GridView (uses SliverChildListDelegate)
    if (widget is ListView || widget is GridView) {
      final delegate = widget is ListView
          ? widget.childrenDelegate
          : (widget as GridView).childrenDelegate;
      if (delegate is SliverChildListDelegate &&
          delegate.children.length > childThreshold) {
        _emitNonLazyScrollViewIssue(element, widget, delegate.children.length);
      }
    }
  }

  @override
  void finalizeScan() {
    // Issues are created inline in _checkForNonLazyList — nothing to finalize.
  }

  void _emitNonLazyScrollViewIssue(
      Element scrollElement, Widget widget, int childCount) {
    final widgetName = widget is ListView ? 'ListView' : 'GridView';
    final stableId =
        widget is ListView ? 'non_lazy_listview' : 'non_lazy_gridview';
    final location = buildAncestorChain(scrollElement);

    final ro = scrollElement.renderObject;
    if (ro != null) {
      final rect = getGlobalRect(ro);
      if (rect != null) {
        _highlights.add(WidgetHighlight(
          rect: rect,
          widgetName: widgetName,
          severity: childCount > childThreshold * 2
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          detectorName: 'Non-lazy',
          detail: '$childCount children built eagerly',
        ));
      }
    }
    final (hint, effort) = FixHintBuilder.nonLazyList(
      childCount: childCount,
      widgetName: widgetName,
      ancestorChain: location,
    );
    _issues.add(PerformanceIssue(
      stableId: stableId,
      severity: childCount > childThreshold * 3
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.possible,
      title: 'Non-lazy $widgetName: $childCount children',
      detail: '$widgetName with $childCount children builds all items at '
          'once instead of lazily. Use $widgetName.builder for '
          'virtualized rendering.\n\n  • $location',
      fixHint: hint,
      fixEffort: effort,
      widgetName: widgetName,
      ancestorChain: location,
      observationSource: ObservationSource.structural,
      detectedAt: DateTime.now(),
    ));
  }

  void _checkForNonLazyList(Element scrollElement) {
    // Walk through wrappers to find Column/Row
    void findFlexChild(Element element) {
      final widget = element.widget;
      if (widget is Column || widget is Row) {
        // Count only direct children of the Column/Row
        int directChildCount = 0;
        element.visitChildren((_) => directChildCount++);

        if (directChildCount > childThreshold) {
          final location = buildAncestorChain(scrollElement);
          final ro = scrollElement.renderObject;
          if (ro != null) {
            final rect = getGlobalRect(ro);
            if (rect != null) {
              _highlights.add(WidgetHighlight(
                rect: rect,
                widgetName: 'SingleChildScrollView',
                severity: directChildCount > childThreshold * 2
                    ? IssueSeverity.critical
                    : IssueSeverity.warning,
                detectorName: 'Non-lazy',
                detail: '$directChildCount children built eagerly',
              ));
            }
          }
          final (hint, effort) = FixHintBuilder.nonLazyList(
            childCount: directChildCount,
            widgetName: 'SingleChildScrollView',
            ancestorChain: location,
          );
          _issues.add(PerformanceIssue(
            stableId: 'non_lazy_list',
            severity: directChildCount > childThreshold * 3
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            category: IssueCategory.build,
            confidence: IssueConfidence.possible,
            title:
                'Non-lazy List: ${widget.runtimeType} with $directChildCount children',
            detail: 'SingleChildScrollView + ${widget.runtimeType} with '
                '$directChildCount children builds all items at once '
                'instead of lazily.\n\n  • $location',
            fixHint: hint,
            fixEffort: effort,
            widgetName: 'SingleChildScrollView',
            ancestorChain: location,
            observationSource: ObservationSource.structural,
            detectedAt: DateTime.now(),
          ));
        }
        return;
      }
      // Traverse through wrapper widgets (Padding, SizedBox, etc.)
      element.visitChildren(findFlexChild);
    }

    scrollElement.visitChildren(findFlexChild);
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
  }
}
