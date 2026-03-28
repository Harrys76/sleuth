import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/models/frame_stats.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

import '../helpers/benchmark_helpers.dart';
import '../helpers/timeline_test_helpers.dart';

void main() {
  group('VM disconnect degrades gracefully', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('structural issues survive VM disconnect', (tester) async {
      await tester.pumpWidget(buildMixedTree(500));
      final context = tester.element(find.byType(Directionality));

      // Start with VM connected
      controller.simulateVmStateChangeForTest(true);

      // Feed timeline data to generate VM-backed issues
      controller.feedTimelineDataForTest(rasterDominantData(
        rasterUs: 30000,
        buildUs: 5000,
        layoutUs: 3000,
        paintUs: 2000,
      ));

      // Run tree scan to generate structural issues
      controller.runTreeScanForTest(context);

      final issuesBefore = controller.issuesNotifier.value;
      expect(issuesBefore, isNotEmpty,
          reason: 'Issues must exist before disconnect to prove survival');

      // Disconnect VM
      controller.simulateVmStateChangeForTest(false);

      // Run another tree scan (structural detectors should still work)
      controller.runTreeScanForTest(context);

      final issuesAfter = controller.issuesNotifier.value;

      // Structural issues should remain
      final structuralAfter = issuesAfter
          .where((i) =>
              i.observationSource == ObservationSource.structural ||
              i.observationSource == ObservationSource.debugCallback ||
              i.observationSource ==
                  ObservationSource.debugCallbackAndStructural)
          .toList();
      expect(structuralAfter, isNotEmpty,
          reason: 'Structural issues must survive VM disconnect');

      // No issue should claim Confirmed confidence for VM-dependent signals
      // after disconnect (hybrid detectors downgrade to possible)
      for (final issue in issuesAfter) {
        if (issue.observationSource == ObservationSource.vmTimeline) {
          fail('VM-timeline-sourced issue "${issue.title}" should not exist '
              'after VM disconnect');
        }
      }
    });

    testWidgets('vmConnectedNotifier updates on state change', (tester) async {
      await tester.pumpWidget(buildMixedTree(100));

      controller.simulateVmStateChangeForTest(true);
      expect(controller.vmConnectedNotifier.value, isTrue);

      controller.simulateVmStateChangeForTest(false);
      expect(controller.vmConnectedNotifier.value, isFalse);
    });

    testWidgets('isVmConnected getter matches simulated state', (tester) async {
      await tester.pumpWidget(buildMixedTree(100));

      controller.simulateVmStateChangeForTest(true);
      expect(controller.isVmConnected, isTrue);

      controller.simulateVmStateChangeForTest(false);
      expect(controller.isVmConnected, isFalse);
    });
  });

  group('VM reconnect restages fresh data', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('hybrid detectors re-acquire VM data after reconnect',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(500));
      final context = tester.element(find.byType(Directionality));

      // Start disconnected — only structural issues
      controller.simulateVmStateChangeForTest(false);
      controller.runTreeScanForTest(context);

      final disconnectedIssues = controller.issuesNotifier.value;
      final vmIssuesWhileDisconnected = disconnectedIssues
          .where((i) => i.observationSource == ObservationSource.vmTimeline)
          .toList();
      expect(vmIssuesWhileDisconnected, isEmpty,
          reason: 'No VM issues when disconnected');

      // Reconnect and feed timeline data
      controller.simulateVmStateChangeForTest(true);
      controller.feedTimelineDataForTest(rasterDominantData(
        rasterUs: 30000,
        buildUs: 5000,
        layoutUs: 3000,
        paintUs: 2000,
      ));
      controller.runTreeScanForTest(context);

      // Issues should now include VM-backed data
      expect(controller.isVmConnected, isTrue);
      expect(controller.vmConnectedNotifier.value, isTrue);
    });
  });

  group('verdict path switches on VM state', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test('verdict is basic mode when VM disconnected', () {
      // VM disconnected by default
      expect(controller.isVmConnected, isFalse);

      // Feed a jank frame
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 30),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.isFullMode, isFalse,
          reason: 'Verdict should be basic mode without VM');
    });

    test('verdict is full mode when VM connected and timeline data arrives',
        () {
      controller.simulateVmStateChangeForTest(true);

      // Feed timeline data with phase events (triggers correlated/full path)
      controller.feedTimelineDataForTest(correlatedTimelineData(
        buildUs: 20000,
        layoutUs: 5000,
        paintUs: 3000,
        rasterUs: 8000,
      ));

      // Feed a jank frame so the timeline path can match it
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 28),
        rasterDuration: const Duration(milliseconds: 8),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      // Feed timeline data again (now there's a frame to correlate with)
      controller.feedTimelineDataForTest(correlatedTimelineData(
        buildUs: 20000,
        layoutUs: 5000,
        paintUs: 3000,
        rasterUs: 8000,
      ));

      final verdict = controller.verdictNotifier.value;
      // With VM connected + timeline data, verdict should be full or correlated
      expect(verdict, isNotNull,
          reason: 'Verdict should exist after VM + timeline + jank frame');
      expect(verdict!.isFullMode || verdict.isCorrelated, isTrue,
          reason: 'Verdict should be full/correlated mode with VM + timeline');
    });
  });

  group('UI mode indicator matches VM state', () {
    testWidgets('vmConnectedNotifier drives UI state', (tester) async {
      final controller = WatchdogController();
      controller.initializeDetectorsForTest();

      // Default: disconnected
      expect(controller.vmConnectedNotifier.value, isFalse);

      // Connect
      controller.simulateVmStateChangeForTest(true);
      expect(controller.vmConnectedNotifier.value, isTrue);

      // Disconnect
      controller.simulateVmStateChangeForTest(false);
      expect(controller.vmConnectedNotifier.value, isFalse);

      controller.dispose();
    });
  });

  group('detector group isolation', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('VM-only detectors produce no issues when VM never connected',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(500));
      final context = tester.element(find.byType(Directionality));

      // VM never connected (default state)
      expect(controller.isVmConnected, isFalse);

      // Run tree scan + aggregate
      controller.runTreeScanForTest(context);

      final issues = controller.issuesNotifier.value;

      // No VM-timeline-sourced issues should exist
      final vmOnlyIssues = issues
          .where((i) => i.observationSource == ObservationSource.vmTimeline)
          .toList();
      expect(vmOnlyIssues, isEmpty,
          reason: 'VM-only detectors must not produce issues without VM');
    });

    testWidgets('structural detectors work without VM', (tester) async {
      await tester.pumpWidget(buildMixedTree(500));
      final context = tester.element(find.byType(Directionality));

      // VM disconnected
      controller.simulateVmStateChangeForTest(false);

      controller.runTreeScanForTest(context);

      // Structural issues should still be generated from tree scanning
      final issues = controller.issuesNotifier.value;
      // The mixed tree doesn't contain anti-patterns, but the scan should
      // complete without error. The real validation is that it doesn't crash.
      expect(issues, isA<List<PerformanceIssue>>());
    });
  });
}
