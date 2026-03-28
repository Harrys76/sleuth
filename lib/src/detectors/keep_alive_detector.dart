import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
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

  @override
  void scanTree(BuildContext context) {
    if (!_isEnabled) return;
    _issues.clear();
    _highlights.clear();

    int keepAliveCount = 0;
    final parentLocations = <String>[];
    Rect? parentRect;

    void countKeepAlives(Element element) {
      if (element.widget.runtimeType.toString() == 'KeepAlive') {
        keepAliveCount++;
      }
      element.visitChildren(countKeepAlives);
    }

    void visitor(Element element) {
      final widget = element.widget;
      final name = widget.runtimeType.toString();

      if (widget is PageView || name == 'TabBarView') {
        final before = keepAliveCount;
        element.visitChildren(countKeepAlives);
        if (keepAliveCount > before) {
          parentLocations.add(buildAncestorChain(element));
          final ro = element.renderObject;
          if (ro != null) parentRect = getGlobalRect(ro);
        }
        return;
      }

      element.visitChildren(visitor);
    }

    try {
      context.visitChildElements(visitor);
    } catch (_) {}

    if (keepAliveCount > threshold) {
      if (parentRect != null) {
        _highlights.add(WidgetHighlight(
          rect: parentRect!,
          widgetName: 'Scrollable',
          severity: keepAliveCount > threshold * 2
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          detectorName: 'KeepAlive',
          detail: '$keepAliveCount items kept alive in memory',
        ));
      }
      final locations =
          parentLocations.take(5).map((chain) => '  • $chain').join('\n');
      _issues.add(
        PerformanceIssue(
          stableId: 'excessive_keep_alive',
          severity: keepAliveCount > threshold * 2
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
          title: 'Excessive Keep-Alive: $keepAliveCount widgets',
          detail: '$keepAliveCount widgets are using '
              'AutomaticKeepAliveClientMixin, keeping them all in '
              'memory.\n\n$locations',
          fixHint: 'Remove AutomaticKeepAliveClientMixin from most items. '
              'Only keep alive items with expensive state. Let others '
              'rebuild naturally when scrolled back to.',
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
