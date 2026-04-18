import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// Detects Opacity/AnimatedOpacity widgets with opacity exactly 0.0.
///
/// **Structural Detector** — Opacity(0.0) short-circuits painting but the
/// widget still participates in hit testing, layout, and semantics.
/// Visibility or conditional removal is usually more correct.
///
/// For AnimatedOpacity, only flags when the animation has settled
/// (completed/dismissed) to avoid transient false positives during fade-in.
class OpacityDetector extends BaseDetector with DetectorMetadataProvider {
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
  final List<String> _found = [];
  bool _isEnabled = true;

  /// Depth counter: >0 when inside an [AnimatedOpacity] subtree.
  /// AnimatedOpacity internally builds a FadeTransition — suppress the
  /// internal one to avoid double-counting.
  int _insideAnimatedOpacity = 0;

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
    _insideAnimatedOpacity = 0;
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    // Static Opacity: exact zero only (v9.1). Values like 0.005 are technically
    // visible and should not be flagged as "invisible."
    if (widget is Opacity && widget.opacity == 0.0) {
      _found.add(buildAncestorChain(element));
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
    } else if (widget is AnimatedOpacity) {
      _insideAnimatedOpacity++;
      _checkSettledAtZero(element, 'AnimatedOpacity');
    } else if (widget is FadeTransition && _insideAnimatedOpacity == 0) {
      // Only flag standalone FadeTransition — AnimatedOpacity internally
      // builds a FadeTransition, which is already counted at the parent level.
      _checkSettledAtZero(element, 'FadeTransition');
    }
  }

  @override
  void afterElement(Element element) {
    if (element.widget is AnimatedOpacity) {
      _insideAnimatedOpacity--;
    }
  }

  /// Shared check for AnimatedOpacity / FadeTransition: both produce
  /// [RenderAnimatedOpacity]. Flag only when settled at 0.0.
  void _checkSettledAtZero(Element element, String widgetName) {
    final ro = element.renderObject;
    if (ro is RenderAnimatedOpacity) {
      final currentOpacity = ro.opacity.value;
      final status = ro.opacity.status;
      if (currentOpacity == 0.0 &&
          (status == AnimationStatus.completed ||
              status == AnimationStatus.dismissed)) {
        _found.add(buildAncestorChain(element));
        final rect = getGlobalRect(ro);
        if (rect != null) {
          _highlights.add(WidgetHighlight(
            rect: rect,
            widgetName: widgetName,
            severity: IssueSeverity.warning,
            detectorName: 'Opacity',
            detail: 'opacity: 0.0 — invisible but still active',
          ));
        }
      }
    }
  }

  @override
  void finalizeScan() {
    if (_found.isNotEmpty) {
      final locations = _found.take(5).map((chain) => '  • $chain').join('\n');
      final (hint, effort) = FixHintBuilder.opacityZero();
      _issues.add(
        PerformanceIssue(
          stableId: 'opacity_zero',
          severity: IssueSeverity.warning,
          category: IssueCategory.layout,
          // confirmed: directly reading widget.opacity — not a heuristic
          confidence: IssueConfidence.confirmed,
          title: 'Invisible Opacity Widgets Still Active: ${_found.length}',
          detail: '${_found.length} widget(s) have opacity 0.0. '
              'Painting is skipped, but the widget still '
              'participates in hit testing, layout, and semantics.\n\n$locations',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.structural,
          confidenceReason:
              'Confirmed — widget opacity value directly observed as 0.0',
          detectedAt: DateTime.now(),
        ),
      );
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _insideAnimatedOpacity = 0;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.unvalidated,
        rationale:
            'Opacity(0) skip heuristic and saveLayer-cost threshold. Not '
            'runtime-verified or cited to Flutter paint-phase guidance.',
      );
}
