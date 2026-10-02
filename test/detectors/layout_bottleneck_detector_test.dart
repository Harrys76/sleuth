import 'package:flutter/material.dart';
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
      expect(
        detector.issues.first.observationSource,
        ObservationSource.structural,
      );
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
      expect(issue.category, IssueCategory.layout);
    });

    testWidgets('single intrinsic is graded warning with possible confidence', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.single;
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.confidence, IssueConfidence.possible);
      expect(issue.confidenceReason, contains('cost depends on subtree size'));
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
            child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expect(detector.issues.first.confidence, IssueConfidence.likely);
      expect(detector.issues.first.title, contains('Nested'));
    });

    testWidgets('nested intrinsic highlight is critical', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(
            child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
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
                child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
              ),
              IntrinsicWidth(child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expect(detector.issues.first.confidence, IssueConfidence.likely);
      expect(detector.issues.first.title, contains('3 intrinsic'));
    });

    // -----------------------------------------------------------------
    // Framework-owned intrinsics are suppressed. Every test first proves
    // the framework intrinsic is in the tree, then asserts silence.
    // -----------------------------------------------------------------

    group('framework intrinsic owners', () {
      final intrinsicFinder = find.byWidgetPredicate(
        (w) => w is IntrinsicWidth || w is IntrinsicHeight,
        skipOffstage: false,
      );

      List<PerformanceIssue> layoutIssues() => detector.issues
          .where((i) => i.stableId == 'layout_bottleneck')
          .toList();

      testWidgets('horizontal ToggleButtons IntrinsicHeight is suppressed', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ToggleButtons(
                isSelected: const [true, false],
                onPressed: (_) {},
                children: const [Text('A'), Text('B')],
              ),
            ),
          ),
        );
        expect(find.byType(IntrinsicHeight, skipOffstage: false), findsWidgets);
        detector.scanTree(tester.element(find.byType(MaterialApp)));
        expect(layoutIssues(), isEmpty);
      });

      testWidgets('vertical ToggleButtons IntrinsicWidth is suppressed', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ToggleButtons(
                direction: Axis.vertical,
                isSelected: const [true, false],
                onPressed: (_) {},
                children: const [Text('A'), Text('B')],
              ),
            ),
          ),
        );
        expect(find.byType(IntrinsicWidth, skipOffstage: false), findsWidgets);
        detector.scanTree(tester.element(find.byType(MaterialApp)));
        expect(layoutIssues(), isEmpty);
      });

      testWidgets('horizontal MenuBar intrinsics are suppressed, not nested', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MenuBar(
                children: [
                  SubmenuButton(
                    menuChildren: [
                      MenuItemButton(onPressed: () {}, child: const Text('x')),
                    ],
                    child: const Text('File'),
                  ),
                  SubmenuButton(
                    menuChildren: [
                      MenuItemButton(onPressed: () {}, child: const Text('y')),
                    ],
                    child: const Text('Edit'),
                  ),
                ],
              ),
            ),
          ),
        );
        expect(find.byType(IntrinsicHeight, skipOffstage: false), findsWidgets);
        expect(find.byType(IntrinsicWidth, skipOffstage: false), findsWidgets);
        detector.scanTree(tester.element(find.byType(MaterialApp)));
        expect(layoutIssues(), isEmpty);
      });

      testWidgets(
        'linear landscape BottomNavigationBar label IntrinsicWidth is '
        'suppressed',
        (tester) async {
          // Default test surface is 800x600, i.e. landscape.
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                bottomNavigationBar: BottomNavigationBar(
                  type: BottomNavigationBarType.fixed,
                  landscapeLayout: BottomNavigationBarLandscapeLayout.linear,
                  items: const [
                    BottomNavigationBarItem(icon: Icon(Icons.home), label: 'A'),
                    BottomNavigationBarItem(icon: Icon(Icons.star), label: 'B'),
                    BottomNavigationBarItem(icon: Icon(Icons.add), label: 'C'),
                  ],
                ),
              ),
            ),
          );
          expect(
            find.byType(IntrinsicWidth, skipOffstage: false),
            findsNWidgets(3),
          );
          detector.scanTree(tester.element(find.byType(MaterialApp)));
          expect(layoutIssues(), isEmpty);
        },
      );

      Future<void> openDialog(WidgetTester tester, Widget dialog) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showDialog<void>(context: context, builder: (_) => dialog),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      testWidgets('AlertDialog IntrinsicWidth is suppressed', (tester) async {
        await openDialog(
          tester,
          const AlertDialog(
            title: Text('Title'),
            content: Text('Body'),
            actions: [Text('OK')],
          ),
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(IntrinsicWidth, skipOffstage: false),
          ),
          findsOneWidget,
        );
        detector.scanTree(tester.element(find.byType(AlertDialog)));
        expect(layoutIssues(), isEmpty);
      });

      testWidgets('SimpleDialog IntrinsicWidth is suppressed', (tester) async {
        await openDialog(
          tester,
          const SimpleDialog(title: Text('Title'), children: [Text('Row')]),
        );
        expect(
          find.descendant(
            of: find.byType(SimpleDialog),
            matching: find.byType(IntrinsicWidth, skipOffstage: false),
          ),
          findsOneWidget,
        );
        detector.scanTree(tester.element(find.byType(SimpleDialog)));
        expect(layoutIssues(), isEmpty);
      });

      testWidgets('Scaffold persistentFooterButtons IntrinsicHeight is '
          'suppressed', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: const SizedBox(),
              persistentFooterButtons: [
                TextButton(onPressed: () {}, child: const Text('Footer')),
              ],
            ),
          ),
        );
        expect(
          find.byType(IntrinsicHeight, skipOffstage: false),
          findsOneWidget,
        );
        detector.scanTree(tester.element(find.byType(MaterialApp)));
        expect(layoutIssues(), isEmpty);
      });

      testWidgets('open PopupMenuButton menu IntrinsicWidth is suppressed', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PopupMenuButton<int>(
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 1, child: Text('One')),
                ],
                child: const Text('menu'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('menu'));
        await tester.pumpAndSettle();
        expect(find.byType(IntrinsicWidth, skipOffstage: false), findsWidgets);
        detector.scanTree(tester.element(find.byType(MaterialApp)));
        expect(layoutIssues(), isEmpty);
      });

      testWidgets(
        'user IntrinsicHeight in AlertDialog content fires once, not nested',
        (tester) async {
          await openDialog(
            tester,
            const AlertDialog(
              title: Text('Title'),
              content: IntrinsicHeight(child: Text('Body')),
            ),
          );
          expect(intrinsicFinder, findsNWidgets(2));
          detector.scanTree(tester.element(find.byType(AlertDialog)));

          final issue = layoutIssues().single;
          expect(issue.title, contains('1 intrinsic'));
          expect(issue.severity, IssueSeverity.warning);
          expect(issue.confidence, IssueConfidence.possible);
        },
      );

      testWidgets('user IntrinsicHeight(IntrinsicWidth) nesting is critical', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: IntrinsicHeight(child: IntrinsicWidth(child: Text('x'))),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(MaterialApp)));

        final issue = layoutIssues().single;
        expect(issue.severity, IssueSeverity.critical);
        expect(issue.confidence, IssueConfidence.likely);
      });

      testWidgets(
        'user IntrinsicHeight inside an open MenuBar submenu fires once; '
        'framework intrinsics do not count toward nesting',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MenuBar(
                  children: [
                    SubmenuButton(
                      menuChildren: [
                        MenuItemButton(
                          onPressed: () {},
                          child: const IntrinsicHeight(child: Text('Item')),
                        ),
                      ],
                      child: const Text('File'),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.tap(find.text('File'));
          await tester.pumpAndSettle();
          // Framework: MenuBar cross-axis IntrinsicHeight, per-item
          // IntrinsicWidth, submenu IntrinsicWidth. User: one IntrinsicHeight.
          expect(intrinsicFinder, findsNWidgets(4));
          detector.scanTree(tester.element(find.byType(MaterialApp)));

          final issue = layoutIssues().single;
          expect(issue.title, contains('1 intrinsic'));
          expect(issue.severity, IssueSeverity.warning);
          expect(issue.confidence, IssueConfidence.possible);
        },
      );

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

      testWidgets('Wrap alongside IntrinsicHeight reports both', (
        tester,
      ) async {
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
