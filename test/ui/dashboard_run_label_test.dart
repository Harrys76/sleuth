import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';

void main() {
  group('Run label', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    Future<void> pumpCard(
      WidgetTester tester, {
      double width = 320,
      bool debug = true,
      SleuthController? card,
      double textScale = 1,
      SleuthThemeData theme = const SleuthThemeData(),
    }) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = card ?? controller;
      c.overlayUiState.setCardGeometry(
        offset: Offset.zero,
        width: width,
        height: 400,
        windowState: CardWindowState.normal,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: Scaffold(
              body: SleuthTheme(
                data: theme,
                child: FloatingIssuesCard(
                  controller: c,
                  onClose: () {},
                  isDebugMode: debug,
                ),
              ),
            ),
          ),
        ),
      );
    }

    /// How far the header stepped down: 0 name and full label, 1 full
    /// label, 2 mode only, 3 dot only.
    int step() {
      if (find.text('Debug · no VM').evaluate().isNotEmpty) {
        return find.text('Sleuth').evaluate().isNotEmpty ? 0 : 1;
      }
      return find.text('Debug').evaluate().isNotEmpty ? 2 : 3;
    }

    testWidgets('replaces the FRAME, VM+ and DBG badges', (tester) async {
      final dbg = SleuthController(
        config: const SleuthConfig(enableDebugCallbacks: true),
      );
      dbg.initializeDetectorsForTest();
      expect(dbg.isDebugCallbacksActive, isTrue);
      await pumpCard(tester, card: dbg);

      expect(find.text('FRAME'), findsNothing);
      expect(find.text('VM+'), findsNothing);
      expect(find.text('DBG'), findsNothing);
      expect(find.bySemanticsLabel('Debug run, no VM link'), findsOneWidget);

      // Disposed in the body: debug callbacks set render debug variables,
      // which the binding checks before tear-downs run.
      await tester.pumpWidget(const SizedBox());
      dbg.dispose();
    });

    testWidgets('names the mode and the VM link on a wide card', (
      tester,
    ) async {
      await pumpCard(tester, width: 600);
      expect(find.text('Sleuth'), findsOneWidget);
      expect(find.text('Debug · no VM'), findsOneWidget);

      controller.vmConnectedNotifier.value = true;
      await tester.pump();
      expect(find.text('Debug · VM'), findsOneWidget);
      expect(find.bySemanticsLabel('Debug run, VM connected'), findsOneWidget);
    });

    testWidgets('the dot is filled with the VM and a ring without it', (
      tester,
    ) async {
      BoxDecoration dot() => tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.bySemanticsLabel(RegExp('run, ')),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((d) => d.decoration as BoxDecoration)
          .firstWhere((d) => d.shape == BoxShape.circle);
      const theme = SleuthThemeData();
      // The 320 px card in the test font shows the short label, where
      // the dot alone carries the VM state.
      await pumpCard(tester);
      expect(dot().color, isNull);
      expect((dot().border! as Border).top.color, theme.severityWarningText);

      controller.vmConnectedNotifier.value = true;
      await tester.pump();
      expect(dot().color, theme.severityOkText);
      expect(dot().border, isNull);
    });

    testWidgets('a larger label font while open steps the header down', (
      tester,
    ) async {
      await pumpCard(tester, width: 640);
      expect(step(), 0);
      // Same card, same scale; only the theme's label size changes.
      await pumpCard(
        tester,
        width: 640,
        theme: const SleuthThemeData().copyWith(fontXs: 40),
      );
      expect(tester.takeException(), isNull);
      expect(step(), greaterThan(0));
    });

    testWidgets('reads Profile outside debug mode', (tester) async {
      await pumpCard(tester, width: 600, debug: false);
      expect(find.text('Profile · no VM'), findsOneWidget);
      expect(find.bySemanticsLabel('Profile run, no VM link'), findsOneWidget);
    });

    testWidgets('drops the name, then the VM text, before it overflows', (
      tester,
    ) async {
      await pumpCard(tester);
      // Five header buttons leave little room at 320 px in the test font.
      expect(find.text('Sleuth'), findsNothing);
      expect(find.text('Debug · no VM'), findsNothing);
      // The label keeps its full reading for a screen reader.
      expect(find.bySemanticsLabel('Debug run, no VM link'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('steps down by measurement at 1.0x and 1.3x, never later '
        'at a larger scale', (tester) async {
      for (final width in [320.0, 420.0, 520.0, 640.0]) {
        final steps = <int>[];
        for (final scale in [1.0, 1.3, 2.0]) {
          await pumpCard(tester, width: width, textScale: scale);
          expect(tester.takeException(), isNull, reason: '$width at $scale');
          steps.add(step());
        }
        expect(steps, orderedEquals([...steps]..sort()), reason: '$width');
        // The header clamps at 1.3x, so 2.0x steps as 1.3x does.
        expect(steps[2], steps[1], reason: '$width');
      }
      // A wide card at 1.0x shows everything; a 320 px card at 1.3x
      // keeps at least the dot.
      await pumpCard(tester, width: 640);
      expect(step(), 0);
      await pumpCard(tester, textScale: 1.3);
      expect(step(), inInclusiveRange(1, 3));
      expect(find.bySemanticsLabel('Debug run, no VM link'), findsOneWidget);
    });
  });
}
