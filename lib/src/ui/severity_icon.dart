import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import 'sleuth_theme.dart';

/// The severity mark on an issue card: a disc (critical, OK) or a
/// triangle (warning) filled with the severity colour, with a mark
/// inside.
///
/// The fill is the bright [SleuthThemeData.severityColor]. The mark
/// inside carries the meaning, so it keeps 3:1 against the fill: white
/// where white reaches it, else a near-black. The discs carry a white
/// ring, which sets their edge apart from a dark card. Where neither the
/// fill nor that ring reaches 3:1 on the card surfaces (amber and green
/// on a light card), the shape is outlined in [edgeOf].
class SleuthSeverityIcon extends StatelessWidget {
  const SleuthSeverityIcon({super.key, required this.severity, this.size = 16});

  final IssueSeverity severity;
  final double size;

  /// The mark's colour on [fill].
  static Color markOn(Color fill) =>
      SleuthThemeData.contrastRatio(const Color(0xFFFFFFFF), fill) >= 3
      ? const Color(0xFFFFFFFF)
      : const Color(0xFF1F1300);

  /// The outline of the shape when neither its fill nor, on a disc, the
  /// white ring reaches 3:1 on the card surfaces: the severity graphic
  /// shade, else the severity text colour. Null when the shape stands out
  /// as drawn.
  static Color? edgeOf(SleuthThemeData theme, IssueSeverity severity) {
    double weakest(Color c) => math.min(
      SleuthThemeData.contrastRatio(c, theme.cardDefault),
      SleuthThemeData.contrastRatio(c, theme.cardBackground),
    );
    if (weakest(theme.severityColor(severity)) >= 3) return null;
    if (severity != IssueSeverity.warning &&
        weakest(const Color(0xFFFFFFFF)) >= 3) {
      return null;
    }
    final graphic = theme.severityGraphicColor(severity);
    return weakest(graphic) >= 3 ? graphic : theme.severityTextColor(severity);
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final fill = theme.severityColor(severity);
    final edge = edgeOf(theme, severity);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _SeverityIconPainter(
          severity: severity,
          fill: fill,
          mark: markOn(fill),
          ring: edge ?? const Color(0xFFFFFFFF),
          edge: edge ?? fill,
        ),
      ),
    );
  }
}

class _SeverityIconPainter extends CustomPainter {
  _SeverityIconPainter({
    required this.severity,
    required this.fill,
    required this.mark,
    required this.ring,
    required this.edge,
  });

  final IssueSeverity severity;
  final Color fill;
  final Color mark;
  final Color ring;

  /// The triangle's outline.
  final Color edge;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 24-unit grid.
    canvas.scale(size.width / 24, size.height / 24);
    final body = Paint()
      ..color = fill
      ..isAntiAlias = true;
    final ringPaint = Paint()
      ..color = ring
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..isAntiAlias = true;
    Paint stroke(double width) => Paint()
      ..color = mark
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    switch (severity) {
      case IssueSeverity.critical:
        canvas
          ..drawCircle(const Offset(12, 12), 10, body)
          ..drawCircle(const Offset(12, 12), 10, ringPaint);
        final line = stroke(2.6);
        canvas
          ..drawLine(const Offset(12, 7), const Offset(12, 13.2), line)
          ..drawLine(const Offset(12, 16.6), const Offset(12, 17), line);
      case IssueSeverity.warning:
        final triangle = Path()
          ..moveTo(12, 2.8)
          ..lineTo(22, 20.2)
          ..lineTo(2, 20.2)
          ..close();
        canvas
          ..drawPath(triangle, body)
          ..drawPath(
            triangle,
            Paint()
              ..color = edge
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6
              ..strokeJoin = StrokeJoin.round
              ..isAntiAlias = true,
          );
        final line = stroke(2.4);
        canvas
          ..drawLine(const Offset(12, 9), const Offset(12, 14), line)
          ..drawLine(const Offset(12, 17), const Offset(12, 17.3), line);
      case IssueSeverity.ok:
        canvas
          ..drawCircle(const Offset(12, 12), 10, body)
          ..drawCircle(const Offset(12, 12), 10, ringPaint);
        canvas.drawPath(
          Path()
            ..moveTo(7.5, 12.3)
            ..lineTo(10.5, 15.3)
            ..lineTo(16.5, 9),
          stroke(2.4),
        );
    }
  }

  @override
  bool shouldRepaint(_SeverityIconPainter old) =>
      old.severity != severity ||
      old.fill != fill ||
      old.mark != mark ||
      old.ring != ring ||
      old.edge != edge;
}
