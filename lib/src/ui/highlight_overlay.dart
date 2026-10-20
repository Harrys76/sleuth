import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

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
    required this.markersEnabled,
  });

  final ValueNotifier<({int generation, List<WidgetHighlight> items})>
  highlights;
  final ValueNotifier<WidgetHighlight?> selectedHighlight;

  /// The corner markers draw while this is true. The list is emptied only
  /// at the next scan, so turning them off hides them here at once.
  final ValueListenable<bool> markersEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    // Drawn outside the card, so the label clamps the app's text scale to
    // the chrome limit itself.
    final textScaler = clampTextScaler(
      MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
      min: kOverlayMinTextScale,
      max: kChromeMaxTextScale,
    );
    // The label stays below a notch or status bar.
    final topInset = MediaQuery.maybeViewPaddingOf(context)?.top ?? 0;
    // Painted labels are a visual aid; screen readers reach the issue
    // through its card.
    return ExcludeSemantics(
      child: IgnorePointer(
        child:
            ValueListenableBuilder<
              ({int generation, List<WidgetHighlight> items})
            >(
              valueListenable: highlights,
              builder: (_, payload, _) => ValueListenableBuilder<bool>(
                valueListenable: markersEnabled,
                builder: (_, markers, _) =>
                    ValueListenableBuilder<WidgetHighlight?>(
                      valueListenable: selectedHighlight,
                      builder: (_, selected, _) {
                        final items = markers
                            ? payload.items
                            : const <WidgetHighlight>[];
                        if (items.isEmpty && selected == null) {
                          return const SizedBox.shrink();
                        }
                        return CustomPaint(
                          painter: _HighlightPainter(
                            highlights: items,
                            generation: payload.generation,
                            selected: selected,
                            theme: theme,
                            textScaler: textScaler,
                            topInset: topInset,
                          ),
                          size: Size.infinite,
                        );
                      },
                    ),
              ),
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
    required this.textScaler,
    required this.topInset,
  });

  final List<WidgetHighlight> highlights;
  final int generation;
  final WidgetHighlight? selected;
  final SleuthThemeData theme;
  final TextScaler textScaler;
  final double topInset;

  static const _markerSize = 8.0;
  static const _labelMargin = 4.0;
  static const _labelPadX = 5.0;
  static const _labelPadY = 2.0;

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
        RRect.fromRectAndRadius(h.rect.inflate(2), const Radius.circular(6)),
      );
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

    // Label: sized to its text, up to two lines, in the severity colour
    // with the text colour that reads on it.
    final label =
        '${h.detectorName}: ${h.widgetName}'
        '${h.detail != null ? ', ${h.detail}' : ''}';
    final textPainter =
        TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: SleuthThemeData.onColor(color),
              fontSize: theme.fontSm,
              fontWeight: FontWeight.bold,
              height: 1.2,
            ),
          ),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
          maxLines: 2,
          ellipsis: '\u2026',
        )..layout(
          maxWidth: math.max(
            0.0,
            math.min(
              clampDouble(h.rect.width + 100, 120, 350),
              size.width - 2 * _labelMargin - 2 * _labelPadX,
            ),
          ),
        );

    final labelWidth = textPainter.width + 2 * _labelPadX;
    final labelHeight = textPainter.height + 2 * _labelPadY;
    final labelLeft = clampDouble(
      h.rect.left,
      _labelMargin,
      math.max(_labelMargin, size.width - labelWidth - _labelMargin),
    );
    final minTop = topInset + _labelMargin;
    final labelTop = clampDouble(
      h.rect.top - labelHeight - 4,
      minTop,
      math.max(minTop, size.height - labelHeight - _labelMargin),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(labelLeft, labelTop, labelWidth, labelHeight),
        const Radius.circular(4),
      ),
      Paint()..color = color,
    );
    textPainter
      ..paint(canvas, Offset(labelLeft + _labelPadX, labelTop + _labelPadY))
      ..dispose();
  }

  @override
  bool shouldRepaint(_HighlightPainter old) =>
      old.generation != generation ||
      !identical(old.selected, selected) ||
      !identical(old.theme, theme) ||
      old.textScaler != textScaler ||
      old.topInset != topInset ||
      !identical(old.highlights, highlights);
}
