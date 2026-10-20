import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import 'focus_ink_well.dart';
import 'severity_icon.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

/// The bar the card shrinks to while it outlines an issue's widget:
/// "Showing X", or "X is off screen" once the widget scrolls away or
/// detaches, with Back to issues and close.
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
  });

  final IssueSeverity severity;
  final String widgetName;

  /// The outlined widget is not on screen now.
  final bool offScreen;

  /// Returns to the issue list.
  final VoidCallback onBack;

  /// Closes the dashboard.
  final VoidCallback onClose;

  /// Focus for Back to issues, which takes focus when the bar opens.
  final FocusNode? backFocusNode;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final label = offScreen
        ? '$widgetName is off screen'
        : 'Showing $widgetName';
    final radius = BorderRadius.circular(theme.radiusXxl);
    final buttonRadius = BorderRadius.circular(theme.radiusLg);
    return SleuthTextScaleClamp(
      maxScaleFactor: kChromeMaxTextScale,
      child: Material(
        elevation: 8,
        color: theme.cardBackground,
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: 48 * chromeScaleOf(context)),
          child: Padding(
            padding: EdgeInsets.only(left: theme.spacingLg),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: SleuthSeverityIcon(severity: severity, size: 16),
                ),
                SizedBox(width: theme.spacingMd),
                Expanded(
                  child: Semantics(
                    container: true,
                    liveRegion: true,
                    label: label,
                    excludeSemantics: true,
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: theme.fontBase,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                // Wraps rather than overflows on a narrow screen at the
                // chrome text limit.
                Flexible(
                  child: Semantics(
                    container: true,
                    button: true,
                    label: 'Back to issues',
                    onTap: onBack,
                    excludeSemantics: true,
                    child: SleuthFocusInkWell(
                      onTap: onBack,
                      focusNode: backFocusNode,
                      excludeFromSemantics: true,
                      borderRadius: buttonRadius,
                      builder: (context, showFocus) => ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: SleuthFocusOutline(
                            show: showFocus,
                            color: theme.checkboxActive,
                            borderRadius: buttonRadius,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: theme.spacingSm,
                              ),
                              child: Text(
                                'Back to issues',
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
                  ),
                ),
                Semantics(
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
                        width: 48,
                        height: 48,
                        child: Icon(
                          Icons.close,
                          size: 18,
                          color: theme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
