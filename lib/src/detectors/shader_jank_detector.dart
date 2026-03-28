import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../vm/timeline_parser.dart';

/// Detects shader compilation jank from VM Timeline events.
///
/// **VM-Only Detector** — flags shader compilations >100ms.
class ShaderJankDetector extends BaseDetector {
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

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;
    _issues.clear();

    for (final durationUs in data.shaderCompileDurations) {
      _totalShaderEvents++;
      final ms = durationUs / 1000;
      if (ms >= thresholdMs) {
        _issues.add(PerformanceIssue(
          stableId: 'shader_compilation',
          severity: ms >= 200 ? IssueSeverity.critical : IssueSeverity.warning,
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
          title: 'Shader Compilation: ${ms.toStringAsFixed(0)}ms',
          detail:
              'A shader was compiled on-the-fly causing a ${ms.toStringAsFixed(0)}ms '
              'spike. Total shader events so far: $_totalShaderEvents.',
          fixHint:
              'Use "flutter run --profile --cache-sksl" to warm up shaders, '
              'then "flutter build --bundle-sksl-path" to pre-compile them.',
          observationSource: ObservationSource.vmTimeline,
          detectedAt: DateTime.now(),
        ));
      }
    }
  }

  @override
  void dispose() => _issues.clear();
}
