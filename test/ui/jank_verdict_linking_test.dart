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
}) {
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
  bool jankFlash = false,
  bool highlighted = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: IssueCard(
        issue: issue,
        jankCorrelated: jankCorrelated,
        jankFlash: jankFlash,
        highlighted: highlighted,
      ),
    ),
  );
}

void main() {
  group('JANK badge on issue cards', () {
    testWidgets('badge shown when jankCorrelated is true', (tester) async {
      await tester.pumpWidget(
        _buildCard(_testIssue(), jankCorrelated: true),
      );
      expect(find.text('JANK'), findsOneWidget);
    });

    testWidgets('badge absent when jankCorrelated is false', (tester) async {
      await tester.pumpWidget(
        _buildCard(_testIssue(), jankCorrelated: false),
      );
      expect(find.text('JANK'), findsNothing);
    });

    testWidgets('badge in card — only on matching issues', (tester) async {
      final issue1 = _testIssue(title: 'Matched', stableId: 'matched');
      final issue2 = _testIssue(title: 'Unmatched', stableId: 'unmatched');

      final controller = SleuthController();
      controller.initializeDetectorsForTest();

      controller.verdictNotifier.value =
          _testVerdict(relatedIssues: [issue1]); // only issue1
      controller.issuesNotifier.value = [issue1, issue2]; // both

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FloatingIssuesCard(controller: controller, onClose: () {}),
        ),
      ));

      // JANK badge should appear once (only on matched issue)
      expect(find.text('JANK'), findsOneWidget);

      controller.dispose();
    });
  });

  group('Edge cases', () {
    testWidgets('flash takes precedence over locate-highlight', (tester) async {
      // Both jankFlash and highlighted true — flash wins
      await tester.pumpWidget(
        _buildCard(
          _testIssue(),
          jankFlash: true,
          highlighted: true,
        ),
      );

      final cards = tester.widgetList<Card>(find.byType(Card));
      final flashCards = cards.where((c) => c.color == const Color(0xFF5F2D1E));
      expect(flashCards, isNotEmpty);

      // Blue locate-highlight should NOT be present
      final blueCards = cards.where((c) => c.color == const Color(0xFF1E3A5F));
      expect(blueCards, isEmpty);
    });
  });
}
