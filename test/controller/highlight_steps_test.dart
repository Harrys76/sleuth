import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/highlight_lookup.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';

PerformanceIssue _issue(String? stableId, {String? widgetName}) =>
    PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.paint,
      confidence: IssueConfidence.possible,
      title: 'T',
      detail: 'D',
      fixHint: 'F',
      stableId: stableId,
      widgetName: widgetName,
    );

WidgetHighlight _h(
  int occurrence, {
  String stableId = 'always_repaint_painter',
  RenderObject? renderObject,
  Rect rect = const Rect.fromLTWH(0, 0, 10, 10),
}) => WidgetHighlight(
  rect: rect,
  widgetName: 'CustomPaint',
  severity: IssueSeverity.warning,
  detectorName: 'Painter',
  occurrenceId: occurrence,
  stableId: stableId,
  renderObject: renderObject,
);

void main() {
  test('only an unnamed issue of a list family lists widgets', () {
    for (final id in [
      'always_repaint_painter',
      'missing_repaint_boundary',
      'layout_bottleneck',
      'uncached_images',
      'expensive_gpu_nodes',
    ]) {
      expect(SleuthController.listsWidgets(_issue(id)), isTrue, reason: id);
    }
    expect(
      SleuthController.listsWidgets(
        _issue('always_repaint_painter', widgetName: 'CustomPaint'),
      ),
      isFalse,
    );
    expect(SleuthController.listsWidgets(_issue('jank_detected')), isFalse);
    expect(SleuthController.listsWidgets(_issue(null)), isFalse);
  });

  testWidgets('steps count each element once and only the issue\'s own '
      'highlights; clearing ends the step', (tester) async {
    final c = SleuthController();
    addTearDown(c.dispose);
    c.scanTickNotifier.value = 1;
    c.publishHighlightsForTest([
      _h(1),
      // A CustomPaint with both painters reports its element twice.
      _h(1),
      _h(2, stableId: 'missing_repaint_boundary'),
      _h(3),
    ]);

    expect(
      c.selectHighlightForIssue(_issue('always_repaint_painter')),
      HighlightLookup.found,
    );
    expect(c.highlightStepNotifier.value, (index: 0, count: 2));
    c.nextHighlightStep();
    expect(c.selectedHighlightNotifier.value?.occurrenceId, 3);

    c.clearSelectedHighlight();
    expect(c.highlightStepNotifier.value, isNull);
    c.nextHighlightStep();
    expect(c.selectedHighlightNotifier.value, isNull);
  });

  testWidgets('a named issue has no step', (tester) async {
    final c = SleuthController();
    addTearDown(c.dispose);
    c.scanTickNotifier.value = 1;
    // A list card's tagged highlight and the repaint card's own one.
    const own = WidgetHighlight(
      rect: Rect.fromLTWH(0, 20, 10, 10),
      widgetName: 'CustomPaint',
      severity: IssueSeverity.warning,
      detectorName: 'Repaint',
    );
    c.publishHighlightsForTest([_h(1), own]);
    c.selectHighlightForIssue(
      _issue('repaint_debug_CustomPaint', widgetName: 'CustomPaint'),
    );
    expect(c.selectedHighlightNotifier.value, same(own));
    expect(c.highlightStepNotifier.value, isNull);
  });

  testWidgets('steps start on the first row the list shows and count only '
      'the rows it shows', (tester) async {
    // The list shows y 100 to 300; scrolled by 75 it builds rows 0 to 10
    // (its cache extent) and shows rows 1 to 5.
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 100),
            child: SizedBox(
              width: 100,
              height: 200,
              child: ListView.builder(
                controller: ScrollController(initialScrollOffset: 75),
                itemExtent: 50,
                itemCount: 20,
                itemBuilder: (_, i) => SizedBox(key: Key('row-$i')),
              ),
            ),
          ),
        ),
      ),
    );
    final c = SleuthController();
    addTearDown(c.dispose);
    c.scanTickNotifier.value = 1;
    c.publishHighlightsForTest([
      for (var i = 0; i <= 10; i++)
        _h(
          i,
          renderObject: tester.renderObject(
            find.byKey(Key('row-$i'), skipOffstage: false),
          ),
        ),
    ]);

    final items = c.highlightsNotifier.value.items;
    expect([for (final h in items) h.occurrenceId], [1, 2, 3, 4, 5]);
    expect(items.first.rect, const Rect.fromLTRB(0, 100, 100, 125));
    expect(
      c.selectHighlightForIssue(_issue('always_repaint_painter')),
      HighlightLookup.found,
    );
    expect(c.selectedHighlightNotifier.value?.occurrenceId, 1);
    expect(c.highlightStepNotifier.value, (index: 0, count: 5));
  });

  testWidgets('a rect refresh after a scroll keeps the step', (tester) async {
    final keys = [GlobalKey(), GlobalKey()];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            for (final k in keys) SizedBox(key: k, width: 50, height: 50),
          ],
        ),
      ),
    );
    final c = SleuthController();
    addTearDown(c.dispose);
    c.scanTickNotifier.value = 1;
    c.publishHighlightsForTest([
      for (var i = 0; i < keys.length; i++)
        _h(
          10 + i,
          renderObject: keys[i].currentContext!.findRenderObject(),
          rect: Rect.fromLTWH(0, 50.0 * i, 50, 50),
        ),
    ]);
    c.selectHighlightForIssue(_issue('always_repaint_painter'));

    c.refreshHighlightRects();
    await tester.pump();
    expect(
      c.highlightsNotifier.value.items.map((h) => h.stableId),
      everyElement('always_repaint_painter'),
    );
    c.nextHighlightStep();
    expect(c.selectedHighlightNotifier.value?.occurrenceId, 11);
    expect(c.highlightStepNotifier.value, (index: 1, count: 2));
  });

  testWidgets('an outline never moves to another issue\'s highlight of the '
      'same element', (tester) async {
    final c = SleuthController();
    addTearDown(c.dispose);
    c.scanTickNotifier.value = 1;
    c.publishHighlightsForTest([_h(1), _h(2)]);
    c.selectHighlightForIssue(_issue('always_repaint_painter'));
    expect(c.selectedHighlightNotifier.value?.occurrenceId, 1);

    // The painter is fixed but its element still lacks a RepaintBoundary.
    c.publishHighlightsForTest([
      _h(1, stableId: 'missing_repaint_boundary'),
      _h(2),
    ]);
    expect(c.selectedHighlightNotifier.value, isNull);

    // A named issue on that element ignores the list issue's highlight.
    final named = PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.layout,
      confidence: IssueConfidence.possible,
      title: 'W',
      detail: 'D',
      fixHint: 'F',
      stableId: 'wrap_layout_bottleneck',
      widgetName: 'Wrap',
      occurrenceId: 1,
    );
    expect(c.selectHighlightForIssue(named), HighlightLookup.notFound);
  });

  testWidgets('Next appears when others arrive while the outlined widget '
      'is gone', (tester) async {
    final c = SleuthController();
    addTearDown(c.dispose);
    c.scanTickNotifier.value = 1;
    c.publishHighlightsForTest([_h(1)]);
    c.selectHighlightForIssue(_issue('always_repaint_painter'));
    expect(c.highlightStepNotifier.value, (index: 0, count: 1));

    c.publishHighlightsForTest([_h(2), _h(3)]);
    expect(c.selectedHighlightNotifier.value, isNull);
    expect(c.highlightStepNotifier.value?.count, 2);
    c.nextHighlightStep();
    expect(c.selectedHighlightNotifier.value?.occurrenceId, 2);
  });

  testWidgets('Next comes back when a widget arrives after none were left', (
    tester,
  ) async {
    final c = SleuthController();
    addTearDown(c.dispose);
    c.scanTickNotifier.value = 1;
    c.publishHighlightsForTest([_h(1), _h(2)]);
    c.selectHighlightForIssue(_issue('always_repaint_painter'));

    // A rect refresh mid-scroll drops every highlight.
    c.publishHighlightsForTest([]);
    expect(c.canStepNext, isFalse);
    c.publishHighlightsForTest([_h(3)]);
    expect(c.canStepNext, isTrue);
    c.nextHighlightStep();
    expect(c.selectedHighlightNotifier.value?.occurrenceId, 3);
  });
}
