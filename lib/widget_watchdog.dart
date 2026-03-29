/// Widget Watchdog — Runtime Performance Diagnostics for Flutter
///
/// Surfaces performance bottlenecks and actionable fixes directly inside
/// your app using three layers of analysis:
/// - **Frame timing**: SchedulerBinding.addTimingsCallback per frame (~zero cost)
/// - **VM timeline** (best-effort): vm_service sub-phase breakdowns when connected
/// - **Widget tree scan**: structural heuristics for common anti-patterns
///
/// ## Usage
///
/// ```dart
/// void main() => runApp(WidgetWatchdog.wrap(child: MyApp()));
/// ```
///
/// ## Features
/// - 21 performance detectors (VM-powered, hybrid, structural, and runtime)
/// - Actionable fix hints for every issue
/// - In-app overlay with live FPS chart and issue dashboard
/// - Debug mode warning (run with --profile for accurate data)
/// - Completely disabled in release builds
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'src/controller/watchdog_controller.dart';
import 'src/models/session_snapshot.dart';
import 'src/ui/watchdog_overlay.dart';

// Public API exports
export 'src/models/performance_issue.dart';
export 'src/models/frame_stats.dart';
export 'src/models/frame_verdict.dart';
export 'src/models/widget_highlight.dart';
export 'src/models/capture_buffer.dart';
export 'src/models/session_snapshot.dart';
export 'src/controller/watchdog_controller.dart' show WatchdogConfig;
export 'src/debug/debug_instrumentation_config.dart';
export 'src/models/base_detector.dart' show DetectorType, DetectorLifecycle;
export 'src/models/allocation_entry.dart';
export 'src/models/cpu_attribution.dart';
export 'src/models/heap_sample.dart';
export 'src/network/request_record.dart';
export 'src/utils/fix_hint_builder.dart';

/// Entry point for the Widget Watchdog package.
///
/// ```dart
/// void main() => runApp(WidgetWatchdog.wrap(child: MyApp()));
/// ```
class WidgetWatchdog {
  WidgetWatchdog._();

  static WatchdogController? _controller;

  /// Wrap your app with the performance overlay.
  ///
  /// In release mode, this returns [child] unchanged (zero cost).
  /// In debug/profile mode, adds the 🐕 overlay with all 21 detectors.
  ///
  /// Optionally pass [config] to customize thresholds and enable/disable
  /// specific detectors.
  static Widget wrap({required Widget child, WatchdogConfig? config}) {
    // Complete no-op in release mode
    if (kReleaseMode) return child;

    final controller = WatchdogController(config: config);
    _controller = controller;

    return WatchdogOverlay(controller: controller, child: child);
  }

  /// Called by [WatchdogOverlay.dispose] to clear the static reference.
  /// Identity check ensures disposing an old overlay doesn't clear a new one.
  ///
  /// Package-internal — do not call from app code.
  static void notifyControllerDisposed(WatchdogController controller) {
    if (_controller == controller) _controller = null;
  }

  /// Export session snapshot for comparison and sharing.
  /// Returns null in release mode, before [wrap], or after overlay disposal.
  static SessionSnapshot? exportSnapshot() => _controller?.exportSnapshot();

  /// Export session snapshot as a formatted JSON string.
  /// Returns null in release mode, before [wrap], or after overlay disposal.
  static String? exportSnapshotJson() => _controller?.exportSnapshotJson();
}
