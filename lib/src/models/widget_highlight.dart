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
    this.occurrenceId,
    this.stableId,
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
  /// [rect] after a scroll without rescanning the tree. For a box, the
  /// overlay shows the part its ancestors' clips leave visible, and nothing
  /// while a clip (such as a list's edge) hides all of it. Null for
  /// highlights built without one; those are dropped by a rect-only refresh.
  final RenderObject? renderObject;

  /// Identity of the element this highlight was measured from: its
  /// `identityHashCode`, equal to the [PerformanceIssue.occurrenceId] of an
  /// issue tied to that one element. Null when the detector gives its
  /// highlights no element identity. Runtime only.
  final int? occurrenceId;

  /// [PerformanceIssue.stableId] of the issue this highlight belongs to,
  /// for an issue that lists several widgets (such as
  /// `always_repaint_painter`). The crosshair on that issue's card steps
  /// through the highlights carrying its id. Null for other highlights.
  final String? stableId;
}
