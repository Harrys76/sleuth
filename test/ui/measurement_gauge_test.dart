import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/ui/measurement_gauge.dart';

const _width = 300.0;
const _fill = Color(0xFFE5484D);
const _radius = Radius.circular(3);

/// A sustained jank count against its line of 3 frames.
IssueMeasurement _frames(double value) =>
    IssueMeasurement(value: value, unit: MeasurementUnit.frames, criticalAt: 3);

Future<void> _pump(WidgetTester tester, double value) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: _width,
          child: SleuthMeasurementGauge(
            measurement: _frames(value),
            color: _fill,
          ),
        ),
      ),
    ),
  );
}

Finder get _paint => find.descendant(
  of: find.byType(SleuthMeasurementGauge),
  matching: find.byType(CustomPaint),
);

/// The critical tick, placed as the painter places it.
Rect get _tick =>
    Rect.fromLTWH(3 / gaugeMax(_frames(3)) * _width - 1, 0, 2, 14);

void main() {
  // The count runs far past the line and changes on every scan.
  testWidgets('a value past the scale fills the track, breaks near the end '
      'and leaves the tick in place', (tester) async {
    for (final value in [52.0, 77.0]) {
      await _pump(tester, value);
      expect(
        _paint,
        paints
          ..rrect()
          ..rrect(
            rrect: RRect.fromLTRBR(0, 4, _width, 10, _radius),
            color: _fill,
          )
          ..line()
          ..line()
          ..rect(rect: _tick),
      );
    }
  });

  testWidgets('the fill follows a value within the scale', (tester) async {
    await _pump(tester, 1.5);
    expect(
      _paint,
      paints
        ..rrect()
        ..rrect(
          rrect: RRect.fromLTRBR(0, 4, _width * 0.4, 10, _radius),
          color: _fill,
        )
        ..rect()
        ..rect(rect: _tick),
    );
    expect(_paint, isNot(paints..line()));
  });

  testWidgets('a value at the end of the scale has no break', (tester) async {
    await _pump(tester, gaugeMax(_frames(3)));
    expect(_paint, isNot(paints..line()));
  });
}
