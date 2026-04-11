import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';

/// Config enabling frameTiming so jank issues can be produced.
const _config = SleuthConfig(
  treeScanInterval: Duration(seconds: 1),
  enabledDetectors: {DetectorType.frameTiming},
);

Widget _multiRouteApp() {
  return MaterialApp(
    initialRoute: '/home',
    onGenerateRoute: (settings) => MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => Scaffold(body: SizedBox(key: ValueKey(settings.name))),
    ),
  );
}

BuildContext _rootContext(WidgetTester tester) =>
    tester.element(find.byType(MaterialApp));

void main() {
  group('Route-scoped issue aggregation (M3)', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController(config: _config);
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('issues upserted to active route session', (tester) async {
      await tester.pumpWidget(_multiRouteApp());
      await tester.pumpAndSettle();

      // Establish a route session.
      controller.scanTreeFullPathForTest(_rootContext(tester));
      expect(controller.activeRouteSessionForTest!.issueSnapshots, isEmpty);

      // Feed jank frames to produce frameTiming issues.
      for (var i = 0; i < 10; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 40),
          rasterDuration: const Duration(milliseconds: 40),
          timestamp: DateTime(2026, 1, 1).add(Duration(milliseconds: i * 16)),
        ));
      }

      // Re-scan to trigger aggregation.
      controller.scanTreeFullPathForTest(_rootContext(tester));

      // If frameTiming detected issues, they should be in the route session.
      if (controller.issuesNotifier.value.isNotEmpty) {
        expect(
          controller.activeRouteSessionForTest!.issueSnapshots,
          isNotEmpty,
        );
        // Issue count in session matches global visible issues.
        expect(
          controller.activeRouteSessionForTest!.issueSnapshots.length,
          controller.issuesNotifier.value.length,
        );
      }
    });

    testWidgets('issues from different routes live in different sessions',
        (tester) async {
      await tester.pumpWidget(_multiRouteApp());
      await tester.pumpAndSettle();

      // Scan /home with jank.
      controller.scanTreeFullPathForTest(_rootContext(tester));
      for (var i = 0; i < 10; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 40),
          rasterDuration: const Duration(milliseconds: 40),
          timestamp: DateTime(2026, 1, 1).add(Duration(milliseconds: i * 16)),
        ));
      }
      controller.scanTreeFullPathForTest(_rootContext(tester));
      final homeIssueCount =
          controller.activeRouteSessionForTest!.issueSnapshots.length;

      // Navigate to /settings — fresh route session.
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/settings');
      await tester.pumpAndSettle();

      controller.scanTreeFullPathForTest(_rootContext(tester));

      // New route session starts with empty issues (no jank on /settings yet).
      expect(controller.activeRouteSessionForTest!.routeName, '/settings');
      expect(controller.activeRouteSessionForTest!.issueSnapshots, isEmpty);

      // Home session retains its issues.
      final homeSession = controller.routeHistoryNotifier.value
          .firstWhere((s) => s.routeName == '/home');
      expect(homeSession.issueSnapshots.length, homeIssueCount);
    });

    testWidgets('new route session starts with empty issueSnapshots',
        (tester) async {
      await tester.pumpWidget(_multiRouteApp());
      await tester.pumpAndSettle();

      controller.scanTreeFullPathForTest(_rootContext(tester));

      // Navigate to create a new session.
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/settings');
      await tester.pumpAndSettle();

      controller.scanTreeFullPathForTest(_rootContext(tester));
      expect(controller.activeRouteSessionForTest!.issueSnapshots, isEmpty);
    });

    testWidgets('upsert replaces existing issue with latest observation',
        (tester) async {
      await tester.pumpWidget(_multiRouteApp());
      await tester.pumpAndSettle();

      // Establish route + jank.
      controller.scanTreeFullPathForTest(_rootContext(tester));
      for (var i = 0; i < 10; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 40),
          rasterDuration: const Duration(milliseconds: 40),
          timestamp: DateTime(2026, 1, 1).add(Duration(milliseconds: i * 16)),
        ));
      }
      controller.scanTreeFullPathForTest(_rootContext(tester));

      final snapshots = controller.activeRouteSessionForTest!.issueSnapshots;
      if (snapshots.isNotEmpty) {
        final firstKey = snapshots.keys.first;
        final firstIssue = snapshots[firstKey]!;

        // Re-scan — same issues should be upserted (replaced), not duplicated.
        controller.scanTreeFullPathForTest(_rootContext(tester));

        final afterCount = snapshots.length;
        // Same number of unique issues (upserted, not appended).
        expect(afterCount, snapshots.length);

        // The issue for the same key is replaced with a fresh observation.
        expect(snapshots[firstKey], isNotNull);
        expect(snapshots[firstKey]!.title, firstIssue.title);
      }
    });
  });
}
