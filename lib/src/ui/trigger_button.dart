import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/frame_stats.dart';
import '../models/performance_issue.dart';
import 'overlay_ui_state.dart';
import 'sleuth_listenable_builder.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

/// Draggable trigger button with bloodhound logo, issue count badge, and live
/// FPS number.
///
/// - Green: no issues / FPS ≥ 83% of target
/// - Amber: warnings only / FPS 50–83% of target
/// - Red: critical issues / FPS < 50% of target
/// - ⚠️ badge: debug mode
///
/// The badge and colour count the cards the overlay would show (hidden
/// cards and filtered severities excluded). The button stays inside the
/// view padding and above the keyboard. A drag snaps it to the nearest
/// horizontal edge and stores the edge plus the vertical fraction in
/// [OverlayUiState.triggerAnchor], so the position survives opening the
/// dashboard and rotation.
class TriggerButton extends StatefulWidget {
  const TriggerButton({
    super.key,
    required this.issuesNotifier,
    required this.vmConnectedNotifier,
    required this.frameStatsNotifier,
    required this.isDebugMode,
    required this.onTap,
    this.uiState,
    this.fpsTarget = 60,
    this.initialAlignment = Alignment.topRight,
    this.initialOffset = const Offset(16, 64),
  });

  final ValueNotifier<List<PerformanceIssue>> issuesNotifier;
  final ValueNotifier<bool> vmConnectedNotifier;
  final ValueNotifier<FrameStatsBuffer> frameStatsNotifier;
  final bool isDebugMode;
  final VoidCallback onTap;

  /// Shared overlay state holding the anchor, hidden keys and severity
  /// filter. When null the button keeps its own.
  final OverlayUiState? uiState;
  final int fpsTarget;

  /// Placement before the first drag: corner or edge from
  /// [initialAlignment], inset by [initialOffset] from the view padding.
  final Alignment initialAlignment;
  final Offset initialOffset;

  @override
  State<TriggerButton> createState() => _TriggerButtonState();
}

/// Where the trigger may sit, in the coordinates of its layout box.
///
/// [loose] is the view-padding rect (above the keyboard) that bounds the
/// configured initial placement and an in-progress drag. [anchored] is
/// [loose] inset by a margin and without the keyboard: snapped positions
/// and the stored fraction live in it. Every range is non-empty
/// (`max(lo, hi)`), so a viewport smaller than the button never throws.
@visibleForTesting
class TriggerBounds {
  TriggerBounds({
    required Size area,
    required Size button,
    required EdgeInsets viewPadding,
    required double keyboardInset,
    required double margin,
  }) {
    final left = math.max(0.0, viewPadding.left);
    final top = math.max(0.0, viewPadding.top);
    final right = math.max(left, area.width - viewPadding.right - button.width);
    final bottomNoKeyboard = math.max(
      top,
      area.height - viewPadding.bottom - button.height,
    );
    final bottom = math.max(
      top,
      area.height - math.max(viewPadding.bottom, keyboardInset) - button.height,
    );
    loose = Rect.fromLTRB(left, top, right, bottom);
    final (aLeft, aRight) = _inset(left, right, margin);
    final (aTop, aBottom) = _inset(top, bottomNoKeyboard, margin);
    anchored = Rect.fromLTRB(aLeft, aTop, aRight, aBottom);
  }

  late final Rect loose;
  late final Rect anchored;

  /// Shrinks `[lo, hi]` by [m] on both sides; collapses to the middle
  /// when the range is narrower than `2m`.
  static (double, double) _inset(double lo, double hi, double m) {
    if (hi - lo >= 2 * m) return (lo + m, hi - m);
    final mid = (lo + hi) / 2;
    return (mid, mid);
  }

  /// Clamps [p] into [loose].
  Offset clampLoose(Offset p) => Offset(
    p.dx.clamp(loose.left, loose.right),
    p.dy.clamp(loose.top, loose.bottom),
  );

  /// Top-left for a stored anchor, kept above the keyboard.
  Offset resolveAnchor(({TriggerEdge edge, double fraction}) anchor) {
    final x = anchor.edge == TriggerEdge.left ? anchored.left : anchored.right;
    final y = anchored.top + anchor.fraction * anchored.height;
    return clampLoose(Offset(x, y));
  }

  /// Anchor for a drop at [p]: the nearer horizontal edge and the
  /// vertical fraction, both measured in [anchored] (the keyboard-free
  /// safe area) so the stored anchor does not depend on the keyboard.
  ({TriggerEdge edge, double fraction}) anchorFor(Offset p) {
    final edge = p.dx < anchored.center.dx
        ? TriggerEdge.left
        : TriggerEdge.right;
    final range = anchored.height;
    final fraction = range <= 0
        ? 0.0
        : ((p.dy - anchored.top) / range).clamp(0.0, 1.0);
    return (edge: edge, fraction: fraction);
  }

  /// Top-left for the configured [alignment] and [offset].
  Offset initial(Alignment alignment, Offset offset) {
    final x = switch (alignment.x) {
      < 0 => loose.left + offset.dx,
      > 0 => loose.right - offset.dx,
      _ => (loose.left + loose.right) / 2,
    };
    final y = switch (alignment.y) {
      < 0 => loose.top + offset.dy,
      > 0 => loose.bottom - offset.dy,
      _ => (loose.top + loose.bottom) / 2,
    };
    return clampLoose(Offset(x, y));
  }
}

class _TriggerButtonState extends State<TriggerButton> {
  OverlayUiState? _ownState;
  final GlobalKey _buttonKey = GlobalKey();

  /// Top-left while a drag is in progress; null otherwise.
  Offset? _dragPosition;

  OverlayUiState get _state =>
      widget.uiState ?? (_ownState ??= OverlayUiState());

  /// Issues plus overlay state, merged once per source pair so a rebuild
  /// does not move the subscription.
  Listenable? _merged;
  Object? _mergedIssues;
  Object? _mergedState;

  Listenable _listenable() {
    final issues = widget.issuesNotifier;
    final state = _state;
    if (_merged == null ||
        !identical(issues, _mergedIssues) ||
        !identical(state, _mergedState)) {
      _merged = Listenable.merge([issues, state]);
      _mergedIssues = issues;
      _mergedState = state;
    }
    return _merged!;
  }

  @override
  void dispose() {
    _ownState?.dispose();
    super.dispose();
  }

  TriggerBounds? _currentBounds() {
    final area = context.size;
    final button = _buttonKey.currentContext?.size;
    if (area == null || button == null) return null;
    return TriggerBounds(
      area: area,
      button: button,
      viewPadding: MediaQuery.maybeViewPaddingOf(context) ?? EdgeInsets.zero,
      keyboardInset: MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0,
      margin: SleuthTheme.of(context).spacingXl,
    );
  }

  Offset? _currentTopLeft() {
    final box = _buttonKey.currentContext?.findRenderObject();
    final self = context.findRenderObject();
    if (box is! RenderBox || self is! RenderBox || !box.hasSize) return null;
    return self.globalToLocal(box.localToGlobal(Offset.zero));
  }

  void _onPanStart(DragStartDetails details) {
    final start = _currentTopLeft();
    if (start == null) return;
    setState(() => _dragPosition = start);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final current = _dragPosition;
    final bounds = _currentBounds();
    if (current == null || bounds == null) return;
    setState(() => _dragPosition = bounds.clampLoose(current + details.delta));
  }

  void _onPanEnd() {
    final drop = _dragPosition;
    final bounds = _currentBounds();
    setState(() => _dragPosition = null);
    if (drop == null || bounds == null) return;
    _state.triggerAnchor = bounds.anchorFor(drop);
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final viewPadding =
        MediaQuery.maybeViewPaddingOf(context) ?? EdgeInsets.zero;
    final keyboardInset = MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0;
    return SleuthListenableBuilder(
      listenable: _listenable(),
      builder: (context) {
        final visible = _state.visibleIssues(widget.issuesNotifier.value);
        return _TriggerLayout(
          delegate: _TriggerLayoutDelegate(
            viewPadding: viewPadding,
            keyboardInset: keyboardInset,
            margin: theme.spacingXl,
            anchor: _state.triggerAnchor,
            dragPosition: _dragPosition,
            initialAlignment: widget.initialAlignment,
            initialOffset: widget.initialOffset,
          ),
          child: GestureDetector(
            key: _buttonKey,
            excludeFromSemantics: true,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: (_) => _onPanEnd(),
            onPanCancel: _onPanEnd,
            onTap: widget.onTap,
            child: Semantics(
              button: true,
              label:
                  'Open Sleuth, ${visible.length} '
                  '${visible.length == 1 ? 'issue' : 'issues'}',
              onTap: widget.onTap,
              container: true,
              excludeSemantics: true,
              // The count and FPS text grow up to 1.3x with the system
              // text size; the 56 px circle does not.
              child: SleuthTextScaleClamp(
                maxScaleFactor: kChromeMaxTextScale,
                child: _buildButton(theme, visible),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildButton(SleuthThemeData theme, List<PerformanceIssue> issues) {
    final hasCritical = issues.any((i) => i.severity == IssueSeverity.critical);
    final hasWarning = issues.any((i) => i.severity == IssueSeverity.warning);

    final Color bgColor;
    if (hasCritical) {
      bgColor = theme.severityCritical;
    } else if (hasWarning) {
      bgColor = theme.severityWarning;
    } else {
      bgColor = theme.severityOk;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Circle button
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: bgColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: bgColor.withValues(alpha: 0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.pets, color: theme.triggerIconColor, size: 28),
              if (issues.isNotEmpty && !widget.isDebugMode)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Container(
                    padding: EdgeInsets.all(theme.spacingXs),
                    decoration: BoxDecoration(
                      color: theme.triggerBadgeBg,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${issues.length}',
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: theme.fontSm,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              if (widget.isDebugMode)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding: EdgeInsets.all(theme.spacingXxs),
                    decoration: BoxDecoration(
                      color: theme.severityWarning,
                      shape: BoxShape.circle,
                    ),
                    child: Text('⚠️', style: TextStyle(fontSize: theme.fontSm)),
                  ),
                ),
            ],
          ),
        ),
        // FPS number below the circle
        SizedBox(height: theme.spacingXxs),
        ValueListenableBuilder<FrameStatsBuffer>(
          valueListenable: widget.frameStatsNotifier,
          builder: (_, buffer, _) {
            // Parity with `_StatusRow`: throughputFps primary,
            // warm-up placeholder until buffer has 3 frames.
            final isWarming = buffer.length < 3;
            final fps = buffer.throughputFps.clamp(
              0.0,
              widget.fpsTarget.toDouble(),
            );
            return Text(
              isWarming ? '—' : fps.toStringAsFixed(0),
              style: TextStyle(
                color: isWarming
                    ? theme.textTertiary
                    : theme.fpsColor(fps, target: widget.fpsTarget),
                fontSize: theme.fontBase,
                fontWeight: FontWeight.bold,
                shadows: [Shadow(color: theme.shadow, blurRadius: 4)],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// The trigger's positioning box. A named subclass so the profile-mode
/// rebuild filter can drop it without dropping app-owned
/// `CustomSingleChildLayout` widgets.
class _TriggerLayout extends CustomSingleChildLayout {
  const _TriggerLayout({required super.delegate, super.child});
}

/// Places the button from its measured size: drag position, else stored
/// anchor, else the configured initial placement.
class _TriggerLayoutDelegate extends SingleChildLayoutDelegate {
  _TriggerLayoutDelegate({
    required this.viewPadding,
    required this.keyboardInset,
    required this.margin,
    required this.anchor,
    required this.dragPosition,
    required this.initialAlignment,
    required this.initialOffset,
  });

  final EdgeInsets viewPadding;
  final double keyboardInset;
  final double margin;
  final ({TriggerEdge edge, double fraction})? anchor;
  final Offset? dragPosition;
  final Alignment initialAlignment;
  final Offset initialOffset;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = TriggerBounds(
      area: size,
      button: childSize,
      viewPadding: viewPadding,
      keyboardInset: keyboardInset,
      margin: margin,
    );
    final drag = dragPosition;
    if (drag != null) return bounds.clampLoose(drag);
    final a = anchor;
    if (a != null) return bounds.resolveAnchor(a);
    return bounds.initial(initialAlignment, initialOffset);
  }

  @override
  bool shouldRelayout(_TriggerLayoutDelegate old) =>
      viewPadding != old.viewPadding ||
      keyboardInset != old.keyboardInset ||
      margin != old.margin ||
      anchor != old.anchor ||
      dragPosition != old.dragPosition ||
      initialAlignment != old.initialAlignment ||
      initialOffset != old.initialOffset;
}
