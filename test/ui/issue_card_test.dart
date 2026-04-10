import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/recurrence_trend.dart';
import 'package:sleuth/src/ui/issue_card.dart';

PerformanceIssue _testIssue({
  IssueCategory category = IssueCategory.build,
  IssueSeverity severity = IssueSeverity.warning,
  IssueConfidence confidence = IssueConfidence.confirmed,
  String? confidenceReason,
  String title = 'Test Issue',
  String detail = 'Test detail',
  String fixHint = 'Test fix',
}) {
  return PerformanceIssue(
    severity: severity,
    category: category,
    confidence: confidence,
    confidenceReason: confidenceReason,
    title: title,
    detail: detail,
    fixHint: fixHint,
  );
}

Widget _pumpIssueCard(
  PerformanceIssue issue, {
  bool initiallyExpanded = false,
  RecurrenceTrend? recurrenceTrend,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: IssueCard(
          issue: issue,
          initiallyExpanded: initiallyExpanded,
          recurrenceTrend: recurrenceTrend,
        ),
      ),
    ),
  );
}

/// Build a trend where all entries are present with constant severity.
/// Produces TrendDirection.stable with ratio = 1.0 when all present.
RecurrenceTrend _stableTrend(int presentCount, int totalLength) {
  final trend = RecurrenceTrend(capacity: totalLength);
  // Present entries first, absent entries last
  for (var i = 0; i < totalLength; i++) {
    if (i < totalLength - presentCount) {
      trend.recordAbsent(i);
    } else {
      trend.recordPresent(i, severityIndex: 2);
    }
  }
  return trend;
}

void main() {
  group('M5: Inline confidence reasoning', () {
    testWidgets('expanded card with non-null confidenceReason shows text',
        (tester) async {
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(
          confidence: IssueConfidence.confirmed,
          confidenceReason: 'Measured directly from VM timeline',
        ),
        initiallyExpanded: true,
      ));

      expect(
        find.text('Measured directly from VM timeline'),
        findsOneWidget,
      );
    });

    testWidgets('expanded card with null confidenceReason hides row',
        (tester) async {
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(confidenceReason: null),
        initiallyExpanded: true,
      ));

      // The confidence reason row uses an italic style with fontSize 11.
      // Ensure no such text exists (there's no reason to show).
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.style?.fontStyle == FontStyle.italic &&
              w.style?.fontSize == 11,
        ),
        findsNothing,
      );
    });

    testWidgets('collapsed card does not show confidenceReason',
        (tester) async {
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(
          confidenceReason: 'Should not be visible when collapsed',
        ),
        initiallyExpanded: false,
      ));

      expect(
        find.text('Should not be visible when collapsed'),
        findsNothing,
      );
    });

    testWidgets('icon matches confidence level', (tester) async {
      // Test confirmed → check_circle_outline
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(
          confidence: IssueConfidence.confirmed,
          confidenceReason: 'Confirmed reason',
        ),
        initiallyExpanded: true,
      ));

      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);

      // Test likely → help_outline
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(
          confidence: IssueConfidence.likely,
          confidenceReason: 'Likely reason',
        ),
        initiallyExpanded: true,
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.help_outline), findsOneWidget);

      // Test possible → info_outline
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(
          confidence: IssueConfidence.possible,
          confidenceReason: 'Possible reason',
        ),
        initiallyExpanded: true,
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.info_outline), findsOneWidget);
    });

    testWidgets('confidence badge uses Semantics instead of Tooltip',
        (tester) async {
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(
          confidenceReason: 'This is the reason',
        ),
        initiallyExpanded: false,
      ));

      // Tooltip was removed (crashes in bare Overlay — no _RenderTheaterMarker).
      // Confidence reason is shown inline when expanded (M5) and as a
      // Semantics label for accessibility.
      expect(find.byType(Tooltip), findsNothing);

      // Verify the Semantics widget carries the reason text.
      final semanticsFinder = find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label != null &&
            w.properties.label!.contains('This is the reason'),
      );
      expect(semanticsFinder, findsOneWidget);
    });
  });

  group('M3: Recurrence badge', () {
    testWidgets('stable trend with ratio >= 0.9 shows "persistent"',
        (tester) async {
      // All 60 present with constant severity → stable, ratio = 1.0
      final trend = _stableTrend(54, 60);
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(),
        recurrenceTrend: trend,
      ));

      expect(find.textContaining('Seen'), findsOneWidget);
      expect(find.textContaining('persistent'), findsOneWidget);
    });

    testWidgets('stable trend below 0.9 shows "stable"', (tester) async {
      // 10 present out of 60 with constant severity → stable, ratio < 0.9
      final trend = _stableTrend(10, 60);
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(),
        recurrenceTrend: trend,
      ));

      expect(find.textContaining('Seen'), findsOneWidget);
      expect(find.textContaining('stable'), findsOneWidget);
    });

    testWidgets('intermittent trend shows "flaky"', (tester) async {
      // Alternating present/absent → >= 3 transitions → intermittent
      final trend = RecurrenceTrend(capacity: 10);
      for (var i = 0; i < 10; i++) {
        if (i.isEven) {
          trend.recordPresent(i, severityIndex: 2);
        } else {
          trend.recordAbsent(i);
        }
      }
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(),
        recurrenceTrend: trend,
      ));

      expect(find.textContaining('Seen'), findsOneWidget);
      expect(find.textContaining('flaky'), findsOneWidget);
    });

    testWidgets('trend with length=1 shows no badge (signal floor)',
        (tester) async {
      final trend = _stableTrend(1, 1);
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(),
        recurrenceTrend: trend,
      ));

      expect(find.textContaining('Seen'), findsNothing);
    });

    testWidgets('null trend shows no badge', (tester) async {
      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(),
        recurrenceTrend: null,
      ));

      expect(find.textContaining('Seen'), findsNothing);
    });

    testWidgets('worsening trend shows "worsening"', (tester) async {
      // Severity increasing over window → worsening
      final trend = RecurrenceTrend(capacity: 10);
      for (var i = 0; i < 5; i++) {
        trend.recordPresent(i, severityIndex: 1);
      }
      for (var i = 5; i < 10; i++) {
        trend.recordPresent(i, severityIndex: 3);
      }

      await tester.pumpWidget(_pumpIssueCard(
        _testIssue(),
        recurrenceTrend: trend,
      ));

      expect(find.textContaining('Seen'), findsOneWidget);
      expect(find.textContaining('worsening'), findsOneWidget);
    });
  });
}
