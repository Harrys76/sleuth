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
  });
}
