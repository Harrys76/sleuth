import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../models/issue_measurement.dart';
import '../models/performance_issue.dart';
import '../utils/measurement_text.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

/// The Measured row's bar: the value as a filled track, with a tick and a
/// label at the warning and critical lines.
///
/// One [CustomPaint]. The fill takes [color]; the track is the theme's
/// `border`. Tick labels grow with the text up to the chrome limit, and
/// the warning label is left out when it would overlap the critical one.
/// The gauge has no semantics of its own: the row's label reads the value
/// and both lines.
class SleuthMeasurementGauge extends StatelessWidget {
  const SleuthMeasurementGauge({
    super.key,
    required this.measurement,
    required this.color,
  });

  final IssueMeasurement measurement;
  final Color color;

  /// Top of the track, its height, and the tick height.
  static const double _trackTop = 4;
  static const double _trackHeight = 6;
  static const double _tickHeight = 14;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final scaler = clampTextScaler(
      MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
      max: kChromeMaxTextScale,
    );
    final labelStyle = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        color: theme.textTertiary,
        fontSize: theme.fontXxs,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final labelHeight = scaler.scale(theme.fontXxs) * 1.4;
    return ExcludeSemantics(
      child: SizedBox(
        height: _tickHeight + 2 + labelHeight,
        width: double.infinity,
        child: CustomPaint(
          painter: _GaugePainter(
            measurement: measurement,
            fill: color,
            track: theme.border,
            gap: theme.sectionBackground,
            tick: theme.textSecondary,
            labelStyle: labelStyle,
            scaler: scaler,
            radius: _trackHeight / 2,
          ),
        ),
      ),
    );
  }
}

/// The gauge's fill for [severity]: the severity graphic colour, or the
/// severity text colour where the graphic colour falls under 3:1 against
/// the Measured box ([SleuthThemeData.sectionBackground]). A gap in the
/// box colour separates the fill from the track, so the fill never meets
/// the track directly.
Color gaugeFillColor(SleuthThemeData theme, IssueSeverity severity) {
  final graphic = theme.severityGraphicColor(severity);
  return SleuthThemeData.contrastRatio(graphic, theme.sectionBackground) >= 3
      ? graphic
      : theme.severityTextColor(severity);
}

/// The value at the right end of the gauge: a quarter past the largest of
/// the value and the lines, or 100 for a percent that stays within it.
@visibleForTesting
double gaugeMax(IssueMeasurement m) {
  final top = [
    m.value,
    ?m.warningAt,
    ?m.criticalAt,
  ].where((v) => v.isFinite).fold(0.0, math.max);
  if (m.unit == MeasurementUnit.percent && top <= 100) return 100;
  return top <= 0 ? 1 : top * 1.25;
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.measurement,
    required this.fill,
    required this.track,
    required this.gap,
    required this.tick,
    required this.labelStyle,
    required this.scaler,
    required this.radius,
  });

  final IssueMeasurement measurement;
  final Color fill;
  final Color track;
  final Color gap;
  final Color tick;
  final TextStyle labelStyle;
  final TextScaler scaler;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final max = gaugeMax(measurement);
    double x(double v) => (v / max).clamp(0.0, 1.0) * size.width;
    const top = SleuthMeasurementGauge._trackTop;
    const height = SleuthMeasurementGauge._trackHeight;
    final r = Radius.circular(radius);
    canvas.drawRRect(
      RRect.fromLTRBR(0, top, size.width, top + height, r),
      Paint()..color = track,
    );
    final end = measurement.hasFiniteValue ? x(measurement.value) : 0.0;
    if (end > 0) {
      final fillEnd = math.max(end, height);
      canvas.drawRRect(
        RRect.fromLTRBR(0, top, fillEnd, top + height, r),
        Paint()..color = fill,
      );
      if (fillEnd < size.width) {
        canvas.drawRect(
          Rect.fromLTWH(
            fillEnd,
            top,
            math.min(2, size.width - fillEnd),
            height,
          ),
          Paint()..color = gap,
        );
      }
    }
    final tickPaint = Paint()..color = tick;
    final labels = <(double, TextPainter)>[];
    for (final (line, name) in [
      (measurement.warningAt, 'warn'),
      (measurement.criticalAt, 'critical'),
    ]) {
      if (line == null || !line.isFinite) continue;
      final at = x(line);
      final left = (at - 1)
          .clamp(0.0, math.max(0.0, size.width - 2))
          .toDouble();
      canvas.drawRect(
        Rect.fromLTWH(left, 0, 2, SleuthMeasurementGauge._tickHeight),
        tickPaint,
      );
      final painter = TextPainter(
        text: TextSpan(
          text: '$name ${formatMeasurementValue(line, measurement.unit)}',
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final dx = (at - painter.width / 2)
          .clamp(0.0, math.max(0.0, size.width - painter.width))
          .toDouble();
      labels.add((dx, painter));
    }
    // The critical label wins when the two would touch.
    if (labels.length == 2 &&
        labels[0].$1 + labels[0].$2.width + 4 > labels[1].$1) {
      labels.first.$2.dispose();
      labels.removeAt(0);
    }
    for (final (dx, painter) in labels) {
      painter
        ..paint(canvas, Offset(dx, SleuthMeasurementGauge._tickHeight + 2))
        ..dispose();
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.measurement != measurement ||
      old.fill != fill ||
      old.track != track ||
      old.gap != gap ||
      old.tick != tick ||
      old.labelStyle != labelStyle ||
      old.scaler != scaler;
}
