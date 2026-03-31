import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// Detects excessive AutomaticKeepAlive usage in PageView/TabBarView.
///
/// **Structural Detector** — >5 keep-alive pages wastes memory.
/// Only counts KeepAlive widgets inside PageView or TabBarView, where
/// entire pages/tabs are kept in memory. ListView/GridView keep-alives
/// are normal framework behavior and are not flagged.
class KeepAliveDetector extends BaseDetector {
  KeepAliveDetector({this.threshold = 5})
      : super(
          type: DetectorType.keepAlive,
          lifecycle: DetectorLifecycle.structural,
          name: 'Keep Alive',
          description: 'Detects excessive keep-alive pages (>5)',
        );

  final int threshold;
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

  int _keepAliveCount = 0;
  final List<String> _parentLocations = [];
  Rect? _parentRect;

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _keepAliveCount = 0;
    _parentLocations.clear();
    _parentRect = null;
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;
    final name = widget.runtimeType.toString();

    // TabBarView checked by string to avoid material.dart import.
    if (widget is PageView || name == 'TabBarView') {
      final before = _keepAliveCount;

      void countKeepAlives(Element child) {
        final typeName = child.widget.runtimeType.toString();
        if (typeName == 'KeepAlive' || typeName == '_KeepAlive') {
          _keepAliveCount++;
        }
        child.visitChildren(countKeepAlives);
      }

      element.visitChildren(countKeepAlives);
      if (_keepAliveCount > before) {
        _parentLocations.add(buildAncestorChain(element));
        final ro = element.renderObject;
        if (ro != null) _parentRect = getGlobalRect(ro);
      }
    }
  }

  @override
  void finalizeScan() {
    if (_keepAliveCount > threshold) {
      if (_parentRect != null) {
        _highlights.add(WidgetHighlight(
          rect: _parentRect!,
          widgetName: 'Scrollable',
          severity: _keepAliveCount > threshold * 2
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          detectorName: 'KeepAlive',
          detail: '$_keepAliveCount items kept alive in memory',
        ));
      }
      final locations =
          _parentLocations.take(5).map((chain) => '  • $chain').join('\n');
      final (hint, effort) =
          FixHintBuilder.excessiveKeepAlive(count: _keepAliveCount);

      _issues.add(
        PerformanceIssue(
          stableId: 'excessive_keep_alive',
          severity: _keepAliveCount > threshold * 2
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
          title: 'Excessive Keep-Alive: $_keepAliveCount widgets',
          detail: '$_keepAliveCount widgets are using '
              'AutomaticKeepAliveClientMixin, keeping them all in '
              'memory.\n\n$locations',
          fixHint: hint,
          fixEffort: effort,
          widgetName: 'Scrollable',
          observationSource: ObservationSource.structural,
          detectedAt: DateTime.now(),
        ),
      );
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
  }
}
