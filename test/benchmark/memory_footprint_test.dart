import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/capture_buffer.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/frame_verdict.dart';

import '../helpers/benchmark_helpers.dart';

void main() {
  group('buffer bounds', () {
    test('frame stats buffer does not exceed capacity', () {
      final buffer = FrameStatsBuffer(capacity: 60);

      // Feed 200 frames — far exceeding capacity
      for (int i = 0; i < 200; i++) {
        buffer.add(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 8),
          rasterDuration: const Duration(milliseconds: 6),
          timestamp: DateTime(2026, 1, 1).add(Duration(milliseconds: i * 16)),
        ));
      }

      expect(buffer.length, 60);
      expect(buffer.length, lessThanOrEqualTo(buffer.capacity));
    });

    test('capture buffer does not exceed capacity', () {
      final buffer = JankCaptureBuffer(capacity: 50);

      // Feed 100 jank frames
      for (int i = 0; i < 100; i++) {
        buffer.add(CaptureEntry(
          frameStats: FrameStats(
            frameNumber: i,
            uiDuration: Duration(milliseconds: 20 + i),
            rasterDuration: const Duration(milliseconds: 10),
            timestamp: DateTime(2026, 1, 1).add(Duration(seconds: i)),
          ),
          verdict: FrameVerdict(
            frameNumber: i,
            totalFrameTime: Duration(milliseconds: 30 + i),
            uiThreadTime: Duration(milliseconds: 20 + i),
            rasterThreadTime: const Duration(milliseconds: 10),
            suspectedPhase: PipelinePhase.build,
            reason: 'test',
          ),
          relatedIssues: const [],
          capturedAt: DateTime(2026, 1, 1),
        ));
      }

      expect(buffer.length, 50);
      expect(buffer.length, lessThanOrEqualTo(buffer.capacity));
    });
  });

  group('aggregate issue bounds', () {
    testWidgets('total issues across all detectors are bounded',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(500));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController();
      controller.initializeDetectorsForTest();

      // Run several scan cycles to accumulate issues
      for (int i = 0; i < 5; i++) {
        controller.runTreeScanForTest(context);
      }

      final issues = controller.issuesNotifier.value;

      // With 23 detectors, each producing at most a few issues,
      // the total should be bounded. We use 50 as a generous upper bound.
      expect(issues.length, lessThan(50));

      // Verify no duplicate stableIds (each detector uses unique prefixes)
      final ids = issues.map((i) => i.stableId).toSet();
      expect(ids.length, issues.length);

      controller.dispose();
    });
  });

  group('highlight bounds', () {
    testWidgets('highlights per detector capped at maxHighlightsPerType',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(1000));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.highlightEnabledNotifier.value = true;

      controller.runTreeScanForTest(context);

      final highlights = controller.highlightsNotifier.value.items;

      // Each detector caps at 3 per type. With 12 highlight-producing detectors
      // and a limited number of detectable anti-patterns in the synthetic tree,
      // total should stay well under 100.
      expect(highlights.length, lessThan(100));

      controller.dispose();
    });
  });
}
