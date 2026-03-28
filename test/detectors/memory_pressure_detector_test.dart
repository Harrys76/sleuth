import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/memory_pressure_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  group('MemoryPressureDetector', () {
    late MemoryPressureDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = MemoryPressureDetector(clock: () => fakeNow);
    });

    test('no issues when disabled', () {
      detector.isEnabled = false;
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      detector.processTimelineData(gcHeavyData(gcCount: 20));
      expect(detector.issues, isEmpty);
    });

    test('no issues with no GC events', () {
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('no issues with low GC frequency', () {
      // 2 GC events over 60 seconds = 2/min — well below 30/min threshold
      fakeNow = fakeNow.add(const Duration(seconds: 60));
      detector.processTimelineData(gcHeavyData(gcCount: 2));
      expect(detector.issues, isEmpty);
    });

    test('flags high GC pressure (>30 GC/min)', () {
      // 10 GC events over 10 seconds = 60/min
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      expect(detector.issues, isNotEmpty);
      expect(detector.issues.first.title, contains('GC Pressure'));
      expect(detector.issues.first.observationSource,
          ObservationSource.vmTimeline);
    });

    test('GC severity uses warning level', () {
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    test('GC issue confidence is likely', () {
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      expect(detector.issues.first.confidence, IssueConfidence.likely);
    });

    test('GC issue detail contains frequency', () {
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      expect(detector.issues.first.detail, contains('/min'));
    });

    test('no heap issue when initial estimate is zero', () {
      // No updateHeapStats called — initial is 0
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      // Only GC issue, no heap growth issue
      final heapIssues = detector.issues.where((i) => i.title.contains('Heap'));
      expect(heapIssues, isEmpty);
    });

    test('no heap issue when growth below threshold', () {
      detector.updateHeapStats(usedBytes: 1000000, capacityBytes: 2000000);
      // 5% growth — below default 10% threshold
      detector.updateHeapStats(usedBytes: 1050000, capacityBytes: 2000000);

      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 1));

      final heapIssues = detector.issues.where((i) => i.title.contains('Heap'));
      expect(heapIssues, isEmpty);
    });

    test('flags heap growth above threshold (warning)', () {
      detector.updateHeapStats(usedBytes: 1000000, capacityBytes: 2000000);
      // 15% growth — above default 10% threshold
      detector.updateHeapStats(usedBytes: 1150000, capacityBytes: 2000000);

      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 1));

      final heapIssues = detector.issues.where((i) => i.title.contains('Heap'));
      expect(heapIssues, hasLength(1));
      expect(heapIssues.first.severity, IssueSeverity.warning);
    });

    test('flags heap growth >30% as critical', () {
      detector.updateHeapStats(usedBytes: 1000000, capacityBytes: 2000000);
      // 40% growth
      detector.updateHeapStats(usedBytes: 1400000, capacityBytes: 2000000);

      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 1));

      final heapIssues = detector.issues.where((i) => i.title.contains('Heap'));
      expect(heapIssues, hasLength(1));
      expect(heapIssues.first.severity, IssueSeverity.critical);
    });

    test('heap detail shows human-readable byte sizes', () {
      // 1MB initial, 1.5MB current
      detector.updateHeapStats(usedBytes: 1048576, capacityBytes: 2 * 1048576);
      detector.updateHeapStats(usedBytes: 1572864, capacityBytes: 2 * 1048576);

      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 1));

      final heapIssues = detector.issues.where((i) => i.title.contains('Heap'));
      expect(heapIssues, isNotEmpty);
      expect(heapIssues.first.detail, contains('MB'));
    });

    test('reset then re-feed produces fresh evaluation', () {
      // Build up state
      detector.updateHeapStats(usedBytes: 1000000, capacityBytes: 2000000);
      detector.updateHeapStats(usedBytes: 1500000, capacityBytes: 2000000);
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));
      expect(detector.issues, isNotEmpty);

      // Reset
      detector.reset();
      expect(detector.issues, isEmpty);

      // Re-feed with low activity — should produce no issues
      fakeNow = fakeNow.add(const Duration(seconds: 60));
      detector.processTimelineData(gcHeavyData(gcCount: 1));
      final heapIssues = detector.issues.where((i) => i.title.contains('Heap'));
      expect(heapIssues, isEmpty);
    });

    test('dispose clears issues', () {
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));
      expect(detector.issues, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
    });
  });
}
