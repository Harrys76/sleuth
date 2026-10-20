import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/recurrence_trend.dart';
import 'package:sleuth/src/ui/issue_card.dart';
import 'package:sleuth/src/ui/issue_card_details.dart';
import 'package:sleuth/src/ui/measurement_gauge.dart';

PerformanceIssue _issue({
  String stableId = 'heavy_compute',
  IssueSeverity severity = IssueSeverity.warning,
  IssueMeasurement? measurement,
  String? widgetName,
  String title = 'Heavy Computation: 10.0ms',
  List<String>? downstreamIds,
}) => PerformanceIssue(
  severity: severity,
  category: IssueCategory.build,
  confidence: IssueConfidence.confirmed,
  title: title,
  detail: 'A long-running operation ran on the UI thread.',
  fixHint: 'Split the widget.',
  stableId: stableId,
  widgetName: widgetName,
  measurement: measurement,
  downstreamIds: downstreamIds,
);

const _tenMs = IssueMeasurement(
  value: 10,
  unit: MeasurementUnit.milliseconds,
  warningAt: 8,
  criticalAt: 16,
);

Future<void> _pump(
  WidgetTester tester,
  IssueCard card, {
  double width = 360,
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, child: card),
            ),
          ),
        ),
      ),
    ),
  );
}

RecurrenceTrend _trend(int present, int length) {
  final trend = RecurrenceTrend();
  for (var i = 0; i < length; i++) {
    if (i < present) {
      trend.recordPresent(i, severityIndex: 1);
    } else {
      trend.recordAbsent(i);
    }
  }
  return trend;
}

void main() {
  group('Measured row', () {
    testWidgets('shows the value against its lines on a gauge', (tester) async {
      await _pump(
        tester,
        IssueCard(issue: _issue(measurement: _tenMs), initiallyExpanded: true),
      );
      expect(find.text('MEASURED'), findsOneWidget);
      expect(find.byType(SleuthMeasurementGauge), findsOneWidget);
      expect(
        find.text('10.0 ms in one build on the UI thread', findRichText: true),
        findsOneWidget,
      );
      // The value replaces the detail.
      expect(
        find.text('A long-running operation ran on the UI thread.'),
        findsNothing,
      );
      expect(
        find.bySemanticsLabel(
          'Measured: 10.0 ms in one build on the UI thread. Warning at 8.0 '
          'ms. Critical at 16.0 ms',
        ),
        findsOneWidget,
      );
    });

    testWidgets('is left out without a measurement; the detail shows', (
      tester,
    ) async {
      await _pump(tester, IssueCard(issue: _issue(), initiallyExpanded: true));
      expect(find.text('MEASURED'), findsNothing);
      expect(find.byType(SleuthMeasurementGauge), findsNothing);
      expect(
        find.text('A long-running operation ran on the UI thread.'),
        findsOneWidget,
      );
    });

    testWidgets('a held critical adds the held line', (tester) async {
      await _pump(
        tester,
        IssueCard(
          issue: _issue(measurement: _tenMs, severity: IssueSeverity.critical),
          initiallyExpanded: true,
        ),
      );
      expect(
        find.text(
          'Held at critical: the value has not stayed below the line long '
          'enough to clear it',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a debug rate over the line at warning adds the reverse '
        'line', (tester) async {
      await _pump(
        tester,
        IssueCard(
          issue: _issue(
            stableId: 'rebuild_debug_FeedTile',
            widgetName: 'FeedTile',
            measurement: const IssueMeasurement(
              value: 35,
              unit: MeasurementUnit.perSecond,
              warningAt: 10,
              criticalAt: 30,
              criticalStrict: true,
            ),
          ),
          initiallyExpanded: true,
        ),
      );
      expect(
        find.text(
          'Not critical: the latest second stayed at or under the line',
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('When reads last seen and the scan counts', (tester) async {
    final seen = DateTime.now().subtract(const Duration(seconds: 2));
    await _pump(
      tester,
      IssueCard(
        issue: _issue(),
        initiallyExpanded: true,
        recurrenceTrend: _trend(5, 8),
        lastSeenOf: () => seen,
      ),
    );
    expect(find.text('Last seen 2 s ago · in 5 of the last 8 scans'), findsOne);
  });

  testWidgets('labels sit beside their values, and above them at 2.0x', (
    tester,
  ) async {
    Offset label() => tester.getTopLeft(find.text('Evidence'));
    Offset value() => tester.getTopLeft(
      find.text('From the overlay heuristics, so confirmed.'),
    );

    await _pump(tester, IssueCard(issue: _issue(), initiallyExpanded: true));
    expect(value().dx, greaterThan(label().dx));
    expect(value().dy, label().dy);

    await _pump(
      tester,
      IssueCard(issue: _issue(), initiallyExpanded: true),
      width: 240,
      textScale: 2,
    );
    expect(value().dx, label().dx);
    expect(value().dy, greaterThan(label().dy));
    expect(tester.takeException(), isNull);
  });

  group('Why it rebuilds', () {
    Future<void> pumpWhy(
      WidgetTester tester,
      RebuildCause? Function()? causeOf,
    ) => _pump(
      tester,
      IssueCard(
        issue: _issue(stableId: 'setstate_scope', widgetName: 'DemoScaffold'),
        initiallyExpanded: true,
        whyItRebuilds: true,
        rebuildCauseOf: causeOf,
      ),
    );

    testWidgets('splits own and forced rebuilds and names the parent', (
      tester,
    ) async {
      await pumpWhy(
        tester,
        () => (
          own: 0,
          forced: 5,
          parents: 1,
          parent: 'CombinedChatDemo',
          parentForced: 5,
          seconds: 10,
          capped: false,
        ),
      );
      expect(find.text('WHY IT REBUILDS · LAST 10 S'), findsOneWidget);
      expect(
        find.text(
          '0 started by the widget itself · 5 forced by its parent '
          'CombinedChatDemo',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Most of these rebuilds come from CombinedChatDemo, so start '
          'there.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('with several parents gives the busiest one its own share', (
      tester,
    ) async {
      await pumpWhy(
        tester,
        () => (
          own: 4,
          forced: 6,
          parents: 3,
          parent: 'FeedList',
          parentForced: 3,
          seconds: 10,
          capped: false,
        ),
      );
      expect(
        find.text(
          '4 started by the widget itself · 6 forced by 3 parents, 3 of '
          'them by FeedList',
          findRichText: true,
        ),
        findsOneWidget,
      );
      // FeedList alone forced fewer than the widget started itself.
      expect(find.textContaining('so start there'), findsNothing);
    });

    testWidgets('capped counters qualify the counts and drop the advice', (
      tester,
    ) async {
      await pumpWhy(
        tester,
        () => (
          own: 0,
          forced: 5,
          parents: 1,
          parent: 'CombinedChatDemo',
          parentForced: 5,
          seconds: 10,
          capped: true,
        ),
      );
      expect(
        find.text(
          'Some widget types went untracked, so these counts can be low.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('so start there'), findsNothing);
    });

    testWidgets('capped counters do not claim no rebuilds', (tester) async {
      await pumpWhy(
        tester,
        () => (
          own: 0,
          forced: 0,
          parents: 0,
          parent: null,
          parentForced: 0,
          seconds: 2,
          capped: true,
        ),
      );
      expect(find.text('No rebuilds in the last 2 s'), findsNothing);
      expect(
        find.text(
          'No rebuilds counted in the last 2 s; some widget types went '
          'untracked',
        ),
        findsOneWidget,
      );
    });

    testWidgets('says when the window had no rebuilds', (tester) async {
      await pumpWhy(
        tester,
        () => (
          own: 0,
          forced: 0,
          parents: 0,
          parent: null,
          parentForced: 0,
          seconds: 2,
          capped: false,
        ),
      );
      expect(find.text('No rebuilds in the last 2 s'), findsOneWidget);
    });

    testWidgets('without debug callbacks it says how to turn them on', (
      tester,
    ) async {
      await pumpWhy(tester, null);
      expect(
        find.textContaining('SleuthConfig.enableDebugCallbacks'),
        findsOneWidget,
      );
    });

    testWidgets('is left out on other cards', (tester) async {
      await _pump(tester, IssueCard(issue: _issue(), initiallyExpanded: true));
      expect(find.textContaining('WHY IT REBUILDS'), findsNothing);
    });
  });

  group('related rows', () {
    final effect = _issue(
      stableId: 'heap_growing',
      title: 'Heap Growing',
      severity: IssueSeverity.critical,
    );

    testWidgets('an open row asks the host to open the card', (tester) async {
      final opened = <PerformanceIssue>[];
      await _pump(
        tester,
        IssueCard(
          issue: _issue(downstreamIds: ['heap_growing']),
          initiallyExpanded: true,
          downstreamIssues: [effect],
          relatedLinkOf: (_) => RelatedLink.open,
          onOpenRelated: opened.add,
        ),
      );
      expect(find.text('EFFECTS (1)'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Critical: Heap Growing'));
      expect(opened, [effect]);
    });

    testWidgets('an inline row opens the details under it', (tester) async {
      await _pump(
        tester,
        IssueCard(
          issue: _issue(downstreamIds: ['heap_growing']),
          initiallyExpanded: true,
          downstreamIssues: [effect],
          relatedLinkOf: (_) => RelatedLink.inline,
        ),
      );
      final detail = find.text(
        'A long-running operation ran on the UI thread.',
      );
      // The card's own detail shows once; the effect's under its row.
      expect(detail, findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Critical: Heap Growing'));
      await tester.pump();
      expect(detail, findsNWidgets(2));
      await tester.tap(find.bySemanticsLabel('Critical: Heap Growing'));
      await tester.pump();
      expect(detail, findsOneWidget);
    });

    testWidgets('an effect that stops being reported stays as plain text', (
      tester,
    ) async {
      Future<void> pump(List<PerformanceIssue> effects) => _pump(
        tester,
        IssueCard(
          issue: _issue(downstreamIds: ['heap_growing']),
          initiallyExpanded: true,
          downstreamIssues: effects,
          relatedLinkOf: (r) =>
              effects.contains(r) ? RelatedLink.open : RelatedLink.plain,
          onOpenRelated: (_) {},
        ),
      );
      await pump([effect]);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      // The causal graph regenerates the root without the gone effect.
      await _pump(
        tester,
        IssueCard(
          issue: _issue(),
          initiallyExpanded: true,
          relatedLinkOf: (_) => RelatedLink.plain,
          onOpenRelated: (_) {},
        ),
      );
      expect(find.text('EFFECTS (1)'), findsOneWidget);
      expect(find.text('Heap Growing'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('an unreported target is plain text', (tester) async {
      await _pump(
        tester,
        IssueCard(
          issue: _issue(downstreamIds: ['heap_growing']),
          initiallyExpanded: true,
          downstreamIssues: [effect],
        ),
      );
      expect(find.text('Heap Growing'), findsOneWidget);
      expect(
        tester
            .widget<Semantics>(find.bySemanticsLabel('Critical: Heap Growing'))
            .properties
            .button,
        isNot(isTrue),
      );
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });
  });

  group('stats links', () {
    testWidgets('a rebuild card links to Rebuild stats with the count', (
      tester,
    ) async {
      var opened = 0;
      await _pump(
        tester,
        IssueCard(
          issue: _issue(stableId: 'rebuild_activity'),
          initiallyExpanded: true,
          onSeeRebuildStats: () => opened++,
          rebuildStatsTotal: 2389,
        ),
      );
      final link = find.bySemanticsLabel(
        'See rebuild stats for this screen · 2,389 rebuilds',
      );
      await tester.tap(link);
      expect(opened, 1);
    });

    testWidgets('the startup card links to Startup metrics', (tester) async {
      var opened = 0;
      await _pump(
        tester,
        IssueCard(
          issue: _issue(stableId: 'slow_startup_ttff'),
          initiallyExpanded: true,
          onSeeStartup: () => opened++,
        ),
      );
      await tester.tap(find.bySemanticsLabel('See startup details'));
      expect(opened, 1);
    });
  });

  testWidgets('a tap on the details keeps the card open; the header '
      'collapses it', (tester) async {
    final changes = <bool>[];
    await _pump(
      tester,
      IssueCard(
        issue: _issue(),
        initiallyExpanded: true,
        onExpandedChanged: changes.add,
      ),
    );
    await tester.tap(find.text('Evidence'));
    await tester.pump();
    expect(changes, isEmpty);
    await tester.tap(find.text('Heavy Computation: 10.0ms'));
    await tester.pump();
    expect(changes, [false]);
  });

  testWidgets('the details sit below a divider at the full card width', (
    tester,
  ) async {
    await _pump(tester, IssueCard(issue: _issue(), initiallyExpanded: true));
    final title = tester.getTopLeft(find.text('Heavy Computation: 10.0ms'));
    final evidence = tester.getTopLeft(find.text('Evidence'));
    // The header keeps its indent; the details start at the icon's edge.
    expect(evidence.dx, lessThan(title.dx));
  });
}
