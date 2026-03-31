import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// Detects expensive GPU widgets without a [RepaintBoundary] ancestor.
///
/// **Structural Detector** — walks the element tree for [Opacity],
/// [ClipPath], [BackdropFilter], [ShaderMask], and [CustomPaint] widgets,
/// then checks the render tree for a [RenderRepaintBoundary] within
/// [maxAncestorDepth] parent levels. Missing boundaries allow repaints to
/// propagate up the tree unnecessarily.
class RepaintBoundaryDetector extends BaseDetector {
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

  /// Widget type names used for paint rate lookup in [DebugSnapshot].
  static const _expensiveTypeNames = [
    'Opacity',
    'ClipPath',
    'BackdropFilter',
    'ShaderMask',
    'CustomPaint',
  ];

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _typeNames.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    if (widget is Opacity ||
        widget is ClipPath ||
        widget is BackdropFilter ||
        widget is ShaderMask ||
        widget is CustomPaint) {
      final ro = element.renderObject;
      if (ro != null && !_hasRepaintBoundaryAncestor(ro)) {
        _found.add(buildAncestorChain(element));
        _typeNames.add(widget.runtimeType.toString());
        final rect = getGlobalRect(ro);
        if (rect != null) {
          _highlights.add(WidgetHighlight(
            rect: rect,
            widgetName: widget.runtimeType.toString(),
            severity: IssueSeverity.warning,
            detectorName: 'RepaintBoundary',
            detail: 'No RepaintBoundary within $maxAncestorDepth ancestors',
          ));
        }
      }
    }
  }

  @override
  void finalizeScan() {
    if (_found.isNotEmpty) {
      final locations = _found.take(5).map((chain) => '  • $chain').join('\n');

      // Check debug snapshot for paint activity across expensive types.
      IssueConfidence confidence = IssueConfidence.possible;
      ObservationSource? source;
      final ds = _lastDebugSnapshot;
      if (ds != null && ds.paintCounts.isNotEmpty) {
        double maxRate = 0;
        for (final typeName in _expensiveTypeNames) {
          final rate = ds.paintsPerSecondForType(typeName);
          if (rate > maxRate) maxRate = rate;
        }
        if (maxRate > 30) {
          confidence = IssueConfidence.confirmed;
          source = ObservationSource.debugCallbackAndStructural;
        } else if (maxRate > 10) {
          confidence = IssueConfidence.likely;
          source = ObservationSource.debugCallbackAndStructural;
        }
      }

      // Determine most common widget type for fix hint context.
      final typeCounts = <String, int>{};
      for (final name in _typeNames) {
        typeCounts[name] = (typeCounts[name] ?? 0) + 1;
      }
      final dominantType =
          typeCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

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
          title: 'Missing RepaintBoundary: ${_found.length} expensive '
              'widget${_found.length == 1 ? '' : 's'} unprotected',
          detail: '${_found.length} GPU-expensive widget(s) found without a '
              'RepaintBoundary ancestor within $maxAncestorDepth levels. '
              'Repaints propagate up the render tree unnecessarily.'
              '\n\n$locations',
          fixHint: hint,
          fixEffort: effort,
          observationSource: source,
          detectedAt: DateTime.now(),
        ),
      );
    }
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
    _lastDebugSnapshot = null;
  }
}
