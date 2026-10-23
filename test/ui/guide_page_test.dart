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

      // Meta line: tags, confidence, recurrence and category words.
      expect(find.text('Meta line'), findsOneWidget);
      expect(find.text('Jank'), findsOneWidget);
      expect(find.text('Debug timing'), findsOneWidget);
      expect(find.text('New'), findsOneWidget);
      final pageText = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => w.text.toPlainText())
          .join('\n');
      for (final term in [
        'Confirmed',
        'Likely',
        'Possible',
        'persistent',
        'flaky',
        'Build',
        'Layout',
        'Network',
        'Startup',
      ]) {
        expect(pageText, contains(term), reason: term);
      }
      expect(pageText, contains('Widget rebuild overhead'));
      expect(pageText, contains('seen X of Y scans'));

      // Gone with the redesigned card.
      expect(find.text('CONFIRMED'), findsNothing);
      expect(find.text('BUILD'), findsNothing);
      expect(find.text('Measured timing'), findsNothing);
      expect(pageText, isNot(contains('left bar')));
      expect(pageText, isNot(contains('Emoji')));
      expect(pageText, isNot(contains('checkbox')));

      // Fix effort
      expect(find.text('Fix effort'), findsOneWidget);
      for (final term in ['Quick', 'Medium effort', 'Involved']) {
        expect(
          find.textContaining(RegExp('^$term  '), findRichText: true),
          findsOneWidget,
          reason: term,
        );
      }

      // Card colours
      expect(find.text('Finding'), findsOneWidget);
      expect(find.text('Jank flash'), findsNothing);
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

    testWidgets('the Back tip names the menu and the highlight bar', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GuidePage(onClose: () {})),
        ),
      );
      await tester.pumpAndSettle();

      final tip = find.textContaining(
        'back gesture or button closes the open page, the More menu or the '
        'highlight bar, then the card',
      );
      await tester.scrollUntilVisible(
        tip,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tip, findsOneWidget);
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
      await openFromMoreMenu(tester, 'Guide');
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
