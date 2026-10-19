import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';

import '../helpers/overlay_harness.dart';

void main() {
  group('FloatingIssuesCard resize', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    Widget buildCard({Size screenSize = const Size(800, 600)}) {
      return MediaQuery(
        data: MediaQueryData(size: screenSize),
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQueryData(size: screenSize),
            child: child!,
          ),
          home: Scaffold(
            body: FloatingIssuesCard(
              controller: controller,
              onClose: () {},
              isDebugMode: false,
            ),
          ),
        ),
      );
    }

    Finder findResizeHandle() {
      return find.byWidgetPredicate(
        (w) =>
            w is MouseRegion && w.cursor == SystemMouseCursors.resizeDownRight,
      );
    }

    ConstrainedBox findCardConstrainedBox(WidgetTester tester) {
      return tester.widget<ConstrainedBox>(
        find.ancestor(
          of: find.byWidgetPredicate((w) => w is Material && w.elevation == 8),
          matching: find.byType(ConstrainedBox),
        ),
      );
    }

    /// Drags the resize handle by [offset]. Uses startGesture + two moveBy
    /// calls: the first exceeds the pan slop threshold (triggers onPanStart),
    /// the second delivers the actual delta to onPanUpdate.
    Future<void> dragHandle(WidgetTester tester, Offset offset) async {
      final center = tester.getCenter(findResizeHandle());
      final gesture = await tester.startGesture(center);
      // First move: exceed pan slop (36px) to activate the recognizer.
      await gesture.moveBy(const Offset(40, 40));
      await tester.pump();
      // Second move: the actual resize delta.
      await gesture.moveBy(offset);
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    /// Labels of the custom actions on the resize grip.
    Set<String?> resizeActions(WidgetTester tester) => {
      for (final id
          in tester
                  .getSemantics(find.bySemanticsLabel('Resize card'))
                  .getSemanticsData()
                  .customSemanticsActionIds ??
              const <int>[])
        CustomSemanticsAction.getAction(id)!.label,
    };

    testWidgets('resize custom actions step by 48 px', (tester) async {
      final handle = tester.ensureSemantics();
      controller.overlayUiState.setCardGeometry(
        offset: const Offset(100, 100),
        width: 360,
        height: null,
        windowState: CardWindowState.normal,
      );
      await tester.pumpWidget(buildCard());
      final resize = find.bySemanticsLabel('Resize card');
      // 48 x 48 hit box.
      expect(tester.getSize(findResizeHandle()), const Size(48, 48));

      await performCustomAction(tester, resize, 'Wider');
      expect(controller.overlayUiState.cardWidth, 408);
      await performCustomAction(tester, resize, 'Narrower');
      expect(controller.overlayUiState.cardWidth, 360);
      // Narrower stops at the 320 px minimum and is not offered there.
      await performCustomAction(tester, resize, 'Narrower');
      expect(controller.overlayUiState.cardWidth, 320);
      expect(resizeActions(tester), {'Taller', 'Shorter', 'Wider'});
      await performCustomAction(tester, resize, 'Taller');
      expect(controller.overlayUiState.cardHeight, 330 + 48);
      await performCustomAction(tester, resize, 'Shorter');
      expect(controller.overlayUiState.cardHeight, 330);
      // Never below the minimum.
      await performCustomAction(tester, resize, 'Shorter');
      expect(controller.overlayUiState.cardHeight, 300);
      handle.dispose();
    });

    testWidgets('resize handle is present', (tester) async {
      await tester.pumpWidget(buildCard());
      expect(findResizeHandle(), findsOneWidget);
    });

    testWidgets('resize handle has CustomPaint child', (tester) async {
      await tester.pumpWidget(buildCard());

      final customPaint = find.descendant(
        of: findResizeHandle(),
        matching: find.byType(CustomPaint),
      );
      expect(customPaint, findsOneWidget);
    });

    testWidgets('dragging handle right increases card width', (tester) async {
      await tester.pumpWidget(buildCard());

      final initial = findCardConstrainedBox(tester).constraints.maxWidth;
      expect(initial, 320.0); // _defaultCardWidth

      await dragHandle(tester, const Offset(50, 0));

      final updated = findCardConstrainedBox(tester).constraints.maxWidth;
      // Pan slop consumes part of the first move, so we only assert direction.
      expect(updated, greaterThan(initial));
    });

    testWidgets('dragging handle left decreases card width', (tester) async {
      controller.overlayUiState.setCardGeometry(
        offset: const Offset(100, 100),
        width: 420,
        height: null,
        windowState: CardWindowState.normal,
      );
      await tester.pumpWidget(buildCard());

      final initial = findCardConstrainedBox(tester).constraints.maxWidth;
      expect(initial, 420);

      // Slop adds 40 px; the 80 px drag left still shrinks the card.
      await dragHandle(tester, const Offset(-80, 0));
      final shrunk = findCardConstrainedBox(tester).constraints.maxWidth;
      expect(shrunk, lessThan(initial));
    });

    testWidgets('Wider is not offered at the widest card', (tester) async {
      final handle = tester.ensureSemantics();
      controller.overlayUiState.setCardGeometry(
        offset: const Offset(0, 0),
        width: 2000,
        height: 400,
        windowState: CardWindowState.normal,
      );
      await tester.pumpWidget(buildCard());
      expect(resizeActions(tester), {'Taller', 'Shorter', 'Narrower'});
      handle.dispose();
    });

    testWidgets('a stored width below the minimum is raised', (tester) async {
      // An older release allowed 220 px.
      controller.overlayUiState.setCardGeometry(
        offset: const Offset(100, 100),
        width: 220,
        height: null,
        windowState: CardWindowState.normal,
        restoreWidth: 230,
      );
      await tester.pumpWidget(buildCard());
      expect(findCardConstrainedBox(tester).constraints.maxWidth, 320);
      // The value stored is raised on the next commit, not on read.
      expect(controller.overlayUiState.cardWidth, 220);
      await tester.tap(find.byIcon(Icons.crop_square));
      await tester.pump();
      expect(controller.overlayUiState.restoreWidth, 320);
    });

    testWidgets('width clamps at minimum (320 px)', (tester) async {
      await tester.pumpWidget(buildCard());

      // Drag far left — slop adds 40px but then -500px overwhelms it
      await dragHandle(tester, const Offset(-500, 0));

      final box = findCardConstrainedBox(tester);
      expect(box.constraints.maxWidth, 320.0);
    });

    testWidgets('dragging handle down increases card height', (tester) async {
      await tester.pumpWidget(buildCard());

      final initial = findCardConstrainedBox(tester).constraints.maxHeight;
      // Default: 600 * 0.55 = 330 (above 300 min floor)
      expect(initial, 330.0);

      await dragHandle(tester, const Offset(0, 50));

      final updated = findCardConstrainedBox(tester).constraints.maxHeight;
      expect(updated, greaterThan(initial));
    });

    testWidgets('height clamps at minimum (55% of screen)', (tester) async {
      await tester.pumpWidget(buildCard());

      // Drag far up — should not go below default
      await dragHandle(tester, const Offset(0, -500));

      final box = findCardConstrainedBox(tester);
      // Static min height = 300px
      expect(box.constraints.maxHeight, 300.0);
    });

    testWidgets('maximize button expands width', (tester) async {
      await tester.pumpWidget(buildCard());

      // Tap the maximize button (crop_square icon)
      await tester.tap(find.byIcon(Icons.crop_square));
      await tester.pump();

      final box = findCardConstrainedBox(tester);
      // Maximized: screenWidth - 32 = 768
      expect(box.constraints.maxWidth, 768.0);
    });

    testWidgets('restore after maximize returns to default width', (
      tester,
    ) async {
      await tester.pumpWidget(buildCard());

      // Maximize
      await tester.tap(find.byIcon(Icons.crop_square));
      await tester.pump();

      expect(findCardConstrainedBox(tester).constraints.maxWidth, 768.0);

      // Restore (filter_none icon replaces minimize/maximize)
      await tester.tap(find.byIcon(Icons.filter_none));
      await tester.pump();

      expect(findCardConstrainedBox(tester).constraints.maxWidth, 320.0);
    });
  });
  group('Card geometry in the overlay', () {
    /// The overlay on a [size] view with the mixed issue set; [keyboard]
    /// is the bottom view inset and [padding] the safe area.
    Future<SleuthController> pumpView(
      WidgetTester tester,
      Size size, {
      double keyboard = 0,
      FakeViewPadding padding = FakeViewPadding.zero,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      tester.view.padding = padding;
      tester.view.viewPadding = padding;
      addTearDown(tester.view.reset);
      final controller = await pumpOverlay(
        tester,
        config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
      );
      controller.issuesNotifier.value = mixedOverlayIssues();
      return controller;
    }

    Rect cardRect(WidgetTester tester) => tester.getRect(
      find.byWidgetPredicate((w) => w is Material && w.elevation == 8),
    );

    testWidgets('on a 300 px screen the minimum is the width less the '
        'margins, and the card fits', (tester) async {
      final controller = await pumpView(tester, const Size(300, 568));
      controller.overlayUiState.setCardGeometry(
        offset: null,
        width: 200,
        height: null,
        windowState: CardWindowState.normal,
      );
      await openDashboard(tester, controller);
      expect(tester.takeException(), isNull);
      // 200 is raised to 300 - 2 x 16.
      final card = cardRect(tester);
      expect(card.width, 268);
      expect(card.left, greaterThanOrEqualTo(0));
      expect(card.right, lessThanOrEqualTo(300));

      // Below 280 px the header has no window controls; a stored
      // maximized state still fits.
      expect(find.byIcon(Icons.crop_square), findsNothing);
      controller.overlayUiState.setCardGeometry(
        offset: null,
        width: null,
        height: null,
        windowState: CardWindowState.maximized,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(cardRect(tester).width, 268);
      expect(cardRect(tester).left, 16);
    });

    testWidgets('a maximized card refits after the screen rotates', (
      tester,
    ) async {
      final controller = await pumpView(tester, const Size(400, 800));
      await openDashboard(tester, controller);
      await tester.tap(find.byIcon(Icons.crop_square));
      await tester.pump();
      expect(cardRect(tester).width, 400 - 32);

      // Landscape, with the notch on the left and its mirror on the right.
      const notch = FakeViewPadding(left: 44, right: 44);
      tester.view.physicalSize = const Size(800, 400);
      tester.view.padding = notch;
      tester.view.viewPadding = notch;
      await tester.pump();
      expect(tester.takeException(), isNull);

      final card = cardRect(tester);
      expect(card.left, 44 + 16);
      expect(card.width, 800 - 88 - 32);
      expect(card.top, 16);
    });

    testWidgets('a stored maximized state is fitted on the first build', (
      tester,
    ) async {
      final controller = await pumpView(tester, const Size(400, 800));
      // As read from the store: maximized, with a width and offset from
      // another screen.
      controller.overlayUiState.setCardGeometry(
        offset: const Offset(120, 300),
        width: 250,
        height: 400,
        windowState: CardWindowState.maximized,
      );
      await openDashboard(tester, controller);

      final card = cardRect(tester);
      expect(card.left, 16);
      expect(card.top, 16);
      expect(card.width, 400 - 32);
    });

    testWidgets('geometry read after the card opened is adopted, and a drag '
        'moves the card from there', (tester) async {
      final controller = await pumpView(tester, const Size(400, 800));
      await openDashboard(tester, controller);
      final ui = controller.overlayUiState;
      expect(ui.cardOffset, isNull);

      // A store read that finishes after the dashboard opened.
      ui.loadJson({
        'schemaVersion': 1,
        'cardOffset': {'dx': 20.0, 'dy': 100.0},
        'cardWidth': 340.0,
        'cardHeight': 420.0,
        'windowState': 'normal',
      });
      await tester.pump();
      expect(cardRect(tester), const Rect.fromLTWH(20, 100, 340, 420));

      await tester.drag(find.byIcon(Icons.pets), const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(ui.cardWidth, 340);
      expect(ui.cardHeight, 420);
      expect(ui.cardOffset!.dx, 20);
      expect(ui.cardOffset!.dy, inExclusiveRange(100, 250 + 1));
      final card = cardRect(tester);
      expect(card.left, 20);
      expect(card.top, ui.cardOffset!.dy);
      expect(card.width, 340);
    });

    /// Opens the dashboard with a normal card of [height] at [offset].
    Future<SleuthController> pumpCard(
      WidgetTester tester, {
      double keyboard = 0,
      Offset offset = const Offset(40, 0),
      double height = 400,
      CardWindowState windowState = CardWindowState.normal,
    }) async {
      final controller = await pumpView(
        tester,
        const Size(320, 568),
        keyboard: keyboard,
      );
      controller.overlayUiState.setCardGeometry(
        offset: offset,
        width: 260,
        height: height,
        windowState: windowState,
      );
      await openDashboard(tester, controller);
      return controller;
    }

    Finder header() => find.bySemanticsLabel('Sleuth');
    Finder grip() => find.bySemanticsLabel('Resize card');

    /// The grip's dots, drawn in both window states.
    Finder gripDots() => find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_CornerGripPainter',
    );

    /// The card and its resize grip lie inside the view above
    /// [usableBottom].
    void expectCardOnScreen(WidgetTester tester, double usableBottom) {
      final card = cardRect(tester);
      expect(card.top, greaterThanOrEqualTo(0));
      expect(card.bottom, lessThanOrEqualTo(usableBottom));
      for (final finder in [gripDots()]) {
        final rect = tester.getRect(finder);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(usableBottom));
        expect(rect.right, lessThanOrEqualTo(320));
      }
    }

    testWidgets('Move down keeps the grip on screen', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = await pumpCard(tester);
      for (var i = 0; i < 5; i++) {
        await performCustomAction(tester, header(), 'Move down');
      }
      expect(tester.takeException(), isNull);
      expectCardOnScreen(tester, 568);
      // The stored geometry fits too: the 400 px card ends at the bottom.
      final ui = controller.overlayUiState;
      expect(ui.cardHeight, 400);
      expect(ui.cardOffset!.dy, 568 - 400);
      handle.dispose();
    });

    testWidgets('Move down stops above the keyboard', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = await pumpCard(tester, keyboard: 253, height: 300);
      await performCustomAction(tester, header(), 'Move down');
      expectCardOnScreen(tester, 568 - 253);
      expect(controller.overlayUiState.cardOffset!.dy, 568 - 253 - 300);
      handle.dispose();
    });

    testWidgets('Taller stops at the usable bottom', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = await pumpCard(
        tester,
        offset: const Offset(40, 100),
        height: 300,
      );
      for (var i = 0; i < 6; i++) {
        await performCustomAction(tester, grip(), 'Taller');
      }
      expectCardOnScreen(tester, 568);
      // The top edge stays; the height stops at the bottom of the view.
      expect(cardRect(tester).top, 100);
      expect(controller.overlayUiState.cardHeight, 568 - 100);
      handle.dispose();
    });

    testWidgets('Taller with the keyboard up moves the card up to fit', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final controller = await pumpCard(
        tester,
        keyboard: 253,
        offset: const Offset(40, 100),
        height: 300,
      );
      await performCustomAction(tester, grip(), 'Taller');
      // 315 px above the keyboard: the card moves up to fit.
      expectCardOnScreen(tester, 568 - 253);
      expect(controller.overlayUiState.cardHeight, 568 - 253);
      expect(controller.overlayUiState.cardOffset!.dy, 0);
      handle.dispose();
    });

    testWidgets('a drag past the bottom edge ends with the card on screen', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final controller = await pumpCard(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.pets)),
      );
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, 50));
        await tester.pump();
      }
      // While the finger is down the title bar stays on screen.
      expect(cardRect(tester).top, lessThanOrEqualTo(568 - 100));
      await gesture.up();
      await tester.pump();
      expectCardOnScreen(tester, 568);
      expect(controller.overlayUiState.cardOffset!.dy, 568 - 400);
      handle.dispose();
    });

    testWidgets('a maximized card neither moves nor drags', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = await pumpCard(
        tester,
        windowState: CardWindowState.maximized,
      );
      final before = cardRect(tester);
      final stored = controller.overlayUiState.cardOffset;
      final data = tester.getSemantics(header()).getSemanticsData();
      expect(data.customSemanticsActionIds ?? const <int>[], isEmpty);

      await tester.drag(find.byIcon(Icons.pets), const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(cardRect(tester), before);
      // The grip draws its dots only: no resize actions.
      expect(grip(), findsNothing);
      expect(gripDots(), findsOneWidget);
      expect(controller.overlayUiState.cardOffset, stored);
      expectCardOnScreen(tester, 568);
      handle.dispose();
    });

    testWidgets('a maximized grip passes drags to the list', (tester) async {
      final controller = await pumpCard(
        tester,
        windowState: CardWindowState.maximized,
      );
      controller.issuesNotifier.value = [
        for (final issue in mixedOverlayIssues()) issue,
        for (var i = 0; i < 12; i++)
          PerformanceIssue(
            severity: IssueSeverity.warning,
            category: IssueCategory.build,
            confidence: IssueConfidence.confirmed,
            title: 'Filler $i',
            detail: 'Detail',
            fixHint: 'Fix',
            stableId: 'filler_$i',
          ),
      ];
      await tester.pump();
      final before = cardRect(tester);
      final list = find.byType(Scrollable).last;
      final offset = tester.state<ScrollableState>(list).position.pixels;

      await tester.dragFrom(
        tester.getCenter(gripDots()),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(cardRect(tester), before);
      expect(
        tester.state<ScrollableState>(list).position.pixels,
        greaterThan(offset),
      );
    });

    for (final keyboard in [150.0, 300.0]) {
      testWidgets('a maximized card above a $keyboard px keyboard keeps a '
          'list under the status row', (tester) async {
        final controller = await pumpView(
          tester,
          const Size(844, 390),
          keyboard: keyboard,
        );
        controller.overlayUiState.setCardGeometry(
          offset: null,
          width: null,
          height: null,
          windowState: CardWindowState.maximized,
        );
        await openDashboard(tester, controller);
        expect(tester.takeException(), isNull);

        // The card keeps a row of the list under the status row.
        final list = tester.getRect(find.byType(ListView));
        expect(list.height, greaterThanOrEqualTo(48));
      });
    }
  });
}
