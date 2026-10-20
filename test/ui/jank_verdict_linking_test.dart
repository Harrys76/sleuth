import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/frame_verdict.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/issue_card.dart';

PerformanceIssue _testIssue({
  String title = 'Test Issue',
  String? stableId,
  IssueSeverity severity = IssueSeverity.warning,
  IssueConfidence confidence = IssueConfidence.confirmed,
  IssueCategory category = IssueCategory.build,
  String? widgetName,
}) {
  return PerformanceIssue(
    severity: severity,
    category: category,
    confidence: confidence,
    title: title,
    detail: 'Detail',
    fixHint: 'Fix',
    stableId: stableId ?? title,
    widgetName: widgetName,
  );
}

FrameVerdict _testVerdict({List<PerformanceIssue> relatedIssues = const []}) {
  return FrameVerdict(
    frameNumber: 1,
    totalFrameTime: const Duration(milliseconds: 32),
    uiThreadTime: const Duration(milliseconds: 20),
    rasterThreadTime: const Duration(milliseconds: 12),
    suspectedPhase: PipelinePhase.build,
    reason: 'Sustained jank: 4 severe frames',
    relatedIssues: relatedIssues,
  );
}

Widget _buildCard(
  PerformanceIssue issue, {
  bool jankCorrelated = false,
  bool finding = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: IssueCard(
        issue: issue,
        jankCorrelated: jankCorrelated,
        finding: finding,
      ),
    ),
  );
}

void main() {
  group('JANK badge on issue cards', () {
    testWidgets('badge shown when jankCorrelated is true', (tester) async {
      await tester.pumpWidget(_buildCard(_testIssue(), jankCorrelated: true));
      expect(find.text('Jank'), findsOneWidget);
    });

    testWidgets('badge absent when jankCorrelated is false', (tester) async {
      await tester.pumpWidget(_buildCard(_testIssue(), jankCorrelated: false));
      expect(find.text('Jank'), findsNothing);
    });

    testWidgets('badge in card — only on matching issues', (tester) async {
      final issue1 = _testIssue(title: 'Matched', stableId: 'matched');
      final issue2 = _testIssue(title: 'Unmatched', stableId: 'unmatched');

      final controller = SleuthController();
      controller.initializeDetectorsForTest();

      controller.verdictNotifier.value = _testVerdict(
        relatedIssues: [issue1],
      ); // only issue1
      final jank = _testIssue(
        title: 'Jank detected',
        stableId: 'jank_detected',
      );
      controller.issuesNotifier.value = [issue1, issue2, jank];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(controller: controller, onClose: () {}),
          ),
        ),
      );

      // JANK badge should appear once (only on matched issue)
      expect(find.text('Jank'), findsOneWidget);

      controller.dispose();
    });

    testWidgets('badge clears when the jank symptom leaves the reported list', (
      tester,
    ) async {
      final cause = _testIssue(title: 'Rebuilds', stableId: 'rebuild_activity');
      final jank = _testIssue(
        title: 'Jank detected',
        stableId: 'jank_detected',
      );
      final controller = SleuthController()..initializeDetectorsForTest();
      addTearDown(controller.dispose);
      controller.verdictNotifier.value = _testVerdict(relatedIssues: [cause]);
      controller.issuesNotifier.value = [cause, jank];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(controller: controller, onClose: () {}),
          ),
        ),
      );
      expect(find.text('Jank'), findsOneWidget);

      // The verdict notifier keeps the last jank frame's verdict.
      controller.issuesNotifier.value = [cause];
      await tester.pump();
      expect(find.text('Jank'), findsNothing);
    });

    testWidgets('badge stays while the symptom is collapsed under its cause', (
      tester,
    ) async {
      final stall = _testIssue(
        title: 'Event loop stall',
        stableId: 'event_loop_stall',
        severity: IssueSeverity.critical,
      );
      final sustained = PerformanceIssue(
        stableId: 'sustained_jank',
        severity: IssueSeverity.critical,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Sustained Jank',
        detail: 'Detail',
        fixHint: 'Fix',
        rootCauseIds: const ['event_loop_stall'],
      );
      final controller = SleuthController()..initializeDetectorsForTest();
      addTearDown(controller.dispose);
      controller.verdictNotifier.value = FrameVerdict(
        frameNumber: 1,
        totalFrameTime: const Duration(milliseconds: 40),
        uiThreadTime: const Duration(milliseconds: 4),
        rasterThreadTime: const Duration(milliseconds: 3),
        suspectedPhase: PipelinePhase.schedulerDelay,
        reason: 'Start delay',
        relatedIssues: [stall],
      );
      controller.issuesNotifier.value = [stall, sustained];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(controller: controller, onClose: () {}),
          ),
        ),
      );
      // The symptom card is folded into its cause, and the cause keeps
      // the tag.
      expect(find.text('Sustained Jank'), findsNothing);
      expect(find.text('Jank'), findsOneWidget);
    });
  });
}
