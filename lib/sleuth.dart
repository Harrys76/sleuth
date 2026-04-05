/// Sleuth — Runtime Performance Diagnostics for Flutter
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
/// void main() => runApp(Sleuth.track(child: MyApp()));
/// ```
///
/// ## Features
/// - 22 performance detectors (VM-powered, hybrid, structural, and runtime)
/// - Actionable fix hints for every issue
/// - In-app overlay with live FPS chart and issue dashboard
/// - Debug mode warning (run with --profile for accurate data)
/// - Completely disabled in release builds
///
/// ## Theming
///
/// The overlay auto-detects dark/light mode from the system brightness.
/// To force a specific theme or customize colors:
///
/// ```dart
/// // Light theme for light-background apps
/// Sleuth.track(
///   child: MyApp(),
///   config: SleuthConfig(theme: SleuthThemeData.light()),
/// );
///
/// // Custom brand colors
/// Sleuth.track(
///   child: MyApp(),
///   config: SleuthConfig(
///     theme: SleuthThemeData.light().copyWith(
///       severityCritical: Color(0xFFDC2626),
///     ),
///   ),
/// );
/// ```
///
/// See [SleuthThemeData] for all available color tokens.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'src/controller/sleuth_controller.dart';
import 'src/models/session_snapshot.dart';
import 'src/ui/sleuth_overlay.dart';

// Public API exports
export 'src/models/ai_chat_adapter.dart';
export 'src/models/performance_issue.dart';
export 'src/models/frame_stats.dart';
export 'src/models/frame_verdict.dart';
export 'src/models/widget_highlight.dart';
export 'src/models/capture_buffer.dart';
export 'src/models/session_snapshot.dart';
export 'src/controller/sleuth_controller.dart' show SleuthConfig;
export 'src/controller/detector_thresholds.dart';
export 'src/ui/sleuth_theme.dart' show SleuthThemeData;
export 'src/debug/debug_instrumentation_config.dart';
export 'src/models/base_detector.dart'
    show DetectorType, DetectorLifecycle, BaseDetector;
export 'src/vm/timeline_parser.dart' show ParsedTimelineData;
export 'src/debug/debug_snapshot.dart' show DebugSnapshot;
export 'src/models/allocation_entry.dart';
export 'src/models/cpu_attribution.dart';
export 'src/models/gc_event_summary.dart';
export 'src/models/heap_sample.dart';
export 'src/models/phase_event.dart';
export 'src/models/platform_channel_summary.dart';
export 'src/network/request_record.dart';
export 'src/utils/fix_hint_builder.dart';

/// Entry point for the Sleuth package.
///
/// ```dart
/// void main() => runApp(Sleuth.track(child: MyApp()));
/// ```
class Sleuth {
  Sleuth._();

  static SleuthController? _controller;

  /// Wrap your app with the performance overlay.
  ///
  /// In release mode, this returns [child] unchanged (zero cost).
  /// In debug/profile mode, adds the overlay with all 22 detectors.
  ///
  /// Optionally pass [config] to customize thresholds, enable/disable
  /// specific detectors, or set a custom [SleuthConfig.theme].
  /// When no theme is provided, the overlay auto-selects dark or light
  /// based on the system brightness.
  static Widget track({required Widget child, SleuthConfig? config}) {
    // Complete no-op in release mode
    if (kReleaseMode) return child;

    final controller = SleuthController(config: config);
    _controller = controller;

    return SleuthOverlay(controller: controller, child: child);
  }

  /// Called by [SleuthOverlay.dispose] to clear the static reference.
  /// Identity check ensures disposing an old overlay doesn't clear a new one.
  ///
  /// Package-internal — do not call from app code.
  static void notifyControllerDisposed(SleuthController controller) {
    if (_controller == controller) _controller = null;
  }

  /// Export session snapshot for comparison and sharing.
  /// Returns null in release mode, before [wrap], or after overlay disposal.
  static SessionSnapshot? exportSnapshot() => _controller?.exportSnapshot();

  /// Export session snapshot as a formatted JSON string.
  /// Returns null in release mode, before [wrap], or after overlay disposal.
  static String? exportSnapshotJson() => _controller?.exportSnapshotJson();
}
