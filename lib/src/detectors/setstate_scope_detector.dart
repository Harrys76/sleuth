import 'package:flutter/material.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// Detects StatefulWidgets that own too large a portion of the widget tree.
/// Confidence is upgraded when rebuild activity is observed (child widget
/// identity churn between scans).
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
  Map<int, int> _childSnapshots = {};

  /// Accumulated rebuild counts per widget name in the current window.
  final Map<String, int> _rebuildEvidence = {};
  DateTime _evidenceWindowStart = DateTime.now();

  /// Evidence window duration — rebuilds older than this are expired.
  static const _evidenceWindowSeconds = 5;

  /// Last debug snapshot for rebuild correlation.
  DebugSnapshot? _lastDebugSnapshot;

  /// Per-type instance counts from the most recent tree walk.
  final Map<String, int> _typeInstanceCounts = {};

  // --- Const/stable element tracking ---

  /// Maps identityHashCode(element) → identityHashCode(element.widget)
  /// from the previous scan. Const widgets keep the same widget instance
  /// across rebuilds, so matching identity means the element is stable.
  Map<int, int> _elementWidgetSnapshots = {};
  Map<int, int> _newElementWidgetSnapshots = {};

  /// Parallel stack to [_subtreeSizeStack] — counts stable (const) elements.
  final List<int> _stableCountStack = [];

  /// Stable element count in the widest StatefulWidget's subtree.
  int _maxStableCount = 0;

  // --- Per-scan accumulators ---

  int _totalElements = 0;
  int _maxSubtreeSize = 0;
  String? _widestStatefulWidget;
  Element? _widestElement;
  Map<int, int> _newSnapshots = {};
  final List<int> _subtreeSizeStack = [];
  bool _walkCompleted = false;
  final Map<String, int> _pendingEvidence = {};

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
    _elementWidgetSnapshots.clear();
    _rebuildEvidence.clear();
    _evidenceWindowStart = DateTime.now();
    _widestElement = null;
    _widestStatefulWidget = null;
  }

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _typeInstanceCounts.clear();
    _totalElements = 0;
    _maxSubtreeSize = 0;
    _widestStatefulWidget = null;
    _widestElement = null;
    _newSnapshots = {};
    _newElementWidgetSnapshots = {};
    _subtreeSizeStack.clear();
    _stableCountStack.clear();
    _maxStableCount = 0;
    _walkCompleted = false;
    _pendingEvidence.clear();
    _expireOldEvidence();
  }

  @override
  void notifyWalkCompleted() {
    _walkCompleted = true;
    // Commit staged rebuild evidence only on successful walk completion.
    for (final entry in _pendingEvidence.entries) {
      _rebuildEvidence[entry.key] =
          (_rebuildEvidence[entry.key] ?? 0) + entry.value;
    }
  }

  @override
  void checkElement(Element element) {
    _totalElements++;
    _subtreeSizeStack.add(0);
    _stableCountStack.add(0);

    // Record widget identity for const-element tracking.
    _newElementWidgetSnapshots[identityHashCode(element)] =
        identityHashCode(element.widget);

    if (element is StatefulElement) {
      final widget = element.widget;
      final name = widget.runtimeType.toString();
      if (!name.startsWith('_') && !isFrameworkWidget(widget)) {
        // --- Rebuild detection (merged from _detectRebuilds) ---
        Widget? firstChildWidget;
        element.visitChildren((child) {
          firstChildWidget ??= child.widget;
        });

        if (firstChildWidget != null) {
          final key = identityHashCode(element);
          final childId = identityHashCode(firstChildWidget);
          _newSnapshots[key] = childId;

          final prevChildId = _childSnapshots[key];
          if (prevChildId != null && prevChildId != childId) {
            // Child widget identity changed — this element rebuilt.
            // Stage in _pendingEvidence; merged on walk completion only.
            _pendingEvidence[name] = (_pendingEvidence[name] ?? 0) + 1;
          }
        }

        // --- Count instances per type for debug correlation ---
        _typeInstanceCounts[name] = (_typeInstanceCounts[name] ?? 0) + 1;
      }
    }
  }

  @override
  void afterElement(Element element) {
    final subtreeSize = _subtreeSizeStack.removeLast();
    if (_subtreeSizeStack.isNotEmpty) {
      _subtreeSizeStack.last += subtreeSize + 1;
    }

    // Stable-element tracking: check if this element's widget identity
    // matches the previous scan. Const widgets keep the same instance.
    final stableChildren = _stableCountStack.removeLast();
    final key = identityHashCode(element);
    final prevWidgetId = _elementWidgetSnapshots[key];
    final currWidgetId = _newElementWidgetSnapshots[key];
    final isStable = prevWidgetId != null && prevWidgetId == currWidgetId;
    final totalStable = stableChildren + (isStable ? 1 : 0);
    if (_stableCountStack.isNotEmpty) {
      _stableCountStack.last += totalStable;
    }

    // Track max inline — same filters as checkElement:
    // skip private-named and framework-owned StatefulWidgets so that
    // Scaffold, Navigator, Overlay, etc. never become the "widest" candidate.
    if (element is StatefulElement && subtreeSize > _maxSubtreeSize) {
      final name = element.widget.runtimeType.toString();
      if (!name.startsWith('_') && !isFrameworkWidget(element.widget)) {
        _maxSubtreeSize = subtreeSize;
        _maxStableCount = totalStable;
        _widestStatefulWidget = name;
        _widestElement = element;
      }
    }
  }

  @override
  void finalizeScan() {
    // Only commit scan results when the walk completed without exceptions.
    // This is set by notifyWalkCompleted(), called by the controller (unified
    // walk) or BaseDetector.scanTree (single-detector walk) only on success.
    // Covers all abort paths: mid-subtree throws (stack non-empty),
    // first-element throws (stack empty, _totalElements == 0), and
    // between-sibling throws (stack empty, _totalElements > 0).
    _subtreeSizeStack.clear();
    _stableCountStack.clear();
    if (!_walkCompleted) return;

    // Swap snapshots
    _childSnapshots = _newSnapshots;
    _elementWidgetSnapshots = _newElementWidgetSnapshots;

    if (_totalElements == 0 || _maxSubtreeSize < minSubtreeSize) return;

    // Combine signals to decide whether to flag
    final hasRebuildEvidence = hasRebuildEvidenceFor(_widestStatefulWidget!);

    // Use mutable (non-const) element count for ratio when rebuild evidence
    // exists. Without a rebuild, all elements appear "stable" (no change),
    // which doesn't mean they're const — just that nothing triggered build().
    // First scan has no baseline, so _maxStableCount is 0 (conservative).
    final mutableSubtreeSize = hasRebuildEvidence
        ? _maxSubtreeSize - _maxStableCount
        : _maxSubtreeSize;
    final ratio = mutableSubtreeSize / _totalElements;
    if (ratio <= dirtyRatioThreshold) return;
    final hasAnimScope =
        _widestElement != null && _containsAnimationScope(_widestElement!);

    // Debug correlation — upgrade confidence if debug snapshot
    // confirms the flagged type is actually rebuilding.
    final debugCorrelation = _computeDebugCorrelation(_widestStatefulWidget!);

    final percent = (ratio * 100).toStringAsFixed(0);
    final constNote = hasRebuildEvidence && _maxStableCount > 0
        ? ' ($mutableSubtreeSize mutable of $_maxSubtreeSize total, '
            '$_maxStableCount const)'
        : '';
    final rawChain =
        _widestElement != null ? buildAncestorChain(_widestElement!) : null;
    final location = rawChain != null ? '\n\n  • $rawChain' : '';

    if (hasRebuildEvidence) {
      final baseConfidence =
          hasAnimScope ? IssueConfidence.possible : IssueConfidence.likely;

      final (hint, effort) = FixHintBuilder.setStateScope(
        widgetName: _widestStatefulWidget ?? 'Unknown',
        subtreePercent: int.tryParse(percent) ?? 0,
        ancestorChain: rawChain,
      );

      _issues.add(
        PerformanceIssue(
          stableId: 'setstate_scope',
          severity:
              ratio > 0.5 ? IssueSeverity.critical : IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: debugCorrelation?.confidence ?? baseConfidence,
          title:
              'Wide setState Scope: $_widestStatefulWidget owns ~$percent% of tree',
          detail:
              '$_widestStatefulWidget has $_maxSubtreeSize of $_totalElements '
              'elements (~$percent%) in its subtree$constNote. Rebuild '
              'activity was detected on this wide subtree.$location',
          fixHint: hint,
          fixEffort: effort,
          widgetName: _widestStatefulWidget,
          ancestorChain: rawChain,
          observationSource:
              debugCorrelation?.source ?? ObservationSource.structural,
          detectedAt: DateTime.now(),
        ),
      );
      _addHighlight(_widestElement!, _widestStatefulWidget!, hasRebuildEvidence,
          percent, _maxSubtreeSize);
    } else if (!hasAnimScope) {
      final (hint2, effort2) = FixHintBuilder.setStateScope(
        widgetName: _widestStatefulWidget ?? 'Unknown',
        subtreePercent: int.tryParse(percent) ?? 0,
        ancestorChain: rawChain,
      );

      _issues.add(
        PerformanceIssue(
          stableId: 'setstate_scope',
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: debugCorrelation?.confidence ?? IssueConfidence.possible,
          title:
              'Wide setState Scope: $_widestStatefulWidget owns ~$percent% of tree',
          detail:
              '$_widestStatefulWidget has $_maxSubtreeSize of $_totalElements '
              'elements (~$percent%) in its subtree$constNote. Any setState() '
              'on this widget would rebuild most of the visible tree.$location',
          fixHint: hint2,
          fixEffort: effort2,
          widgetName: _widestStatefulWidget,
          ancestorChain: rawChain,
          observationSource:
              debugCorrelation?.source ?? ObservationSource.structural,
          detectedAt: DateTime.now(),
        ),
      );
      _addHighlight(_widestElement!, _widestStatefulWidget!, hasRebuildEvidence,
          percent, _maxSubtreeSize);
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

  void _addHighlight(Element element, String widgetName,
      bool hasRebuildEvidence, String percent, int subtreeSize) {
    final ro = element.renderObject;
    if (ro == null) return;
    final rect = getGlobalRect(ro);
    if (rect == null) return;
    _highlights.add(WidgetHighlight(
      rect: rect,
      widgetName: widgetName,
      severity:
          hasRebuildEvidence ? IssueSeverity.critical : IssueSeverity.warning,
      detectorName: 'setState',
      detail: 'Owns ~$percent% of tree ($subtreeSize elements)',
    ));
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
    // _ModalScope<T> runtimeType includes the generic parameter
    // (e.g. '_ModalScope<dynamic>'), so use startsWith.
    if (name.startsWith('_ModalScope')) return true;
    return _frameworkWidgetNames.contains(name);
  }

  static const _frameworkWidgetNames = {
    'ScaffoldMessenger',
    'MaterialApp',
    'WidgetsApp',
    'CupertinoApp',
    'CupertinoPageScaffold',
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
    _elementWidgetSnapshots.clear();
    _rebuildEvidence.clear();
    _pendingEvidence.clear();
    _typeInstanceCounts.clear();
    _subtreeSizeStack.clear();
    _stableCountStack.clear();
  }
}
