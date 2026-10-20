import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/status_lines.dart';

PerformanceIssue _testIssue({
  IssueSeverity severity = IssueSeverity.warning,
  IssueConfidence confidence = IssueConfidence.confirmed,
  IssueCategory category = IssueCategory.build,
  String title = 'Test Issue',
}) {
  return PerformanceIssue(
    severity: severity,
    category: category,
    confidence: confidence,
    title: title,
    detail: 'Detail',
    fixHint: 'Fix',
    stableId: title,
  );
}

void main() {
  group('Status row chips', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    Widget buildCard() {
      return MaterialApp(
        home: Scaffold(
          body: FloatingIssuesCard(controller: controller, onClose: () {}),
        ),
      );
    }

    testWidgets('no issues: no severity chips', (tester) async {
      await tester.pumpWidget(buildCard());

      expect(find.byType(SleuthStatusBox), findsOneWidget);
      expect(find.textContaining('critical'), findsNothing);
      expect(find.textContaining('warning'), findsNothing);
    });

    testWidgets('chips name each severity with its count', (tester) async {
      controller.issuesNotifier.value = [
        _testIssue(severity: IssueSeverity.critical, title: 'C1'),
        _testIssue(severity: IssueSeverity.critical, title: 'C2'),
        _testIssue(severity: IssueSeverity.warning, title: 'W1'),
      ];

      await tester.pumpWidget(buildCard());

      expect(find.text('2 critical'), findsOneWidget);
      expect(find.text('1 warning'), findsOneWidget);
      // A severity with no cards has no chip while it is on.
      expect(find.textContaining(' ok'), findsNothing);
    });

    testWidgets('no confidence caption under the chips', (tester) async {
      controller.issuesNotifier.value = [
        _testIssue(confidence: IssueConfidence.confirmed, title: 'Confirmed'),
        _testIssue(confidence: IssueConfidence.possible, title: 'Possible'),
      ];

      await tester.pumpWidget(buildCard());

      expect(find.textContaining('confirmed'), findsNothing);
      expect(find.textContaining('heuristic'), findsNothing);
    });

    testWidgets('chips follow issue changes', (tester) async {
      controller.issuesNotifier.value = [
        _testIssue(severity: IssueSeverity.warning, title: 'W1'),
      ];

      await tester.pumpWidget(buildCard());
      expect(find.text('1 warning'), findsOneWidget);
      expect(find.textContaining('critical'), findsNothing);

      controller.issuesNotifier.value = [
        _testIssue(severity: IssueSeverity.warning, title: 'W1'),
        _testIssue(severity: IssueSeverity.critical, title: 'C1'),
      ];
      await tester.pump();

      expect(find.text('1 warning'), findsOneWidget);
      expect(find.text('1 critical'), findsOneWidget);
    });
  });
}
