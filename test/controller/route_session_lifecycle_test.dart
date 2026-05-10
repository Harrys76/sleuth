// IDE analyzer false-positive: dart:core RegExp uses @Deprecated.implement
// (fires only on subclassing). Remove when analyzer-server recognizes the
// implement-only kind.
// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/route_session.dart';

/// Config with only frameTiming so structural detectors don't fire.
const _cleanConfig = SleuthConfig(
  treeScanInterval: Duration(seconds: 1),
  enabledDetectors: {DetectorType.frameTiming},
);

/// A MaterialApp with a named route and Scaffold so that
/// `_findVisiblePageContext` resolves a scan context and
/// `_currentRouteName()` returns a real route name.
Widget _namedRouteApp({String routeName = '/home'}) {
  return MaterialApp(
    initialRoute: routeName,
    routes: {
      routeName: (_) => const Scaffold(body: SizedBox(width: 100, height: 100)),
    },
  );
}

/// Multi-route MaterialApp for testing route change detection.
/// Uses onGenerateRoute so we can push any route name.
Widget _multiRouteApp() {
  return MaterialApp(
    initialRoute: '/home',
    onGenerateRoute: (settings) => MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => Scaffold(body: SizedBox(key: ValueKey(settings.name))),
    ),
  );
}

/// Returns the root context above the Navigator for scan tests.
/// `_findVisiblePageContext` needs to walk DOWN from a root to
/// find the visible Scaffold, filter offstage routes, etc.
BuildContext _rootContext(WidgetTester tester) =>
    tester.element(find.byType(MaterialApp));

void main() {
  group('Route session lifecycle (M2)', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController(config: _cleanConfig);
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('creates route session on first scan', (tester) async {
      await tester.pumpWidget(_namedRouteApp());
      await tester.pumpAndSettle();
      final context = _rootContext(tester);

      expect(controller.activeRouteSessionForTest, isNull);
      expect(controller.routeHistoryNotifier.value, isEmpty);

      controller.scanTreeFullPathForTest(context);

      expect(controller.activeRouteSessionForTest, isNotNull);
      expect(controller.activeRouteSessionForTest!.routeName, '/home');
      expect(controller.activeRouteSessionForTest!.isActive, isTrue);
      expect(controller.activeRouteSessionForTest!.scanCycleCount, 1);
      expect(controller.routeHistoryNotifier.value.length, 1);
    });

    testWidgets('increments scanCycleCount on repeated scans of same route',
        (tester) async {
      await tester.pumpWidget(_namedRouteApp());
      await tester.pumpAndSettle();
      final context = _rootContext(tester);

      controller.scanTreeFullPathForTest(context);
      controller.scanTreeFullPathForTest(context);
      controller.scanTreeFullPathForTest(context);

      expect(controller.activeRouteSessionForTest!.scanCycleCount, 3);
      // Still same session, history length 1.
      expect(controller.routeHistoryNotifier.value.length, 1);
    });

    testWidgets('same route name does not create duplicate sessions',
        (tester) async {
      await tester.pumpWidget(_namedRouteApp());
      await tester.pumpAndSettle();
      final context = _rootContext(tester);

      controller.scanTreeFullPathForTest(context);
      final firstSession = controller.activeRouteSessionForTest;

      controller.scanTreeFullPathForTest(context);
      expect(controller.activeRouteSessionForTest, same(firstSession));
      expect(controller.routeHistoryNotifier.value.length, 1);
    });

    testWidgets('route change closes old session and creates new one',
        (tester) async {
      await tester.pumpWidget(_multiRouteApp());
      await tester.pumpAndSettle();

      // Scan home route.
      controller.scanTreeFullPathForTest(_rootContext(tester));
      final homeSession = controller.activeRouteSessionForTest!;
      expect(homeSession.routeName, '/home');
      expect(homeSession.isActive, isTrue);

      // Navigate to /settings.
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/settings');
      await tester.pumpAndSettle();

      controller.scanTreeFullPathForTest(_rootContext(tester));

      // Old session closed.
      expect(homeSession.isActive, isFalse);
      expect(homeSession.endedAt, isNotNull);

      // New session active.
      final settingsSession = controller.activeRouteSessionForTest!;
      expect(settingsSession.routeName, '/settings');
      expect(settingsSession.isActive, isTrue);
      expect(settingsSession.scanCycleCount, 1);

      // History has both.
      expect(controller.routeHistoryNotifier.value.length, 2);
      expect(controller.routeHistoryNotifier.value.first.routeName, '/home');
      expect(controller.routeHistoryNotifier.value.last.routeName, '/settings');
    });

    testWidgets('consecutive clean scans reset to 0 on route change',
        (tester) async {
      await tester.pumpWidget(_multiRouteApp());
      await tester.pumpAndSettle();

      // Run scans to build up clean scan count.
      controller.scanTreeFullPathForTest(_rootContext(tester));
      controller.scanTreeFullPathForTest(_rootContext(tester));
      expect(controller.consecutiveCleanScansForTest, greaterThan(0));

      // Navigate to /settings.
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/settings');
      await tester.pumpAndSettle();

      controller.scanTreeFullPathForTest(_rootContext(tester));

      // Route change resets _consecutiveCleanScans to 0 before the scan
      // runs detectors. If the scan itself is clean, the counter ends at 1.
      // Without the reset it would be 3.
      expect(controller.consecutiveCleanScansForTest, lessThanOrEqualTo(1));
    });

    testWidgets('unnamed routes get synthetic <unnamed-N> names',
        (tester) async {
      // A Scaffold without MaterialApp/Navigator — no ModalRoute, so
      // _currentRouteName() returns null and the unnamed counter kicks in.
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Scaffold(body: SizedBox(width: 100, height: 100)),
        ),
      );
      await tester.pumpAndSettle();
      // Pass root context (above the Scaffold).
      final context = tester.element(find.byType(Directionality));

      controller.scanTreeFullPathForTest(context);

      final session = controller.activeRouteSessionForTest!;
      expect(session.routeName, startsWith('<unnamed-'));
      expect(session.routeName, matches(RegExp(r'^<unnamed-\d+>$')));
    });

    testWidgets('repeated scans on unnamed route reuse same session (no leak)',
        (tester) async {
      // Regression: the unnamed counter must NOT increment on every scan.
      // Consecutive null route names should be treated as the same route.
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Scaffold(body: SizedBox(width: 100, height: 100)),
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Directionality));

      controller.scanTreeFullPathForTest(context);
      final firstSession = controller.activeRouteSessionForTest!;
      final firstName = firstSession.routeName;

      // Second scan — same null route → must reuse same session.
      controller.scanTreeFullPathForTest(context);
      expect(controller.activeRouteSessionForTest, same(firstSession));
      expect(controller.activeRouteSessionForTest!.routeName, firstName);
      expect(controller.activeRouteSessionForTest!.scanCycleCount, 2);

      // Third scan — still the same.
      controller.scanTreeFullPathForTest(context);
      expect(controller.routeHistoryNotifier.value.length, 1);
      expect(controller.activeRouteSessionForTest!.scanCycleCount, 3);
    });

    testWidgets('per-route frame stats populated via addFrameForTest',
        (tester) async {
      await tester.pumpWidget(_namedRouteApp());
      await tester.pumpAndSettle();
      final context = _rootContext(tester);

      controller.scanTreeFullPathForTest(context);

      // Add frames — these go through _onFrameStats which forwards to
      // the active route session.
      for (var i = 0; i < 5; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i + 1,
          uiDuration: const Duration(milliseconds: 16),
          rasterDuration: const Duration(milliseconds: 10),
          timestamp: DateTime(2026, 1, 1).add(Duration(milliseconds: i * 16)),
        ));
      }

      expect(controller.activeRouteSessionForTest!.frameStats.length, 5);
    });

    testWidgets(
        'route history honors SleuthConfig.routeHistoryCapacity '
        '(FIFO eviction when cap is exceeded)', (tester) async {
      // Use a small explicit cap so the test stays fast and the eviction
      // contract is exercised independently of the package default (which
      // was raised from 20 → 50 in v0.14.1 to accommodate bottom-nav apps
      // that create many per-tab sessions).
      final ctrl = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
          routeHistoryCapacity: 5,
        ),
      );
      ctrl.initializeDetectorsForTest();
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(_multiRouteApp());
      await tester.pumpAndSettle();

      // First scan — captures /home.
      ctrl.scanTreeFullPathForTest(_rootContext(tester));
      expect(ctrl.routeHistoryNotifier.value.length, 1);

      // Push 5 more routes (total 6 → cap triggers, evicts oldest /home).
      for (var i = 1; i <= 5; i++) {
        tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/r$i');
        await tester.pumpAndSettle();
        ctrl.scanTreeFullPathForTest(_rootContext(tester));
      }

      expect(ctrl.routeHistoryNotifier.value.length, 5,
          reason: 'Cap is configured to 5.');
      expect(ctrl.routeHistoryNotifier.value.first.routeName, '/r1',
          reason: 'Oldest (/home) must be evicted FIFO when cap is hit.');
      expect(ctrl.routeHistoryNotifier.value.last.routeName, '/r5');
    });

    testWidgets('routeHistoryNotifier value is unmodifiable', (tester) async {
      await tester.pumpWidget(_namedRouteApp());
      await tester.pumpAndSettle();
      final context = _rootContext(tester);

      controller.scanTreeFullPathForTest(context);

      final history = controller.routeHistoryNotifier.value;
      expect(
        () => (history).add(
          RouteSession(routeName: '/x', startedAt: DateTime.now()),
        ),
        throwsUnsupportedError,
      );
    });

    testWidgets('frames before first scan do not crash', (tester) async {
      // No scan yet — _activeRouteSession is null.
      // addFrameForTest should not throw (null-safe ?. guard).
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 16),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime(2026, 1, 1),
      ));

      // No crash, and no active session to receive the frame.
      expect(controller.activeRouteSessionForTest, isNull);
    });

    testWidgets('route session tracks frames from correct route only',
        (tester) async {
      await tester.pumpWidget(_multiRouteApp());
      await tester.pumpAndSettle();

      // Scan /home and add 3 frames.
      controller.scanTreeFullPathForTest(_rootContext(tester));
      for (var i = 0; i < 3; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i + 1,
          uiDuration: const Duration(milliseconds: 16),
          rasterDuration: const Duration(milliseconds: 10),
          timestamp: DateTime(2026, 1, 1).add(Duration(milliseconds: i * 16)),
        ));
      }

      final homeSession = controller.activeRouteSessionForTest!;
      expect(homeSession.frameStats.length, 3);

      // Navigate to /settings.
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/settings');
      await tester.pumpAndSettle();

      controller.scanTreeFullPathForTest(_rootContext(tester));

      // Add 2 frames — these should go to the /settings session.
      for (var i = 0; i < 2; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i + 10,
          uiDuration: const Duration(milliseconds: 16),
          rasterDuration: const Duration(milliseconds: 10),
          timestamp:
              DateTime(2026, 1, 1, 1).add(Duration(milliseconds: i * 16)),
        ));
      }

      // /home still has 3 frames, /settings has 2.
      expect(homeSession.frameStats.length, 3);
      expect(controller.activeRouteSessionForTest!.frameStats.length, 2);
    });

    test('dispose cleans up routeHistoryNotifier without throwing', () {
      final ctrl = SleuthController(config: _cleanConfig);
      ctrl.initializeDetectorsForTest();
      ctrl.dispose();
    });
  });
}
