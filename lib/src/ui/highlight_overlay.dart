import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import 'highlight_bar.dart';
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
    this.outlineSeverity,
    this.highlightStep,
    this.barAtTop,
  });

  final ValueNotifier<({int generation, List<WidgetHighlight> items})>
  highlights;
  final ValueNotifier<WidgetHighlight?> selectedHighlight;

  /// The corner markers draw while this is true. The list is emptied only
  /// at the next scan, so turning them off hides them here at once.
  final ValueListenable<bool> markersEnabled;

  /// The severity of the issue the outline belongs to, read when the
  /// selection changes. The outline takes its colour, so a critical card's
  /// widget is not outlined in a widget's own warning colour. Null keeps
  /// the highlight's severity.
  final IssueSeverity? Function()? outlineSeverity;

  /// The outline's step through an issue's widgets; with two or more the
  /// highlight bar has a second row the label stays below.
  final ValueListenable<({int index, int count})?>? highlightStep;

  /// The bar's edge while it is up (true at the top), set by the card.
  /// Without it the label assumes the bar's default edge for the outline.
  final ValueListenable<bool?>? barAtTop;

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
    // The label stays below a notch or status bar, and below the
    // highlight bar when the bar sits at the top.
    final topInset = MediaQuery.maybeViewPaddingOf(context)?.top ?? 0;
    final keyboardHeight = MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0;
    // Painted labels are a visual aid; screen readers reach the issue
    // through its card.
    return ExcludeSemantics(
      child: IgnorePointer(
        child: ValueListenableBuilder<({int index, int count})?>(
          valueListenable: highlightStep ?? _noStep,
          builder: (_, step, _) => ValueListenableBuilder<bool?>(
            valueListenable: barAtTop ?? _noEdge,
            builder: (_, atTop, _) {
              // The bar has its second row when it shows Next.
              final barSteps = (step?.count ?? 0) > 1;
              return ValueListenableBuilder<
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
                              outlineSeverity: selected == null
                                  ? null
                                  : outlineSeverity?.call(),
                              theme: theme,
                              textScaler: textScaler,
                              topInset: topInset,
                              keyboardHeight: keyboardHeight,
                              barSteps: barSteps,
                              barAtTop: atTop,
                            ),
                            size: Size.infinite,
                          );
                        },
                      ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Stands in for a missing [HighlightOverlay.highlightStep].
final ValueNotifier<({int index, int count})?> _noStep = ValueNotifier(null);

/// Stands in for a missing [HighlightOverlay.barAtTop].
final ValueNotifier<bool?> _noEdge = ValueNotifier(null);

class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required this.highlights,
    required this.generation,
    this.selected,
    this.outlineSeverity,
    required this.theme,
    required this.textScaler,
    required this.topInset,
    required this.keyboardHeight,
    this.barSteps = false,
    this.barAtTop,
  });

  final List<WidgetHighlight> highlights;
  final int generation;
  final WidgetHighlight? selected;
  final IssueSeverity? outlineSeverity;
  final SleuthThemeData theme;
  final TextScaler textScaler;
  final double topInset;
  final double keyboardHeight;

  /// The highlight bar has its second row (see [highlightBarHeight]).
  final bool barSteps;

  /// The bar's edge as the card placed it, null to use the default rule.
  final bool? barAtTop;

  static const _markerSize = 8.0;

  /// Widest the outline label's text runs before it wraps, whatever the
  /// width of the widget it names.
  static const _labelMaxWidth = 350.0;

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
    // Off screen, the bar says so; a dimmed screen and a label pinned to
    // its edge would point at a widget the screen cannot show.
    final shown = Rect.fromLTRB(
      0,
      0,
      size.width,
      math.max(0.0, size.height - keyboardHeight),
    );
    if (!h.rect.overlaps(shown)) return;
    final color = _colorFor(outlineSeverity ?? h.severity);

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
    final margin = theme.spacingXs;
    final padX = theme.spacingMd;
    final padY = theme.spacingXxs;
    final label =
        '${h.detectorName}: ${h.widgetName}'
        '${h.detail != null ? ', ${h.detail}' : ''}';
    final textPainter =
        TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: SleuthThemeData.onColor(color),
              fontSize: theme.fontMd,
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
            math.min(_labelMaxWidth, size.width - 2 * margin - 2 * padX),
          ),
        );

    final labelWidth = textPainter.width + 2 * padX;
    final labelHeight = textPainter.height + 2 * padY;
    final labelLeft = clampDouble(
      h.rect.left,
      margin,
      math.max(margin, size.width - labelWidth - margin),
    );
    // Below the status bar, and below the highlight bar when it sits at
    // the top (the card places it by the same rule).
    final visible = Rect.fromLTRB(
      0,
      0,
      size.width,
      math.max(0.0, size.height - keyboardHeight),
    );
    final chromeScale = clampDouble(
      textScaler.scale(14) / 14,
      1,
      kChromeMaxTextScale,
    );
    final minTop =
        topInset +
        margin +
        ((barAtTop ?? highlightBarAtTop(h.rect, visible))
            ? theme.spacingMd + highlightBarHeight(chromeScale, steps: barSteps)
            : 0);
    final labelTop = clampDouble(
      h.rect.top - labelHeight - margin,
      minTop,
      math.max(minTop, size.height - labelHeight - margin),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(labelLeft, labelTop, labelWidth, labelHeight),
        Radius.circular(theme.radiusMd),
      ),
      Paint()..color = color,
    );
    textPainter
      ..paint(canvas, Offset(labelLeft + padX, labelTop + padY))
      ..dispose();
  }

  @override
  bool shouldRepaint(_HighlightPainter old) =>
      old.generation != generation ||
      !identical(old.selected, selected) ||
      old.outlineSeverity != outlineSeverity ||
      !identical(old.theme, theme) ||
      old.textScaler != textScaler ||
      old.topInset != topInset ||
      old.keyboardHeight != keyboardHeight ||
      old.barSteps != barSteps ||
      old.barAtTop != barAtTop ||
      !identical(old.highlights, highlights);
}
