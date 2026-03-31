import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/models/widget_highlight.dart';
import 'package:widget_watchdog/src/ui/highlight_overlay.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  group('HighlightOverlay', () {
    testWidgets('renders no CustomPaint when empty', (tester) async {
      final highlights = ValueNotifier<List<WidgetHighlight>>([]);
      final selected = ValueNotifier<WidgetHighlight?>(null);

      await tester.pumpWidget(wrap(
        HighlightOverlay(
          highlights: highlights,
          selectedHighlight: selected,
        ),
      ));

      // Empty state renders SizedBox.shrink, not CustomPaint
      expect(
        find.descendant(
          of: find.byType(HighlightOverlay),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );

      highlights.dispose();
      selected.dispose();
    });

    testWidgets('renders CustomPaint with highlights', (tester) async {
      final highlights = ValueNotifier<List<WidgetHighlight>>([
        const WidgetHighlight(
          rect: Rect.fromLTWH(10, 10, 100, 50),
          widgetName: 'MyWidget',
          severity: IssueSeverity.warning,
          detectorName: 'RebuildDetector',
        ),
      ]);
      final selected = ValueNotifier<WidgetHighlight?>(null);

      await tester.pumpWidget(wrap(
        HighlightOverlay(
          highlights: highlights,
          selectedHighlight: selected,
        ),
      ));

      expect(
        find.descendant(
          of: find.byType(HighlightOverlay),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );

      highlights.dispose();
      selected.dispose();
    });

    testWidgets('renders CustomPaint with selected highlight', (tester) async {
      final highlights = ValueNotifier<List<WidgetHighlight>>([]);
      const highlight = WidgetHighlight(
        rect: Rect.fromLTWH(20, 20, 80, 40),
        widgetName: 'SelectedWidget',
        severity: IssueSeverity.critical,
        detectorName: 'GpuPressureDetector',
        detail: 'GPU pressure detected',
      );
      final selected = ValueNotifier<WidgetHighlight?>(highlight);

      await tester.pumpWidget(wrap(
        HighlightOverlay(
          highlights: highlights,
          selectedHighlight: selected,
        ),
      ));

      expect(
        find.descendant(
          of: find.byType(HighlightOverlay),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );

      highlights.dispose();
      selected.dispose();
    });

    testWidgets('wraps in IgnorePointer', (tester) async {
      final highlights = ValueNotifier<List<WidgetHighlight>>([]);
      final selected = ValueNotifier<WidgetHighlight?>(null);

      await tester.pumpWidget(wrap(
        HighlightOverlay(
          highlights: highlights,
          selectedHighlight: selected,
        ),
      ));

      expect(
        find.descendant(
          of: find.byType(HighlightOverlay),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );

      highlights.dispose();
      selected.dispose();
    });
  });
}
