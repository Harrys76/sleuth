import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/detector_thresholds.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/detectors/heavy_compute_detector.dart';
import 'package:sleuth/src/detectors/image_memory_detector.dart';
import 'package:sleuth/src/detectors/keep_alive_detector.dart';
import 'package:sleuth/src/detectors/listview_detector.dart';
import 'package:sleuth/src/detectors/memory_pressure_detector.dart';
import 'package:sleuth/src/detectors/platform_channel_detector.dart';
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';
import 'package:sleuth/src/detectors/setstate_scope_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
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
/// window (5 s), heap_growing sustain window (10 s). The 3× critical
/// multiplier of rebuild_activity and excessive_repaint is pinned by the
/// detector tests.
void main() {
  const config = SleuthConfig();
  const thresholds = DetectorThresholds();
  final frameTiming = FrameTimingDetector();
  final setStateScope = SetStateScopeDetector();
  final gpu = GpuPressureDetector();
  final image = ImageMemoryDetector();
  final keepAliveThreshold = KeepAliveDetector().threshold;
  final repaintDebugRate = RepaintDetector().paintFrequencyThreshold;
  final heavyMs = DetectorThresholds.defaultHeavyComputeGapMs;
  final heavyCriticalMs = heavyMs * HeavyComputeDetector.criticalMultiplier;
  const jankPercent = FrameTimingDetector.jankPercentThreshold;
  const jankFrames = FrameTimingDetector.minJankSampleFrames;
  const severeFrames = FrameTimingDetector.sustainedSevereFrameCount;
  const severeX = FrameStats.severeJankBudgetMultiplier;

  final rows = <(String stableId, _Field field, String expected)>[
    (
      'excessive_keep_alive',
      _Field.readingTheData,
      'more than $keepAliveThreshold kept-alive subtrees',
    ),
    (
      'non_lazy_list',
      _Field.readingTheData,
      'above ${config.maxListChildren} children',
    ),
    (
      'non_lazy_list',
      _Field.readingTheData,
      'critical above ${ListviewDetector.criticalChildMultiplier} times the '
          'threshold '
          '(more than ${config.maxListChildren * ListviewDetector.criticalChildMultiplier})',
    ),
    (
      'platform_channel_traffic',
      _Field.readingTheData,
      'above ${config.platformChannelLimit}/sec (default, configurable)',
    ),
    (
      'platform_channel_traffic',
      _Field.readingTheData,
      'critical above ${PlatformChannelDetector.criticalMultiplier} times that '
          '(more than ${config.platformChannelLimit * PlatformChannelDetector.criticalMultiplier}/sec',
    ),
    (
      'heavy_compute',
      _Field.whatItIs,
      'At 60 Hz, more than $heavyMs ms is a warning and more than '
          '$heavyCriticalMs ms is critical',
    ),
    (
      'heavy_compute',
      _Field.readingTheData,
      'above ${heavyMs}ms (warning) and above ${heavyCriticalMs}ms '
          '(critical)',
    ),
    (
      'heap_near_capacity',
      _Field.readingTheData,
      'for ${MemoryPressureDetector.budgetRequiredHits} of the last '
          '${MemoryPressureDetector.budgetWindowSize} memory polls',
    ),
    (
      'jank_detected',
      _Field.whatItIs,
      'More than $jankPercent% of the buffered frames (with at least '
          '$jankFrames frames',
    ),
    (
      'jank_detected',
      _Field.readingTheData,
      'above $jankPercent%, once at least $jankFrames frames are sampled',
    ),
    (
      'sustained_jank',
      _Field.whatItIs,
      'At least $severeFrames severe frames (over $severeX times the',
    ),
    (
      'sustained_jank',
      _Field.readingTheData,
      '$severeFrames or more severe frames',
    ),
    (
      'sustained_jank',
      _Field.readingTheData,
      'frames over $severeX times the budget',
    ),
    (
      'large_response',
      _Field.readingTheData,
      'above ${config.largeResponseThresholdBytes >> 20}MB',
    ),
    (
      'large_response',
      _Field.whatItIs,
      '${config.largeResponseThresholdBytes >> 20}MB',
    ),
    (
      'request_frequency',
      _Field.whatItIs,
      '(default: ${config.requestFrequencyLimit} per',
    ),
    (
      'rebuild_debug',
      _Field.readingTheData,
      'at ${config.rebuildThreshold}/sec or more',
    ),
    (
      'rebuild_debug',
      _Field.readingTheData,
      'alert at ${RebuildDetector.builderThresholdMultiplier} times that rate',
    ),
    (
      'rebuild_debug',
      _Field.readingTheData,
      'critical above ${RebuildDetector.debugCriticalMultiplier} times the '
          'alert rate',
    ),
    for (final id in ['repaint_debug', 'excessive_repaint_debug']) ...[
      (id, _Field.readingTheData, 'at $repaintDebugRate/sec or more'),
      (
        id,
        _Field.readingTheData,
        'critical above ${RepaintDetector.debugCriticalMultiplier} times that '
            '(more than ${repaintDebugRate * RepaintDetector.debugCriticalMultiplier}/sec)',
      ),
    ],
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
      'above ${thresholds.memoryGrowthBytesPerSec ~/ 1000} KB/s',
    ),
    (
      'gc_pressure',
      _Field.readingTheData,
      'above ${config.gcRateThresholdPerMin}/min',
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
      'at ${(thresholds.memoryCapacityPercent * 100).round()}% or more',
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
      'more than ${config.requestFrequencyLimit} per',
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
      'above ${(thresholds.setStateScopeOwnershipPercent * 100).round()}%',
    ),
    (
      'setstate_scope',
      _Field.readingTheData,
      'at least ${setStateScope.minSubtreeSize} elements',
    ),
    (
      'multiple_custom_fonts',
      _Field.readingTheData,
      'more than ${thresholds.fontLoadingMaxFamilies} custom font families',
    ),
    (
      'stateful_density',
      _Field.readingTheData,
      '${RebuildDetector().statefulDensityThreshold} or more public',
    ),
    (
      'rebuild_activity',
      _Field.readingTheData,
      'above ${thresholds.buildTimePercentThreshold.round()}% of UI-thread time '
          '(warning)',
    ),
    (
      'rebuild_activity',
      _Field.readingTheData,
      'above ${(thresholds.buildTimePercentThreshold * 3).round()}% (critical)',
    ),
    (
      'excessive_repaint',
      _Field.readingTheData,
      'above ${thresholds.paintTimePercentThreshold.round()}% of UI-thread time '
          '(warning)',
    ),
    (
      'excessive_repaint',
      _Field.readingTheData,
      'above ${(thresholds.paintTimePercentThreshold * 3).round()}% (critical)',
    ),
    (
      'heavy_compute',
      _Field.readingTheData,
      'above ${thresholds.heavyComputeGapMs ?? DetectorThresholds.defaultHeavyComputeGapMs}ms '
          '(warning)',
    ),
    (
      'raster_dominance',
      _Field.readingTheData,
      'above ${thresholds.gpuPressureRatio} times',
    ),
    (
      'raster_dominance',
      _Field.readingTheData,
      'above ${thresholds.gpuPressureRatio} times (warning)',
    ),
    (
      'raster_dominance',
      _Field.readingTheData,
      'above ${thresholds.gpuPressureRatio * 2} times (critical)',
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
      'above ${ListviewDetector.shrinkWrapMinChildCount} items',
    ),
    (
      'non_lazy_shrinkwrap',
      _Field.readingTheData,
      'critical above ${ListviewDetector.shrinkWrapCriticalChildCount}',
    ),
    (
      'sliver_to_box_adapter_shrinkwrap',
      _Field.readingTheData,
      'above ${ListviewDetector.shrinkWrapMinChildCount} items',
    ),
    (
      'uncached_images',
      _Field.readingTheData,
      'at ${image.oversizeRatio} times or more',
    ),
    (
      'uncached_images',
      _Field.readingTheData,
      'at ${image.minWastedBytes >> 20} MiB of total waste',
    ),
    (
      'uncached_images',
      _Field.readingTheData,
      'critical at ${image.criticalWastedBytes >> 20} MiB',
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
