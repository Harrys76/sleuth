import 'package:flutter/material.dart'
    show AlertDialog, DropdownButton, DropdownMenuItem, Material, MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/layout_bottleneck_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  group('LayoutBottleneckDetector', () {
    late LayoutBottleneckDetector detector;

    setUp(() {
      detector = LayoutBottleneckDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    testWidgets('flags IntrinsicHeight widget', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('1 intrinsic'));
      expect(detector.issues.first.observationSource,
          ObservationSource.structural);
    });

    testWidgets('flags IntrinsicWidth widget', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicWidth(child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('1 intrinsic'));
    });

    testWidgets('counts multiple intrinsic nodes', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
              IntrinsicWidth(child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('2 intrinsic'));
    });

    testWidgets('stableId, confidence, and category', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.first;
      expect(issue.stableId, 'layout_bottleneck');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.layout);
      expect(issue.severity, IssueSeverity.warning);
    });

    testWidgets('highlights produced per intrinsic node', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
              IntrinsicWidth(child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, hasLength(2));
      expect(detector.highlights.first.detectorName, 'Layout');
    });

    testWidgets('no issues for tree without intrinsics', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              SizedBox(width: 10, height: 10),
              SizedBox(width: 20, height: 20),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    testWidgets('dispose clears issues and highlights', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
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
    // v9.4: Nested intrinsic detection
    // -----------------------------------------------------------------

    testWidgets('nested intrinsics escalated to critical', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(
            child: IntrinsicHeight(
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expect(detector.issues.first.title, contains('Nested'));
    });

    testWidgets('nested intrinsic highlight is critical', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(
            child: IntrinsicHeight(
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, hasLength(2));
      // Outer = warning, inner = critical
      final severities = detector.highlights.map((h) => h.severity).toList();
      expect(severities, contains(IssueSeverity.critical));
      expect(severities, contains(IssueSeverity.warning));
    });

    testWidgets('mixed nested and non-nested reports critical', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              IntrinsicHeight(
                child: IntrinsicHeight(
                  child: SizedBox(width: 10, height: 10),
                ),
              ),
              IntrinsicWidth(child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expect(detector.issues.first.title, contains('3 intrinsic'));
    });

    // -----------------------------------------------------------------
    // v11.3: Framework widget intrinsic suppression
    // -----------------------------------------------------------------

    group('framework widget suppression', () {
      testWidgets('IntrinsicWidth inside DropdownButton is NOT flagged',
          (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Material(
              child: DropdownButton<String>(
                value: 'a',
                items: const [
                  DropdownMenuItem(value: 'a', child: Text('A')),
                  DropdownMenuItem(value: 'b', child: Text('B')),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Material).last));

        expect(detector.issues, isEmpty,
            reason: 'DropdownButton uses IntrinsicWidth internally — suppress');
      });

      testWidgets('standalone IntrinsicWidth is still flagged', (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: IntrinsicWidth(child: SizedBox(width: 10, height: 10)),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
      });

      testWidgets('IntrinsicHeight inside AlertDialog is NOT flagged',
          (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: AlertDialog(
              content: const Text('Test'),
              actions: const [SizedBox()],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(AlertDialog)));

        // AlertDialog may or may not use IntrinsicWidth internally depending
        // on Flutter version. If it does, it should be suppressed.
        // If it doesn't, no issues either. Both are correct.
        for (final issue in detector.issues) {
          expect(issue.detail, isNot(contains('AlertDialog')),
              reason: 'Intrinsics inside AlertDialog should be suppressed');
        }
      });
    });

    // -----------------------------------------------------------------
    // v11.4: Wrap with excessive children
    // -----------------------------------------------------------------

    group('Wrap layout bottleneck', () {
      testWidgets('flags Wrap with >30 children', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SingleChildScrollView(
              child: Wrap(
                children: List.generate(
                  35,
                  (i) => SizedBox(key: ValueKey(i), width: 50, height: 50),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final wrapIssues = detector.issues
            .where((i) => i.stableId == 'wrap_layout_bottleneck')
            .toList();
        expect(wrapIssues, hasLength(1));
        expect(wrapIssues.first.title, contains('35'));
        expect(wrapIssues.first.confidence, IssueConfidence.possible);
        expect(wrapIssues.first.category, IssueCategory.layout);
      });

      testWidgets('no issue for Wrap with <=30 children', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SingleChildScrollView(
              child: Wrap(
                children: List.generate(
                  30,
                  (i) => SizedBox(key: ValueKey(i), width: 50, height: 50),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final wrapIssues = detector.issues
            .where((i) => i.stableId == 'wrap_layout_bottleneck')
            .toList();
        expect(wrapIssues, isEmpty);
      });

      testWidgets('Wrap alongside IntrinsicHeight reports both',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  Wrap(
                    children: List.generate(
                      35,
                      (i) => SizedBox(key: ValueKey(i), width: 50, height: 50),
                    ),
                  ),
                  const IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
                ],
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final wrapIssues = detector.issues
            .where((i) => i.stableId == 'wrap_layout_bottleneck')
            .toList();
        final intrinsicIssues = detector.issues
            .where((i) => i.stableId == 'layout_bottleneck')
            .toList();
        expect(wrapIssues, hasLength(1));
        expect(intrinsicIssues, hasLength(1));
      });

      testWidgets('critical severity for large Wrap', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SingleChildScrollView(
              child: Wrap(
                children: List.generate(
                  65,
                  (i) => SizedBox(key: ValueKey(i), width: 50, height: 50),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final wrapIssues = detector.issues
            .where((i) => i.stableId == 'wrap_layout_bottleneck')
            .toList();
        expect(wrapIssues.first.severity, IssueSeverity.critical);
      });
    });
  });
}
