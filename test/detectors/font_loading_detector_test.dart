import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/font_loading_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

void main() {
  group('FontLoadingDetector', () {
    late FontLoadingDetector detector;

    setUp(() {
      detector = FontLoadingDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
              Text('d', style: TextStyle(fontFamily: 'FontD')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('no issues when 3 or fewer custom fonts', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('flags when >3 custom font families detected', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
              Text('d', style: TextStyle(fontFamily: 'FontD')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('4 families'));
      expect(detector.issues.first.observationSource,
          ObservationSource.structural);
    });

    testWidgets('system fonts are not counted', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'Roboto')),
              Text('b', style: TextStyle(fontFamily: 'Arial')),
              Text('c', style: TextStyle(fontFamily: 'Helvetica')),
              Text('d', style: TextStyle(fontFamily: 'Times')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('counts unique families only (deduplication)', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              10,
              (_) => const Text('a', style: TextStyle(fontFamily: 'FontA')),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      // Only 1 unique family, below threshold of >3
      expect(detector.issues, isEmpty);
    });

    testWidgets('RichText root style fontFamily detected', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              const Text('a', style: TextStyle(fontFamily: 'FontA')),
              const Text('b', style: TextStyle(fontFamily: 'FontB')),
              const Text('c', style: TextStyle(fontFamily: 'FontC')),
              // RichText with root-level fontFamily provides the 4th font
              RichText(
                text: const TextSpan(
                  text: 'd',
                  style: TextStyle(fontFamily: 'FontD'),
                ),
              ),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, hasLength(1));
    });

    testWidgets('stableId, confidence, and category', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
              Text('d', style: TextStyle(fontFamily: 'FontD')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.first;
      expect(issue.stableId, 'multiple_custom_fonts');
      expect(issue.confidence, IssueConfidence.possible);
      expect(issue.category, IssueCategory.font);
      expect(issue.severity, IssueSeverity.warning);
    });

    testWidgets('no highlights produced', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
              Text('d', style: TextStyle(fontFamily: 'FontD')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isEmpty);
    });

    testWidgets('dispose clears issues', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
              Text('d', style: TextStyle(fontFamily: 'FontD')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
    });

    // -----------------------------------------------------------------
    // Custom thresholds
    // -----------------------------------------------------------------

    testWidgets('custom maxFamilies fires at lower count', (tester) async {
      detector = FontLoadingDetector(maxFamilies: 1);
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('A', style: TextStyle(fontFamily: 'Lobster')),
              Text('B', style: TextStyle(fontFamily: 'Pacifico')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, hasLength(1));
    });

    testWidgets('default maxFamilies allows 3 custom fonts', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('A', style: TextStyle(fontFamily: 'Lobster')),
              Text('B', style: TextStyle(fontFamily: 'Pacifico')),
              Text('C', style: TextStyle(fontFamily: 'DancingScript')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });
  });
}
