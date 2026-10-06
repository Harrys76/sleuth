import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/framework_painters.dart';
import '../utils/rate_hysteresis.dart';
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

  /// Repaints per second above which a painter is flagged as frequent.
  static const double _frequentRate = 30;

  /// Repaints per second above which `always_repaint_painter` is `likely`.
  static const double _observedRate = 10;

  // The busiest CustomPaint's likely-origin rate swings with frame drops
  // (debug builds drop frames under load), so both gates hold their
  // verdict across scans the way the per-widget repaint cards do: enter
  // on one window at the rate, leave when two windows average under
  // three quarters of it or on a window with no such repaint.
  final RateHysteresis _frequent = RateHysteresis();
  final RateHysteresis _observed = RateHysteresis();

  @override
  void updateDebugSnapshot(DebugSnapshot snapshot) {
    final origins = snapshot.paintOrigins['CustomPaint'];
    final counts = {
      if (origins != null && origins.maxCount > 0)
        'CustomPaint': origins.maxCount,
    };
    final us = snapshot.elapsed.inMicroseconds;
    for (final (gate, threshold) in [
      (_frequent, _frequentRate),
      (_observed, _observedRate),
    ]) {
      gate.update(
        counts: counts,
        elapsedUs: us,
        capped: snapshot.paintOriginTypesCapped,
        // Both gates are strictly above their rate, so exactly 30/sec
        // (or 10/sec) stays silent, as the reproducer pins.
        thresholdFor: (_) => threshold + 1e-9,
        criticalMultiplier: double.infinity,
      );
    }
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
      if (_observed.held.containsKey('CustomPaint')) {
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
              'shouldRepaint(). This forces a repaint on every frame, '
              'needed or not.\n\n$locations',
          fixHint: hint1,
          fixEffort: effort1,
          observationSource: source,
          confidenceReason:
              'Structural scan only. Connect the VM for higher confidence',
          detectedAt: DateTime.now(),
        ),
      );
    }

    // Secondary heuristic: painters that passed self-comparison but start
    // repaints often may have problematic shouldRepaint logic that only
    // manifests with different old/new instances.
    if (_found.isEmpty && _userPaintCount > 0) {
      final held = _frequent.held['CustomPaint'];
      if (held != null) {
        final cpRate = held.rate;
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
                '${cpRate.round()} repaints/sec. Check that shouldRepaint() '
                'returns false when the visual state has not changed.',
            fixHint: hint2,
            fixEffort: effort2,
            observationSource: ObservationSource.debugCallbackAndStructural,
            confidenceReason:
                'Debug callback likely-origin rate and a structural scan',
            detectedAt: DateTime.now(),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _userPaintCount = 0;
    _frequent.reset();
    _observed.reset();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hermetic reproducer pins both emission branches. '
        '`always_repaint_painter` fires when the shouldRepaint '
        'self-comparison returns true, exercised on both the `painter` and '
        '`foregroundPainter` slots. `frequent_repaint_painter` fires when '
        'CustomPaint likely-origin repaints/sec are above 30 for the '
        'busiest instance (strict-greater, silent at the threshold), driven '
        'by an injected `DebugSnapshot`. That rate excludes animation-owned '
        'repaints and repaints the instance only shared with its layer. The '
        '"always-repaint suppresses frequent" ordering contract is pinned '
        'as a negative control, so both branches cannot fire at once. The '
        'detector skips framework toggle and scrollbar painters '
        '(ToggleablePainter, ScrollbarPainter). It also skips private '
        'framework painters that it matches by class name plus an owner '
        'widget within a measured hop budget: Material shape borders, input '
        'borders, the TabBar indicator and divider, progress and activity '
        'indicators, overscroll glow and stretch, AnimatedIcon, the '
        'dropdown menu, Placeholder and GridPaper. RepaintBoundaryDetector '
        'records the hop counts. A TabBar image indicator whose image just '
        'arrived (shouldRepaint(self) is true until the next paint) is '
        'pinned silent on a real decode. A user always-repaint painter with '
        'a framework painter name outside its owner still fires. The '
        'paint-rate branch needs at least one user CustomPaint in the scan. '
        'No real paint-counter stream verifies it at runtime yet.',
    reproducerPath: 'test/validation/custom_painter_reproducer_test.dart',
    coveredStableIds: {'always_repaint_painter', 'frequent_repaint_painter'},
  );
}
