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
    c.publishHighlightsForTest([_h(1)]);
    c.selectHighlightForIssue(
      _issue('repaint_debug_CustomPaint', widgetName: 'CustomPaint'),
    );
    expect(c.selectedHighlightNotifier.value, isNotNull);
    expect(c.highlightStepNotifier.value, isNull);
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
}
