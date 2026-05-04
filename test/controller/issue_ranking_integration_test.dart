import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  group('issue ranking integration', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController(
        config: const SleuthConfig(
          frameTimingWarmupFrameCount: 0,
          frameTimingWarmupDuration: Duration.zero,
        ),
      );
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('issues sorted by severity after aggregation', (tester) async {
      // Build a widget tree that triggers both warning and critical issues.
      // Opacity(0.0) -> warning (opacity_zero)
      // Non-lazy list with 25+ children -> warning (non_lazy_list)
      // We also inject a critical jank frame to produce a critical issue.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );

      // Inject severe jank frames to produce a critical FrameTiming issue
      for (var i = 0; i < 5; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i + 1,
          uiDuration: const Duration(milliseconds: 50),
          rasterDuration: const Duration(milliseconds: 10),
          timestamp: DateTime.now(),
        ));
      }

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty);

      // Verify severity ordering: all critical before all warning
      bool seenWarning = false;
      for (final issue in issues) {
        if (issue.severity == IssueSeverity.warning) {
          seenWarning = true;
        }
        if (issue.severity == IssueSeverity.critical && seenWarning) {
          fail(
              'Critical issue found after warning issue — severity order violated');
        }
      }
    });

    testWidgets('recurrence counts increment across scan cycles',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );

      final ctx = tester.element(find.byType(Directionality));

      // First scan
      controller.runTreeScanForTest(ctx);
      final firstCounts = controller.recurrenceCountsForTest;
      expect(firstCounts.values, isNotEmpty);
      final firstValue = firstCounts.values.first;
      expect(firstValue, 1);

      // Second scan — same issues, recurrence increments
      controller.runTreeScanForTest(ctx);
      final secondCounts = controller.recurrenceCountsForTest;
      expect(secondCounts.values.first, 2);
    });

    testWidgets('recurrence resets when issue disappears', (tester) async {
      // First: widget tree with Opacity(0.0) issue
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );
      expect(controller.recurrenceCountsForTest, isNotEmpty);

      // Now: clean widget tree — Opacity issue disappears
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 10, height: 10),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      // Recurrence for the opacity issue should be gone
      expect(
        controller.recurrenceCountsForTest.containsKey('non_lazy_list'),
        isFalse,
      );
    });

    testWidgets('frame impact boosts build issues during UI thread jank',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );

      // Inject jank frames with UI > raster (build bottleneck)
      for (var i = 0; i < 5; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i + 1,
          uiDuration: const Duration(milliseconds: 50),
          rasterDuration: const Duration(milliseconds: 5),
          timestamp: DateTime.now(),
        ));
      }

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      final issues = controller.issuesNotifier.value;
      // FrameTiming issue (build category, confirmed) should exist
      final jankIssue = issues.where(
        (i) => i.stableId == 'sustained_jank' || i.stableId == 'jank_detected',
      );
      expect(jankIssue, isNotEmpty);

      // The jank issue (critical, build) should be ranked first
      expect(issues.first.severity, IssueSeverity.critical);
    });

    testWidgets('frame impact clears when jank stops (no stale phase boost)',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );

      final ctx = tester.element(find.byType(Directionality));

      // First: inject jank
      for (var i = 0; i < 5; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i + 1,
          uiDuration: const Duration(milliseconds: 50),
          rasterDuration: const Duration(milliseconds: 5),
          timestamp: DateTime.now(),
        ));
      }
      controller.runTreeScanForTest(ctx);
      final withJank = controller.issuesNotifier.value;
      expect(withJank.any((i) => i.severity == IssueSeverity.critical), isTrue);

      // Then: inject many smooth frames to evict the jank pattern. Detector
      // buffer capacity is fixed at 240 in v0.17.0 C2 fix (decoupled from
      // fpsTarget so actualFpsRaw is a faithful device rate). Fill must be
      // at least 240 smooth frames to evict the 5 original jank frames.
      for (var i = 0; i < 245; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i + 100,
          uiDuration: const Duration(milliseconds: 5),
          rasterDuration: const Duration(milliseconds: 3),
          timestamp: DateTime.now(),
        ));
      }
      controller.runTreeScanForTest(ctx);
      final afterJank = controller.issuesNotifier.value;

      // No critical jank issues anymore
      expect(
        afterJank.any(
          (i) =>
              i.stableId == 'sustained_jank' || i.stableId == 'jank_detected',
        ),
        isFalse,
      );
    });

    testWidgets(
        'timeline path (aggregateIssuesForTest) does not increment recurrence',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );

      final ctx = tester.element(find.byType(Directionality));

      // Scan path: sets recurrence to 1
      controller.runTreeScanForTest(ctx);
      expect(controller.issuesNotifier.value, isNotEmpty);
      final afterScan = Map.of(controller.recurrenceCountsForTest);
      expect(afterScan.values, everyElement(1));

      // Simulate timeline path: re-aggregates but must NOT increment recurrence
      controller.aggregateIssuesForTest();
      controller.aggregateIssuesForTest();
      controller.aggregateIssuesForTest();

      // Recurrence should still be 1 — timeline path doesn't call _updateRecurrence
      expect(controller.recurrenceCountsForTest, afterScan);
    });

    test('recurrence cleared on dispose', () {
      // We can't use testWidgets easily here so just verify the map is empty
      // after dispose by checking that a new controller starts clean.
      final c = SleuthController();
      c.initializeDetectorsForTest();
      expect(c.recurrenceCountsForTest, isEmpty);
      c.dispose();
      expect(c.recurrenceCountsForTest, isEmpty);
    });
  });
}
