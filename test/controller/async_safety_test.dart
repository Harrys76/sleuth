import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/heap_sample.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  // =========================================================================
  // v6.1 Async safety: dispose guards and error visibility
  // =========================================================================

  group('Heap sample dispose guard', () {
    test('_onHeapSample is no-op after dispose', () {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);
      controller.dispose();

      // Should not throw — _disposed guard returns early before any work.
      controller.feedHeapSampleForTest(HeapSample(
        heapUsage: 100 * 1024 * 1024,
        heapCapacity: 200 * 1024 * 1024,
        externalUsage: 0,
        timestamp: DateTime(2026, 1, 1),
      ));
      // If we get here without an exception, the guard works.
    });

    test('heap sample before dispose processes normally', () {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);

      // Feed a sample — should not throw.
      controller.feedHeapSampleForTest(HeapSample(
        heapUsage: 50 * 1024 * 1024,
        heapCapacity: 200 * 1024 * 1024,
        externalUsage: 0,
        timestamp: DateTime(2026, 1, 1),
      ));

      // Controller still functional.
      expect(controller.issuesNotifier.value, isNotNull);
      controller.dispose();
    });
  });

  group('CPU attribution dispose safety', () {
    test('dispose does not crash with pending enrichment', () {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);

      // Feed timeline data to trigger frame processing path
      controller.feedTimelineDataForTest(emptyTimelineData());

      // Dispose immediately — any in-flight enrichment callbacks should
      // check _disposed and return early.
      controller.dispose();
      // No crash = success
    });
  });

  group('Allocation enrichment dispose safety', () {
    test('enrichment method returns early when vmClient is null', () async {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      // Don't connect VM — _vmClient is null.

      // Feed heap samples that would trigger heap growth.
      // Without VM, _enrichWithAllocationProfile returns immediately.
      for (int i = 0; i < 20; i++) {
        controller.feedHeapSampleForTest(HeapSample(
          heapUsage: (50 + i * 5) * 1024 * 1024,
          heapCapacity: 500 * 1024 * 1024,
          externalUsage: 0,
          timestamp: DateTime(2026, 1, 1).add(Duration(seconds: i)),
        ));
      }

      // No crash — enrichment was skipped because no VM client.
      controller.dispose();
    });

    test('dispose during allocation enrichment delay does not crash', () async {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);

      // Feed enough heap samples to trigger growth detection.
      // The detector needs multiple samples to detect a trend.
      for (int i = 0; i < 20; i++) {
        controller.feedHeapSampleForTest(HeapSample(
          heapUsage: (50 + i * 5) * 1024 * 1024,
          heapCapacity: 500 * 1024 * 1024,
          externalUsage: 0,
          timestamp: DateTime(2026, 1, 1).add(Duration(seconds: i)),
        ));
      }

      // Dispose immediately — if allocation enrichment was triggered,
      // its async callbacks will check _disposed and bail out.
      controller.dispose();

      // Allow any pending microtasks/timers to settle.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // No crash = success
    });
  });

  group('Enrichment error visibility', () {
    test('CPU attribution failure does not crash controller', () {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);

      // Feed timeline data to exercise the aggregation path.
      // Without a real VM service, CPU attribution will fail gracefully.
      controller.feedTimelineDataForTest(emptyTimelineData());

      expect(controller.issuesNotifier.value, isNotNull);
      controller.dispose();
    });

    test('allocation enrichment failure does not crash controller', () async {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);

      // Feed heap samples without a real VM service.
      for (int i = 0; i < 20; i++) {
        controller.feedHeapSampleForTest(HeapSample(
          heapUsage: (50 + i * 5) * 1024 * 1024,
          heapCapacity: 500 * 1024 * 1024,
          externalUsage: 0,
          timestamp: DateTime(2026, 1, 1).add(Duration(seconds: i)),
        ));
      }

      // Allow any pending async operations.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(controller.issuesNotifier.value, isNotNull);
      controller.dispose();
    });
  });

  group('Dispose during active scan', () {
    testWidgets('dispose immediately after tree scan does not crash',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 10, height: 10),
        ),
      );

      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.simulateVmStateChangeForTest(true);

      // Run a tree scan
      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      // Feed timeline data to trigger aggregation
      controller.feedTimelineDataForTest(emptyTimelineData());

      // Dispose immediately during/after aggregation
      controller.dispose();
      // No crash = success
    });
  });
}
