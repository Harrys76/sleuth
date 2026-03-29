import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/platform_channel_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  group('PlatformChannelDetector', () {
    late PlatformChannelDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1);
      detector = PlatformChannelDetector(clock: () => fakeNow);
    });

    test('no issues when disabled', () {
      detector.isEnabled = false;
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('no issues when call count below threshold after flush', () {
      // Feed 15 events (below default threshold of 20)
      detector.processTimelineData(
        platformChannelData(channelEventCount: 15),
      );
      // Advance past 1s window and flush
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('warning when calls/sec exceed threshold after flush', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
      expect(detector.issues.first.observationSource,
          ObservationSource.vmTimeline);
    });

    test('critical when calls/sec exceed 2x threshold after flush', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 45),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    test('window reset clears issues via double-flush', () {
      // First window: 25 events → warning
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));

      // Second window: 0 events → clears
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('stableId, confidence, and category', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      final issue = detector.issues.first;
      expect(issue.stableId, 'platform_channel_traffic');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.channel);
    });

    test('title contains call count', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues.first.title, contains('25'));
    });

    test('custom threshold works', () {
      detector = PlatformChannelDetector(
        callsPerSecThreshold: 5,
        clock: () => fakeNow,
      );
      detector.processTimelineData(
        platformChannelData(channelEventCount: 8),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
    });

    test('detail mentions call count, duration, and thresholds', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      final issue = detector.issues.first;
      expect(issue.detail, contains('25 calls'));
      expect(issue.detail, contains('Thresholds: 20 calls/sec'));
      expect(issue.detail, contains('8ms cumulative'));
    });

    test('fixHint recommends batching and Pigeon', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues.first.fixHint, contains('Batch'));
      expect(detector.issues.first.fixHint, contains('Pigeon'));
    });

    test('no issue when duration below threshold despite moderate frequency',
        () {
      // 15 calls × 100µs each = 1.5ms (below 8ms threshold)
      // 15 calls (below 20 threshold)
      detector.processTimelineData(
        platformChannelData(channelEventCount: 15, durUs: 100),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('warning when cumulative duration exceeds threshold', () {
      // 3 calls × 5000µs = 15ms (> 8ms threshold), but only 3 calls (< 20)
      detector.processTimelineData(
        platformChannelData(channelEventCount: 3, durUs: 5000),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
      expect(detector.issues.first.title, contains('Slow Platform Channels'));
      expect(detector.issues.first.title, contains('15.0ms'));
    });

    test('critical when cumulative duration far exceeds threshold', () {
      // 3 calls × 50000µs = 150ms (> 8ms × 2 = 16ms)
      detector.processTimelineData(
        platformChannelData(channelEventCount: 3, durUs: 50000),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    test('detail includes method names', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25, methodName: 'getLocation'),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.detail, contains('getLocation: 25×'));
    });

    test('dispose clears issues', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
    });
  });
}
