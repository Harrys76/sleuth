import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/type_name_cache.dart';
import '../utils/widget_location.dart';

/// Detects non-lazy ListView/GridView with many children, shrinkWrap lists
/// inside a Column/Row, and sliver anti-patterns (SliverToBoxAdapter large
/// subtrees, SliverFillRemaining misuse, shrinkWrap inside slivers).
///
/// **Structural Detector** — checks for SliverChildListDelegate with >50
/// items, `shrinkWrap: true` lists under a Flex, and three sliver
/// anti-patterns that defeat lazy loading.
class ListviewDetector extends BaseDetector with DetectorMetadataProvider {
  ListviewDetector({this.childThreshold = 50})
    : super(
        type: DetectorType.listview,
        lifecycle: DetectorLifecycle.structural,
        name: 'ListView',
        description: 'Detects non-lazy lists and sliver anti-patterns',
      );

  final int childThreshold;

  /// `sliver_to_box_adapter_shrinkwrap` and `non_lazy_shrinkwrap` fire
  /// only above this many children (or when the count is unbounded).
  static const shrinkWrapMinChildCount = 20;

  /// A list with more than this many times [childThreshold] children is
  /// critical.
  static const int criticalChildMultiplier = 3;

  /// `non_lazy_shrinkwrap` is critical above this many children.
  static const shrinkWrapCriticalChildCount = 100;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  /// Depth counter to skip SliverList/SliverGrid that are internal children
  /// of a ListView/GridView (already detected at the parent level).
  int _insideBoxScrollView = 0;

  /// Depth counter tracking when we are inside a SliverToBoxAdapter subtree.
  int _insideSliverToBoxAdapter = 0;

  /// Type names of the enclosing [Flex] widgets (Column, Row), innermost
  /// last. Pushed in [checkElement], popped in [afterElement].
  final List<String> _flexStack = [];

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
    _flexStack.clear();
    _sliverFillFindings.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    if (widget is Flex) {
      _flexStack.add(
        widget is Column
            ? 'Column'
            : widget is Row
            ? 'Row'
            : 'Flex',
      );
      return;
    }

    // Detect SingleChildScrollView + Column/Row pattern (non-lazy list)
    if (widget is SingleChildScrollView) {
      // Check B: also record if inside SliverFillRemaining(hasScrollBody: false)
      if (_insideSliverFillNoScroll > 0) {
        _sliverFillFindings.add(
          _SliverFillFinding(
            element: element,
            scrollableType: 'SingleChildScrollView',
          ),
        );
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
      final shrinkWrap = (widget as BoxScrollView).shrinkWrap;
      final delegateCount = switch (delegate) {
        final SliverChildListDelegate d => d.children.length,
        final SliverChildBuilderDelegate d => d.childCount,
        _ => null,
      };
      final manyChildren =
          delegateCount == null || delegateCount > shrinkWrapMinChildCount;
      final isNonLazy =
          delegate is SliverChildListDelegate &&
          delegate.children.length > childThreshold;

      // shrinkWrap inside a Column/Row builds every child whether or not
      // the list uses a builder, so it takes precedence over the non-lazy
      // id. Inside a SliverToBoxAdapter, Check C owns the finding. With a
      // bounded main axis (Expanded, a sized box) the shrink-wrapping
      // viewport lays out only what fits, so nothing is reported.
      final shrinkWrapInFlex =
          shrinkWrap &&
          _flexStack.isNotEmpty &&
          _insideSliverToBoxAdapter == 0 &&
          manyChildren &&
          _mainAxisUnbounded(element, widget.scrollDirection);
      if (shrinkWrapInFlex) {
        _emitShrinkWrapInFlexIssue(
          element,
          widget is ListView ? 'ListView' : 'GridView',
          _flexStack.last,
          delegateCount,
        );
      } else if (isNonLazy) {
        _emitNonLazyScrollViewIssue(element, widget, delegate.children.length);
      }

      // --- Check C: shrinkWrap scrollable inside SliverToBoxAdapter ---
      // Only when the child count is unbounded or large enough for eager
      // measurement to matter.
      if (_insideSliverToBoxAdapter > 0 &&
          shrinkWrap &&
          !isNonLazy &&
          manyChildren) {
        _emitSliverToBoxAdapterShrinkWrapIssue(
          element,
          widget is ListView ? 'ListView' : 'GridView',
        );
      }

      // --- Check B: scrollable inside SliverFillRemaining(hasScrollBody: false) ---
      if (_insideSliverFillNoScroll > 0) {
        _sliverFillFindings.add(
          _SliverFillFinding(
            element: element,
            scrollableType: widget is ListView ? 'ListView' : 'GridView',
          ),
        );
      }
      return;
    }

    // Check B: also catch CustomScrollView inside
    // SliverFillRemaining(hasScrollBody: false).
    // (SingleChildScrollView is handled above in its own branch.)
    if (_insideSliverFillNoScroll > 0 && widget is CustomScrollView) {
      _sliverFillFindings.add(
        _SliverFillFinding(
          element: element,
          scrollableType: 'CustomScrollView',
        ),
      );
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
    if (widget is Flex) {
      _flexStack.removeLast();
    } else if (widget is ListView || widget is GridView) {
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
    Element scrollElement,
    Widget widget,
    int childCount,
  ) {
    final widgetName = widget is ListView ? 'ListView' : 'GridView';
    final stableId = widget is ListView
        ? 'non_lazy_listview'
        : 'non_lazy_gridview';
    final location = buildAncestorChain(scrollElement);

    final ro = scrollElement.renderObject;
    if (ro != null) {
      final rect = getGlobalRect(ro);
      if (rect != null) {
        _highlights.add(
          WidgetHighlight(
            rect: rect,
            renderObject: ro,
            widgetName: widgetName,
            severity: childCount > childThreshold * criticalChildMultiplier
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            detectorName: 'Non-lazy',
            detail: '$childCount children built eagerly',
          ),
        );
      }
    }
    final (hint, effort) = FixHintBuilder.nonLazyList(
      childCount: childCount,
      widgetName: widgetName,
      ancestorChain: location,
    );
    _issues.add(
      PerformanceIssue(
        stableId: stableId,
        severity: childCount > childThreshold * criticalChildMultiplier
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        confidenceReason:
            'Structural scan only. The scan found a non-lazy list pattern',
        title: 'Non-lazy $widgetName: $childCount children',
        detail:
            '$widgetName with $childCount children allocates every child '
            'widget on each parent rebuild, with no lazy construction. '
            'Use $widgetName.builder so only the visible children are '
            'created.\n\n  • $location',
        fixHint: hint,
        fixEffort: effort,
        widgetName: widgetName,
        ancestorChain: location,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
        occurrenceId: identityHashCode(scrollElement),
      ),
    );
  }

  void _emitNonLazySliverIssue(
    Element sliverElement,
    SliverMultiBoxAdaptorWidget widget,
    int childCount,
  ) {
    final widgetName = widget is SliverGrid ? 'SliverGrid' : 'SliverList';
    final location = buildAncestorChain(sliverElement);

    final ro = sliverElement.renderObject;
    if (ro != null) {
      final rect = getGlobalRect(ro);
      if (rect != null) {
        _highlights.add(
          WidgetHighlight(
            rect: rect,
            renderObject: ro,
            widgetName: widgetName,
            severity: childCount > childThreshold * criticalChildMultiplier
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            detectorName: 'Non-lazy',
            detail: '$childCount children built eagerly',
          ),
        );
      }
    }
    final (hint, effort) = FixHintBuilder.nonLazySliver(
      childCount: childCount,
      widgetName: widgetName,
      ancestorChain: location,
    );
    _issues.add(
      PerformanceIssue(
        stableId:
            'non_lazy_${widgetName == 'SliverGrid' ? 'sliver_grid' : 'sliver_list'}',
        severity: childCount > childThreshold * criticalChildMultiplier
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        confidenceReason:
            'Structural scan only. The scan found a non-lazy list pattern',
        title: 'Non-lazy $widgetName: $childCount children',
        detail:
            '$widgetName with SliverChildListDelegate allocates all '
            '$childCount child widgets on each parent rebuild, with no lazy '
            'construction. Use $widgetName.builder so only the visible '
            'children are created.\n\n  • $location',
        fixHint: hint,
        fixEffort: effort,
        widgetName: widgetName,
        ancestorChain: location,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
        occurrenceId: identityHashCode(sliverElement),
      ),
    );
  }

  /// Whether the scroll view's main axis is unbounded, the case where
  /// `shrinkWrap: true` lays out every child. The scroll view's first
  /// render object is a proxy box, so its constraints are the ones the
  /// Column or Row handed down. Before the first layout the answer is
  /// unknown and the structural claim stands.
  static bool _mainAxisUnbounded(Element element, Axis axis) {
    final ro = element.renderObject;
    if (ro is! RenderBox || !ro.hasSize) return true;
    final constraints = ro.constraints;
    return axis == Axis.vertical
        ? !constraints.hasBoundedHeight
        : !constraints.hasBoundedWidth;
  }

  void _emitShrinkWrapInFlexIssue(
    Element scrollElement,
    String widgetName,
    String flexName,
    int? childCount,
  ) {
    final location = buildAncestorChain(scrollElement);
    final severity =
        childCount != null && childCount > shrinkWrapCriticalChildCount
        ? IssueSeverity.critical
        : IssueSeverity.warning;
    final built = childCount == null ? 'all' : '$childCount';

    final ro = scrollElement.renderObject;
    if (ro != null) {
      final rect = getGlobalRect(ro);
      if (rect != null) {
        _highlights.add(
          WidgetHighlight(
            rect: rect,
            renderObject: ro,
            widgetName: widgetName,
            severity: severity,
            detectorName: 'Non-lazy',
            detail: '$widgetName(shrinkWrap: true) inside $flexName',
          ),
        );
      }
    }
    final (hint, effort) = FixHintBuilder.nonLazyShrinkWrap(
      scrollableType: widgetName,
      flexType: flexName,
      ancestorChain: location,
    );
    _issues.add(
      PerformanceIssue(
        stableId: 'non_lazy_shrinkwrap',
        severity: severity,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        confidenceReason:
            'Structural scan only. The scan found a shrinkWrap list in a Flex',
        title:
            '$widgetName(shrinkWrap: true) inside $flexName: '
            '$built children built eagerly',
        detail:
            '$widgetName(shrinkWrap: true) inside a $flexName sizes itself '
            'to its content, so every child is built and laid out up front '
            'even when off-screen, whether or not it uses a builder.'
            '\n\n  • $location',
        fixHint: hint,
        fixEffort: effort,
        widgetName: widgetName,
        ancestorChain: location,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
        occurrenceId: identityHashCode(scrollElement),
      ),
    );
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
        _highlights.add(
          WidgetHighlight(
            rect: rect,
            renderObject: ro,
            widgetName: 'SliverToBoxAdapter',
            severity: childCount > childThreshold * criticalChildMultiplier
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            detectorName: 'Eager Sliver',
            detail: '$childCount children built eagerly',
          ),
        );
      }
    }
    final (hint, effort) = FixHintBuilder.sliverToBoxAdapterLarge(
      childCount: childCount,
      childType: childType,
      ancestorChain: location,
    );
    _issues.add(
      PerformanceIssue(
        stableId: 'sliver_to_box_adapter_large',
        severity: childCount > childThreshold * criticalChildMultiplier
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        confidenceReason:
            'Structural scan only. The scan found an eager sliver pattern',
        title:
            'Eager Sliver: SliverToBoxAdapter + $childType '
            'with $childCount children',
        detail:
            'A SliverToBoxAdapter that wraps a $childType with $childCount '
            'children allocates and lays out every child on each parent '
            'rebuild, so CustomScrollView cannot build them lazily. Replace '
            'it with SliverList.builder.\n\n  • $location',
        fixHint: hint,
        fixEffort: effort,
        widgetName: 'SliverToBoxAdapter',
        ancestorChain: location,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
        occurrenceId: identityHashCode(sliverElement),
      ),
    );
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
        _highlights.add(
          WidgetHighlight(
            rect: rect,
            renderObject: ro,
            widgetName: 'SliverFillRemaining',
            severity: IssueSeverity.warning,
            detectorName: 'Sliver Misuse',
            detail: 'Scrollable child with hasScrollBody: false',
          ),
        );
      }
    }
    final (hint, effort) = FixHintBuilder.sliverFillRemainingScrollable(
      ancestorChain: location,
    );
    _issues.add(
      PerformanceIssue(
        stableId: 'sliver_fill_remaining_scrollable',
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        confidenceReason:
            'Structural scan only. The scan found SliverFillRemaining misuse',
        title:
            'SliverFillRemaining Misuse: scrollable child with '
            'hasScrollBody: false',
        detail:
            'SliverFillRemaining(hasScrollBody: false) contains a '
            '$scrollableType. This gives the child unconstrained height, so '
            'the child has to shrinkWrap and builds all its children eagerly. '
            'Use hasScrollBody: true (the default) instead.\n\n  • $location',
        fixHint: hint,
        fixEffort: effort,
        widgetName: 'SliverFillRemaining',
        ancestorChain: location,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
        occurrenceId: identityHashCode(scrollableElement),
      ),
    );
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
        _highlights.add(
          WidgetHighlight(
            rect: rect,
            renderObject: ro,
            widgetName: 'SliverToBoxAdapter',
            severity: IssueSeverity.warning,
            detectorName: 'Eager Sliver',
            detail:
                '$scrollableType(shrinkWrap: true) inside SliverToBoxAdapter',
          ),
        );
      }
    }
    final (hint, effort) = FixHintBuilder.sliverToBoxAdapterShrinkWrap(
      scrollableType: scrollableType,
      ancestorChain: location,
    );
    _issues.add(
      PerformanceIssue(
        stableId: 'sliver_to_box_adapter_shrinkwrap',
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title:
            'Eager Sliver: SliverToBoxAdapter + '
            '$scrollableType(shrinkWrap: true)',
        detail:
            'A SliverToBoxAdapter that wraps $scrollableType(shrinkWrap: true) '
            'measures all its children eagerly. Use SliverList.builder or '
            'SliverGrid.builder in its place.\n\n  • $location',
        fixHint: hint,
        fixEffort: effort,
        widgetName: 'SliverToBoxAdapter',
        ancestorChain: location,
        observationSource: ObservationSource.structural,
        confidenceReason:
            'Structural scan only. The scan found an eager sliver pattern',
        detectedAt: DateTime.now(),
        occurrenceId: identityHashCode(scrollableElement),
      ),
    );
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
              _highlights.add(
                WidgetHighlight(
                  rect: rect,
                  renderObject: ro,
                  widgetName: 'SingleChildScrollView',
                  severity:
                      directChildCount >
                          childThreshold * criticalChildMultiplier
                      ? IssueSeverity.critical
                      : IssueSeverity.warning,
                  detectorName: 'Non-lazy',
                  detail: '$directChildCount children built eagerly',
                ),
              );
            }
          }
          final (hint, effort) = FixHintBuilder.nonLazyList(
            childCount: directChildCount,
            widgetName: 'SingleChildScrollView',
            ancestorChain: location,
          );
          _issues.add(
            PerformanceIssue(
              stableId: 'non_lazy_list',
              severity:
                  directChildCount > childThreshold * criticalChildMultiplier
                  ? IssueSeverity.critical
                  : IssueSeverity.warning,
              category: IssueCategory.build,
              confidence: IssueConfidence.possible,
              title:
                  'Non-lazy List: ${widget.runtimeType} with $directChildCount children',
              detail:
                  'A SingleChildScrollView around a ${widget.runtimeType} '
                  'with $directChildCount children allocates and lays out '
                  'every child on each parent rebuild, with no lazy '
                  'construction.\n\n  • $location',
              fixHint: hint,
              fixEffort: effort,
              widgetName: 'SingleChildScrollView',
              ancestorChain: location,
              observationSource: ObservationSource.structural,
              confidenceReason:
                  'Structural scan only. The scan found a non-lazy list pattern',
              detectedAt: DateTime.now(),
              occurrenceId: identityHashCode(scrollElement),
            ),
          );
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
    _flexStack.clear();
    _sliverFillFindings.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hermetic reproducer pins all 9 stable-id families. The non-lazy '
        'construction families are non_lazy_listview (ListView(children:) '
        'above childThreshold, with the .builder lazy path as the negative '
        'control), non_lazy_gridview (GridView(children:) above the '
        'threshold, .builder negative), non_lazy_sliver_list '
        '(SliverList(SliverChildListDelegate) above the threshold, '
        'SliverChildBuilderDelegate negative), non_lazy_sliver_grid '
        '(SliverGrid(SliverChildListDelegate) above the threshold, builder '
        'negative) and non_lazy_list (a SingleChildScrollView around a '
        'Column or Row above the threshold, at-threshold negative). '
        'non_lazy_shrinkwrap covers a ListView or GridView with '
        'shrinkWrap:true under a Column or Row, tracked by a Flex depth '
        'stack. It fires when the delegate child count is null or above 20 '
        'and the main axis of the list is unbounded, and it is critical '
        'above 100. Its negatives are a 20-child list, a list with no Flex '
        'and bounded-height lists (Expanded, sized box). The same list in a '
        'SliverToBoxAdapter routes to Check C, and non_lazy_shrinkwrap '
        'replaces non_lazy_listview for the same element. The sliver '
        'boundary families are sliver_to_box_adapter_large (a Column '
        'subtree above the threshold), sliver_to_box_adapter_shrinkwrap and '
        'sliver_fill_remaining_scrollable. sliver_to_box_adapter_shrinkwrap '
        '(an inner ListView with shrinkWrap:true inside a SliverToBoxAdapter) '
        'fires when !isNonLazy and the delegate child count is null or above '
        '20. Its negatives are a 5-child list and shrinkWrap:false, and many '
        'list-delegate children route to Check A non_lazy_listview instead, '
        'which pins the isNonLazy bypass. sliver_fill_remaining_scrollable '
        'is a structural adjacency check. It fires when any scrollable '
        'descendant appears under SliverFillRemaining(hasScrollBody:false), '
        'with hasScrollBody:true as the negative control. The reproducer '
        'does not measure the runtime cost that the sliver_fill_remaining '
        'pattern correlates with, because the real anti-pattern throws a '
        'layout error in flutter_test and needs a SizedBox wrapper around '
        'the inner scrollable. The detector is DetectorLifecycle.structural '
        'by declaration, so structural-only validation is internally '
        'consistent. A raise to runtimeVerified would need a profile-mode '
        'capture triad per family that shows measurable frame-budget impact '
        'on the non-lazy construction path.',
    reproducerPath: 'test/validation/listview_reproducer_test.dart',
    coveredStableIds: {
      'non_lazy_listview',
      'non_lazy_gridview',
      'non_lazy_sliver_list',
      'non_lazy_sliver_grid',
      'non_lazy_list',
      'non_lazy_shrinkwrap',
      'sliver_to_box_adapter_large',
      'sliver_to_box_adapter_shrinkwrap',
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
