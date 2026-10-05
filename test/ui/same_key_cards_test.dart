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
}) => PerformanceIssue(
  severity: severity,
  category: category,
  confidence: IssueConfidence.confirmed,
  title: 'Title $name',
  detail: 'Detail $name',
  fixHint: 'Fix $name',
  stableId: id,
  widgetName: widget,
);

void main() {
  group('applyFreezeZone with two issues sharing a list key', () {
    final a = _issue('a', id: 'heavy_compute', widget: 'Scope');
    final b = _issue('b', id: 'heavy_compute', widget: 'Scope');
    final c = _issue('c', id: 'jank_detected', widget: 'List');
    List<String> titles(List<PerformanceIssue> l) => [
      for (final i in l) i.title,
    ];

    test('expanding the third card keeps both of the pair', () {
      final result = applyFreezeZone(
        visibleIssues: [a, b, c],
        orderSnapshot: [a, b, c],
        expandedIndices: {listKeyFor(c): 2},
      );
      expect(titles(result), ['Title a', 'Title b', 'Title c']);
    });

    test('expanding the first of the pair keeps every card once', () {
      final result = applyFreezeZone(
        visibleIssues: [a, b, c],
        orderSnapshot: [a, b, c],
        expandedIndices: {listKeyFor(a): 0},
      );
      expect(titles(result), ['Title a', 'Title b', 'Title c']);
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
          find.descendant(of: cardOf(name), matching: find.byType(Checkbox));
      await tester.tap(checkboxOf('a'));
      await tester.pump();
      controller.selectedHighlightNotifier.value = const WidgetHighlight(
        rect: Rect.fromLTWH(0, 0, 10, 10),
        widgetName: 'Row',
        severity: IssueSeverity.warning,
        detectorName: 'LayoutDetector',
      );
      await tester.pump();

      expect(tester.widget<Checkbox>(checkboxOf('a')).value, isTrue);
      expect(tester.widget<Checkbox>(checkboxOf('b')).value, isFalse);
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
        matching: find.text('Ask AI about this issue'),
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
