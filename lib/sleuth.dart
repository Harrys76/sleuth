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
/// - 23 performance detectors (VM-powered, hybrid, structural, and runtime)
/// - Actionable fix hints for every issue
/// - In-app overlay with live FPS chart and issue dashboard
/// - Debug mode warning (run with --profile for accurate data)
/// - Completely disabled in release builds
///
/// ## Theming
///
/// The overlay auto-detects dark/light mode from the system brightness.
/// A built-in toggle in the overlay header lets you switch at runtime.
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
///
/// // Toggle at runtime (e.g. from app code)
/// Sleuth.updateTheme(const SleuthThemeData.light());
/// Sleuth.updateTheme(null); // revert to auto-detect
/// ```
///
/// See [SleuthThemeData] for all available tokens (colors, spacing,
/// typography, and border radii).
library;

import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show FrameTiming, SchedulerBinding;
import 'package:flutter/widgets.dart';

import 'src/controller/sleuth_controller.dart';
import 'src/models/fix_verification_result.dart';
import 'src/models/route_session.dart';
import 'src/models/session_snapshot.dart';
import 'src/models/startup_metrics.dart';
import 'src/ui/sleuth_overlay.dart';
import 'src/ui/sleuth_theme.dart';

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
export 'src/models/simple_structural_detector.dart';
export 'src/vm/timeline_parser.dart' show ParsedTimelineData;
export 'src/debug/debug_snapshot.dart' show DebugSnapshot, RebuildCountSource;
export 'src/models/allocation_entry.dart';
export 'src/models/cpu_attribution.dart';
export 'src/models/gc_event_summary.dart';
export 'src/models/heap_sample.dart';
export 'src/models/phase_event.dart';
export 'src/models/platform_channel_summary.dart';
export 'src/models/recurrence_trend.dart';
export 'src/models/widget_heat_map_entry.dart';
export 'src/models/fix_verification_result.dart'
    show FixVerificationResult, FixVerificationStatus, IssueVerificationEntry;
export 'src/network/request_record.dart';
export 'src/utils/fix_hint_builder.dart';
export 'src/utils/session_markdown_exporter.dart';
export 'src/models/startup_metrics.dart';
export 'src/models/route_session.dart';
export 'src/validation/evidence_tier.dart';
export 'src/validation/detector_metadata.dart';
export 'src/validation/component_metadata.dart';
export 'src/validation/profile_capture_schema.dart';

/// Entry point for the Sleuth package.
///
/// ## Startup tracing (recommended)
///
/// For accurate time-to-first-frame measurement, call [init] before [runApp]:
///
/// ```dart
/// void main() {
///   Sleuth.init();
///   runApp(Sleuth.track(child: MyApp()));
/// }
/// ```
///
/// ## Basic usage
///
/// ```dart
/// void main() => runApp(Sleuth.track(child: MyApp()));
/// ```
class Sleuth {
  Sleuth._();

  static SleuthController? _controller;

  // ── Startup tracing state ──────────────────────────────────────────────

  /// Whether [init] has been called. Prevents double-measurement.
  /// Survives hot restart (intentional — warm VM numbers are misleading).
  static bool _initCalled = false;

  /// Dart entry timestamp captured by [init].
  static DateTime? _dartEntryTimestamp;

  /// Monotonic microsecond timestamp from `Timeline.now` at [init] entry.
  /// Same clock domain as engine timeline events.
  static int? _dartEntryMonotonicUs;

  /// Framework init duration in microseconds (direct measurement).
  static int? _frameworkInitDurationUs;

  /// Startup metrics populated by the first-frame callback.
  static StartupMetrics? _startupMetrics;

  /// Buffered engine events that arrived before the first-frame callback.
  /// Flushed into [_startupMetrics] when the callback fires.
  static _PendingEngineEvents? _pendingEngineEvents;

  /// Timestamp when [markInteractive] was called.
  static DateTime? _interactiveTimestamp;

  /// Initialize startup tracing before [runApp].
  ///
  /// Captures the Dart entry timestamp and registers a one-shot
  /// [SchedulerBinding.addTimingsCallback] to measure the first frame.
  /// This provides accurate time-to-first-frame (TTFF) data.
  ///
  /// Call this **before** [runApp] for best accuracy:
  /// ```dart
  /// void main() {
  ///   Sleuth.init();
  ///   runApp(Sleuth.track(child: MyApp()));
  /// }
  /// ```
  ///
  /// **Measurement window.** [StartupMetrics.ttffMs] is measured from this
  /// call (Dart entry) to the first [FrameTiming] raster-finish. It
  /// deliberately excludes the native pre-Dart phase, which differs by
  /// platform:
  ///
  /// - **iOS**: `dyld`, Obj-C `+load`, `UIApplicationMain`, `AppDelegate`
  ///   init, `FlutterEngine` creation, Dart VM bootstrap, AOT snapshot
  ///   load — typically 400–1200ms on iPhone 12-class cold starts.
  /// - **Android**: Zygote fork, `Application.onCreate`, ContentProvider
  ///   auto-init (Firebase, WorkManager, etc.), `FlutterActivity.onCreate`,
  ///   `FlutterEngine` creation, Dart VM bootstrap, AOT snapshot load —
  ///   typically 300–900ms on mid-range devices, often >1500ms on budget
  ///   / Android Go hardware.
  ///
  /// That portion is outside Dart's control, so `ttffMs` isolates the
  /// part your Dart code can actually move. This is **not** the same
  /// window as `flutter run --trace-startup`, which measures from engine
  /// C++ entry — expect its numbers to be larger by the pre-Dart
  /// overhead on either platform.
  ///
  /// For the `--trace-startup`-equivalent number, read
  /// [StartupMetrics.engineTtffMs] (engine C++ entry → first frame
  /// rasterized). For the native-phase gap alone, read
  /// [StartupMetrics.preDartOverheadMs]. Both are populated retroactively
  /// when VM timeline enrichment lands before the ring buffer evicts the
  /// `FlutterEngineMainEnter` event — reliable in debug/profile mode,
  /// unavailable in release.
  ///
  /// Zero-cost in release mode. Safe to call multiple times (only the
  /// first invocation measures). Survives hot restart intentionally —
  /// a warm VM gives misleading cold-start numbers.
  static void init() {
    if (kReleaseMode) return;
    if (_initCalled) return;
    _initCalled = true;
    _dartEntryTimestamp = DateTime.now();
    _dartEntryMonotonicUs = Timeline.now;

    // Ensure bindings exist so SchedulerBinding is available.
    // Wrap in Timeline.now to directly measure framework init duration
    // (100% reliable — no VM timeline needed for this metric).
    final fwInitStart = Timeline.now;
    try {
      WidgetsFlutterBinding.ensureInitialized();
    } catch (_) {
      // Custom binding already initialized. Timestamp is still captured;
      // FrameTiming callback registration may fail below — that's OK,
      // the detector will use the timestamp-only fallback.
    }
    _frameworkInitDurationUs = Timeline.now - fwInitStart;

    try {
      late void Function(List<FrameTiming>) callback;
      callback = (List<FrameTiming> timings) {
        // Unregister immediately — one-shot.
        SchedulerBinding.instance.removeTimingsCallback(callback);

        if (timings.isEmpty) return;
        final first = timings.first;

        final vsyncStart = first.timestampInMicroseconds(
          FramePhase.vsyncStart,
        );
        final buildStart = first.timestampInMicroseconds(
          FramePhase.buildStart,
        );
        final buildFinish = first.timestampInMicroseconds(
          FramePhase.buildFinish,
        );
        final rasterStart = first.timestampInMicroseconds(
          FramePhase.rasterStart,
        );
        final rasterFinish = first.timestampInMicroseconds(
          FramePhase.rasterFinish,
        );

        final vsyncOverhead = (buildStart - vsyncStart) / 1000.0;
        final buildMs = (buildFinish - buildStart) / 1000.0;
        final rasterMs = (rasterFinish - rasterStart) / 1000.0;
        final totalMs = (rasterFinish - vsyncStart) / 1000.0;

        // TTFF = time from Dart entry to first frame raster complete.
        // Use wall-clock DateTime.now() — FrameTiming timestamps are from the
        // monotonic system clock (uptime-based), not the Unix epoch, so
        // DateTime.fromMicrosecondsSinceEpoch(rasterFinish) would produce
        // garbage when diffed against _dartEntryTimestamp (wall clock).
        final firstFrameCompleteTime = DateTime.now();
        final ttff = firstFrameCompleteTime
                .difference(_dartEntryTimestamp!)
                .inMicroseconds /
            1000.0;

        _startupMetrics = StartupMetrics(
          dartEntryTimestamp: _dartEntryTimestamp!,
          ttffMs: ttff > 0 ? ttff : null,
          ttiMs: _interactiveTimestamp != null
              ? _interactiveTimestamp!
                      .difference(_dartEntryTimestamp!)
                      .inMicroseconds /
                  1000.0
              : null,
          firstFrameVsyncOverheadMs: vsyncOverhead,
          firstFrameBuildMs: buildMs,
          firstFrameRasterMs: rasterMs,
          firstFrameTotalMs: totalMs,
          dartEntryMonotonicUs: _dartEntryMonotonicUs,
          frameworkInitDurationUs: _frameworkInitDurationUs,
        );

        // Flush any engine events that arrived before first frame.
        if (_pendingEngineEvents != null) {
          _startupMetrics = _startupMetrics!.copyWith(
            engineEnterUs: _pendingEngineEvents!.engineEnterUs,
            firstFrameRasterizedUs:
                _pendingEngineEvents!.firstFrameRasterizedUs,
            vmFirstBuildScopeMs: _pendingEngineEvents!.vmFirstBuildScopeMs,
            vmFirstFlushLayoutMs: _pendingEngineEvents!.vmFirstFlushLayoutMs,
            vmFirstFlushPaintMs: _pendingEngineEvents!.vmFirstFlushPaintMs,
            vmFirstRasterMs: _pendingEngineEvents!.vmFirstRasterMs,
          );
          _pendingEngineEvents = null;
        }
      };
      SchedulerBinding.instance.addTimingsCallback(callback);
    } catch (_) {
      // SchedulerBinding not available (custom binding without
      // SchedulerBinding mixin). TTFF will not be measured, but
      // _dartEntryTimestamp is still available for TTI calculation.
    }
  }

  /// Mark the app as interactive.
  ///
  /// Call this when your app's home screen is fully loaded and ready
  /// for user interaction. TTI is measured from [init] to this call.
  ///
  /// ```dart
  /// @override
  /// void initState() {
  ///   super.initState();
  ///   Sleuth.markInteractive();
  /// }
  /// ```
  ///
  /// No-op in release mode or if [init] was not called.
  static void markInteractive() {
    if (kReleaseMode) return;
    if (_dartEntryTimestamp == null) return;
    _interactiveTimestamp = DateTime.now();

    // Update metrics if already captured by the first-frame callback.
    if (_startupMetrics != null) {
      _startupMetrics = _startupMetrics!.copyWith(
        ttiMs: _interactiveTimestamp!
                .difference(_dartEntryTimestamp!)
                .inMicroseconds /
            1000.0,
      );
    }
  }

  /// Current startup metrics, or null if [init] was not called or the
  /// first frame has not yet been rendered.
  ///
  /// Package-internal — read by [StartupDetector] and [SleuthController].
  static StartupMetrics? get startupMetrics => _startupMetrics;

  /// Enrich startup metrics with VM timeline data (package-internal).
  ///
  /// Called by [SleuthController] on the first timeline poll when
  /// retroactive startup events are found in the VM ring buffer.
  /// Accepts both VM sub-phase durations and engine-level timestamps
  /// extracted from the timeline.
  static void enrichStartupWithVmData({
    double? vmFirstBuildScopeMs,
    double? vmFirstFlushLayoutMs,
    double? vmFirstFlushPaintMs,
    double? vmFirstRasterMs,
    int? engineEnterUs,
    int? firstFrameRasterizedUs,
  }) {
    if (_startupMetrics == null) {
      // First-frame callback hasn't fired yet. Buffer all VM data
      // for deferred application when metrics become available.
      if (engineEnterUs != null ||
          firstFrameRasterizedUs != null ||
          vmFirstBuildScopeMs != null ||
          vmFirstFlushLayoutMs != null ||
          vmFirstFlushPaintMs != null ||
          vmFirstRasterMs != null) {
        _pendingEngineEvents = _PendingEngineEvents(
          engineEnterUs: engineEnterUs,
          firstFrameRasterizedUs: firstFrameRasterizedUs,
          vmFirstBuildScopeMs: vmFirstBuildScopeMs,
          vmFirstFlushLayoutMs: vmFirstFlushLayoutMs,
          vmFirstFlushPaintMs: vmFirstFlushPaintMs,
          vmFirstRasterMs: vmFirstRasterMs,
        );
      }
      return;
    }
    _startupMetrics = _startupMetrics!.copyWith(
      vmFirstBuildScopeMs: vmFirstBuildScopeMs,
      vmFirstFlushLayoutMs: vmFirstFlushLayoutMs,
      vmFirstFlushPaintMs: vmFirstFlushPaintMs,
      vmFirstRasterMs: vmFirstRasterMs,
      engineEnterUs: engineEnterUs,
      firstFrameRasterizedUs: firstFrameRasterizedUs,
    );
  }

  /// Reset startup state for testing purposes only.
  @visibleForTesting
  static void resetStartupForTest() {
    _initCalled = false;
    _dartEntryTimestamp = null;
    _dartEntryMonotonicUs = null;
    _frameworkInitDurationUs = null;
    _startupMetrics = null;
    _pendingEngineEvents = null;
    _interactiveTimestamp = null;
  }

  /// Inject startup metrics for testing purposes only.
  @visibleForTesting
  static void setStartupMetricsForTest(StartupMetrics metrics) {
    _startupMetrics = metrics;
  }

  // ── Core API ───────────────────────────────────────────────────────────

  /// Wrap your app with the performance overlay.
  ///
  /// In release mode, this returns [child] unchanged (zero cost).
  /// In debug/profile mode, adds the overlay with all 23 detectors.
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

  /// Emits a `sleuth.scenario.begin` instant trace event for profile-mode
  /// capture procedures. The matching `sleuth.scenario.end` marker MUST be
  /// emitted via [markScenarioEnd] on the same isolate before the work
  /// being measured completes — `ProfileCaptureSchema.validateBracket`
  /// requires the pair so the AB-1 cross-check can compute span/observed
  /// ratios.
  ///
  /// No-op in release mode AND when [SleuthConfig.captureMode] is false
  /// (the default). Production app sessions never emit these markers.
  ///
  /// [name] is recorded as an `args` field; pick something stable across
  /// runs of the same scenario (e.g. `'heavy_compute_above'`).
  static void markScenarioBegin(String name) {
    if (kReleaseMode) return;
    final c = _controller;
    if (c == null || !c.config.captureMode) return;
    // Reset per-detector record buffers (NetworkMonitor; future
    // runtimeVerified detectors that hold scenario-bounded state) so a
    // multi-leg flow on one screen does not leak leg N records into
    // leg N+1. Note: this does NOT clear the producer-side composite-
    // key dedup set — that set must persist across scenarios so stale
    // events in the retainTimeline=true VM buffer cannot re-emit on
    // the next scenario's flush. Stable per-event identity (e.g.
    // dedupIdentityMicros derived from event.timestampUs) ensures
    // every legitimate new emission still maps to a unique composite
    // key. See SleuthController.resetCaptureState for the full rationale.
    c.resetCaptureState();
    Timeline.instantSync('sleuth.scenario.begin', arguments: {'name': name});
  }

  /// Counterpart to [markScenarioBegin]. Emits `sleuth.scenario.end`
  /// after the work being measured completes.
  static void markScenarioEnd(String name) {
    if (kReleaseMode) return;
    final c = _controller;
    if (c == null || !c.config.captureMode) return;
    Timeline.instantSync('sleuth.scenario.end', arguments: {'name': name});
  }

  /// Forces a synchronous VM-timeline poll AND drains any pending
  /// detector issue-record emissions before the returned Future
  /// completes. Call this BETWEEN [markScenarioBegin] and
  /// [markScenarioEnd] so vmOnly detector traces (HeavyCompute,
  /// ShaderJank, MemoryPressure, GpuPressure, PlatformChannel) land
  /// inside the scenario span instead of post-dating it on the next
  /// 500 ms poll tick.
  ///
  /// The caller MUST `await` this call. Without `await`, the poll +
  /// emission may not complete before [markScenarioEnd] fires, the
  /// trace record lands outside the span, and
  /// `ProfileCaptureSchema.validateBracket` rejects the capture.
  ///
  /// No-op (returns immediately) in release mode AND when
  /// [SleuthConfig.captureMode] is false. Production app sessions
  /// pay zero overhead.
  ///
  /// [timeout] guards against an unresponsive VM service. When
  /// non-null and the poll exceeds the duration, the returned Future
  /// completes with a `TimeoutException` — caller should treat this
  /// as a failed capture and retry.
  static Future<void> flushTimelineNow({Duration? timeout}) async {
    if (kReleaseMode) return;
    final c = _controller;
    if (c == null || !c.config.captureMode) return;
    await c.flushTimelineNow(timeout: timeout);
  }

  /// Diagnostic snapshot of capture-mode preconditions. Capture screens
  /// call this on `exportCaptureJson` null-return to surface the exact
  /// environmental state to the operator without requiring Console.app
  /// or `flutter run` terminal access. None of the values are
  /// load-bearing for the audit pipeline — purely diagnostic.
  ///
  /// Returns:
  /// - `initialized`: `Sleuth.init()` has been called and the controller
  ///   is constructed. False = `init()` was skipped or `kReleaseMode`
  ///   stripped Sleuth out.
  /// - `captureMode`: `SleuthConfig.captureMode` is true on the live
  ///   controller. False = `markScenarioBegin/End`, `flushTimelineNow`,
  ///   and `exportCaptureJson` are all no-ops (capture markers never
  ///   reach the buffer, export returns null with "scenario markers
  ///   not found"). Most common cause: `--dart-define=SLEUTH_CAPTURE_MODE
  ///   =true` not passed at launch.
  /// - `vmConnected`: VM service client is connected (VM+ mode active).
  ///   False = FRAME mode (DevTools / `flutter run` owns the VM service)
  ///   so `exportCaptureJson` returns null with "VM service client
  ///   disconnected".
  static ({bool initialized, bool captureMode, bool vmConnected})
      diagnoseCaptureState() {
    final c = _controller;
    if (c == null) {
      return (initialized: false, captureMode: false, vmConnected: false);
    }
    return (
      initialized: true,
      captureMode: c.config.captureMode,
      vmConnected: c.isVmConnected,
    );
  }

  /// Narrows the VM timeline stream allowlist to `Dart` only for the
  /// duration of a long-running scenario. Disables Embedder + GC
  /// streams (high-volume per-frame paint/raster/build/GC events) so
  /// the default ~50k-event ring buffer cannot overflow during 10s+
  /// allocation phases. Required for the MemoryPressure heap_growing
  /// capture procedure where the 30s sustained-allocation phase would
  /// otherwise roll scenario.begin off the buffer before
  /// [exportCaptureJson] can read it.
  ///
  /// MUST be paired with [resumeAllTimelineStreams] after the scenario
  /// completes — otherwise subsequent live-monitoring sessions see
  /// degraded timeline coverage.
  ///
  /// No-op in release mode AND when [SleuthConfig.captureMode] is
  /// false. Production app sessions never narrow streams.
  static Future<void> suspendNonEssentialTimelineStreams() async {
    if (kReleaseMode) return;
    final c = _controller;
    if (c == null || !c.config.captureMode) return;
    await c.suspendNonEssentialTimelineStreams();
  }

  /// Restores the full VM timeline stream allowlist
  /// (`['Dart', 'Embedder', 'GC']`). Counterpart to
  /// [suspendNonEssentialTimelineStreams].
  static Future<void> resumeAllTimelineStreams() async {
    if (kReleaseMode) return;
    final c = _controller;
    if (c == null || !c.config.captureMode) return;
    await c.resumeAllTimelineStreams();
  }

  /// Composes a `runtimeVerified`-conformant capture JSON for the
  /// most recent scenario whose `markScenarioBegin` / `markScenarioEnd`
  /// markers are still in the VM timeline buffer. Used by capture
  /// procedures where DevTools is unavailable (e.g. re-opened iOS
  /// profile-mode build with no `flutter run` attached).
  ///
  /// Returns null when:
  /// - Sleuth is not initialized.
  /// - VM service is disconnected (FRAME mode).
  /// - The scenario markers are missing from the VM trace buffer.
  /// - The trace fetch fails for any other reason.
  ///
  /// The returned string is the full wrapped capture (Chrome Trace
  /// `traceEvents` array filtered to the scenario span +
  /// `sleuthMetadata` block) and can be written directly to a file
  /// by the caller. The library does NOT do file I/O — example apps
  /// or capture screens are expected to use `path_provider` (or
  /// equivalent) to write the result somewhere the operator can
  /// extract via Xcode device sandbox / `adb pull` / share sheet.
  ///
  /// Pre-conditions for an audit-conformant export:
  /// - The detector pipeline must have fired its issue inside the
  ///   scenario span — i.e. the VM service is connected and the
  ///   detector observed its threshold-crossing input. Without that
  ///   the wrapped capture lacks the required
  ///   `sleuth.issue.<id>.<severity>` trace record and the schema
  ///   audit will reject it as "Missing detector trace record."
  /// - `SleuthConfig.captureMode` must be true so the VM service
  ///   client retains the trace buffer between polls (otherwise
  ///   scenario events get cleared before Export can read them).
  static Future<String?> exportCaptureJson({
    required String scenario,
    required String role,
    required num magnitudeMin,
    required num magnitudeObserved,
    required num magnitudeMax,
    required String unit,
    required String device,
    required String deviceOsVersion,
    required String flutterVersion,
    String? captureCommand,
    String? captureNotes,
    String? magnitudeSourceEventName,
  }) async {
    if (kReleaseMode) return null;
    final c = _controller;
    if (c == null) return null;
    return c.exportCaptureJson(
      scenario: scenario,
      role: role,
      magnitudeMin: magnitudeMin,
      magnitudeObserved: magnitudeObserved,
      magnitudeMax: magnitudeMax,
      magnitudeSourceEventName: magnitudeSourceEventName,
      unit: unit,
      device: device,
      deviceOsVersion: deviceOsVersion,
      flutterVersion: flutterVersion,
      captureCommand: captureCommand,
      captureNotes: captureNotes,
    );
  }

  /// Export session snapshot for comparison and sharing.
  /// Returns null in release mode, before [wrap], or after overlay disposal.
  static SessionSnapshot? exportSnapshot() => _controller?.exportSnapshot();

  /// Export session snapshot as a formatted JSON string.
  /// Returns null in release mode, before [wrap], or after overlay disposal.
  static String? exportSnapshotJson() => _controller?.exportSnapshotJson();

  /// Export a human-readable markdown summary suitable for pasting into
  /// Slack, a PR description, or a bug report. Includes the top ranked
  /// issues, frame stats, and causal chains.
  ///
  /// Unlike [exportSnapshotJson], this is lossy by design — it trims to
  /// the top 5 issues by default and drops the raw frame histogram.
  ///
  /// Returns `null` in release mode or before [track] has been called.
  /// Pass [topN] to override the issue count (capped at 20).
  static String? exportSummary({int topN = 5}) =>
      _controller?.exportSummary(topN: topN);

  /// Per-route session history. Returns null if Sleuth is not initialized.
  ///
  /// Each [RouteSession] contains per-route FPS, issue snapshots, and a
  /// composite [RouteSession.healthScore]. The list is ordered chronologically
  /// (oldest first) and capped at [SleuthConfig.routeHistoryCapacity].
  ///
  /// In bottom-nav / tab-shell apps (`IndexedStack`,
  /// `StatefulShellRoute.indexedStack`, `CupertinoTabScaffold`) multiple
  /// sessions may share the same [RouteSession.routeName] — they are
  /// disambiguated by [RouteSession.scaffoldHashKey] and
  /// [RouteSession.tabVisitIndex]. Group by the compound key
  /// `(routeName, scaffoldHashKey)` to see one entry per tab.
  static List<RouteSession>? get routeHistory =>
      _controller?.routeHistoryNotifier.value;

  /// Health score for a specific route. Returns null if the route has not
  /// been visited or Sleuth is not initialized.
  ///
  /// The score ranges from 0 (severely degraded) to 100 (perfect).
  ///
  /// In tab-shell apps where multiple sessions share the same [routeName],
  /// this returns the health of the FIRST (oldest) matching session. For
  /// per-tab health inspection, iterate [routeHistory] and match on
  /// `(routeName, scaffoldHashKey)` directly.
  static int? routeHealthScore(String routeName) {
    return _controller?.routeHistoryNotifier.value
        .cast<RouteSession?>()
        .firstWhere((s) => s?.routeName == routeName, orElse: () => null)
        ?.healthScore;
  }

  /// Update the overlay theme at runtime.
  ///
  /// Passing a [SleuthThemeData] overrides both the config theme and
  /// auto-detection. Passing `null` reverts to the config theme or
  /// auto-detection.
  ///
  /// ```dart
  /// Sleuth.updateTheme(const SleuthThemeData.light());
  /// ```
  static void updateTheme(SleuthThemeData? theme) {
    _controller?.updateTheme(theme);
  }

  /// Capture a baseline of current issues for fix verification.
  /// After applying a fix and hot-reloading, call [compareToBaseline]
  /// to see which issues improved or resolved.
  static void captureBaseline() => _controller?.captureBaseline();

  /// Compare current issues against the captured baseline.
  /// Returns null if no baseline was captured or in release mode.
  static FixVerificationResult? compareToBaseline() =>
      _controller?.compareToBaseline();

  /// Whether a fix baseline has been captured.
  static bool get hasBaseline => _controller?.hasBaseline ?? false;

  /// Clear the fix verification baseline.
  static void clearBaseline() => _controller?.clearBaseline();
}

/// Buffered engine events that arrived before the first-frame callback.
class _PendingEngineEvents {
  const _PendingEngineEvents({
    this.engineEnterUs,
    this.firstFrameRasterizedUs,
    this.vmFirstBuildScopeMs,
    this.vmFirstFlushLayoutMs,
    this.vmFirstFlushPaintMs,
    this.vmFirstRasterMs,
  });
  final int? engineEnterUs;
  final int? firstFrameRasterizedUs;
  final double? vmFirstBuildScopeMs;
  final double? vmFirstFlushLayoutMs;
  final double? vmFirstFlushPaintMs;
  final double? vmFirstRasterMs;
}
