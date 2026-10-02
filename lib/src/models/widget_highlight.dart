import 'package:flutter/rendering.dart';

import 'performance_issue.dart';

/// A detected widget's screen position and performance status.
///
/// Collected during tree scans and used by `HighlightOverlay` to draw
/// colored borders around problematic widgets.
class WidgetHighlight {
  const WidgetHighlight({
    required this.rect,
    required this.widgetName,
    required this.severity,
    required this.detectorName,
    this.detail,
    this.renderObject,
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

  /// The render object [rect] was measured from. Lets the overlay re-measure
  /// [rect] after a scroll without rescanning the tree. Null for highlights
  /// built without one; those are dropped by a rect-only refresh.
  final RenderObject? renderObject;
}
