import 'package:flutter/material.dart';

/// An [InkWell] that tells [builder] when to draw a keyboard focus
/// outline.
///
/// The overlay sits above the app's `MaterialApp`, so an InkWell's own
/// focus fill comes from `ThemeData.fallback()` and barely shows on the
/// card. [builder] gets true while the well has focus and the keyboard
/// drives focus (`FocusHighlightMode.traditional`), the same rule
/// InkWell applies to its fill.
class SleuthFocusInkWell extends StatefulWidget {
  const SleuthFocusInkWell({
    super.key,
    required this.onTap,
    required this.borderRadius,
    required this.builder,
    this.focusNode,
    this.excludeFromSemantics = false,
  });

  /// Null disables the well; it then takes no focus.
  final VoidCallback? onTap;

  /// The ink splash's shape.
  final BorderRadius borderRadius;

  final FocusNode? focusNode;

  /// Leaves the tap out of semantics, for a well whose ancestor node
  /// carries it.
  final bool excludeFromSemantics;

  /// Builds the child; `showFocus` is true while the outline should show.
  final Widget Function(BuildContext context, bool showFocus) builder;

  @override
  State<SleuthFocusInkWell> createState() => _SleuthFocusInkWellState();
}

class _SleuthFocusInkWellState extends State<SleuthFocusInkWell> {
  bool _focused = false;
  bool _keyboard =
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    super.dispose();
  }

  void _onHighlightMode(FocusHighlightMode mode) {
    final keyboard = mode == FocusHighlightMode.traditional;
    if (keyboard != _keyboard) setState(() => _keyboard = keyboard);
  }

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: widget.onTap,
    focusNode: widget.focusNode,
    excludeFromSemantics: widget.excludeFromSemantics,
    borderRadius: widget.borderRadius,
    focusColor: Colors.transparent,
    onFocusChange: (focused) {
      if (focused != _focused) setState(() => _focused = focused);
    },
    child: widget.builder(context, _focused && _keyboard),
  );
}

/// The outline [SleuthFocusInkWell] callers draw: 2 px of [color] around
/// [child], or nothing while [show] is false.
class SleuthFocusOutline extends StatelessWidget {
  const SleuthFocusOutline({
    super.key,
    required this.show,
    required this.color,
    required this.borderRadius,
    required this.child,
  });

  final bool show;
  final Color color;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: show
        ? BoxDecoration(
            border: Border.all(color: color, width: 2),
            borderRadius: borderRadius,
          )
        : const BoxDecoration(),
    child: child,
  );
}
