import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart' show Sleuth, StartupMetrics;
import 'package:sleuth/src/ui/focus_ink_well.dart';
import 'package:sleuth/src/ui/more_menu.dart';
import 'package:sleuth/src/ui/startup_metrics_page.dart';
import 'package:sleuth/src/ui/hidden_issues_page.dart';
import 'package:sleuth/src/ui/issue_encyclopedia_page.dart';
import 'package:sleuth/src/ui/guide_page.dart';
import 'package:sleuth/src/ui/issue_card.dart';
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
/// the `_FakeCoordinator` pattern in `rebuild_stats_scan_test.dart`:
/// returns a pre-configured snapshot from `snapshot()` so the real
/// `_scanTreeInner` drain → merge block runs against synthetic
/// `flutterTimeline`-source data without needing profile-mode compilation.
class _FakeCoordinator extends DebugInstrumentationCoordinator {
  _FakeCoordinator({this.profileMode = false})
    : super(installRebuild: false, installPaint: false);

  /// Stands in for an installed profile-mode timeline drain.
  final bool profileMode;

  @override
  bool get isProfileModeInstalled => profileMode;

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

  group('Minimize/maximize/restore', () {
    testWidgets('minimize hides body, shows only header', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Body content should be present initially
      expect(find.textContaining('No issues detected'), findsOneWidget);

      // Tap minimize
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();

      // Body content should be gone
      expect(find.textContaining('No issues detected'), findsNothing);
      // The header stays: its paw and run label.
      expect(find.byIcon(Icons.pets), findsOneWidget);
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

  group('Debug-mode banner', () {
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

    testWidgets('a dismissal lasts for the controller\'s session', (
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

      // Closing and reopening the dashboard keeps it dismissed: the
      // controller holds the dismissal for the session.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpWidget(pumpCard(isDebugMode: true));
      expect(find.textContaining(bannerText), findsNothing);

      // A new session shows it again.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpWidget(
        pumpCard(isDebugMode: true, config: const SleuthConfig()),
      );
      expect(find.textContaining(bannerText), findsOneWidget);
    });
  });

  group('More menu', () {
    // Scans need a Scaffold above the card for `_findVisiblePageContext`.
    Widget pumpMenuCard(SleuthController c, {VoidCallback? onAppTap}) {
      final card = FloatingIssuesCard(
        controller: c,
        onClose: () {},
        isDebugMode: false,
      );
      return MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onAppTap,
                ),
              ),
              card,
            ],
          ),
        ),
      );
    }

    SleuthController scanningController() {
      controller.dispose();
      final c = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          enabledDetectors: {DetectorType.frameTiming},
        ),
      )..initializeDetectorsForTest();
      controller = c;
      return c;
    }

    /// The first scan creates the active route session; the second merges
    /// [counts] into it.
    Future<void> mergeCounts(
      WidgetTester tester,
      SleuthController c,
      _FakeCoordinator fake,
      Map<String, int> counts,
    ) async {
      c.scanTreeFullPathForTest(tester.element(find.byType(MaterialApp)));
      fake.nextSnapshot = DebugSnapshot(
        rebuildCounts: counts,
        totalPaintCount: 0,
        elapsed: const Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      c.scanTreeFullPathForTest(tester.element(find.byType(MaterialApp)));
      await tester.pump();
    }

    testWidgets('empty rows read as such and are disabled', (tester) async {
      await tester.pumpWidget(pumpMenuCard(controller));
      await openMoreMenu(tester);

      expect(
        find.bySemanticsLabel('Startup, Not measured yet'),
        findsOneWidget,
      );
      // A debug run counts rebuilds for the detectors only.
      expect(find.bySemanticsLabel('Rebuild stats, Off'), findsOneWidget);
      // No hidden issues: no row.
      expect(moreMenuRow('Hidden issues'), findsNothing);
      await tester.tap(moreMenuRow('Startup'));
      await tester.pump();
      expect(find.byType(StartupMetricsPage), findsNothing);
      expect(find.byType(SleuthMoreMenu), findsOneWidget);
    });

    testWidgets('Rebuild stats waits for counts in a run that counts them', (
      tester,
    ) async {
      final c = scanningController();
      c.debugCoordinatorForTest = _FakeCoordinator(profileMode: true);
      await tester.pumpWidget(pumpMenuCard(c));
      await openMoreMenu(tester);

      expect(
        find.bySemanticsLabel('Rebuild stats, No counts yet'),
        findsOneWidget,
      );
    });

    testWidgets('Rebuild stats shows the total read at open and opens its '
        'page on that snapshot', (tester) async {
      final c = scanningController();
      final fake = _FakeCoordinator();
      c.debugCoordinatorForTest = fake;
      await tester.pumpWidget(pumpMenuCard(c));
      await mergeCounts(tester, c, fake, {
        'ProductCard': 2000,
        'PriceTag': 389,
      });

      await openMoreMenu(tester);
      expect(find.bySemanticsLabel('Rebuild stats, 2,389'), findsOneWidget);

      // A scan while the menu is open leaves its value alone.
      fake.nextSnapshot = const DebugSnapshot(
        rebuildCounts: {'ProductCard': 11},
        totalPaintCount: 0,
        elapsed: Duration(milliseconds: 500),
        source: RebuildCountSource.flutterTimeline,
      );
      c.scanTreeFullPathForTest(tester.element(find.byType(MaterialApp)));
      await tester.pump();
      expect(find.bySemanticsLabel('Rebuild stats, 2,389'), findsOneWidget);

      await tester.tap(moreMenuRow('Rebuild stats'));
      await tester.pump();
      expect(find.byType(SleuthMoreMenu), findsNothing);
      expect(find.byType(RebuildStatsPage), findsOneWidget);
    });

    testWidgets('Startup shows TTFF and opens Startup metrics', (tester) async {
      addTearDown(Sleuth.resetStartupForTest);
      Sleuth.setStartupMetricsForTest(
        StartupMetrics(dartEntryTimestamp: DateTime(2026), ttffMs: 200.4),
      );
      await tester.pumpWidget(pumpMenuCard(controller));
      await openMoreMenu(tester);
      // Shown as "TTFF 200 ms", read out in words.
      expect(find.text('TTFF 200 ms'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Startup, time to first frame 200 milliseconds'),
        findsOneWidget,
      );
      await tester.tap(moreMenuRow('Startup'));
      await tester.pump();
      expect(find.byType(StartupMetricsPage), findsOneWidget);
    });

    testWidgets('Hidden issues appears with a count and opens the list', (
      tester,
    ) async {
      controller.overlayUiState
        ..hide('a')
        ..hide('b');
      await tester.pumpWidget(pumpMenuCard(controller));
      await openMoreMenu(tester);
      expect(find.bySemanticsLabel('Hidden issues, 2'), findsOneWidget);
      await tester.ensureVisible(moreMenuRow('Hidden issues'));
      await tester.tap(moreMenuRow('Hidden issues'));
      await tester.pump();
      expect(find.byType(HiddenIssuesPage), findsOneWidget);
    });

    for (final (row, page) in [
      ('Encyclopedia', IssueEncyclopediaPage),
      ('Guide', GuidePage),
    ]) {
      testWidgets('$row closes the menu and opens its page; closing the '
          'page returns focus to More', (tester) async {
        await tester.pumpWidget(pumpMenuCard(controller));
        await openFromMoreMenu(tester, row);
        expect(find.byType(SleuthMoreMenu), findsNothing);
        expect(find.byType(page), findsOneWidget);

        final state = tester.state<State<FloatingIssuesCard>>(
          find.byType(FloatingIssuesCard),
        );
        expect((state as OverlayLayerHost).closeInnermostLayer(), isTrue);
        await tester.pump();
        await tester.pump();
        expect(find.byType(page), findsNothing);
        final more = Focus.of(tester.element(find.byIcon(Icons.more_horiz)));
        expect(more.hasPrimaryFocus, isTrue);
      });
    }

    testWidgets('Copy snapshot closes the menu and copies', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(pumpMenuCard(controller));
      await openFromMoreMenu(tester, 'Copy snapshot');
      expect(find.byType(SleuthMoreMenu), findsNothing);
      expect(copied, contains('"currentIssues"'));
      expect(find.text('Snapshot copied to clipboard'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a theme segment applies in place with no toast', (
      tester,
    ) async {
      await tester.pumpWidget(pumpMenuCard(controller));
      await openMoreMenu(tester);
      await tester.ensureVisible(find.bySemanticsLabel('Auto theme'));
      await tester.pump();
      expect(
        tester.getSemantics(find.bySemanticsLabel('Auto theme')),
        matchesSemantics(
          label: 'Auto theme',
          isButton: true,
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          isChecked: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.bySemanticsLabel('Dark theme'));
      await tester.pump();
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.dark);
      // The menu stays open and no toast reports the change.
      expect(find.byType(SleuthMoreMenu), findsOneWidget);
      expect(find.textContaining('Theme:'), findsNothing);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Dark theme')),
        matchesSemantics(
          label: 'Dark theme',
          isButton: true,
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          isChecked: true,
          hasTapAction: true,
        ),
      );
    });

    testWidgets('the scrim takes the tap that closes the menu', (tester) async {
      var appTaps = 0;
      controller.issuesNotifier.value = [_pinIssue(id: 'under_scrim')];
      await tester.pumpWidget(
        pumpMenuCard(
          controller,
          onAppTap: () {
            appTaps++;
          },
        ),
      );
      await openMoreMenu(tester);
      // On the card beside the panel: the tap closes the menu, nothing
      // else.
      final card = tester.getRect(find.byType(IssueCard));
      final panel = tester.getRect(find.byType(SleuthMoreMenu));
      expect(card.right, greaterThan(panel.right + 10));
      await tester.tapAt(Offset(panel.right + 5, card.center.dy));
      await tester.pump();
      expect(find.byType(SleuthMoreMenu), findsNothing);
      // The card did not expand: its detail is not shown.
      expect(find.text('Detail'), findsNothing);
      expect(appTaps, 0);
    });

    testWidgets('a tap on the app closes the menu and reaches the app', (
      tester,
    ) async {
      var appTaps = 0;
      await tester.pumpWidget(
        pumpMenuCard(
          controller,
          onAppTap: () {
            appTaps++;
          },
        ),
      );
      await openMoreMenu(tester);
      await tester.tapAt(const Offset(5, 590));
      await tester.pump();
      expect(find.byType(SleuthMoreMenu), findsNothing);
      expect(appTaps, 1);
    });

    testWidgets('minimize and a header drag close the menu', (tester) async {
      await tester.pumpWidget(pumpMenuCard(controller));
      await openMoreMenu(tester);
      await tester.drag(find.byIcon(Icons.pets), const Offset(-30, 40));
      await tester.pump();
      expect(find.byType(SleuthMoreMenu), findsNothing);

      await openMoreMenu(tester);
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();
      expect(find.byType(SleuthMoreMenu), findsNothing);
    });

    testWidgets('keyboard focus moves into the menu and back to More', (
      tester,
    ) async {
      await tester.pumpWidget(pumpMenuCard(controller));
      await openMoreMenu(tester);
      final panelScope = FocusScope.of(tester.element(moreMenuRow('Guide')));
      expect(panelScope.hasFocus, isTrue);

      // Escape closes the menu before the card.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(SleuthMoreMenu), findsNothing);
      expect(find.byType(FloatingIssuesCard), findsOneWidget);
      expect(
        Focus.of(tester.element(find.byIcon(Icons.more_horiz))).hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('opening focuses the first enabled row, and Enter opens it', (
      tester,
    ) async {
      await tester.pumpWidget(pumpMenuCard(controller));
      await openMoreMenu(tester);
      // Startup and Rebuild stats have nothing to show and are disabled.
      expect(
        Focus.of(tester.element(moreMenuRow('Encyclopedia'))).hasPrimaryFocus,
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(IssueEncyclopediaPage), findsOneWidget);
      expect(find.byType(SleuthMoreMenu), findsNothing);
    });

    testWidgets('the focused row is outlined only while the keyboard drives '
        'focus', (tester) async {
      Iterable<SleuthFocusOutline> shown() => tester
          .widgetList<SleuthFocusOutline>(find.byType(SleuthFocusOutline))
          .where((o) => o.show);
      await tester.pumpWidget(pumpMenuCard(controller));
      await openMoreMenu(tester);
      // Opened by touch: focus moved, no outline.
      expect(shown(), isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(shown(), hasLength(1));
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(
        focused.findAncestorWidgetOfExactType<SleuthMoreMenu>(),
        isNotNull,
      );
      expect(shown().single.color, const SleuthThemeData().checkboxActive);
    });

    testWidgets('the theme bar fills and bolds the current choice in one '
        'outlined bar', (tester) async {
      await tester.pumpWidget(pumpMenuCard(controller));
      await openMoreMenu(tester);
      await tester.ensureVisible(moreMenuRow('Theme'));
      await tester.pump();
      final theme = SleuthTheme.of(tester.element(moreMenuRow('Theme')));
      BoxDecoration cellOf(Finder face) =>
          tester
                  .widget<DecoratedBox>(
                    find
                        .ancestor(of: face, matching: find.byType(DecoratedBox))
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      // No icon before the label, outline icons whatever the choice.
      expect(
        find.descendant(
          of: find.byType(SleuthMoreMenu),
          matching: find.byIcon(Icons.contrast),
        ),
        findsNothing,
      );
      final auto = tester.widget<Text>(find.text('Auto'));
      expect(auto.style!.fontWeight, FontWeight.w600);
      expect(
        cellOf(find.text('Auto')).color,
        theme.checkboxActive.withValues(alpha: 0.24),
      );
      expect(cellOf(find.text('Auto')).border, isNull);

      await tester.tap(find.bySemanticsLabel('Dark theme'));
      await tester.pump();
      final dark = find.byIcon(Icons.dark_mode_outlined);
      expect(dark, findsOneWidget);
      expect(find.byIcon(Icons.dark_mode), findsNothing);
      expect(tester.widget<Icon>(dark).color, theme.textPrimary);
      expect(cellOf(dark).color, theme.checkboxActive.withValues(alpha: 0.24));
      expect(cellOf(find.text('Auto')).color, isNull);
      expect(
        tester.widget<Text>(find.text('Auto')).style!.fontWeight,
        FontWeight.normal,
      );
      // Each choice stays a 48 px target.
      expect(
        tester.getSize(find.bySemanticsLabel('Dark theme')),
        const Size(48, 48),
      );
    });

    testWidgets('on iOS the selected theme segment reads as selected', (
      tester,
    ) async {
      await tester.pumpWidget(pumpMenuCard(controller));
      await openMoreMenu(tester);
      // `flagsCollection` is not available on the 3.32 floor.
      bool selected(String label) => tester
          .getSemantics(find.bySemanticsLabel(label))
          // ignore: deprecated_member_use
          .hasFlag(SemanticsFlag.isSelected);
      expect(selected('Auto theme'), isTrue);
      expect(selected('Dark theme'), isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('the panel fits the card and the More button reads its '
        'state', (tester) async {
      await tester.pumpWidget(pumpMenuCard(controller));
      expect(
        tester.getSemantics(find.bySemanticsLabel('More')),
        matchesSemantics(
          label: 'More',
          isButton: true,
          hasExpandedState: true,
          hasTapAction: true,
        ),
      );
      await openMoreMenu(tester);
      expect(
        tester.getSemantics(find.bySemanticsLabel('More').first),
        matchesSemantics(
          label: 'More',
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
        ),
      );
      final card = tester.getRect(find.byType(Material).first);
      final panel = tester.getRect(find.byType(SleuthMoreMenu));
      expect(panel.width, lessThanOrEqualTo(236));
      expect(panel.left, greaterThanOrEqualTo(card.left));
      expect(panel.right, lessThanOrEqualTo(card.right));
      expect(panel.bottom, lessThanOrEqualTo(card.bottom));
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
  //   * `applyFreezeZone` — composes the rendered list from the frozen
  //     zone (the cards down to the lowest expanded one, matched to their
  //     reports) and everything else in current ranker-flow order.
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

    /// The zone captured from [rows] with the cards at [expanded]
    /// expanded.
    List<FrozenCard> zone(List<PerformanceIssue> rows, Set<int> expanded) {
      final keys = occurrenceKeysFor(rows);
      return [
        for (var i = 0; i < rows.length; i++)
          (
            key: keys[i],
            issue: rows[i],
            expanded: expanded.contains(i),
            reported: true,
          ),
      ];
    }

    List<String> order(
      List<PerformanceIssue> visible,
      List<FrozenCard>? frozen,
    ) => ids0(applyFreezeZone(visibleIssues: visible, frozen: frozen).issues);

    final abc = [_pinIssue(id: 'A'), _pinIssue(id: 'B'), _pinIssue(id: 'C')];

    test('no zone returns visibleIssues as-is', () {
      final result = applyFreezeZone(visibleIssues: abc, frozen: null);
      expect(ids0(result.issues), ['A', 'B', 'C']);
      expect(result.keys, occurrenceKeysFor(abc));
      expect(result.frozen, isNull);
    });

    test(
      'expanding index 2 freezes 0..2; new critical below lands at index 3',
      () {
        // User's exact reported scenario: they expand the card at index 2
        // while reading. A new critical 'D' now arrives from the ranker at
        // the top of its output. With freeze-above, D must land BELOW the
        // frozen zone so the card the user is reading doesn't shift under
        // their eyes.
        final rankerFlow = [
          _pinIssue(id: 'D', severity: IssueSeverity.critical),
          _pinIssue(id: 'A'),
          _pinIssue(id: 'B'),
          _pinIssue(id: 'C'),
        ];
        expect(order(rankerFlow, zone(abc, {2})), ['A', 'B', 'C', 'D']);
      },
    );

    test('with several cards expanded the zone ends at the lowest', () {
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
      expect(order(rankerFlow, zone(snapshot, {1, 4})), [
        'A',
        'B',
        'C',
        'D',
        'E',
      ]);
    });

    test('an expanded entry that disappeared from visible keeps its place', () {
      // B is gone on the next update (downstream absorbed, detector
      // evicted, etc.). The user is reading B, so it stays where it was,
      // marked as no longer reported.
      final rankerFlow = [_pinIssue(id: 'A'), _pinIssue(id: 'C')];
      final result = applyFreezeZone(
        visibleIssues: rankerFlow,
        frozen: zone(abc, {1}),
      );
      expect(ids0(result.issues), ['A', 'B', 'C']);
      expect([for (final c in result.frozen!) c.reported], [true, false]);
    });

    test('a collapsed frozen entry that disappeared is dropped', () {
      // A is above the expanded B and leaves; only expanded cards stay.
      final rankerFlow = [_pinIssue(id: 'B'), _pinIssue(id: 'C')];
      expect(order(rankerFlow, zone(abc, {1})), ['B', 'C']);
    });

    test('collapsed cards below the lowest expanded one flow', () {
      final rankerFlow = [
        _pinIssue(id: 'C'),
        _pinIssue(id: 'B'),
        _pinIssue(id: 'A'),
      ];
      final result = applyFreezeZone(
        visibleIssues: rankerFlow,
        frozen: zone(abc, {0}),
      );
      expect(ids0(result.issues), ['A', 'C', 'B']);
      expect(result.frozen, hasLength(1));
    });

    test('an expanded card stays when the visible list shrinks', () {
      final rankerFlow = [_pinIssue(id: 'A')];
      // B disappeared and is dropped; C disappeared but is expanded, so
      // it stays.
      expect(order(rankerFlow, zone(abc, {2})), ['A', 'C']);
    });

    test('flow section preserves ranker order for non-frozen items', () {
      final rankerFlow = [
        _pinIssue(id: 'A'),
        _pinIssue(id: 'B'),
        _pinIssue(id: 'D'),
        _pinIssue(id: 'C'),
      ];
      expect(
        order(rankerFlow, zone([_pinIssue(id: 'A'), _pinIssue(id: 'B')], {1})),
        ['A', 'B', 'D', 'C'],
      );
    });

    test('expanding the top card freezes only position 0', () {
      final rankerFlow = [
        _pinIssue(id: 'B'),
        _pinIssue(id: 'A'),
        _pinIssue(id: 'C'),
      ];
      expect(order(rankerFlow, zone(abc, {0})), ['A', 'B', 'C']);
    });

    test('expanding the last card freezes the whole list', () {
      final rankerFlow = [
        _pinIssue(id: 'C'),
        _pinIssue(id: 'A'),
        _pinIssue(id: 'B'),
      ];
      expect(order(rankerFlow, zone(abc, {2})), ['A', 'B', 'C']);
    });

    test('a zone with no expanded card is released', () {
      final result = applyFreezeZone(
        visibleIssues: abc.reversed.toList(),
        frozen: zone(abc, {}),
      );
      expect(ids0(result.issues), ['C', 'B', 'A']);
      expect(result.frozen, isNull);
    });

    test('a matched card shows its latest report', () {
      final newer = _pinIssue(id: 'B', severity: IssueSeverity.critical);
      final result = applyFreezeZone(
        visibleIssues: [
          _pinIssue(id: 'A'),
          newer,
          _pinIssue(id: 'C'),
        ],
        frozen: zone(abc, {1}),
      );
      expect(identical(result.issues[1], newer), isTrue);
      expect(identical(result.frozen![1].issue, newer), isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // v0.15.5: Freeze-above-on-expand widget smoke tests
  //
  // End-to-end wiring — pump the overlay, toggle expansion, confirm the
  // state flows through to the `IssueCard` the user actually sees and
  // that the frozen zone is captured on the 0→1 expand transition and
  // released on the 1→0 collapse transition, on dispose and on a
  // controller swap.
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
      expect(expandedIssueCards(), findsNothing);

      // Tap the card title to expand → pin icon appears (state hint).
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(expandedIssueCards(), findsOneWidget);

      // Tap again to collapse → pin icon disappears.
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(expandedIssueCards(), findsNothing);
    });

    testWidgets('summary bar issue count does not change when a card expands', (
      tester,
    ) async {
      useTallView(tester);
      // The summary bar reads the pre-freeze visible list. Whether the
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

    testWidgets('dispose clears the frozen zone — remount with same controller '
        'starts fresh', (tester) async {
      useTallView(tester);
      controller.issuesNotifier.value = [_pinIssue(id: 'A')];
      await tester.pumpWidget(pumpFreezeCard(controller));
      await tester.pumpAndSettle();

      await tester.tap(find.text('A'));
      await tester.pump();
      expect(expandedIssueCards(), findsOneWidget);

      // Unmount the card — triggers dispose on `_FloatingIssuesCardState`.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      // Remount a fresh card pointing at the same controller. A ghost
      // expand from the previous state would have made the icon appear
      // on first render; the new state starts empty and no pin icon
      // shows.
      await tester.pumpWidget(pumpFreezeCard(controller));
      await tester.pump();
      expect(expandedIssueCards(), findsNothing);
    });

    testWidgets('didUpdateWidget controller swap clears the frozen zone', (
      tester,
    ) async {
      useTallView(tester);
      // Build with controller A, expand its card so state is populated.
      controller.issuesNotifier.value = [_pinIssue(id: 'A')];
      await tester.pumpWidget(pumpFreezeCard(controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(expandedIssueCards(), findsOneWidget);

      // Swap to a fresh controller with a differently-identified issue.
      // Without the clear in `didUpdateWidget`, the old zone would keep
      // A expanded on the next render and show a ghost pin icon.
      final controllerB = SleuthController()..initializeDetectorsForTest();
      addTearDown(controllerB.dispose);
      controllerB.issuesNotifier.value = [_pinIssue(id: 'Z')];
      await tester.pumpWidget(pumpFreezeCard(controllerB));
      await tester.pump();

      expect(expandedIssueCards(), findsNothing);
      expect(find.text('Z'), findsOneWidget);
    });

    testWidgets('collapsing the last expanded card releases the zone so the '
        'list flows freely again', (tester) async {
      useTallView(tester);
      // The 1→0 collapse transition must release the zone. Verified
      // indirectly: after collapse, mutating the issues list surfaces new
      // ordering without a lingering frozen prefix.
      controller.issuesNotifier.value = [_pinIssue(id: 'A')];
      await tester.pumpWidget(pumpFreezeCard(controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(expandedIssueCards(), findsOneWidget);

      await tester.tap(find.text('A'));
      await tester.pump();
      expect(expandedIssueCards(), findsNothing);

      // Ranker now emits a different top issue.
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
        expect(find.textContaining('seen 2 of 2 scans'), findsOneWidget);

        controller.scanTreeFullPathForTest(root);
        await tester.pump();
        expect(find.textContaining('seen 3 of 3 scans'), findsOneWidget);
        expect(notifications, 1);
      },
    );
  });

  group('Theme in the More menu', () {
    SleuthThemeData theme(WidgetTester tester) =>
        tester.widget<SleuthTheme>(find.byType(SleuthTheme)).data;

    /// Taps the [name] segment, opening the menu first when it is closed.
    Future<void> pickTheme(WidgetTester tester, String name) async {
      if (find.byType(SleuthMoreMenu).evaluate().isEmpty) {
        await openMoreMenu(tester);
      }
      final segment = find.bySemanticsLabel('$name theme');
      await tester.ensureVisible(segment);
      await tester.pump();
      await tester.tap(segment);
      await tester.pump();
    }

    bool isOn(WidgetTester tester, String name) => tester
        .getSemantics(find.bySemanticsLabel('$name theme'))
        // `flagsCollection` is not available on the 3.32 floor.
        // ignore: deprecated_member_use
        .hasFlag(SemanticsFlag.isChecked);

    testWidgets('sets Light, Dark and Auto in place and persists', (
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

      await openMoreMenu(tester);
      expect(isOn(tester, 'Auto'), isTrue);

      await pickTheme(tester, 'Light');
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.light);
      // The override stays; Light takes precedence over it.
      expect(
        controller.themeOverride.value,
        same(const SleuthThemeData.highContrastLight()),
      );
      expect(identical(theme(tester), const SleuthThemeData.light()), isTrue);
      expect(isOn(tester, 'Light'), isTrue);
      expect(find.textContaining('Theme:'), findsNothing);

      await pickTheme(tester, 'Dark');
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.dark);
      expect(identical(theme(tester), const SleuthThemeData()), isTrue);

      await pickTheme(tester, 'Auto');
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.system);
      // Auto shows the app's override again.
      expect(
        identical(theme(tester), const SleuthThemeData.highContrastLight()),
        isTrue,
      );

      await pickTheme(tester, 'Light');
      await tester.pump(const Duration(seconds: 3));
      final saved = jsonDecode(store.json!) as Map<String, Object?>;
      expect(saved['themeMode'], 'light');
    });

    testWidgets('Light then Auto brings the override back', (tester) async {
      const override = SleuthThemeData.highContrastDark();
      final controller = await pumpOverlay(
        tester,
        platformBrightness: Brightness.light,
      );
      await openDashboard(tester, controller);
      controller.updateTheme(override);
      await tester.pump();
      expect(identical(theme(tester), override), isTrue);

      await pickTheme(tester, 'Light');
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.light);
      expect(identical(theme(tester), const SleuthThemeData.light()), isTrue);

      await pickTheme(tester, 'Auto');
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.system);
      expect(identical(theme(tester), override), isTrue);
    });

    testWidgets('updateTheme while Dark switches the menu to Auto', (
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
      await openMoreMenu(tester);
      await tester.ensureVisible(find.bySemanticsLabel('Auto theme'));
      await tester.pump();
      expect(isOn(tester, 'Auto'), isTrue);

      // Clearing the override leaves the mode alone.
      controller.updateTheme(null);
      await tester.pump();
      expect(controller.overlayUiState.themeMode, SleuthThemeMode.system);
      expect(identical(theme(tester), const SleuthThemeData()), isTrue);
    });

    testWidgets('the segment that is on follows the mode', (tester) async {
      final controller = await pumpOverlay(
        tester,
        platformBrightness: Brightness.dark,
        themeMode: SleuthThemeMode.light,
      );
      await openDashboard(tester, controller);
      await openMoreMenu(tester);
      await tester.ensureVisible(find.bySemanticsLabel('Light theme'));
      await tester.pump();
      expect(isOn(tester, 'Light'), isTrue);
      controller.overlayUiState.themeMode = SleuthThemeMode.dark;
      await tester.pump();
      expect(isOn(tester, 'Dark'), isTrue);
      expect(isOn(tester, 'Light'), isFalse);
    });
  });

  group('Escape key', () {
    testWidgets('closes the open page, then the card', (tester) async {
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      await openFromMoreMenu(tester, 'Guide');
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
      await openFromMoreMenu(tester, 'Guide');
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
