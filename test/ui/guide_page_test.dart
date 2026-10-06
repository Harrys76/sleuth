import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/ui/guide_page.dart';

import '../helpers/overlay_harness.dart';

void main() {
  group('GuidePage', () {
    testWidgets('shows all legend content', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GuidePage(onClose: () {})),
        ),
      );

      // Color Legend section visible
      expect(find.text('Color legend'), findsOneWidget);

      // Severity section
      expect(find.textContaining('Critical'), findsOneWidget);
      expect(find.textContaining('Warning'), findsOneWidget);

      // Confidence badges
      expect(find.text('CONFIRMED'), findsOneWidget);
      expect(find.text('LIKELY'), findsOneWidget);
      expect(find.text('POSSIBLE'), findsOneWidget);

      // Source accents
      expect(find.text('Measured timing'), findsOneWidget);
      expect(find.text('Debug callback'), findsOneWidget);
      expect(find.text('Structural scan'), findsOneWidget);

      // Category badges with descriptions
      expect(find.text('BUILD'), findsOneWidget);
      expect(find.text('LAYOUT'), findsOneWidget);
      expect(find.text('NETWORK'), findsOneWidget);
      expect(find.textContaining('Widget rebuild overhead'), findsOneWidget);
      expect(find.textContaining('Layout constraint issues'), findsOneWidget);
      expect(find.textContaining('HTTP request performance'), findsOneWidget);

      // Effort badges
      expect(find.text('QUICK FIX'), findsOneWidget);
      expect(find.text('MEDIUM FIX'), findsOneWidget);
      expect(find.text('INVOLVED FIX'), findsOneWidget);

      // Special indicators
      expect(find.text('JANK'), findsOneWidget);
      expect(find.text('Highlighted'), findsOneWidget);
      expect(find.text('Jank flash'), findsOneWidget);
    });

    testWidgets('describes current overlay behavior', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GuidePage(onClose: () {})),
        ),
      );
      await tester.pumpAndSettle();

      final pageText = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => w.text.toPlainText())
          .join('\n');

      expect(pageText, isNot(contains('Double-tap')));
      expect(pageText, isNot(contains('blue border')));
      expect(pageText, contains('83'));
    });

    testWidgets('back button calls onClose', (tester) async {
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GuidePage(onClose: () => closed = true)),
        ),
      );

      await tester.tap(find.byIcon(Icons.arrow_back));
      expect(closed, isTrue);
    });

    testWidgets('system back closes the guide, then the dashboard', (
      tester,
    ) async {
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      await tester.tap(find.bySemanticsLabel('Guide'));
      await tester.pumpAndSettle();
      expect(find.byType(GuidePage), findsOneWidget);

      // The overlay hosts the page outside any Navigator; system back
      // reaches it through the binding observer.
      expect(await systemBack(tester), isTrue);
      expect(find.byType(GuidePage), findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);

      expect(await systemBack(tester), isTrue);
      expect(controller.overlayUiState.dashboardOpen, isFalse);
      expect(find.text('app'), findsOneWidget);
    });
  });
}
