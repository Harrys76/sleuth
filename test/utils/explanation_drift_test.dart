import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/detector_thresholds.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';
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
/// window (5 s), heap_growing sustain window (10 s), critical multipliers
/// for rebuild_activity (3×) and heavy_compute (2×).
void main() {
  const config = SleuthConfig();
  const thresholds = DetectorThresholds();
  final frameTiming = FrameTimingDetector();
  final setStateScope = SetStateScopeDetector();

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
      '>${config.rebuildThreshold}/sec',
    ),
    (
      'heavy_compute',
      _Field.readingTheData,
      '>${thresholds.heavyComputeGapMs ?? DetectorThresholds.defaultHeavyComputeGapMs}ms '
          '(warning)',
    ),
  ];

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
