import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';
import 'sleuth_theme.dart';

/// Visual tone of an [OverlayToastModel].
enum OverlayToastTone {
  /// Confirmation (copied, exported, hidden).
  info,

  /// Something did not happen as asked.
  warning,
}

/// One toast message.
@immutable
class OverlayToastModel {
  const OverlayToastModel({
    required this.text,
    required this.duration,
    this.tone = OverlayToastTone.info,
    this.actionLabel,
    this.onAction,
    this.held = false,
  });

  final String text;
  final Duration duration;
  final OverlayToastTone tone;

  /// Label of the optional action button (e.g. "Undo").
  final String? actionLabel;

  /// Runs at most once, and only while this toast is the current one.
  final VoidCallback? onAction;

  /// Shown while [OverlayToastController.holdActions] was on: the toast
  /// stays past [duration] and carries a Dismiss button.
  final bool held;
}

/// Single-slot toast queue: a new toast replaces the current one and
/// restarts the dismiss timer.
class OverlayToastController extends ValueNotifier<OverlayToastModel?> {
  OverlayToastController() : super(null);

  /// Display time of informational toasts.
  static const Duration infoDuration = Duration(seconds: 2);

  /// Display time of toasts that carry an action (Undo).
  static const Duration actionDuration = Duration(seconds: 4);

  Timer? _timer;
  bool _disposed = false;

  /// The current toast once its display time ran out while held.
  OverlayToastModel? _expired;

  /// Multiplier for every display time. The card sets 3 while a screen
  /// reader or another assistive service is on (accessible navigation or
  /// semantics enabled), so toasts stay long enough to be announced and
  /// acted on.
  double durationScale = 1;

  /// While true, a toast with an action stays after its display time until
  /// the action runs, it is dismissed or another toast replaces it, as a
  /// `SnackBar` with an action does under accessible navigation. The card
  /// sets it together with [durationScale]. Turned off, a held toast whose
  /// time has run out leaves.
  bool get holdActions => _holdActions;
  bool _holdActions = false;
  set holdActions(bool value) {
    if (value == _holdActions) return;
    _holdActions = value;
    final expired = _expired;
    if (!value && expired != null && identical(this.value, expired)) {
      dismiss();
    }
  }

  /// Shows [text], replacing any current toast. [duration] defaults to
  /// [actionDuration] when an action is given, else [infoDuration]; it is
  /// multiplied by [durationScale].
  void show(
    String text, {
    OverlayToastTone tone = OverlayToastTone.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    if (_disposed) return;
    final hasAction = actionLabel != null && onAction != null;
    final model = OverlayToastModel(
      text: text,
      tone: tone,
      actionLabel: hasAction ? actionLabel : null,
      onAction: hasAction ? onAction : null,
      duration:
          (duration ?? (hasAction ? actionDuration : infoDuration)) *
          durationScale,
      held: hasAction && _holdActions,
    );
    _timer?.cancel();
    _expired = null;
    _timer = Timer(model.duration, () {
      _timer = null;
      if (_disposed || !identical(value, model)) return;
      if (model.onAction != null && _holdActions) {
        _expired = model;
      } else {
        value = null;
      }
    });
    value = model;
  }

  /// Runs [model]'s action if it is still the current toast, then
  /// dismisses it. A replaced or expired toast's action never runs.
  void runAction(OverlayToastModel model) {
    if (_disposed || value != model) return;
    final action = model.onAction;
    dismiss();
    action?.call();
  }

  /// Hides [model] if it is still the current toast.
  void dismissIfCurrent(OverlayToastModel model) {
    if (!_disposed && identical(value, model)) dismiss();
  }

  /// Hides the current toast.
  void dismiss() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _expired = null;
    value = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// Bottom-anchored toast for the overlay, rendered inside the card's
/// [Stack] (the overlay has no [ScaffoldMessenger] above it). Sits above
/// the keyboard and the bottom safe-area inset, fades in and out over
/// 200 ms (at once under reduced motion, and a running fade finishes when
/// reduced motion turns on), and announces itself to screen readers as a
/// live region. A held toast ([OverlayToastModel.held]) adds a Dismiss
/// button and a dismiss semantics action.
class OverlayToast extends StatelessWidget {
  const OverlayToast({super.key, required this.controller});

  final OverlayToastController controller;

  static const Duration _fade = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final bottomInset = math.max(
      MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0.0,
      MediaQuery.maybeViewPaddingOf(context)?.bottom ?? 0.0,
    );
    return Positioned(
      left: theme.spacingXl,
      right: theme.spacingXl,
      bottom: theme.spacingXl + bottomInset,
      child: ValueListenableBuilder<OverlayToastModel?>(
        valueListenable: controller,
        builder: (context, model, _) => _ToastFade(
          model: model,
          onAction: controller.runAction,
          onDismiss: controller.dismissIfCurrent,
        ),
      ),
    );
  }
}

/// Fades a toast in when it appears and out when it is dismissed; a
/// replacement fades in from transparent. A fading-out toast ignores taps.
class _ToastFade extends StatefulWidget {
  const _ToastFade({
    required this.model,
    required this.onAction,
    required this.onDismiss,
  });

  final OverlayToastModel? model;
  final ValueChanged<OverlayToastModel> onAction;
  final ValueChanged<OverlayToastModel> onDismiss;

  @override
  State<_ToastFade> createState() => _ToastFadeState();
}

class _ToastFadeState extends State<_ToastFade>
    with SingleTickerProviderStateMixin {
  // Created in initState: a lazily created controller would be built
  // inside dispose() for a toast that never showed, and creating a ticker
  // there looks up TickerMode on a deactivated element.
  late final AnimationController _opacity;

  /// The toast on screen; outlives [_ToastFade.model] while fading out.
  OverlayToastModel? _shown;

  @override
  void initState() {
    super.initState();
    _opacity = AnimationController(vsync: this, duration: OverlayToast._fade)
      ..addStatusListener(_onStatus);
    _shown = widget.model;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // First call only: a toast present at insertion fades in. Later calls
    // (reduced motion turned on among them) finish a running fade.
    if (_shown != null && _opacity.status == AnimationStatus.dismissed) {
      _opacity
        ..duration = motionDuration(context, OverlayToast._fade)
        ..forward();
      settleOnReducedMotion(context, _opacity);
    } else {
      settleIfMotionReduced(context, _opacity);
    }
  }

  @override
  void didUpdateWidget(_ToastFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.model;
    if (identical(next, oldWidget.model)) return;
    _opacity.duration = motionDuration(context, OverlayToast._fade);
    if (next != null) {
      _shown = next;
      _opacity.forward(from: 0);
    } else {
      _opacity.reverse();
    }
    settleOnReducedMotion(context, _opacity);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        widget.model == null &&
        _shown != null) {
      setState(() => _shown = null);
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    return IgnorePointer(
      ignoring: widget.model == null,
      child: FadeTransition(
        opacity: _opacity,
        child: _ToastBody(
          key: ObjectKey(shown),
          model: shown,
          onAction: () => widget.onAction(shown),
          onDismiss: () => widget.onDismiss(shown),
        ),
      ),
    );
  }
}

class _ToastBody extends StatelessWidget {
  const _ToastBody({
    super.key,
    required this.model,
    required this.onAction,
    required this.onDismiss,
  });

  final OverlayToastModel model;
  final VoidCallback onAction;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final warning = model.tone == OverlayToastTone.warning;
    final background = warning ? theme.bannerWarningBg : theme.bannerSuccessBg;
    final foreground = warning
        ? theme.bannerWarningText
        : theme.bannerSuccessText;
    return Center(
      child: Semantics(
        liveRegion: true,
        container: true,
        // A held toast stays until used or dismissed; screen readers get a
        // dismiss action next to the Dismiss button.
        onDismiss: model.held ? onDismiss : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(theme.radiusLg),
            boxShadow: [BoxShadow(color: theme.shadow, blurRadius: 8)],
          ),
          child: Padding(
            padding: EdgeInsets.only(
              left: theme.spacingLg,
              right: model.actionLabel == null
                  ? theme.spacingLg
                  : theme.spacingXs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: theme.spacingMd),
                    child: Text(
                      model.text,
                      style: TextStyle(
                        color: foreground,
                        fontSize: theme.fontSm,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (model.actionLabel != null)
                  Semantics(
                    container: true,
                    button: true,
                    child: GestureDetector(
                      onTap: onAction,
                      behavior: HitTestBehavior.opaque,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: theme.spacingMd,
                          ),
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              model.actionLabel!,
                              style: TextStyle(
                                color: foreground,
                                fontSize: theme.fontSm,
                                fontWeight: FontWeight.bold,
                                decoration: TextDecoration.underline,
                                decorationColor: foreground,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (model.held)
                  Semantics(
                    container: true,
                    button: true,
                    label: 'Dismiss',
                    child: GestureDetector(
                      onTap: onDismiss,
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child: Icon(Icons.close, size: 16, color: foreground),
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
