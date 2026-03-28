import 'dart:ui';

import 'performance_issue.dart';

/// A detected widget's screen position and performance status.
///
/// Collected during tree scans and used by [HighlightOverlay] to draw
/// colored borders around problematic widgets.
class WidgetHighlight {
  const WidgetHighlight({
    required this.rect,
    required this.widgetName,
    required this.severity,
    required this.detectorName,
    this.detail,
  });

  /// The widget's bounding box in global (screen) coordinates.
  final Rect rect;

  /// The widget's runtime type name.
  final String widgetName;

  /// How bad the issue is — determines border color.
  final IssueSeverity severity;

  /// Which detector flagged this widget.
  final String detectorName;

  /// Short description of the issue.
  final String? detail;
}
