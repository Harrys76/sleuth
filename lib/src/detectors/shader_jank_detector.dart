import '../../sleuth.dart' show Sleuth;
import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/phase_event.dart';
import '../utils/fix_hint_builder.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../vm/timeline_parser.dart';

/// Detects shader compilation jank from VM Timeline events.
///
/// **VM-Only Detector** — flags shader compilations >100ms.
/// On Impeller (default since Flutter 3.16), shaders are pre-compiled at
/// build time so this detector correctly produces no issues.
///
/// Each emission stamps `extraTraceArgs.shaderWarmupContext` with one of
/// `'cold_start' | 'hot_path' | 'keyframe'` discriminating shader-compile
/// origin. Cold_start takes precedence over keyframe — lifecycle is the
/// more specific operator signal. Keyframe window is one-sided causal:
/// the build event must come BEFORE the shader compile.
class ShaderJankDetector extends BaseDetector with DetectorMetadataProvider {
  ShaderJankDetector({
    this.thresholdMs = 100,
    this.coldStartShaderWindowSeconds = 5,
    this.shaderKeyframeWindowMs = 100,
    int? Function()? appStartMonotonicUsForTest,
  })  : _appStartForTest = appStartMonotonicUsForTest,
        super(
          type: DetectorType.shaderJank,
          lifecycle: DetectorLifecycle.vmOnly,
          name: 'Shader Jank',
          description: 'Detects shader compilation spikes (>100ms)',
        );

  final int thresholdMs;
  final int coldStartShaderWindowSeconds;
  final int shaderKeyframeWindowMs;
  final int? Function()? _appStartForTest;
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

    final shaderEvents = data.phaseEvents
        .where((e) => e.phase == TimelinePhase.shader)
        .toList(growable: false);

    if (shaderEvents.isEmpty) {
      _emptyPollsSinceLastShader++;
      if (_emptyPollsSinceLastShader > 3) {
        _issues.clear();
      }
      return;
    }

    _emptyPollsSinceLastShader = 0;
    _issues.clear();

    for (final event in shaderEvents) {
      _totalShaderEvents++;
      final ms = event.durationUs / 1000;
      if (ms >= thresholdMs) {
        final (hint, effort) = FixHintBuilder.shaderCompilation();
        final context = _classifyShaderWarmup(event.timestampUs, data);
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
          extraTraceArgs: {'shaderWarmupContext': context},
        ));
      }
    }
  }

  String _classifyShaderWarmup(int shaderTsUs, ParsedTimelineData data) {
    final appStart = _appStartForTest?.call() ?? Sleuth.dartEntryMonotonicUs;
    // cold_start takes precedence over keyframe — lifecycle is more specific.
    if (appStart != null) {
      final deltaUs = shaderTsUs - appStart;
      final coldStartWindowUs = coldStartShaderWindowSeconds * 1000000;
      // Require non-negative delta — VM ring-buffer replay or late
      // [Sleuth.init] can surface shader events with timestamps BEFORE
      // the captured app-start, and an unguarded `<` comparison would
      // satisfy the cold-start branch trivially for any negative value.
      if (deltaUs >= 0 && deltaUs < coldStartWindowUs) {
        return 'cold_start';
      }
    }
    // One-sided keyframe window: build BEFORE shader (causal direction).
    // Limitation: correlation only checks build events in the SAME
    // poll batch. A causal build that lands in the previous poll's
    // batch and a shader compile that lands in the next poll's batch
    // are not correlated — those classify as `'hot_path'` instead of
    // `'keyframe'`. Cross-poll correlation would require a sliding
    // build-event window kept across `processTimelineData` calls; not
    // implemented because typical poll batches (~500 ms) exceed the
    // keyframe window (default 100 ms), so most causal pairs land in
    // the same batch.
    final keyframeWindowUs = shaderKeyframeWindowMs * 1000;
    final hasNearbyBuild = data.phaseEvents.any((e) =>
        e.phase == TimelinePhase.build &&
        shaderTsUs >= e.timestampUs &&
        shaderTsUs - e.timestampUs < keyframeWindowUs);
    return hasNearbyBuild ? 'keyframe' : 'hot_path';
  }

  @override
  void dispose() {
    _issues.clear();
    _emptyPollsSinceLastShader = 0;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        rationale: 'VM-only detector. Shader-compile duration threshold '
            '(100ms inclusive, 2× critical) pinned by hermetic '
            'reproducer feeding raw `List<TimelineEvent>` through '
            '`TimelineParser.parse()` into the detector — exercises the '
            'VM → parser → detector boundary including shader name '
            'variants (ShaderCompilation, Pipeline::Create, lowercase) '
            'and Impeller-zero suppression via consecutive empty polls. '
            '`extraTraceArgs.shaderWarmupContext` discriminates '
            'cold_start (within `coldStartShaderWindowSeconds` of '
            '`Sleuth.dartEntryMonotonicUs`), keyframe (build event '
            'within `shaderKeyframeWindowMs` BEFORE shader compile), '
            'and hot_path (fallback) — pinned by per-context reproducer '
            'tests with mocked app-start clock and synthetic '
            '`PhaseEvent` fixtures. Fixtures hand-built against parser '
            'allowlist; real-device capture comparison is '
            'runtime-verified-tier work.',
        reproducerPath: 'test/validation/shader_jank_reproducer_test.dart',
        coveredStableIds: {'shader_compilation'},
      );
}
