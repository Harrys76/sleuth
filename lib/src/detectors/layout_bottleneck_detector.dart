import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// Detects intrinsic dimension render objects that cause layout bottlenecks.
///
/// **Structural Detector** — scans render tree for RenderIntrinsicHeight/Width.
/// Nested intrinsics are escalated to critical severity (exponential layout).
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
  final List<({String name, bool nested})> _found = [];
  int _intrinsicDepth = 0;
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
    _found.clear();
    _intrinsicDepth = 0;
  }

  @override
  void checkElement(Element element) {
    final ro = element.renderObject;
    if (ro != null) {
      final typeName = ro.runtimeType.toString();
      if (typeName.contains('RenderIntrinsicHeight') ||
          typeName.contains('RenderIntrinsicWidth')) {
        final isNested = _intrinsicDepth > 0;
        final widgetName = element.widget.runtimeType.toString();
        _found.add((name: widgetName, nested: isNested));
        _intrinsicDepth++;
        final rect = getGlobalRect(ro);
        if (rect != null) {
          _highlights.add(WidgetHighlight(
            rect: rect,
            widgetName: widgetName,
            severity: isNested ? IssueSeverity.critical : IssueSeverity.warning,
            detectorName: 'Layout',
            detail: isNested
                ? 'Nested intrinsic — O(N²+) layout'
                : 'Causes O(N^2) layout passes',
          ));
        }
      }
    }
  }

  @override
  void afterElement(Element element) {
    final ro = element.renderObject;
    if (ro != null) {
      final typeName = ro.runtimeType.toString();
      if (typeName.contains('RenderIntrinsicHeight') ||
          typeName.contains('RenderIntrinsicWidth')) {
        _intrinsicDepth--;
      }
    }
  }

  @override
  void finalizeScan() {
    if (_found.isNotEmpty) {
      final hasNested = _found.any((f) => f.nested);
      final locations = _found.take(5).map((f) {
        final prefix = f.nested ? '⚠ ' : '';
        return '  • $prefix${f.name}${f.nested ? ' (nested)' : ''}';
      }).join('\n');
      final (hint, effort) = FixHintBuilder.layoutBottleneck();

      _issues.add(PerformanceIssue(
        stableId: 'layout_bottleneck',
        severity: hasNested ? IssueSeverity.critical : IssueSeverity.warning,
        category: IssueCategory.layout,
        // confirmed: IntrinsicHeight/Width always triggers two-pass layout
        // (framework guarantee — not a heuristic)
        confidence: IssueConfidence.confirmed,
        title: hasNested
            ? 'Nested Layout Bottleneck: ${_found.length} intrinsic nodes'
            : 'Layout Bottleneck: ${_found.length} intrinsic nodes',
        detail: hasNested
            ? 'Found ${_found.length} IntrinsicHeight/IntrinsicWidth widgets '
                'including nested intrinsics. Nesting multiplies layout '
                'passes exponentially.\n\n$locations'
            : 'Found ${_found.length} IntrinsicHeight/IntrinsicWidth '
                'widgets. These cause O(N²) layout passes.\n\n$locations',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
      ));
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _intrinsicDepth = 0;
  }
}
