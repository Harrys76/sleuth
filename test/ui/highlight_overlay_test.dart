import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';
import 'package:sleuth/src/ui/highlight_overlay.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  group('HighlightOverlay', () {
    testWidgets('renders no CustomPaint when empty', (tester) async {
      final highlights =
          ValueNotifier<({int generation, List<WidgetHighlight> items})>((
            generation: 0,
            items: [],
          ));
      final selected = ValueNotifier<WidgetHighlight?>(null);
      final markers = ValueNotifier<bool>(true);
      addTearDown(markers.dispose);

      await tester.pumpWidget(
        wrap(
          HighlightOverlay(
            highlights: highlights,
            selectedHighlight: selected,
            markersEnabled: markers,
          ),
        ),
      );

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
      final highlights =
          ValueNotifier<({int generation, List<WidgetHighlight> items})>((
            generation: 1,
            items: [
              const WidgetHighlight(
                rect: Rect.fromLTWH(10, 10, 100, 50),
                widgetName: 'MyWidget',
                severity: IssueSeverity.warning,
                detectorName: 'RebuildDetector',
              ),
            ],
          ));
      final selected = ValueNotifier<WidgetHighlight?>(null);
      final markers = ValueNotifier<bool>(true);
      addTearDown(markers.dispose);

      await tester.pumpWidget(
        wrap(
          HighlightOverlay(
            highlights: highlights,
            selectedHighlight: selected,
            markersEnabled: markers,
          ),
        ),
      );

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
      final highlights =
          ValueNotifier<({int generation, List<WidgetHighlight> items})>((
            generation: 0,
            items: [],
          ));
      const highlight = WidgetHighlight(
        rect: Rect.fromLTWH(20, 20, 80, 40),
        widgetName: 'SelectedWidget',
        severity: IssueSeverity.critical,
        detectorName: 'GpuPressureDetector',
        detail: 'GPU pressure detected',
      );
      final selected = ValueNotifier<WidgetHighlight?>(highlight);
      final markers = ValueNotifier<bool>(true);
      addTearDown(markers.dispose);

      await tester.pumpWidget(
        wrap(
          HighlightOverlay(
            highlights: highlights,
            selectedHighlight: selected,
            markersEnabled: markers,
          ),
        ),
      );

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
      final highlights =
          ValueNotifier<({int generation, List<WidgetHighlight> items})>((
            generation: 0,
            items: [],
          ));
      final selected = ValueNotifier<WidgetHighlight?>(null);
      final markers = ValueNotifier<bool>(true);
      addTearDown(markers.dispose);

      await tester.pumpWidget(
        wrap(
          HighlightOverlay(
            highlights: highlights,
            selectedHighlight: selected,
            markersEnabled: markers,
          ),
        ),
      );

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

  group('Outline', () {
    // The outline of an issue's widget: a widget's own highlight can be a
    // warning while its card is critical.
    Future<Finder> pumpOutline(
      WidgetTester tester,
      Rect rect, {
      IssueSeverity? outline,
    }) async {
      final highlights =
          ValueNotifier<({int generation, List<WidgetHighlight> items})>((
            generation: 1,
            items: const [],
          ));
      final selected = ValueNotifier<WidgetHighlight?>(
        WidgetHighlight(
          rect: rect,
          widgetName: 'Opacity',
          severity: IssueSeverity.warning,
          detectorName: 'RepaintBoundary',
        ),
      );
      final markers = ValueNotifier<bool>(false);
      addTearDown(highlights.dispose);
      addTearDown(selected.dispose);
      addTearDown(markers.dispose);
      await tester.pumpWidget(
        wrap(
          HighlightOverlay(
            highlights: highlights,
            selectedHighlight: selected,
            markersEnabled: markers,
            outlineSeverity: () => outline,
          ),
        ),
      );
      return find.descendant(
        of: find.byType(HighlightOverlay),
        matching: find.byType(CustomPaint),
      );
    }

    const theme = SleuthThemeData();

    testWidgets('takes the issue\'s severity colour', (tester) async {
      final paint = await pumpOutline(
        tester,
        const Rect.fromLTWH(20, 200, 100, 50),
        outline: IssueSeverity.critical,
      );
      expect(
        paint,
        paints
          ..path()
          ..rrect(color: theme.severityCritical, style: PaintingStyle.stroke),
      );
    });

    testWidgets('keeps the highlight\'s colour without an issue severity', (
      tester,
    ) async {
      final paint = await pumpOutline(
        tester,
        const Rect.fromLTWH(20, 200, 100, 50),
      );
      expect(
        paint,
        paints
          ..path()
          ..rrect(color: theme.severityWarning, style: PaintingStyle.stroke),
      );
    });

    // The bar says the widget is off screen; nothing on screen points at it.
    testWidgets('draws no dim, border or label for a widget off screen', (
      tester,
    ) async {
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final paint = await pumpOutline(
        tester,
        Rect.fromLTWH(20, size.height + 40, 100, 50),
        outline: IssueSeverity.critical,
      );
      expect(paint, paintsNothing);
    });
  });
}
