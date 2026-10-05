import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
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

    testWidgets('resize custom actions step by 48 px', (tester) async {
      final handle = tester.ensureSemantics();
      controller.overlayUiState.setCardGeometry(
        offset: const Offset(100, 100),
        width: 300,
        height: null,
        windowState: CardWindowState.normal,
      );
      await tester.pumpWidget(buildCard());
      final resize = find.bySemanticsLabel('Resize card');
      // 48 x 48 hit box.
      expect(tester.getSize(findResizeHandle()), const Size(48, 48));

      await performCustomAction(tester, resize, 'Wider');
      expect(controller.overlayUiState.cardWidth, 348);
      await performCustomAction(tester, resize, 'Narrower');
      expect(controller.overlayUiState.cardWidth, 300);
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
      expect(initial, 300.0); // _defaultCardWidth

      await dragHandle(tester, const Offset(50, 0));

      final updated = findCardConstrainedBox(tester).constraints.maxWidth;
      // Pan slop consumes part of the first move, so we only assert direction.
      expect(updated, greaterThan(initial));
    });

    testWidgets('dragging handle left decreases card width', (tester) async {
      await tester.pumpWidget(buildCard());

      final initial = findCardConstrainedBox(tester).constraints.maxWidth;

      // Large leftward drag — slop adds ~10px right, then -300 overwhelms it.
      // Net result should be less than initial (300).
      await dragHandle(tester, const Offset(-300, 0));
      final shrunk = findCardConstrainedBox(tester).constraints.maxWidth;
      expect(shrunk, lessThan(initial));
    });

    testWidgets('width clamps at minimum (220px)', (tester) async {
      await tester.pumpWidget(buildCard());

      // Drag far left — slop adds 40px but then -500px overwhelms it
      await dragHandle(tester, const Offset(-500, 0));

      final box = findCardConstrainedBox(tester);
      expect(box.constraints.maxWidth, 220.0);
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

      expect(findCardConstrainedBox(tester).constraints.maxWidth, 300.0);
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
        'cardWidth': 240.0,
        'cardHeight': 420.0,
        'windowState': 'normal',
      });
      await tester.pump();
      expect(cardRect(tester), const Rect.fromLTWH(20, 100, 240, 420));

      await tester.drag(find.text('Sleuth'), const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(ui.cardWidth, 240);
      expect(ui.cardHeight, 420);
      expect(ui.cardOffset!.dx, 20);
      expect(ui.cardOffset!.dy, inExclusiveRange(100, 250 + 1));
      final card = cardRect(tester);
      expect(card.left, 20);
      expect(card.top, ui.cardOffset!.dy);
      expect(card.width, 240);
    });

    for (final keyboard in [150.0, 300.0]) {
      testWidgets('a maximized card above a $keyboard px keyboard keeps a '
          'list under the summary bar', (tester) async {
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

        final list = tester.getRect(find.byType(ListView));
        expect(list.height, greaterThan(0));
        // The summary bar's 36 px sit over the top of the list's area,
        // which keeps at least the chips' 48 px hit height.
        expect(list.height + 36, greaterThanOrEqualTo(48));
        if (keyboard == 150) {
          // Room for the bar and a row: the banners give it to the list.
          expect(list.height, greaterThanOrEqualTo(48));
        }
      });
    }
  });
}
