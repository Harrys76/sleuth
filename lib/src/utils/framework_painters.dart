import 'package:flutter/widgets.dart';

/// Whether [paint] is drawn by a framework toggle or scrollbar painter
/// rather than user code.
///
/// Material/Cupertino Checkbox, Switch, and Radio painters extend
/// [ToggleablePainter] (whose `shouldRepaint` always returns true by
/// design); Material `Scrollbar` and `RawScrollbar` paint through
/// [ScrollbarPainter]. Neither is a user `CustomPainter` to fix.
bool isFrameworkPainterPaint(CustomPaint paint) =>
    _isFrameworkPainter(paint.painter) ||
    _isFrameworkPainter(paint.foregroundPainter);

bool _isFrameworkPainter(CustomPainter? painter) =>
    painter is ToggleablePainter || painter is ScrollbarPainter;
