import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';

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

  final ValueNotifier<List<WidgetHighlight>> highlights;
  final ValueNotifier<WidgetHighlight?> selectedHighlight;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<List<WidgetHighlight>>(
        valueListenable: highlights,
        builder: (_, items, __) => ValueListenableBuilder<WidgetHighlight?>(
          valueListenable: selectedHighlight,
          builder: (_, selected, __) {
            if (items.isEmpty && selected == null) {
              return const SizedBox.shrink();
            }
            return CustomPaint(
              painter: _HighlightPainter(highlights: items, selected: selected),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter({required this.highlights, this.selected});

  final List<WidgetHighlight> highlights;
  final WidgetHighlight? selected;

  static const _criticalColor = Color(0xFFEF4444);
  static const _warningColor = Color(0xFFF59E0B);
  static const _okColor = Color(0xFF10B981);
  static const _markerSize = 8.0;

  Color _colorFor(IssueSeverity severity) => switch (severity) {
        IssueSeverity.critical => _criticalColor,
        IssueSeverity.warning => _warningColor,
        IssueSeverity.ok => _okColor,
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
      Paint()..color = Colors.white,
    );
  }

  /// Full border + label for the selected/focused widget.
  void _drawSelectedBorder(Canvas canvas, Size size, WidgetHighlight h) {
    final color = _colorFor(h.severity);

    // Dim the rest of the screen
    final dimPaint = Paint()..color = const Color(0x44000000);
    final screenRect = Offset.zero & size;
    canvas.saveLayer(screenRect, Paint());
    canvas.drawRect(screenRect, dimPaint);
    // Cut out the selected widget area
    final clearPaint = Paint()..blendMode = BlendMode.clear;
    canvas.drawRRect(
      RRect.fromRectAndRadius(h.rect.inflate(2), const Radius.circular(6)),
      clearPaint,
    );
    canvas.restore();

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
      style: const TextStyle(
        color: Colors.white,
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
      !identical(old.highlights, highlights) ||
      !identical(old.selected, selected);
}
