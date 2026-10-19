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

FrameVerdict _testVerdict({
  List<PerformanceIssue> relatedIssues = const [],
  int frameNumber = 1,
  PipelinePhase phase = PipelinePhase.build,
}) {
  return FrameVerdict(
    frameNumber: frameNumber,
    totalFrameTime: const Duration(milliseconds: 32),
    uiThreadTime: const Duration(milliseconds: 20),
    rasterThreadTime: const Duration(milliseconds: 12),
    suspectedPhase: phase,
    reason: 'Sustained jank: 4 severe frames',
    relatedIssues: relatedIssues,
  );
}

Future<SleuthController> _pumpCard(
  WidgetTester tester,
  List<PerformanceIssue> issues, {
  FrameVerdict? verdict,
}) async {
  // Holds are timed on the controller's clock; follow the test's time.
  SleuthController.clockOverrideForTest = () => tester.binding.clock.now();
  addTearDown(() => SleuthController.clockOverrideForTest = null);
  final controller = SleuthController()..initializeDetectorsForTest();
  addTearDown(controller.dispose);
  controller.verdictNotifier.value = verdict;
  controller.issuesNotifier.value = issues;
  await tester.pumpWidget(_cardApp(controller));
  return controller;
}

Widget _cardApp(SleuthController controller) => MaterialApp(
  home: Scaffold(
    body: FloatingIssuesCard(controller: controller, onClose: () {}),
  ),
);

Widget _buildCard(
  PerformanceIssue issue, {
  bool jankCorrelated = false,
  bool highlighted = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: IssueCard(
        issue: issue,
        jankCorrelated: jankCorrelated,
        highlighted: highlighted,
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

    testWidgets('the badge stays through a verdict that names other issues, '
        'for the jank window', (tester) async {
      final cause = _testIssue(title: 'Rebuilds', stableId: 'rebuild_activity');
      final jank = _testIssue(
        title: 'Jank detected',
        stableId: 'jank_detected',
      );
      final controller = await _pumpCard(tester, [
        cause,
        jank,
      ], verdict: _testVerdict(relatedIssues: [cause]));
      expect(find.text('Jank'), findsOneWidget);

      // A raster frame names no build issue.
      controller.verdictNotifier.value = _testVerdict(
        frameNumber: 2,
        phase: PipelinePhase.raster,
      );
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Jank'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Jank'), findsNothing);
    });

    testWidgets('closing and reopening the dashboard keeps what is left of '
        'each hold', (tester) async {
      final cause = _testIssue(title: 'Rebuilds', stableId: 'rebuild_activity');
      final jank = _testIssue(
        title: 'Jank detected',
        stableId: 'jank_detected',
      );
      final controller = await _pumpCard(tester, [
        cause,
        jank,
      ], verdict: _testVerdict(relatedIssues: [cause]));
      bool causeTagged() => tester
          .widget<IssueCard>(
            find.byWidgetPredicate(
              (w) => w is IssueCard && w.issue.stableId == 'rebuild_activity',
            ),
          )
          .jankCorrelated;
      expect(causeTagged(), isTrue);

      // A raster frame names no build issue; then the dashboard closes.
      controller.verdictNotifier.value = _testVerdict(
        frameNumber: 2,
        phase: PipelinePhase.raster,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));

      await tester.pumpWidget(_cardApp(controller));
      expect(causeTagged(), isTrue);

      // The hold ends 10 s after the verdict, not 10 s after reopening.
      await tester.pump(const Duration(seconds: 4));
      expect(causeTagged(), isFalse);
    });

    testWidgets('a later verdict naming the issue restarts its hold', (
      tester,
    ) async {
      final cause = _testIssue(title: 'Rebuilds', stableId: 'rebuild_activity');
      final jank = _testIssue(
        title: 'Jank detected',
        stableId: 'jank_detected',
      );
      final controller = await _pumpCard(tester, [
        cause,
        jank,
      ], verdict: _testVerdict(relatedIssues: [cause]));

      await tester.pump(const Duration(seconds: 6));
      controller.verdictNotifier.value = _testVerdict(
        frameNumber: 2,
        relatedIssues: [cause],
      );
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Jank'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Jank'), findsNothing);
    });
  });
}
