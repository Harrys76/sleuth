import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/models/frame_verdict.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/ui/dashboard_sheet.dart';
import 'package:widget_watchdog/src/ui/issue_card.dart';

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
  group('Jank banner visibility', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    Widget buildDashboard() {
      return MaterialApp(
        home: Scaffold(
          body: DashboardSheet(
            controller: controller,
            onClose: () {},
          ),
        ),
      );
    }

    testWidgets('no banner when verdict is null', (tester) async {
      await tester.pumpWidget(buildDashboard());
      expect(find.textContaining('causing jank'), findsNothing);
    });

    testWidgets('no banner when relatedIssues empty', (tester) async {
      controller.verdictNotifier.value = _testVerdict(relatedIssues: const []);
      await tester.pumpWidget(buildDashboard());
      expect(find.textContaining('causing jank'), findsNothing);
    });

    testWidgets('no banner when relatedIssues dont match current issues',
        (tester) async {
      final issueA = _testIssue(title: 'Issue A', stableId: 'a');
      final issueB = _testIssue(title: 'Issue B', stableId: 'b');

      controller.verdictNotifier.value = _testVerdict(relatedIssues: [issueA]);
      controller.issuesNotifier.value = [issueB];

      await tester.pumpWidget(buildDashboard());
      expect(find.textContaining('causing jank'), findsNothing);
    });

    testWidgets('banner shown when verdict has matching relatedIssues',
        (tester) async {
      final issue = _testIssue(title: 'Rebuild', stableId: 'rebuild');

      controller.verdictNotifier.value = _testVerdict(relatedIssues: [issue]);
      controller.issuesNotifier.value = [issue];

      await tester.pumpWidget(buildDashboard());
      expect(find.textContaining('causing jank'), findsOneWidget);
      expect(find.textContaining('View Issues'), findsOneWidget);
    });

    testWidgets('correct pluralization — singular and plural', (tester) async {
      final issue1 = _testIssue(title: 'Issue 1', stableId: 'i1');
      final issue2 = _testIssue(title: 'Issue 2', stableId: 'i2');

      // Singular
      controller.verdictNotifier.value = _testVerdict(relatedIssues: [issue1]);
      controller.issuesNotifier.value = [issue1];
      await tester.pumpWidget(buildDashboard());
      expect(find.text('1 issue may be causing jank'), findsOneWidget);

      // Plural
      controller.verdictNotifier.value =
          _testVerdict(relatedIssues: [issue1, issue2]);
      controller.issuesNotifier.value = [issue1, issue2];
      await tester.pump();
      expect(find.text('2 issues may be causing jank'), findsOneWidget);
    });
  });

  group('Banner tap behavior', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    Widget buildDashboard() {
      return MaterialApp(
        home: Scaffold(
          body: DashboardSheet(
            controller: controller,
            onClose: () {},
          ),
        ),
      );
    }

    testWidgets('tapping banner switches to Issues tab', (tester) async {
      final issue =
          _testIssue(title: 'Rebuild', stableId: 'rebuild', widgetName: 'Foo');

      controller.verdictNotifier.value = _testVerdict(relatedIssues: [issue]);
      controller.issuesNotifier.value = [issue];

      await tester.pumpWidget(buildDashboard());

      // Tap the banner
      await tester.tap(find.textContaining('causing jank'));
      await tester.pumpAndSettle();

      // Issue card should now be visible (Issues tab)
      expect(find.text('Rebuild'), findsOneWidget);

      // Drain the 2-second flash timer
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('tapping banner activates flash on matching cards',
        (tester) async {
      final issue = _testIssue(title: 'Rebuild', stableId: 'rebuild');

      controller.verdictNotifier.value = _testVerdict(relatedIssues: [issue]);
      controller.issuesNotifier.value = [issue];

      await tester.pumpWidget(buildDashboard());

      // Tap banner
      await tester.tap(find.textContaining('causing jank'));
      await tester.pumpAndSettle();

      // Card should have the amber flash color (0xFF5F2D1E)
      final cards = tester.widgetList<Card>(find.byType(Card));
      final issueCard = cards.where((c) => c.color == const Color(0xFF5F2D1E));
      expect(issueCard, isNotEmpty);

      // Drain the 2-second flash timer
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('flash clears after 2 seconds', (tester) async {
      final issue = _testIssue(title: 'Rebuild', stableId: 'rebuild');

      controller.verdictNotifier.value = _testVerdict(relatedIssues: [issue]);
      controller.issuesNotifier.value = [issue];

      await tester.pumpWidget(buildDashboard());

      // Tap banner and navigate
      await tester.tap(find.textContaining('causing jank'));
      await tester.pumpAndSettle();

      // Flash present
      var cards = tester.widgetList<Card>(find.byType(Card));
      expect(
        cards.where((c) => c.color == const Color(0xFF5F2D1E)),
        isNotEmpty,
      );

      // Wait 3 seconds — flash should clear
      await tester.pump(const Duration(seconds: 3));

      // Card should be back to normal gray
      cards = tester.widgetList<Card>(find.byType(Card));
      final flashCards = cards.where((c) => c.color == const Color(0xFF5F2D1E));
      expect(flashCards, isEmpty);
    });
  });

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

    testWidgets('badge in dashboard — only on matching issues', (tester) async {
      final issue1 = _testIssue(title: 'Matched', stableId: 'matched');
      final issue2 = _testIssue(title: 'Unmatched', stableId: 'unmatched');

      final controller = WatchdogController();
      controller.initializeDetectorsForTest();

      controller.verdictNotifier.value =
          _testVerdict(relatedIssues: [issue1]); // only issue1
      controller.issuesNotifier.value = [issue1, issue2]; // both

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DashboardSheet(controller: controller, onClose: () {}),
        ),
      ));

      // Navigate to Issues tab
      await tester.tap(find.text('Issues'));
      await tester.pumpAndSettle();

      // JANK badge should appear once (only on matched issue)
      expect(find.text('JANK'), findsOneWidget);

      controller.dispose();
    });

    testWidgets('banner only on Live tab, not Issues or Guide', (tester) async {
      final issue = _testIssue(title: 'Rebuild', stableId: 'rebuild');

      final controller = WatchdogController();
      controller.initializeDetectorsForTest();

      controller.verdictNotifier.value = _testVerdict(relatedIssues: [issue]);
      controller.issuesNotifier.value = [issue];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DashboardSheet(controller: controller, onClose: () {}),
        ),
      ));

      // Banner visible on Live tab (default)
      expect(find.textContaining('causing jank'), findsOneWidget);

      // Switch to Issues tab — banner should not be here
      await tester.tap(find.text('Issues'));
      await tester.pumpAndSettle();
      expect(find.textContaining('causing jank'), findsNothing);

      // Switch to Guide tab — banner should not be here
      await tester.tap(find.text('Guide'));
      await tester.pumpAndSettle();
      expect(find.textContaining('causing jank'), findsNothing);

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

    testWidgets('banner disappears when verdict clears relatedIssues',
        (tester) async {
      final issue = _testIssue(title: 'Rebuild', stableId: 'rebuild');

      final controller = WatchdogController();
      controller.initializeDetectorsForTest();

      controller.verdictNotifier.value = _testVerdict(relatedIssues: [issue]);
      controller.issuesNotifier.value = [issue];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DashboardSheet(controller: controller, onClose: () {}),
        ),
      ));

      // Banner initially visible
      expect(find.textContaining('causing jank'), findsOneWidget);

      // Clear related issues
      controller.verdictNotifier.value = _testVerdict(relatedIssues: const []);
      await tester.pump();

      // Banner should be gone
      expect(find.textContaining('causing jank'), findsNothing);

      controller.dispose();
    });
  });
}
