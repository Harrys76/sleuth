import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/persistence/sleuth_state_store.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';
import 'package:sleuth/src/ui/rebuild_stats_page.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';

import '../helpers/contrast_helpers.dart';
import '../helpers/overlay_harness.dart';

PerformanceIssue _pinIssue({
  required String id,
  IssueSeverity severity = IssueSeverity.warning,
  IssueConfidence confidence = IssueConfidence.confirmed,
  List<String>? rootCauseIds,
}) {
  return PerformanceIssue(
    severity: severity,
    category: IssueCategory.build,
    confidence: confidence,
    title: id,
    detail: 'Detail',
    fixHint: 'Fix',
    stableId: id,
    rootCauseIds: rootCauseIds,
  );
}

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

/// Emits the same issue every scan.
class _SteadyDetector extends BaseDetector {
  _SteadyDetector()
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.structural,
        name: 'Steady',
        description: 'Same issue every scan.',
      );

  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => _issues;
  @override
  List<WidgetHighlight> get highlights => const [];
  @override
  bool get isEnabled => _isEnabled;
  @override
  set isEnabled(bool v) => _isEnabled = v;

  @override
  void scanTree(BuildContext context) {
    _issues
      ..clear()
      ..add(_pinIssue(id: 'steady_issue'));
  }

  @override
  void dispose() => _issues.clear();
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

  Widget pumpCard({bool isDebugMode = true, SleuthConfig? config}) {
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(
              controller: controller,
              onClose: () => closed = true,
              isDebugMode: false,
            ),
          ),
        ),
      );

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
    testWidgets('banner present in debug mode with default config', (
      tester,
    ) async {
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      expect(find.textContaining(bannerText), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);
    });

    testWidgets('tap dismiss hides banner', (tester) async {
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      expect(find.textContaining(bannerText), findsOneWidget);

      // Tap the close icon on the banner (last, since header also has close)
      // The banners scroll when the card is short.
      await tester.ensureVisible(find.byIcon(Icons.close).last);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();

      expect(find.textContaining(bannerText), findsNothing);
    });

    testWidgets('showDebugModeBanner:false hides banner', (tester) async {
      await tester.pumpWidget(
        pumpCard(
          isDebugMode: true,
          config: const SleuthConfig(showDebugModeBanner: false),
        ),
      );

      expect(find.textContaining(bannerText), findsNothing);
    });

    testWidgets('isDebugMode:false hides banner', (tester) async {
      await tester.pumpWidget(pumpCard(isDebugMode: false));

      expect(find.textContaining(bannerText), findsNothing);
    });

    testWidgets('new widget instance shows banner again after dismiss', (
      tester,
    ) async {
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      // Dismiss (last close icon — first is the header's)
      // The banners scroll when the card is short.
      await tester.ensureVisible(find.byIcon(Icons.close).last);
      await tester.pump();
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
    // (b) an always-pinned IssueCard collided with issue ranker reorders,
    // and (c) profile-mode KDD-5 inflations
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
    Widget pumpCardForBanner(SleuthController c, {SleuthThemeData? theme}) {
      final card = FloatingIssuesCard(
        controller: c,
        onClose: () {},
        isDebugMode: false,
      );
      return MaterialApp(
        home: Scaffold(
          body: theme == null ? card : SleuthTheme(data: theme, child: card),
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

    testWidgets(
      'banner is hidden when active session has zero rebuild counts',
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
      },
    );

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
      },
    );

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
      },
    );

    testWidgets('banner renders for low-volume routes (always-on contract)', (
      tester,
    ) async {
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

    testWidgets('the header row is at least 48 px tall', (tester) async {
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
      await primeAndMergeCounts(tester, controller, fake, {'TinyCard': 4});

      final header = find.bySemanticsLabel(
        RegExp(r'^Rebuilds: 4 across 1 widget'),
      );
      expect(tester.getSize(header).height, greaterThanOrEqualTo(48));
    });

    testWidgets('the collapsed pause indicator is not announced twice', (
      tester,
    ) async {
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
      await primeAndMergeCounts(tester, controller, fake, {'TinyCard': 4});

      final header = find.text('Rebuilds: 4 across 1 widget');
      await tester.ensureVisible(header);
      await tester.tap(header);
      await tester.pump();
      await tester.ensureVisible(find.byIcon(Icons.pause));
      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();
      await tester.tap(header);
      await tester.pump();

      // Collapsed and paused: the header label says so; the icon is
      // silent.
      expect(
        find.bySemanticsLabel(RegExp(r'paused, collapsed')),
        findsOneWidget,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.pause)).semanticLabel,
        isNull,
      );
    });

    for (final (name, theme) in [
      ('dark', const SleuthThemeData()),
      ('light', const SleuthThemeData.light()),
      ('highContrastDark', const SleuthThemeData.highContrastDark()),
      ('highContrastLight', const SleuthThemeData.highContrastLight()),
    ]) {
      testWidgets('$name: the collapsed pause indicator keeps 3:1 on the '
          'banner', (tester) async {
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

        await tester.pumpWidget(pumpCardForBanner(controller, theme: theme));
        await tester.pumpAndSettle();
        await primeAndMergeCounts(tester, controller, fake, {'TinyCard': 4});

        final header = find.text('Rebuilds: 4 across 1 widget');
        await tester.ensureVisible(header);
        await tester.tap(header);
        await tester.pump();
        await tester.ensureVisible(find.byIcon(Icons.pause));
        await tester.tap(find.byIcon(Icons.pause));
        await tester.pump();
        await tester.tap(header);
        await tester.pump();

        final pause = find.byIcon(Icons.pause);
        final icon = tester.widget<Icon>(pause).color!;
        // The banner's tint, the nearest filled box behind the icon.
        final tint = tester
            .widgetList<DecoratedBox>(
              find.ancestor(of: pause, matching: find.byType(DecoratedBox)),
            )
            .map((box) => box.decoration)
            .whereType<BoxDecoration>()
            .firstWhere((d) => d.color != null)
            .color!;
        for (final host in const [Color(0xFF000000), Color(0xFFFFFFFF)]) {
          final banner = composite(tint, composite(theme.cardBackground, host));
          expect(
            wcagContrast(composite(icon, banner), banner),
            greaterThanOrEqualTo(3),
            reason: 'over $host',
          );
        }
      });
    }

    testWidgets('panel is collapsed by default — top rows are hidden', (
      tester,
    ) async {
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

    testWidgets('tapping the header expands top-3 rows + footer link', (
      tester,
    ) async {
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
      await tester.ensureVisible(find.text('Rebuilds: 37 across 4 widgets'));
      await tester.pump();
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

    testWidgets(
      'tapping "See all" link pushes the RebuildStatsPage drilldown',
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
        await tester.ensureVisible(find.text('Rebuilds: 13 across 4 widgets'));
        await tester.pump();
        await tester.tap(find.text('Rebuilds: 13 across 4 widgets'));
        await tester.pump();

        // Now tap the "See all 4 →" link.
        // The banners scroll when the card is short.
        await tester.ensureVisible(find.text('See all 4 \u2192'));
        await tester.pump();
        await tester.tap(find.text('See all 4 \u2192'));
        await tester.pump();

        // Drilldown is now mounted.
        expect(find.byType(RebuildStatsPage), findsOneWidget);
      },
    );

    testWidgets('expanded panel shows pause icon — tap freezes counts', (
      tester,
    ) async {
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

      await tester.ensureVisible(find.text('Rebuilds: 15 across 4 widgets'));
      await tester.pump();
      await tester.tap(find.text('Rebuilds: 15 across 4 widgets'));
      await tester.pump();

      // Pause icon is visible only while expanded.
      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);

      await tester.ensureVisible(find.byIcon(Icons.pause));
      await tester.pump();
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
      controller.scanTreeFullPathForTest(
        tester.element(find.byType(MaterialApp)),
      );
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
      await tester.ensureVisible(find.text('See all 4 \u2192'));
      await tester.pump();
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

  // ───────────────────────────────────────────────────────────────────
  // v0.15.5: Freeze-above-on-expand
  //
  // The freeze-above algorithm is split across two pure top-level
  // functions in `floating_issues_card.dart`:
  //
  //   * `computeVisibleIssues` — folds downstream issues under their
  //     root and re-surfaces orphans. Used by both the render path
  //     and the prune path so they agree on "visible".
  //   * `applyFreezeZone` — composes the rendered list by drawing
  //     positions 0..max(expandedIndices) from the order snapshot and
  //     appending everything else in current ranker-flow order.
  //
  // These are tested directly as pure functions because pumping the
  // full overlay through `flutter_test` gives the inner `ListView` only
  // ~34 dp of viewport — `Column(mainAxisSize: MainAxisSize.min)` in
  // `_buildCardBody` doesn't propagate bounded height down to the
  // `Flexible > Column > Expanded(ListView)` chain in widget tests, so
  // at most one `IssueCard` would build lazily and positional
  // assertions over several cards would be unreliable. The algorithm is
  // fully covered here; widget-level integration (pin icon, summary bar
  // unchanged on expand, dispose/didUpdateWidget clear state, new
  // critical below the frozen zone) is covered by the smoke tests in
  // the sibling group below plus `issue_card_test.dart`.
  // ───────────────────────────────────────────────────────────────────
  group('v0.15.5 computeVisibleIssues', () {
    test('empty input returns empty list', () {
      expect(computeVisibleIssues(const []), isEmpty);
    });

    test('pass-through when no issue has rootCauseId', () {
      final issues = [
        _pinIssue(id: 'A'),
        _pinIssue(id: 'B'),
        _pinIssue(id: 'C'),
      ];
      final visible = computeVisibleIssues(issues);
      expect(visible.map((i) => i.stableId).toList(), ['A', 'B', 'C']);
    });

    test('downstream issues nested under present root are hidden', () {
      final issues = [
        _pinIssue(id: 'A'),
        _pinIssue(id: 'B', rootCauseIds: ['A']),
        _pinIssue(id: 'C'),
      ];
      final visible = computeVisibleIssues(issues);
      expect(visible.map((i) => i.stableId).toList(), ['A', 'C']);
    });

    test(
      'downstream issues whose root is missing re-surface as standalone',
      () {
        final issues = [
          _pinIssue(id: 'orphan', rootCauseIds: ['missing-root']),
          _pinIssue(id: 'A'),
        ];
        final visible = computeVisibleIssues(issues);
        expect(
          visible.map((i) => i.stableId).toList(),
          ['orphan', 'A'],
          reason:
              'Orphan with unknown rootCauseId must re-surface — otherwise '
              'ranker-suppressed parents would silently drop their children.',
        );
      },
    );

    test('result preserves input order for visible issues', () {
      final issues = [
        _pinIssue(id: 'A'),
        _pinIssue(id: 'child', rootCauseIds: ['A']),
        _pinIssue(id: 'B'),
        _pinIssue(id: 'C'),
      ];
      final visible = computeVisibleIssues(issues);
      expect(visible.map((i) => i.stableId).toList(), ['A', 'B', 'C']);
    });

    // Single-parent collapse requires parent severity ≥ child severity so
    // a critical effect is never hidden under a warning parent.
    test('single parent: critical child of a warning parent stays visible', () {
      final issues = [
        _pinIssue(id: 'parent', severity: IssueSeverity.warning),
        _pinIssue(
          id: 'child',
          severity: IssueSeverity.critical,
          rootCauseIds: ['parent'],
        ),
      ];
      final visible = computeVisibleIssues(issues);
      expect(visible.map((i) => i.stableId).toList(), ['parent', 'child']);
    });

    test('single parent: warning child of a warning parent is hidden', () {
      final issues = [
        _pinIssue(id: 'parent', severity: IssueSeverity.warning),
        _pinIssue(
          id: 'child',
          severity: IssueSeverity.warning,
          rootCauseIds: ['parent'],
        ),
      ];
      final visible = computeVisibleIssues(issues);
      expect(visible.map((i) => i.stableId).toList(), ['parent']);
    });

    test('single parent: warning child of a critical parent is hidden', () {
      final issues = [
        _pinIssue(id: 'parent', severity: IssueSeverity.critical),
        _pinIssue(
          id: 'child',
          severity: IssueSeverity.warning,
          rootCauseIds: ['parent'],
        ),
      ];
      final visible = computeVisibleIssues(issues);
      expect(visible.map((i) => i.stableId).toList(), ['parent']);
    });

    test('a parent id shared by two issues: the instance listing the '
        'child decides', () {
      PerformanceIssue parent(IssueSeverity severity, {bool owns = false}) =>
          _pinIssue(
            id: 'parent',
            severity: severity,
          ).copyWith(downstreamIds: owns ? const ['child'] : null);
      final child = _pinIssue(
        id: 'child',
        severity: IssueSeverity.critical,
        rootCauseIds: ['parent'],
      );

      // The critical instance does not list the child; the warning one
      // that does is less severe, so the child stays visible.
      var visible = computeVisibleIssues([
        parent(IssueSeverity.critical),
        parent(IssueSeverity.warning, owns: true),
        child,
      ]);
      expect(visible, contains(child));

      // The critical instance lists it: collapsed under that card.
      visible = computeVisibleIssues([
        parent(IssueSeverity.critical, owns: true),
        parent(IssueSeverity.warning),
        child,
      ]);
      expect(visible, isNot(contains(child)));
    });

    test('two parents: child visible for every parent/child severity mix', () {
      for (final childSeverity in IssueSeverity.values) {
        for (final aSeverity in IssueSeverity.values) {
          for (final bSeverity in IssueSeverity.values) {
            final issues = [
              _pinIssue(id: 'A', severity: aSeverity),
              _pinIssue(id: 'B', severity: bSeverity),
              _pinIssue(
                id: 'child',
                severity: childSeverity,
                rootCauseIds: ['A', 'B'],
              ),
            ];
            expect(
              computeVisibleIssues(issues).map((i) => i.stableId),
              contains('child'),
              reason: 'child=$childSeverity A=$aSeverity B=$bSeverity',
            );
          }
        }
      }
    });

    // v0.25.0 multi-parent visibility: ≥2 parents ALWAYS surfaces
    // standalone with the "Caused by" badge, regardless of how many of
    // those parents are individually visible. The bidirectional surface
    // is the user's primary discoverability path for multi-cause
    // relationships. Single-parent legacy collapse-under-parent
    // behaviour is preserved.
    test('multi-parent: surfaces standalone even when all parents visible', () {
      final issues = [
        _pinIssue(id: 'A'),
        _pinIssue(id: 'B'),
        _pinIssue(id: 'child', rootCauseIds: ['A', 'B']),
      ];
      final visible = computeVisibleIssues(issues);
      expect(visible.map((i) => i.stableId).toList(), ['A', 'B', 'child']);
    });

    test('multi-parent: surfaces standalone with mixed parent visibility', () {
      final issues = [
        _pinIssue(id: 'A'),
        _pinIssue(id: 'child', rootCauseIds: ['A', 'missing-B', 'missing-C']),
      ];
      final visible = computeVisibleIssues(issues);
      expect(visible.map((i) => i.stableId).toList(), ['A', 'child']);
    });

    test('multi-parent: surfaces when every parent is suppressed', () {
      final issues = [
        _pinIssue(id: 'orphan', rootCauseIds: ['missing-A', 'missing-B']),
        _pinIssue(id: 'C'),
      ];
      final visible = computeVisibleIssues(issues);
      expect(
        visible.map((i) => i.stableId).toList(),
        ['orphan', 'C'],
        reason:
            'A multi-parent downstream re-surfaces only when no parent is in the visible set — preserves orphan-resurface semantics from v0.15.5',
      );
    });
  });

  group('v0.15.5 applyFreezeZone', () {
    List<String> ids0(List<PerformanceIssue> issues) =>
        issues.map((i) => i.stableId ?? i.title).toList();

    final abc = [_pinIssue(id: 'A'), _pinIssue(id: 'B'), _pinIssue(id: 'C')];

    test(
      'empty expandedIndices + null snapshot returns visibleIssues as-is',
      () {
        expect(
          ids0(
            applyFreezeZone(
              visibleIssues: abc,
              orderSnapshot: null,
              expandedIndices: const {},
            ),
          ),
          ['A', 'B', 'C'],
        );
      },
    );

    test(
      'expanding index 2 freezes 0..2; new critical below lands at index 3',
      () {
        // User's exact reported scenario: they expand the card at index 2
        // while reading. Snapshot = visible at that instant. A new critical
        // 'D' now arrives from the ranker at the top of its output. With
        // freeze-above, D must land BELOW the frozen zone so the card the
        // user is reading doesn't shift under their eyes.
        final snapshot = List<PerformanceIssue>.of(abc);
        final rankerFlow = [
          _pinIssue(id: 'D', severity: IssueSeverity.critical),
          _pinIssue(id: 'A'),
          _pinIssue(id: 'B'),
          _pinIssue(id: 'C'),
        ];
        final result = applyFreezeZone(
          visibleIssues: rankerFlow,
          orderSnapshot: snapshot,
          expandedIndices: const {'C': 2},
        );
        expect(ids0(result), ['A', 'B', 'C', 'D']);
      },
    );

    test('multi-expand uses MAX rule for freezeEnd', () {
      // Cards at indices 1 and 4 both expanded. freezeEnd = max(1, 4) = 4.
      // Snapshot [A..E] freezes entirely, nothing below to flow.
      final snapshot = [
        _pinIssue(id: 'A'),
        _pinIssue(id: 'B'),
        _pinIssue(id: 'C'),
        _pinIssue(id: 'D'),
        _pinIssue(id: 'E'),
      ];
      final rankerFlow = [
        _pinIssue(id: 'E'),
        _pinIssue(id: 'A'),
        _pinIssue(id: 'B'),
        _pinIssue(id: 'C'),
        _pinIssue(id: 'D'),
      ];
      final result = applyFreezeZone(
        visibleIssues: rankerFlow,
        orderSnapshot: snapshot,
        expandedIndices: const {'B': 1, 'E': 4},
      );
      expect(ids0(result), ['A', 'B', 'C', 'D', 'E']);
    });

    test('frozen-zone entry disappeared from visible is dropped silently', () {
      // Snapshot said [A, B, C] with B expanded at index 1. On the next
      // frame B is gone (downstream absorbed, detector evicted, etc.).
      // B must drop silently; A and C stay frozen; `_pruneStaleState`
      // would remove the expand entry on its next sweep but the render
      // must not throw in the interim.
      final snapshot = List<PerformanceIssue>.of(abc);
      final rankerFlow = [_pinIssue(id: 'A'), _pinIssue(id: 'C')];
      final result = applyFreezeZone(
        visibleIssues: rankerFlow,
        orderSnapshot: snapshot,
        expandedIndices: const {'B': 1},
      );
      expect(ids0(result), ['A', 'C']);
    });

    test('freezeEnd clamped when snapshot shorter than captured index '
        '(downstream collapse shrank snapshot)', () {
      // Pathological: caller-level state drift puts capturedIndex past
      // the snapshot length. Must not throw; clamp and carry on.
      final snapshot = [_pinIssue(id: 'A')];
      final rankerFlow = [_pinIssue(id: 'A'), _pinIssue(id: 'X')];
      final result = applyFreezeZone(
        visibleIssues: rankerFlow,
        orderSnapshot: snapshot,
        expandedIndices: const {'A': 5},
      );
      expect(ids0(result), ['A', 'X']);
    });

    test('freezeEnd clamped when visibleIssues shorter than snapshot', () {
      // Same shape but the live visible list shrank this frame.
      final snapshot = List<PerformanceIssue>.of(abc);
      final rankerFlow = [_pinIssue(id: 'A')];
      final result = applyFreezeZone(
        visibleIssues: rankerFlow,
        orderSnapshot: snapshot,
        expandedIndices: const {'C': 2},
      );
      // C disappeared; with the surviving identity 'A' the result is
      // just [A]. No throw, no corruption.
      expect(ids0(result), ['A']);
    });

    test('flow section preserves ranker order for non-frozen items', () {
      // Freeze zone [A, B]. Ranker output below has [D, C] in that
      // order. Flow section must preserve that order.
      final snapshot = [_pinIssue(id: 'A'), _pinIssue(id: 'B')];
      final rankerFlow = [
        _pinIssue(id: 'A'),
        _pinIssue(id: 'B'),
        _pinIssue(id: 'D'),
        _pinIssue(id: 'C'),
      ];
      final result = applyFreezeZone(
        visibleIssues: rankerFlow,
        orderSnapshot: snapshot,
        expandedIndices: const {'B': 1},
      );
      expect(ids0(result), ['A', 'B', 'D', 'C']);
    });

    test('freezeEnd = 0 (top card expanded) freezes only position 0', () {
      // Boundary: expanding the very first card freezes a single-slot
      // zone. Ranker churn below index 0 still reorders freely.
      final snapshot = List<PerformanceIssue>.of(abc);
      final rankerFlow = [
        _pinIssue(id: 'B'),
        _pinIssue(id: 'A'),
        _pinIssue(id: 'C'),
      ];
      final result = applyFreezeZone(
        visibleIssues: rankerFlow,
        orderSnapshot: snapshot,
        expandedIndices: const {'A': 0},
      );
      expect(ids0(result), ['A', 'B', 'C']);
    });

    test('freezeEnd = length - 1 freezes entire snapshot; flow is empty', () {
      // Boundary: expanding the last card locks the full list to the
      // snapshot order. No items remain to flow below.
      final snapshot = List<PerformanceIssue>.of(abc);
      final rankerFlow = [
        _pinIssue(id: 'C'),
        _pinIssue(id: 'A'),
        _pinIssue(id: 'B'),
      ];
      final result = applyFreezeZone(
        visibleIssues: rankerFlow,
        orderSnapshot: snapshot,
        expandedIndices: const {'C': 2},
      );
      expect(ids0(result), ['A', 'B', 'C']);
    });

    test('assert fires when orderSnapshot is non-null but map is empty', () {
      expect(
        () => applyFreezeZone(
          visibleIssues: abc,
          orderSnapshot: List<PerformanceIssue>.of(abc),
          expandedIndices: const {},
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('assert fires when orderSnapshot is null but map is non-empty', () {
      expect(
        () => applyFreezeZone(
          visibleIssues: abc,
          orderSnapshot: null,
          expandedIndices: const {'A': 0},
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // v0.15.5: Freeze-above-on-expand widget smoke tests
  //
  // End-to-end wiring — pump the overlay, toggle expansion, confirm the
  // state flows through to the `IssueCard` the user actually sees and
  // that the state (`_expandedIndices` + `_orderSnapshot`) lifecycle
  // matches the class invariant: both populated together on the 0→1
  // expand transition, both cleared together on the 1→0 collapse
  // transition, and both cleared together on dispose /
  // controller-swap.
  //
  // Only interacts with the first visible card where positional
  // assertions are needed because the flutter_test layout only builds
  // that one (see explanatory comment above).
  // ───────────────────────────────────────────────────────────────────
  group('v0.15.5 freeze-above-on-expand widget smoke', () {
    // The summary chips are 48 dp tall; give the card's list room for a
    // tappable row.
    void useTallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Widget pumpFreezeCard(SleuthController c) {
      return MaterialApp(
        home: Scaffold(
          body: FloatingIssuesCard(controller: c, onClose: () {}),
        ),
      );
    }

    testWidgets('expanding a card shows the pin icon; collapse hides it', (
      tester,
    ) async {
      useTallView(tester);
      controller.issuesNotifier.value = [_pinIssue(id: 'A')];
      await tester.pumpWidget(pumpFreezeCard(controller));
      await tester.pumpAndSettle();

      // Collapsed: no pin icon.
      expect(find.byIcon(Icons.push_pin), findsNothing);

      // Tap the card title to expand → pin icon appears (state hint).
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

      // Tap again to collapse → pin icon disappears.
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(find.byIcon(Icons.push_pin), findsNothing);
    });

    testWidgets('summary bar issue count does not change when a card expands', (
      tester,
    ) async {
      useTallView(tester);
      // M5: summary bar reads the pre-freeze visible list. Whether the
      // user has a card expanded or not, counts must not move.
      controller.issuesNotifier.value = [
        _pinIssue(id: 'A', severity: IssueSeverity.critical),
        _pinIssue(id: 'B', severity: IssueSeverity.warning),
      ];
      await tester.pumpWidget(pumpFreezeCard(controller));
      await tester.pumpAndSettle();

      final confirmedBefore = find
          .textContaining('confirmed')
          .evaluate()
          .length;

      await tester.tap(find.text('A'));
      await tester.pump();

      final confirmedAfter = find.textContaining('confirmed').evaluate().length;
      expect(confirmedAfter, confirmedBefore);
    });

    testWidgets(
      'dispose clears expandedIndices AND orderSnapshot — remount with '
      'same controller starts fresh',
      (tester) async {
        useTallView(tester);
        controller.issuesNotifier.value = [_pinIssue(id: 'A')];
        await tester.pumpWidget(pumpFreezeCard(controller));
        await tester.pumpAndSettle();

        await tester.tap(find.text('A'));
        await tester.pump();
        expect(find.byIcon(Icons.push_pin), findsOneWidget);

        // Unmount the card — triggers dispose on `_FloatingIssuesCardState`.
        // If dispose only cleared one field, the class invariant
        // `(orderSnapshot == null) == expandedIndices.isEmpty` would be
        // violated on the next remount's first `applyFreezeZone` call and
        // the assert there would throw. We assert no throw by virtue of
        // the remount succeeding and rendering normally.
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();

        // Remount a fresh card pointing at the same controller. A ghost
        // expand from the previous state would have made the icon appear
        // on first render; because dispose clears both fields together,
        // the new state starts empty and no pin icon shows.
        await tester.pumpWidget(pumpFreezeCard(controller));
        await tester.pump();
        expect(find.byIcon(Icons.push_pin), findsNothing);
      },
    );

    testWidgets('didUpdateWidget controller swap clears expandedIndices AND '
        'orderSnapshot', (tester) async {
      useTallView(tester);
      // Build with controller A, expand its card so state is populated.
      controller.issuesNotifier.value = [_pinIssue(id: 'A')];
      await tester.pumpWidget(pumpFreezeCard(controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

      // Swap to a fresh controller with a differently-identified issue.
      // Without the dual-clear in `didUpdateWidget`, the stale
      // `_expandedIndices` map keyed on A's stableId combined with a
      // non-null `_orderSnapshot` referencing A would violate the class
      // invariant on the next render and re-emit a ghost pin icon.
      final controllerB = SleuthController()..initializeDetectorsForTest();
      addTearDown(controllerB.dispose);
      controllerB.issuesNotifier.value = [_pinIssue(id: 'Z')];
      await tester.pumpWidget(pumpFreezeCard(controllerB));
      await tester.pump();

      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(find.text('Z'), findsOneWidget);
    });

    testWidgets('collapsing the last expanded card clears orderSnapshot so the '
        'list flows freely again', (tester) async {
      useTallView(tester);
      // The 1→0 collapse transition must release `_orderSnapshot` —
      // otherwise subsequent ranker churn would be silently compared
      // against a stale snapshot. Verified indirectly: after collapse,
      // mutating the issues list surfaces new ordering without a
      // lingering frozen prefix.
      controller.issuesNotifier.value = [_pinIssue(id: 'A')];
      await tester.pumpWidget(pumpFreezeCard(controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

      await tester.tap(find.text('A'));
      await tester.pump();
      expect(find.byIcon(Icons.push_pin), findsNothing);

      // Ranker now emits a different top issue. If the snapshot had
      // survived the collapse, a non-null `_orderSnapshot` with empty
      // `_expandedIndices` would have thrown the invariant assert in
      // `applyFreezeZone` on this render. The pump succeeding proves
      // the dual-clear ran.
      controller.issuesNotifier.value = [_pinIssue(id: 'NEW')];
      await tester.pump();
      expect(find.text('NEW'), findsOneWidget);
    });
  });
  group('Live panels follow the scan pulse', () {
    Widget host(SleuthController c) => MaterialApp(
      home: Scaffold(
        body: FloatingIssuesCard(
          controller: c,
          onClose: () {},
          isDebugMode: false,
        ),
      ),
    );

    testWidgets('rebuild banner updates on ticks that leave issues unchanged', (
      tester,
    ) async {
      controller.dispose();
      controller = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      final fake = _FakeCoordinator();
      controller.debugCoordinatorForTest = fake;
      var notifications = 0;
      controller.issuesNotifier.addListener(() => notifications++);

      await tester.pumpWidget(host(controller));
      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);
      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'ProductCard': 3},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      controller.scanTreeFullPathForTest(root);
      await tester.pump();
      expect(find.text('Rebuilds: 3 across 1 widget'), findsOneWidget);
      final notificationsBefore = notifications;

      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'ProductCard': 4},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      controller.scanTreeFullPathForTest(root);
      await tester.pump();

      expect(notifications, notificationsBefore);
      expect(find.text('Rebuilds: 7 across 1 widget'), findsOneWidget);
    });

    testWidgets(
      'recurrence badge updates on ticks that leave issues unchanged',
      (tester) async {
        controller.dispose();
        controller = SleuthController(
          config: SleuthConfig(
            enabledDetectors: const {DetectorType.frameTiming},
            customDetectors: [_SteadyDetector()],
          ),
        );
        controller.initializeDetectorsForTest();
        var notifications = 0;
        controller.issuesNotifier.addListener(() => notifications++);

        await tester.pumpWidget(host(controller));
        final root = tester.element(find.byType(MaterialApp));
        controller.scanTreeFullPathForTest(root);
        controller.scanTreeFullPathForTest(root);
        await tester.pump();
        expect(find.textContaining('Seen 2/2'), findsOneWidget);

        controller.scanTreeFullPathForTest(root);
        await tester.pump();
        expect(find.textContaining('Seen 3/3'), findsOneWidget);
        expect(notifications, 1);
      },
    );
  });

  group('Header theme toggle', () {
    SleuthThemeData theme(WidgetTester tester) =>
        tester.widget<SleuthTheme>(find.byType(SleuthTheme)).data;

    testWidgets('cycles System, Light, Dark with a toast and persists', (
      tester,
    ) async {
      final store = InMemorySleuthStateStore();
      final controller = await pumpOverlay(
        tester,
        config: SleuthConfig(stateStore: store),
        platformBrightness: Brightness.dark,
      );
      await tester.pump();
      await openDashboard(tester, controller);
      controller.updateTheme(const SleuthThemeData.highContrastLight());
      await tester.pump();

      final toggle = find.bySemanticsLabel('Toggle theme');
      expect(tester.getSemantics(toggle).value, 'System');

      await tester.tap(toggle);
      await tester.pump();
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.light);
      // The override stays; Light takes precedence over it.
      expect(
        controller.themeOverride.value,
        same(const SleuthThemeData.highContrastLight()),
      );
      expect(identical(theme(tester), const SleuthThemeData.light()), isTrue);
      expect(find.text('Theme: Light'), findsOneWidget);
      expect(tester.getSemantics(toggle).value, 'Light');

      await tester.tap(toggle);
      await tester.pump();
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.dark);
      expect(identical(theme(tester), const SleuthThemeData()), isTrue);
      expect(find.text('Theme: Dark'), findsOneWidget);

      await tester.tap(toggle);
      await tester.pump();
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.system);
      expect(find.text('Theme: System'), findsOneWidget);
      // System shows the app's override again.
      expect(
        identical(theme(tester), const SleuthThemeData.highContrastLight()),
        isTrue,
      );

      await tester.tap(toggle);
      await tester.pump(const Duration(seconds: 3));
      final saved = jsonDecode(store.json!) as Map<String, Object?>;
      expect(saved['themeMode'], 'light');
    });
  });

  group('Header theme toggle precedence', () {
    SleuthThemeData theme(WidgetTester tester) =>
        tester.widget<SleuthTheme>(find.byType(SleuthTheme)).data;

    testWidgets('Light then System brings the override back', (tester) async {
      const override = SleuthThemeData.highContrastDark();
      final controller = await pumpOverlay(
        tester,
        platformBrightness: Brightness.light,
      );
      await openDashboard(tester, controller);
      controller.updateTheme(override);
      await tester.pump();
      expect(identical(theme(tester), override), isTrue);

      final toggle = find.bySemanticsLabel('Toggle theme');
      await tester.tap(toggle);
      await tester.pump();
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.light);
      expect(identical(theme(tester), const SleuthThemeData.light()), isTrue);

      // Light -> Dark -> System.
      await tester.tap(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.system);
      expect(identical(theme(tester), override), isTrue);
    });

    testWidgets('updateTheme while Dark switches the toggle to System', (
      tester,
    ) async {
      const override = SleuthThemeData.highContrastLight();
      final controller = await pumpOverlay(
        tester,
        platformBrightness: Brightness.dark,
        themeMode: SleuthThemeMode.dark,
      );
      await openDashboard(tester, controller);
      expect(identical(theme(tester), const SleuthThemeData()), isTrue);

      controller.updateTheme(override);
      await tester.pump();
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.system);
      expect(identical(theme(tester), override), isTrue);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Toggle theme')).value,
        'System',
      );
      // The icon follows the mode, not the theme's brightness.
      expect(find.byIcon(Icons.brightness_auto), findsOneWidget);

      // Clearing the override leaves the mode alone.
      controller.updateTheme(null);
      await tester.pump();
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.system);
      expect(identical(theme(tester), const SleuthThemeData()), isTrue);
    });

    testWidgets('the toggle icon follows the mode', (tester) async {
      final controller = await pumpOverlay(
        tester,
        platformBrightness: Brightness.dark,
        themeMode: SleuthThemeMode.light,
      );
      await openDashboard(tester, controller);
      expect(find.byIcon(Icons.light_mode), findsOneWidget);
      controller.overlayUiState.themeMode = SleuthThemeMode.dark;
      await tester.pump();
      expect(find.byIcon(Icons.dark_mode), findsOneWidget);
    });
  });

  group('Escape key', () {
    testWidgets('closes the open page, then the card', (tester) async {
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      await tester.tap(find.bySemanticsLabel('Guide'));
      await tester.pumpAndSettle();
      expect(find.text('Sleuth Guide'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Sleuth Guide'), findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.overlayUiState.dashboardOpen, isFalse);

      // Card gone: its handler is removed and Escape does nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.overlayUiState.dashboardOpen, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a focused app text field keeps Escape', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final controller = await pumpOverlay(
        tester,
        app: MaterialApp(
          home: Scaffold(body: TextField(focusNode: focus)),
        ),
      );
      await openDashboard(tester, controller);
      focus.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.overlayUiState.dashboardOpen, isTrue);
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('an open app dialog takes Escape', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = await pumpOverlay(
        tester,
        app: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('app')),
        ),
      );
      await openDashboard(tester, controller);
      unawaited(
        showDialog<void>(
          context: navigatorKey.currentContext!,
          builder: (_) => const AlertDialog(content: Text('host dialog')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('host dialog'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('host dialog'), findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);
    });

    testWidgets('a plain app page route leaves Escape to Sleuth', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = await pumpOverlay(
        tester,
        app: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('app')),
        ),
      );
      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('second page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openDashboard(tester, controller);
      await tester.tap(find.bySemanticsLabel('Guide'));
      await tester.pumpAndSettle();
      expect(find.text('Sleuth Guide'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Sleuth Guide'), findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);
      expect(find.text('second page'), findsOneWidget);
    });
  });

  group('Header custom actions', () {
    testWidgets('move the card in 48 px steps and to the corner', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final controller = await pumpOverlay(tester);
      controller.overlayUiState.setCardGeometry(
        offset: const Offset(200, 200),
        width: 300,
        height: null,
        windowState: CardWindowState.normal,
      );
      await openDashboard(tester, controller);
      final header = find.bySemanticsLabel('Sleuth');

      await performCustomAction(tester, header, 'Move down');
      expect(controller.overlayUiState.cardOffset, const Offset(200, 248));
      await performCustomAction(tester, header, 'Move left');
      expect(controller.overlayUiState.cardOffset, const Offset(152, 248));
      await performCustomAction(tester, header, 'Move up');
      await performCustomAction(tester, header, 'Move right');
      expect(controller.overlayUiState.cardOffset, const Offset(200, 200));
      await performCustomAction(tester, header, 'Move to top left');
      expect(controller.overlayUiState.cardOffset, Offset.zero);
      handle.dispose();
    });
  });

  group('holdIssueOrder', () {
    List<PerformanceIssue> issues(List<String> ids) => [
      for (final id in ids) _pinIssue(id: id),
    ];

    test('null held keys adopt the ranker order', () {
      final r = holdIssueOrder(
        visibleIssues: issues(['B', 'A']),
        heldKeys: null,
      );
      expect(r.keys, ['B', 'A']);
      expect(r.pending, isFalse);
      expect(r.added, isEmpty);
    });

    test('held keys keep their order; the difference is pending', () {
      final r = holdIssueOrder(
        visibleIssues: issues(['C', 'B', 'A']),
        heldKeys: ['A', 'B', 'C'],
      );
      expect(r.keys, ['A', 'B', 'C']);
      expect(r.issues.map((i) => i.stableId), ['A', 'B', 'C']);
      expect(r.pending, isTrue);
    });

    test('new keys go to the top in ranker order; missing keys drop', () {
      final r = holdIssueOrder(
        visibleIssues: issues(['A', 'N1', 'C', 'N2']),
        heldKeys: ['A', 'B', 'C'],
      );
      expect(r.keys, ['N1', 'N2', 'A', 'C']);
      expect(r.added, {'N1', 'N2'});
      expect(r.pending, isTrue);
    });

    test('a severity promotion moves above the first card ranked below it', () {
      final r = holdIssueOrder(
        visibleIssues: [
          _pinIssue(id: 'A'),
          _pinIssue(id: 'D', severity: IssueSeverity.critical),
          _pinIssue(id: 'B'),
          _pinIssue(id: 'C'),
        ],
        heldKeys: ['C', 'B', 'A', 'D'],
        heldSeverities: const {
          'A': IssueSeverity.warning,
          'B': IssueSeverity.warning,
          'C': IssueSeverity.warning,
          'D': IssueSeverity.warning,
        },
      );
      // Same-tier moves stay held (C, B, A); D moves above C, the first
      // held card the ranker places below it.
      expect(r.keys, ['D', 'C', 'B', 'A']);
    });

    test('a promoted card stops below held cards ranked above it', () {
      final r = holdIssueOrder(
        visibleIssues: [
          _pinIssue(id: 'A', severity: IssueSeverity.critical),
          _pinIssue(id: 'D', severity: IssueSeverity.critical),
          _pinIssue(id: 'B'),
          _pinIssue(id: 'C'),
        ],
        heldKeys: ['A', 'B', 'C', 'D'],
        heldSeverities: const {
          'A': IssueSeverity.critical,
          'B': IssueSeverity.warning,
          'C': IssueSeverity.warning,
          'D': IssueSeverity.warning,
        },
      );
      expect(r.keys, ['A', 'D', 'B', 'C']);
      expect(r.pending, isFalse);
    });

    test('a demotion is held like any other rank change', () {
      final r = holdIssueOrder(
        visibleIssues: [
          _pinIssue(id: 'B'),
          _pinIssue(id: 'A', severity: IssueSeverity.ok),
        ],
        heldKeys: ['A', 'B'],
        heldSeverities: const {
          'A': IssueSeverity.critical,
          'B': IssueSeverity.warning,
        },
      );
      expect(r.keys, ['A', 'B']);
      expect(r.pending, isTrue);
    });

    test('issues sharing a key stay together without duplicates', () {
      final r = holdIssueOrder(
        visibleIssues: [
          _pinIssue(id: 'A'),
          _pinIssue(id: 'B'),
          _pinIssue(id: 'A'),
        ],
        heldKeys: ['B', 'A'],
      );
      expect(r.keys, ['B', 'A']);
      expect(r.issues.map((i) => i.stableId), ['B', 'A', 'A']);
    });

    test('null held keys group issues sharing a key', () {
      final r = holdIssueOrder(
        visibleIssues: [
          _pinIssue(id: 'A'),
          _pinIssue(id: 'B'),
          _pinIssue(id: 'A'),
        ],
        heldKeys: null,
      );
      expect(r.keys, ['A', 'B']);
      expect(r.issues.map((i) => i.stableId), ['A', 'A', 'B']);
    });

    test('a promotion never moves a card down', () {
      final r = holdIssueOrder(
        visibleIssues: [
          _pinIssue(id: 'A', severity: IssueSeverity.critical),
          _pinIssue(id: 'D', severity: IssueSeverity.critical),
          _pinIssue(id: 'B'),
          _pinIssue(id: 'C'),
        ],
        heldKeys: ['D', 'A', 'B', 'C'],
        heldSeverities: const {
          'A': IssueSeverity.critical,
          'B': IssueSeverity.warning,
          'C': IssueSeverity.warning,
          'D': IssueSeverity.warning,
        },
      );
      expect(r.keys, ['D', 'A', 'B', 'C']);
      expect(r.pending, isTrue);
    });

    test('promote: false holds a promotion like any rank change', () {
      final r = holdIssueOrder(
        visibleIssues: [
          _pinIssue(id: 'B', severity: IssueSeverity.critical),
          _pinIssue(id: 'A'),
        ],
        heldKeys: ['A', 'B'],
        heldSeverities: const {
          'A': IssueSeverity.warning,
          'B': IssueSeverity.warning,
        },
        promote: false,
      );
      expect(r.keys, ['A', 'B']);
      expect(r.pending, isTrue);
    });

    test('the same order is not pending', () {
      final r = holdIssueOrder(
        visibleIssues: issues(['A', 'B']),
        heldKeys: ['A', 'B'],
      );
      expect(r.pending, isFalse);
    });
  });
}
