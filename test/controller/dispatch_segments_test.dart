import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

void main() {
  test('a timeline dispatch records its detector, correlate and aggregate '
      'segments within the dispatch time', () {
    final controller = SleuthController()
      ..initializeDetectorsForTest()
      ..simulateVmStateChangeForTest(true);
    addTearDown(controller.dispose);
    expect(controller.lastDispatchSegmentsForTest, (
      detectors: 0,
      correlate: 0,
      aggregate: 0,
    ));

    for (var i = 0; i < 5; i++) {
      final start = 1000000 + i * 50000;
      controller.addFrameForTest(
        FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 30),
          rasterDuration: const Duration(milliseconds: 10),
          timestamp: DateTime(2026),
          vsyncStartUs: start,
          buildStartUs: start,
          buildFinishUs: start + 30000,
          rasterStartUs: start + 30000,
          rasterFinishUs: start + 40000,
        ),
      );
    }
    final data = ParsedTimelineData(
      buildScopeDurations: const [20000],
      buildEventCount: 1,
      phaseEvents: const [
        PhaseEvent(
          phase: TimelinePhase.build,
          timestampUs: 1200000,
          durationUs: 20000,
        ),
      ],
    );

    final watch = Stopwatch()..start();
    controller.feedTimelineDataForTest(data);
    final totalUs = watch.elapsedMicroseconds;

    final s = controller.lastDispatchSegmentsForTest;
    expect(s.detectors, greaterThanOrEqualTo(0));
    expect(s.correlate, greaterThanOrEqualTo(0));
    expect(s.aggregate, greaterThanOrEqualTo(0));
    expect(s.detectors + s.correlate + s.aggregate, greaterThan(0));
    expect(s.detectors + s.correlate + s.aggregate, lessThanOrEqualTo(totalUs));
  });
}
