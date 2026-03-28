import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/widget_watchdog.dart';

void main() {
  group('exportSnapshot', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test('returns valid SessionSnapshot with metadata', () {
      final snapshot = controller.exportSnapshot();

      expect(snapshot.packageVersion, '0.2.0');
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
      final smallController = WatchdogController(
        config: const WatchdogConfig(captureBufferCapacity: 2),
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
      final fresh = WatchdogController();
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
  });
}
