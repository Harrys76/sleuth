import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/recurrence_trend.dart';
import 'package:sleuth/src/ui/issue_card.dart';
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

  group('M5: Inline confidence reasoning', () {
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

      expect(find.text('Measured directly from VM timeline'), findsOneWidget);
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

    testWidgets('icon matches confidence level', (tester) async {
      // Test confirmed → check_circle_outline
      await tester.pumpWidget(
        _pumpIssueCard(
          _testIssue(
            confidence: IssueConfidence.confirmed,
            confidenceReason: 'Confirmed reason',
          ),
          initiallyExpanded: true,
        ),
      );

      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);

      // Test likely → help_outline
      await tester.pumpWidget(
        _pumpIssueCard(
          _testIssue(
            confidence: IssueConfidence.likely,
            confidenceReason: 'Likely reason',
          ),
          initiallyExpanded: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.help_outline), findsOneWidget);

      // Test possible → info_outline
      await tester.pumpWidget(
        _pumpIssueCard(
          _testIssue(
            confidence: IssueConfidence.possible,
            confidenceReason: 'Possible reason',
          ),
          initiallyExpanded: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.info_outline), findsOneWidget);
    });

    testWidgets('confidence badge uses Semantics instead of Tooltip', (
      tester,
    ) async {
      await tester.pumpWidget(
        _pumpIssueCard(
          _testIssue(confidenceReason: 'This is the reason'),
          initiallyExpanded: false,
        ),
      );

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
    testWidgets('stable trend with ratio >= 0.9 shows "persistent"', (
      tester,
    ) async {
      // All 60 present with constant severity → stable, ratio = 1.0
      final trend = _stableTrend(54, 60);
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: trend),
      );

      expect(find.textContaining('Seen'), findsOneWidget);
      expect(find.textContaining('persistent'), findsOneWidget);
    });

    testWidgets('stable trend below 0.9 shows "stable"', (tester) async {
      // 10 present out of 60 with constant severity → stable, ratio < 0.9
      final trend = _stableTrend(10, 60);
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: trend),
      );

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
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: trend),
      );

      expect(find.textContaining('Seen'), findsOneWidget);
      expect(find.textContaining('flaky'), findsOneWidget);
    });

    testWidgets('trend with length=1 shows no badge (signal floor)', (
      tester,
    ) async {
      final trend = _stableTrend(1, 1);
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: trend),
      );

      expect(find.textContaining('Seen'), findsNothing);
    });

    testWidgets('null trend shows no badge', (tester) async {
      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: null),
      );

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

      await tester.pumpWidget(
        _pumpIssueCard(_testIssue(), recurrenceTrend: trend),
      );

      expect(find.textContaining('Seen'), findsOneWidget);
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
      expect(find.textContaining('Seen'), findsNothing);
      expect(parentBuilds, 1);

      trend.recordPresent(0, severityIndex: 2);
      trend.recordPresent(1, severityIndex: 2);
      tick.value++;
      await tester.pump();
      expect(find.textContaining('Seen 2/2'), findsOneWidget);

      trend.recordPresent(2, severityIndex: 2);
      tick.value++;
      await tester.pump();
      expect(find.textContaining('Seen 3/3'), findsOneWidget);
      expect(parentBuilds, 1);
      tick.dispose();
    });
  });

  group('v0.15.5 freeze-above-on-expand pin indicator', () {
    testWidgets(
      'pin icon appears when card is expanded and disappears when collapsed',
      (tester) async {
        // Start collapsed → no pin icon in the tree.
        await tester.pumpWidget(
          _pumpIssueCard(_testIssue(), initiallyExpanded: false),
        );

        expect(find.byIcon(Icons.push_pin), findsNothing);

        // Tap the card header to expand → pin icon renders.
        await tester.tap(find.byType(IssueCard));
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.push_pin), findsOneWidget);

        // Tap the title again to collapse → pin icon disappears. (The
        // card's centre now holds the 48 px "About this detection" row.)
        await tester.tap(find.text('Test Issue'));
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.push_pin), findsNothing);
      },
    );

    testWidgets(
      'Semantics node is unconditional, label only populated when expanded',
      (tester) async {
        // Collapsed: the Semantics node exists but carries no visible label
        // and excludes its child's semantics so TalkBack stays silent.
        await tester.pumpWidget(
          _pumpIssueCard(_testIssue(), initiallyExpanded: false),
        );

        final collapsedPinSemantics = find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label == '' &&
              w.excludeSemantics == true,
        );
        expect(
          collapsedPinSemantics,
          findsOneWidget,
          reason:
              'Unconditional Semantics node must exist when collapsed so '
              'traversal order does not shift when the user toggles expansion.',
        );

        // Pin label is hidden while collapsed.
        final pinLabelFinder = find.byWidgetPredicate(
          (w) =>
              w is Semantics && w.properties.label == 'Pinned while expanded',
        );
        expect(pinLabelFinder, findsNothing);

        // Expand → same Semantics node now carries the pin label and surfaces
        // its child (excludeSemantics flips to false).
        await tester.tap(find.byType(IssueCard));
        await tester.pumpAndSettle();

        final expandedPinSemantics = find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label == 'Pinned while expanded' &&
              w.excludeSemantics == false,
        );
        expect(
          expandedPinSemantics,
          findsOneWidget,
          reason:
              'When expanded the Semantics node must publish the "Pinned while '
              'expanded" label and stop excluding child semantics.',
        );
      },
    );

    testWidgets('pin icon stays within card bounds at 300dp with all '
        'header badges present', (tester) async {
      // A long title truncated with ellipsis plus confidence badge, pin
      // icon, JANK badge, "↳ N" downstream badge, and Checkbox can
      // squeeze the pin out of the card bounds on a 300dp wide card
      // (the default overlay width).
      //
      // This test pumps the exact combinatorial tail and asserts that
      // the pin icon's rect is fully contained inside its ancestor Card.
      // That's the pin-specific invariant v0.15.5 is responsible for.
      //
      // The category and confidence badges sit beside the title only
      // while the title keeps its minimum width; JANK / downstream badges
      // wrap on the badge line, so the header never overflows.
      final rootIssue = _testIssue(
        title:
            'Excessive rebuilds detected in a very long widget path that '
            'would definitely truncate on narrow overlays',
        severity: IssueSeverity.critical,
      );
      final downstream = _testIssue(
        title: 'Downstream child',
        severity: IssueSeverity.warning,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                // Default overlay card width — the real user-facing
                // constraint the pin icon must survive.
                width: 300,
                child: IssueCard(
                  issue: rootIssue,
                  initiallyExpanded: true,
                  jankCorrelated: true,
                  locatable: true,
                  downstreamIssues: [downstream],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No RenderFlex overflow with every header badge present.
      expect(tester.takeException(), isNull);

      final pinFinder = find.byIcon(Icons.push_pin);
      expect(pinFinder, findsOneWidget);

      final pinRect = tester.getRect(pinFinder);
      final cardRect = tester.getRect(find.byType(Card));
      expect(
        pinRect.width,
        greaterThan(0),
        reason: 'Pin icon must render at a non-zero size.',
      );
      expect(
        cardRect.contains(pinRect.topLeft) &&
            cardRect.contains(pinRect.bottomRight),
        isTrue,
        reason:
            'Pin icon must be fully inside the card bounds even with '
            'long title + confidence + JANK + downstream + checkbox in '
            'the same header row. Pin rect: $pinRect, card rect: $cardRect',
      );

      // Final safety net: no additional, unexpected exceptions.
      expect(tester.takeException(), isNull);
    });
  });

  group('Ask AI shimmer', () {
    Widget card() => MaterialApp(
      home: Scaffold(
        body: IssueCard(
          issue: _testIssue(),
          initiallyExpanded: true,
          onAskAi: () {},
        ),
      ),
    );

    testWidgets('sweeps while animations are on', (tester) async {
      await tester.pumpWidget(card());
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('rests under reduce motion', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(card());
      // Settles: no repeating ticker.
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.text('Ask AI about this issue'), findsOneWidget);
    });

    testWidgets('rests under iOS Reduce Motion', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(card());
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('stops and restarts when Reduce Motion flips', (tester) async {
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(card());
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);

      // MediaQueryData does not change; the observer picks it up.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);

      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('link text is a solid token readable on every card fill; '
        'only the icon shimmers', (tester) async {
      const label = 'Ask AI about this issue';
      for (final theme in _presets) {
        for (final (highlighted, jankFlash) in [
          (false, false),
          (true, false),
          (false, true),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SleuthTheme(
                  data: theme,
                  child: IssueCard(
                    issue: _testIssue(),
                    initiallyExpanded: true,
                    highlighted: highlighted,
                    jankFlash: jankFlash,
                    onAskAi: () {},
                  ),
                ),
              ),
            ),
          );
          final text = tester.widget<Text>(find.text(label)).style!.color!;
          final fill = tester.widget<Card>(find.byType(Card)).color!;
          expect(text, theme.textSecondary);
          expect(
            wcagContrast(text, fill),
            greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness.name} on $fill',
          );
          // A shader over the text would replace its colour.
          expect(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(ShaderMask),
            ),
            findsNothing,
          );
          expect(
            find.ancestor(
              of: find.byIcon(Icons.auto_awesome),
              matching: find.byType(ShaderMask),
            ),
            findsOneWidget,
          );
        }
      }
    });
  });

  testWidgets('the highlight checkbox check keeps 3:1 on its fill', (
    tester,
  ) async {
    for (final theme in _presets) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SleuthTheme(
              data: theme,
              child: IssueCard(
                issue: _testIssue(),
                locatable: true,
                highlighted: true,
              ),
            ),
          ),
        ),
      );
      final box = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(box.activeColor, theme.checkboxActive);
      expect(
        wcagContrast(box.checkColor!, box.activeColor!),
        greaterThanOrEqualTo(3),
        reason: theme.brightness.name,
      );
    }
  });

  group('Inline category and confidence badges', () {
    Widget cards(double width, List<PerformanceIssue> issues) => MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: Column(
                children: [
                  for (final issue in issues)
                    IssueCard(issue: issue, locatable: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('keep their intrinsic width and a fixed right column', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        cards(480, [
          _testIssue(title: 'Short'),
          _testIssue(
            title:
                'A much longer title that has to ellipsize before the '
                'badges give way',
          ),
        ]),
      );
      expect(tester.takeException(), isNull);
      final confirmed = find.text('CONFIRMED');
      expect(confirmed, findsNWidgets(2));
      for (final element in confirmed.evaluate()) {
        final paragraph = element.renderObject! as RenderParagraph;
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      // Same right edge on both cards: the title takes the slack.
      expect(
        tester.getTopRight(confirmed.at(0)).dx,
        tester.getTopRight(confirmed.at(1)).dx,
      );
      // Beside the title.
      final title = find.text('Short');
      expect(
        (tester.getCenter(confirmed.at(0)).dy - tester.getCenter(title).dy)
            .abs(),
        lessThan(4),
      );
    });

    testWidgets('move to the badge line when the title would get narrow', (
      tester,
    ) async {
      await tester.pumpWidget(cards(300, [_testIssue(title: 'Short')]));
      expect(tester.takeException(), isNull);
      final confirmed = find.text('CONFIRMED');
      expect(
        tester.getTopLeft(confirmed).dy,
        greaterThan(tester.getBottomLeft(find.text('Short')).dy),
      );
      final paragraph = tester.renderObject<RenderParagraph>(confirmed);
      expect(paragraph.didExceedMaxLines, isFalse);
    });
  });
}
