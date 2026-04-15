// Rebuild-stats scan-path unit tests — spec v15 M12.
//
// These tests exercise the `_scanTreeInner` drain → merge → route-switch
// pipeline that was added in M5/M7 for profile-mode per-widget rebuild
// counting. Widget tests run under `kDebugMode == true`, so the real
// profile-mode coordinator install (`installProfileMode()`) is NOT used
// here — spec R3 explicitly documents this limitation and notes that the
// only full end-to-end profile validation is the `rebuild_stats_probe.dart`
// M1 probe run against a physical device.
//
// Instead of producing real `FlutterTimeline` events, these tests inject
// a fake [DebugInstrumentationCoordinator] subclass via the `@visibleForTesting`
// `debugCoordinatorForTest` setter. The fake's `snapshot()` returns a
// hand-built `DebugSnapshot` tagged with
// `RebuildCountSource.flutterTimeline`, so the real `_scanTreeInner`
// merge block — which is gated on `source == flutterTimeline` — runs
// exactly as it would in profile mode. This exercises the production
// code path while keeping the test harness in debug mode.
//
// Coverage:
// - **Scan re-entry regression (R7):** a second `_scanTree` call while
//   `_scanInProgress == true` must be a silent no-op — the guard
//   prevents double-draining the coordinator (which would reset
//   `_lastSnapshotTime` and corrupt elapsed/per-second rate math).
// - **Null-route drop (R18):** when `_activeRouteSession == null`
//   (route is in `routeIgnorePatterns`, or pre-first-session), merged
//   counts are silently discarded rather than attributed to an unknown
//   session.
// - **Drain → attribute → route-switch ordering (R5):** within a single
//   `_scanTreeInner` call, merged counts MUST land on the pre-route-change
//   active session (A) even when the same scan detects a route change
//   and creates a fresh session (B). Reordering this pair (route-switch
//   before merge) would race the drain and mis-attribute counts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/models/base_detector.dart';

/// Fake coordinator that returns a pre-configured [DebugSnapshot] from
/// `snapshot()` and counts calls. Used to inject synthetic
/// `flutterTimeline`-source data into the real `_scanTreeInner` path
/// without needing profile-mode compilation.
class _FakeCoordinator extends DebugInstrumentationCoordinator {
  _FakeCoordinator() : super(installRebuild: false, installPaint: false);

  /// The snapshot returned by the next `snapshot()` call. After each call
  /// it is reset to an empty `none`-source snapshot so a subsequent scan
  /// doesn't re-merge stale counts.
  DebugSnapshot nextSnapshot = const DebugSnapshot(
    rebuildCounts: {},
    totalPaintCount: 0,
    elapsed: Duration.zero,
  );

  int snapshotCallCount = 0;

  @override
  DebugSnapshot snapshot() {
    snapshotCallCount++;
    final result = nextSnapshot;
    nextSnapshot = const DebugSnapshot(
      rebuildCounts: {},
      totalPaintCount: 0,
      elapsed: Duration.zero,
    );
    return result;
  }
}

/// Minimal single-route app used by the null-route and ordering tests.
/// `/home` resolves to a [Scaffold] so `_findVisiblePageContext` succeeds
/// and `_currentRouteName()` returns the settings name.
Widget _appWith(String routeName, {Widget? home}) {
  return MaterialApp(
    initialRoute: routeName,
    onGenerateRoute: (settings) => MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => Scaffold(
        key: ValueKey(settings.name),
        body: home ?? const SizedBox.shrink(),
      ),
    ),
  );
}

BuildContext _rootContext(WidgetTester tester) =>
    tester.element(find.byType(MaterialApp));

const _config = SleuthConfig(
  treeScanInterval: Duration(seconds: 1),
  enabledDetectors: {DetectorType.frameTiming},
);

void main() {
  group('Rebuild-stats scan pipeline (spec v15 M12)', () {
    late SleuthController controller;
    late _FakeCoordinator fake;

    setUp(() {
      controller = SleuthController(config: _config);
      controller.initializeDetectorsForTest();
      fake = _FakeCoordinator();
      // Replace whatever coordinator initializeDetectorsForTest installed
      // with our fake so `_scanTreeInner`'s drain returns controlled data.
      controller.debugCoordinatorForTest = fake;
    });

    tearDown(() {
      // Detach the fake BEFORE dispose so the controller's dispose path
      // doesn't call into it (and because _FakeCoordinator doesn't install
      // any framework slots, it needs no teardown of its own).
      controller.debugCoordinatorForTest = null;
      controller.dispose();
    });

    testWidgets('scan re-entry guard blocks second synchronous _scanTree call',
        (
      tester,
    ) async {
      await tester.pumpWidget(_appWith('/home'));
      await tester.pumpAndSettle();

      // Prime: first scan creates session A. Merge runs BEFORE route
      // detection, so with no active session yet the merge-block
      // `session != null` guard drops any counts drained on the first
      // scan — feed an empty snapshot to keep the baseline clean.
      controller.scanTreeFullPathForTest(_rootContext(tester));
      expect(fake.snapshotCallCount, 1);
      expect(controller.activeRouteSessionForTest, isNotNull);
      expect(
        controller.activeRouteSessionForTest!.rebuildCountsByType,
        isEmpty,
      );

      // Second scan merges ProductCard into the now-active session.
      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'ProductCard': 3},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      controller.scanTreeFullPathForTest(_rootContext(tester));

      expect(fake.snapshotCallCount, 2);
      expect(
        controller
            .activeRouteSessionForTest!.rebuildCountsByType['ProductCard'],
        3,
      );

      // Now simulate re-entry: flip the in-progress flag and call scan
      // again. The re-entry guard must early-return WITHOUT touching the
      // coordinator, so `snapshotCallCount` stays at 2.
      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'ProductCard': 99},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      controller.scanInProgressForTest = true;
      controller.scanTreeFullPathForTest(_rootContext(tester));

      expect(
        fake.snapshotCallCount,
        2,
        reason: 're-entry guard must block the second drain entirely',
      );
      expect(
        controller
            .activeRouteSessionForTest!.rebuildCountsByType['ProductCard'],
        3,
        reason: 'ProductCard count must not have been merged a second time',
      );

      // Release the flag — the next scan should proceed normally. The
      // 99-count `nextSnapshot` was never consumed (fake wasn't called)
      // and has since been reset by our pre-set — seed fresh counts.
      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'ProductCard': 2},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      controller.scanInProgressForTest = false;
      controller.scanTreeFullPathForTest(_rootContext(tester));

      expect(fake.snapshotCallCount, 3);
      expect(
        controller
            .activeRouteSessionForTest!.rebuildCountsByType['ProductCard'],
        5,
        reason: '3 + 2 — merge is additive',
      );
    });

    testWidgets('null active route session drops merged counts silently (R18)',
        (
      tester,
    ) async {
      // Reconfigure with an ignore pattern so the first scan sees /home as
      // ignored and sets `_activeRouteSession = null`.
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
          routeIgnorePatterns: {'/home'},
        ),
      );
      controller.initializeDetectorsForTest();
      fake = _FakeCoordinator();
      controller.debugCoordinatorForTest = fake;

      await tester.pumpWidget(_appWith('/home'));
      await tester.pumpAndSettle();

      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'IgnoredCard': 7},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      controller.scanTreeFullPathForTest(_rootContext(tester));

      // Route /home is ignored → no active session was created.
      expect(controller.activeRouteSessionForTest, isNull);
      // And the drained counts were dropped — nothing in route history
      // received them.
      expect(
        controller.routeHistoryForTest,
        isEmpty,
        reason: 'ignored routes must not spawn sessions',
      );
      expect(
        fake.snapshotCallCount,
        1,
        reason: 'drain still ran — counts were simply discarded at merge time',
      );
    });

    testWidgets(
        'drain → attribute → route-switch ordering: '
        'counts land on pre-route-change session (R5)', (tester) async {
      // First, establish session A on /home.
      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      await tester.pumpWidget(_appWith('/home'));
      await tester.pumpAndSettle();
      controller.scanTreeFullPathForTest(_rootContext(tester));

      final sessionA = controller.activeRouteSessionForTest!;
      expect(sessionA.routeName, '/home');
      expect(sessionA.rebuildCountsByType, isEmpty);

      // Navigate to /settings WITHOUT scanning yet. The active session is
      // still A — the controller has no idea the widget tree changed.
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/settings');
      await tester.pumpAndSettle();

      // Now prime the fake with counts that accumulated "while A was
      // active" and trigger the next scan. Inside `_scanTreeInner` the
      // drain happens BEFORE the route-change block, so the counts must
      // land on A even though the same scan will create session B.
      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'Greeter': 4, 'Header': 1},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      controller.scanTreeFullPathForTest(_rootContext(tester));

      // Session A received the counts.
      expect(sessionA.rebuildCountsByType['Greeter'], 4);
      expect(sessionA.rebuildCountsByType['Header'], 1);
      expect(sessionA.totalRebuilds, 5);
      // Session A is now closed (endedAt stamped).
      expect(sessionA.endedAt, isNotNull);

      // A fresh session B exists for /settings with empty counts.
      final sessionB = controller.activeRouteSessionForTest!;
      expect(sessionB.routeName, '/settings');
      expect(sessionB, isNot(same(sessionA)));
      expect(
        sessionB.rebuildCountsByType,
        isEmpty,
        reason: 'drained counts belonged to A and must not leak into B',
      );
    });

    testWidgets(
        'debugCallback-source snapshots are NOT merged into '
        'rebuildCountsByType (KDD-1 mutual exclusivity)', (tester) async {
      // The merge block is gated on `source == flutterTimeline`. Debug-mode
      // snapshots (source == debugCallback) are consumed by detectors via
      // `updateDebugSnapshot()` and must never touch the session rollup
      // map, or the two sources would double-count.
      await tester.pumpWidget(_appWith('/home'));
      await tester.pumpAndSettle();

      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'ShouldNotMerge': 42},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.debugCallback,
      );
      controller.scanTreeFullPathForTest(_rootContext(tester));

      expect(controller.activeRouteSessionForTest!.routeName, '/home');
      expect(
        controller.activeRouteSessionForTest!.rebuildCountsByType,
        isEmpty,
        reason: 'debugCallback-source must not touch rebuildCountsByType',
      );
    });

    testWidgets('subsequent scans additively merge counts on the same session',
        (tester) async {
      await tester.pumpWidget(_appWith('/home'));
      await tester.pumpAndSettle();

      // Prime — establish session A (counts drained on first scan are
      // dropped because `_activeRouteSession` is null at merge time).
      controller.scanTreeFullPathForTest(_rootContext(tester));
      final session = controller.activeRouteSessionForTest!;
      expect(session.rebuildCountsByType, isEmpty);

      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'ProductCard': 3, 'Header': 1},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      controller.scanTreeFullPathForTest(_rootContext(tester));
      expect(session.rebuildCountsByType['ProductCard'], 3);

      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'ProductCard': 2, 'Footer': 5},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      controller.scanTreeFullPathForTest(_rootContext(tester));

      // Same session, counts accumulated additively.
      expect(controller.activeRouteSessionForTest, same(session));
      expect(session.rebuildCountsByType['ProductCard'], 5);
      expect(session.rebuildCountsByType['Header'], 1);
      expect(session.rebuildCountsByType['Footer'], 5);
      expect(session.totalRebuilds, 11);
    });
  });
}
