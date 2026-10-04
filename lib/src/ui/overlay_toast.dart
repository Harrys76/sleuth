import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

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
  });

  final String text;
  final Duration duration;
  final OverlayToastTone tone;

  /// Label of the optional action button (e.g. "Undo").
  final String? actionLabel;

  /// Runs at most once, and only while this toast is the current one.
  final VoidCallback? onAction;
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

  /// Shows [text], replacing any current toast. [duration] defaults to
  /// [actionDuration] when an action is given, else [infoDuration].
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
      duration: duration ?? (hasAction ? actionDuration : infoDuration),
    );
    _timer?.cancel();
    _timer = Timer(model.duration, () {
      _timer = null;
      if (!_disposed && value == model) value = null;
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

  /// Hides the current toast.
  void dismiss() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
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
/// 200 ms, and announces itself to screen readers as a live region.
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
        builder: (context, model, _) => AnimatedSwitcher(
          duration: _fade,
          child: model == null
              ? const SizedBox.shrink()
              : _ToastBody(
                  key: ObjectKey(model),
                  model: model,
                  onAction: () => controller.runAction(model),
                ),
        ),
      ),
    );
  }
}

class _ToastBody extends StatelessWidget {
  const _ToastBody({super.key, required this.model, required this.onAction});

  final OverlayToastModel model;
  final VoidCallback onAction;

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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
