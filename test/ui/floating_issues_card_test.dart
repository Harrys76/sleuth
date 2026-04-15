import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/rebuild_stats_page.dart';

/// Minimal fake coordinator for the rebuild-stats banner tests. Mirrors
/// the M12 `_FakeCoordinator` pattern in `rebuild_stats_scan_test.dart`:
/// returns a pre-configured snapshot from `snapshot()` so the real
/// `_scanTreeInner` drain → merge block runs against synthetic
/// `flutterTimeline`-source data without needing profile-mode compilation.
class _FakeCoordinator extends DebugInstrumentationCoordinator {
  _FakeCoordinator() : super(installRebuild: false, installPaint: false);

  DebugSnapshot nextSnapshot = const DebugSnapshot(
    rebuildCounts: {},
    totalPaintCount: 0,
    elapsed: Duration.zero,
  );

  @override
  DebugSnapshot snapshot() {
    final result = nextSnapshot;
    nextSnapshot = const DebugSnapshot(
      rebuildCounts: {},
      totalPaintCount: 0,
      elapsed: Duration.zero,
    );
    return result;
  }
}

void main() {
  late SleuthController controller;

  setUp(() {
    controller = SleuthController();
    controller.initializeDetectorsForTest();
  });

  tearDown(() {
    controller.dispose();
  });

  Widget pumpCard({
    bool isDebugMode = true,
    SleuthConfig? config,
  }) {
    if (config != null) {
      controller.dispose();
      controller = SleuthController(config: config);
      controller.initializeDetectorsForTest();
    }
    return MaterialApp(
      home: Scaffold(
        body: FloatingIssuesCard(
          controller: controller,
          onClose: () {},
          isDebugMode: isDebugMode,
        ),
      ),
    );
  }

  // Use specific text to distinguish our banner from the existing
  // debug-mode disclaimer in _WarningBanners.
  const bannerText = 'timings are';

  group('M2: Minimize/maximize/restore', () {
    testWidgets('minimize hides body, shows only header', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Body content should be present initially
      expect(find.textContaining('No issues detected'), findsOneWidget);

      // Tap minimize
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();

      // Body content should be gone
      expect(find.textContaining('No issues detected'), findsNothing);
      // Header title should still be there
      expect(find.text('Sleuth'), findsOneWidget);
      // Restore button should appear (replaces minimize/maximize)
      expect(find.byIcon(Icons.filter_none), findsOneWidget);
      expect(find.byIcon(Icons.minimize), findsNothing);
      expect(find.byIcon(Icons.crop_square), findsNothing);
    });

    testWidgets('maximize expands card, body still present', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Tap maximize
      await tester.tap(find.byIcon(Icons.crop_square));
      await tester.pump();

      // Body content should still be present
      expect(find.textContaining('No issues detected'), findsOneWidget);
      // Restore button should appear
      expect(find.byIcon(Icons.filter_none), findsOneWidget);
      expect(find.byIcon(Icons.minimize), findsNothing);
    });

    testWidgets('restore after minimize brings back body', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Minimize
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();
      expect(find.textContaining('No issues detected'), findsNothing);

      // Restore
      await tester.tap(find.byIcon(Icons.filter_none));
      await tester.pump();

      // Body should be back
      expect(find.textContaining('No issues detected'), findsOneWidget);
      // Minimize/maximize buttons should be back
      expect(find.byIcon(Icons.minimize), findsOneWidget);
      expect(find.byIcon(Icons.crop_square), findsOneWidget);
      expect(find.byIcon(Icons.filter_none), findsNothing);
    });

    testWidgets('restore after maximize returns to normal', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Maximize
      await tester.tap(find.byIcon(Icons.crop_square));
      await tester.pump();
      expect(find.byIcon(Icons.filter_none), findsOneWidget);

      // Restore
      await tester.tap(find.byIcon(Icons.filter_none));
      await tester.pump();

      // Normal state buttons restored
      expect(find.byIcon(Icons.minimize), findsOneWidget);
      expect(find.byIcon(Icons.crop_square), findsOneWidget);
      expect(find.byIcon(Icons.filter_none), findsNothing);
    });

    testWidgets('minimize→maximize→restore cycle works', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Minimize
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();
      expect(find.textContaining('No issues detected'), findsNothing);

      // Restore to normal
      await tester.tap(find.byIcon(Icons.filter_none));
      await tester.pump();
      expect(find.textContaining('No issues detected'), findsOneWidget);

      // Maximize
      await tester.tap(find.byIcon(Icons.crop_square));
      await tester.pump();
      expect(find.textContaining('No issues detected'), findsOneWidget);

      // Restore to normal again
      await tester.tap(find.byIcon(Icons.filter_none));
      await tester.pump();
      expect(find.byIcon(Icons.minimize), findsOneWidget);
      expect(find.byIcon(Icons.crop_square), findsOneWidget);
    });

    testWidgets('close button works in all states', (tester) async {
      var closed = false;
      controller.dispose();
      controller = SleuthController();
      controller.initializeDetectorsForTest();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FloatingIssuesCard(
            controller: controller,
            onClose: () => closed = true,
            isDebugMode: false,
          ),
        ),
      ));

      // Minimize first
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();

      // Close button should still work
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(closed, isTrue);
    });
  });

  group('M6: Debug-mode banner', () {
    testWidgets('banner present in debug mode with default config',
        (tester) async {
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      expect(find.textContaining(bannerText), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);
    });

    testWidgets('tap dismiss hides banner', (tester) async {
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      expect(find.textContaining(bannerText), findsOneWidget);

      // Tap the close icon on the banner (last, since header also has close)
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();

      expect(find.textContaining(bannerText), findsNothing);
    });

    testWidgets('showDebugModeBanner:false hides banner', (tester) async {
      await tester.pumpWidget(pumpCard(
        isDebugMode: true,
        config: const SleuthConfig(showDebugModeBanner: false),
      ));

      expect(find.textContaining(bannerText), findsNothing);
    });

    testWidgets('isDebugMode:false hides banner', (tester) async {
      await tester.pumpWidget(pumpCard(isDebugMode: false));

      expect(find.textContaining(bannerText), findsNothing);
    });

    testWidgets('new widget instance shows banner again after dismiss',
        (tester) async {
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      // Dismiss (last close icon — first is the header's)
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();
      expect(find.textContaining(bannerText), findsNothing);

      // Force state disposal by pumping a different widget, then rebuild
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      // Banner should reappear (per-instance, not persisted)
      expect(find.textContaining(bannerText), findsOneWidget);
    });
  });

  group('Rebuild stats banner (always-on entry point)', () {
    // The banner is the SOLE data-discovery path for rebuild stats since
    // v0.15.2 — the previous `rebuild_hotspot_summary` rollup IssueCard
    // (and the always-on chip above the issue list) was removed in
    // v0.15.2 because (a) the panel covers both the data and the signal,
    // (b) an always-pinned IssueCard collided with the issue ranker /
    // severity-escalation pipeline, and (c) profile-mode KDD-5 inflations
    // made route entry look like a warning storm in the issues list.
    //
    // The panel must therefore render whenever the active RouteSession
    // has rebuild attribution, regardless of volume, so low-volume routes
    // are still reachable through `RebuildStatsPage` via the inline
    // "See all N →" drilldown link.
    //
    // Tests use the M12 fake-coordinator + scanTreeFullPathForTest pattern
    // from `test/controller/rebuild_stats_scan_test.dart` to inject
    // synthetic `flutterTimeline`-source counts through the real
    // `_scanTreeInner` drain → merge path. The first scan creates the
    // active session and drops merged counts (no session at merge time);
    // the second scan then merges into the now-active session.

    // Lightweight pump for banner tests — the scan loop needs a Scaffold
    // above the floating card for `_findVisiblePageContext` to succeed.
    Widget pumpCardForBanner(SleuthController c) {
      return MaterialApp(
        home: Scaffold(
          body: FloatingIssuesCard(
            controller: c,
            onClose: () {},
            isDebugMode: false,
          ),
        ),
      );
    }

    Future<void> primeAndMergeCounts(
      WidgetTester tester,
      SleuthController c,
      _FakeCoordinator fake,
      Map<String, int> counts,
    ) async {
      // First scan — creates the active route session. Merge runs before
      // route detection, so any counts on this scan land on a `null`
      // session and are dropped (R18). Feed an empty snapshot.
      c.scanTreeFullPathForTest(tester.element(find.byType(MaterialApp)));
      // Second scan merges synthetic counts into the now-active session.
      fake.nextSnapshot = DebugSnapshot(
        rebuildCounts: counts,
        totalPaintCount: 0,
        elapsed: const Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      c.scanTreeFullPathForTest(tester.element(find.byType(MaterialApp)));
      await tester.pump();
    }

    testWidgets('banner is hidden when active session has zero rebuild counts',
        (tester) async {
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      controller.debugCoordinatorForTest = _FakeCoordinator();

      await tester.pumpWidget(pumpCardForBanner(controller));
      await tester.pumpAndSettle();

      // No scan run → no active session → banner hidden.
      expect(find.byIcon(Icons.repeat), findsNothing);
      expect(find.textContaining('Rebuilds:'), findsNothing);
    });

    testWidgets(
        'banner appears with total + widget count once attribution lands',
        (tester) async {
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      final fake = _FakeCoordinator();
      controller.debugCoordinatorForTest = fake;

      await tester.pumpWidget(pumpCardForBanner(controller));
      await tester.pumpAndSettle();

      await primeAndMergeCounts(tester, controller, fake, {
        'ProductCard': 12,
        'PriceTag': 5,
      });

      expect(find.byIcon(Icons.repeat), findsOneWidget);
      // 17 total across 2 widget types — the chip is the data-discovery
      // path so it surfaces both numbers, not just the headline total.
      expect(find.text('Rebuilds: 17 across 2 widgets'), findsOneWidget);
    });

    testWidgets(
        'banner uses singular "widget" when only one widget type has counts',
        (tester) async {
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      final fake = _FakeCoordinator();
      controller.debugCoordinatorForTest = fake;

      await tester.pumpWidget(pumpCardForBanner(controller));
      await tester.pumpAndSettle();

      await primeAndMergeCounts(tester, controller, fake, {'SoloCard': 3});

      expect(find.text('Rebuilds: 3 across 1 widget'), findsOneWidget);
    });

    testWidgets('banner renders for low-volume routes (always-on contract)',
        (tester) async {
      // v0.15.2 always-on contract: the panel must render whenever the
      // active session has ANY rebuild attribution, no matter how small.
      // Pre-v0.15.2 the `rebuild_hotspot_summary` rollup IssueCard was
      // gated on a sustained rate (≥ 20 builds/sec + ≥ 30 total + ≥ 1.5s
      // duration), so a handful of rebuilds on a quiet route had no UI
      // surface at all. The inline panel replaced that gating: it shows
      // up the moment counts exist, and the drilldown link is the only
      // entry point users have for low-volume routes. This test pins
      // that "no minimum" contract so a future rate-floor regression
      // can't silently re-introduce a discoverability gap.
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      final fake = _FakeCoordinator();
      controller.debugCoordinatorForTest = fake;

      await tester.pumpWidget(pumpCardForBanner(controller));
      await tester.pumpAndSettle();

      // 4 rebuilds total — pre-v0.15.2 this was below every rollup gate
      // (rate, count, and duration). The panel must still render.
      await primeAndMergeCounts(tester, controller, fake, {'TinyCard': 4});

      expect(find.text('Rebuilds: 4 across 1 widget'), findsOneWidget);
    });

    testWidgets('panel is collapsed by default — top rows are hidden',
        (tester) async {
      // v0.15.2 UX knob #2: the panel starts collapsed. Header is the
      // only row visible until the user expands it. This pins the
      // "minimal noise when nothing surprising is happening" contract.
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      final fake = _FakeCoordinator();
      controller.debugCoordinatorForTest = fake;

      await tester.pumpWidget(pumpCardForBanner(controller));
      await tester.pumpAndSettle();

      await primeAndMergeCounts(tester, controller, fake, {
        'ProductCard': 12,
        'PriceTag': 5,
      });

      // Header summary is visible…
      expect(find.text('Rebuilds: 17 across 2 widgets'), findsOneWidget);
      // …but the per-widget rows + drilldown link are not.
      expect(find.textContaining('ProductCard'), findsNothing);
      expect(find.textContaining('See all'), findsNothing);
      // Collapsed chevron is shown (expand_more, not expand_less).
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsNothing);
    });

    testWidgets('tapping the header expands top-3 rows + footer link',
        (tester) async {
      // v0.15.2 UX knob #1: top-N = 3. The expanded panel shows the
      // three highest-count widget types, the inflation footnote, and
      // the "See all N →" drilldown link.
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      final fake = _FakeCoordinator();
      controller.debugCoordinatorForTest = fake;

      await tester.pumpWidget(pumpCardForBanner(controller));
      await tester.pumpAndSettle();

      await primeAndMergeCounts(tester, controller, fake, {
        'ProductCard': 20,
        'PriceTag': 10,
        'Avatar': 5,
        'BadgeChip': 2, // 4th — must NOT be shown inline.
      });

      // Tap the collapsed header to expand.
      await tester.tap(find.text('Rebuilds: 37 across 4 widgets'));
      await tester.pump();

      // Top-3 widget rows are now visible…
      expect(find.text('ProductCard'), findsOneWidget);
      expect(find.text('PriceTag'), findsOneWidget);
      expect(find.text('Avatar'), findsOneWidget);
      // …but the 4th widget is NOT inlined.
      expect(find.text('BadgeChip'), findsNothing);
      // Inflation footnote is rendered…
      expect(find.text('incl. inflations'), findsOneWidget);
      // …and the drilldown link uses the full hotspot count (4).
      expect(find.text('See all 4 \u2192'), findsOneWidget);
      // Chevron flipped.
      expect(find.byIcon(Icons.expand_less), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('tapping "See all" link pushes the RebuildStatsPage drilldown',
        (tester) async {
      // The drilldown is reached via expand → tap link, NOT via tap on
      // the header (which now toggles expansion). This test pins that
      // wiring end-to-end through the same snapshot-and-push code path
      // the v0.15.0/v0.15.1 rollup IssueCard used before removal.
      //
      // Needs ≥ 4 widget types because v0.15.2 C2 hides the redundant
      // "See all N →" link when widgetCount ≤ topN = 3 (the inline rows
      // already show every widget in that case, so a drilldown would
      // surface nothing new).
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      final fake = _FakeCoordinator();
      controller.debugCoordinatorForTest = fake;

      await tester.pumpWidget(pumpCardForBanner(controller));
      await tester.pumpAndSettle();

      await primeAndMergeCounts(tester, controller, fake, {
        'ProductCard': 7,
        'PriceTag': 3,
        'Avatar': 2,
        'Footer': 1,
      });

      // Drilldown not yet visible.
      expect(find.byType(RebuildStatsPage), findsNothing);

      // Expand the panel.
      await tester.tap(find.text('Rebuilds: 13 across 4 widgets'));
      await tester.pump();

      // Now tap the "See all 4 →" link.
      await tester.tap(find.text('See all 4 \u2192'));
      await tester.pump();

      // Drilldown is now mounted.
      expect(find.byType(RebuildStatsPage), findsOneWidget);
    });

    testWidgets('expanded panel shows pause icon — tap freezes counts',
        (tester) async {
      // The pause/resume toggle freezes the rendered counts so the user
      // can read a stable snapshot while live attribution continues to
      // accumulate. Frozen counts ignore subsequent merges until Resume
      // (or auto-resume on route change) clears the freeze.
      //
      // We need ≥ 4 widget types in the panel so that the inline panel
      // renders the "See all N →" drilldown link (v0.15.2 C2: link is
      // suppressed when widgetCount ≤ topN = 3 because the inline rows
      // already show everything). Without ≥ 4 the TF2 panel↔drilldown
      // contract assertion below could not exercise the snapshot path.
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      final fake = _FakeCoordinator();
      controller.debugCoordinatorForTest = fake;

      await tester.pumpWidget(pumpCardForBanner(controller));
      await tester.pumpAndSettle();

      await primeAndMergeCounts(tester, controller, fake, {
        'ProductCard': 8,
        'PriceTag': 4,
        'Avatar': 2,
        'Footer': 1,
      });

      await tester.tap(find.text('Rebuilds: 15 across 4 widgets'));
      await tester.pump();

      // Pause icon is visible only while expanded.
      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);

      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();

      // Pause flipped to play_arrow (Resume).
      expect(find.byIcon(Icons.pause), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      // Header still shows the frozen total even after a fresh merge.
      // Drive a second merge that would change the live total — the
      // frozen view must NOT update.
      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'ProductCard': 5},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      controller
          .scanTreeFullPathForTest(tester.element(find.byType(MaterialApp)));
      await tester.pump();

      // Frozen at 15, not 20 (15 + 5 from the new merge).
      expect(find.text('Rebuilds: 15 across 4 widgets'), findsOneWidget);
      expect(find.text('Rebuilds: 20 across 4 widgets'), findsNothing);

      // TF2: panel ↔ drilldown contract. While paused, tapping the
      // "See all N →" link must open RebuildStatsPage against the
      // FROZEN counts, not the live `session.rebuildCountsByType`.
      // Pre-fix the drilldown snapshot was read from `session` at tap
      // time, so a paused panel showing 15 would push a drilldown
      // showing 20 — the C1 snapshot-drift bug. This assertion pins
      // the fix end-to-end through the full
      // banner.onTap → _onSeeAllRebuildsTap(overrideCounts) → push
      // path.
      await tester.tap(find.text('See all 4 \u2192'));
      await tester.pumpAndSettle();
      expect(find.byType(RebuildStatsPage), findsOneWidget);

      // Both the panel (still mounted under the drilldown) and the
      // drilldown render `×8`-style text, so we must scope all finds
      // to the drilldown subtree to assert the contract precisely.
      Finder inDrilldown(Finder f) =>
          find.descendant(of: find.byType(RebuildStatsPage), matching: f);

      // Drilldown header summary chips: 15 total, 4 distinct types
      // (matches the FROZEN snapshot, not the live total of 20).
      expect(inDrilldown(find.text('15')), findsOneWidget);
      expect(inDrilldown(find.text('20')), findsNothing);
      // The live ProductCard count would be 13 (8 + 5); the frozen
      // count is 8, so the drilldown row for ProductCard must read ×8.
      expect(inDrilldown(find.text('\u00d78')), findsOneWidget);
      expect(inDrilldown(find.text('\u00d713')), findsNothing);
    });

    testWidgets('banner is hidden while the card is minimized', (tester) async {
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      final fake = _FakeCoordinator();
      controller.debugCoordinatorForTest = fake;

      await tester.pumpWidget(pumpCardForBanner(controller));
      await tester.pumpAndSettle();

      await primeAndMergeCounts(tester, controller, fake, {'Card': 6});
      expect(find.byIcon(Icons.repeat), findsOneWidget);

      // Minimize the card — the entire body (including all banners) is
      // suppressed. The chip should disappear with the rest of the body.
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();

      expect(find.byIcon(Icons.repeat), findsNothing);
      expect(find.textContaining('Rebuilds:'), findsNothing);
    });
  });
}
