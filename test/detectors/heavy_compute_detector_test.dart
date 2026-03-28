import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/heavy_compute_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  group('HeavyComputeDetector', () {
    late HeavyComputeDetector detector;

    setUp(() {
      detector = HeavyComputeDetector();
    });

    test('no issues when disabled', () {
      detector.isEnabled = false;
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [50000]),
      );
      expect(detector.issues, isEmpty);
    });

    test('no issues when buildScope durations below threshold', () {
      // Default lagThresholdMs=8, so trigger is ms > 16.
      // 15ms = 15000us should NOT trigger.
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [15000]),
      );
      expect(detector.issues, isEmpty);
    });

    test('no issue at exact threshold boundary', () {
      // 16ms = 16000us. Condition is ms > 16, so 16.0 > 16 is false.
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [16000]),
      );
      expect(detector.issues, isEmpty);
    });

    test('critical when buildScope exceeds threshold with default config', () {
      // 20ms = 20000us. ms > 16 triggers, ms >= 16 → critical.
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [20000]),
      );
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expect(detector.issues.first.observationSource,
          ObservationSource.vmTimeline);
    });

    test('warning severity with custom lagThresholdMs', () {
      // lagThresholdMs=4, trigger is ms > 8, critical is ms >= 16.
      // 12ms: 12 > 8 triggers, 12 >= 16 is false → warning.
      detector = HeavyComputeDetector(lagThresholdMs: 4);
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [12000]),
      );
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    test('stableId, confidence, and category', () {
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [20000]),
      );
      final issue = detector.issues.first;
      expect(issue.stableId, 'heavy_compute');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.build);
    });

    test('title contains duration in ms', () {
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [20000]),
      );
      expect(detector.issues.first.title, contains('20.0ms'));
    });

    test('multiple buildScope events produce multiple issues', () {
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [20000, 30000]),
      );
      expect(detector.issues, hasLength(2));
    });

    test('no issue for normal buildScope times', () {
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [5000, 8000, 10000]),
      );
      expect(detector.issues, isEmpty);
    });

    test('detail mentions blocking and duration', () {
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [20000]),
      );
      final issue = detector.issues.first;
      expect(issue.detail, contains('20.0ms'));
      expect(issue.detail, contains('blocks frame rendering'));
    });

    test('fixHint recommends isolate', () {
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [20000]),
      );
      expect(detector.issues.first.fixHint, contains('Isolate.run()'));
      expect(detector.issues.first.fixHint, contains('compute()'));
    });

    test('dispose clears issues', () {
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [20000]),
      );
      expect(detector.issues, isNotEmpty);
      detector.dispose();
      expect(detector.issues, isEmpty);
    });
  });

  group('HeavyComputeDetector enrichment', () {
    late HeavyComputeDetector detector;

    setUp(() {
      detector = HeavyComputeDetector();
    });

    test('enriched build shows widget names in title', () {
      detector.processTimelineData(enrichedBuildData(
        buildDurationUs: 25000,
        dirtyCount: 2,
        dirtyList: ['MyWidget', 'OtherWidget'],
        scopeContext: 'MyApp(dirty)',
      ));

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.title, contains('Heavy Build:'));
      expect(issue.title, contains('MyWidget'));
      expect(issue.title, contains('OtherWidget'));
    });

    test('enriched build includes dirty count and widgets in detail', () {
      detector.processTimelineData(enrichedBuildData(
        buildDurationUs: 25000,
        dirtyCount: 3,
        dirtyList: ['A', 'B', 'C'],
        scopeContext: 'TestApp',
      ));

      final issue = detector.issues.first;
      expect(issue.detail, contains('Dirty widget count: 3'));
      expect(issue.detail, contains('Dirty widgets: A, B, C'));
      expect(issue.detail, contains('Scope context: TestApp'));
    });

    test('enriched build without dirty list uses generic title', () {
      detector.processTimelineData(enrichedBuildData(
        buildDurationUs: 25000,
        dirtyCount: 5,
        // no dirtyList
      ));

      final issue = detector.issues.first;
      expect(issue.title, contains('Heavy Computation:'));
      expect(issue.title, isNot(contains('Heavy Build:')));
    });

    test('widget summary truncates at 3 names', () {
      detector.processTimelineData(enrichedBuildData(
        buildDurationUs: 25000,
        dirtyList: ['Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon'],
      ));

      final issue = detector.issues.first;
      expect(issue.title, contains('Alpha'));
      expect(issue.title, contains('Beta'));
      expect(issue.title, contains('Gamma'));
      expect(issue.title, contains('+2 more'));
      expect(issue.title, isNot(contains('Delta')));
    });

    test('fallback to buildScopeDurations when no phaseEvents', () {
      // Old-style data with only raw durations (no phaseEvents)
      detector.processTimelineData(
        heavyComputeData(buildScopeDurationsUs: [20000]),
      );

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('Heavy Computation:'));
    });

    test('phaseEvents below threshold produce no issues', () {
      detector.processTimelineData(enrichedBuildData(
        buildDurationUs: 10000, // 10ms, below 16ms threshold
        dirtyList: ['SomeWidget'],
      ));

      expect(detector.issues, isEmpty);
    });
  });
}
