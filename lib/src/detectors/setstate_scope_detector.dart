import 'package:flutter/material.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/widget_location.dart';

/// Detects StatefulWidgets that own too large a portion of the widget tree
/// AND are actually calling setState(), causing wide rebuilds.
///
/// Uses three signals:
/// 1. **Structural**: does the StatefulWidget own >50% of the tree?
/// 2. **Behavioral**: did `build()` actually re-run? (child widget identity change)
/// 3. **Animation scope**: does the subtree use AnimatedBuilder/AnimatedWidget?
///
/// This avoids false positives on animation-based pages (CustomPainterDemo)
/// while reliably catching setState-heavy pages (HighLevelSetStateDemo).
class SetStateScopeDetector extends BaseDetector {
  SetStateScopeDetector({
    this.dirtyRatioThreshold = 0.5,
    this.minSubtreeSize = 50,
    this.rebuildEvidenceThreshold = 2,
  }) : super(
          type: DetectorType.setStateScope,
          lifecycle: DetectorLifecycle.structural,
          name: 'setState Scope',
          description: 'Detects StatefulWidgets owning >50% of tree',
        );

  /// If subtreeSize/totalElements exceeds this ratio, flag it.
  final double dirtyRatioThreshold;

  /// Minimum subtree size to flag — avoids false positives on small pages.
  final int minSubtreeSize;

  /// Minimum rebuild count in the evidence window to consider confirmed.
  final int rebuildEvidenceThreshold;

  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  // --- Behavioral tracking state ---

  /// Maps element identity → identityHashCode of its first child widget.
  /// Used to detect when build() re-runs (child widget instance changes).
  final Map<int, int> _childSnapshots = {};

  /// Accumulated rebuild counts per widget name in the current window.
  final Map<String, int> _rebuildEvidence = {};
  DateTime _evidenceWindowStart = DateTime.now();

  /// Evidence window duration — rebuilds older than this are expired.
  static const _evidenceWindowSeconds = 5;

  /// Last debug snapshot for rebuild correlation.
  DebugSnapshot? _lastDebugSnapshot;

  /// Per-type instance counts from the most recent tree walk.
  final Map<String, int> _typeInstanceCounts = {};

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

  /// Whether this widget name has recent rebuild evidence.
  bool hasRebuildEvidenceFor(String widgetName) =>
      (_rebuildEvidence[widgetName] ?? 0) >= rebuildEvidenceThreshold;

  /// Clear tracking state (call on route changes).
  void clearSnapshots() {
    _childSnapshots.clear();
    _rebuildEvidence.clear();
    _evidenceWindowStart = DateTime.now();
  }

  @override
  void scanTree(BuildContext context) {
    if (!_isEnabled) return;
    _issues.clear();
    _highlights.clear();

    // Phase 1: Detect which user StatefulElements were rebuilt since last scan
    _detectRebuilds(context);
    _expireOldEvidence();

    // Phase 2: Structural analysis — find the widest user StatefulWidget
    int totalElements = 0;
    int maxSubtreeSize = 0;
    String? widestStatefulWidget;
    Element? widestElement;
    _typeInstanceCounts.clear();

    void visitor(Element element) {
      totalElements++;

      if (element is StatefulElement) {
        final widget = element.widget;
        final name = widget.runtimeType.toString();
        if (!name.startsWith('_') && !isFrameworkWidget(widget)) {
          // Count instances per type for debug correlation
          _typeInstanceCounts[name] = (_typeInstanceCounts[name] ?? 0) + 1;

          int subtreeSize = 0;
          void countSubtree(Element child) {
            subtreeSize++;
            child.visitChildren(countSubtree);
          }

          element.visitChildren(countSubtree);

          if (subtreeSize > maxSubtreeSize) {
            maxSubtreeSize = subtreeSize;
            widestStatefulWidget = name;
            widestElement = element;
          }
        }
      }

      element.visitChildren(visitor);
    }

    try {
      context.visitChildElements(visitor);
    } catch (_) {}

    if (totalElements == 0 || maxSubtreeSize < minSubtreeSize) return;

    final ratio = maxSubtreeSize / totalElements;
    if (ratio <= dirtyRatioThreshold) return;

    // Phase 3: Combine signals to decide whether to flag
    final hasEvidence = hasRebuildEvidenceFor(widestStatefulWidget!);
    final hasAnimScope =
        widestElement != null && _containsAnimationScope(widestElement!);

    // Phase 3b: Debug correlation — upgrade confidence if debug snapshot
    // confirms the flagged type is actually rebuilding.
    final debugCorrelation = _computeDebugCorrelation(widestStatefulWidget!);

    final percent = (ratio * 100).toStringAsFixed(0);
    final rawChain =
        widestElement != null ? buildAncestorChain(widestElement!) : null;
    final location = rawChain != null ? '\n\n  • $rawChain' : '';

    if (hasEvidence) {
      final baseConfidence =
          hasAnimScope ? IssueConfidence.possible : IssueConfidence.likely;

      _issues.add(
        PerformanceIssue(
          stableId: 'setstate_scope',
          severity:
              ratio > 0.5 ? IssueSeverity.critical : IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: debugCorrelation?.confidence ?? baseConfidence,
          title:
              'Wide setState Scope: $widestStatefulWidget owns ~$percent% of tree',
          detail: '$widestStatefulWidget has $maxSubtreeSize of $totalElements '
              'elements (~$percent%) in its subtree. setState() was detected '
              'rebuilding this wide subtree.$location',
          fixHint: 'Move setState() calls to smaller, focused widgets. '
              'Use Builder or ValueListenableBuilder to scope rebuilds. '
              'Extract stateful logic into the lowest possible subtree.',
          widgetName: widestStatefulWidget,
          ancestorChain: rawChain,
          observationSource:
              debugCorrelation?.source ?? ObservationSource.structural,
          detectedAt: DateTime.now(),
        ),
      );
      _addHighlight(widestElement!, widestStatefulWidget!, hasEvidence, percent,
          maxSubtreeSize);
    } else if (!hasAnimScope) {
      _issues.add(
        PerformanceIssue(
          stableId: 'setstate_scope',
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: debugCorrelation?.confidence ?? IssueConfidence.possible,
          title:
              'Wide setState Scope: $widestStatefulWidget owns ~$percent% of tree',
          detail: '$widestStatefulWidget has $maxSubtreeSize of $totalElements '
              'elements (~$percent%) in its subtree. Any setState() on this '
              'widget would rebuild most of the visible tree.$location',
          fixHint: 'Move setState() calls to smaller, focused widgets. '
              'Use Builder or ValueListenableBuilder to scope rebuilds. '
              'Extract stateful logic into the lowest possible subtree.',
          widgetName: widestStatefulWidget,
          ancestorChain: rawChain,
          observationSource:
              debugCorrelation?.source ?? ObservationSource.structural,
          detectedAt: DateTime.now(),
        ),
      );
      _addHighlight(widestElement!, widestStatefulWidget!, hasEvidence, percent,
          maxSubtreeSize);
    }
    // else: large subtree + animation scope + no rebuild evidence → suppress
  }

  /// Compute debug-based confidence upgrade for the flagged widget type.
  ///
  /// Returns null if no debug data is available or the type doesn't appear
  /// in rebuild counts. Otherwise:
  /// - `confirmed` if the type is unique in the scanned tree (one instance)
  /// - `likely` if multiple instances exist (can't distinguish which rebuilds)
  ({IssueConfidence confidence, ObservationSource source})?
      _computeDebugCorrelation(String widgetType) {
    final snapshot = _lastDebugSnapshot;
    if (snapshot == null) return null;

    final count = snapshot.rebuildCounts[widgetType];
    if (count == null || count == 0) return null;

    final instanceCount = _typeInstanceCounts[widgetType] ?? 0;
    final confidence =
        instanceCount <= 1 ? IssueConfidence.confirmed : IssueConfidence.likely;

    return (
      confidence: confidence,
      source: ObservationSource.debugCallbackAndStructural,
    );
  }

  void _addHighlight(Element element, String widgetName, bool hasEvidence,
      String percent, int subtreeSize) {
    final ro = element.renderObject;
    if (ro == null) return;
    final rect = getGlobalRect(ro);
    if (rect == null) return;
    _highlights.add(WidgetHighlight(
      rect: rect,
      widgetName: widgetName,
      severity: hasEvidence ? IssueSeverity.critical : IssueSeverity.warning,
      detectorName: 'setState',
      detail: 'Owns ~$percent% of tree ($subtreeSize elements)',
    ));
  }

  /// Detect which user StatefulElements had their build() re-run since
  /// the last scan by comparing child widget identity.
  void _detectRebuilds(BuildContext context) {
    final newSnapshots = <int, int>{};

    void visitor(Element element) {
      if (element is StatefulElement) {
        final widget = element.widget;
        final name = widget.runtimeType.toString();
        if (!name.startsWith('_') && !isFrameworkWidget(widget)) {
          // Get first child's widget identity
          Widget? firstChildWidget;
          element.visitChildren((child) {
            firstChildWidget ??= child.widget;
          });

          if (firstChildWidget != null) {
            final key = identityHashCode(element);
            final childId = identityHashCode(firstChildWidget);
            newSnapshots[key] = childId;

            final prevChildId = _childSnapshots[key];
            if (prevChildId != null && prevChildId != childId) {
              // build() ran on this State — setState was called
              _rebuildEvidence[name] = (_rebuildEvidence[name] ?? 0) + 1;
            }
          }
        }
      }
      element.visitChildren(visitor);
    }

    try {
      context.visitChildElements(visitor);
    } catch (_) {}

    _childSnapshots
      ..clear()
      ..addAll(newSnapshots);
  }

  /// Expire old rebuild evidence.
  void _expireOldEvidence() {
    final now = DateTime.now();
    if (now.difference(_evidenceWindowStart).inSeconds >
        _evidenceWindowSeconds) {
      _rebuildEvidence.clear();
      _evidenceWindowStart = now;
    }
  }

  /// Check if the subtree contains AnimatedBuilder/AnimatedWidget within
  /// a few levels — indicating animation-scoped rebuilds, not wide setState.
  bool _containsAnimationScope(Element statefulElement) {
    bool found = false;
    int depth = 0;

    void check(Element el) {
      if (found || depth > 5) return;
      if (el.widget is AnimatedWidget) {
        found = true;
        return;
      }
      // Also check for ListenableBuilder by name (it may not extend AnimatedWidget
      // in all Flutter versions)
      final name = el.widget.runtimeType.toString();
      if (name == 'ListenableBuilder' || name == 'ValueListenableBuilder') {
        found = true;
        return;
      }
      depth++;
      el.visitChildren(check);
      depth--;
    }

    statefulElement.visitChildren(check);
    return found;
  }

  /// Returns true if the widget is a framework StatefulWidget that naturally
  /// owns large subtrees but is not a user anti-pattern.
  static bool isFrameworkWidget(Widget widget) {
    if (widget is ImplicitlyAnimatedWidget) return true;
    if (widget is AnimatedWidget) return true;
    if (widget is ScrollView) return true;
    if (widget is Scaffold) return true;
    if (widget is AppBar) return true;
    if (widget is Material) return true;
    if (widget is Navigator) return true;
    if (widget is Overlay) return true;
    if (widget is Scrollable) return true;
    if (widget is ScrollNotificationObserver) return true;
    if (widget is FocusScope) return true;
    if (widget is FocusTraversalGroup) return true;
    if (widget is Actions) return true;
    if (widget is Shortcuts) return true;
    if (widget is GlowingOverscrollIndicator) return true;
    if (widget is StretchingOverscrollIndicator) return true;
    if (widget is RawGestureDetector) return true;
    if (widget is RawScrollbar) return true;
    if (widget is PageView) return true;
    if (widget is TabBarView) return true;
    if (widget is TabBar) return true;
    if (widget is EditableText) return true;
    if (widget is ModalBarrier) return true;

    final name = widget.runtimeType.toString();
    return _frameworkWidgetNames.contains(name);
  }

  static const _frameworkWidgetNames = {
    'ScaffoldMessenger',
    'MaterialApp',
    'WidgetsApp',
    'CupertinoApp',
    'CupertinoTabScaffold',
    'HeroControllerScope',
    'PrimaryScrollController',
    'ScrollConfiguration',
    'DefaultTextEditingShortcuts',
    'DefaultSelectionStyle',
    'DefaultTabController',
    'NestedScrollView',
    'SingleChildScrollView',
    'AnimatedList',
    'ReorderableListView',
    'RefreshIndicator',
    'DraggableScrollableSheet',
    'ExpansionTile',
    'DrawerController',
  };

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _childSnapshots.clear();
    _rebuildEvidence.clear();
    _typeInstanceCounts.clear();
  }
}
