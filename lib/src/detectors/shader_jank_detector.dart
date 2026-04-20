import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Detects shader compilation jank from VM Timeline events.
///
/// **VM-Only Detector** — flags shader compilations >100ms.
/// On Impeller (default since Flutter 3.16), shaders are pre-compiled at
/// build time so this detector correctly produces no issues.
class ShaderJankDetector extends BaseDetector with DetectorMetadataProvider {
  ShaderJankDetector({this.thresholdMs = 100})
      : super(
          type: DetectorType.shaderJank,
          lifecycle: DetectorLifecycle.vmOnly,
          name: 'Shader Jank',
          description: 'Detects shader compilation spikes (>100ms)',
        );

  final int thresholdMs;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;
  int _totalShaderEvents = 0;
  int _emptyPollsSinceLastShader = 0;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    if (data.shaderCompileDurations.isEmpty) {
      _emptyPollsSinceLastShader++;
      if (_emptyPollsSinceLastShader > 3) {
        _issues.clear();
      }
      return;
    }

    // Shader events found — reset empty counter.
    _emptyPollsSinceLastShader = 0;
    _issues.clear();

    for (final durationUs in data.shaderCompileDurations) {
      _totalShaderEvents++;
      final ms = durationUs / 1000;
      if (ms >= thresholdMs) {
        final (hint, effort) = FixHintBuilder.shaderCompilation();
        _issues.add(PerformanceIssue(
          stableId: 'shader_compilation',
          severity: ms >= thresholdMs * 2
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
          title: 'Shader Compilation: ${ms.toStringAsFixed(0)}ms',
          detail:
              'A shader was compiled on-the-fly causing a ${ms.toStringAsFixed(0)}ms '
              'spike. Total shader events so far: $_totalShaderEvents.',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.vmTimeline,
          detectedAt: DateTime.now(),
          confidenceReason:
              'Measured directly from VM timeline shader_compile events',
        ));
      }
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _emptyPollsSinceLastShader = 0;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.unvalidated,
        rationale: 'Shader-compile duration threshold for first-frame jank '
            'attribution. Not runtime-verified against Impeller/Skia '
            'shader-compile budgets or externally cited.',
      );
}
