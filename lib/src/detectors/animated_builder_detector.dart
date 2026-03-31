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

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _found.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    if (widget is AnimatedBuilder && widget.child == null) {
      if (isFrameworkOwned(element)) {
        return;
      }

      int subtreeSize = 0;
      void countSubtree(Element child) {
        subtreeSize++;
        child.visitChildren(countSubtree);
      }

      element.visitChildren(countSubtree);

      if (subtreeSize > minSubtreeSize) {
        _found.add(buildAncestorChain(element));
        final ro = element.renderObject;
        if (ro != null) {
          final rect = getGlobalRect(ro);
          if (rect != null) {
            _highlights.add(WidgetHighlight(
              rect: rect,
              widgetName: 'AnimatedBuilder',
              severity: IssueSeverity.warning,
              detectorName: 'AnimatedBuilder',
              detail: 'No child — $subtreeSize widgets rebuild per tick',
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

      // Check debug snapshot for AnimatedBuilder rebuild/paint evidence.
      String? debugEvidence;
      IssueConfidence confidence = IssueConfidence.possible;
      ObservationSource? source;
      final ds = _lastDebugSnapshot;
      if (ds != null) {
        final abRate = ds.rebuildsPerSecond('AnimatedBuilder');
        final paintRate = ds.paintsPerSecondForType('AnimatedBuilder');
        if (abRate > 30) {
          debugEvidence = 'AnimatedBuilder rebuilding at ${abRate.round()}/sec'
              '${paintRate > 30 ? ', painting at ${paintRate.round()}/sec' : ''}'
              ' (debug callback).';
          confidence = IssueConfidence.likely;
          source = ObservationSource.debugCallbackAndStructural;
        }
      }

      final (hint, effort) = FixHintBuilder.animatedBuilderNoChild(
        widgetName: 'AnimatedBuilder',
        ancestorChain: _found.isNotEmpty ? _found.first : null,
      );

      _issues.add(
        PerformanceIssue(
          stableId: 'animated_builder_no_child',
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: confidence,
          title: 'AnimatedBuilder without child: ${_found.length} found',
          detail: '${_found.length} AnimatedBuilder(s) do not use the child '
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
    _lastDebugSnapshot = null;
  }
}
