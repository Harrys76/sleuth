@Tags(['benchmark'])
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/issue_card.dart';

import '../helpers/overlay_harness.dart';

// The overlay builds inside the app's frames, where Sleuth's own-work log
// does not reach, so every extra overlay build adds to the app's
// rebuild_activity share. A change that builds the card more often per
// scan tick than [_budgets] allows fails here. Build time is printed, not
// asserted, so the test does not flake on a busy machine.

/// Builds of [FloatingIssuesCard] and of all [IssueCard]s over 50 ticks.
typedef _Builds = ({int card, int issueCards});

/// Recorded with the 1.0.0 header, status row, More menu, collapsed card
/// and the one debug banner (Flutter 3.47.6, 390 x 844 view). A title
/// change rebuilds each card the list has built, the ones on screen plus
/// the cache extent: 9 collapsed or 5 with three expanded. The collapsed
/// card has no 48 px checkbox setting its height, and one banner takes
/// less room than the two it replaced, so more cards fit than before the
/// redesign (5 per change then).
const _budgets = <String, _Builds>{
  'collapsed, no change': (card: 0, issueCards: 0),
  'collapsed, title change': (card: 0, issueCards: 450),
  'three expanded, no change': (card: 0, issueCards: 0),
  'three expanded, title change': (card: 0, issueCards: 250),
};

const _ticks = 50;

/// 20 issues across severities, categories and confidences; every fourth
/// names a widget.
List<PerformanceIssue> _issues({String suffix = ''}) => [
  for (var i = 0; i < 20; i++)
    PerformanceIssue(
      stableId: 'issue_$i',
      severity: IssueSeverity.values[i % 3],
      category: IssueCategory.values[i % IssueCategory.values.length],
      confidence: IssueConfidence.values[i % 3],
      title: 'Title $i${i == 0 ? suffix : ''}',
      detail: 'Detail for issue $i, long enough to wrap onto a second line.',
      fixHint: 'Fix hint $i.',
      widgetName: i % 4 == 0 ? 'Widget$i' : null,
    ),
];

void main() {
  /// Counts card builds while [tick] runs [_ticks] times, one scan tick
  /// (1 s) apart, and reports the time a tick's frame took.
  Future<_Builds> measure(
    WidgetTester tester,
    SleuthController controller,
    String label,
    void Function(int tick) tick,
  ) async {
    var card = 0;
    var issueCards = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      final widget = element.widget;
      if (widget is FloatingIssuesCard) {
        card++;
      } else if (widget is IssueCard) {
        issueCards++;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    final watch = Stopwatch();
    for (var i = 0; i < _ticks; i++) {
      tick(i);
      controller.scanTickNotifier.value++;
      watch.start();
      await tester.pump(const Duration(seconds: 1));
      watch.stop();
    }
    debugOnRebuildDirtyWidget = null;
    // ignore: avoid_print
    print(
      '  $label: card $card, issue cards $issueCards builds over $_ticks '
      'ticks; ${(watch.elapsedMicroseconds / _ticks).toStringAsFixed(0)} µs '
      'per tick',
    );
    return (card: card, issueCards: issueCards);
  }

  Future<SleuthController> openWithIssues(
    WidgetTester tester, {
    required bool expandThree,
  }) async {
    // A phone-sized view (iPhone 12 points); on a short surface the
    // debug-mode banners leave the list too little room to expand three
    // cards.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // No real scan runs, so the seeded issues stay for the whole run.
    final controller = await pumpOverlay(
      tester,
      config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
    );
    controller.seedIssuesForTest(_issues());
    await openDashboard(tester, controller);
    if (expandThree) {
      final titles = [
        for (final card in tester.widgetList<IssueCard>(find.byType(IssueCard)))
          card.issue.title,
      ].take(3);
      for (final title in titles) {
        // An earlier expansion can push the card out of view.
        await tester.ensureVisible(find.text(title, skipOffstage: false));
        await tester.pump();
        await tester.tap(find.text(title));
        await tester.pump();
      }
      expect(find.byType(IssueCard), findsWidgets);
    }
    // ignore: avoid_print
    print(
      '  open: ${find.byType(IssueCard).evaluate().length} cards on screen, '
      '${controller.issuesNotifier.value.length} issues',
    );
    // Lets the new-card accents and the expansion animations finish.
    await tester.pump(const Duration(seconds: 3));
    return controller;
  }

  for (final expandThree in [false, true]) {
    final layout = expandThree ? 'three expanded' : 'collapsed';

    testWidgets('$layout, no change', (tester) async {
      final controller = await openWithIssues(tester, expandThree: expandThree);
      final label = '$layout, no change';
      final builds = await measure(tester, controller, label, (_) {});
      expect(builds.card, lessThanOrEqualTo(_budgets[label]!.card));
      expect(builds.issueCards, lessThanOrEqualTo(_budgets[label]!.issueCards));
    }, semanticsEnabled: false);

    testWidgets('$layout, title change', (tester) async {
      final controller = await openWithIssues(tester, expandThree: expandThree);
      final label = '$layout, title change';
      final builds = await measure(tester, controller, label, (i) {
        controller.issuesNotifier.value = _issues(suffix: i.isEven ? ' *' : '');
      });
      expect(builds.card, lessThanOrEqualTo(_budgets[label]!.card));
      expect(builds.issueCards, lessThanOrEqualTo(_budgets[label]!.issueCards));
    }, semanticsEnabled: false);
  }
}
