import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/widget_location.dart';

/// Detects Opacity widgets with opacity == 0.0.
///
/// **Structural Detector** — Opacity(0.0) short-circuits painting but the
/// widget still participates in hit testing, layout, and semantics.
/// Visibility or conditional removal is usually more correct.
class OpacityDetector extends BaseDetector {
  OpacityDetector()
      : super(
          type: DetectorType.opacity,
          lifecycle: DetectorLifecycle.structural,
          name: 'Opacity',
          description:
              'Detects Opacity(0.0) — invisible but still in layout/hit testing',
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

  @override
  void scanTree(BuildContext context) {
    if (!_isEnabled) return;
    _issues.clear();
    _highlights.clear();

    final found = <String>[];

    void visitor(Element element) {
      final widget = element.widget;

      if (widget is Opacity && widget.opacity == 0.0) {
        found.add(buildAncestorChain(element));
        final ro = element.renderObject;
        if (ro != null) {
          final rect = getGlobalRect(ro);
          if (rect != null) {
            _highlights.add(WidgetHighlight(
              rect: rect,
              widgetName: 'Opacity',
              severity: IssueSeverity.warning,
              detectorName: 'Opacity',
              detail: 'opacity: 0.0 — invisible but still active',
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
      _issues.add(
        PerformanceIssue(
          stableId: 'opacity_zero',
          severity: IssueSeverity.warning,
          category: IssueCategory.layout,
          confidence: IssueConfidence.possible,
          title: 'Invisible Opacity Widgets Still Active: ${found.length}',
          detail: '${found.length} Opacity widget(s) have opacity set to 0.0. '
              'Painting is skipped, but the widget still participates in '
              'hit testing, layout, and semantics.\n\n$locations',
          fixHint: 'If the widget should disappear entirely, remove it from '
              'the tree. If it should stay in layout, use Visibility with the '
              'maintain* flags chosen intentionally. Add IgnorePointer or '
              'ExcludeSemantics if hidden content should also stop receiving '
              'taps or accessibility focus.',
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
