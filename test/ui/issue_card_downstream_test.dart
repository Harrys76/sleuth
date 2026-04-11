import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/issue_card.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  const rootIssue = PerformanceIssue(
    severity: IssueSeverity.warning,
    category: IssueCategory.build,
    confidence: IssueConfidence.likely,
    title: 'Wide setState scope',
    detail: 'Rebuilds 12 widgets',
    fixHint: 'Narrow the setState call',
    stableId: 'setstate_scope',
    downstreamIds: ['heavy_compute', 'rebuild_activity'],
  );

  const downstream1 = PerformanceIssue(
    severity: IssueSeverity.warning,
    category: IssueCategory.build,
    confidence: IssueConfidence.confirmed,
    title: 'Heavy compute on main thread',
    detail: 'D',
    fixHint: 'F',
    stableId: 'heavy_compute',
    rootCauseId: 'setstate_scope',
  );

  const downstream2 = PerformanceIssue(
    severity: IssueSeverity.critical,
    category: IssueCategory.build,
    confidence: IssueConfidence.likely,
    title: 'Excessive rebuilds: MyWidget',
    detail: 'D',
    fixHint: 'F',
    stableId: 'rebuild_activity',
    rootCauseId: 'setstate_scope',
  );

  group('IssueCard downstream rendering', () {
    testWidgets('root card shows effects badge when downstream present',
        (tester) async {
      await tester.pumpWidget(wrap(
        IssueCard(
          issue: rootIssue,
          downstreamIssues: const [downstream1, downstream2],
        ),
      ));

      // Effects badge shows count
      expect(find.text('\u21B3 2'), findsOneWidget);
    });

    testWidgets('no badge when downstreamIssues is null', (tester) async {
      await tester.pumpWidget(wrap(
        const IssueCard(issue: rootIssue),
      ));

      expect(find.text('\u21B3 2'), findsNothing);
    });

    testWidgets('no badge when downstreamIssues is empty', (tester) async {
      await tester.pumpWidget(wrap(
        const IssueCard(
          issue: rootIssue,
          downstreamIssues: [],
        ),
      ));

      expect(find.text('\u21B3 0'), findsNothing);
    });

    testWidgets('expanding root card shows downstream titles', (tester) async {
      await tester.pumpWidget(wrap(
        IssueCard(
          issue: rootIssue,
          downstreamIssues: const [downstream1, downstream2],
          initiallyExpanded: true,
        ),
      ));

      // Downstream titles visible
      expect(find.text('Heavy compute on main thread'), findsOneWidget);
      expect(find.text('Excessive rebuilds: MyWidget'), findsOneWidget);

      // Section header
      expect(find.text('Related effects (2):'), findsOneWidget);
    });

    testWidgets('downstream not visible when collapsed', (tester) async {
      await tester.pumpWidget(wrap(
        IssueCard(
          issue: rootIssue,
          downstreamIssues: const [downstream1, downstream2],
        ),
      ));

      // Section header should not be visible
      expect(find.text('Related effects (2):'), findsNothing);
    });

    testWidgets('max 5 downstream shown with overflow text', (tester) async {
      final manyDownstream = List.generate(
        7,
        (i) => PerformanceIssue(
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          title: 'Downstream issue $i',
          detail: 'D',
          fixHint: 'F',
          stableId: 'ds_$i',
        ),
      );

      await tester.pumpWidget(wrap(
        IssueCard(
          issue: rootIssue,
          downstreamIssues: manyDownstream,
          initiallyExpanded: true,
        ),
      ));

      // First 5 visible
      for (var i = 0; i < 5; i++) {
        expect(find.text('Downstream issue $i'), findsOneWidget);
      }
      // 6th and 7th hidden behind overflow
      expect(find.text('Downstream issue 5'), findsNothing);
      expect(find.text('Downstream issue 6'), findsNothing);

      // Overflow text
      expect(find.text('and 2 more...'), findsOneWidget);
    });
  });
}
