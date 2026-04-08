import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';

import '../helpers/benchmark_helpers.dart';

void main() {
  group('Issue allocation reduction (M5)', () {
    group('_getAllIssues generation cache', () {
      testWidgets('cached list reused when called twice without scan',
          (tester) async {
        await tester.pumpWidget(buildMixedTree(500));
        final context = tester.element(find.byType(Directionality));

        final controller = SleuthController();
        controller.initializeDetectorsForTest();

        // Run a structural scan to produce issues and increment generation.
        controller.runTreeScanForTest(context);

        // Two consecutive aggregations without a scan between — the second
        // should reuse the cached _getAllIssues list (same generation).
        controller.aggregateIssuesForTest();
        final issues1 = controller.issuesNotifier.value;
        controller.aggregateIssuesForTest();
        final issues2 = controller.issuesNotifier.value;

        expect(issues1.length, issues2.length);
        for (int i = 0; i < issues1.length; i++) {
          expect(issues2[i].stableId, issues1[i].stableId);
        }

        controller.dispose();
      });

      testWidgets('fresh list after structural scan', (tester) async {
        await tester.pumpWidget(buildMixedTree(500));
        final context = tester.element(find.byType(Directionality));

        final controller = SleuthController();
        controller.initializeDetectorsForTest();

        // First scan.
        controller.runTreeScanForTest(context);
        final issues1 = controller.issuesNotifier.value;

        // Second scan — _runStructuralScans increments generation.
        controller.runTreeScanForTest(context);
        final issues2 = controller.issuesNotifier.value;

        // Same detections (tree unchanged), but a fresh list was created.
        expect(issues2.length, issues1.length);

        controller.dispose();
      });

      testWidgets('generation increments independently in scan and timeline',
          (tester) async {
        await tester.pumpWidget(buildMixedTree(500));
        final context = tester.element(find.byType(Directionality));

        final controller = SleuthController();
        controller.initializeDetectorsForTest();

        // Structural scan increments generation.
        controller.runTreeScanForTest(context);
        final afterScan = controller.issuesNotifier.value.length;

        // Aggregation alone (no scan) reuses cache.
        controller.aggregateIssuesForTest();
        expect(controller.issuesNotifier.value.length, afterScan);

        controller.dispose();
      });
    });

    group('clean-scan counter interaction', () {
      testWidgets('cache does not interfere with adaptive scan tracking',
          (tester) async {
        await tester.pumpWidget(buildMixedTree(50));
        final context = tester.element(find.byType(Directionality));

        final controller = SleuthController(
          config: const SleuthConfig(
            enabledDetectors: {DetectorType.frameTiming},
          ),
        );
        controller.initializeDetectorsForTest();

        // Multiple clean scans — verify issue list cache doesn't interfere
        // with clean-scan tracking for adaptive interval.
        for (int i = 0; i < 5; i++) {
          controller.runTreeScanForTest(context);
        }
        expect(controller.consecutiveCleanScansForTest, 5);
        expect(controller.issuesNotifier.value, isEmpty);

        controller.dispose();
      });
    });
  });
}
