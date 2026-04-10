// ignore_for_file: file_names
// The cookbook files are numbered to suggest a reading order. See
// `01_simple_structural_detector.dart` for the full rationale.

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:sleuth/sleuth.dart';

/// Cookbook 02 — The runtime-callback detector.
///
/// Flags frames whose total on-CPU build+raster time exceeds a configurable
/// threshold. Unlike cookbook 01, this detector does NOT inspect widgets —
/// it observes app events via [SchedulerBinding.addTimingsCallback] and
/// stores its findings directly in [_issues].
///
/// Why this can't use [SimpleStructuralDetector]:
///
/// - [SimpleStructuralDetector] is built around `inspect(Element)` — it
///   runs on every element in the tree. We have nothing to inspect here;
///   the data arrives asynchronously from the framework.
/// - The data comes from a long-lived subscription, not a single scan. We
///   need a proper `dispose` to unregister the callback.
///
/// Shape highlights to note when you copy this file:
///
/// 1. **`DetectorLifecycle.runtime`** — this detector uses always-available
///    runtime APIs. It has no VM timeline or tree walk requirements, so it
///    works in every environment.
/// 2. **Subscription management** — `_attachTimingsCallback` is called once
///    in the constructor body, and `dispose` removes the callback. Forgetting
///    this leaks the detector across hot reloads.
/// 3. **`finalizeScan` publishes issues** — callbacks can fire at any time,
///    but the Sleuth controller only reads `issues` during its scan loop.
///    We accumulate slow-frame samples into a ring buffer and materialise
///    them into [PerformanceIssue] objects once per scan.
/// 4. **`_isEnabled` gates both the callback path and scan path** — if the
///    detector is disabled, neither the timings callback nor the scan should
///    emit anything. This is the contract for every [BaseDetector] subclass.
///
/// Use this shape when:
///
/// - You're observing app events (frame timings, route transitions,
///   lifecycle callbacks) instead of inspecting widgets.
/// - Your detector owns a long-lived resource (timer, stream, callback)
///   that must be released in [dispose].
/// - You don't need VM timeline data.
class SlowFrameDetector extends BaseDetector {
  SlowFrameDetector({this.thresholdMs = 32, this.sampleWindow = 60})
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.runtime,
        name: 'Slow Frame Detector',
        description: 'Flags frames whose total time exceeds $thresholdMs ms',
        // Stable key lets SleuthConfig.disabledCustomDetectorKeys turn
        // this detector off without removing it from the detector list.
        key: 'slow_frame_detector',
      ) {
    _attachTimingsCallback();
  }

  /// Frames taking longer than this are considered "slow". Default 32 ms is
  /// a 2x headroom over 16.67 ms (60 FPS budget). Raise for 120 Hz targets.
  final int thresholdMs;

  /// Size of the rolling window used to decide severity. A burst of slow
  /// frames within this window escalates the emitted issue.
  final int sampleWindow;

  final List<PerformanceIssue> _issues = [];
  final List<Duration> _recentSlowFrames = [];
  TimingsCallback? _callback;
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) {
    _isEnabled = value;
    if (!value) {
      _recentSlowFrames.clear();
    }
  }

  /// Attach to the scheduler so we hear about every frame.
  ///
  /// `addTimingsCallback` hands us a list of [FrameTiming] objects after
  /// each frame. Each entry has nanosecond-precision timestamps for the
  /// build, raster, and vsync phases. We only care about the total wall
  /// time, which is `totalSpan.inMilliseconds`.
  ///
  /// **Trap (important):** Sleuth's documented wiring pattern passes the
  /// detector as a constructor argument to `Sleuth.track`, which means the
  /// detector is built during `main()` *before* `runApp()` actually
  /// initializes the Flutter binding. Touching `SchedulerBinding.instance`
  /// at that point crashes with `Null check operator used on a null
  /// value`. The fix is to call `WidgetsFlutterBinding.ensureInitialized()`
  /// first — it is idempotent and safe to call multiple times, and it
  /// guarantees the binding chain (including `SchedulerBinding`) exists
  /// before we ask for `instance`. Test bindings (`TestWidgetsFlutterBinding`)
  /// initialize automatically under `testWidgets`, which is why the
  /// cookbook smoke test does not exercise this path.
  void _attachTimingsCallback() {
    WidgetsFlutterBinding.ensureInitialized();
    _callback = (List<FrameTiming> timings) {
      if (!_isEnabled) return;
      for (final timing in timings) {
        final total = timing.totalSpan.inMilliseconds;
        if (total >= thresholdMs) {
          _recentSlowFrames.add(timing.totalSpan);
          if (_recentSlowFrames.length > sampleWindow) {
            _recentSlowFrames.removeAt(0);
          }
        }
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_callback!);
  }

  /// Reset the issue list at the start of each scan.
  ///
  /// Note: we do NOT reset `_recentSlowFrames` here — that's our rolling
  /// window of cross-scan state. The issue list is the per-scan projection
  /// of that state, which is why [finalizeScan] rebuilds it below.
  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
  }

  /// No tree inspection needed — we don't override [checkElement].
  ///
  /// [SimpleStructuralDetector] users never see this distinction, but for
  /// runtime detectors it's important to know that leaving [checkElement]
  /// unimplemented (default no-op) is correct and intentional.

  /// Materialise rolling-window state into issues at the end of the scan.
  @override
  void finalizeScan() {
    if (!_isEnabled) return;
    if (_recentSlowFrames.isEmpty) return;

    final count = _recentSlowFrames.length;
    final worstMs = _recentSlowFrames
        .map((d) => d.inMilliseconds)
        .fold<int>(0, (max, current) => current > max ? current : max);

    // Severity escalates with burst size. One slow frame is a warning;
    // ten or more is critical (the user will feel it as visible jank).
    final severity = count >= 10
        ? IssueSeverity.critical
        : IssueSeverity.warning;

    _issues.add(
      PerformanceIssue(
        stableId: 'slow_frame_detector',
        severity: severity,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title:
            '$count slow frame${count == 1 ? '' : 's'} '
            '(worst: ${worstMs}ms)',
        detail:
            'Observed $count frame${count == 1 ? '' : 's'} exceeding '
            '${thresholdMs}ms in the last $sampleWindow-sample window. '
            'Worst frame was ${worstMs}ms.',
        fixHint:
            'Profile the build phase with DevTools > Performance. Common '
            'causes: expensive work in build(), synchronous I/O, or a large '
            'widget tree rebuilding unnecessarily.',
        observationSource: ObservationSource.debugCallback,
        detectedAt: DateTime.now(),
      ),
    );
  }

  /// Clear the rolling window when the detector is torn down so that hot
  /// reload and test isolation behave cleanly.
  @override
  void dispose() {
    if (_callback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_callback!);
      _callback = null;
    }
    _issues.clear();
    _recentSlowFrames.clear();
  }
}
