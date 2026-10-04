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
/// Read when an animation starts. A change of setting applies to the next
/// animation; one already running finishes at its old duration.
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
/// calls do nothing.
void startEntrance(BuildContext context, AnimationController controller) {
  if (controller.status != AnimationStatus.dismissed) return;
  if (reducedMotionOf(context)) {
    controller.value = controller.upperBound;
  } else {
    controller.forward();
  }
}
