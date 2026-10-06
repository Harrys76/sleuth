import 'package:flutter/widgets.dart';

/// Whether the overlay should skip motion at [context].
///
/// True when either platform setting asks for reduced motion:
/// [MediaQueryData.disableAnimations] (the Android animator-duration
/// scale) or [AccessibilityFeatures.reduceMotion] (iOS Reduce Motion,
/// which Flutter does not fold into [MediaQueryData]). Works without a
/// [MediaQuery] or [View] above [context]; the platform dispatcher of the
/// binding stands in for a missing view.
///
/// Read when an animation starts. A run already going when the setting
/// turns on finishes at once if it was started through [startEntrance],
/// [settleOnReducedMotion], [animateScrollTo] or [ensureVisibleWithMotion].
bool reducedMotionOf(BuildContext context) {
  if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return true;
  final dispatcher =
      View.maybeOf(context)?.platformDispatcher ??
      WidgetsBinding.instance.platformDispatcher;
  return dispatcher.accessibilityFeatures.reduceMotion;
}

/// [normal], or [Duration.zero] when [reducedMotionOf] is true.
Duration motionDuration(BuildContext context, Duration normal) =>
    reducedMotionOf(context) ? Duration.zero : normal;

/// Starts a page entrance once: runs [controller] forward, or jumps it to
/// its end under reduced motion. Call from `didChangeDependencies`; later
/// calls start nothing, and finish an entrance still running once reduced
/// motion is on (a [MediaQueryData.disableAnimations] change reaches
/// `didChangeDependencies`; iOS Reduce Motion is watched from here).
void startEntrance(BuildContext context, AnimationController controller) {
  if (controller.status != AnimationStatus.dismissed) {
    settleIfMotionReduced(context, controller);
    return;
  }
  if (reducedMotionOf(context)) {
    controller.value = controller.upperBound;
  } else {
    controller.forward();
    settleOnReducedMotion(context, controller);
  }
}

/// Finishes [controller]'s run at once when reduced motion is on: a
/// forward run jumps to its upper bound, a reverse run to its lower bound.
/// Call from `didChangeDependencies` of a widget that read
/// [reducedMotionOf], which runs when [MediaQueryData.disableAnimations]
/// changes.
void settleIfMotionReduced(
  BuildContext context,
  AnimationController controller,
) {
  if (controller.isAnimating && reducedMotionOf(context)) _finish(controller);
}

/// Finishes [controller]'s current forward or reverse run at once if
/// reduced motion turns on before it ends. Call right after starting the
/// run; [context] is the owner's, and the watch ends with the run or when
/// [context] unmounts.
void settleOnReducedMotion(
  BuildContext context,
  AnimationController controller,
) {
  if (!controller.isAnimating) return;
  final watch = _MotionWatch(
    context,
    isRunning: () => controller.isAnimating,
    settle: () => _finish(controller),
  );
  void onStatus(AnimationStatus status) {
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      return;
    }
    controller.removeStatusListener(onStatus);
    _ReducedMotionWatcher.instance.unwatch(watch);
  }

  controller.addStatusListener(onStatus);
  _ReducedMotionWatcher.instance.watch(controller, watch);
}

/// [ScrollController.animateTo] [offset], or a jump under reduced motion.
/// A run still going when reduced motion turns on jumps to [offset].
void animateScrollTo(
  BuildContext context,
  ScrollController controller,
  double offset, {
  required Duration duration,
  required Curve curve,
}) {
  if (reducedMotionOf(context)) {
    controller.jumpTo(offset);
    return;
  }
  var running = true;
  final watch = _MotionWatch(
    context,
    isRunning: () => running && controller.hasClients,
    settle: () => controller.jumpTo(offset),
  );
  controller.animateTo(offset, duration: duration, curve: curve).whenComplete(
    () {
      running = false;
      _ReducedMotionWatcher.instance.unwatch(watch);
    },
  );
  _ReducedMotionWatcher.instance.watch(controller, watch);
}

/// [Scrollable.ensureVisible] for [target] over [duration], at once under
/// reduced motion at [context]. A run still going when reduced motion
/// turns on jumps to its end.
void ensureVisibleWithMotion(
  BuildContext context,
  BuildContext target, {
  required Duration duration,
  required Curve curve,
}) {
  if (reducedMotionOf(context)) {
    Scrollable.ensureVisible(target);
    return;
  }
  var running = true;
  final watch = _MotionWatch(
    context,
    isRunning: () => running && target.mounted,
    // A zero-duration call jumps and ends the running one.
    settle: () => Scrollable.ensureVisible(target),
  );
  Scrollable.ensureVisible(
    target,
    duration: duration,
    curve: curve,
  ).whenComplete(() {
    running = false;
    _ReducedMotionWatcher.instance.unwatch(watch);
  });
  _ReducedMotionWatcher.instance.watch(target, watch);
}

void _finish(AnimationController controller) {
  controller.value = controller.status == AnimationStatus.reverse
      ? controller.lowerBound
      : controller.upperBound;
}

/// A run that settles at once when reduced motion turns on.
final class _MotionWatch {
  _MotionWatch(this.context, {required this.isRunning, required this.settle});

  final BuildContext context;
  final bool Function() isRunning;
  final VoidCallback settle;
}

/// Settles the watched runs when the accessibility features change: at
/// once (iOS Reduce Motion, read from the platform), and again after the
/// next frame, once [MediaQuery] carries a new `disableAnimations`.
/// Observes the binding only while it watches a run; a watch ends with
/// its run, or is dropped once its owner unmounts.
final class _ReducedMotionWatcher with WidgetsBindingObserver {
  _ReducedMotionWatcher._();

  static final _ReducedMotionWatcher instance = _ReducedMotionWatcher._();

  /// One watch per animating object (controller or scroll target); a new
  /// run of the same object replaces its watch.
  final Map<Object, _MotionWatch> _watches = {};
  bool _observing = false;
  bool _recheckScheduled = false;

  void watch(Object key, _MotionWatch watch) {
    _prune();
    _watches[key] = watch;
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
  }

  /// Ends [watch]; a newer run of the same object keeps its own.
  void unwatch(_MotionWatch watch) {
    _watches.removeWhere((_, current) => identical(current, watch));
    _stopObservingWhenIdle();
  }

  @override
  void didChangeAccessibilityFeatures() {
    _settle();
    if (_watches.isEmpty || _recheckScheduled) return;
    _recheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recheckScheduled = false;
      _settle();
    });
  }

  void _prune() => _watches.removeWhere(
    (_, watch) => !watch.context.mounted || !watch.isRunning(),
  );

  void _settle() {
    _prune();
    for (final key in [..._watches.keys]) {
      final watch = _watches[key];
      if (watch == null || !reducedMotionOf(watch.context)) continue;
      _watches.remove(key);
      watch.settle();
    }
    _stopObservingWhenIdle();
  }

  void _stopObservingWhenIdle() {
    if (_watches.isNotEmpty || !_observing) return;
    _observing = false;
    WidgetsBinding.instance.removeObserver(this);
  }
}
