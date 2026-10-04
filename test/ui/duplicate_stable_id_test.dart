import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/issue_card.dart';

/// An issue with detector id [id] reported on [widget]; the title names
/// the widget so the two cards can be told apart.
PerformanceIssue _issue(
  String id, {
  String? widget,
  IssueSeverity severity = IssueSeverity.warning,
  IssueCategory category = IssueCategory.build,
  List<String>? rootCauseIds,
  List<String>? downstreamIds,
}) => PerformanceIssue(
  severity: severity,
  category: category,
  confidence: IssueConfidence.confirmed,
  title: 'Title ${widget ?? id}',
  detail: 'Detail $id',
  fixHint: 'Fix $id',
  stableId: id,
  widgetName: widget,
  rootCauseIds: rootCauseIds,
  downstreamIds: downstreamIds,
);

void main() {
  late SleuthController controller;

  setUp(() => controller = SleuthController()..initializeDetectorsForTest());
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

  Future<void> drainToasts(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> tapTitle(WidgetTester tester, String name) async {
    await tester.tap(find.text('Title $name'));
    await tester.pump();
  }

  Finder cardOf(String name) => find.ancestor(
    of: find.text('Title $name'),
    matching: find.byType(IssueCard),
  );

  Finder checkboxOf(String name) =>
      find.descendant(of: cardOf(name), matching: find.byType(Checkbox));

  bool? checked(WidgetTester tester, String name) =>
      tester.widget<Checkbox>(checkboxOf(name)).value;

  Future<void> hideVia(WidgetTester tester, String name) async {
    await tester.tap(
      find.descendant(
        of: cardOf(name),
        matching: find.bySemanticsLabel('Hide this issue'),
      ),
    );
    await tester.pump();
  }

  List<String> rowOrder(WidgetTester tester, List<String> names) {
    final shown = [
      for (final n in names)
        if (find.text('Title $n').evaluate().isNotEmpty) n,
    ];
    return shown..sort(
      (a, b) => tester
          .getTopLeft(find.text('Title $a'))
          .dy
          .compareTo(tester.getTopLeft(find.text('Title $b')).dy),
    );
  }

  test('listKeyFor appends the widget name', () {
    expect(listKeyFor(_issue('dup', widget: 'A')), 'dup|A');
    expect(listKeyFor(_issue('dup')), 'dup');
    expect(
      listKeyFor(_issue('dup', widget: 'A')),
      hideKeyFor(_issue('dup', widget: 'A')),
    );
  });

  testWidgets('same stableId on two widgets renders two cards', (tester) async {
    controller.issuesNotifier.value = [
      _issue('dup', widget: 'A'),
      _issue('dup', widget: 'B'),
    ];
    await pumpCard(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(IssueCard), findsNWidgets(2));
    expect(find.text('Title A'), findsOneWidget);
    expect(find.text('Title B'), findsOneWidget);
  });

  testWidgets('hiding one leaves the other visible; footer reads 1 hidden', (
    tester,
  ) async {
    controller.issuesNotifier.value = [
      _issue('dup', widget: 'A'),
      _issue('dup', widget: 'B'),
    ];
    await pumpCard(tester);
    await tapTitle(tester, 'A');
    await hideVia(tester, 'A');

    expect(tester.takeException(), isNull);
    expect(find.text('Title A'), findsNothing);
    expect(find.text('Title B'), findsOneWidget);
    expect(find.text('1 hidden'), findsOneWidget);
    expect(controller.overlayUiState.hiddenKeys, {'dup|A'});
    await drainToasts(tester);
  });

  testWidgets('expanding both then an issues update keeps the freeze zone '
      'consistent', (tester) async {
    controller.issuesNotifier.value = [
      _issue('dup', widget: 'A'),
      _issue('other'),
      _issue('dup', widget: 'B'),
    ];
    await pumpCard(tester);
    await tapTitle(tester, 'A');
    await tapTitle(tester, 'B');
    expect(find.byIcon(Icons.push_pin), findsNWidgets(2));

    // The ranker reorders and a new critical lands.
    controller.issuesNotifier.value = [
      _issue('new', severity: IssueSeverity.critical),
      _issue('dup', widget: 'B'),
      _issue('other'),
      _issue('dup', widget: 'A'),
    ];
    await tester.pump();
    expect(tester.takeException(), isNull);
    const names = ['A', 'other', 'B', 'new'];
    expect(rowOrder(tester, names), ['A', 'other', 'B', 'new']);
    expect(find.byIcon(Icons.push_pin), findsNWidgets(2));

    // One of the pair leaves; the other stays expanded.
    controller.issuesNotifier.value = [
      _issue('dup', widget: 'B'),
      _issue('other'),
    ];
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byType(IssueCard), findsNWidgets(2));
  });

  testWidgets('the highlight selects one card; hiding the other keeps it, '
      'hiding the selected one clears it', (tester) async {
    controller.issuesNotifier.value = [
      _issue('dup', widget: 'A', category: IssueCategory.layout),
      _issue('dup', widget: 'B', category: IssueCategory.layout),
    ];
    await pumpCard(tester);
    await tester.tap(checkboxOf('A'));
    await tester.pump();
    expect(controller.pendingIssueSelection?.widgetName, 'A');
    // The scan resolves the pending selection to A's widget.
    controller.selectedHighlightNotifier.value = const WidgetHighlight(
      rect: Rect.fromLTWH(0, 0, 10, 10),
      widgetName: 'A',
      severity: IssueSeverity.warning,
      detectorName: 'LayoutDetector',
    );
    await tester.pump();
    expect(checked(tester, 'A'), isTrue);
    expect(checked(tester, 'B'), isFalse);

    await tapTitle(tester, 'B');
    await hideVia(tester, 'B');
    expect(controller.selectedHighlightNotifier.value, isNotNull);
    expect(checked(tester, 'A'), isTrue);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(checked(tester, 'B'), isFalse);

    await tapTitle(tester, 'A');
    await hideVia(tester, 'A');
    expect(controller.selectedHighlightNotifier.value, isNull);
    expect(controller.pendingIssueSelection, isNull);
    expect(find.text('Title A'), findsNothing);
    expect(checked(tester, 'B'), isFalse);
    expect(tester.takeException(), isNull);
    await drainToasts(tester);
  });

  test('computeVisibleIssues collapses a child naming a shared stableId; '
      'the parent rank is the most severe card carrying that id', () {
    final a = _issue('dup', widget: 'A', downstreamIds: ['child']);
    final b = _issue(
      'dup',
      widget: 'B',
      severity: IssueSeverity.critical,
      downstreamIds: ['child'],
    );
    final child = _issue(
      'child',
      severity: IssueSeverity.critical,
      rootCauseIds: ['dup'],
    );
    expect(computeVisibleIssues([a, b, child]), [a, b]);
    // Only the warning holder of the id: a critical child stays standalone.
    expect(computeVisibleIssues([a, child]), [a, child]);
  });
}
