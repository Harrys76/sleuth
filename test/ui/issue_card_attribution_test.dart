import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/issue_card.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';

PerformanceIssue _testIssue({
  IssueCategory category = IssueCategory.build,
  ObservationSource? observationSource,
  IssueSeverity severity = IssueSeverity.warning,
  IssueConfidence confidence = IssueConfidence.confirmed,
  String? ancestorChain,
  String? widgetName,
  String title = 'Test Issue',
}) {
  return PerformanceIssue(
    severity: severity,
    category: category,
    confidence: confidence,
    title: title,
    detail: 'Test detail',
    fixHint: 'Test fix',
    observationSource: observationSource,
    ancestorChain: ancestorChain,
    widgetName: widgetName,
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
  group('IssueCard category in the meta line', () {
    for (final (category, name) in [
      (IssueCategory.build, 'Build'),
      (IssueCategory.layout, 'Layout'),
      (IssueCategory.paint, 'Paint'),
      (IssueCategory.raster, 'Raster'),
      (IssueCategory.memory, 'Memory'),
      (IssueCategory.channel, 'Channel'),
      (IssueCategory.font, 'Font'),
      (IssueCategory.network, 'Network'),
      (IssueCategory.startup, 'Startup'),
    ]) {
      testWidgets('${category.name} reads $name', (tester) async {
        await tester.pumpWidget(_buildCard(_testIssue(category: category)));
        expect(find.textContaining(name), findsOneWidget);
      });
    }

    testWidgets('the line is quiet text, whatever the source', (tester) async {
      for (final source in [null, ...ObservationSource.values]) {
        await tester.pumpWidget(
          _buildCard(_testIssue(observationSource: source)),
        );
        const theme = SleuthThemeData();
        final text = tester.widget<Text>(find.textContaining('Build'));
        expect(text.style?.fontSize, theme.fontMd);
        expect(text.style?.color, theme.textTertiary);
      }
    });
  });

  group('IssueCard Where row', () {
    testWidgets('shows the widget and the location of the leaf element', (
      tester,
    ) async {
      final copies = <(String, String)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IssueCard(
                issue: _testIssue(
                  widgetName: 'FeedTile',
                  ancestorChain:
                      'MyPage > FeedList > FeedTile (feed_tile.dart:42)',
                ),
                initiallyExpanded: true,
                onCopyText: (text, confirmation) =>
                    copies.add((text, confirmation)),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Where'), findsOneWidget);
      expect(find.text('FeedTile'), findsOneWidget);
      expect(find.text('feed_tile.dart:42'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Copy location'));
      expect(copies, [('feed_tile.dart:42', 'Location copied')]);
    });

    testWidgets('shows the widget alone when the run tracks no locations', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildCard(
          _testIssue(
            widgetName: 'FeedTile',
            ancestorChain: 'MyPage > FeedTile',
          ),
          initiallyExpanded: true,
        ),
      );
      expect(find.text('Where'), findsOneWidget);
      expect(find.bySemanticsLabel('Copy location'), findsNothing);
    });

    testWidgets('is left out without a widget or a location', (tester) async {
      await tester.pumpWidget(
        _buildCard(_testIssue(), initiallyExpanded: true),
      );
      expect(find.text('Where'), findsNothing);
      expect(find.text('Evidence'), findsOneWidget);
    });

    testWidgets('a collapsed card shows no detail rows', (tester) async {
      await tester.pumpWidget(_buildCard(_testIssue(widgetName: 'FeedTile')));
      expect(find.text('Where'), findsNothing);
      expect(find.text('Evidence'), findsNothing);
    });
  });

  group('IssueCard edge cases', () {
    testWidgets('empty fixHint does not crash when expanded', (tester) async {
      final issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Test',
        detail: 'Detail',
        fixHint: '',
      );

      await tester.pumpWidget(_buildCard(issue, initiallyExpanded: true));

      // Should render without crash
      expect(find.text('Detail'), findsOneWidget);
    });
  });
}
