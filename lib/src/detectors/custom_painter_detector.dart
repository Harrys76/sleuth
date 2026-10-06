import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/framework_painters.dart';
import '../utils/widget_location.dart';

/// Detects CustomPainter where shouldRepaint always returns true.
///
/// **Structural Detector** — checks CustomPaint widgets for always-true repaint.
class CustomPainterDetector extends BaseDetector with DetectorMetadataProvider {
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

  /// User (non-framework) CustomPaint widgets seen this scan. The
  /// type-aggregated paint-rate heuristic needs at least one.
  int _userPaintCount = 0;
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
    _userPaintCount = 0;
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    // Framework-owned painters (toggles, scrollbars, Material shape
    // borders, tab indicators, ...) are not user code.
    if (widget is CustomPaint && !isFrameworkPainterPaint(element)) {
      _userPaintCount++;
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
            _highlights.add(
              WidgetHighlight(
                rect: rect,
                renderObject: ro,
                widgetName: 'CustomPaint',
                severity: IssueSeverity.warning,
                detectorName: 'Painter',
                detail: 'shouldRepaint always true',
              ),
            );
          }
        }
      }
    } catch (e, s) {
      assert(() {
        debugPrint('Sleuth: shouldRepaint check failed: $e\n$s');
        return true;
      }());
    }
  }

  @override
  void finalizeScan() {
    if (_found.isNotEmpty) {
      final locations = _found.take(5).map((chain) => '  • $chain').join('\n');

      // Check debug snapshot for CustomPaint repaint activity.
      IssueConfidence confidence = IssueConfidence.possible;
      ObservationSource? source;
      final ds = _lastDebugSnapshot;
      if (ds != null && _customPaintOriginRate(ds) > 10) {
        confidence = IssueConfidence.likely;
        source = ObservationSource.debugCallbackAndStructural;
      }

      final (hint1, effort1) = FixHintBuilder.alwaysRepaintPainter();

      _issues.add(
        PerformanceIssue(
          stableId: 'always_repaint_painter',
          severity: IssueSeverity.warning,
          category: IssueCategory.paint,
          confidence: confidence,
          title: 'Always-Repaint CustomPainter: ${_found.length} found',
          detail:
              '${_found.length} CustomPainter(s) return true from '
              'shouldRepaint(). This causes unnecessary repaint on every '
              'frame.\n\n$locations',
          fixHint: hint1,
          fixEffort: effort1,
          observationSource: source,
          confidenceReason:
              'Structural scan only — connect VM for higher confidence',
          detectedAt: DateTime.now(),
        ),
      );
    }

    // Secondary heuristic: painters that passed self-comparison but start
    // repaints often may have problematic shouldRepaint logic that only
    // manifests with different old/new instances.
    if (_found.isEmpty && _userPaintCount > 0) {
      final ds = _lastDebugSnapshot;
      if (ds != null) {
        final cpRate = _customPaintOriginRate(ds);
        if (cpRate > 30) {
          final (hint2, effort2) = FixHintBuilder.frequentRepaintPainter();

          _issues.add(
            PerformanceIssue(
              stableId: 'frequent_repaint_painter',
              severity: IssueSeverity.warning,
              category: IssueCategory.paint,
              confidence: IssueConfidence.possible,
              title: 'Frequent CustomPainter Repaints: ${cpRate.round()}/sec',
              detail:
                  'A CustomPaint was the likely origin of '
                  '${cpRate.round()} repaints/sec. Verify shouldRepaint() '
                  "returns false when visual state hasn't changed.",
              fixHint: hint2,
              fixEffort: effort2,
              observationSource: ObservationSource.debugCallbackAndStructural,
              confidenceReason:
                  'Debug callback likely-origin rate + structural scan',
              detectedAt: DateTime.now(),
            ),
          );
        }
      }
    }
  }

  /// Repaints per second the busiest CustomPaint was the likely origin
  /// of, leaving out frames an animation owner drove
  /// ([DebugSnapshot.paintOrigins]). A CustomPaint that only repaints
  /// because something else in its layer did never reaches its painter's
  /// shouldRepaint, so those paints are not counted; animation-driven
  /// repaints (progress indicators, transitions) are expected every frame
  /// and say nothing about shouldRepaint either.
  static double _customPaintOriginRate(DebugSnapshot snapshot) =>
      snapshot.paintOriginsPerSecondForType('CustomPaint');

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _userPaintCount = 0;
    _lastDebugSnapshot = null;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hermetic reproducer pins both emission branches: '
        '`always_repaint_painter` (shouldRepaint self-comparison returns '
        'true, exercised on both `painter` and `foregroundPainter` '
        'slots) and `frequent_repaint_painter` (CustomPaint '
        'likely-origin repaints/sec > 30 for the busiest instance, '
        'excluding animation-owned repaints and repaints it only shared '
        'with its layer, via injected `DebugSnapshot`, silent at the '
        'threshold, strict-greater). The "always-repaint suppresses frequent" '
        'ordering contract is pinned as a negative control so both '
        'branches cannot fire simultaneously. Framework toggle and '
        'scrollbar painters (ToggleablePainter, ScrollbarPainter) are '
        'skipped, as are private framework painters matched by class '
        'name plus an owner widget within a measured hop budget (Material '
        'shape borders, input borders, TabBar indicator and divider, '
        'progress and activity indicators, overscroll glow and stretch, '
        'AnimatedIcon, dropdown menu, Placeholder, GridPaper; hop counts '
        'recorded on RepaintBoundaryDetector). A TabBar image indicator '
        'whose image just arrived (shouldRepaint(self) true until the '
        'next paint) is pinned silent on a real decode, and a user '
        'always-repaint painter carrying a framework painter name outside '
        'its owner still fires. The paint-rate branch needs at least one '
        'user CustomPaint in the scan. Not yet runtime-verified '
        'against a real paint-counter stream.',
    reproducerPath: 'test/validation/custom_painter_reproducer_test.dart',
    coveredStableIds: {'always_repaint_painter', 'frequent_repaint_painter'},
  );
}
