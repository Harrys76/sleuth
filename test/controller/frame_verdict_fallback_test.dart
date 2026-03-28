import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/models/frame_stats.dart';
import 'package:widget_watchdog/src/models/frame_verdict.dart';

void main() {
  group('FRAME fallback verdict path', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    FrameStats makeFrame({
      required int uiMs,
      required int rasterMs,
      int frameNumber = 1,
      int vsyncOverheadUs = 0,
    }) {
      return FrameStats(
        frameNumber: frameNumber,
        uiDuration: Duration(milliseconds: uiMs),
        rasterDuration: Duration(milliseconds: rasterMs),
        timestamp: DateTime.now(),
        vsyncOverhead: Duration(microseconds: vsyncOverheadUs),
        frameBudgetMs: 16,
      );
    }

    test('jank frame with VM disconnected produces a fallback FrameVerdict',
        () {
      // VM is not connected by default (isVmConnected = false)
      controller.addFrameForTest(makeFrame(uiMs: 30, rasterMs: 10));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.isFullMode, isFalse);
      expect(verdict.frameNumber, 1);
      // totalDuration = max(ui, raster), not sum
      expect(verdict.totalFrameTime, const Duration(milliseconds: 30));
      expect(verdict.uiThreadTime, const Duration(milliseconds: 30));
      expect(verdict.rasterThreadTime, const Duration(milliseconds: 10));
    });

    test('suspected phase is build when UI > raster', () {
      controller.addFrameForTest(makeFrame(uiMs: 30, rasterMs: 10));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.suspectedPhase, PipelinePhase.build);
    });

    test('suspected phase is raster when raster > UI', () {
      controller.addFrameForTest(makeFrame(uiMs: 10, rasterMs: 30));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.suspectedPhase, PipelinePhase.raster);
    });

    test('suspected phase is raster when raster == UI', () {
      controller.addFrameForTest(makeFrame(uiMs: 20, rasterMs: 20));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      // Equal durations: !(ui > raster), so falls to raster branch
      expect(verdict!.suspectedPhase, PipelinePhase.raster);
    });

    test('reason includes UI and raster timings', () {
      controller.addFrameForTest(makeFrame(uiMs: 30, rasterMs: 10));

      final verdict = controller.verdictNotifier.value!;
      expect(verdict.reason, contains('UI: 30ms'));
      expect(verdict.reason, contains('Raster: 10ms'));
    });

    test('reason includes vsync text when overhead > 500us', () {
      controller.addFrameForTest(
        makeFrame(uiMs: 30, rasterMs: 10, vsyncOverheadUs: 1500),
      );

      final verdict = controller.verdictNotifier.value!;
      expect(verdict.reason, contains('Vsync wait: 1.5ms'));
    });

    test('reason omits vsync text when overhead <= 500us', () {
      controller.addFrameForTest(
        makeFrame(uiMs: 30, rasterMs: 10, vsyncOverheadUs: 400),
      );

      final verdict = controller.verdictNotifier.value!;
      expect(verdict.reason, isNot(contains('Vsync')));
    });

    test('relatedIssues are attached from current detector state', () {
      // Feed enough janky frames to trigger FrameTimingDetector's own jank issue
      for (var i = 0; i < 10; i++) {
        controller.addFrameForTest(
          makeFrame(uiMs: 40, rasterMs: 8, frameNumber: i + 1),
        );
      }

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.relatedIssues, isNotEmpty,
          reason: 'Sustained jank should produce FrameTimingDetector issues');
    });

    test('no fallback verdict for non-jank frames', () {
      controller.addFrameForTest(makeFrame(uiMs: 8, rasterMs: 6));

      expect(controller.verdictNotifier.value, isNull);
    });

    test('no fallback verdict when VM is connected', () {
      controller.vmConnectedForTest = true;
      expect(controller.isVmConnected, isTrue);

      controller.addFrameForTest(makeFrame(uiMs: 30, rasterMs: 10));

      expect(controller.verdictNotifier.value, isNull,
          reason: 'Fallback path should be skipped when VM is connected');
    });

    test('fallback verdict resumes after VM disconnects', () {
      controller.vmConnectedForTest = true;
      controller.addFrameForTest(makeFrame(uiMs: 30, rasterMs: 10));
      expect(controller.verdictNotifier.value, isNull);

      // Disconnect
      controller.vmConnectedForTest = false;
      controller.addFrameForTest(
        makeFrame(uiMs: 30, rasterMs: 10, frameNumber: 2),
      );
      expect(controller.verdictNotifier.value, isNotNull,
          reason: 'Fallback should resume after VM disconnect');
    });

    test('verdict includes totalSpan and gap when provided', () {
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 30),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
        totalSpan: const Duration(milliseconds: 45),
        buildToRasterGap: const Duration(microseconds: 5000),
      ));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.totalSpan, const Duration(milliseconds: 45));
      expect(verdict.buildToRasterGapTime, const Duration(microseconds: 5000));
    });
  });
}
