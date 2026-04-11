import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';

void main() {
  group('Route ignore patterns', () {
    late SleuthController controller;

    tearDown(() {
      controller.dispose();
    });

    testWidgets('exact match skips session creation', (tester) async {
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
          routeIgnorePatterns: {'/splash'},
        ),
      );
      controller.initializeDetectorsForTest();

      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/splash',
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('Splash')),
          ),
        ),
      );

      final rootCtx = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(rootCtx);

      // /splash is ignored — no session should be created.
      expect(controller.routeHistoryNotifier.value, isEmpty);
      expect(controller.activeRouteSessionForTest, isNull);
    });

    testWidgets('wildcard match skips session creation', (tester) async {
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
          routeIgnorePatterns: {'/dialog*'},
        ),
      );
      controller.initializeDetectorsForTest();

      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/dialogConfirm',
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('Dialog')),
          ),
        ),
      );

      final rootCtx = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(rootCtx);

      expect(controller.routeHistoryNotifier.value, isEmpty);
      expect(controller.activeRouteSessionForTest, isNull);
    });

    testWidgets('non-matching route still tracked', (tester) async {
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
          routeIgnorePatterns: {'/splash', '/dialog*'},
        ),
      );
      controller.initializeDetectorsForTest();

      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/home',
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('Home')),
          ),
        ),
      );

      final rootCtx = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(rootCtx);

      expect(controller.routeHistoryNotifier.value, hasLength(1));
      expect(controller.routeHistoryNotifier.value.first.routeName, '/home');
    });
  });

  group('Route history capacity', () {
    late SleuthController controller;

    tearDown(() {
      controller.dispose();
    });

    testWidgets('capacity override respected', (tester) async {
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
          routeHistoryCapacity: 3,
        ),
      );
      controller.initializeDetectorsForTest();

      // Build app with initial route and navigate through 5 routes.
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/r1',
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => Scaffold(body: Text('Route ${settings.name}')),
          ),
        ),
      );

      final rootCtx = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(rootCtx);
      expect(controller.routeHistoryNotifier.value, hasLength(1));

      // Navigate through additional routes by pushing.
      for (final name in ['/r2', '/r3', '/r4', '/r5']) {
        Navigator.of(tester.element(find.byType(Scaffold))).pushNamed(name);
        await tester.pumpAndSettle();
        controller.scanTreeFullPathForTest(rootCtx);
      }

      // Should be capped at 3 (most recent).
      final history = controller.routeHistoryNotifier.value;
      expect(history.length, 3);
      // Oldest sessions evicted — last 3 remain.
      expect(history.map((s) => s.routeName).toList(), ['/r3', '/r4', '/r5']);
    });
  });

  group('Static API', () {
    test('routeHistory returns null when not initialized', () {
      expect(Sleuth.routeHistory, isNull);
    });

    test('routeHealthScore returns null when not initialized', () {
      expect(Sleuth.routeHealthScore('/home'), isNull);
    });
  });
}
