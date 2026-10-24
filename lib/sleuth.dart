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
/// - 21 performance detectors (VM-powered, hybrid, structural, and runtime)
/// - Actionable fix hints for every issue
/// - In-app overlay with live FPS chart and issue dashboard
/// - Debug mode warning (run with --profile for accurate data)
/// - Completely disabled in release builds
///
/// ## Theming
///
/// The overlay auto-detects dark/light mode from the system brightness and
/// uses the high-contrast presets when the platform asks for high
/// contrast. The header toggle cycles System, Light and Dark (persisted in
/// `OverlayUiState.themeMode`). To force a specific theme or customize
/// colors:
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
/// Sleuth.updateTheme(null); // revert to the config theme or auto-detect
/// ```
///
/// See [SleuthThemeData] for all available tokens (colors, spacing,
/// typography, and border radii).
library;

import 'dart:developer' show Timeline;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show FrameTiming, SchedulerBinding;
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart' show experimental;

import 'src/controller/active_controller.dart';
import 'src/controller/sleuth_controller.dart';
import 'src/detectors/network_monitor_detector.dart'
    show NetworkMonitorDetector;
import 'src/detectors/memory_pressure_detector.dart'
    show MemoryPressureDetector;
import 'src/detectors/rebuild_detector.dart' show RebuildDetector;
import 'src/detectors/repaint_detector.dart' show RepaintDetector;
import 'src/detectors/startup_detector.dart' show StartupDetector;
import 'src/detectors/stream_resource_detector.dart'
    show StreamResourceDetector, StreamResourcePollResult;
import 'src/detectors/tracked_resource_detector.dart'
    show TrackedResourceDetector;
import 'src/models/fix_verification_result.dart';
import 'src/models/route_session.dart';
import 'src/models/session_snapshot.dart';
import 'src/models/startup_metrics.dart';
import 'src/startup/startup_tracker.dart';
import 'src/ui/overlay_ui_state.dart';
import 'src/ui/sleuth_overlay.dart';
import 'src/vm/poll_timings.dart';
import 'src/ui/sleuth_theme.dart';

// Public API exports. Every line has a `show` list, and
// test/validation/public_api_test.dart pins the exported names. Capture
// and validation tooling lives in validation.dart instead.
export 'src/ai/ai_providers.dart' show AiProviderException;
export 'src/models/ai_chat_adapter.dart'
    show AiChatAdapter, AiChatMessage, AiChatRequest, AiChatRole;
export 'src/models/performance_issue.dart'
    show
        FixEffort,
        InteractionContext,
        IssueCategory,
        IssueConfidence,
        IssueSeverity,
        ObservationSource,
        PerformanceIssue;
export 'src/models/issue_measurement.dart'
    show IssueMeasurement, MeasurementUnit;
export 'src/models/frame_stats.dart'
    show FpsPercentiles, FrameStats, FrameStatsBuffer;
export 'src/models/frame_verdict.dart' show FrameVerdict, PipelinePhase;
export 'src/models/widget_highlight.dart' show WidgetHighlight;
export 'src/models/capture_buffer.dart' show CaptureEntry;
export 'src/models/not_useful_mark.dart' show NotUsefulMark;
export 'src/models/session_snapshot.dart'
    show FrameStatsSummary, SessionSnapshot;
export 'src/models/snapshot_sections.dart' show SnapshotSection;
export 'src/controller/sleuth_controller.dart' show SleuthConfig;
export 'src/controller/detector_thresholds.dart' show DetectorThresholds;
export 'src/ui/sleuth_theme.dart' show SleuthThemeData;
export 'src/ui/overlay_ui_state.dart'
    show OverlayUiState, TriggerEdge, CardWindowState, SleuthThemeMode;
export 'src/persistence/sleuth_state_store.dart'
    show InMemorySleuthStateStore, SleuthStateStore;
export 'src/debug/debug_instrumentation_config.dart'
    show DebugInstrumentationConfig;
export 'src/models/base_detector.dart'
    show DetectorType, DetectorLifecycle, BaseDetector;
export 'src/models/simple_structural_detector.dart'
    show SimpleStructuralDetector;
export 'src/vm/timeline_parser.dart'
    show ParsedTimelineData, PlatformChannelCall;
export 'src/debug/debug_snapshot.dart'
    show
        DebugSnapshot,
        PaintOriginInstance,
        PaintOriginStats,
        RebuildCountSource;
export 'src/models/allocation_entry.dart' show AllocationEntry;
export 'src/models/cpu_attribution.dart' show CpuAttribution;
export 'src/models/gc_event_summary.dart' show GcEventSummary;
export 'src/models/heap_sample.dart' show HeapSample;
export 'src/models/phase_event.dart' show PhaseEvent, TimelinePhase;
export 'src/models/platform_channel_summary.dart' show PlatformChannelSummary;
export 'src/models/widget_heat_map_entry.dart' show WidgetHeatMapEntry;
export 'src/models/fix_verification_result.dart'
    show FixVerificationResult, FixVerificationStatus, IssueVerificationEntry;
export 'src/network/request_record.dart' show RequestRecord;
export 'src/detectors/network_monitor_detector.dart'
    show NetworkMonitorDetector;
export 'src/detectors/rebuild_detector.dart' show RebuildDetector;
export 'src/detectors/stream_resource_detector.dart'
    show StreamResourceDetector;
export 'src/models/startup_metrics.dart' show StartupMetrics;
export 'src/models/route_session.dart' show RouteSession;

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
///
/// ## Stability
///
/// Members marked `@experimental` drive the capture tooling in
/// `package:sleuth/validation.dart`, and members marked
/// `@visibleForTesting` exist for tests. Both are outside Sleuth's semver
/// promise and can change in a minor release.
class Sleuth {
  Sleuth._();

  static SleuthController? get _controller => ActiveController.current;

  // ── Startup tracing ────────────────────────────────────────────────────

  /// Print-once throttle on pre-init [setResourceThreshold] warning;
  /// multi-name pre-init would otherwise spam the debug console.
  static bool _preInitWarned = false;

  /// The clock [init] and its first-frame callback read. Tests set it to
  /// control the measured time to first frame; null reads
  /// [DateTime.now].
  @visibleForTesting
  static DateTime Function()? get startupClockForTest =>
      StartupTracker.clockForTest;

  @visibleForTesting
  static set startupClockForTest(DateTime Function()? clock) =>
      StartupTracker.clockForTest = clock;

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
  static void init() => StartupTracker.init();

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
  static void markInteractive() => StartupTracker.markInteractive();

  /// Current startup metrics, or null if [init] was not called or the
  /// first frame has not yet been rendered.
  static StartupMetrics? get startupMetrics => StartupTracker.metrics;

  /// Reset startup state for testing purposes only.
  @visibleForTesting
  static void resetStartupForTest() => StartupTracker.resetForTest();

  /// Inject startup metrics for testing purposes only.
  @visibleForTesting
  static void setStartupMetricsForTest(StartupMetrics metrics) =>
      StartupTracker.setMetricsForTest(metrics);

  // ── Core API ───────────────────────────────────────────────────────────

  /// Wrap your app with the performance overlay.
  ///
  /// In release mode, this returns [child] unchanged (zero cost).
  /// In debug/profile mode, adds the overlay with all 21 detectors.
  ///
  /// Optionally pass [config] to customize thresholds, enable/disable
  /// specific detectors, or set a custom [SleuthConfig.theme].
  /// When no theme is provided, the overlay auto-selects dark or light
  /// based on the system brightness.
  static Widget track({required Widget child, SleuthConfig? config}) {
    // Complete no-op in release mode
    if (kReleaseMode) return child;

    // Capture Dart entry timestamp if the app skipped explicit [init];
    // init runs once. Detectors that compare timeline timestamps against
    // app start (e.g. shader-warmup attribution) read
    // `StartupTracker.dartEntryMonotonicUs`, which would stay null on
    // `runApp(Sleuth.track(...))` without this call.
    init();

    final controller = SleuthController(config: config);
    ActiveController.current = controller;

    return SleuthOverlay(controller: controller, child: child);
  }

  /// Emits a `sleuth.scenario.begin` instant trace event for profile-mode
  /// capture procedures. The matching `sleuth.scenario.end` marker MUST be
  /// emitted via [markScenarioEnd] on the same isolate before the work
  /// being measured completes — `ProfileCaptureSchema.validateBracket`
  /// requires the pair so the trace-vs-observed cross-check can compute
  /// span/observed ratios.
  ///
  /// No-op in release mode AND when [SleuthConfig.captureMode] is false
  /// (the default). Production app sessions never emit these markers.
  ///
  /// [name] is recorded as an `args` field; pick something stable across
  /// runs of the same scenario (e.g. `'heavy_compute_above'`).
  @experimental
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
  @experimental
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
  @experimental
  static Future<void> flushTimelineNow({Duration? timeout}) async {
    if (kReleaseMode) return;
    final c = _controller;
    if (c == null || !c.config.captureMode) return;
    await c.flushTimelineNow(timeout: timeout);
  }

  /// Public accessor for the [NetworkMonitorDetector] instance. Capture
  /// screens read [NetworkMonitorDetector.lastObservedPeakCount] and
  /// call [NetworkMonitorDetector.flushFrequencyEvaluation] before
  /// exporting sub-threshold legs so the wrapped magnitude reflects
  /// detector measurement rather than the operator's plan. Returns
  /// null when [Sleuth] has not been initialised or in release mode.
  static NetworkMonitorDetector? get networkMonitor {
    if (kReleaseMode) return null;
    return _controller?.networkMonitor;
  }

  /// Public accessor for the [RebuildDetector] instance. Capture
  /// screens read [RebuildDetector.peakObservedBuildPercent] (and
  /// [RebuildDetector.lastObservedBuildPercent] for calibration) after
  /// driving a Ticker scenario and `await Sleuth.flushTimelineNow()`
  /// so the wrapped magnitude reflects the detector-measured build-time
  /// share rather than the operator's plan. Returns null when
  /// [Sleuth] has not been initialised or in release mode.
  static RebuildDetector? get rebuildDetector {
    if (kReleaseMode) return null;
    return _controller?.rebuildDetector;
  }

  /// Public accessor for the [RepaintDetector] instance. Capture
  /// screens read [RepaintDetector.peakObservedPaintPercent] (and
  /// [RepaintDetector.lastObservedPaintPercent] for calibration) after
  /// driving a paint-heavy scenario so the wrapped magnitude reflects
  /// the detector-measured paint-time share rather than the operator's
  /// plan. Returns null when [Sleuth] has not been
  /// initialised, in release mode, or when [DetectorType.repaint] was
  /// excluded from [SleuthConfig.enabledDetectors].
  @experimental
  static RepaintDetector? get repaintDetector {
    if (kReleaseMode) return null;
    return _controller?.repaintDetector;
  }

  /// Public accessor for the [MemoryPressureDetector] instance. Capture
  /// screens read [MemoryPressureDetector.isHeapGrowingActive] to gate
  /// scenario.begin on the heap-pressure precondition required by
  /// downstream detectors. Returns null when [Sleuth] has not been
  /// initialised, in release mode, or when [DetectorType.memoryPressure]
  /// was excluded from [SleuthConfig.enabledDetectors].
  @experimental
  static MemoryPressureDetector? get memoryPressureDetector {
    if (kReleaseMode) return null;
    return _controller?.memoryPressureDetector;
  }

  /// Public accessor for the [StartupDetector] instance. The
  /// slow_startup_ttff capture flow reads [StartupDetector.evaluated] to
  /// know when the detector has judged the first-frame metrics. Returns
  /// null when [Sleuth] has not been initialised, in release mode, or
  /// when [SleuthConfig.enabledDetectors] leaves out
  /// [DetectorType.startup].
  @experimental
  static StartupDetector? get startupDetector {
    if (kReleaseMode) return null;
    return _controller?.startupDetector;
  }

  /// Public accessor for the [StreamResourceDetector] instance. Capture
  /// screens read [StreamResourceDetector.lastObservedTopGrowthDelta]
  /// after driving a leak workload and call
  /// [StreamResourceDetector.flushStreamResourceEvaluation] so the
  /// wrapped magnitude reflects the detector-measured K=4 window delta
  /// rather than the operator's plan. Returns null when [Sleuth] has
  /// not been initialised, in release mode, or when
  /// [DetectorType.streamResource] was excluded from
  /// [SleuthConfig.enabledDetectors].
  static StreamResourceDetector? get streamResourceDetector {
    if (kReleaseMode) return null;
    return _controller?.streamResourceDetector;
  }

  /// Public accessor for the [TrackedResourceDetector] instance.
  /// Returns null when [Sleuth] has not been initialised or in
  /// release mode. When [DetectorType.trackedResource] is excluded
  /// from [SleuthConfig.enabledDetectors], the detector is
  /// constructed but disabled — `Sleuth.trackResource` /
  /// `Sleuth.untrackResource` no-op via the disabled flag.
  @experimental
  static TrackedResourceDetector? get trackedResourceDetector {
    if (kReleaseMode) return null;
    return _controller?.trackedResourceDetector;
  }

  /// Register [resource] under [name] for opt-in retention tracking.
  /// The tracker holds only a [WeakReference] so registration cannot
  /// prevent garbage collection. Cross-isolate calls are no-ops.
  ///
  /// Emits `tracked_resource_concurrent.warning` when more than
  /// [DetectorThresholds.trackedResourceMaxConcurrent] live instances
  /// share the same name, and `tracked_resource_long_lived.warning`
  /// when a single instance has been alive longer than
  /// [DetectorThresholds.trackedResourceLongLivedSeconds] without
  /// being finalised by the GC.
  ///
  /// [resource] must be a class instance — primitives ([num],
  /// [String], [bool], [Symbol]) and records are silently dropped
  /// (debug builds assert). [Future], [Stream], and closures are
  /// technically tracked but typically not the right target; track
  /// the owning service / repository / subscription instead.
  ///
  /// No-op in release mode and when [Sleuth] has not been
  /// initialised. Pre-init calls do not retain any reference to
  /// [resource].
  static void trackResource(String name, Object resource) {
    if (kReleaseMode) return;
    _controller?.trackResource(name, resource);
  }

  /// Best-effort decrement: removes a registration whose target is
  /// `identical` to [resource] from the bucket named [name]. Silent
  /// no-op when [name] is unknown or the identity does not match
  /// any tracked instance.
  ///
  /// Optional — the GC + Finalizer wiring decrements automatically
  /// when [resource] is reclaimed. Call [untrackResource] when you
  /// want to signal explicit dispose ahead of the next GC cycle.
  static void untrackResource(String name, Object resource) {
    if (kReleaseMode) return;
    _controller?.trackedResourceDetector?.untrack(name, resource);
  }

  /// Override concurrent / long-lived thresholds for resource [name].
  /// Call AFTER [Sleuth.init] — pre-init calls log a once-per-session
  /// debug warning and drop.
  ///
  /// Merge semantics: omitted or invalid axis preserves the prior
  /// value; explicit both-null clears the override and reverts to
  /// global defaults. Updates land on one axis without losing the
  /// other.
  ///
  /// ```dart
  /// Sleuth.setResourceThreshold('http_pool', maxConcurrent: 50);
  /// Sleuth.setResourceThreshold('http_pool', longLivedSeconds: 3600);
  /// // (max: 50, long: 3600) — first call's value preserved.
  /// Sleuth.setResourceThreshold('http_pool'); // clears.
  /// ```
  ///
  /// Does NOT begin tracking — call [trackResource] to register
  /// instances. Override is bucket-independent: survives empty-bucket
  /// sweep, LRU drops, and `isEnabled` toggles. Invalid values
  /// (`<= 0`) drop that axis only and count via
  /// `Sleuth.trackedResourceDetector!.droppedOverridesCount` (debug
  /// only). No-op in release mode and from spawned isolates.
  static void setResourceThreshold(
    String name, {
    int? maxConcurrent,
    int? longLivedSeconds,
  }) {
    if (kReleaseMode) return;
    final detector = _controller?.trackedResourceDetector;
    if (detector == null) {
      // Print once per session — subsequent pre-init calls remain
      // silent to prevent debug-console spam during multi-name init.
      if (kDebugMode && !_preInitWarned) {
        _preInitWarned = true;
        // ignore: avoid_print
        print(
          '[Sleuth] setResourceThreshold was called before Sleuth.init(), '
          'so the override was dropped. This warning prints once per '
          'session.',
        );
      }
      return;
    }
    detector.registerNameOverride(
      name,
      maxConcurrent: maxConcurrent,
      longLivedSeconds: longLivedSeconds,
    );
  }

  /// Capture-pipeline shortcut: trigger one immediate
  /// `getAllocationProfile` RPC + window ingestion on the
  /// [StreamResourceDetector]. Awaits any in-flight automatic poll
  /// before running its own — the explicit poll cannot be silently
  /// skipped behind the auto-path. Returns a [StreamResourcePollResult]
  /// with diagnostic counters (member count, matched count, RPC
  /// elapsed, error reason) so capture screens can log per-poll
  /// evolution and diagnose empty-window failures without another
  /// 50-second on-device session.
  ///
  /// Returns a `disabled` result in release mode, when [Sleuth] has
  /// not been initialised, or when the detector is off. See
  /// [StreamResourceDetector.pollAllocationProfileNow].
  @experimental
  static Future<StreamResourcePollResult>
  pollStreamResourceAllocationProfileNow() async {
    if (kReleaseMode) {
      return const StreamResourcePollResult(
        succeeded: false,
        errorReason: 'release_mode',
      );
    }
    final controller = _controller;
    if (controller == null) {
      return const StreamResourcePollResult(
        succeeded: false,
        errorReason: 'disabled',
      );
    }
    return controller.pollStreamResourceAllocationProfileNowWithCapture();
  }

  /// Reason the most recent [exportCaptureJson] call returned null.
  /// Capture screens display this in their in-app log so operators
  /// can diagnose failures without parsing flutter-tool console
  /// output. Cleared at the start of every [exportCaptureJson] call.
  /// Returns null in release mode or before any capture export has
  /// been attempted.
  @experimental
  static String? get lastCaptureExportFailure {
    if (kReleaseMode) return null;
    return _controller?.lastCaptureExportFailure;
  }

  /// Per-segment cost of the most recent VM timeline poll (RPC with the
  /// decode inside it, parse, detector dispatch, remaining RPCs), with
  /// the time it held the UI isolate, the raw response size and the
  /// duplicate events the poll skipped. Null in
  /// release mode, before [init], without a VM connection, or before the
  /// first poll. The same values are served by `ext.sleuth.diagnose`.
  @experimental
  static PollTimings? get lastPollTimings {
    if (kReleaseMode) return null;
    return _controller?.lastPollTimings;
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
  @experimental
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
  @experimental
  static Future<bool> suspendNonEssentialTimelineStreams() async {
    if (kReleaseMode) return false;
    final c = _controller;
    if (c == null || !c.config.captureMode) return false;
    return c.suspendNonEssentialTimelineStreams();
  }

  /// Restores the full VM timeline stream allowlist
  /// (`['Dart', 'Embedder', 'GC']`). Counterpart to
  /// [suspendNonEssentialTimelineStreams].
  ///
  /// Both return whether the VM accepted the stream list: false in
  /// release mode, outside capture mode, without a VM link, or when the
  /// RPC failed, so a capture procedure can retry a restore that did not
  /// land.
  @experimental
  static Future<bool> resumeAllTimelineStreams() async {
    if (kReleaseMode) return false;
    final c = _controller;
    if (c == null || !c.config.captureMode) return false;
    return c.resumeAllTimelineStreams();
  }

  /// Stops Sleuth's own `getAllocationProfile` reads for a capture leg
  /// and waits up to [timeout] for a read already in flight to finish.
  ///
  /// Sleuth reads the allocation profile when `heap_growing` first
  /// appears, and every 10 s while it stays active for
  /// [StreamResourceDetector]. Each response is decoded on the app's UI
  /// isolate, and the GC activity that follows lands in the heap samples
  /// of a memory capture leg. A
  /// request whose caller timed out still runs until the VM answers, so
  /// the hold also waits for those.
  ///
  /// Returns true when no read is in flight. Returns false when the VM
  /// service is not connected, when [timeout] passes first, or when the
  /// session changed while waiting; the leg should not start then. The
  /// hold stays in place whatever the result and MUST be paired with
  /// [releaseAllocationProfileReads].
  ///
  /// No-op returning false in release mode and when
  /// [SleuthConfig.captureMode] is false.
  @experimental
  static Future<bool> holdAllocationProfileReads({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (kReleaseMode) return false;
    final c = _controller;
    if (c == null || !c.config.captureMode) return false;
    return c.holdAllocationProfileReads(timeout: timeout);
  }

  /// Switches the two legs of `heap_growing` for a capture leg, so each
  /// leg's evidence is recorded alone: the floor leg (heap level right
  /// after idle full collections) and the sample leg (the 500 ms
  /// heap-sample regression). Pass null to leave a leg as it is, and turn
  /// both back on when the leg ends.
  ///
  /// No-op in release mode and when [SleuthConfig.captureMode] is false;
  /// a normal session always runs both legs.
  @experimental
  static void setHeapGrowingLegsForCapture({bool? floor, bool? sample}) {
    if (kReleaseMode) return;
    final c = _controller;
    if (c == null || !c.config.captureMode) return;
    c.setHeapGrowingLegsForCapture(floor: floor, sample: sample);
  }

  /// Ends one [holdAllocationProfileReads].
  @experimental
  static void releaseAllocationProfileReads() {
    if (kReleaseMode) return;
    final c = _controller;
    if (c == null || !c.config.captureMode) return;
    c.releaseAllocationProfileReads();
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
  @experimental
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
    String? bracketStableId,
    String? bracketSeverityLabel,
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
      bracketStableId: bracketStableId,
      bracketSeverityLabel: bracketSeverityLabel,
    );
  }

  /// Export session snapshot for comparison and sharing.
  /// Returns null in release mode, before `wrap`, or after overlay disposal.
  static SessionSnapshot? exportSnapshot() => _controller?.exportSnapshot();

  /// Export session snapshot as a formatted JSON string.
  /// Returns null in release mode, before `wrap`, or after overlay disposal.
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

  /// The overlay's UI state: dashboard open, trigger anchor, card
  /// geometry, hidden issues and severity filter. Null when Sleuth has not
  /// been initialised or in release mode.
  ///
  /// Advanced: the overlay drives this itself. Hiding issues or filtering
  /// severities here changes only what the overlay shows; `ext.sleuth.*`,
  /// snapshots and budgets still report every issue.
  static OverlayUiState? get overlayUiState {
    if (kReleaseMode) return null;
    return _controller?.overlayUiState;
  }

  /// Whether [overlayUiState] holds its startup value (the configured
  /// `SleuthConfig.stateStore` has been read, failed, or timed out).
  /// False when Sleuth has not been initialised or in release mode.
  static bool get isOverlayUiStateReady {
    if (kReleaseMode) return false;
    return _controller?.uiStateReady.value ?? false;
  }

  /// Update the overlay theme at runtime.
  ///
  /// Passing a [SleuthThemeData] overrides the config theme and
  /// auto-detection, and sets the header toggle to System so the theme
  /// shows. Picking Light or Dark in the header takes precedence over it;
  /// picking System shows it again. Passing `null` reverts to the config
  /// theme or auto-detection. Pass the same instance on every call (a
  /// const preset or a theme built once): the overlay compares themes by
  /// identity.
  ///
  /// ```dart
  /// Sleuth.updateTheme(const SleuthThemeData.light());
  /// Sleuth.updateTheme(const SleuthThemeData.highContrastDark());
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
