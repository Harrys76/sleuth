import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/detector_thresholds.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/detectors/image_memory_detector.dart';
import 'package:sleuth/src/detectors/listview_detector.dart';
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/detectors/setstate_scope_detector.dart';
import 'package:sleuth/src/utils/issue_explanation_builder.dart';

/// Which explanation field a drift row checks.
enum _Field { whatItIs, readingTheData }

String _field(IssueExplanation e, _Field f) => switch (f) {
  _Field.whatItIs => e.whatItIs,
  _Field.readingTheData => e.readingTheData ?? '',
};

/// Encyclopedia threshold text must track the defaults the detectors
/// actually run with. Every expected literal is built from a value read
/// from code (`SleuthConfig`, `DetectorThresholds`, detector defaults),
/// never from the explanation text itself.
///
/// Not covered because the constant is private: Wrap child threshold
/// (>30), SliverToBoxAdapter child threshold (>50), request-frequency
/// window (5 s), heap_growing sustain window (10 s), critical multiplier
/// for heavy_compute (2×). The 3× critical multiplier of rebuild_activity
/// and excessive_repaint is pinned by the detector tests.
void main() {
  const config = SleuthConfig();
  const thresholds = DetectorThresholds();
  final frameTiming = FrameTimingDetector();
  final setStateScope = SetStateScopeDetector();
  final gpu = GpuPressureDetector();
  final image = ImageMemoryDetector();

  final rows = <(String stableId, _Field field, String expected)>[
    (
      'slow_request',
      _Field.readingTheData,
      '${config.slowRequestThresholdMs}ms',
    ),
    (
      'slow_request',
      _Field.readingTheData,
      '${config.criticalSlowRequestThresholdMs}ms',
    ),
    (
      'heap_growing',
      _Field.readingTheData,
      '>${thresholds.memoryGrowthBytesPerSec ~/ 1000} KB/s',
    ),
    (
      'gc_pressure',
      _Field.readingTheData,
      '>${config.gcRateThresholdPerMin}/min',
    ),
    (
      'gc_pressure',
      _Field.readingTheData,
      'more than ${config.gcRateThresholdPerMin ~/ 6} cycles in 10 seconds',
    ),
    (
      'heap_near_capacity',
      _Field.whatItIs,
      '${(thresholds.memoryCapacityPercent * 100).round()}% or more of the '
          'memory budget',
    ),
    (
      'heap_near_capacity',
      _Field.readingTheData,
      '≥${(thresholds.memoryCapacityPercent * 100).round()}%',
    ),
    if (thresholds.memoryBudgetBytes == null)
      (
        'heap_near_capacity',
        _Field.whatItIs,
        'without one this issue never fires',
      ),
    (
      'request_frequency',
      _Field.readingTheData,
      '>${config.requestFrequencyLimit} per',
    ),
    (
      'tracked_resource_concurrent',
      _Field.whatItIs,
      'more than ${thresholds.trackedResourceMaxConcurrent} live',
    ),
    (
      'tracked_resource_long_lived',
      _Field.whatItIs,
      '${thresholds.trackedResourceLongLivedSeconds} s',
    ),
    (
      'stream_resource_growth',
      _Field.readingTheData,
      '${thresholds.streamResourceMinDelta} instances',
    ),
    (
      'sustained_jank',
      _Field.readingTheData,
      '${frameTiming.frameBuffer.capacity}-frame buffer',
    ),
    (
      'setstate_scope',
      _Field.readingTheData,
      '>${(thresholds.setStateScopeOwnershipPercent * 100).round()}%',
    ),
    (
      'setstate_scope',
      _Field.readingTheData,
      'at least ${setStateScope.minSubtreeSize} elements',
    ),
    (
      'multiple_custom_fonts',
      _Field.readingTheData,
      '>${thresholds.fontLoadingMaxFamilies} custom font families',
    ),
    (
      'stateful_density',
      _Field.readingTheData,
      '≥${RebuildDetector().statefulDensityThreshold} public',
    ),
    (
      'rebuild_activity',
      _Field.readingTheData,
      '>${thresholds.buildTimePercentThreshold.round()}% of UI-thread time '
          '(warning)',
    ),
    (
      'rebuild_activity',
      _Field.readingTheData,
      '>${(thresholds.buildTimePercentThreshold * 3).round()}% (critical)',
    ),
    (
      'excessive_repaint',
      _Field.readingTheData,
      '>${thresholds.paintTimePercentThreshold.round()}% of UI-thread time '
          '(warning)',
    ),
    (
      'excessive_repaint',
      _Field.readingTheData,
      '>${(thresholds.paintTimePercentThreshold * 3).round()}% (critical)',
    ),
    (
      'heavy_compute',
      _Field.readingTheData,
      '>${thresholds.heavyComputeGapMs ?? DetectorThresholds.defaultHeavyComputeGapMs}ms '
          '(warning)',
    ),
    (
      'raster_dominance',
      _Field.readingTheData,
      'above ${thresholds.gpuPressureRatio}×',
    ),
    (
      'raster_dominance',
      _Field.readingTheData,
      '>${thresholds.gpuPressureRatio}× (warning)',
    ),
    (
      'raster_dominance',
      _Field.readingTheData,
      '>${thresholds.gpuPressureRatio * 2}× (critical)',
    ),
    (
      'raster_dominance',
      _Field.readingTheData,
      '${gpu.minRasterDominantFrames} raster-dominant frames within one '
          'second',
    ),
    (
      'raster_dominance',
      _Field.readingTheData,
      '${gpu.maxFrameRasterFloorUs ~/ 1000} ms at 60 Hz',
    ),
    (
      'non_lazy_shrinkwrap',
      _Field.readingTheData,
      '>${ListviewDetector.shrinkWrapMinChildCount} items',
    ),
    (
      'non_lazy_shrinkwrap',
      _Field.readingTheData,
      'critical above ${ListviewDetector.shrinkWrapCriticalChildCount}',
    ),
    (
      'sliver_to_box_adapter_shrinkwrap',
      _Field.readingTheData,
      '>${ListviewDetector.shrinkWrapMinChildCount} items',
    ),
    (
      'uncached_images',
      _Field.readingTheData,
      'at ${image.oversizeRatio}× or more',
    ),
    (
      'uncached_images',
      _Field.readingTheData,
      '≥ ${image.minWastedBytes >> 20} MiB in total',
    ),
    (
      'uncached_images',
      _Field.readingTheData,
      'critical at ≥ ${image.criticalWastedBytes >> 20} MiB',
    ),
  ];

  group('VM time-share entries', () {
    for (final stableId in ['rebuild_activity', 'excessive_repaint']) {
      test('$stableId reads as a share of UI-thread time', () {
        final entry = IssueExplanationBuilder.explain(stableId)!;
        expect(entry.readingTheData, contains('% of UI-thread time'));
        expect(entry.readingTheData, isNot(contains('/sec')));
        expect(entry.whatItIs, isNot(contains('/sec')));
      });
    }
  });

  group('encyclopedia thresholds match detector defaults', () {
    for (final (stableId, field, expected) in rows) {
      test('$stableId.${field.name} contains "$expected"', () {
        final entry = IssueExplanationBuilder.explain(stableId);
        expect(entry, isNotNull, reason: 'no encyclopedia entry: $stableId');
        expect(
          _field(entry!, field),
          contains(expected),
          reason:
              '$stableId.${field.name} no longer states the default '
              '"$expected"; update the encyclopedia text or the detector '
              'default so they agree.',
        );
      });
    }
  });
}
