import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';

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
  group('Issues summary bar', () {
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
          body: FloatingIssuesCard(
            controller: controller,
            onClose: () {},
          ),
        ),
      );
    }

    testWidgets('no issues — summary bar not rendered', (tester) async {
      await tester.pumpWidget(buildCard());

      // Empty state shown
      expect(find.textContaining('No issues detected'), findsOneWidget);
      // "confirmed" text from summary bar should not be present
      expect(find.textContaining('confirmed'), findsNothing);
    });

    testWidgets('issues present — summary bar rendered', (tester) async {
      controller.issuesNotifier.value = [
        _testIssue(severity: IssueSeverity.critical, title: 'Issue 1'),
        _testIssue(severity: IssueSeverity.warning, title: 'Issue 2'),
      ];

      await tester.pumpWidget(buildCard());

      expect(find.textContaining('confirmed'), findsOneWidget);
    });

    testWidgets('severity counts are correct', (tester) async {
      controller.issuesNotifier.value = [
        _testIssue(severity: IssueSeverity.critical, title: 'C1'),
        _testIssue(severity: IssueSeverity.critical, title: 'C2'),
        _testIssue(severity: IssueSeverity.warning, title: 'W1'),
      ];

      await tester.pumpWidget(buildCard());

      // Find the severity count texts in the summary bar.
      // Critical count = 2, warning count = 1
      final texts = tester.widgetList<Text>(find.byType(Text));
      final countTexts = texts
          .where((t) =>
              t.style?.fontSize == 10 && t.style?.fontWeight == FontWeight.bold)
          .map((t) => t.data)
          .toList();

      expect(countTexts, contains('2')); // 2 critical
      expect(countTexts, contains('1')); // 1 warning
    });

    testWidgets('evidence quality shows confirmed and heuristic counts',
        (tester) async {
      controller.issuesNotifier.value = [
        _testIssue(
          confidence: IssueConfidence.confirmed,
          title: 'Confirmed 1',
        ),
        _testIssue(
          confidence: IssueConfidence.confirmed,
          title: 'Confirmed 2',
        ),
        _testIssue(
          confidence: IssueConfidence.possible,
          title: 'Possible 1',
        ),
      ];

      await tester.pumpWidget(buildCard());

      expect(find.textContaining('2 confirmed'), findsOneWidget);
      expect(find.textContaining('1 heuristic'), findsOneWidget);
    });

    testWidgets('summary bar updates when issues change', (tester) async {
      controller.issuesNotifier.value = [
        _testIssue(severity: IssueSeverity.warning, title: 'W1'),
      ];

      await tester.pumpWidget(buildCard());

      // Initially 1 warning
      final textsInitial = tester.widgetList<Text>(find.byType(Text));
      final warningCounts = textsInitial
          .where((t) =>
              t.data == '1' &&
              t.style?.fontSize == 10 &&
              t.style?.fontWeight == FontWeight.bold)
          .toList();
      expect(warningCounts, isNotEmpty);

      // Add a critical issue
      controller.issuesNotifier.value = [
        _testIssue(severity: IssueSeverity.warning, title: 'W1'),
        _testIssue(severity: IssueSeverity.critical, title: 'C1'),
      ];
      await tester.pump();

      // Now should show both counts
      expect(find.textContaining('2 confirmed'), findsOneWidget);
    });
  });
}
