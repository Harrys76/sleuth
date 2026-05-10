import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/issue_card.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

  PerformanceIssue parent(String id) => PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: IssueConfidence.likely,
        title: id,
        detail: 'D',
        fixHint: 'F',
        stableId: id,
      );

  PerformanceIssue downstream({
    required List<String> rootCauseIds,
    String id = 'heap_growing',
  }) =>
      PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: IssueConfidence.confirmed,
        title: id,
        detail: 'D',
        fixHint: 'F',
        stableId: id,
        rootCauseIds: rootCauseIds,
      );

  group('IssueCard _causedBySection (multi-parent)', () {
    testWidgets(
        'renders "Caused by (N):" header + each parent title when '
        'parentIssues set', (tester) async {
      final a = parent('uncached_images');
      final b = parent('stream_resource_growth');
      await tester.pumpWidget(wrap(
        IssueCard(
          issue: downstream(
              rootCauseIds: ['uncached_images', 'stream_resource_growth']),
          initiallyExpanded: true,
          parentIssues: [a, b],
        ),
      ));
      expect(find.text('Caused by (2):'), findsOneWidget);
      expect(find.text('uncached_images'), findsOneWidget);
      expect(find.text('stream_resource_growth'), findsOneWidget);
    });

    testWidgets('caps at 5 + "and N more..." for >5 parents', (tester) async {
      final parents = List.generate(7, (i) => parent('parent_$i'));
      await tester.pumpWidget(wrap(
        IssueCard(
          issue: downstream(
              rootCauseIds: parents.map((p) => p.stableId!).toList()),
          initiallyExpanded: true,
          parentIssues: parents,
        ),
      ));
      expect(find.text('Caused by (7):'), findsOneWidget);
      expect(find.text('parent_0'), findsOneWidget);
      expect(find.text('parent_4'), findsOneWidget);
      expect(find.text('parent_5'), findsNothing,
          reason: 'over-cap entries collapse into the more-row');
      expect(find.text('and 2 more...'), findsOneWidget);
    });

    testWidgets(
        '"(+N suppressed)" annotation renders when suppressedParentCount > 0',
        (tester) async {
      final a = parent('uncached_images');
      await tester.pumpWidget(wrap(
        IssueCard(
          issue: downstream(
              rootCauseIds: ['uncached_images', 'missing-b', 'missing-c']),
          initiallyExpanded: true,
          parentIssues: [a],
          suppressedParentCount: 2,
        ),
      ));
      // Header counts ALL parents (resolved + suppressed).
      expect(find.text('Caused by (3):'), findsOneWidget);
      expect(find.text('uncached_images'), findsOneWidget);
      expect(find.text('(+2 suppressed)'), findsOneWidget);
    });

    testWidgets(
        'no _causedBySection when parentIssues null and '
        'suppressedParentCount is zero', (tester) async {
      await tester.pumpWidget(wrap(
        IssueCard(
          issue: downstream(rootCauseIds: ['x']),
          initiallyExpanded: true,
        ),
      ));
      expect(find.textContaining('Caused by'), findsNothing);
    });

    testWidgets(
        'all-suppressed orphan: section still renders with only the '
        '"(+N suppressed)" annotation (no parent rows)', (tester) async {
      await tester.pumpWidget(wrap(
        IssueCard(
          issue: downstream(rootCauseIds: ['missing-a', 'missing-b']),
          initiallyExpanded: true,
          parentIssues: null,
          suppressedParentCount: 2,
        ),
      ));
      expect(find.text('Caused by (2):'), findsOneWidget);
      expect(find.text('(+2 suppressed)'), findsOneWidget);
    });
  });
}
