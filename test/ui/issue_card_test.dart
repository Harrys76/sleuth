import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/recurrence_trend.dart';
import 'package:sleuth/src/ui/focus_ink_well.dart';
import 'package:sleuth/src/ui/issue_card.dart';
import 'package:sleuth/src/ui/severity_icon.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';

import '../helpers/contrast_helpers.dart';

const _presets = [
  SleuthThemeData(),
  SleuthThemeData.light(),
  SleuthThemeData.highContrastDark(),
  SleuthThemeData.highContrastLight(),
];

PerformanceIssue _testIssue({
  IssueCategory category = IssueCategory.build,
  IssueSeverity severity = IssueSeverity.warning,
  IssueConfidence confidence = IssueConfidence.confirmed,
  String? confidenceReason,
  String title = 'Test Issue',
  String detail = 'Test detail',
  String fixHint = 'Test fix',
  String? widgetName,
  ObservationSource? observationSource,
  IssueMeasurement? measurement,
  bool debugModeDisclaimer = false,
}) {
  return PerformanceIssue(
    severity: severity,
    category: category,
    confidence: confidence,
    confidenceReason: confidenceReason,
    title: title,
    detail: detail,
    fixHint: fixHint,
    widgetName: widgetName,
    observationSource: observationSource,
    measurement: measurement,
    debugModeDisclaimer: debugModeDisclaimer,
  );
}

Widget _pumpIssueCard(
  PerformanceIssue issue, {
  bool initiallyExpanded = false,
  RecurrenceTrend? recurrenceTrend,
  VoidCallback? onAskAi,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: IssueCard(
          issue: issue,
          initiallyExpanded: initiallyExpanded,
          recurrenceTrend: recurrenceTrend,
          onAskAi: onAskAi,
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
  testWidgets('a new card carries the hint New and keeps its layout', (
    tester,
  ) async {
    final issue = _testIssue(title: 'Fresh');
    Widget card(bool isNew) => MaterialApp(
      home: Scaffold(
        body: IssueCard(issue: issue, isNew: isNew),
      ),
    );
    await tester.pumpWidget(card(false));
    final plain = tester.getRect(find.text('Fresh'));
    expect(
      tester.getSemantics(find.byType(IssueCard)).getSemanticsData().hint,
      isEmpty,
    );

    await tester.pumpWidget(card(true));
    expect(tester.getRect(find.text('Fresh')), plain);
    expect(
      tester.getSemantics(find.byType(IssueCard)).getSemanticsData().hint,
      'New',
    );
  });

  testWidgets('expanded body reads as separate nodes, not one utterance', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final issue = _testIssue(
      title: 'Heavy Build',
      detail: 'Build took 48 ms on the home route.',
      fixHint: 'Move the work off the build method.',
    );
    await tester.pumpWidget(_pumpIssueCard(issue, initiallyExpanded: true));
    await tester.pump();

    final card = tester.getSemantics(find.byType(IssueCard));
    expect(card.label, 'Heavy Build');
    expect(card.label, isNot(contains('48 ms')));
    expect(card.label, isNot(contains('build method')));
    expect(find.bySemanticsLabel(RegExp('48 ms')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('build method')), findsOneWidget);
    handle.dispose();
  });

  group('Inline confidence reasoning', () {
    testWidgets('expanded card with non-null confidenceReason shows text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _pumpIssueCard(
          _testIssue(
            confidence: IssueConfidence.confirmed,
            confidenceReason: 'Measured directly from VM timeline',
          ),
          initiallyExpanded: true,
        ),
      );

      // The reason opens the Evidence row.
      expect(
        find.text(
          'Measured directly from VM timeline. Sleuth rates it confirmed.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('expanded card with null confidenceReason hides row', (
      tester,
    ) async {
      await tester.pumpWidget(
        _pumpIssueCard(
          _testIssue(confidenceReason: null),
          initiallyExpanded: true,
        ),
      );

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

    testWidgets('collapsed card does not show confidenceReason', (
      tester,
    ) async {
      await tester.pumpWidget(
        _pumpIssueCard(
          _testIssue(confidenceReason: 'Should not be visible when collapsed'),
          initiallyExpanded: false,
        ),
      );

      expect(find.text('Should not be visible when collapsed'), findsNothing);
    });

    testWidgets('the meta line reads category and confidence as one '
        'phrase', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(confidenceReason: 'This is the reason')),
      );
      expect(find.byType(Tooltip), findsNothing);
      expect(find.textContaining('Build'), findsOneWidget);
      expect(find.textContaining('Confirmed'), findsOneWidget);
      expect(find.bySemanticsLabel('Build, Confirmed'), findsOneWidget);
      handle.dispose();
    });
  });

  group('Recurrence in the meta line', () {
    testWidgets('stable trend with ratio >= 0.9 shows "persistent"', (
      tester,
    ) async {
      // All 60 present with constant severity → stable, ratio = 1.0
      final trend = _stableTrend(54, 60);
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: trend),
      );

      expect(find.textContaining('scans, '), findsOneWidget);
      expect(find.textContaining('persistent'), findsOneWidget);
    });

    testWidgets('stable trend below 0.9 shows "stable"', (tester) async {
      // 10 present out of 60 with constant severity → stable, ratio < 0.9
      final trend = _stableTrend(10, 60);
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: trend),
      );

      expect(find.textContaining('scans, '), findsOneWidget);
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
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: trend),
      );

      expect(find.textContaining('scans, '), findsOneWidget);
      expect(find.textContaining('flaky'), findsOneWidget);
    });

    testWidgets('trend with length=1 shows no badge (signal floor)', (
      tester,
    ) async {
      final trend = _stableTrend(1, 1);
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: trend),
      );

      expect(find.textContaining('scans'), findsNothing);
    });

    testWidgets('null trend shows no badge', (tester) async {
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: null),
      );

      expect(find.textContaining('scans'), findsNothing);
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

      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: trend),
      );

      expect(find.textContaining('scans, '), findsOneWidget);
      expect(find.textContaining('worsening'), findsOneWidget);
    });

    testWidgets('scanTick refreshes the badge through recurrenceTrendOf '
        'without rebuilding the card', (tester) async {
      final tick = ValueNotifier<int>(0);
      final trend = RecurrenceTrend(capacity: 10);
      var parentBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                parentBuilds++;
                return IssueCard(
                  issue: _testIssue(),
                  recurrenceTrend: _stableTrend(5, 5),
                  recurrenceTrendOf: () => trend,
                  scanTick: tick,
                );
              },
            ),
          ),
        ),
      );
      // The resolver's empty trend wins over the fixed one: no badge.
      expect(find.textContaining('scans'), findsNothing);
      expect(parentBuilds, 1);

      trend.recordPresent(0, severityIndex: 2);
      trend.recordPresent(1, severityIndex: 2);
      tick.value++;
      await tester.pump();
      expect(find.textContaining('seen 2 of 2 scans'), findsOneWidget);

      trend.recordPresent(2, severityIndex: 2);
      tick.value++;
      await tester.pump();
      expect(find.textContaining('seen 3 of 3 scans'), findsOneWidget);
      expect(parentBuilds, 1);
      tick.dispose();
    });
  });

  testWidgets('an expanded card shows the whole title', (tester) async {
    const title =
        'A long title that keeps going past two lines on a narrow card so '
        'that a collapsed card has to ellipsize it near the end';
    Widget card(bool expanded) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 240,
            child: SingleChildScrollView(
              child: IssueCard(
                key: ValueKey(expanded),
                issue: _testIssue(title: title),
                initiallyExpanded: expanded,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(card(false));
    final collapsed = tester.renderObject<RenderParagraph>(find.text(title));
    expect(collapsed.maxLines, 2);
    expect(collapsed.didExceedMaxLines, isTrue);

    await tester.pumpWidget(card(true));
    final expanded = tester.renderObject<RenderParagraph>(find.text(title));
    expect(expanded.maxLines, isNull);
    expect(expanded.didExceedMaxLines, isFalse);
  });

  group('Pinned while expanded', () {
    testWidgets('is announced on an expanded card and never drawn', (
      tester,
    ) async {
      String? hint() =>
          tester.getSemantics(find.byType(IssueCard)).getSemanticsData().hint;
      await tester.pumpWidget(_pumpIssueCard(_testIssue()));
      expect(hint(), isEmpty);
      expect(find.byIcon(Icons.push_pin), findsNothing);

      await tester.tap(find.byType(IssueCard));
      await tester.pumpAndSettle();
      expect(hint(), 'Pinned while expanded');
      expect(find.byIcon(Icons.push_pin), findsNothing);

      await tester.tap(find.text('Test Issue'));
      await tester.pumpAndSettle();
      expect(hint(), isEmpty);
    });

    testWidgets('joins the New hint', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IssueCard(
                issue: _testIssue(),
                isNew: true,
                initiallyExpanded: true,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSemantics(find.byType(IssueCard)).getSemanticsData().hint,
        'New, Pinned while expanded',
      );
    });
  });

  group('Ask AI button', () {
    testWidgets('draws a still icon: nothing animates', (tester) async {
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), initiallyExpanded: true, onAskAi: () {}),
      );
      expect(find.bySemanticsLabel('Ask AI'), findsOneWidget);
      expect(find.byType(ShaderMask), findsNothing);
      // A repeating animation would keep this from settling.
      await tester.pumpAndSettle();
    });
  });

  group('Crosshair', () {
    Widget card(
      PerformanceIssue issue, {
      bool finding = false,
      bool locatable = true,
      ValueChanged<bool>? onChanged,
      SleuthThemeData theme = const SleuthThemeData(),
      double width = 320,
    }) => MaterialApp(
      home: Scaffold(
        body: SleuthTheme(
          data: theme,
          child: Center(
            child: SizedBox(
              width: width,
              child: IssueCard(
                issue: issue,
                locatable: locatable,
                finding: finding,
                onHighlightChanged: onChanged ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('shows only when the host can locate the issue', (
      tester,
    ) async {
      await tester.pumpWidget(
        card(_testIssue(widgetName: 'PriceTag'), locatable: false),
      );
      expect(find.byIcon(Icons.my_location), findsNothing);
      expect(find.byType(Checkbox), findsNothing);

      await tester.pumpWidget(card(_testIssue(widgetName: 'PriceTag')));
      expect(find.byIcon(Icons.my_location), findsOneWidget);
      expect(find.bySemanticsLabel('Show PriceTag on screen'), findsOneWidget);
    });

    testWidgets(
      "on an issue that lists widgets reads Show this issue's widgets",
      (tester) async {
        await tester.pumpWidget(card(_testIssue()));
        expect(
          find.bySemanticsLabel("Show this issue's widgets on screen"),
          findsOneWidget,
        );
      },
    );

    testWidgets('is a 48 px button in the card corner; while finding it '
        'reads Finding and a second tap cancels', (tester) async {
      final changes = <bool>[];
      await tester.pumpWidget(
        card(_testIssue(widgetName: 'PriceTag'), onChanged: changes.add),
      );
      final target = find.bySemanticsLabel('Show PriceTag on screen');
      final box = tester.getRect(target);
      final cardRect = tester.getRect(find.byType(Card));
      expect(box.size, const Size(48, 48));
      expect(box.topRight, cardRect.topRight);
      // An action, not a toggle: the card shrinks to the bar once found.
      final idle = tester.widget<Semantics>(target).properties;
      expect(idle.toggled, isNull);
      expect(idle.value, isNull);

      // A tap at the edge of the hit box, outside the 18 px glyph.
      await tester.tapAt(box.topLeft + const Offset(3, 3));
      expect(changes, [true]);

      await tester.pumpWidget(
        card(
          _testIssue(widgetName: 'PriceTag'),
          finding: true,
          onChanged: changes.add,
        ),
      );
      expect(tester.widget<Semantics>(target).properties.value, 'Finding');
      await tester.tap(target);
      expect(changes, [true, false]);
    });

    testWidgets('its face is centred on the title\'s first line', (
      tester,
    ) async {
      await tester.pumpWidget(card(_testIssue(widgetName: 'PriceTag')));
      final face = tester.getCenter(find.byIcon(Icons.my_location));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('Test Issue'),
      );
      final line = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .first
          .toRect();
      final titleTop = tester.getTopLeft(find.text('Test Issue')).dy;
      expect((face.dy - (titleTop + line.center.dy)).abs(), lessThan(1));
    });

    testWidgets('the title row leaves room for it', (tester) async {
      await tester.pumpWidget(
        card(
          _testIssue(
            widgetName: 'PriceTag',
            title: 'A long title that wraps onto its second line here',
          ),
        ),
      );
      final title = tester.getRect(
        find.text('A long title that wraps onto its second line here'),
      );
      final target = tester.getRect(
        find.bySemanticsLabel('Show PriceTag on screen'),
      );
      expect(title.right, lessThanOrEqualTo(target.left + 10 + 0.5));
    });

    testWidgets('its glyph keeps 3:1 off and on, in every preset', (
      tester,
    ) async {
      for (final theme in _presets) {
        for (final on in [false, true]) {
          await tester.pumpWidget(
            card(
              _testIssue(widgetName: 'PriceTag'),
              finding: on,
              theme: theme,
            ),
          );
          final glyph = tester.widget<Icon>(find.byIcon(Icons.my_location));
          final cardFill = on ? theme.cardHighlighted : theme.cardDefault;
          final fill = on
              ? composite(
                  theme.checkboxActive.withValues(alpha: 0.22),
                  cardFill,
                )
              : cardFill;
          expect(
            wcagContrast(glyph.color!, fill),
            greaterThanOrEqualTo(3),
            reason: '${theme.brightness.name} on: $on',
          );
        }
      }
    });
  });

  group('Collapsed layout', () {
    Widget cards(double width, double scale, List<PerformanceIssue> issues) =>
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final issue in issues)
                          IssueCard(
                            issue: issue,
                            locatable: true,
                            onHighlightChanged: (_) {},
                            jankCorrelated: true,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('icon, title and meta line fit at ${scale}x', (tester) async {
        const title =
            'A long title that keeps going past two lines on a narrow '
            'card so it has to ellipsize somewhere near the end';
        await tester.pumpWidget(
          cards(320, scale, [_testIssue(title: title, widgetName: 'PriceTag')]),
        );
        expect(tester.takeException(), isNull);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(title),
        );
        expect(paragraph.maxLines, scale > 1.3 ? 3 : 2);
        // The icon sits on the title's first line.
        final icon = tester.getRect(find.byType(SleuthSeverityIcon));
        final firstLine = paragraph
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 1),
            )
            .first;
        final titleTop = tester.getTopLeft(find.text(title)).dy;
        expect(
          (icon.center.dy - (titleTop + firstLine.toRect().center.dy)).abs(),
          lessThan(2),
        );
        // The meta line starts under the title.
        expect(
          tester.getTopLeft(find.textContaining('Build')).dx,
          tester.getTopLeft(find.text(title)).dx,
        );
      });
    }

    testWidgets('under a one-line title the meta line ends before the '
        'crosshair', (tester) async {
      await tester.pumpWidget(
        cards(320, 1, [_testIssue(title: 'Short', widgetName: 'PriceTag')]),
      );
      // The room the paragraph may fill, not the width its text takes.
      final meta = find.textContaining('Build');
      final paragraph = tester.renderObject<RenderParagraph>(
        // The paragraph itself; the tags' own texts sit inside it.
        find.descendant(of: meta, matching: find.byType(RichText)).first,
      );
      final target = tester.getRect(
        find.bySemanticsLabel('Show PriceTag on screen'),
      );
      expect(
        tester.getTopLeft(meta).dx + paragraph.constraints.maxWidth,
        lessThanOrEqualTo(target.left + 10.5),
      );
    });

    testWidgets('the severity icon is a filled mark', (tester) async {
      await tester.pumpWidget(
        cards(320, 1, [
          _testIssue(severity: IssueSeverity.critical, title: 'C'),
        ]),
      );
      final icon = tester.widget<SleuthSeverityIcon>(
        find.byType(SleuthSeverityIcon),
      );
      expect(icon.severity, IssueSeverity.critical);
      expect(find.text('\u{1F534}'), findsNothing);
      // Its mark keeps 3:1 on the severity fill, and its shape (the fill,
      // or the outline where the fill falls short) 3:1 on the card
      // surfaces, in every preset.
      for (final theme in [
        ..._presets,
        SleuthThemeData.fromSeed(Colors.teal),
        SleuthThemeData.fromSeed(Colors.teal, brightness: Brightness.dark),
      ]) {
        for (final severity in IssueSeverity.values) {
          final fill = theme.severityColor(severity);
          expect(
            wcagContrast(SleuthSeverityIcon.markOn(fill), fill),
            greaterThanOrEqualTo(3),
            reason: '${theme.brightness.name} $severity',
          );
          final edge = SleuthSeverityIcon.edgeOf(theme, severity);
          // A disc's white ring outlines it unless an edge colour does.
          final outlines = [
            ?edge,
            if (edge == null) fill,
            if (edge == null && severity != IssueSeverity.warning)
              const Color(0xFFFFFFFF),
          ];
          for (final surface in [theme.cardDefault, theme.cardBackground]) {
            expect(
              outlines.map((c) => wcagContrast(c, surface)).reduce(math.max),
              greaterThanOrEqualTo(3),
              reason: '${theme.brightness.name} $severity shape',
            );
          }
        }
      }
      // The dark default keeps its unoutlined fills.
      for (final severity in IssueSeverity.values) {
        expect(
          SleuthSeverityIcon.edgeOf(const SleuthThemeData(), severity),
          isNull,
        );
      }
      // No left accent bar: the card has no decoration border.
      expect(
        find.descendant(
          of: find.byType(IssueCard),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).border != null,
          ),
        ),
        findsNothing,
      );
    });
  });

  testWidgets('a press tints the card without a ripple', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: IssueCard(issue: _testIssue())),
      ),
    );
    final well = tester.widget<InkWell>(
      find.descendant(
        of: find.byType(IssueCard),
        matching: find.byType(InkWell),
      ),
    );
    expect(well.splashFactory, NoSplash.splashFactory);
    expect(
      well.highlightColor,
      const SleuthThemeData().textPrimary.withValues(alpha: 0.08),
    );
  });

  testWidgets('the card body draws the focus outline in keyboard mode', (
    tester,
  ) async {
    Iterable<SleuthFocusOutline> shown() => tester
        .widgetList<SleuthFocusOutline>(find.byType(SleuthFocusOutline))
        .where((o) => o.show);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IssueCard(
            issue: _testIssue(widgetName: 'PriceTag'),
            locatable: true,
            onHighlightChanged: (_) {},
          ),
        ),
      ),
    );
    expect(shown(), isEmpty);
    // Tab reaches the card first, then the crosshair.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    const theme = SleuthThemeData();
    expect(shown().single.borderRadius, BorderRadius.circular(theme.radiusXl));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(shown().single.borderRadius, BorderRadius.circular(theme.radiusLg));
  });

  group('Meta line tags', () {
    Widget card(
      PerformanceIssue issue, {
      bool jank = false,
      bool isNew = false,
    }) => MaterialApp(
      home: Scaffold(
        body: IssueCard(issue: issue, jankCorrelated: jank, isNew: isNew),
      ),
    );

    testWidgets('Jank and New lead the line; New is not read twice', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(card(_testIssue(), jank: true, isNew: true));
      expect(
        tester.getTopLeft(find.text('New')).dx,
        lessThan(tester.getTopLeft(find.text('Jank')).dx),
      );
      // Both tags come before the words, and the dot stays with the
      // word before it.
      final meta = tester.widget<Text>(find.textContaining('Build'));
      expect(
        meta.textSpan!.toPlainText(),
        '\uFFFC\uFFFCBuild\u00A0\u00B7 Confirmed',
      );
      expect(find.bySemanticsLabel('Jank, Build, Confirmed'), findsOneWidget);
      handle.dispose();
    });

    PerformanceIssue timed({
      bool debug = true,
      ObservationSource? source = ObservationSource.vmTimeline,
      MeasurementUnit unit = MeasurementUnit.milliseconds,
    }) => _testIssue(
      debugModeDisclaimer: debug,
      observationSource: source,
      measurement: IssueMeasurement(value: 10, unit: unit),
    );

    testWidgets('Debug timing replaces confidence on a timing issue in a '
        'debug run', (tester) async {
      await tester.pumpWidget(card(timed()));
      expect(find.text('Debug timing'), findsOneWidget);
      expect(find.textContaining('Confirmed'), findsNothing);
      // In the confidence slot, after the category.
      final meta = tester.widget<Text>(find.textContaining('Build'));
      expect(meta.textSpan!.toPlainText(), 'Build\u00A0\u00B7 \uFFFC');
    });

    for (final (name, issue) in [
      ('a profile run', () => timed(debug: false)),
      ('a structural issue', () => timed(source: ObservationSource.structural)),
      ('a rate', () => timed(unit: MeasurementUnit.perSecond)),
      ('a size', () => timed(unit: MeasurementUnit.bytes)),
      ('no measurement', () => _testIssue(debugModeDisclaimer: true)),
    ]) {
      testWidgets('no Debug timing tag for $name', (tester) async {
        await tester.pumpWidget(card(issue()));
        expect(find.text('Debug timing'), findsNothing);
        expect(find.textContaining('Confirmed'), findsOneWidget);
      });
    }

    testWidgets('effects count the downstream issues', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IssueCard(
              issue: _testIssue(),
              downstreamIssues: [
                _testIssue(title: 'a'),
                _testIssue(title: 'b'),
              ],
            ),
          ),
        ),
      );
      expect(find.textContaining('2 effects'), findsOneWidget);
    });

    testWidgets('Not detected right now reads in every preset', (tester) async {
      for (final theme in _presets) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SleuthTheme(
                data: theme,
                child: IssueCard(issue: _testIssue(), stale: true),
              ),
            ),
          ),
        );
        final tag = tester.widget<Text>(find.text('Not detected right now'));
        expect(tag.style!.color, theme.badgeTextOn(theme.textSecondary));
        expect(
          wcagContrast(
            tag.style!.color!,
            composite(theme.badgeFill(theme.textSecondary), theme.cardDefault),
          ),
          greaterThanOrEqualTo(4.5),
          reason: theme.brightness.name,
        );
      }
    });

    testWidgets('the per-card debug disclaimer is gone', (tester) async {
      await tester.pumpWidget(card(_testIssue(debugModeDisclaimer: true)));
      expect(find.textContaining('Debug mode result'), findsNothing);
    });
  });

  group('expanded card buttons', () {
    const labels = [
      'Show on screen',
      'Learn more',
      'Ask AI',
      'Copy details',
      'Hide',
      'Not useful',
    ];

    Future<Map<String, Rect>> pumpButtons(
      WidgetTester tester,
      double width,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: IssueCard(
                    issue: _testIssue(widgetName: 'FeedTile'),
                    initiallyExpanded: true,
                    locatable: true,
                    onHighlightChanged: (_) {},
                    onCopy: () {},
                    onHide: () {},
                    onLearnMore: () {},
                    onAskAi: () {},
                    onNotUsefulChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return {
        for (final label in labels)
          label: tester.getRect(find.bySemanticsLabel(label)),
      };
    }

    testWidgets('run in reading order, each a 48 px hit box', (tester) async {
      final r = await pumpButtons(tester, 400);
      for (var i = 0; i < labels.length; i++) {
        final rect = r[labels[i]]!;
        expect(rect.height, greaterThanOrEqualTo(48), reason: labels[i]);
        expect(rect.width, greaterThanOrEqualTo(48), reason: labels[i]);
        if (i == 0) continue;
        final before = r[labels[i - 1]]!;
        // The next button sits to the right on the same row, or on a
        // later row.
        expect(
          rect.top > before.top ||
              (rect.top == before.top && rect.left >= before.right),
          isTrue,
          reason: '${labels[i - 1]} then ${labels[i]}',
        );
      }
    });

    testWidgets('wrap on a narrow card without overlapping, each row '
        'starting at the same edge', (tester) async {
      final r = await pumpButtons(tester, 180);
      final rects = r.values.toList();
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].overlaps(rects[j]), isFalse);
        }
      }
      final lefts = {for (final rect in rects) rect.left.round()};
      expect(lefts.length, lessThan(rects.length));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Not useful is a toggle read as on and off', (tester) async {
      final changes = <bool>[];
      Future<void> pump(bool marked) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IssueCard(
                issue: _testIssue(),
                initiallyExpanded: true,
                notUseful: marked,
                onNotUsefulChanged: changes.add,
              ),
            ),
          ),
        ),
      );
      await pump(false);
      final node = find.bySemanticsLabel('Not useful');
      expect(tester.widget<Semantics>(node).properties.toggled, isFalse);
      await tester.tap(node);
      await pump(true);
      expect(tester.widget<Semantics>(node).properties.toggled, isTrue);
      await tester.tap(node);
      expect(changes, [true, false]);
    });
  });

  group('sameInputsAs', () {
    // The card list keeps a card whose inputs are unchanged, so a field
    // the check leaves out would leave its card stale.
    test('compares every constructor field', () {
      final source = File('lib/src/ui/issue_card.dart').readAsStringSync();
      final constructor = RegExp(
        r'const IssueCard\(\{([^}]*)\}\)',
      ).firstMatch(source)!.group(1)!;
      final fields = [
        for (final m in RegExp(r'this\.(\w+)').allMatches(constructor))
          m.group(1)!,
      ];
      final start = source.indexOf('bool sameInputsAs(IssueCard other) {');
      final body = source.substring(start, source.indexOf('\n  }\n', start));
      expect(fields, isNotEmpty);
      expect([
        for (final f in fields)
          if (!body.contains('other.$f')) f,
      ], isEmpty);
    });

    test('an issue with the same fingerprint and occurrence is the same', () {
      final a = IssueCard(
        issue: _testIssue(title: 'T'),
        onCopy: () {},
      );
      final b = IssueCard(
        issue: _testIssue(title: 'T'),
        onCopy: () {},
      );
      expect(a.sameInputsAs(b), isTrue);
      expect(
        a.sameInputsAs(
          IssueCard(
            issue: _testIssue(title: 'U'),
            onCopy: () {},
          ),
        ),
        isFalse,
      );
      expect(
        a.sameInputsAs(
          IssueCard(
            issue: _testIssue(title: 'T').copyWith(occurrenceId: 7),
            onCopy: () {},
          ),
        ),
        isFalse,
      );
      expect(a.sameInputsAs(IssueCard(issue: _testIssue(title: 'T'))), isFalse);
      expect(
        a.sameInputsAs(
          IssueCard(
            issue: _testIssue(title: 'T'),
            onCopy: () {},
            stale: true,
          ),
        ),
        isFalse,
      );
    });
  });
}
