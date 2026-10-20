import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import 'focus_ink_well.dart';
import 'severity_icon.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

/// Whether the highlight bar sits at the top edge: when the centre of the
/// outlined [rect] is in the lower half of [visible], the part of the
/// screen the keyboard leaves. The outline label reads the same rule to
/// stay clear of the bar.
bool highlightBarAtTop(Rect rect, Rect visible) =>
    rect.center.dy > visible.center.dy;

/// Height of the highlight bar at chrome text scale [chromeScale]: one
/// 48 px row, or two when it [steps] through an issue's widgets.
double highlightBarHeight(double chromeScale, {bool steps = false}) =>
    (steps ? 96 : 48) * chromeScale;

/// The bar the card shrinks to while it outlines an issue's widget:
/// "Showing X", or "X is off screen" once the widget scrolls away or
/// detaches, with Back to issues and close.
///
/// For an issue that lists widgets ([step] set), Back to issues sits on a
/// second row, and with two or more widgets the first row shows the
/// outlined widget's position ("1 of 3") and a Next button. The rows stay
/// when the count changes, so Back to issues keeps its focus.
///
/// The label is a live region, so a screen reader hears the switch to
/// off screen.
class SleuthHighlightBar extends StatelessWidget {
  const SleuthHighlightBar({
    super.key,
    required this.severity,
    required this.widgetName,
    required this.offScreen,
    required this.onBack,
    required this.onClose,
    this.backFocusNode,
    this.step,
    this.onNext,
    this.nextFocusNode,
    this.showNext = false,
  });

  final IssueSeverity severity;
  final String widgetName;

  /// Position of the outlined widget among the issue's widgets; Next shows
  /// when there are two or more.
  final ({int index, int count})? step;

  /// Outlines the issue's next widget.
  final VoidCallback? onNext;

  /// Whether Next shows: two or more widgets, or the outlined one is gone
  /// and another remains.
  final bool showNext;

  /// Focus for Next, which takes focus when a bar with Next opens.
  final FocusNode? nextFocusNode;

  /// The outlined widget is not on screen now.
  final bool offScreen;

  /// Returns to the issue list.
  final VoidCallback onBack;

  /// Closes the dashboard.
  final VoidCallback onClose;

  /// Focus for Back to issues, which takes focus when a bar without Next
  /// opens.
  final FocusNode? backFocusNode;

  /// Side of the close button and the least size of the text buttons.
  static const double _hit = 48;

  /// Whether the bar has its second row, for an issue that lists widgets.
  bool get _twoRows => step != null;

  /// Whether the bar shows the position: two or more widgets.
  bool get _position => _twoRows && step!.count > 1;

  /// Whether the bar shows Next.
  bool get _next => _twoRows && showNext && onNext != null;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final state = offScreen
        ? '$widgetName is off screen'
        : 'Showing $widgetName';
    final position = _position ? '${step!.index + 1} of ${step!.count}' : null;
    final spoken = position == null ? state : '$state, $position';
    final radius = BorderRadius.circular(theme.radiusXxl);
    final buttonRadius = BorderRadius.circular(theme.radiusLg);
    final textStyle = TextStyle(
      color: theme.textPrimary,
      fontSize: theme.fontBase,
    );
    // The widget name takes the ellipsis; the position never breaks.
    final labelText = Expanded(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: spoken,
        excludeSemantics: true,
        child: Row(
          children: [
            Flexible(
              child: Text(
                position == null ? state : '$state ·',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ),
            if (position != null)
              Text(' $position', softWrap: false, style: textStyle),
          ],
        ),
      ),
    );
    final icon = ExcludeSemantics(
      child: SleuthSeverityIcon(severity: severity, size: 16),
    );
    final close = Semantics(
      container: true,
      button: true,
      label: 'Close Sleuth',
      onTap: onClose,
      excludeSemantics: true,
      child: SleuthFocusInkWell(
        onTap: onClose,
        excludeFromSemantics: true,
        borderRadius: buttonRadius,
        builder: (context, showFocus) => SleuthFocusOutline(
          show: showFocus,
          color: theme.checkboxActive,
          borderRadius: buttonRadius,
          child: SizedBox(
            width: _hit,
            height: _hit,
            child: Icon(Icons.close, size: 16, color: theme.textTertiary),
          ),
        ),
      ),
    );
    final chromeScale = chromeScaleOf(context);
    final rowHeight = BoxConstraints(
      minHeight: highlightBarHeight(chromeScale),
    );
    return SleuthTextScaleClamp(
      maxScaleFactor: kChromeMaxTextScale,
      child: Material(
        elevation: 8,
        color: theme.cardBackground,
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: highlightBarHeight(chromeScale, steps: _twoRows),
          ),
          child: Padding(
            padding: EdgeInsets.only(left: theme.spacingLg),
            // Back to issues keeps its width up to half the row and wraps
            // past it; the label takes the rest, so close stays at the end.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final back = ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth / 2,
                  ),
                  child: _textButton(
                    theme,
                    buttonRadius,
                    text: 'Back to issues',
                    onTap: onBack,
                    focusNode: backFocusNode,
                  ),
                );
                if (!_twoRows) {
                  return Row(
                    children: [
                      icon,
                      SizedBox(width: theme.spacingMd),
                      labelText,
                      back,
                      close,
                    ],
                  );
                }
                // Next and Back to issues end on the same edge, left of
                // close.
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: rowHeight,
                      child: Row(
                        children: [
                          icon,
                          SizedBox(width: theme.spacingMd),
                          labelText,
                          if (_next)
                            _textButton(
                              theme,
                              buttonRadius,
                              text: 'Next',
                              semanticsLabel: 'Next widget',
                              onTap: onNext!,
                              focusNode: nextFocusNode,
                            ),
                          close,
                        ],
                      ),
                    ),
                    ConstrainedBox(
                      constraints: rowHeight,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          back,
                          const SizedBox(width: _hit),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _textButton(
    SleuthThemeData theme,
    BorderRadius radius, {
    required String text,
    String? semanticsLabel,
    required VoidCallback onTap,
    FocusNode? focusNode,
  }) => Semantics(
    container: true,
    button: true,
    label: semanticsLabel ?? text,
    onTap: onTap,
    excludeSemantics: true,
    child: SleuthFocusInkWell(
      onTap: onTap,
      focusNode: focusNode,
      excludeFromSemantics: true,
      borderRadius: radius,
      builder: (context, showFocus) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: _hit, minHeight: _hit),
        // End-aligned, so stacked buttons end on one edge.
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          widthFactor: 1,
          child: SleuthFocusOutline(
            show: showFocus,
            color: theme.checkboxActive,
            borderRadius: radius,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: theme.spacingSm),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.checkboxActive,
                  fontSize: theme.fontBase,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
