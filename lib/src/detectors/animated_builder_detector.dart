import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';
import 'setstate_scope_detector.dart';

/// Detects AnimatedBuilder widgets that don't use the `child` parameter.
///
/// **Structural Detector** — without `child`, the entire builder subtree
/// rebuilds on every animation tick (60x/sec), causing unnecessary work.
class AnimatedBuilderDetector extends BaseDetector {
  AnimatedBuilderDetector({this.minSubtreeSize = 50})
      : super(
          type: DetectorType.animatedBuilder,
          lifecycle: DetectorLifecycle.structural,
          name: 'AnimatedBuilder',
          description: 'Detects AnimatedBuilder without child parameter',
        );

  final int minSubtreeSize;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;
  DebugSnapshot? _lastDebugSnapshot;

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

  final List<String> _found = [];
  final List<String> _widgetNames = [];
  final List<int> _subtreeSizeStack = [];

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _widgetNames.clear();
    _subtreeSizeStack.clear();
  }

  @override
  void checkElement(Element element) {
    _subtreeSizeStack.add(0);
  }

  @override
  void afterElement(Element element) {
    final subtreeSize = _subtreeSizeStack.removeLast();
    if (_subtreeSizeStack.isNotEmpty) {
      _subtreeSizeStack.last += subtreeSize + 1;
    }

    final widget = element.widget;

    // AnimatedBuilder — framework creates these internally (scroll physics,
    // transitions), so filter via isFrameworkOwned.
    if (widget is AnimatedBuilder && widget.child == null) {
      if (isFrameworkOwned(element)) return;
      _recordNoChild(element, 'AnimatedBuilder', subtreeSize);
      return;
    }

    // TweenAnimationBuilder — always user-placed, never framework-created.
    // Skip isFrameworkOwned: TweenAnimationBuilder extends
    // ImplicitlyAnimatedWidget which isFrameworkWidget() classifies as
    // framework-owned, causing false negatives inside Scaffold/Navigator.
    if (widget is TweenAnimationBuilder && widget.child == null) {
      _recordNoChild(element, 'TweenAnimationBuilder', subtreeSize);
    }
  }

  void _recordNoChild(Element element, String widgetName, int subtreeSize) {
    if (subtreeSize <= minSubtreeSize) return;

    _found.add(buildAncestorChain(element));
    _widgetNames.add(widgetName);
    final ro = element.renderObject;
    if (ro != null) {
      final rect = getGlobalRect(ro);
      if (rect != null) {
        _highlights.add(WidgetHighlight(
          rect: rect,
          widgetName: widgetName,
          severity: IssueSeverity.warning,
          detectorName: 'AnimatedBuilder',
          detail: 'No child — $subtreeSize widgets rebuild per tick',
        ));
      }
    }
  }

  @override
  void finalizeScan() {
    _subtreeSizeStack.clear();
    if (_found.isNotEmpty) {
      final locations = _found.take(5).map((chain) => '  • $chain').join('\n');

      // Determine dominant widget name for title and hints.
      final typeCounts = <String, int>{};
      for (final name in _widgetNames) {
        typeCounts[name] = (typeCounts[name] ?? 0) + 1;
      }
      final dominantName =
          typeCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

      // Check debug snapshot for rebuild/paint evidence.
      String? debugEvidence;
      IssueConfidence confidence = IssueConfidence.possible;
      ObservationSource? source;
      final ds = _lastDebugSnapshot;
      if (ds != null) {
        for (final typeName in typeCounts.keys) {
          final abRate = ds.rebuildsPerSecond(typeName);
          final paintRate = ds.paintsPerSecondForType(typeName);
          if (abRate > 30) {
            debugEvidence = '$typeName rebuilding at ${abRate.round()}/sec'
                '${paintRate > 30 ? ', painting at ${paintRate.round()}/sec' : ''}'
                ' (debug callback).';
            confidence = IssueConfidence.likely;
            source = ObservationSource.debugCallbackAndStructural;
            break;
          }
        }
      }

      final (hint, effort) = FixHintBuilder.animatedBuilderNoChild(
        widgetName: dominantName,
        ancestorChain: _found.isNotEmpty ? _found.first : null,
      );

      _issues.add(
        PerformanceIssue(
          stableId: 'animated_builder_no_child',
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: confidence,
          title: '$dominantName without child: ${_found.length} found',
          detail: '${_found.length} animation builder(s) do not use the child '
              'parameter. The entire builder subtree rebuilds on every '
              'animation tick (60x/sec).'
              '${debugEvidence != null ? '\n\n$debugEvidence' : ''}'
              '\n\n$locations',
          fixHint: hint,
          fixEffort: effort,
          observationSource: source,
          detectedAt: DateTime.now(),
        ),
      );
    }
  }

  /// Check if this AnimatedBuilder is owned by framework code by walking
  /// up to the nearest StatefulElement and checking if it's a framework widget.
  static bool isFrameworkOwned(Element element) {
    bool frameworkOwned = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor is StatefulElement) {
        frameworkOwned =
            SetStateScopeDetector.isFrameworkWidget(ancestor.widget);
        return false; // stop walking
      }
      return true; // keep walking up
    });
    return frameworkOwned;
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _widgetNames.clear();
    _subtreeSizeStack.clear();
    _lastDebugSnapshot = null;
  }
}
