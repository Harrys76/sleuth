import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/nested_scroll_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

void main() {
  group('NestedScrollDetector', () {
    late NestedScrollDetector detector;

    setUp(() {
      detector = NestedScrollDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: ListView(
                    children: const [SizedBox(height: 10)],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('flags SCSV nested with >threshold children (sized path)',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ListView(
            children: [
              SingleChildScrollView(
                child: Column(
                  children: List.generate(
                    55,
                    (i) => SizedBox(key: ValueKey(i), height: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('55 children'));
      expect(detector.issues.first.widgetName, 'SingleChildScrollView');
      expect(detector.issues.first.observationSource,
          ObservationSource.structural);
    });

    testWidgets('generic ListView nested inside scrollable', (tester) async {
      // Inner ListView must be bounded to avoid layout error
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: ListView(
                    children: const [SizedBox(height: 10)],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('ListView'));
      expect(detector.issues.first.title, contains('inside scrollable'));
    });

    testWidgets('no issue when no nesting', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                5,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('critical severity for sized path when count > 2x threshold',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ListView(
            children: [
              SingleChildScrollView(
                child: Column(
                  children: List.generate(
                    105,
                    (i) => SizedBox(key: ValueKey(i), height: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    testWidgets(
        'SCSV with <= threshold children falls through to generic warning',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ListView(
            children: [
              SingleChildScrollView(
                child: Column(
                  children: List.generate(
                    5,
                    (i) => SizedBox(key: ValueKey(i), height: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('inside scrollable'));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    testWidgets('stableId, confidence, and category', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: ListView(
                    children: const [SizedBox(height: 10)],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.first;
      expect(issue.stableId, 'nested_scroll_same_axis');
      expect(issue.confidence, IssueConfidence.possible);
      expect(issue.category, IssueCategory.build);
    });

    testWidgets('highlights produced for nested scroll', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: ListView(
                    children: const [SizedBox(height: 10)],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isNotEmpty);
      expect(detector.highlights, isNotEmpty);
      expect(detector.highlights.first.detectorName, 'Nested Scroll');
      expect(detector.highlights.first.widgetName, 'ListView');
    });

    testWidgets('no highlights when no nesting', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                5,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    testWidgets('highlights cleared on dispose', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: ListView(
                    children: const [SizedBox(height: 10)],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isNotEmpty);

      detector.dispose();
      expect(detector.highlights, isEmpty);
    });

    testWidgets('no issue for horizontal ListView inside vertical ScrollView',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            // vertical (default)
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: const [SizedBox(width: 100)],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty,
          reason: 'Cross-axis nesting is a standard pattern');
    });

    testWidgets('flags vertical ListView inside vertical ScrollView',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            // vertical (default)
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: ListView(
                    // vertical (default) — same axis
                    children: const [SizedBox(height: 10)],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1),
          reason: 'Same-axis nesting should be flagged');
    });

    testWidgets('no issue for horizontal GridView inside vertical ScrollView',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: GridView.count(
                    scrollDirection: Axis.horizontal,
                    crossAxisCount: 2,
                    children: const [SizedBox(), SizedBox()],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty,
          reason: 'Cross-axis nesting is a standard pattern');
    });

    testWidgets('flags same-axis nested CustomScrollView', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 200,
                  child: ListView(
                    children: const [SizedBox(height: 10)],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1),
          reason: 'Same-axis (vertical) nesting should be flagged');
    });

    testWidgets('dispose clears issues', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: ListView(
                    children: const [SizedBox(height: 10)],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
    });
  });
}
