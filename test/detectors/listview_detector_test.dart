import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/listview_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  group('ListviewDetector', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
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

    testWidgets('flags SingleChildScrollView + Column with >50 children',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('Column'));
      expect(detector.issues.first.title, contains('55'));
      expect(detector.issues.first.observationSource,
          ObservationSource.structural);
    });

    testWidgets('no issue when children count <= threshold', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                50,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('issue warning severity when count <= 3x threshold',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    testWidgets('issue critical severity when count > 3x threshold',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                155,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    testWidgets('highlight critical severity at > 2x threshold',
        (tester) async {
      // 105 children: issue is warning (<=150), but highlight is critical (>100)
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                105,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues.first.severity, IssueSeverity.warning);
      expect(detector.highlights.first.severity, IssueSeverity.critical);
    });

    testWidgets('detects Row inside SingleChildScrollView', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('Row'));
    });

    testWidgets('no issue for ListView.builder', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ListView.builder(
            itemCount: 100,
            itemBuilder: (_, i) => SizedBox(key: ValueKey(i), height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('stableId, confidence, and category', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.first;
      expect(issue.stableId, 'non_lazy_list');
      expect(issue.confidence, IssueConfidence.possible);
      expect(issue.category, IssueCategory.build);
    });

    testWidgets('custom threshold works', (tester) async {
      detector = ListviewDetector(childThreshold: 10);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                15,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, hasLength(1));
    });

    testWidgets('dispose clears issues and highlights', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isNotEmpty);
      expect(detector.highlights, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    // -----------------------------------------------------------------
    // v10.1: Non-builder ListView / GridView detection
    // -----------------------------------------------------------------

    group('non-builder ListView', () {
      testWidgets('flags ListView with >threshold children', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'non_lazy_listview');
        expect(detector.issues.first.title, contains('ListView'));
        expect(detector.issues.first.title, contains('55'));
        expect(detector.issues.first.observationSource,
            ObservationSource.structural);
      });

      testWidgets('no issue for ListView.builder', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView.builder(
              itemCount: 200,
              itemBuilder: (_, i) => SizedBox(key: ValueKey(i), height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('no issue when children <= threshold', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView(
              children: List.generate(
                50,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('warning severity when count <= 3x threshold',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues.first.severity, IssueSeverity.warning);
      });

      testWidgets('critical severity when count > 3x threshold',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView(
              children: List.generate(
                155,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues.first.severity, IssueSeverity.critical);
      });

      testWidgets('highlight critical at > 2x threshold', (tester) async {
        // 105 children: issue is warning (<=150), but highlight is critical (>100)
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView(
              children: List.generate(
                105,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues.first.severity, IssueSeverity.warning);
        expect(detector.highlights.first.severity, IssueSeverity.critical);
      });

      testWidgets('confidence and category', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final issue = detector.issues.first;
        expect(issue.confidence, IssueConfidence.possible);
        expect(issue.category, IssueCategory.build);
      });
    });

    group('non-builder GridView', () {
      testWidgets('flags GridView.count with >threshold children',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: GridView.count(
              crossAxisCount: 2,
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'non_lazy_gridview');
        expect(detector.issues.first.title, contains('GridView'));
        expect(detector.issues.first.title, contains('55'));
        expect(detector.issues.first.observationSource,
            ObservationSource.structural);
      });

      testWidgets('no issue for GridView.builder', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
              ),
              itemCount: 200,
              itemBuilder: (_, i) => SizedBox(key: ValueKey(i), height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('no issue when children <= threshold', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: GridView.count(
              crossAxisCount: 2,
              children: List.generate(
                50,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('warning severity when count <= 3x threshold',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: GridView.count(
              crossAxisCount: 2,
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues.first.severity, IssueSeverity.warning);
      });

      testWidgets('critical severity when count > 3x threshold',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: GridView.count(
              crossAxisCount: 2,
              children: List.generate(
                155,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues.first.severity, IssueSeverity.critical);
      });

      testWidgets('highlight critical at > 2x threshold', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: GridView.count(
              crossAxisCount: 2,
              children: List.generate(
                105,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues.first.severity, IssueSeverity.warning);
        expect(detector.highlights.first.severity, IssueSeverity.critical);
      });
    });

    // -----------------------------------------------------------------
    // v11.1: SliverList / SliverGrid with SliverChildListDelegate
    // -----------------------------------------------------------------

    group('non-builder SliverList', () {
      testWidgets('flags SliverList with SliverChildListDelegate >threshold',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverList(
                  delegate: SliverChildListDelegate(
                    List.generate(
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
        expect(detector.issues.first.stableId, 'non_lazy_sliver_list');
        expect(detector.issues.first.title, contains('SliverList'));
        expect(detector.issues.first.title, contains('55'));
        expect(detector.issues.first.observationSource,
            ObservationSource.structural);
      });

      testWidgets('no issue for SliverList.builder', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverList.builder(
                  itemCount: 200,
                  itemBuilder: (_, i) => SizedBox(key: ValueKey(i), height: 10),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('no issue when children <= threshold', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverList(
                  delegate: SliverChildListDelegate(
                    List.generate(
                      50,
                      (i) => SizedBox(key: ValueKey(i), height: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('warning severity when count <= 3x threshold',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverList(
                  delegate: SliverChildListDelegate(
                    List.generate(
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
        expect(detector.issues.first.severity, IssueSeverity.warning);
      });

      testWidgets('critical severity when count > 3x threshold',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverList(
                  delegate: SliverChildListDelegate(
                    List.generate(
                      155,
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

      testWidgets('confidence and category', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverList(
                  delegate: SliverChildListDelegate(
                    List.generate(
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

        final issue = detector.issues.first;
        expect(issue.confidence, IssueConfidence.possible);
        expect(issue.category, IssueCategory.build);
      });
    });

    // -----------------------------------------------------------------
    // v11.19: Sliver anti-pattern detection
    // -----------------------------------------------------------------

    group('Check A — SliverToBoxAdapter + large Column/Row', () {
      testWidgets('flags SliverToBoxAdapter + Column(55 children)',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
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
        expect(detector.issues.first.stableId, 'sliver_to_box_adapter_large');
        expect(detector.issues.first.title, contains('Column'));
        expect(detector.issues.first.title, contains('55'));
        expect(detector.issues.first.severity, IssueSeverity.warning);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
        expect(detector.issues.first.category, IssueCategory.build);
        expect(detector.issues.first.observationSource,
            ObservationSource.structural);
      });

      testWidgets('no issue when Column has 50 children (at threshold)',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: List.generate(
                      50,
                      (i) => SizedBox(key: ValueKey(i), height: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('flags SliverToBoxAdapter + Row(55 children)',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Row(
                    children: List.generate(
                      55,
                      (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('Row'));
      });

      testWidgets('no issue for SliverToBoxAdapter + single SizedBox',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(
                  child: SizedBox(height: 100),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('traverses through Padding wrapper to find Column',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      children: List.generate(
                        55,
                        (i) => SizedBox(key: ValueKey(i), height: 10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'sliver_to_box_adapter_large');
      });

      testWidgets('critical severity at 151+ children (3x threshold)',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: List.generate(
                      155,
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
        expect(detector.issues.first.severity, IssueSeverity.critical);
      });
    });

    group('Check B — SliverFillRemaining with scrollable child', () {
      testWidgets('flags SliverFillRemaining(hasScrollBody: false) + ListView',
          (tester) async {
        // Wrap in SizedBox to prevent rendering error from the anti-pattern
        // itself — the detector walks structure, not rendering output.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: SizedBox(
                    height: 200,
                    child: ListView.builder(
                      itemCount: 10,
                      itemBuilder: (_, i) =>
                          SizedBox(key: ValueKey(i), height: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(
            detector.issues.first.stableId, 'sliver_fill_remaining_scrollable');
        expect(detector.issues.first.severity, IssueSeverity.warning);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
      });

      testWidgets(
          'no issue for SliverFillRemaining(hasScrollBody: true) + ListView',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  // hasScrollBody defaults to true
                  child: ListView.builder(
                    itemCount: 10,
                    itemBuilder: (_, i) =>
                        SizedBox(key: ValueKey(i), height: 10),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets(
          'no issue for SliverFillRemaining(hasScrollBody: false) + non-scrollable',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('Hello')),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('flags SliverFillRemaining(hasScrollBody: false) + GridView',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: SizedBox(
                    height: 200,
                    child: GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                      ),
                      itemCount: 10,
                      itemBuilder: (_, i) =>
                          SizedBox(key: ValueKey(i), height: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(
            detector.issues.first.stableId, 'sliver_fill_remaining_scrollable');
      });

      testWidgets(
          'flags SliverFillRemaining(hasScrollBody: false) + SingleChildScrollView',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: SizedBox(
                    height: 200,
                    child: SingleChildScrollView(
                      child: Column(
                        children: List.generate(
                          10,
                          (i) => SizedBox(key: ValueKey(i), height: 10),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues
              .where((i) => i.stableId == 'sliver_fill_remaining_scrollable'),
          hasLength(1),
        );
      });

      testWidgets(
          'flags SliverFillRemaining(hasScrollBody: false) + CustomScrollView',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: SizedBox(
                    height: 200,
                    child: CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: SizedBox(height: 50),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues
              .where((i) => i.stableId == 'sliver_fill_remaining_scrollable'),
          hasLength(1),
        );
      });
    });

    group('Check C — SliverToBoxAdapter + shrinkWrap scrollable', () {
      testWidgets('flags SliverToBoxAdapter + ListView.builder(shrinkWrap)',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: 100,
                    itemBuilder: (_, i) =>
                        SizedBox(key: ValueKey(i), height: 10),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(
            detector.issues.first.stableId, 'sliver_to_box_adapter_shrinkwrap');
        expect(detector.issues.first.title, contains('ListView'));
        expect(detector.issues.first.severity, IssueSeverity.warning);
      });

      testWidgets(
          'no issue for SliverToBoxAdapter + ListView(shrinkWrap: false)',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 200,
                    child: ListView.builder(
                      itemCount: 100,
                      itemBuilder: (_, i) =>
                          SizedBox(key: ValueKey(i), height: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('flags SliverToBoxAdapter + GridView.builder(shrinkWrap)',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: GridView.builder(
                    shrinkWrap: true,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                    ),
                    itemCount: 100,
                    itemBuilder: (_, i) =>
                        SizedBox(key: ValueKey(i), height: 10),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(
            detector.issues.first.stableId, 'sliver_to_box_adapter_shrinkwrap');
        expect(detector.issues.first.title, contains('GridView'));
      });

      testWidgets('no duplicate when non-lazy + shrinkWrap both apply',
          (tester) async {
        // ListView(children: [...], shrinkWrap: true) inside SliverToBoxAdapter:
        // should emit non_lazy_listview only, NOT shrinkwrap
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: ListView(
                    shrinkWrap: true,
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
        expect(detector.issues.first.stableId, 'non_lazy_listview');
      });
    });

    group('dispose clears sliver state', () {
      testWidgets('dispose clears sliver findings', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
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
        expect(detector.issues, isNotEmpty);

        detector.dispose();
        expect(detector.issues, isEmpty);
        expect(detector.highlights, isEmpty);
      });
    });

    group('non-builder SliverGrid', () {
      testWidgets('flags SliverGrid with SliverChildListDelegate >threshold',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                  ),
                  delegate: SliverChildListDelegate(
                    List.generate(
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
        expect(detector.issues.first.stableId, 'non_lazy_sliver_grid');
        expect(detector.issues.first.title, contains('SliverGrid'));
        expect(detector.issues.first.title, contains('55'));
      });

      testWidgets('no issue for SliverGrid.builder', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                  ),
                  itemCount: 200,
                  itemBuilder: (_, i) => SizedBox(key: ValueKey(i), height: 10),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });
    });
  });
}
