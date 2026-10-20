import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/highlight_bar.dart';
import 'package:sleuth/src/ui/highlight_overlay.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';

import '../helpers/overlay_harness.dart';

const _lay = PerformanceIssue(
  severity: IssueSeverity.warning,
  category: IssueCategory.layout,
  confidence: IssueConfidence.likely,
  title: 'Title lay',
  detail: 'D',
  fixHint: 'F',
  stableId: 'lay',
  widgetName: 'Lay',
);

PerformanceIssue _other(String id) => PerformanceIssue(
  severity: IssueSeverity.warning,
  category: IssueCategory.build,
  confidence: IssueConfidence.likely,
  title: 'Title $id',
  detail: 'D',
  fixHint: 'F',
  stableId: id,
);

WidgetHighlight _layAt(Rect rect) => WidgetHighlight(
  rect: rect,
  widgetName: 'Lay',
  severity: IssueSeverity.warning,
  detectorName: 'LayoutDetector',
);

/// A scan has run and outlined Lay at [rect].
void _seedHighlight(SleuthController controller, Rect rect, {int gen = 1}) {
  controller.scanTickNotifier.value = 1;
  controller.highlightsNotifier.value = (
    generation: gen,
    items: [_layAt(rect)],
  );
}

/// Node ids of the focus semantics events sent to the platform.
List<int> _recordScreenReaderFocus(WidgetTester tester) {
  final ids = <int>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockDecodedMessageHandler<Object?>(
    SystemChannels.accessibility,
    (message) async {
      if (message case {'type': 'focus', 'nodeId': final int id}) ids.add(id);
      return null;
    },
  );
  addTearDown(
    () => messenger.setMockDecodedMessageHandler<Object?>(
      SystemChannels.accessibility,
      null,
    ),
  );
  return ids;
}

const _top = Rect.fromLTWH(0, 40, 200, 100);
const _bottom = Rect.fromLTWH(0, 600, 200, 100);

Finder get _bar => find.byType(SleuthHighlightBar);

Finder get _back => find.bySemanticsLabel('Back to issues');

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<SleuthController> _openWith(
  WidgetTester tester,
  List<PerformanceIssue> issues, {
  Widget? app,
}) async {
  _phone(tester);
  final controller = await pumpOverlay(
    tester,
    app: app,
    config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
  );
  controller.issuesNotifier.value = issues;
  await openDashboard(tester, controller);
  return controller;
}

Future<void> _tapCrosshair(
  WidgetTester tester, [
  String title = 'Title lay',
]) async {
  await tester.ensureVisible(crosshair(title));
  await tester.pump();
  await tester.tap(crosshair(title));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('Highlight bar', () {
    testWidgets('a found widget turns the card into the bar; Back to issues '
        'returns it with focus on the crosshair', (tester) async {
      final controller = await _openWith(tester, [_lay]);
      _seedHighlight(controller, _top);
      final focused = _recordScreenReaderFocus(tester);

      await _tapCrosshair(tester);
      expect(_bar, findsOneWidget);
      expect(find.text('Showing Lay'), findsOneWidget);
      expect(find.text('Title lay'), findsNothing);
      expect(focused.last, tester.getSemantics(_back).id);

      await tester.tap(_back);
      await tester.pump();
      await tester.pump();
      expect(_bar, findsNothing);
      expect(find.text('Title lay'), findsOneWidget);
      expect(controller.selectedHighlightNotifier.value, isNull);
      expect(
        focused.last,
        tester.getSemantics(find.bySemanticsLabel('Show Lay on screen')).id,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the bar sits at the edge away from the widget, and reads off '
        'screen until a scan finds it again', (tester) async {
      final controller = await _openWith(tester, [_lay]);
      _seedHighlight(controller, _bottom);
      await _tapCrosshair(tester);
      expect(tester.getRect(_bar).top, 8);

      // Scrolled away: the bar keeps its edge.
      controller.selectedHighlightNotifier.value = _layAt(
        const Rect.fromLTWH(0, -300, 200, 100),
      );
      await tester.pump();
      expect(find.text('Lay is off screen'), findsOneWidget);
      expect(tester.getRect(_bar).top, 8);

      // Detached: the outline goes.
      controller.selectedHighlightNotifier.value = null;
      await tester.pump();
      expect(find.text('Lay is off screen'), findsOneWidget);

      // Back on screen in the top half: outlined again, bar at the bottom.
      _seedHighlight(controller, _top, gen: 2);
      await tester.pump();
      expect(find.text('Showing Lay'), findsOneWidget);
      expect(tester.getRect(_bar).bottom, 800 - 8);
    });

    testWidgets('a toast stays above the bar at the bottom', (tester) async {
      final controller = await _openWith(tester, [_lay]);
      _seedHighlight(controller, _top);
      await _tapCrosshair(tester);
      controller.vmConnectedNotifier.value = true;
      await tester.pump();
      controller.vmConnectedNotifier.value = false;
      await tester.pump();
      final toast = find.textContaining('VM link lost');
      expect(toast, findsOneWidget);
      expect(tester.getRect(toast).bottom, lessThan(tester.getRect(_bar).top));
      await tester.pump(const Duration(seconds: 15));
    }, semanticsEnabled: false);

    testWidgets('leaving restores a maximized card and its list offset, '
        'returns the markers toggle and writes no overlay state', (
      tester,
    ) async {
      // Lay in the middle, so a scroll that moved it to the top would
      // show in the offset.
      final controller = await _openWith(tester, [
        for (var i = 0; i < 12; i++) _other('o$i'),
        _lay,
        for (var i = 12; i < 24; i++) _other('o$i'),
      ]);
      await tester.tap(find.bySemanticsLabel('Maximize'));
      await tester.pump();
      expect(find.bySemanticsLabel('Restore'), findsOneWidget);
      _seedHighlight(controller, _top);
      final list = find.descendant(
        of: find.descendant(
          of: find.byType(FloatingIssuesCard),
          matching: find.byType(ListView),
        ),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        crosshair('Title lay'),
        200,
        scrollable: list.first,
      );
      // Away from both edges of the viewport.
      await tester.ensureVisible(crosshair('Title lay'));
      await tester.pumpAndSettle();
      await tester.drag(list.first, const Offset(0, 150));
      await tester.pumpAndSettle();
      final offset = tester.state<ScrollableState>(list.first).position.pixels;
      expect(offset, greaterThan(0));
      final saved = controller.overlayUiState.toJson();
      var writes = 0;
      void count() => writes++;
      controller.overlayUiState.addListener(count);
      addTearDown(() => controller.overlayUiState.removeListener(count));
      expect(controller.highlightEnabledNotifier.value, isFalse);

      // In view already, so tapped where it is.
      await tester.tap(crosshair('Title lay'));
      await tester.pump();
      await tester.pump();
      expect(_bar, findsOneWidget);
      expect(controller.highlightEnabledNotifier.value, isTrue);

      await tester.tap(_back);
      await tester.pump();
      await tester.pump();
      // Past the crosshair's focus scroll, which must not move a list
      // that already shows it.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.bySemanticsLabel('Restore'), findsOneWidget);
      expect(tester.state<ScrollableState>(list.first).position.pixels, offset);
      expect(controller.highlightEnabledNotifier.value, isFalse);
      expect(writes, 0);
      expect(controller.overlayUiState.toJson(), saved);
    });

    testWidgets('markers that were on stay on', (tester) async {
      final controller = await _openWith(tester, [_lay]);
      controller.highlightEnabledNotifier.value = true;
      _seedHighlight(controller, _top);
      await _tapCrosshair(tester);
      await tester.tap(_back);
      await tester.pump();
      expect(controller.highlightEnabledNotifier.value, isTrue);
    });

    testWidgets('a widget not on screen leaves the card with a toast and '
        'the markers as they were', (tester) async {
      final controller = await _openWith(tester, [_lay]);
      controller.scanTickNotifier.value = 1;
      await _tapCrosshair(tester);
      expect(_bar, findsNothing);
      expect(
        find.text(
          "Couldn't find Lay on screen. It may be scrolled away or not "
          'built yet.',
        ),
        findsOneWidget,
      );
      expect(find.text('Title lay'), findsOneWidget);
      expect(controller.highlightEnabledNotifier.value, isFalse);
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('back and Escape close the bar before the dashboard', (
      tester,
    ) async {
      final controller = await _openWith(tester, [_lay]);
      _seedHighlight(controller, _top);
      await _tapCrosshair(tester);

      expect(await systemBack(tester), isTrue);
      expect(_bar, findsNothing);
      expect(find.text('Title lay'), findsOneWidget);
      expect(controller.overlayUiState.dashboardOpen, isTrue);

      await _tapCrosshair(tester);
      expect(_bar, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_bar, findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);

      expect(await systemBack(tester), isTrue);
      expect(controller.overlayUiState.dashboardOpen, isFalse);
    });

    testWidgets('the bar\'s close ends the highlight with the dashboard', (
      tester,
    ) async {
      final controller = await _openWith(tester, [_lay]);
      _seedHighlight(controller, _top);
      await _tapCrosshair(tester);
      await tester.tap(
        find.descendant(
          of: _bar,
          matching: find.bySemanticsLabel('Close Sleuth'),
        ),
      );
      await tester.pump();
      expect(controller.overlayUiState.dashboardOpen, isFalse);
      expect(controller.selectedHighlightNotifier.value, isNull);
      expect(controller.highlightEnabledNotifier.value, isFalse);
    });

    testWidgets('closing the dashboard another way ends the highlight', (
      tester,
    ) async {
      final controller = await _openWith(tester, [_lay]);
      _seedHighlight(controller, _top);
      await _tapCrosshair(tester);
      controller.overlayUiState.dashboardOpen = false;
      await tester.pump();
      expect(controller.selectedHighlightNotifier.value, isNull);
      expect(controller.highlightEnabledNotifier.value, isFalse);
    });

    testWidgets('the issue going brings the card back', (tester) async {
      final controller = await _openWith(tester, [_lay, _other('a')]);
      _seedHighlight(controller, _top);
      await _tapCrosshair(tester);
      expect(_bar, findsOneWidget);
      // Keyboard focus on Back to issues moves to the header's More.
      Focus.of(tester.element(find.text('Back to issues'))).requestFocus();
      await tester.pump();
      controller.issuesNotifier.value = [_other('a')];
      await tester.pump();
      await tester.pump();
      expect(_bar, findsNothing);
      expect(find.text('Title a'), findsOneWidget);
      expect(controller.highlightEnabledNotifier.value, isFalse);
      expect(
        find.text('The issue on Lay is no longer reported.'),
        findsOneWidget,
      );
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Sleuth More');
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('a second tap of a double tap does not reach the app', (
      tester,
    ) async {
      var appTaps = 0;
      final controller = await _openWith(
        tester,
        [_lay],
        app: MaterialApp(
          home: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => appTaps++,
            child: const SizedBox.expand(),
          ),
        ),
      );
      _seedHighlight(controller, _top);
      final spot = tester.getCenter(crosshair('Title lay'));
      await tester.tapAt(spot);
      await tester.pump();
      expect(_bar, findsOneWidget);
      await tester.tapAt(spot);
      await tester.pump();
      expect(appTaps, 0);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(spot);
      await tester.pump();
      expect(appTaps, 1);
    });

    testWidgets('only the issue\'s own element is outlined again', (
      tester,
    ) async {
      const own = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.layout,
        confidence: IssueConfidence.likely,
        title: 'Title lay',
        detail: 'D',
        fixHint: 'F',
        stableId: 'lay',
        widgetName: 'Lay',
        occurrenceId: 2,
      );
      WidgetHighlight at(Rect rect, int occurrence) => WidgetHighlight(
        rect: rect,
        widgetName: 'Lay',
        severity: IssueSeverity.warning,
        detectorName: 'LayoutDetector',
        occurrenceId: occurrence,
      );
      final controller = await _openWith(tester, [own]);
      controller.scanTickNotifier.value = 1;
      controller.highlightsNotifier.value = (
        generation: 1,
        items: [at(_top, 2)],
      );
      await _tapCrosshair(tester);
      expect(find.text('Showing Lay'), findsOneWidget);

      controller.selectedHighlightNotifier.value = null;
      // A twin of the same name is not outlined in its place.
      controller.highlightsNotifier.value = (
        generation: 2,
        items: [at(_top, 1)],
      );
      await tester.pump();
      expect(find.text('Lay is off screen'), findsOneWidget);
      expect(controller.selectedHighlightNotifier.value, isNull);

      controller.highlightsNotifier.value = (
        generation: 3,
        items: [at(_top, 1), at(_bottom, 2)],
      );
      await tester.pump();
      expect(find.text('Showing Lay'), findsOneWidget);
      expect(controller.selectedHighlightNotifier.value?.occurrenceId, 2);
    });

    testWidgets('a widget behind the keyboard reads off screen', (
      tester,
    ) async {
      _phone(tester);
      // The keyboard is up; the app's own metrics stay as they are.
      final controller = await pumpOverlay(
        tester,
        config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
        host: (overlay) => MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(viewInsets: const EdgeInsets.only(bottom: 400)),
          child: overlay,
        ),
      );
      controller.issuesNotifier.value = [_lay];
      await openDashboard(tester, controller);
      _seedHighlight(controller, const Rect.fromLTWH(0, 500, 200, 100));
      await _tapCrosshair(tester);
      expect(find.text('Lay is off screen'), findsOneWidget);
      // Never seen on screen, the bar sits at the bottom, above the keyboard.
      expect(tester.getRect(_bar).bottom, lessThanOrEqualTo(800 - 400));
    });

    testWidgets('a lookup before the first scan reads Finding, then the scan '
        'opens the bar', (tester) async {
      const appKey = ValueKey('app');
      final app = MaterialApp(
        home: Scaffold(
          key: appKey,
          body: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );
      _phone(tester);
      final controller = await pumpOverlay(
        tester,
        app: app,
        config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
      );
      // The issue the first scan will report, with its element identity.
      final probe = SleuthController()..initializeDetectorsForTest();
      probe.runTreeScanForTest(tester.element(find.byKey(appKey)));
      final reported = probe.latestIssues.firstWhere(
        (i) => i.widgetName == 'SingleChildScrollView',
      );
      probe.dispose();
      controller.issuesNotifier.value = [reported];
      await openDashboard(tester, controller);

      final title = reported.title;
      await _tapCrosshair(tester, title);
      expect(_bar, findsNothing);
      expect(crosshairFinding(tester, crosshair(title)), isTrue);

      controller.runTreeScanForTest(tester.element(find.byKey(appKey)));
      await tester.pump();
      await tester.pump();
      expect(_bar, findsOneWidget);
      expect(find.text('Showing SingleChildScrollView'), findsOneWidget);
    });

    testWidgets('the bar fits a 320 px screen at 2.0x text', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = await pumpOverlay(
        tester,
        textScale: 2.0,
        config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
      );
      controller.issuesNotifier.value = [_lay];
      await openDashboard(tester, controller);
      _seedHighlight(controller, _top);
      expect(tester.takeException(), isNull);
      await _tapCrosshair(tester);
      expect(_bar, findsOneWidget);
      expect(tester.takeException(), isNull);
      final bar = tester.getRect(_bar);
      expect(bar.left, greaterThanOrEqualTo(8));
      expect(bar.right, lessThanOrEqualTo(320 - 8));
    });

    testWidgets('turning the markers off during a lookup ends it', (
      tester,
    ) async {
      final controller = await _openWith(tester, [_lay]);
      await _tapCrosshair(tester);
      expect(crosshairFinding(tester, crosshair('Title lay')), isTrue);
      await tester.tap(find.bySemanticsLabel('Mark flagged widgets'));
      await tester.pump();
      expect(crosshairFinding(tester, crosshair('Title lay')), isFalse);
      expect(controller.pendingIssueSelection, isNull);
      expect(controller.highlightEnabledNotifier.value, isFalse);
    });

    testWidgets('the header markers toggle is named for what it does', (
      tester,
    ) async {
      final controller = await _openWith(tester, [_lay]);
      final toggle = find.bySemanticsLabel('Mark flagged widgets');
      expect(tester.widget<Semantics>(toggle).properties.toggled, isFalse);
      await tester.tap(toggle);
      await tester.pump();
      expect(controller.highlightEnabledNotifier.value, isTrue);
      expect(tester.widget<Semantics>(toggle).properties.toggled, isTrue);
    });
  });

  group('Outline label', () {
    const theme = SleuthThemeData();

    Future<List<Rect>> labelRects(
      WidgetTester tester,
      double scale,
      WidgetHighlight selected, {
      double topInset = 0,
    }) async {
      final highlights =
          ValueNotifier<({int generation, List<WidgetHighlight> items})>((
            generation: 0,
            items: const [],
          ));
      final current = ValueNotifier<WidgetHighlight?>(selected);
      final markers = ValueNotifier<bool>(false);
      addTearDown(highlights.dispose);
      addTearDown(current.dispose);
      addTearDown(markers.dispose);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(400, 800),
            textScaler: TextScaler.linear(scale),
            viewPadding: EdgeInsets.only(top: topInset),
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SleuthTheme(
              data: theme,
              child: HighlightOverlay(
                highlights: highlights,
                selectedHighlight: current,
                markersEnabled: markers,
              ),
            ),
          ),
        ),
      );
      final rects = <Rect>[];
      expect(
        find.descendant(
          of: find.byType(HighlightOverlay),
          matching: find.byType(CustomPaint),
        ),
        paints..everything((method, args) {
          if (method == #drawRRect) {
            final paint = args[1] as Paint;
            if (paint.style == PaintingStyle.fill &&
                // Paint keeps 32-bit floats, so compare the packed value.
                paint.color.toARGB32() == theme.severityWarning.toARGB32()) {
              rects.add((args[0] as RRect).outerRect);
            }
          }
          return true;
        }),
      );
      return rects;
    }

    const short = WidgetHighlight(
      rect: Rect.fromLTWH(40, 200, 120, 80),
      widgetName: 'Lay',
      severity: IssueSeverity.warning,
      detectorName: 'Layout',
    );
    const long = WidgetHighlight(
      rect: Rect.fromLTWH(40, 200, 120, 80),
      widgetName: 'DemoScaffold',
      severity: IssueSeverity.warning,
      detectorName: 'Wide setState Scope',
      detail: 'owns about 88% of the tree below the route and rebuilds it',
    );

    testWidgets('grows with the text up to the chrome limit', (tester) async {
      final at1 = (await labelRects(tester, 1.0, short)).single;
      final at13 = (await labelRects(tester, 1.3, short)).single;
      final at2 = (await labelRects(tester, 2.0, short)).single;
      expect(at13.height, greaterThan(at1.height));
      expect(at2.height, at13.height);
      expect(at2.width, at13.width);
      // The old label was a fixed 18 px tall.
      expect(at13.height, greaterThan(18));
    });

    testWidgets('stays below the status bar', (tester) async {
      final rect = (await labelRects(
        tester,
        1.0,
        const WidgetHighlight(
          rect: Rect.fromLTWH(40, 0, 120, 80),
          widgetName: 'Lay',
          severity: IssueSeverity.warning,
          detectorName: 'Layout',
        ),
        topInset: 47,
      )).single;
      expect(rect.top, greaterThanOrEqualTo(47 + 4));
    });

    testWidgets('wraps a long label to two lines and no more', (tester) async {
      final oneLine = (await labelRects(tester, 1.3, short)).single;
      final at13 = (await labelRects(tester, 1.3, long)).single;
      final at2 = (await labelRects(tester, 2.0, long)).single;
      const pad = 4;
      expect(at13.height - pad, closeTo(2 * (oneLine.height - pad), 0.5));
      expect(at2.height, at13.height);
      expect(at13.right, lessThanOrEqualTo(400 - 4));
    });

    test('its text reads on every severity fill', () {
      for (final t in const [
        SleuthThemeData(),
        SleuthThemeData.light(),
        SleuthThemeData.highContrastDark(),
        SleuthThemeData.highContrastLight(),
      ]) {
        for (final fill in [
          t.severityCritical,
          t.severityWarning,
          t.severityOk,
        ]) {
          expect(
            SleuthThemeData.contrastRatio(SleuthThemeData.onColor(fill), fill),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
    });
  });
}
