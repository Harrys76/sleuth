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

    test('detail mentions call count and threshold', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      final issue = detector.issues.first;
      expect(issue.detail, contains('25'));
      expect(issue.detail, contains('Threshold: 20/sec'));
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
