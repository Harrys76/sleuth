import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/type_name_cache.dart';
import '../utils/widget_location.dart';

/// Detects non-lazy ListView/GridView with many children and sliver
/// anti-patterns (SliverToBoxAdapter large subtrees, SliverFillRemaining
/// misuse, shrinkWrap inside slivers).
///
/// **Structural Detector** — checks for SliverChildListDelegate with >50 items
/// and three sliver anti-patterns that defeat lazy loading.
class ListviewDetector extends BaseDetector with DetectorMetadataProvider {
  ListviewDetector({this.childThreshold = 50})
      : super(
          type: DetectorType.listview,
          lifecycle: DetectorLifecycle.structural,
          name: 'ListView',
          description: 'Detects non-lazy lists and sliver anti-patterns',
        );

  final int childThreshold;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  /// Depth counter to skip SliverList/SliverGrid that are internal children
  /// of a ListView/GridView (already detected at the parent level).
  int _insideBoxScrollView = 0;

  /// Depth counter tracking when we are inside a SliverToBoxAdapter subtree.
  int _insideSliverToBoxAdapter = 0;

  /// Depth counter tracking when we are inside a
  /// SliverFillRemaining(hasScrollBody: false) subtree.
  int _insideSliverFillNoScroll = 0;

  /// Deferred findings for SliverFillRemaining scrollable children,
  /// emitted in [finalizeScan].
  final List<_SliverFillFinding> _sliverFillFindings = [];

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
    _insideBoxScrollView = 0;
    _insideSliverToBoxAdapter = 0;
    _insideSliverFillNoScroll = 0;
    _sliverFillFindings.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    // Detect SingleChildScrollView + Column/Row pattern (non-lazy list)
    if (widget is SingleChildScrollView) {
      // Check B: also record if inside SliverFillRemaining(hasScrollBody: false)
      if (_insideSliverFillNoScroll > 0) {
        _sliverFillFindings.add(_SliverFillFinding(
          element: element,
          scrollableType: 'SingleChildScrollView',
        ));
      }
      _checkForNonLazyList(element);
      return;
    }

    // --- Check A/C: Track SliverToBoxAdapter depth ---
    if (widget is SliverToBoxAdapter) {
      _insideSliverToBoxAdapter++;
      _checkSliverToBoxAdapterChild(element);
      return;
    }

    // --- Check B: Track SliverFillRemaining(hasScrollBody: false) depth ---
    if (widget is SliverFillRemaining && !widget.hasScrollBody) {
      _insideSliverFillNoScroll++;
      return;
    }

    // Detect non-builder ListView/GridView (uses SliverChildListDelegate)
    if (widget is ListView || widget is GridView) {
      _insideBoxScrollView++;
      final delegate = widget is ListView
          ? widget.childrenDelegate
          : (widget as GridView).childrenDelegate;
      final isNonLazy = delegate is SliverChildListDelegate &&
          delegate.children.length > childThreshold;
      if (isNonLazy) {
        _emitNonLazyScrollViewIssue(element, widget, delegate.children.length);
      }

      // --- Check C: shrinkWrap scrollable inside SliverToBoxAdapter ---
      if (_insideSliverToBoxAdapter > 0 &&
          (widget as BoxScrollView).shrinkWrap &&
          !isNonLazy) {
        _emitSliverToBoxAdapterShrinkWrapIssue(
          element,
          widget is ListView ? 'ListView' : 'GridView',
        );
      }

      // --- Check B: scrollable inside SliverFillRemaining(hasScrollBody: false) ---
      if (_insideSliverFillNoScroll > 0) {
        _sliverFillFindings.add(_SliverFillFinding(
          element: element,
          scrollableType: widget is ListView ? 'ListView' : 'GridView',
        ));
      }
      return;
    }

    // Check B: also catch CustomScrollView inside
    // SliverFillRemaining(hasScrollBody: false).
    // (SingleChildScrollView is handled above in its own branch.)
    if (_insideSliverFillNoScroll > 0 && widget is CustomScrollView) {
      _sliverFillFindings.add(_SliverFillFinding(
        element: element,
        scrollableType: 'CustomScrollView',
      ));
      return;
    }

    // Detect non-builder SliverList/SliverGrid inside CustomScrollView
    // (skip when inside ListView/GridView — already detected at parent level)
    if (_insideBoxScrollView == 0 && widget is SliverMultiBoxAdaptorWidget) {
      final delegate = widget.delegate;
      if (delegate is SliverChildListDelegate &&
          delegate.children.length > childThreshold) {
        _emitNonLazySliverIssue(element, widget, delegate.children.length);
      }
    }
  }

  @override
  void afterElement(Element element) {
    final widget = element.widget;
    if (widget is ListView || widget is GridView) {
      _insideBoxScrollView--;
    } else if (widget is SliverToBoxAdapter) {
      _insideSliverToBoxAdapter--;
    } else if (widget is SliverFillRemaining && !widget.hasScrollBody) {
      _insideSliverFillNoScroll--;
    }
  }

  @override
  void finalizeScan() {
    // Emit deferred SliverFillRemaining findings (Check B).
    for (final finding in _sliverFillFindings) {
      _emitSliverFillRemainingIssue(finding.element, finding.scrollableType);
    }
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
      confidenceReason: 'Structural scan only — non-lazy list pattern found',
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

  void _emitNonLazySliverIssue(Element sliverElement,
      SliverMultiBoxAdaptorWidget widget, int childCount) {
    final widgetName = widget is SliverGrid ? 'SliverGrid' : 'SliverList';
    final location = buildAncestorChain(sliverElement);

    final ro = sliverElement.renderObject;
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
    final (hint, effort) = FixHintBuilder.nonLazySliver(
      childCount: childCount,
      widgetName: widgetName,
      ancestorChain: location,
    );
    _issues.add(PerformanceIssue(
      stableId:
          'non_lazy_${widgetName == 'SliverGrid' ? 'sliver_grid' : 'sliver_list'}',
      severity: childCount > childThreshold * 3
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.possible,
      confidenceReason: 'Structural scan only — non-lazy list pattern found',
      title: 'Non-lazy $widgetName: $childCount children',
      detail: '$widgetName with SliverChildListDelegate builds all '
          '$childCount children at once instead of lazily. Use '
          '$widgetName.builder for virtualized rendering.\n\n  • $location',
      fixHint: hint,
      fixEffort: effort,
      widgetName: widgetName,
      ancestorChain: location,
      observationSource: ObservationSource.structural,
      detectedAt: DateTime.now(),
    ));
  }

  // ---------------------------------------------------------------------------
  // Check A: SliverToBoxAdapter wrapping Column/Row with >threshold children
  // ---------------------------------------------------------------------------

  void _checkSliverToBoxAdapterChild(Element sliverElement) {
    // Walk through wrapper widgets to find Column/Row (same pattern as
    // _checkForNonLazyList).
    void findFlexChild(Element element) {
      final widget = element.widget;
      if (widget is Column || widget is Row) {
        int directChildCount = 0;
        element.visitChildren((_) => directChildCount++);

        if (directChildCount > childThreshold) {
          _emitSliverToBoxAdapterLargeIssue(
            sliverElement,
            widget,
            directChildCount,
          );
        }
        return;
      }
      // Traverse through wrapper widgets (Padding, SizedBox, Center, etc.)
      element.visitChildren(findFlexChild);
    }

    sliverElement.visitChildren(findFlexChild);
  }

  void _emitSliverToBoxAdapterLargeIssue(
    Element sliverElement,
    Widget childWidget,
    int childCount,
  ) {
    final childType = typeNameCache.lookup(childWidget);
    final location = buildAncestorChain(sliverElement);

    final ro = sliverElement.renderObject;
    if (ro != null) {
      final rect = getGlobalRect(ro);
      if (rect != null) {
        _highlights.add(WidgetHighlight(
          rect: rect,
          widgetName: 'SliverToBoxAdapter',
          severity: childCount > childThreshold * 2
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          detectorName: 'Eager Sliver',
          detail: '$childCount children built eagerly',
        ));
      }
    }
    final (hint, effort) = FixHintBuilder.sliverToBoxAdapterLarge(
      childCount: childCount,
      childType: childType,
      ancestorChain: location,
    );
    _issues.add(PerformanceIssue(
      stableId: 'sliver_to_box_adapter_large',
      severity: childCount > childThreshold * 3
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.possible,
      confidenceReason: 'Structural scan only — eager sliver pattern found',
      title: 'Eager Sliver: SliverToBoxAdapter + $childType '
          'with $childCount children',
      detail: 'SliverToBoxAdapter wrapping a $childType with $childCount '
          'children builds all items eagerly, defeating CustomScrollView '
          'lazy loading. Replace with SliverList.builder.\n\n  • $location',
      fixHint: hint,
      fixEffort: effort,
      widgetName: 'SliverToBoxAdapter',
      ancestorChain: location,
      observationSource: ObservationSource.structural,
      detectedAt: DateTime.now(),
    ));
  }

  // ---------------------------------------------------------------------------
  // Check B: SliverFillRemaining(hasScrollBody: false) with scrollable child
  // ---------------------------------------------------------------------------

  void _emitSliverFillRemainingIssue(
    Element scrollableElement,
    String scrollableType,
  ) {
    final location = buildAncestorChain(scrollableElement);

    final ro = scrollableElement.renderObject;
    if (ro != null) {
      final rect = getGlobalRect(ro);
      if (rect != null) {
        _highlights.add(WidgetHighlight(
          rect: rect,
          widgetName: 'SliverFillRemaining',
          severity: IssueSeverity.warning,
          detectorName: 'Sliver Misuse',
          detail: 'Scrollable child with hasScrollBody: false',
        ));
      }
    }
    final (hint, effort) = FixHintBuilder.sliverFillRemainingScrollable(
      ancestorChain: location,
    );
    _issues.add(PerformanceIssue(
      stableId: 'sliver_fill_remaining_scrollable',
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.possible,
      confidenceReason:
          'Structural scan only — SliverFillRemaining misuse pattern found',
      title: 'SliverFillRemaining Misuse: scrollable child with '
          'hasScrollBody: false',
      detail: 'SliverFillRemaining(hasScrollBody: false) contains a '
          '$scrollableType. This gives the child unconstrained height, '
          'forcing shrinkWrap and eager building of all children. '
          'Use hasScrollBody: true (the default) instead.\n\n  • $location',
      fixHint: hint,
      fixEffort: effort,
      widgetName: 'SliverFillRemaining',
      ancestorChain: location,
      observationSource: ObservationSource.structural,
      detectedAt: DateTime.now(),
    ));
  }

  // ---------------------------------------------------------------------------
  // Check C: SliverToBoxAdapter wrapping shrinkWrap ListView/GridView
  // ---------------------------------------------------------------------------

  void _emitSliverToBoxAdapterShrinkWrapIssue(
    Element scrollableElement,
    String scrollableType,
  ) {
    final location = buildAncestorChain(scrollableElement);

    final ro = scrollableElement.renderObject;
    if (ro != null) {
      final rect = getGlobalRect(ro);
      if (rect != null) {
        _highlights.add(WidgetHighlight(
          rect: rect,
          widgetName: 'SliverToBoxAdapter',
          severity: IssueSeverity.warning,
          detectorName: 'Eager Sliver',
          detail: '$scrollableType(shrinkWrap: true) inside SliverToBoxAdapter',
        ));
      }
    }
    final (hint, effort) = FixHintBuilder.sliverToBoxAdapterShrinkWrap(
      scrollableType: scrollableType,
      ancestorChain: location,
    );
    _issues.add(PerformanceIssue(
      stableId: 'sliver_to_box_adapter_shrinkwrap',
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.possible,
      title: 'Eager Sliver: SliverToBoxAdapter + '
          '$scrollableType(shrinkWrap: true)',
      detail: 'SliverToBoxAdapter wrapping $scrollableType(shrinkWrap: true) '
          'forces eager measurement of all children. Replace with '
          'SliverList.builder/SliverGrid.builder directly.\n\n  • $location',
      fixHint: hint,
      fixEffort: effort,
      widgetName: 'SliverToBoxAdapter',
      ancestorChain: location,
      observationSource: ObservationSource.structural,
      confidenceReason: 'Structural scan only — eager sliver pattern found',
      detectedAt: DateTime.now(),
    ));
  }

  // ---------------------------------------------------------------------------
  // SingleChildScrollView + Column/Row (original non-lazy list check)
  // ---------------------------------------------------------------------------

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
            confidenceReason:
                'Structural scan only — non-lazy list pattern found',
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
    _sliverFillFindings.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Hermetic reproducer pins 3 of 8 stable-id families: '
            'non_lazy_listview (childThreshold boundary + ListView.builder '
            'lazy-path bypass), sliver_to_box_adapter_large (Column subtree '
            'above threshold), sliver_fill_remaining_scrollable '
            '(hasScrollBody:false eager-build trap vs hasScrollBody:true '
            'happy path). Remaining 5 families '
            '(non_lazy_gridview, non_lazy_sliver_list, non_lazy_sliver_grid, '
            'sliver_to_box_adapter_shrinkwrap, non_lazy_list) remain '
            'implicitly unvalidated at v0.16.3 — same single-family pin '
            'precedent as v0.16.1 NetworkMonitor. Ledger row calls this out.',
        reproducerPath: 'test/validation/listview_reproducer_test.dart',
        coveredStableIds: {
          'non_lazy_listview',
          'sliver_to_box_adapter_large',
          'sliver_fill_remaining_scrollable',
        },
      );
}

/// Internal record for deferred SliverFillRemaining findings (Check B).
class _SliverFillFinding {
  _SliverFillFinding({required this.element, required this.scrollableType});
  final Element element;
  final String scrollableType;
}
