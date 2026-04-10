import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';

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
          of: find.byWidgetPredicate(
            (w) => w is Material && w.elevation == 8,
          ),
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
      // Default: 600 * 0.55 = 330 (above 250 min floor)
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
      // Static min height = 250px
      expect(box.constraints.maxHeight, 250.0);
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

    testWidgets('restore after maximize returns to default width',
        (tester) async {
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
}
