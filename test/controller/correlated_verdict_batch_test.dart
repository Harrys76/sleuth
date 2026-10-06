import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/vm/connection_mode.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

void main() {
  group('correlated verdict over a multi-frame batch', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController(
        config: const SleuthConfig(
          frameTimingWarmupFrameCount: 0,
          frameTimingWarmupDuration: Duration.zero,
        ),
      );
      controller.initializeDetectorsForTest();
      controller.markInitializedAtForTest(
        DateTime.now().subtract(const Duration(seconds: 10)),
      );
      controller.simulateVmStateChangeForTest(true);
    });

    tearDown(() {
      controller.dispose();
    });

    // Frame i: vsync at 100 ms + i × 50 ms, 30 ms build, 10 ms raster.
    int vsyncOf(int i) => 100000 + i * 50000;

    FrameStats jankFrame(int i) {
      final vsync = vsyncOf(i);
      return FrameStats(
        frameNumber: i + 1,
        uiDuration: const Duration(milliseconds: 30),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
        vsyncStartUs: vsync,
        buildStartUs: vsync + 500,
        buildFinishUs: vsync + 30500,
        rasterStartUs: vsync + 31000,
        rasterFinishUs: vsync + 41000,
      );
    }

    // Build, layout, paint and raster events inside each frame's windows:
    // every event matches a frame, each frame holds a third of the batch.
    ParsedTimelineData batchOverFrames(int frameCount) {
      final events = <PhaseEvent>[];
      for (var i = 0; i < frameCount; i++) {
        final vsync = vsyncOf(i);
        events.addAll([
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: vsync + 1000,
            durationUs: 20000 + i * 1000,
          ),
          PhaseEvent(
            phase: TimelinePhase.layout,
            timestampUs: vsync + 21000 + i * 1000,
            durationUs: 4000,
          ),
          PhaseEvent(
            phase: TimelinePhase.paint,
            timestampUs: vsync + 26000 + i * 1000,
            durationUs: 2000,
          ),
          PhaseEvent(
            phase: TimelinePhase.raster,
            timestampUs: vsync + 32000,
            durationUs: 8000,
          ),
        ]);
      }
      return ParsedTimelineData(
        buildScopeDurations: [
          for (var i = 0; i < frameCount; i++) 20000 + i * 1000,
        ],
        flushLayoutDurations: List.filled(frameCount, 4000),
        flushPaintDurations: List.filled(frameCount, 2000),
        rasterDurations: List.filled(frameCount, 8000),
        phaseEvents: events,
      );
    }

    test('three jank frames with full batch coverage yield a correlated '
        'verdict', () {
      for (var i = 0; i < 3; i++) {
        controller.addFrameForTest(jankFrame(i));
      }

      controller.feedTimelineDataForTest(batchOverFrames(3));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.isCorrelated, isTrue);
      expect(verdict.correlationCoverage, 1.0);
      // The worst jank frame wins; all three tie on duration, so the first.
      expect(verdict.frameNumber, 1);
      expect(computeConnectionMode(controller), ConnectionMode.correlated);
    });

    test('a single-frame batch with full coverage stays correlated', () {
      controller.addFrameForTest(jankFrame(0));

      controller.feedTimelineDataForTest(batchOverFrames(1));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.isCorrelated, isTrue);
      expect(verdict.correlationCoverage, 1.0);
      expect(computeConnectionMode(controller), ConnectionMode.correlated);
    });
  });
}
