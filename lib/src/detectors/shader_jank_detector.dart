import 'dart:collection';

import '../models/base_detector.dart';
import '../models/issue_measurement.dart';
import '../models/performance_issue.dart';
import '../models/phase_event.dart';
import '../utils/fix_hint_builder.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../vm/timeline_parser.dart';
import '../startup/startup_tracker.dart';

/// Detects pipeline and shader build jank from VM Timeline events.
///
/// **VM-Only Detector** — flags Impeller Vulkan pipeline builds
/// (`PipelineVK::Create`, `CreateComputePipeline`), Impeller OpenGL ES
/// program links (`LinkProgram`, the Android fallback backend) and Skia
/// shader compiles (events tagged `devtoolsTag: shaders`) of 100 ms or
/// more.
/// Impeller Metal precompiles pipelines and emits no such events, so the
/// detector stays silent there by design. Issues are `likely`: a build
/// runs on a worker thread, and only frames that need that pipeline wait
/// for it.
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
  }) : _appStartForTest = appStartMonotonicUsForTest,
       super(
         type: DetectorType.shaderJank,
         lifecycle: DetectorLifecycle.vmOnly,
         name: 'Shader Jank',
         description:
             'Detects Impeller Vulkan pipeline builds, Impeller OpenGL ES '
             'program links and Skia shader compiles of at least 100ms '
             '(silent on Impeller Metal by design)',
       );

  final int thresholdMs;
  final int coldStartShaderWindowSeconds;
  final int shaderKeyframeWindowMs;
  final int? Function()? _appStartForTest;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;
  int _totalShaderEvents = 0;
  int _emptyPollsSinceLastShader = 0;

  /// Build start times of the last [_buildMemoryBatches] batches that
  /// held builds. A pipeline worker's shader events reach Sleuth when the
  /// worker's timeline block fills or a catch-up read makes the VM post
  /// it, often a batch after the build that asked for the pipeline.
  final ListQueue<List<int>> _recentBuildBatches = ListQueue();
  static const int _buildMemoryBatches = 20;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    _rememberBuilds(data);
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
        final context = _classifyShaderWarmup(event.timestampUs);
        _issues.add(
          PerformanceIssue(
            stableId: 'shader_compilation',
            severity: ms >= thresholdMs * 2
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            category: IssueCategory.raster,
            confidence: IssueConfidence.likely,
            title: 'Shader Compilation: ${ms.toStringAsFixed(0)}ms',
            detail:
                'A pipeline or shader build took ${ms.toStringAsFixed(0)}ms. '
                'Frames that need that pipeline wait for it. Total shader '
                'events so far: $_totalShaderEvents.',
            fixHint: hint,
            fixEffort: effort,
            observationSource: ObservationSource.vmTimeline,
            detectedAt: DateTime.now(),
            confidenceReason:
                'Build duration measured from VM timeline begin and end '
                'events. Frame impact depends on whether a frame waited for '
                'it',
            extraTraceArgs: {'shaderWarmupContext': context},
            measurement: IssueMeasurement(
              value: ms,
              unit: MeasurementUnit.milliseconds,
              warningAt: thresholdMs.toDouble(),
              criticalAt: (thresholdMs * 2).toDouble(),
            ),
          ),
        );
      }
    }
  }

  String _classifyShaderWarmup(int shaderTsUs) {
    final appStart =
        _appStartForTest?.call() ?? StartupTracker.dartEntryMonotonicUs;
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
    // The build must start before the shader compile, in this batch or an
    // earlier one.
    final keyframeWindowUs = shaderKeyframeWindowMs * 1000;
    final hasNearbyBuild = _recentBuildBatches.any(
      (batch) => batch.any(
        (buildUs) =>
            shaderTsUs >= buildUs && shaderTsUs - buildUs < keyframeWindowUs,
      ),
    );
    return hasNearbyBuild ? 'keyframe' : 'hot_path';
  }

  void _rememberBuilds(ParsedTimelineData data) {
    final starts = <int>[
      for (final e in data.phaseEvents)
        if (e.phase == TimelinePhase.build) e.timestampUs,
    ];
    if (starts.isEmpty) return;
    _recentBuildBatches.addLast(starts);
    if (_recentBuildBatches.length > _buildMemoryBatches) {
      _recentBuildBatches.removeFirst();
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _emptyPollsSinceLastShader = 0;
    _recentBuildBatches.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'VM-only detector. A hermetic reproducer pins the build duration '
        'threshold (100ms inclusive, critical at 2 times) by feeding raw '
        '`List<TimelineEvent>` through `TimelineParser.parse()` into the '
        'detector. Fixtures mirror the engine shapes. They use '
        '`TRACE_EVENT` begin and end pairs for Impeller Vulkan '
        '`PipelineVK::Create` and `CreateComputePipeline`, Impeller OpenGL '
        'ES `LinkProgram`, and Skia events tagged `devtoolsTag: shaders`. '
        '`PipelineItem` and '
        '`CreateShaderLibrary` stay silent, as does an empty Impeller '
        'Metal timeline. `extraTraceArgs.shaderWarmupContext` tells apart '
        'cold_start (within `coldStartShaderWindowSeconds` of '
        '`StartupTracker.dartEntryMonotonicUs`), keyframe (a build event within '
        '`shaderKeyframeWindowMs` before the shader compile) and hot_path '
        '(the fallback). Per-context reproducer tests pin these with a '
        'mocked app-start clock and synthetic `PhaseEvent` fixtures. A '
        'real-device capture comparison on an Impeller Vulkan device '
        'belongs to the runtimeVerified tier.',
    reproducerPath: 'test/validation/shader_jank_reproducer_test.dart',
    coveredStableIds: {'shader_compilation'},
  );
}
