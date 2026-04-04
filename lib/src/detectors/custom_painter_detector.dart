import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// Detects CustomPainter where shouldRepaint always returns true.
///
/// **Structural Detector** — checks CustomPaint widgets for always-true repaint.
class CustomPainterDetector extends BaseDetector {
  CustomPainterDetector()
      : super(
          type: DetectorType.customPainter,
          lifecycle: DetectorLifecycle.structural,
          name: 'CustomPainter',
          description: 'Detects CustomPainter with shouldRepaint always true',
        );

  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  final List<String> _found = [];
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

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _found.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    if (widget is CustomPaint) {
      if (widget.painter != null) {
        _checkPainter(element, widget.painter!);
      }
      if (widget.foregroundPainter != null) {
        _checkPainter(element, widget.foregroundPainter!);
      }
    }
  }

  void _checkPainter(Element element, CustomPainter painter) {
    try {
      // Known limitation: self-comparison only catches trivially wrong
      // implementations (=> true). Secondary heuristic (debug paint rate)
      // handles painters that correctly compare fields.
      if (painter.shouldRepaint(painter)) {
        _found.add(buildAncestorChain(element));
        final ro = element.renderObject;
        if (ro != null) {
          final rect = getGlobalRect(ro);
          if (rect != null) {
            _highlights.add(WidgetHighlight(
              rect: rect,
              widgetName: element.widget.runtimeType.toString(),
              severity: IssueSeverity.warning,
              detectorName: 'Painter',
              detail: 'shouldRepaint always true',
            ));
          }
        }
      }
    } catch (_) {}
  }

  @override
  void finalizeScan() {
    if (_found.isNotEmpty) {
      final locations = _found.take(5).map((chain) => '  • $chain').join('\n');

      // Check debug snapshot for CustomPaint paint activity.
      IssueConfidence confidence = IssueConfidence.possible;
      ObservationSource? source;
      final ds = _lastDebugSnapshot;
      if (ds != null && ds.paintCounts.isNotEmpty) {
        final cpRate = ds.paintsPerSecondForType('CustomPaint');
        if (cpRate > 10) {
          confidence = IssueConfidence.likely;
          source = ObservationSource.debugCallbackAndStructural;
        }
      }

      final (hint1, effort1) = FixHintBuilder.alwaysRepaintPainter();

      _issues.add(
        PerformanceIssue(
          stableId: 'always_repaint_painter',
          severity: IssueSeverity.warning,
          category: IssueCategory.paint,
          confidence: confidence,
          title: 'Always-Repaint CustomPainter: ${_found.length} found',
          detail: '${_found.length} CustomPainter(s) return true from '
              'shouldRepaint(). This causes unnecessary repaint on every '
              'frame.\n\n$locations',
          fixHint: hint1,
          fixEffort: effort1,
          observationSource: source,
          detectedAt: DateTime.now(),
        ),
      );
    }

    // Secondary heuristic: painters that passed self-comparison but have
    // high paint rates may have problematic shouldRepaint logic that
    // only manifests with different old/new instances.
    if (_found.isEmpty) {
      final ds = _lastDebugSnapshot;
      if (ds != null && ds.paintCounts.isNotEmpty) {
        final cpRate = ds.paintsPerSecondForType('CustomPaint');
        if (cpRate > 30) {
          final (hint2, effort2) = FixHintBuilder.frequentRepaintPainter();

          _issues.add(PerformanceIssue(
            stableId: 'frequent_repaint_painter',
            severity: IssueSeverity.warning,
            category: IssueCategory.paint,
            confidence: IssueConfidence.possible,
            title: 'Frequent CustomPainter Repaints: ${cpRate.round()}/sec',
            detail: 'CustomPainter is repainting at ${cpRate.round()}/sec. '
                'Verify shouldRepaint() returns false when visual state '
                "hasn't changed.",
            fixHint: hint2,
            fixEffort: effort2,
            observationSource: ObservationSource.debugCallbackAndStructural,
            detectedAt: DateTime.now(),
          ));
        }
      }
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _lastDebugSnapshot = null;
  }
}
