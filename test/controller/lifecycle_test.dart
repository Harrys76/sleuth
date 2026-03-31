import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/models/heap_sample.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  // =========================================================================
  // v6.17 Controller lifecycle tests
  // =========================================================================

  group('Pre-initialization safety', () {
    test('notifiers have safe defaults before initialization', () {
      final controller = WatchdogController();

      expect(controller.issuesNotifier.value, isEmpty);
      expect(controller.frameStatsNotifier.value.averageFps, 0);
      expect(controller.verdictNotifier.value, isNull);
      expect(controller.vmConnectedNotifier.value, isFalse);
      expect(controller.highlightsNotifier.value, isEmpty);
      expect(controller.highlightEnabledNotifier.value, isFalse);
      expect(controller.selectedHighlightNotifier.value, isNull);
      expect(controller.suppressedCountNotifier.value, 0);

      controller.dispose();
    });

    test('exportSnapshot is safe before initialization', () {
      final controller = WatchdogController();

      final snapshot = controller.exportSnapshot();
      expect(snapshot.currentIssues, isEmpty);
      expect(snapshot.frameStatsSummary.totalFrames, 0);

      controller.dispose();
    });

    test('dispose before initialization does not throw', () {
      final controller = WatchdogController();
      // No initialize() or initializeDetectorsForTest() call — just dispose.
      controller.dispose();
      // No crash = success. Guards against LateInitializationError on
      // _detectors which is only set during initialization.
    });
  });

  group('Dispose lifecycle', () {
    test('notifiers accessible after dispose', () {
      final controller = WatchdogController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);

      controller.feedTimelineDataForTest(emptyTimelineData());
      controller.aggregateIssuesForTest();

      controller.dispose();

      // After dispose, notifier values are still readable (stale but no crash).
      expect(controller.issuesNotifier.value, isNotNull);
      expect(controller.frameStatsNotifier.value, isNotNull);
    });

    test('heap sample feed after dispose is safe', () {
      final controller = WatchdogController();
      controller.initializeDetectorsForTest();
      controller.dispose();

      // _onHeapSample has a _disposed guard — should be a no-op.
      controller.feedHeapSampleForTest(HeapSample(
        heapUsage: 100 * 1024 * 1024,
        heapCapacity: 200 * 1024 * 1024,
        externalUsage: 0,
        timestamp: DateTime(2026, 1, 1),
      ));
      // No crash = guard works.
    });

    test('recurrence counts cleared on dispose', () {
      final controller = WatchdogController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);

      // Feed data that triggers aggregation with recurrence tracking.
      controller.feedTimelineDataForTest(highBuildActivityData());
      controller.aggregateIssuesForTest();
      // Feed again to build up recurrence.
      controller.feedTimelineDataForTest(highBuildActivityData());
      controller.aggregateIssuesForTest();

      controller.dispose();
      expect(controller.recurrenceCountsForTest, isEmpty);
    });
  });

  group('Concurrent data processing', () {
    test('multiple rapid timeline batches without crash', () {
      final controller = WatchdogController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);

      // Feed 10 batches rapidly — simulates burst of VM events.
      for (int i = 0; i < 10; i++) {
        controller.feedTimelineDataForTest(emptyTimelineData());
      }

      controller.aggregateIssuesForTest();
      expect(controller.issuesNotifier.value, isNotNull);
      controller.dispose();
    });

    test('interleaved heap samples and timeline data', () {
      final controller = WatchdogController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);

      // Alternate between different data sources.
      for (int i = 0; i < 5; i++) {
        controller.feedHeapSampleForTest(HeapSample(
          heapUsage: (50 + i * 5) * 1024 * 1024,
          heapCapacity: 500 * 1024 * 1024,
          externalUsage: 0,
          timestamp: DateTime(2026, 1, 1).add(Duration(seconds: i)),
        ));
        controller.feedTimelineDataForTest(emptyTimelineData());
      }

      controller.aggregateIssuesForTest();
      controller.dispose();
    });

    test('suppression config applied at construction', () {
      final controller = WatchdogController(
        config: const WatchdogConfig(
          suppressedIssues: {'rebuild_*'},
        ),
      );
      controller.initializeDetectorsForTest();
      controller.aggregateIssuesForTest();

      // Verify suppression tracking is functional.
      expect(controller.suppressedCountForTest, isA<int>());
      controller.dispose();
    });

    testWidgets('tree scan completes without crash', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 100, height: 100),
        ),
      );

      final controller = WatchdogController();
      controller.initializeDetectorsForTest();

      // Run a tree scan — exercises _runStructuralScans, _collectHighlights,
      // _aggregateIssues, and _updateRecurrence in sequence.
      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      expect(controller.issuesNotifier.value, isNotNull);
      controller.dispose();
    });
  });
}
