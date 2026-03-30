import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/ui/guide_page.dart';

void main() {
  group('GuidePage', () {
    testWidgets('shows all legend content', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GuidePage(onClose: () {}),
        ),
      ));

      // Color Legend section visible
      expect(find.text('Color Legend'), findsOneWidget);

      // Severity section
      expect(find.textContaining('Critical'), findsOneWidget);
      expect(find.textContaining('Warning'), findsOneWidget);

      // Confidence badges
      expect(find.text('CONFIRMED'), findsOneWidget);
      expect(find.text('LIKELY'), findsOneWidget);
      expect(find.text('POSSIBLE'), findsOneWidget);

      // Source accents
      expect(find.text('VM timeline event'), findsOneWidget);
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

    testWidgets('back button calls onClose', (tester) async {
      var closed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GuidePage(onClose: () => closed = true),
        ),
      ));

      await tester.tap(find.byIcon(Icons.arrow_back));
      expect(closed, isTrue);
    });

    testWidgets('system back gesture calls onClose', (tester) async {
      var closed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GuidePage(onClose: () => closed = true),
        ),
      ));

      // Simulate system back button / gesture
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(closed, isTrue);
    });
  });
}
