import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/widget_location.dart';

/// Detects intrinsic dimension render objects that cause layout bottlenecks.
///
/// **Structural Detector** — scans render tree for RenderIntrinsicHeight/Width.
class LayoutBottleneckDetector extends BaseDetector {
  LayoutBottleneckDetector()
      : super(
          type: DetectorType.layoutBottleneck,
          lifecycle: DetectorLifecycle.structural,
          name: 'Layout Bottleneck',
          description: 'Detects RenderIntrinsicHeight/Width nodes',
        );

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

  /// Scan render tree for layout bottleneck patterns.
  @override
  void scanTree(BuildContext context) {
    if (!_isEnabled) return;
    _issues.clear();
    _highlights.clear();

    final found = <String>[];

    void visitor(Element element) {
      final ro = element.renderObject;
      if (ro != null) {
        final typeName = ro.runtimeType.toString();
        if (typeName.contains('RenderIntrinsicHeight') ||
            typeName.contains('RenderIntrinsicWidth')) {
          final widgetName = element.widget.runtimeType.toString();
          found.add(widgetName);
          final rect = getGlobalRect(ro);
          if (rect != null) {
            _highlights.add(WidgetHighlight(
              rect: rect,
              widgetName: widgetName,
              severity: IssueSeverity.warning,
              detectorName: 'Layout',
              detail: 'Causes O(N^2) layout passes',
            ));
          }
        }
      }
      element.visitChildren(visitor);
    }

    try {
      context.visitChildElements(visitor);
    } catch (_) {}

    if (found.isNotEmpty) {
      final locations = found.take(5).map((chain) => '  • $chain').join('\n');
      _issues.add(PerformanceIssue(
        stableId: 'layout_bottleneck',
        severity: IssueSeverity.warning,
        category: IssueCategory.layout,
        confidence: IssueConfidence.possible,
        title: 'Layout Bottleneck: ${found.length} intrinsic nodes',
        detail: 'Found ${found.length} IntrinsicHeight/IntrinsicWidth '
            'widgets. These cause O(N²) layout passes.\n\n$locations',
        fixHint: 'Replace IntrinsicHeight/Width with fixed sizes, '
            'Expanded, or SizedBox where possible. '
            'Use Row/Column crossAxisAlignment instead.',
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
      ));
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
  }
}
