import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/ranking/issue_ranker.dart';
import 'package:widget_watchdog/src/ui/dashboard_sheet.dart';
import 'package:widget_watchdog/src/ui/issue_card.dart';

PerformanceIssue _testIssue({
  String title = 'Test Issue',
  String? stableId,
  IssueSeverity severity = IssueSeverity.warning,
  IssueConfidence confidence = IssueConfidence.confirmed,
  IssueCategory category = IssueCategory.build,
  String? widgetName,
  String? ancestorChain,
  String fixHint = 'Some fix hint',
  ObservationSource? observationSource,
  InteractionContext? interactionContext,
}) {
  return PerformanceIssue(
    severity: severity,
    category: category,
    confidence: confidence,
    title: title,
    detail: 'Detail',
    fixHint: fixHint,
    stableId: stableId ?? title,
    widgetName: widgetName,
    ancestorChain: ancestorChain,
    observationSource: observationSource,
    interactionContext: interactionContext,
  );
}

Widget _buildCard(
  PerformanceIssue issue, {
  bool initiallyExpanded = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: IssueCard(
        issue: issue,
        initiallyExpanded: initiallyExpanded,
      ),
    ),
  );
}

void main() {
  group('Widget name ordering (3.8.1)', () {
    testWidgets('widgetName shown before ancestorChain when both present',
        (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(
          widgetName: 'MyImage',
          ancestorChain: 'MyPage > Column > MyImage',
          title: 'Large Image',
        ),
        initiallyExpanded: true,
      ));

      expect(find.text('Widget: MyImage'), findsOneWidget);
      expect(
        find.text('Ancestors: MyPage > Column > MyImage'),
        findsOneWidget,
      );
    });

    testWidgets('widgetName shown alone when no ancestorChain', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(
          widgetName: 'MyWidget',
          title: 'Some Issue',
        ),
        initiallyExpanded: true,
      ));

      expect(find.text('Widget: MyWidget'), findsOneWidget);
      expect(find.textContaining('Ancestors:'), findsNothing);
    });

    testWidgets('ancestorChain hidden when equal to widgetName',
        (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(
          widgetName: 'MyWidget',
          ancestorChain: 'MyWidget',
          title: 'Some Issue',
        ),
        initiallyExpanded: true,
      ));

      expect(find.text('Widget: MyWidget'), findsOneWidget);
      // Ancestors line suppressed because it matches widgetName
      expect(find.textContaining('Ancestors:'), findsNothing);
    });
  });

  group('Effort indicators (3.8.5)', () {
    testWidgets('Quick effort badge for ListView.builder keyword',
        (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(
            fixHint:
                'Use ListView.builder() to lazily build visible items only.'),
        initiallyExpanded: true,
      ));

      expect(find.text('QUICK FIX'), findsOneWidget);
    });

    testWidgets('Involved effort badge for Isolate keyword', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(
            fixHint:
                'Move heavy work to a background isolate using Isolate.run().'),
        initiallyExpanded: true,
      ));

      expect(find.text('INVOLVED FIX'), findsOneWidget);
    });

    testWidgets('Medium effort badge as default', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(fixHint: 'Consider refactoring this code path.'),
        initiallyExpanded: true,
      ));

      expect(find.text('MEDIUM FIX'), findsOneWidget);
    });

    testWidgets('Explicit fixEffort takes precedence over keyword inference',
        (tester) async {
      // fixHint contains "ListView.builder" (quick keyword) but model says involved
      await tester.pumpWidget(_buildCard(
        PerformanceIssue(
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          title: 'Test',
          detail: 'Detail',
          fixHint: 'Use ListView.builder() for this list.',
          stableId: 'test',
          fixEffort: FixEffort.involved,
        ),
        initiallyExpanded: true,
      ));

      // Model fixEffort (involved) wins over keyword (quick)
      expect(find.text('INVOLVED FIX'), findsOneWidget);
      expect(find.text('QUICK FIX'), findsNothing);
    });
  });

  group('About this detection (3.8.4)', () {
    testWidgets('About section toggle visible when card expanded',
        (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(observationSource: ObservationSource.vmTimeline),
        initiallyExpanded: true,
      ));

      expect(find.text('About this detection'), findsOneWidget);
      // Content not shown yet
      expect(find.textContaining('Based on:'), findsNothing);
    });

    testWidgets('About section shows content on tap', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(
          observationSource: ObservationSource.vmTimeline,
          confidence: IssueConfidence.confirmed,
          category: IssueCategory.build,
        ),
        initiallyExpanded: true,
      ));

      // Tap "About this detection"
      await tester.tap(find.text('About this detection'));
      await tester.pumpAndSettle();

      // All content rows should appear
      expect(find.textContaining('Based on:'), findsOneWidget);
      expect(find.textContaining('Confidence:'), findsOneWidget);
      expect(find.textContaining('Accuracy:'), findsOneWidget);
      expect(find.textContaining('Verify with:'), findsOneWidget);
    });
  });

  group('Highlight not-found feedback (3.8.2)', () {
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

    testWidgets('banner shown when highlight not found', (tester) async {
      // Issue with widgetName (locatable) but no matching highlight in tree
      final issue = _testIssue(
        title: 'Large Image',
        stableId: 'large-image',
        widgetName: 'MyImage',
        category: IssueCategory.build,
      );
      controller.issuesNotifier.value = [issue];

      await tester.pumpWidget(buildDashboard());

      // Navigate to Issues tab
      await tester.tap(find.text('Issues'));
      await tester.pumpAndSettle();

      // Find and tap the checkbox (highlight toggle)
      final checkboxes = find.byType(Checkbox);
      expect(checkboxes, findsOneWidget);
      await tester.tap(checkboxes);
      await tester.pump();

      // Banner should appear
      expect(
        find.text(
            'Widget not currently visible. Navigate to the screen where this issue occurs.'),
        findsOneWidget,
      );

      // Drain the 3-second timer
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('banner clears after 3 seconds', (tester) async {
      final issue = _testIssue(
        title: 'Large Image',
        stableId: 'large-image',
        widgetName: 'MyImage',
        category: IssueCategory.build,
      );
      controller.issuesNotifier.value = [issue];

      await tester.pumpWidget(buildDashboard());

      // Navigate to Issues tab and tap highlight
      await tester.tap(find.text('Issues'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pump();

      // Banner visible
      expect(
          find.textContaining('Widget not currently visible'), findsOneWidget);

      // Wait 4 seconds — banner should clear
      await tester.pump(const Duration(seconds: 4));

      expect(find.textContaining('Widget not currently visible'), findsNothing);
    });
  });

  group('Interaction context filter (3.8.3)', () {
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

    testWidgets('filter chips visible on Issues tab', (tester) async {
      controller.issuesNotifier.value = [_testIssue()];

      await tester.pumpWidget(buildDashboard());
      await tester.tap(find.text('Issues'));
      await tester.pumpAndSettle();

      expect(find.textContaining('All'), findsOneWidget);
      expect(find.textContaining('Idle'), findsOneWidget);
      expect(find.textContaining('Scrolling'), findsOneWidget);
      expect(find.textContaining('Navigating'), findsOneWidget);
    });

    testWidgets('filtering by Scrolling shows only scrolling issues',
        (tester) async {
      final idleIssue = _testIssue(
        title: 'Idle Issue',
        stableId: 'idle',
        interactionContext: InteractionContext.idle,
      );
      final scrollingIssue = _testIssue(
        title: 'Scrolling Issue',
        stableId: 'scrolling',
        interactionContext: InteractionContext.scrolling,
      );

      controller.issuesNotifier.value = [idleIssue, scrollingIssue];

      await tester.pumpWidget(buildDashboard());
      await tester.tap(find.text('Issues'));
      await tester.pumpAndSettle();

      // Both visible by default
      expect(find.text('Idle Issue'), findsOneWidget);
      expect(find.text('Scrolling Issue'), findsOneWidget);

      // Tap "Scrolling" filter chip (not the issue title)
      await tester.tap(find.textContaining(RegExp(r'^Scrolling \(')));
      await tester.pump();

      // Only scrolling issue visible
      expect(find.text('Idle Issue'), findsNothing);
      expect(find.text('Scrolling Issue'), findsOneWidget);
    });

    test('scrolling deprioritization in ranker', () {
      const ranker = IssueRanker();
      const ctx = IssueRankingContext(
        recurrenceCounts: {'idle-issue': 5, 'scroll-issue': 5},
      );

      final idleIssue = _testIssue(
        title: 'Idle Issue',
        stableId: 'idle-issue',
        interactionContext: InteractionContext.idle,
      );
      final scrollIssue = _testIssue(
        title: 'Scroll Issue',
        stableId: 'scroll-issue',
        interactionContext: InteractionContext.scrolling,
      );

      final idleScore = ranker.scoreOf(idleIssue, ctx);
      final scrollScore = ranker.scoreOf(scrollIssue, ctx);

      // Idle issue should score higher (scrolling gets 0.7× recurrence)
      expect(idleScore, greaterThan(scrollScore));
    });
  });

  group('Color legend (3.8.6)', () {
    testWidgets('legend visible on Guide tab', (tester) async {
      final controller = WatchdogController();
      controller.initializeDetectorsForTest();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DashboardSheet(controller: controller, onClose: () {}),
        ),
      ));

      // Navigate to Guide tab
      await tester.tap(find.text('Guide'));
      await tester.pumpAndSettle();

      // Color Legend section visible
      expect(find.text('Color Legend'), findsOneWidget);

      // Severity section
      expect(find.textContaining('Critical'), findsOneWidget);
      expect(find.textContaining('Warning'), findsOneWidget);

      // Confidence badges
      expect(find.text('CONFIRMED'), findsOneWidget);
      expect(find.text('LIKELY'), findsOneWidget);
      expect(find.text('POSSIBLE'), findsOneWidget);

      // Source accents
      expect(find.text('VM timeline event'), findsOneWidget);
      expect(find.text('Debug callback'), findsOneWidget);
      expect(find.text('Structural scan'), findsOneWidget);

      // Category badges
      expect(find.text('BUILD'), findsOneWidget);
      expect(find.text('LAYOUT'), findsOneWidget);
      expect(find.text('NETWORK'), findsOneWidget);

      // Effort badges
      expect(find.text('QUICK FIX'), findsOneWidget);
      expect(find.text('MEDIUM FIX'), findsOneWidget);
      expect(find.text('INVOLVED FIX'), findsOneWidget);

      controller.dispose();
    });
  });
}
