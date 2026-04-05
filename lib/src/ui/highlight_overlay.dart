import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import 'sleuth_theme.dart';

/// Two-mode highlight overlay:
///
/// 1. **Markers mode** (show all): Small colored corner badges on every
///    flagged widget — no clutter, no overlap.
/// 2. **Selected mode** (tap issue): One widget gets a full prominent
///    border with label, triggered from the Issues tab.
class HighlightOverlay extends StatelessWidget {
  const HighlightOverlay({
    super.key,
    required this.highlights,
    required this.selectedHighlight,
  });

  final ValueNotifier<({int generation, List<WidgetHighlight> items})>
      highlights;
  final ValueNotifier<WidgetHighlight?> selectedHighlight;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return IgnorePointer(
      child: ValueListenableBuilder<
          ({int generation, List<WidgetHighlight> items})>(
        valueListenable: highlights,
        builder: (_, payload, __) => ValueListenableBuilder<WidgetHighlight?>(
          valueListenable: selectedHighlight,
          builder: (_, selected, __) {
            if (payload.items.isEmpty && selected == null) {
              return const SizedBox.shrink();
            }
            return CustomPaint(
              painter: _HighlightPainter(
                highlights: payload.items,
                generation: payload.generation,
                selected: selected,
                theme: theme,
              ),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required this.highlights,
    required this.generation,
    this.selected,
    required this.theme,
  });

  final List<WidgetHighlight> highlights;
  final int generation;
  final WidgetHighlight? selected;
  final SleuthThemeData theme;

  static const _markerSize = 8.0;

  Color _colorFor(IssueSeverity severity) => switch (severity) {
        IssueSeverity.critical => theme.severityCritical,
        IssueSeverity.warning => theme.severityWarning,
        IssueSeverity.ok => theme.severityOk,
      };

  @override
  void paint(Canvas canvas, Size size) {
    // --- Corner markers for all highlights ---
    for (final h in highlights) {
      if (h.rect.isEmpty) continue;
      _drawCornerMarker(canvas, h);
    }

    // --- Full border for selected highlight ---
    if (selected != null && !selected!.rect.isEmpty) {
      _drawSelectedBorder(canvas, size, selected!);
    }
  }

  /// Small colored triangle at the top-left corner of the widget.
  void _drawCornerMarker(Canvas canvas, WidgetHighlight h) {
    final color = _colorFor(h.severity);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(h.rect.left, h.rect.top)
      ..lineTo(h.rect.left + _markerSize * 2, h.rect.top)
      ..lineTo(h.rect.left, h.rect.top + _markerSize * 2)
      ..close();

    canvas.drawPath(path, paint);

    // Tiny dot for extra visibility
    canvas.drawCircle(
      Offset(h.rect.left + 3, h.rect.top + 3),
      2,
      Paint()..color = theme.highlightDot,
    );
  }

  /// Full border + label for the selected/focused widget.
  void _drawSelectedBorder(Canvas canvas, Size size, WidgetHighlight h) {
    final color = _colorFor(h.severity);

    // Dim the rest of the screen using path difference (v9.14).
    // Replaces saveLayer + BlendMode.clear — no offscreen GPU buffer.
    final dimPaint = Paint()..color = theme.dimOverlay;
    final screenRect = Offset.zero & size;
    final cutout = Path()
      ..addRRect(
          RRect.fromRectAndRadius(h.rect.inflate(2), const Radius.circular(6)));
    final screen = Path()..addRect(screenRect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, screen, cutout),
      dimPaint,
    );

    // Border
    final borderPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(h.rect, const Radius.circular(4)),
      borderPaint,
    );

    // Label
    final label = '${h.detectorName}: ${h.widgetName}'
        '${h.detail != null ? ' — ${h.detail}' : ''}';
    final textSpan = TextSpan(
      text: label,
      style: TextStyle(
        color: theme.highlightLabelText,
        fontSize: 10,
        fontWeight: FontWeight.bold,
        height: 1.2,
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: (h.rect.width + 100).clamp(120, 350));

    final labelLeft = h.rect.left.clamp(
      4.0,
      size.width - textPainter.width - 12,
    );
    final labelTop = (h.rect.top - 22).clamp(4.0, size.height - 18);

    final labelRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(labelLeft, labelTop, textPainter.width + 10, 18),
      const Radius.circular(4),
    );

    canvas.drawRRect(labelRect, Paint()..color = color);
    textPainter.paint(canvas, Offset(labelLeft + 5, labelTop + 2));
  }

  @override
  bool shouldRepaint(_HighlightPainter old) =>
      old.generation != generation ||
      !identical(old.selected, selected) ||
      !identical(old.theme, theme);
}
