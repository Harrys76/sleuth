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

  group('IssueCard ancestor chain display', () {
    testWidgets('expanded card with ancestorChain shows Ancestors: line', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildCard(
          _testIssue(ancestorChain: 'MyPage > Column > Image'),
          initiallyExpanded: true,
        ),
      );

      expect(find.text('Ancestors: MyPage > Column > Image'), findsOneWidget);
    });

    testWidgets(
      'expanded card with null chain but widgetName not in title shows Widget: fallback',
      (tester) async {
        await tester.pumpWidget(
          _buildCard(
            _testIssue(widgetName: 'MyCustomWidget', title: 'Some Other Issue'),
            initiallyExpanded: true,
          ),
        );

        expect(find.text('Widget: MyCustomWidget'), findsOneWidget);
      },
    );

    testWidgets(
      'expanded card with null chain and widgetName in title does not show duplicate',
      (tester) async {
        await tester.pumpWidget(
          _buildCard(
            _testIssue(
              widgetName: 'MyWidget',
              title: 'Excessive Rebuilds: MyWidget (15/sec)',
            ),
            initiallyExpanded: true,
          ),
        );

        expect(find.textContaining('Widget: MyWidget'), findsNothing);
      },
    );

    testWidgets('collapsed card does not show Ancestors: line', (tester) async {
      await tester.pumpWidget(
        _buildCard(_testIssue(ancestorChain: 'MyPage > Column > Image')),
      );

      // Card is collapsed by default
      expect(find.text('Test detail'), findsNothing);
      expect(find.text('Ancestors: MyPage > Column > Image'), findsNothing);
    });

    testWidgets('ancestor chain text has correct style', (tester) async {
      await tester.pumpWidget(
        _buildCard(
          _testIssue(ancestorChain: 'MyPage > Column > Image'),
          initiallyExpanded: true,
        ),
      );

      final textWidget = tester.widget<Text>(
        find.text('Ancestors: MyPage > Column > Image'),
      );
      expect(textWidget.style?.fontSize, 10);
      expect(textWidget.style?.fontStyle, FontStyle.italic);
      expect(textWidget.style?.color, const SleuthThemeData().textTertiary);
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
