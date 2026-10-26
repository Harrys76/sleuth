import 'sleuth_controller.dart';

/// The controller of the mounted `Sleuth.track` overlay, which the `Sleuth`
/// statics read.
abstract final class ActiveController {
  static SleuthController? current;

  /// Clears [current] only when it is [controller], so disposing an old
  /// overlay does not clear a newer one.
  static void release(SleuthController controller) {
    if (identical(current, controller)) current = null;
  }
}
