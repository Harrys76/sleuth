import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/ui/issue_card.dart';

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
  group('IssueCard left border accent (R1)', () {
    testWidgets('vmTimeline source shows green accent', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(observationSource: ObservationSource.vmTimeline),
      ));

      // Find the accent strip — a Container(width:3) with the green color
      final containers = tester.widgetList<Container>(find.byType(Container));
      final accent = containers.where((c) {
        final constraints = c.constraints;
        if (constraints == null) return false;
        return constraints.maxWidth == 3 &&
            constraints.minWidth == 3 &&
            c.color == const Color(0xFF10B981);
      });
      expect(accent, isNotEmpty);
    });

    testWidgets('debugCallback source shows purple accent', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(observationSource: ObservationSource.debugCallback),
      ));

      final containers = tester.widgetList<Container>(find.byType(Container));
      final accent = containers.where((c) {
        final constraints = c.constraints;
        if (constraints == null) return false;
        return constraints.maxWidth == 3 &&
            constraints.minWidth == 3 &&
            c.color == const Color(0xFF8B5CF6);
      });
      expect(accent, isNotEmpty);
    });

    testWidgets('debugCallbackAndStructural source shows purple accent',
        (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(
            observationSource: ObservationSource.debugCallbackAndStructural),
      ));

      final containers = tester.widgetList<Container>(find.byType(Container));
      final accent = containers.where((c) {
        final constraints = c.constraints;
        if (constraints == null) return false;
        return constraints.maxWidth == 3 &&
            constraints.minWidth == 3 &&
            c.color == const Color(0xFF8B5CF6);
      });
      expect(accent, isNotEmpty);
    });

    testWidgets('structural source shows gray accent', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(observationSource: ObservationSource.structural),
      ));

      final containers = tester.widgetList<Container>(find.byType(Container));
      final accent = containers.where((c) {
        final constraints = c.constraints;
        if (constraints == null) return false;
        return constraints.maxWidth == 3 &&
            constraints.minWidth == 3 &&
            c.color == const Color(0xFF6B7280);
      });
      expect(accent, isNotEmpty);
    });

    testWidgets('null source shows subtle gray accent', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(observationSource: null),
      ));

      final containers = tester.widgetList<Container>(find.byType(Container));
      final accent = containers.where((c) {
        final constraints = c.constraints;
        if (constraints == null) return false;
        return constraints.maxWidth == 3 &&
            constraints.minWidth == 3 &&
            c.color == const Color(0xFF4B5563);
      });
      expect(accent, isNotEmpty);
    });

    testWidgets('accent visible when card is collapsed', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(observationSource: ObservationSource.vmTimeline),
      ));

      // Card is collapsed by default — accent should still be present
      expect(find.text('Test detail'), findsNothing); // collapsed
      final containers = tester.widgetList<Container>(find.byType(Container));
      final accent = containers.where((c) {
        final constraints = c.constraints;
        if (constraints == null) return false;
        return constraints.maxWidth == 3 && constraints.minWidth == 3;
      });
      expect(accent, isNotEmpty);
    });
  });

  group('IssueCard category badge (R2)', () {
    testWidgets('build category shows BUILD badge', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(category: IssueCategory.build),
      ));
      expect(find.text('BUILD'), findsOneWidget);
    });

    testWidgets('layout category shows LAYOUT badge', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(category: IssueCategory.layout),
      ));
      expect(find.text('LAYOUT'), findsOneWidget);
    });

    testWidgets('paint category shows PAINT badge', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(category: IssueCategory.paint),
      ));
      expect(find.text('PAINT'), findsOneWidget);
    });

    testWidgets('raster category shows RASTER badge', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(category: IssueCategory.raster),
      ));
      expect(find.text('RASTER'), findsOneWidget);
    });

    testWidgets('memory category shows MEMORY badge', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(category: IssueCategory.memory),
      ));
      expect(find.text('MEMORY'), findsOneWidget);
    });

    testWidgets('channel category shows CHANNEL badge', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(category: IssueCategory.channel),
      ));
      expect(find.text('CHANNEL'), findsOneWidget);
    });

    testWidgets('font category shows FONT badge', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(category: IssueCategory.font),
      ));
      expect(find.text('FONT'), findsOneWidget);
    });

    testWidgets('category badge has correct font size and weight',
        (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(category: IssueCategory.build),
      ));

      final textWidget = tester.widget<Text>(find.text('BUILD'));
      expect(textWidget.style?.fontSize, 8);
      expect(textWidget.style?.fontWeight, FontWeight.bold);
    });
  });

  group('IssueCard ancestor chain display (R6)', () {
    testWidgets('expanded card with ancestorChain shows Widget: line',
        (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(ancestorChain: 'MyPage > Column > Image'),
        initiallyExpanded: true,
      ));

      expect(
        find.text('Widget: MyPage > Column > Image'),
        findsOneWidget,
      );
    });

    testWidgets(
        'expanded card with null chain but widgetName not in title shows Widget: fallback',
        (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(
          widgetName: 'MyCustomWidget',
          title: 'Some Other Issue',
        ),
        initiallyExpanded: true,
      ));

      expect(find.text('Widget: MyCustomWidget'), findsOneWidget);
    });

    testWidgets(
        'expanded card with null chain and widgetName in title does not show duplicate',
        (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(
          widgetName: 'MyWidget',
          title: 'Excessive Rebuilds: MyWidget (15/sec)',
        ),
        initiallyExpanded: true,
      ));

      expect(find.textContaining('Widget: MyWidget'), findsNothing);
    });

    testWidgets('collapsed card does not show Widget: line', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(ancestorChain: 'MyPage > Column > Image'),
      ));

      // Card is collapsed by default
      expect(find.text('Test detail'), findsNothing);
      expect(
        find.text('Widget: MyPage > Column > Image'),
        findsNothing,
      );
    });

    testWidgets('ancestor chain text has correct style', (tester) async {
      await tester.pumpWidget(_buildCard(
        _testIssue(ancestorChain: 'MyPage > Column > Image'),
        initiallyExpanded: true,
      ));

      final textWidget = tester.widget<Text>(
        find.text('Widget: MyPage > Column > Image'),
      );
      expect(textWidget.style?.fontSize, 10);
      expect(textWidget.style?.fontStyle, FontStyle.italic);
      expect(textWidget.style?.color, const Color(0xFF9CA3AF));
    });
  });
}
