import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/sleuth.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  group('exportSnapshot', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test('returns valid SessionSnapshot with metadata', () {
      final snapshot = controller.exportSnapshot();

      expect(snapshot.packageVersion, '0.5.2');
      expect(snapshot.schemaVersion, 2);
      expect(snapshot.capturedFrames, isEmpty);
      expect(snapshot.currentIssues, isEmpty);
      expect(snapshot.frameStatsSummary.totalFrames, 0);
    });

    test('capturedFrames populated from jank frames', () {
      // Feed enough jank frames to trigger sustained jank detection.
      // In basic mode (!vmConnected), _onFrameStats creates verdicts for jank.
      for (var i = 1; i <= 5; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 50),
          rasterDuration: const Duration(milliseconds: 10),
          timestamp: DateTime.now(),
        ));
      }

      expect(controller.captureBufferForTest.length, greaterThan(0));
      final snapshot = controller.exportSnapshot();
      expect(snapshot.capturedFrames, isNotEmpty);
    });

    test('non-jank frames not captured', () {
      for (var i = 1; i <= 5; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 5),
          rasterDuration: const Duration(milliseconds: 5),
          timestamp: DateTime.now(),
        ));
      }

      expect(controller.captureBufferForTest.isEmpty, isTrue);
    });

    test('duplicate frame guard prevents double capture', () {
      // Feed the same frame number twice — should only capture once.
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 50),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
      ));
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 50),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
      ));

      // At most 1 capture for frame #1
      final entries = controller.captureBufferForTest.entries
          .where((e) => e.frameStats.frameNumber == 1)
          .toList();
      expect(entries.length, lessThanOrEqualTo(1));
    });

    test('exportSnapshotJson produces valid decodable JSON', () {
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 50),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
      ));

      final jsonStr = controller.exportSnapshotJson();
      expect(() => jsonDecode(jsonStr), returnsNormally);

      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(decoded.containsKey('capturedFrames'), isTrue);
      expect(decoded.containsKey('currentIssues'), isTrue);
      expect(decoded.containsKey('frameStatsSummary'), isTrue);
    });

    test('frameStatsSummary reflects live buffer', () {
      for (var i = 1; i <= 10; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: Duration(milliseconds: i.isOdd ? 50 : 5),
          rasterDuration: const Duration(milliseconds: 5),
          timestamp: DateTime.now(),
        ));
      }

      final snapshot = controller.exportSnapshot();
      expect(snapshot.frameStatsSummary.totalFrames, 10);
      expect(snapshot.frameStatsSummary.jankFrames, greaterThan(0));
    });

    test('captureBufferCapacity config respected', () {
      final smallController = SleuthController(
        config: const SleuthConfig(captureBufferCapacity: 2),
      );
      smallController.initializeDetectorsForTest();

      for (var i = 1; i <= 10; i++) {
        smallController.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 50),
          rasterDuration: const Duration(milliseconds: 10),
          timestamp: DateTime.now(),
        ));
      }

      expect(smallController.captureBufferForTest.length, lessThanOrEqualTo(2));
      smallController.dispose();
    });

    test('export before initialize returns empty snapshot', () {
      // Fresh controller without calling initializeDetectorsForTest.
      // Don't dispose — late final detectors haven't been initialized.
      final fresh = SleuthController();
      final snapshot = fresh.exportSnapshot();

      expect(snapshot.capturedFrames, isEmpty);
      expect(snapshot.currentIssues, isEmpty);
      expect(snapshot.frameStatsSummary.totalFrames, 0);
    });

    testWidgets('exported relatedIssues carry route/context tags',
        (tester) async {
      // Build a widget tree that triggers structural issues.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  25,
                  (i) => SizedBox(key: ValueKey(i), height: 10),
                ),
              ),
            ),
          ),
        ),
      );

      // Run tree scan to populate and stamp issues.
      // Use Scaffold context (inside the route) so ModalRoute.of() resolves.
      controller.runTreeScanForTest(
        tester.element(find.byType(Scaffold)),
      );

      // Verify stamped issues exist.
      expect(controller.issuesNotifier.value, isNotEmpty);

      // Feed a jank frame to trigger capture.
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 50),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
      ));

      // Capture buffer should have an entry with stamped issues.
      expect(controller.captureBufferForTest.isEmpty, isFalse);
      final entry = controller.captureBufferForTest.entries.first;
      expect(entry.relatedIssues, isNotEmpty);

      // Verify route/context tags were actually stamped by _aggregateIssues.
      final stamped = entry.relatedIssues.first;
      expect(stamped.routeName, '/',
          reason: 'routeName should be stamped from MaterialApp default route');
      expect(stamped.debugModeDisclaimer, isTrue,
          reason: 'debugModeDisclaimer should be true in debug mode');
    });

    test('phase events buffered from timeline data', () {
      final data = enrichedBuildData(
        buildDurationUs: 15000,
        dirtyCount: 5,
        dirtyList: ['MyWidget'],
      );
      controller.feedTimelineDataForTest(data);

      expect(controller.phaseEventBufferForTest, hasLength(1));
      expect(
          controller.phaseEventBufferForTest.first.phase, TimelinePhase.build);
      expect(controller.phaseEventBufferForTest.first.dirtyCount, 5);
    });

    test('phase event buffer respects 100-event cap', () {
      // Feed 110 batches with 1 phase event each
      for (var i = 0; i < 110; i++) {
        controller.feedTimelineDataForTest(enrichedBuildData(
          buildDurationUs: 5000,
          baseTimestampUs: i * 10000,
        ));
      }

      expect(controller.phaseEventBufferForTest, hasLength(100));
      // Oldest events should have been evicted (FIFO)
      expect(controller.phaseEventBufferForTest.first.timestampUs, 10 * 10000);
    });

    test('GC events buffered from timeline data', () {
      final data = gcHeavyData(gcCount: 3);
      controller.feedTimelineDataForTest(data);

      expect(controller.gcEventBufferForTest, hasLength(3));
      expect(controller.gcEventBufferForTest.first.name, 'GC');
      expect(controller.gcEventBufferForTest.first.category, 'gc');
    });

    test('platform channel events buffered from timeline data', () {
      final data = platformChannelData(channelEventCount: 2);
      controller.feedTimelineDataForTest(data);

      expect(controller.platformChannelBufferForTest, hasLength(2));
    });

    test('export includes schemaVersion 2', () {
      final snapshot = controller.exportSnapshot();
      expect(snapshot.schemaVersion, 2);

      final json = snapshot.toJson();
      expect(json['schemaVersion'], 2);
    });

    test('export includes phaseEvents when buffer non-empty', () {
      controller.feedTimelineDataForTest(enrichedBuildData(
        buildDurationUs: 10000,
        dirtyCount: 3,
      ));

      final snapshot = controller.exportSnapshot();
      expect(snapshot.phaseEvents, isNotNull);
      expect(snapshot.phaseEvents, hasLength(1));
    });

    test('export includes gcEvents when buffer non-empty', () {
      controller.feedTimelineDataForTest(gcHeavyData(gcCount: 5));

      final snapshot = controller.exportSnapshot();
      expect(snapshot.gcEvents, isNotNull);
      expect(snapshot.gcEvents, hasLength(5));
    });

    test('export includes recentFrames with full buffer contents', () {
      for (var i = 1; i <= 5; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(microseconds: 8000),
          rasterDuration: const Duration(microseconds: 4000),
          timestamp: DateTime.now(),
        ));
      }

      final snapshot = controller.exportSnapshot();
      expect(snapshot.recentFrames, isNotNull);
      expect(snapshot.recentFrames, hasLength(5));
    });

    test('export includes fpsPercentiles when buffer has frames', () {
      for (var i = 1; i <= 10; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: Duration(microseconds: i * 5000),
          rasterDuration: const Duration(microseconds: 3000),
          timestamp: DateTime.now(),
        ));
      }

      final snapshot = controller.exportSnapshot();
      expect(snapshot.frameStatsSummary.fpsPercentiles, isNotNull);
      expect(snapshot.frameStatsSummary.fpsPercentiles!.p50, greaterThan(0));
    });

    testWidgets('exported issues have rankingScore populated', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  25,
                  (i) => SizedBox(key: ValueKey(i), height: 10),
                ),
              ),
            ),
          ),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Scaffold)),
      );

      // Only test if there are issues
      if (controller.issuesNotifier.value.isNotEmpty) {
        final snapshot = controller.exportSnapshot();
        for (final issue in snapshot.currentIssues) {
          expect(issue.rankingScore, isNotNull,
              reason: 'Every exported issue should have a ranking score');
          expect(issue.rankingBreakdown, isNotNull,
              reason: 'Every exported issue should have a ranking breakdown');
        }
      }
    });

    test('pre-init export has null for v2 optional fields', () {
      final fresh = SleuthController();
      final snapshot = fresh.exportSnapshot();

      expect(snapshot.phaseEvents, isNull);
      expect(snapshot.gcEvents, isNull);
      expect(snapshot.platformChannelEvents, isNull);
      // recentFrames is null when no frames recorded
      expect(snapshot.recentFrames, isNull);
    });

    test('JSON roundtrip of full v2 snapshot', () {
      // Feed frames and timeline data to populate all fields
      for (var i = 1; i <= 5; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(microseconds: 15000),
          rasterDuration: const Duration(microseconds: 5000),
          timestamp: DateTime.now(),
        ));
      }
      controller.feedTimelineDataForTest(enrichedBuildData(
        buildDurationUs: 10000,
        dirtyCount: 2,
      ));
      controller.feedTimelineDataForTest(gcHeavyData(gcCount: 1));

      final snapshot = controller.exportSnapshot();
      final jsonStr = snapshot.toJsonString();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final restored = SessionSnapshot.fromJson(decoded);

      expect(restored.schemaVersion, 2);
      expect(restored.recentFrames, hasLength(5));
      expect(restored.phaseEvents, isNotNull);
      expect(restored.gcEvents, isNotNull);
    });
  });
}
