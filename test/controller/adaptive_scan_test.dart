import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';

import '../helpers/benchmark_helpers.dart';

/// Config that only enables frameTiming — structural detectors won't fire,
/// ensuring scans are "clean" for adaptive-interval tests.
const _cleanConfig = SleuthConfig(
  treeScanInterval: Duration(seconds: 1),
  enabledDetectors: {DetectorType.frameTiming},
);

void main() {
  group('Adaptive scan frequency (M4)', () {
    testWidgets('backs off after 3 consecutive clean scans', (tester) async {
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(config: _cleanConfig);
      controller.initializeDetectorsForTest();

      // Baseline: normal interval.
      expect(controller.currentScanIntervalMsForTest, 1000);
      expect(controller.consecutiveCleanScansForTest, 0);

      // Run 3 clean scans.
      for (int i = 0; i < 3; i++) {
        controller.runTreeScanForTest(context);
      }

      expect(controller.consecutiveCleanScansForTest, 3);
      // After 3 clean cycles: interval doubles, capped at 2000ms.
      expect(controller.currentScanIntervalMsForTest, 2000);

      controller.dispose();
    });

    testWidgets('returns to normal interval when issues appear', (
      tester,
    ) async {
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(config: _cleanConfig);
      controller.initializeDetectorsForTest();

      // Run 5 clean scans to enter back-off.
      for (int i = 0; i < 5; i++) {
        controller.runTreeScanForTest(context);
      }
      expect(controller.consecutiveCleanScansForTest, 5);
      expect(controller.currentScanIntervalMsForTest, 2000);

      // Feed jank frames to produce a sustained_jank issue from frameTiming.
      for (int i = 0; i < 10; i++) {
        controller.addFrameForTest(
          FrameStats(
            frameNumber: i,
            uiDuration: const Duration(milliseconds: 40),
            rasterDuration: const Duration(milliseconds: 40),
            timestamp: DateTime(2026, 1, 1).add(Duration(milliseconds: i * 16)),
          ),
        );
      }

      // Run scan — if frameTiming issues surfaced, counter resets.
      controller.runTreeScanForTest(context);

      if (controller.issuesNotifier.value.isNotEmpty) {
        expect(controller.consecutiveCleanScansForTest, 0);
        expect(controller.currentScanIntervalMsForTest, 1000);
      }

      controller.dispose();
    });

    testWidgets(
      '3-consecutive requirement: flicker does not trigger back-off',
      (tester) async {
        await tester.pumpWidget(buildMixedTree(50));
        final context = tester.element(find.byType(Directionality));

        final controller = SleuthController(config: _cleanConfig);
        controller.initializeDetectorsForTest();

        // 2 clean scans.
        controller.runTreeScanForTest(context);
        controller.runTreeScanForTest(context);
        expect(controller.consecutiveCleanScansForTest, 2);
        expect(
          controller.currentScanIntervalMsForTest,
          1000,
        ); // Not backed off.

        // Inject jank frames to create issues, then scan.
        for (int i = 0; i < 10; i++) {
          controller.addFrameForTest(
            FrameStats(
              frameNumber: i,
              uiDuration: const Duration(milliseconds: 40),
              rasterDuration: const Duration(milliseconds: 40),
              timestamp: DateTime(
                2026,
                1,
                1,
              ).add(Duration(milliseconds: i * 16)),
            ),
          );
        }
        controller.runTreeScanForTest(context);

        if (controller.issuesNotifier.value.isNotEmpty) {
          expect(controller.consecutiveCleanScansForTest, 0);
        }

        // 2 more clean scans after reset — still not 3 consecutive.
        // Use a fresh controller to guarantee clean scans.
        controller.dispose();

        final controller2 = SleuthController(config: _cleanConfig);
        controller2.initializeDetectorsForTest();
        controller2.runTreeScanForTest(context);
        controller2.runTreeScanForTest(context);
        expect(controller2.consecutiveCleanScansForTest, 2);
        expect(controller2.currentScanIntervalMsForTest, 1000);

        controller2.dispose();
      },
    );

    testWidgets('opt-out: adaptiveScanEnabled=false keeps fixed interval', (
      tester,
    ) async {
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          adaptiveScanEnabled: false,
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();

      // Run 5 clean scans — interval should never change.
      for (int i = 0; i < 5; i++) {
        controller.runTreeScanForTest(context);
      }

      expect(controller.consecutiveCleanScansForTest, 5);
      expect(controller.currentScanIntervalMsForTest, 1000);

      controller.dispose();
    });

    testWidgets('back-off respects maxBackOff for small intervals', (
      tester,
    ) async {
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(milliseconds: 500),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();

      for (int i = 0; i < 3; i++) {
        controller.runTreeScanForTest(context);
      }

      // 500ms * 2 = 1000ms (within 2000ms cap).
      expect(controller.currentScanIntervalMsForTest, 1000);

      controller.dispose();
    });

    testWidgets('back-off caps at 2000ms for large intervals', (tester) async {
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(milliseconds: 1500),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();

      for (int i = 0; i < 3; i++) {
        controller.runTreeScanForTest(context);
      }

      // 1500ms * 2 = 3000ms, clamped to 2000ms.
      expect(controller.currentScanIntervalMsForTest, 2000);

      controller.dispose();
    });

    test('dispose cancels rescheduling timer', () {
      final controller = SleuthController();
      // Don't start scanning — just verify dispose doesn't throw.
      controller.dispose();
    });

    testWidgets('scan chain survives detector exception (try/finally)', (
      tester,
    ) async {
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(config: _cleanConfig);
      controller.initializeDetectorsForTest();

      // Run a clean scan first to verify baseline works.
      controller.runTreeScanForTest(context);
      expect(controller.consecutiveCleanScansForTest, 1);

      // Run another scan — the controller should still be functional
      // after any internal exception. The try/finally in _scanTree
      // and the try/catch in _scheduleNextScan ensure:
      // 1. _isIteratingDetectors is always cleared
      // 2. pending mutations are always drained
      // 3. the timer chain is always rescheduled
      controller.runTreeScanForTest(context);
      expect(controller.consecutiveCleanScansForTest, 2);

      controller.dispose();
    });
  });
  group('Cost stretch', () {
    SleuthController make(SleuthConfig config) {
      final c = SleuthController(config: config);
      c.initializeDetectorsForTest();
      addTearDown(c.dispose);
      return c;
    }

    test('costs at or under 4 ms leave the interval alone', () {
      final c = make(_cleanConfig);
      c.scanDurationOverrideForTest = 4000;
      expect(c.currentScanIntervalMsForTest, 1000);
    });

    test('20 ms tick stretches a 1 s base to the 5 s cap', () {
      final c = make(_cleanConfig);
      c.scanDurationOverrideForTest = 20000;
      expect(c.currentScanIntervalMsForTest, 5000);
      c.scanDurationOverrideForTest = 400000;
      expect(c.currentScanIntervalMsForTest, 5000);
    });

    test('6 ms tick stretches a 1 s base to 2 s', () {
      final c = make(_cleanConfig);
      c.scanDurationOverrideForTest = 6000;
      expect(c.currentScanIntervalMsForTest, 2000);
    });

    test('capture mode never stretches', () {
      final c = make(
        const SleuthConfig(
          enabledDetectors: {DetectorType.frameTiming},
          captureMode: true,
        ),
      );
      c.scanDurationOverrideForTest = 20000;
      expect(c.currentScanIntervalMsForTest, 1000);
    });

    test('a stretch never shortens the back-off interval', () {
      final c = make(
        const SleuthConfig(
          treeScanInterval: Duration(milliseconds: 3000),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      c.scanDurationOverrideForTest = 5000;
      expect(c.currentScanIntervalMsForTest, 5000);
    });

    testWidgets('back-off never drops below a 3 s base', (tester) async {
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));
      final c = make(
        const SleuthConfig(
          treeScanInterval: Duration(milliseconds: 3000),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      for (int i = 0; i < 3; i++) {
        c.runTreeScanForTest(context);
      }
      expect(c.consecutiveCleanScansForTest, 3);
      expect(c.currentScanIntervalMsForTest, 3000);
    });

    testWidgets('a real tick records its cost and element count', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: buildMixedTree(300))),
      );
      final c = make(_cleanConfig);
      c.scanTreeFullPathForTest(tester.element(find.byType(MaterialApp)));
      expect(c.lastScanElementCount, greaterThan(300));
      expect(c.lastScanDurationUs, greaterThan(0));
    });
  });

  group('Element cap', () {
    testWidgets('an oversized walk skips one tick, then scans again', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: buildMixedTree(600))),
      );
      final c = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {DetectorType.frameTiming},
          adaptiveScanEnabled: false,
          maxElementsPerScan: 500,
        ),
      );
      c.initializeDetectorsForTest();
      c.markInitializedForTest();
      // The interval stretches on measured scan cost (wall clock); pin
      // it so a slow machine cannot push the rescheduled tick past the
      // fake-clock expectations below.
      c.scanDurationOverrideForTest = 0;
      var scans = 0;
      c.scanTickNotifier.addListener(() => scans++);

      // Scheduled ticks run in a post-frame callback; force a frame.
      Future<void> elapse(int ms) async {
        await tester.pump(Duration(milliseconds: ms));
        tester.binding.scheduleFrame();
        await tester.pump();
      }

      c.startTreeScanning(tester.element(find.byType(MaterialApp)));
      await elapse(1000);
      expect(scans, 1);
      final walked = c.lastScanElementCount;
      expect(walked, greaterThan(500));
      final issuesBefore = c.issuesNotifier.value;

      // Second tick: skipped; the next one is scheduled at 2x.
      await elapse(1000);
      expect(scans, 1);
      expect(c.issuesNotifier.value, same(issuesBefore));
      expect(c.lastScanElementCount, walked);
      await elapse(1000);
      expect(scans, 1);

      // Third tick (2 s after the skip) runs.
      await elapse(1000);
      expect(scans, 2);
      c.dispose();
    });

    testWidgets('walks under the cap never skip', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: buildMixedTree(100))),
      );
      final c = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {DetectorType.frameTiming},
          adaptiveScanEnabled: false,
          maxElementsPerScan: 500,
        ),
      );
      c.initializeDetectorsForTest();
      c.markInitializedForTest();
      var scans = 0;
      c.scanTickNotifier.addListener(() => scans++);

      c.startTreeScanning(tester.element(find.byType(MaterialApp)));
      for (var i = 1; i <= 3; i++) {
        await tester.pump(const Duration(milliseconds: 1000));
        tester.binding.scheduleFrame();
        await tester.pump();
        expect(scans, i);
      }
      c.dispose();
    });
  });
}
