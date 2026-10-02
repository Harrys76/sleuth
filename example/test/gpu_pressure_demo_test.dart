// The GPU Pressure demo's animated blur must run by default, repaint
// without rebuilding, and stop when paused.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:example/demos/gpu_pressure_demo.dart';

void main() {
  testWidgets('animated blur runs by default and the switch pauses it', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: GpuPressureDemo()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);

    final painter = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_BlurOrbsPainter',
    );
    expect(painter, findsOneWidget);
    final before = tester.widget<CustomPaint>(painter).painter;
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<CustomPaint>(painter).painter,
      same(before),
      reason: 'Frames repaint through the listenable; nothing rebuilds.',
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('Paused'), findsOneWidget);
  });
}
