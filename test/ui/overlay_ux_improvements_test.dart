import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ranking/issue_ranker.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/issue_card.dart';

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

Widget _buildCard(PerformanceIssue issue, {bool initiallyExpanded = false}) {
  return MaterialApp(
    home: Scaffold(
      body: IssueCard(issue: issue, initiallyExpanded: initiallyExpanded),
    ),
  );
}

void main() {
  group('Fix block', () {
    Future<void> pumpFix(
      WidgetTester tester,
      PerformanceIssue issue, {
      List<(String, String)>? copies,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: IssueCard(
              issue: issue,
              initiallyExpanded: true,
              onCopyText: copies == null
                  ? null
                  : (text, confirmation) => copies.add((text, confirmation)),
            ),
          ),
        ),
      ),
    );

    for (final (effort, label) in [
      (FixEffort.quick, 'FIX · QUICK'),
      (FixEffort.medium, 'FIX · MEDIUM EFFORT'),
      (FixEffort.involved, 'FIX · INVOLVED'),
    ]) {
      testWidgets('the label names a ${effort.name} fix', (tester) async {
        await pumpFix(tester, _testIssue().copyWith(fixEffort: effort));
        expect(find.text(label), findsOneWidget);
      });
    }

    testWidgets('without an effort the label says Fix alone', (tester) async {
      await pumpFix(tester, _testIssue());
      expect(find.text('FIX'), findsOneWidget);
    });

    testWidgets('code after a colon sits in a code block with Copy code', (
      tester,
    ) async {
      final copies = <(String, String)>[];
      await pumpFix(
        tester,
        _testIssue(
          fixHint:
              'Move it off the UI isolate:\n'
              'final result = await Isolate.run(() => parse(data));\n'
              'Or split the work.',
        ),
        copies: copies,
      );
      expect(find.text('Move it off the UI isolate:'), findsOneWidget);
      expect(
        find.text('final result = await Isolate.run(() => parse(data));'),
        findsOneWidget,
      );
      expect(find.text('Or split the work.'), findsOneWidget);
      expect(find.text('Dart'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Copy code'));
      expect(copies, [
        ('final result = await Isolate.run(() => parse(data));', 'Code copied'),
      ]);
    });

    testWidgets('a command is labelled Terminal', (tester) async {
      await pumpFix(
        tester,
        _testIssue(fixHint: 'Run in profile mode:\nflutter run --profile'),
      );
      expect(find.text('Terminal'), findsOneWidget);
    });
  });

  group('Evidence and Check in', () {
    testWidgets('Evidence gives the reason and the confidence', (tester) async {
      await tester.pumpWidget(
        _buildCard(
          _testIssue(
            confidence: IssueConfidence.likely,
          ).copyWith(confidenceReason: 'Rebuild evidence and a subtree scan'),
          initiallyExpanded: true,
        ),
      );
      expect(
        find.text(
          'Rebuild evidence and a subtree scan. Sleuth rates it likely, not '
          'confirmed.',
        ),
        findsOneWidget,
      );
      expect(find.text('About this detection'), findsNothing);
    });

    testWidgets('without a reason Evidence names the data source', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildCard(
          _testIssue(observationSource: ObservationSource.vmTimeline),
          initiallyExpanded: true,
        ),
      );
      expect(
        find.text('From the VM timeline. Sleuth rates it confirmed.'),
        findsOneWidget,
      );
    });

    testWidgets('Check in names the DevTools view for the category', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildCard(
          _testIssue(category: IssueCategory.raster),
          initiallyExpanded: true,
        ),
      );
      expect(
        find.text('DevTools › Performance › Raster Stats'),
        findsOneWidget,
      );
    });
  });

  group('Highlight not-found feedback (3.8.2)', () {
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
            isDebugMode: false,
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
      // A scan already ran and outlined nothing.
      controller.scanTickNotifier.value = 1;

      await tester.pumpWidget(buildCard());

      // Find and tap the crosshair (highlight toggle)
      final crosshairs = find.byIcon(Icons.my_location);
      expect(crosshairs, findsOneWidget);
      await tester.tap(crosshairs);
      await tester.pump();

      // Banner should appear
      expect(
        find.text(
          'Widget not currently visible. Navigate to the screen where this issue occurs.',
        ),
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
      // A scan already ran and outlined nothing.
      controller.scanTickNotifier.value = 1;

      await tester.pumpWidget(buildCard());

      // Tap the crosshair
      await tester.tap(find.byIcon(Icons.my_location));
      await tester.pump();

      // Banner visible
      expect(
        find.textContaining('Widget not currently visible'),
        findsOneWidget,
      );

      // Wait 4 seconds — banner should clear after its fade-out.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('Widget not currently visible'), findsNothing);
      // Semantics on would triple the display time.
    }, semanticsEnabled: false);
  });

  group('Interaction context scoring (3.8.3)', () {
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
}
