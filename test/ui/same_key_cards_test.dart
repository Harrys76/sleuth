import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/ai_chat_adapter.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/issue_card.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';

import '../helpers/overlay_harness.dart';

const _adapter = AiChatAdapter(sendMessage: _reply);

Stream<String> _reply(AiChatRequest request) => Stream.value('ok');

/// An issue whose title and detail are named [name], so cards sharing a
/// stable id and widget can still be told apart.
PerformanceIssue _issue(
  String name, {
  required String id,
  String? widget,
  IssueSeverity severity = IssueSeverity.warning,
  IssueCategory category = IssueCategory.build,
  int? occurrence,
}) => PerformanceIssue(
  severity: severity,
  category: category,
  confidence: IssueConfidence.confirmed,
  title: 'Title $name',
  detail: 'Detail $name',
  fixHint: 'Fix $name',
  stableId: id,
  widgetName: widget,
  occurrenceId: occurrence,
);

void main() {
  group('applyFreezeZone with two issues sharing a list key', () {
    final a = _issue('a', id: 'heavy_compute', widget: 'Scope');
    final b = _issue('b', id: 'heavy_compute', widget: 'Scope');
    final c = _issue('c', id: 'jank_detected', widget: 'List');
    List<String> titles(List<PerformanceIssue> l) => [
      for (final i in l) i.title,
    ];

    List<FrozenCard> zone(List<PerformanceIssue> rows, int expanded) {
      final keys = occurrenceKeysFor(rows);
      return [
        for (var i = 0; i < rows.length; i++)
          (
            key: keys[i],
            issue: rows[i],
            expanded: i == expanded,
            reported: true,
          ),
      ];
    }

    test('expanding the third card keeps both of the pair', () {
      final result = applyFreezeZone(
        visibleIssues: [a, b, c],
        frozen: zone([a, b, c], 2),
      );
      expect(titles(result.issues), ['Title a', 'Title b', 'Title c']);
    });

    test('expanding the first of the pair keeps every card once', () {
      final result = applyFreezeZone(
        visibleIssues: [a, b, c],
        frozen: zone([a, b, c], 0),
      );
      expect(titles(result.issues), ['Title a', 'Title b', 'Title c']);
    });

    test('a frozen card keeps its key when a twin ahead of it goes; the '
        'flow skips it', () {
      final x1 = _issue('x1', id: 'layout', widget: 'Row', occurrence: 1);
      final x2 = _issue('x2', id: 'layout', widget: 'Row', occurrence: 2);
      final x3 = _issue('x3', id: 'layout', widget: 'Row', occurrence: 3);
      // x2 expanded under 'layout|Row#2'; x1 goes and x3 arrives.
      final result = applyFreezeZone(
        visibleIssues: [x3, x2],
        frozen: zone([x1, x2], 1),
      );
      expect(titles(result.issues), ['Title x2', 'Title x3']);
      expect(result.keys, ['layout|Row#2', 'layout|Row']);
    });

    test('a frozen card is matched by occurrence, not position', () {
      final x1 = _issue('x1', id: 'layout', widget: 'Row', occurrence: 1);
      final x2 = _issue('x2', id: 'layout', widget: 'Row', occurrence: 2);
      final x2b = _issue('x2b', id: 'layout', widget: 'Row', occurrence: 2);
      // x1 goes; the newer report of x2 is matched to its card.
      final result = applyFreezeZone(
        visibleIssues: [x2b],
        frozen: zone([x1, x2], 1),
      );
      final card = result.frozen!.single;
      expect(card.key, 'layout|Row#2');
      expect(identical(card.issue, x2b), isTrue);
      expect(card.reported, isTrue);
    });
  });

  test('occurrence keys number the later cards sharing a list key', () {
    final a = _issue('a', id: 'heavy_compute', widget: 'Scope');
    final b = _issue('b', id: 'heavy_compute', widget: 'Scope');
    final c = _issue('c', id: 'jank_detected', widget: 'List');
    expect(occurrenceKeysFor([a, b, c]), [
      'heavy_compute|Scope',
      'heavy_compute|Scope#2',
      'jank_detected|List',
    ]);
    expect(listKeyFor(a), listKeyFor(b));
  });

  test('hiding a warning leaves a later critical from the same detector '
      'and widget visible', () {
    final warning = _issue(
      'warn',
      id: 'jank_detected',
      widget: 'Feed',
      category: IssueCategory.raster,
    );
    final critical = _issue(
      'crit',
      id: 'jank_detected',
      widget: 'Feed',
      severity: IssueSeverity.critical,
      category: IssueCategory.raster,
    );
    final visible = applyOverlayFilters(
      [critical],
      severities: IssueSeverity.values.toSet(),
      hiddenKeys: {hideKeyFor(warning)},
    );
    expect([for (final i in visible) i.title], ['Title crit']);
  });

  group('cards sharing a stable id and widget', () {
    late SleuthController controller;

    setUp(
      () => controller = SleuthController(
        config: const SleuthConfig(aiChat: _adapter),
      )..initializeDetectorsForTest(),
    );
    tearDown(() => controller.dispose());

    Future<void> pumpCard(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(
              controller: controller,
              onClose: () {},
              isDebugMode: false,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Finder cardOf(String name) => find.ancestor(
      of: find.text('Title $name'),
      matching: find.byType(IssueCard),
    );

    Future<void> tapTitle(WidgetTester tester, String name) async {
      await tester.tap(find.text('Title $name'));
      await tester.pump();
    }

    bool isExpanded(String name) => find
        .descendant(of: cardOf(name), matching: expandedIssueCards())
        .evaluate()
        .isNotEmpty;

    testWidgets('a kept card keeps its expansion, and a new twin stays '
        'collapsed, when a card below them expands', (tester) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'layout', widget: 'Row', occurrence: 1),
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
        _issue('d', id: 'jank_detected', widget: 'List'),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'b');
      // a goes and c, a new occurrence, arrives.
      controller.issuesNotifier.value = [
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
        _issue('c', id: 'layout', widget: 'Row', occurrence: 3),
        _issue('d', id: 'jank_detected', widget: 'List'),
      ];
      await tester.pump();
      await tapTitle(tester, 'd');
      await tester.pump();
      expect(isExpanded('b'), isTrue);
      expect(isExpanded('c'), isFalse);
      expect(isExpanded('d'), isTrue);
    });

    testWidgets('an expanded card stays once its newer report goes too', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'layout', widget: 'Row', occurrence: 1),
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'b');
      controller.issuesNotifier.value = [
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await tester.pump();
      controller.issuesNotifier.value = [];
      await tester.pump();
      expect(find.text('Title b'), findsOneWidget);
      expect(isExpanded('b'), isTrue);
      expect(tester.widget<IssueCard>(cardOf('b')).stale, isTrue);
    });

    testWidgets('a card expanded beside a kept twin stays when its issue '
        'goes', (tester) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'layout', widget: 'Row', occurrence: 1),
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'b');
      // a goes; c, unrelated, arrives below b.
      controller.issuesNotifier.value = [
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
        _issue('c', id: 'jank_detected', widget: 'List'),
      ];
      await tester.pump();
      await tapTitle(tester, 'c');
      await tester.pump();
      controller.issuesNotifier.value = [
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await tester.pump();
      expect(find.text('Title c'), findsOneWidget);
      expect(isExpanded('c'), isTrue);
      expect(tester.widget<IssueCard>(cardOf('c')).stale, isTrue);

      // Collapsing it lets it go.
      await tapTitle(tester, 'c');
      await tester.pump();
      expect(find.text('Title c'), findsNothing);
      expect(isExpanded('b'), isTrue);
    });

    testWidgets('hiding one of an expanded pair hides both; neither stays', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'heavy_compute', widget: 'Scope'),
        _issue('b', id: 'heavy_compute', widget: 'Scope'),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'a');
      await tapTitle(tester, 'b');
      expect(expandedIssueCards(), findsNWidgets(2));

      await tapVisible(
        tester,
        find.descendant(
          of: cardOf('b'),
          matching: find.bySemanticsLabel('Hide'),
        ),
      );
      await tester.pump();
      // The shared hide key hides both, the expanded twin included.
      expect(find.text('Title a'), findsNothing);
      expect(find.text('Title b'), findsNothing);
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('of an expanded pair, only the card whose element went is '
        'stale', (tester) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'layout', widget: 'Row', occurrence: 1),
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'a');
      await tapTitle(tester, 'b');

      controller.issuesNotifier.value = [
        _issue('a', id: 'layout', widget: 'Row', occurrence: 1),
      ];
      await tester.pump();
      expect(expandedIssueCards(), findsNWidgets(2));
      expect(
        find.descendant(
          of: cardOf('b'),
          matching: find.text('Not detected right now'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: cardOf('a'),
          matching: find.text('Not detected right now'),
        ),
        findsNothing,
      );
    });

    testWidgets('when the first of an expanded pair goes, each card shows '
        'once and only the gone one is stale', (tester) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'layout', widget: 'Row', occurrence: 1),
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'a');
      await tapTitle(tester, 'b');

      // b now holds the occurrence key a had.
      controller.issuesNotifier.value = [
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await tester.pump();
      expect(find.text('Title a'), findsOneWidget);
      expect(find.text('Title b'), findsOneWidget);
      expect(tester.widget<IssueCard>(cardOf('a')).stale, isTrue);
      expect(tester.widget<IssueCard>(cardOf('b')).stale, isFalse);
    });

    testWidgets('when the expanded first of a pair goes, the other stays in '
        'the list once', (tester) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'layout', widget: 'Row', occurrence: 1),
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'a');
      controller.issuesNotifier.value = [
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await tester.pump();
      expect(find.text('Title a'), findsOneWidget);
      expect(find.text('Title b'), findsOneWidget);
      expect(tester.widget<IssueCard>(cardOf('a')).stale, isTrue);
    });

    testWidgets('the expanded second of a pair stays expanded when the '
        'first goes', (tester) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'layout', widget: 'Row', occurrence: 1),
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'b');
      expect(expandedIssueCards(), findsOneWidget);

      controller.issuesNotifier.value = [
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await tester.pump();
      await tester.pump();
      expect(find.text('Title a'), findsNothing);
      expect(find.text('Title b'), findsOneWidget);
      expect(expandedIssueCards(), findsOneWidget);
      expect(tester.widget<IssueCard>(cardOf('b')).stale, isFalse);

      // Collapsing it works on the key it is shown under.
      await tapTitle(tester, 'b');
      expect(expandedIssueCards(), findsNothing);
      expect(find.text('Title b'), findsOneWidget);
    });

    testWidgets('expanding the card that replaced a twin keeps that card '
        'and does not bring the old one back', (tester) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'layout', widget: 'Row', occurrence: 1),
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'b');
      // c replaces a under the same list key.
      controller.issuesNotifier.value = [
        _issue('c', id: 'layout', widget: 'Row', occurrence: 3),
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await tester.pump();
      await tapTitle(tester, 'c');
      await tester.pump();
      expect(find.text('Title a'), findsNothing);
      expect(find.text('Title c'), findsOneWidget);
      expect(expandedIssueCards(), findsNWidgets(2));
      expect(tester.widget<IssueCard>(cardOf('c')).stale, isFalse);
      expect(tester.widget<IssueCard>(cardOf('b')).stale, isFalse);
    });

    testWidgets('a kept card\'s crosshair stays on through later updates', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'layout', widget: 'Row', occurrence: 1),
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'b');
      controller.issuesNotifier.value = [
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await tester.pump();

      final target = find.descendant(of: cardOf('b'), matching: crosshair());
      await tester.tap(target);
      await tester.pump();
      controller.selectedHighlightNotifier.value = const WidgetHighlight(
        rect: Rect.fromLTWH(0, 0, 10, 10),
        widgetName: 'Row',
        severity: IssueSeverity.warning,
        detectorName: 'LayoutDetector',
        occurrenceId: 2,
      );
      await tester.pump();
      expect(crosshairOn(tester, target), isTrue);

      // A later report of the same issue keeps the selection.
      controller.issuesNotifier.value = [
        _issue('b', id: 'layout', widget: 'Row', occurrence: 2),
      ];
      await tester.pump();
      expect(crosshairOn(tester, target), isTrue);
      expect(controller.selectedHighlightNotifier.value, isNotNull);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('hiding the live one of an expanded pair also hides its '
        'stale twin', (tester) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'heavy_compute', widget: 'Scope', occurrence: 1),
        _issue('b', id: 'heavy_compute', widget: 'Scope', occurrence: 2),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'a');
      await tapTitle(tester, 'b');
      controller.issuesNotifier.value = [
        _issue('b', id: 'heavy_compute', widget: 'Scope', occurrence: 2),
      ];
      await tester.pump();
      expect(tester.widget<IssueCard>(cardOf('a')).stale, isTrue);

      await tapVisible(
        tester,
        find.descendant(
          of: cardOf('b'),
          matching: find.bySemanticsLabel('Hide'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Title a'), findsNothing);
      expect(find.text('Title b'), findsNothing);
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('an expanded card goes when it falls back under its hide '
        'key', (tester) async {
      // Hidden while a warning; it came back critical and was expanded.
      controller.overlayUiState.hide(
        hideKeyFor(_issue('a', id: 'heavy_compute')),
      );
      controller.issuesNotifier.value = [
        _issue('a', id: 'heavy_compute', severity: IssueSeverity.critical),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'a');
      expect(expandedIssueCards(), findsOneWidget);

      controller.issuesNotifier.value = [_issue('a', id: 'heavy_compute')];
      await tester.pump();
      expect(find.text('Title a'), findsNothing);
      await tester.pump();
      expect(find.text('Title a'), findsNothing);
    });

    testWidgets('a card that outlives its issue shows the last report, not '
        'the one it was expanded with', (tester) async {
      controller.issuesNotifier.value = [_issue('a', id: 'heavy_compute')];
      await pumpCard(tester);
      await tapTitle(tester, 'a');
      // The issue turns critical, then stops being reported.
      controller.issuesNotifier.value = [
        _issue('a', id: 'heavy_compute', severity: IssueSeverity.critical),
      ];
      await tester.pump();
      controller.issuesNotifier.value = const [];
      await tester.pump();
      final card = tester.widget<IssueCard>(cardOf('a'));
      expect(card.issue.severity, IssueSeverity.critical);
      expect(card.stale, isTrue);
    });

    testWidgets('expanding an unrelated card keeps both of the pair', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'heavy_compute', widget: 'Scope'),
        _issue('b', id: 'heavy_compute', widget: 'Scope'),
        _issue('c', id: 'jank_detected', widget: 'List'),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'c');
      expect(tester.takeException(), isNull);

      expect(find.text('Title a'), findsOneWidget);
      expect(find.text('Title b'), findsOneWidget);
      expect(find.text('Title c'), findsOneWidget);
    });

    testWidgets('expanding the first of the pair shows its own detail and '
        'leaves the second collapsed', (tester) async {
      controller.issuesNotifier.value = [
        _issue('a', id: 'heavy_compute', widget: 'Scope'),
        _issue('b', id: 'heavy_compute', widget: 'Scope'),
        _issue('c', id: 'jank_detected', widget: 'List'),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'a');
      expect(tester.takeException(), isNull);

      expect(find.text('Title a'), findsOneWidget);
      expect(find.text('Title b'), findsOneWidget);
      expect(find.text('Detail a'), findsOneWidget);
      expect(find.text('Detail b'), findsNothing);
    });

    testWidgets('ticking the highlight on one of the pair leaves the other '
        'unticked', (tester) async {
      controller.issuesNotifier.value = [
        _issue(
          'a',
          id: 'layout_bottleneck',
          widget: 'Row',
          category: IssueCategory.layout,
        ),
        _issue(
          'b',
          id: 'layout_bottleneck',
          widget: 'Row',
          category: IssueCategory.layout,
        ),
      ];
      await pumpCard(tester);
      Finder checkboxOf(String name) =>
          find.descendant(of: cardOf(name), matching: crosshair());
      await tester.tap(checkboxOf('a'));
      await tester.pump();
      controller.selectedHighlightNotifier.value = const WidgetHighlight(
        rect: Rect.fromLTWH(0, 0, 10, 10),
        widgetName: 'Row',
        severity: IssueSeverity.warning,
        detectorName: 'LayoutDetector',
      );
      await tester.pump();

      expect(crosshairOn(tester, checkboxOf('a')), isTrue);
      expect(crosshairOn(tester, checkboxOf('b')), isFalse);
    });

    testWidgets('Ask AI on the second of two same-id cards opens a chat '
        'about that card', (tester) async {
      controller.issuesNotifier.value = [
        _issue('list', id: 'non_lazy_shrinkwrap', widget: 'ListView'),
        _issue('grid', id: 'non_lazy_shrinkwrap', widget: 'GridView'),
      ];
      await pumpCard(tester);
      await tapTitle(tester, 'grid');
      final askAi = find.descendant(
        of: cardOf('grid'),
        matching: find.bySemanticsLabel('Ask AI'),
      );
      await tester.ensureVisible(askAi);
      await tester.pump();
      await tester.tap(askAi);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);

      expect(find.text('Title grid'), findsOneWidget);
      expect(find.text('Title list'), findsNothing);
    });
  });

  testWidgets('the card fits a screen whose usable height is under the '
      '300 px minimum', (tester) async {
    tester.view.physicalSize = const Size(400, 270);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = await pumpOverlay(
      tester,
      config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
    );
    controller.overlayUiState.setCardGeometry(
      offset: Offset.zero,
      width: 300,
      height: 300,
      windowState: CardWindowState.normal,
    );
    controller.issuesNotifier.value = mixedOverlayIssues();
    await openDashboard(tester, controller);
    expect(tester.takeException(), isNull);

    final grip = tester.getRect(find.bySemanticsLabel('Resize card'));
    expect(grip.bottom, lessThanOrEqualTo(270));
  });
}
