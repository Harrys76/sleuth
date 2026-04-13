import 'dart:async';
import 'dart:collection';

import 'package:flutter/cupertino.dart' show CupertinoPageScaffold;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Scaffold, TabBarView;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:vm_service/vm_service.dart' show AllocationProfile, Event;

import '../ui/floating_issues_card.dart';
import '../ui/highlight_overlay.dart';
import '../ui/trigger_button.dart';
import '../ui/sleuth_theme.dart';
import '../analyzer/causal_graph.dart';
import '../analyzer/detector_correlator.dart';
import '../analyzer/frame_event_correlator.dart';
import '../analyzer/render_pipeline_analyzer.dart';
import '../models/ai_chat_adapter.dart';
import 'detector_thresholds.dart';
import '../debug/debug_instrumentation_config.dart';
import '../debug/debug_instrumentation_coordinator.dart';
import '../debug/debug_snapshot.dart';
import '../detectors/frame_timing_detector.dart';
import '../detectors/shader_jank_detector.dart';
import '../detectors/heavy_compute_detector.dart';
import '../detectors/platform_channel_detector.dart';
import '../detectors/memory_pressure_detector.dart';
import '../detectors/repaint_detector.dart';
import '../detectors/rebuild_detector.dart';
import '../detectors/setstate_scope_detector.dart';
import '../detectors/gpu_pressure_detector.dart';
import '../detectors/shallow_rebuild_risk_detector.dart';
import '../detectors/layout_bottleneck_detector.dart';
import '../detectors/listview_detector.dart';
import '../detectors/image_memory_detector.dart';
import '../detectors/global_key_detector.dart';
import '../detectors/nested_scroll_detector.dart';
import '../detectors/custom_painter_detector.dart';
import '../detectors/keep_alive_detector.dart';
import '../detectors/animated_builder_detector.dart';
import '../detectors/opacity_detector.dart';
import '../detectors/font_loading_detector.dart';
import '../detectors/network_monitor_detector.dart';
import '../detectors/repaint_boundary_detector.dart';
import '../detectors/startup_detector.dart';
import '../../sleuth.dart' show Sleuth;
import '../models/allocation_entry.dart';
import '../models/base_detector.dart';
import '../models/gc_event_summary.dart';
import '../models/heap_sample.dart';
import '../models/capture_buffer.dart';
import '../models/frame_stats.dart';
import '../models/frame_verdict.dart';
import '../models/performance_issue.dart';
import '../models/phase_event.dart';
import '../models/platform_channel_summary.dart';
import '../models/fix_verification_result.dart';
import '../models/recurrence_trend.dart';
import '../models/route_session.dart';
import '../models/session_snapshot.dart';
import '../models/widget_heat_map_entry.dart';
import '../models/widget_highlight.dart';
import '../network/http_monitor.dart';
import '../ranking/issue_ranker.dart';
import '../vm/cpu_sample_aggregator.dart';
import '../vm/vm_service_client.dart';
import '../utils/session_markdown_exporter.dart';
import '../utils/type_name_cache.dart';
import '../vm/timeline_parser.dart';

/// Central controller aggregating all detectors and the pipeline analyzer.
class SleuthController {
  SleuthController({SleuthConfig? config})
      : config = config ?? const SleuthConfig(),
        _captureBuffer = JankCaptureBuffer(
          capacity: (config ?? const SleuthConfig()).captureBufferCapacity,
        ) {
    // Runtime validation for fields that cannot be asserted in a const
    // constructor because Duration operators are not const-evaluable.
    // These would otherwise silently hang the scan loop with a zero-tick
    // timer in debug mode.
    assert(() {
      final interval = (config ?? const SleuthConfig()).treeScanInterval;
      if (interval <= Duration.zero) {
        throw ArgumentError(
          'SleuthConfig.treeScanInterval must be > Duration.zero, got $interval. '
          'Use Duration(seconds: 1) or longer for normal operation.',
        );
      }
      return true;
    }());
    _compileSuppressions();
  }

  final SleuthConfig config;

  // Precompiled suppression patterns (v6.15).
  late final Set<String> _exactSuppressions;
  late final List<String> _prefixSuppressions;

  // Capture buffer — eager init so exportSnapshot() is safe before initialize()
  final JankCaptureBuffer _captureBuffer;
  int _lastCapturedFrameNumber = -1;

  // VM layer
  VmServiceClient? _vmClient;

  // -- First-launch / BASIC-mode recovery --
  //
  // On cold start, the VM web server may not be bound yet when initialize()
  // runs. VmServiceClient.connect() has its own short retry window
  // (~13.5 s total), but on real iOS devices in profile mode the dyld + engine
  // + VM bind race can easily outlast that budget. If the initial connect
  // fails, we fall to BASIC verdict mode and previously had NO way back —
  // the poll-error reconnect path only fires once polling has started.
  //
  // [_scheduleBackgroundReconnect] runs a persistent exponential-backoff
  // retry loop until connect succeeds or the controller is disposed. The
  // ladder starts at 500 ms so the first recovery probe lands well inside
  // the iOS cold-start bind window, then backs off to 30 s for long idle
  // profiling sessions.
  Timer? _backgroundReconnectTimer;
  int _backgroundReconnectAttempt = 0;
  bool _backgroundReconnectActive = false;

  /// In-flight [reconnect] future. A second concurrent call (e.g. the user
  /// double-tapping a "reconnect" button) joins it instead of starting a
  /// parallel attempt and returning a stale `false`.
  Future<bool>? _reconnectInFlight;
  static const List<Duration> _backgroundReconnectDelays = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  // Analyzer
  final RenderPipelineAnalyzer _analyzer = RenderPipelineAnalyzer();
  final FrameEventCorrelator _correlator = FrameEventCorrelator();
  final CpuSampleAggregator _cpuAggregator = const CpuSampleAggregator();

  // Unified detector registry — built in _initializeDetectors()
  late final List<BaseDetector> _detectors;
  bool _detectorsReady = false;

  // Typed access for detectors with methods beyond BaseDetector
  late final FrameTimingDetector _frameTiming;
  late final MemoryPressureDetector _memoryPressure;
  late final NetworkMonitorDetector _networkMonitor;

  // HTTP override proxy (not a detector)
  SleuthHttpOverrides? _httpOverrides;

  // Ranking & correlation
  final DetectorCorrelator _detectorCorrelator = const DetectorCorrelator();
  final IssueRanker _ranker = const IssueRanker();
  final Map<String, RecurrenceTrend> _recurrenceTrends = {};
  int _scanCycleIndex = 0;

  // Fix verification baseline (Pillar 3a)
  FixBaseline? _fixBaseline;
  int _postReassembleGraceCycles = 0;
  static const _reassembleGraceCycles = 3;
  static const _fixCooldownCycles = 5;

  // Cached verdict phase for ranking context (v9.2)
  PipelinePhase? _lastVerdictPhase;
  int? _lastVerdictFrameNumber;

  // Export enrichment buffers (rolling, fed from _onTimelineData)
  final Queue<PhaseEvent> _phaseEventBuffer = Queue();
  static const _phaseEventBufferCapacity = 100;
  final Queue<GcEventSummary> _gcEventBuffer = Queue();
  static const _gcEventBufferCapacity = 50;
  final Queue<PlatformChannelSummary> _platformChannelBuffer = Queue();
  static const _platformChannelBufferCapacity = 50;

  // Interaction context
  InteractionContext _interactionState = InteractionContext.idle;
  Timer? _scrollIdleTimer;
  Timer? _typingIdleTimer;
  bool _keyboardVisible = false;

  // Allocation enrichment
  DateTime? _lastAllocationEnrichmentTime;

  // -- Fix A: frameStatsNotifier throttle --
  //
  // FrameTimingDetector fires _onFrameStats on every presented frame (~60 Hz),
  // which used to push a fresh FrameStatsBuffer into frameStatsNotifier at the
  // same rate. That notifier is driven by UI (TriggerButton, FloatingIssuesCard)
  // as a text-only FPS readout — any rate above ~5 Hz is unreadable anyway, and
  // the 60 Hz emission created a self-feedback loop where Sleuth's own overlay
  // rebuilds dominated the VM build-event count and fired rebuild_activity on
  // an otherwise idle screen. The detector still samples every vsync for jank
  // analysis; only the notifier emission is throttled.
  //
  // Emits at: first sample, then ≥200ms since last emission, then once more
  // on jank frames so the export snapshot's notifier-backed fallback is fresh.
  DateTime? _lastFrameStatsNotifierEmit;
  static const _frameStatsNotifierThrottle = Duration(milliseconds: 200);

  /// Test-only clock override. Dart's [DateTime.now] is not affected by
  /// [fakeAsync], so throttle tests inject a fake clock here.
  @visibleForTesting
  static DateTime Function()? clockOverrideForTest;

  /// SDK/framework classes excluded from allocation attribution unless
  /// they dominate > 50% of total allocations.
  static const _frameworkClassPrefixes = [
    '_List',
    '_GrowableList',
    '_InternalLinkedHashMap',
    '_LinkedHashMap',
    '_String',
    '_Uint8List',
    '_Int32List',
    '_Double',
    '_Smi',
    '_Mint',
    '_OneByteString',
    '_TwoByteString',
    '_ExternalOneByteString',
    '_CompactLinkedHashSet',
    '_HashSet',
    '_Type',
    '_Closure',
  ];

  // Debug instrumentation
  DebugInstrumentationCoordinator? _debugCoordinator;
  bool? _prevProfileBuildsEnabled;
  bool? _prevProfilePaintsEnabled;
  bool? _prevProfileLayoutsEnabled;
  bool? _prevEnhanceBuildArgs;
  bool? _prevEnhanceLayoutArgs;
  bool? _prevEnhancePaintArgs;

  // State
  bool _initialized = false;
  bool _disposed = false;
  Timer? _treeScanTimer;

  /// Incremented on each [startTreeScanning] call to invalidate stale
  /// post-frame callbacks from a previous timer chain. Prevents parallel
  /// timer chains when startTreeScanning is called rapidly (e.g. widget
  /// remount during hot reload).
  int _scanTimerGeneration = 0;

  /// Consecutive scan cycles with zero issues. Used by adaptive scan to
  /// determine when to back off the tree walk interval.
  int _consecutiveCleanScans = 0;

  /// Adaptive back-off threshold: require this many consecutive clean cycles
  /// before slowing down, to avoid thrashing on flicker.
  static const _cleanScanThreshold = 3;

  /// Maximum back-off interval in ms regardless of [SleuthConfig.treeScanInterval].
  static const _maxBackOffMs = 2000;

  // -- M5: Issue allocation reduction caches --

  /// Generation counter incremented when detectors produce fresh issues
  /// (after structural scans or timeline evaluateNow). Allows
  /// [_getAllIssues] to return a cached list when nothing has changed.
  int _issueGeneration = 0;
  int _cachedIssueGeneration = -1;
  List<PerformanceIssue>? _cachedAllIssues;

  /// Notifies listeners when issues change.
  final ValueNotifier<List<PerformanceIssue>> issuesNotifier = ValueNotifier(
    [],
  );

  /// Notifies listeners when frame stats update.
  final ValueNotifier<FrameStatsBuffer> frameStatsNotifier = ValueNotifier(
    FrameStatsBuffer(),
  );

  /// Notifies listeners when a new verdict is available.
  final ValueNotifier<FrameVerdict?> verdictNotifier = ValueNotifier(null);

  /// Whether VM service is connected (full mode).
  final ValueNotifier<bool> vmConnectedNotifier = ValueNotifier(false);

  /// Widget highlights for the visual overlay.
  /// Record bundles a generation counter with the list — the counter increments
  /// on every content change so that the painter's `shouldRepaint` can compare
  /// a single int instead of relying on list identity.
  int _highlightGeneration = 0;
  final ValueNotifier<({int generation, List<WidgetHighlight> items})>
      highlightsNotifier = ValueNotifier((generation: 0, items: []));

  /// Whether the highlight overlay is active.
  final ValueNotifier<bool> highlightEnabledNotifier = ValueNotifier(false);

  /// The currently selected/focused highlight (from tapping an issue).
  final ValueNotifier<WidgetHighlight?> selectedHighlightNotifier =
      ValueNotifier(null);

  /// Runtime theme override. Takes precedence over [config.theme] and
  /// auto-detection when non-null.
  final ValueNotifier<SleuthThemeData?> _themeOverride =
      ValueNotifier<SleuthThemeData?>(null);

  /// Listenable for the current theme override. Null means use config or
  /// auto-detect.
  ValueListenable<SleuthThemeData?> get themeOverride => _themeOverride;

  /// Update the overlay theme at runtime. Pass `null` to revert to
  /// config theme or auto-detection.
  void updateTheme(SleuthThemeData? theme) {
    _themeOverride.value = theme;
  }

  // -- Route session tracking --

  /// Per-route session history, bounded by [SleuthConfig.routeHistoryCapacity]
  /// (default 50; FIFO eviction).
  final Queue<RouteSession> _routeHistory = Queue<RouteSession>();

  /// The currently active route session. Null before the first scan.
  RouteSession? _activeRouteSession;

  /// Counter for synthetic names assigned to unnamed routes.
  // ignore: prefer_final_fields
  int _unnamedRouteCounter = 0;

  /// Maps a scaffold hash (null for scaffold-free) to the stable unnamed-route
  /// ordinal assigned the first time the controller saw that hash under a
  /// null `routeName`. Without this, tab-switching between two unnamed tabs
  /// churned the counter (`<unnamed-1>`, `<unnamed-2>`, `<unnamed-3>`, ... on
  /// every back-and-forth). With it, each tab keeps its original unnamed id, and
  /// returning to a previously-seen tab uses its cached label.
  ///
  /// Cleared on hot reload by [_reassembleInternal] — old hashes are stale
  /// once Elements rotate.
  final Map<int?, int> _unnamedIdByHash = <int?, int>{};

  /// Debug-only hot-reload generation stamped on every [RouteSession] created
  /// while this value is non-zero. Incremented by [_reassembleInternal] each
  /// time Flutter's reassemble fires. `0` in profile/release mode and before
  /// the first reload.
  int _hotReloadGeneration = 0;

  /// Notifies listeners when route history changes (new session created or
  /// old session evicted). Value is an unmodifiable snapshot.
  final ValueNotifier<List<RouteSession>> routeHistoryNotifier =
      ValueNotifier([]);

  /// Number of issues hidden by the suppression list after the last aggregation.
  final ValueNotifier<int> suppressedCountNotifier = ValueNotifier(0);

  /// Issue waiting to be highlighted after the next tree scan populates
  /// the highlights list. Set by the UI when highlights aren't ready yet.
  PerformanceIssue? pendingIssueSelection;

  /// Clear the selected highlight.
  void clearSelectedHighlight() {
    selectedHighlightNotifier.value = null;
    pendingIssueSelection = null;
  }

  /// Select the best matching highlight for a given issue.
  /// Returns true if a match was found.
  bool selectHighlightForIssue(PerformanceIssue issue) {
    // Eagerly collect highlights if empty — detectors already computed them
    // during their last scanTree(), but _collectHighlights() only runs when
    // highlightEnabled was true at scan time. On the first checkbox tap,
    // highlighting was just enabled so highlights haven't been gathered yet.
    if (highlightsNotifier.value.items.isEmpty) {
      _collectHighlights();
    }
    final highlights = highlightsNotifier.value.items;
    if (highlights.isEmpty) return false;

    // Try exact match on widgetName first
    if (issue.widgetName != null) {
      for (final h in highlights) {
        if (h.widgetName == issue.widgetName) {
          selectedHighlightNotifier.value = h;
          highlightEnabledNotifier.value = true;
          return true;
        }
      }
    }

    // Map issue category to likely detector names
    final detectorNames = detectorNamesForCategory(issue.category);
    for (final name in detectorNames) {
      for (final h in highlights) {
        if (h.detectorName == name) {
          selectedHighlightNotifier.value = h;
          highlightEnabledNotifier.value = true;
          return true;
        }
      }
    }

    return false;
  }

  static List<String> detectorNamesForCategory(IssueCategory category) {
    return switch (category) {
      IssueCategory.layout => ['Layout', 'Opacity'],
      IssueCategory.build => [
          'Non-lazy',
          'GlobalKey',
          'setState',
          'AnimatedBuilder',
          'Rebuild',
        ],
      IssueCategory.paint => ['Painter', 'Repaint'],
      IssueCategory.raster => ['GPU'],
      IssueCategory.memory => ['Image', 'KeepAlive'],
      IssueCategory.channel => [],
      IssueCategory.font => [],
      IssueCategory.network => [],
      IssueCategory.startup => ['Startup'],
    };
  }

  /// Whether running in debug mode.
  bool get isDebugMode => kDebugMode;

  /// Whether debug callbacks are currently installed.
  bool get isDebugCallbacksActive {
    bool result = false;
    assert(() {
      result = _debugCoordinator?.isInstalled ?? false;
      return true;
    }());
    return result;
  }

  /// Whether any heavy debug profiling flags are actually active.
  ///
  /// Returns `true` only when at least one Flutter debug flag was saved and
  /// overridden. If `enableDeepDebugInstrumentation` is `true` but all
  /// advanced sub-flags are `false`, this returns `false`.
  bool get isDeepInstrumentationActive {
    bool result = false;
    assert(() {
      result = _prevProfileBuildsEnabled != null ||
          _prevProfileLayoutsEnabled != null ||
          _prevProfilePaintsEnabled != null ||
          _prevEnhanceBuildArgs != null ||
          _prevEnhanceLayoutArgs != null ||
          _prevEnhancePaintArgs != null;
      return true;
    }());
    return result;
  }

  /// Whether VM service is connected.
  bool get isVmConnected =>
      _vmConnectedOverride ?? _vmClient?.isConnected ?? false;

  /// Test-only override for [isVmConnected]. When non-null, takes precedence
  /// over [_vmClient?.isConnected].
  bool? _vmConnectedOverride;

  @visibleForTesting
  set vmConnectedForTest(bool value) => _vmConnectedOverride = value;

  /// Simulate a VM connection state change in tests. Sets the override,
  /// updates [vmConnectedNotifier], and propagates to hybrid detectors
  /// via [_syncVmState] — mirroring the production [_onVmConnectionChanged].
  @visibleForTesting
  void simulateVmStateChangeForTest(bool connected) {
    _vmConnectedOverride = connected;
    vmConnectedNotifier.value = connected;
    _syncVmState(connected);
  }

  /// Merges user-configured [SleuthConfig.networkExcludePatterns] with
  /// adapter-provided [AiChatAdapter.networkExcludePatterns] without mutating
  /// either source list.
  List<String>? _mergedExcludePatterns() {
    final userPatterns = config.networkExcludePatterns;
    final adapterPatterns = config.aiChat?.networkExcludePatterns;
    if (userPatterns == null && adapterPatterns == null) return null;
    if (userPatterns == null) return adapterPatterns;
    if (adapterPatterns == null) return userPatterns;
    return {...userPatterns, ...adapterPatterns}.toList();
  }

  /// Initialize all detectors and connect to VM service.
  Future<void> initialize() async {
    if (_initialized || kReleaseMode) return;

    _initializeDetectors();

    // Install HTTP monitoring proxy before any network requests start
    if (config.enableNetworkMonitoring &&
        config.enabledDetectors.contains(DetectorType.networkMonitor)) {
      _httpOverrides = SleuthHttpOverrides(
        onRecord: _networkMonitor.processRecord,
        onRequestStarted: _networkMonitor.startRequest,
        onRequestEnded: _networkMonitor.endRequest,
        excludePatterns: _mergedExcludePatterns(),
      );
      SleuthHttpOverrides.install(_httpOverrides!);
    }

    _installDebugInstrumentation();

    // Start frame timing immediately so the FPS counter captures initial
    // frames while the (potentially slow) VM connection is in progress.
    _frameTiming.start();

    // Connect to VM service
    final client = VmServiceClient(
      onTimelineData: _onTimelineData,
      onGcEvent: _onGcEvent,
      onHeapSample: _onHeapSample,
      onConnectionChanged: _onVmConnectionChanged,
      onStartupTimelineEvents: _onStartupTimelineEvents,
    );
    _vmClient = client;

    bool connected = false;
    try {
      connected = await client.connect();
    } catch (_) {
      // Connect failure is expected on real devices — the background
      // reconnect ladder below handles recovery.
    }
    if (_disposed) return;
    vmConnectedNotifier.value = connected;
    _syncVmState(connected);

    _initialized = true;

    // BASIC-mode recovery: if the cold-start connect failed, keep trying in
    // the background with exponential backoff. Without this, a first-launch
    // bind race leaves Sleuth permanently in BASIC mode for the session.
    if (!connected && !_disposed) {
      _scheduleBackgroundReconnect();
    }
  }

  /// Schedule the next background reconnect attempt with exponential backoff.
  ///
  /// Idempotent: calling this while a background attempt is already pending
  /// is a no-op. The loop self-cancels on success, on dispose, or when a
  /// manual [reconnect] call supersedes it.
  void _scheduleBackgroundReconnect() {
    if (_disposed || _backgroundReconnectActive) return;
    final client = _vmClient;
    if (client == null || client.isDisposed) return;
    if (client.isConnected) {
      _backgroundReconnectAttempt = 0;
      return;
    }

    // Cap: stop retrying after exhausting the delay ladder. On platforms
    // where the VM web server is structurally unreachable (e.g. real iOS
    // devices launched via IDE — the USB bridge port is host-only), there
    // is no point retrying forever.
    if (_backgroundReconnectAttempt >= _backgroundReconnectDelays.length) {
      return;
    }

    _backgroundReconnectActive = true;
    final delay = _backgroundReconnectDelays[_backgroundReconnectAttempt];
    _backgroundReconnectTimer?.cancel();
    _backgroundReconnectTimer = Timer(delay, () async {
      _backgroundReconnectTimer = null;
      // Do NOT clear _backgroundReconnectActive yet — keeping it true during
      // the in-flight connect prevents a concurrent caller of
      // [_scheduleBackgroundReconnect] (e.g., [_onVmConnectionChanged] firing
      // from a different path) from stacking a second timer on top of ours.
      // The flag is cleared in the finally block after the connect resolves.
      var rescheduleNeeded = false;
      try {
        if (_disposed) return;
        final c = _vmClient;
        if (c == null || c.isDisposed || c.isConnected) {
          _backgroundReconnectAttempt = 0;
          return;
        }
        // maxRetries: 1 — each tick gets two inner attempts separated by
        // the client's 500 ms retry delay. Covers the cold-start bind
        // window more densely than a single-shot probe without compounding
        // too much delay into a single tick (~6.5 s worst case per tick).
        final ok = await c.connect(maxRetries: 1);
        if (_disposed) return;
        if (ok) {
          _backgroundReconnectAttempt = 0;
          vmConnectedNotifier.value = true;
          _syncVmState(true);
          return;
        }
        _backgroundReconnectAttempt++;
        rescheduleNeeded = true;
      } finally {
        _backgroundReconnectActive = false;
      }
      if (rescheduleNeeded) {
        _scheduleBackgroundReconnect();
      }
    });
  }

  /// Manually trigger a VM reconnect attempt. Safe to call before
  /// [initialize], after [dispose], or while a background reconnect is
  /// pending. Returns `true` on success, `false` otherwise.
  ///
  /// Intended as the "Tap to reconnect" hook for overlay UI when Sleuth
  /// is stuck in BASIC mode. Cancels any in-flight background loop before
  /// delegating so two attempts don't race each other.
  ///
  /// **Concurrency**: a second call while the first is still running joins
  /// the in-flight future — a user double-tapping the UI gets one result,
  /// not two parallel attempts.
  Future<bool> reconnect() {
    if (_disposed || kReleaseMode) return Future.value(false);
    final existing = _reconnectInFlight;
    if (existing != null) return existing;

    final future = _reconnectImpl();
    _reconnectInFlight = future;
    future.whenComplete(() {
      if (identical(_reconnectInFlight, future)) _reconnectInFlight = null;
    });
    return future;
  }

  Future<bool> _reconnectImpl() async {
    final client = _vmClient;
    if (client == null || client.isDisposed) return false;

    // Stop the background loop; a manual attempt supersedes the scheduled one.
    _backgroundReconnectTimer?.cancel();
    _backgroundReconnectTimer = null;
    _backgroundReconnectActive = false;

    final ok = await client.reconnect();
    if (_disposed) return false;
    if (ok) {
      _backgroundReconnectAttempt = 0;
      vmConnectedNotifier.value = true;
      _syncVmState(true);
      return true;
    }
    // Resume background loop from the current attempt counter so the user
    // doesn't have to keep tapping.
    _scheduleBackgroundReconnect();
    return false;
  }

  void _initializeDetectors() {
    final enabled = config.enabledDetectors;

    // Typed detectors are always constructed — they have special access
    // patterns (frame buffer, heap samples, HTTP records) beyond the
    // BaseDetector interface. Their isEnabled flag gates detection logic.
    _frameTiming = FrameTimingDetector(
      fpsTarget: config.fpsTarget,
      warmupFrameCount: config.frameTimingWarmupFrameCount,
      onFrameStats: _onFrameStats,
    )..isEnabled = enabled.contains(DetectorType.frameTiming);

    _memoryPressure = MemoryPressureDetector(
      warmupDurationMs: config.memoryWarmupDurationMs,
      growthThresholdBytesPerSec: config.thresholds.memoryGrowthBytesPerSec,
      capacityThresholdPercent: config.thresholds.memoryCapacityPercent,
    )..isEnabled = enabled.contains(DetectorType.memoryPressure);

    _networkMonitor = NetworkMonitorDetector(
      slowThresholdMs: config.slowRequestThresholdMs,
      frequencyLimit: config.requestFrequencyLimit,
      largeResponseBytes: config.largeResponseThresholdBytes,
    )..isEnabled = enabled.contains(DetectorType.networkMonitor);

    // Factory map for non-typed detectors. Only detectors present in
    // [enabledDetectors] are constructed — saves buffer allocations and
    // reduces the unified walk iteration count (M6: lazy initialization).
    final factories = <DetectorType, BaseDetector Function()>{
      DetectorType.shaderJank: () => ShaderJankDetector(
            thresholdMs: config.thresholds.shaderJankMs,
          ),
      DetectorType.heavyCompute: () => HeavyComputeDetector(
            lagThresholdMs: config.thresholds.heavyComputeGapMs,
          ),
      DetectorType.platformChannel: () => PlatformChannelDetector(
            callsPerSecThreshold: config.platformChannelLimit,
            durationThresholdUs:
                config.platformChannelDurationThresholdMs * 1000,
          ),
      DetectorType.repaint: RepaintDetector.new,
      DetectorType.rebuild: () =>
          RebuildDetector(rebuildsPerSecThreshold: config.rebuildThreshold),
      DetectorType.setStateScope: () => SetStateScopeDetector(
            dirtyRatioThreshold:
                config.thresholds.setStateScopeOwnershipPercent,
          ),
      DetectorType.gpuPressure: () => GpuPressureDetector(
            rasterMultiplierThreshold: config.thresholds.gpuPressureRatio,
          ),
      DetectorType.shallowRebuildRisk: () => ShallowRebuildRiskDetector(
            depthThreshold: config.thresholds.shallowRebuildMaxDepth,
          ),
      DetectorType.layoutBottleneck: LayoutBottleneckDetector.new,
      DetectorType.listview: () =>
          ListviewDetector(childThreshold: config.maxListChildren),
      DetectorType.imageMemory: ImageMemoryDetector.new,
      DetectorType.globalKey: () =>
          GlobalKeyDetector(threshold: config.maxGlobalKeys),
      DetectorType.nestedScroll: () =>
          NestedScrollDetector(childThreshold: config.maxListChildren),
      DetectorType.customPainter: CustomPainterDetector.new,
      DetectorType.keepAlive: () =>
          KeepAliveDetector(threshold: config.thresholds.keepAliveMax),
      DetectorType.animatedBuilder: () => AnimatedBuilderDetector(
            minSubtreeSize: config.thresholds.animatedBuilderMinSubtreeSize,
          ),
      DetectorType.opacity: OpacityDetector.new,
      DetectorType.fontLoading: () => FontLoadingDetector(
            maxFamilies: config.thresholds.fontLoadingMaxFamilies,
          ),
      DetectorType.repaintBoundary: RepaintBoundaryDetector.new,
      DetectorType.startup: () => StartupDetector(
            ttffWarningMs: config.thresholds.startupTtffWarningMs,
            ttffCriticalMs: config.thresholds.startupTtffCriticalMs,
          ),
    };

    // Persist factory map for runtime enable/disable (enableDetector).
    _detectorFactories = factories;

    _detectors = [
      _frameTiming,
      // Only construct non-typed detectors that are enabled.
      for (final entry in factories.entries)
        if (enabled.contains(entry.key)) entry.value()..isEnabled = true,
      _memoryPressure,
      _networkMonitor,
      // Custom detectors.
      //
      // Default: enabled. A custom detector with a non-null [key] that
      // matches an entry in [SleuthConfig.disabledCustomDetectorKeys] is
      // constructed but starts disabled. Detectors with a null key are
      // always enabled — null is the "I don't participate in config-driven
      // gating" signal (see [BaseDetector.key] doc).
      for (final d in config.customDetectors)
        d
          ..isEnabled = d.key == null ||
              !config.disabledCustomDetectorKeys.contains(d.key),
    ];
    _detectorsReady = true;
  }

  /// Factory map for non-typed detectors, persisted for runtime enable.
  Map<DetectorType, BaseDetector Function()> _detectorFactories = {};

  /// True while `_scanTree` or `_onTimelineData` is iterating [_detectors].
  /// When set, [enableDetector]/[disableDetector] defer list mutations to
  /// [_pendingDetectorMutations] to avoid ConcurrentModificationError.
  bool _isIteratingDetectors = false;
  final List<void Function()> _pendingDetectorMutations = [];

  /// Apply any detector enable/disable calls that were deferred because
  /// they arrived during an active scan or timeline iteration.
  void _drainPendingDetectorMutations() {
    if (_pendingDetectorMutations.isEmpty) return;
    final pending = List.of(_pendingDetectorMutations);
    _pendingDetectorMutations.clear();
    for (final mutation in pending) {
      mutation();
    }
  }

  /// Constructs and adds a detector at runtime if not already present.
  ///
  /// No-op for the 3 typed detectors (frameTiming, memoryPressure,
  /// networkMonitor) — use their `isEnabled` flag instead.
  void enableDetector(DetectorType type) {
    if (!_detectorsReady) return;
    // Typed detectors: just flip the flag (safe during iteration).
    if (type == DetectorType.frameTiming) {
      _frameTiming.isEnabled = true;
      return;
    }
    if (type == DetectorType.memoryPressure) {
      _memoryPressure.isEnabled = true;
      return;
    }
    if (type == DetectorType.networkMonitor) {
      _networkMonitor.isEnabled = true;
      return;
    }
    // Defer list mutation if we're mid-iteration.
    if (_isIteratingDetectors) {
      _pendingDetectorMutations.add(() => enableDetector(type));
      return;
    }
    // Non-typed: construct if not already in the list.
    if (_detectors.any((d) => d.type == type)) {
      _detectors.firstWhere((d) => d.type == type).isEnabled = true;
      return;
    }
    final factory = _detectorFactories[type];
    if (factory != null) {
      _detectors.add(factory()..isEnabled = true);
    }
  }

  /// Removes a non-typed detector at runtime, freeing its internal buffers.
  ///
  /// For typed detectors, disables without removing (they're always needed
  /// for framework access patterns like frame buffer and heap samples).
  void disableDetector(DetectorType type) {
    if (!_detectorsReady) return;
    // Typed detectors: just flip the flag — don't remove (safe during iteration).
    if (type == DetectorType.frameTiming) {
      _frameTiming.isEnabled = false;
      return;
    }
    if (type == DetectorType.memoryPressure) {
      _memoryPressure.isEnabled = false;
      return;
    }
    if (type == DetectorType.networkMonitor) {
      _networkMonitor.isEnabled = false;
      return;
    }
    // Defer list mutation if we're mid-iteration.
    if (_isIteratingDetectors) {
      _pendingDetectorMutations.add(() => disableDetector(type));
      return;
    }
    _detectors.removeWhere((d) => d.type == type);
  }

  /// Initialize detectors without VM client or SchedulerBinding.
  @visibleForTesting
  void initializeDetectorsForTest() {
    _initializeDetectors();
    _installDebugInstrumentation();
  }

  /// Inject a (typically fake) [VmServiceClient] for tests that need to
  /// drive the background reconnect loop without going through the real
  /// [dart:developer.Service] path. Production code must never call this.
  @visibleForTesting
  void setVmClientForTest(VmServiceClient client) {
    _vmClient = client;
  }

  /// Simulate the post-[initialize] failure handoff that schedules the
  /// background reconnect loop. Used by tests that cannot run the real
  /// [initialize] path because it would touch [dart:developer.Service].
  @visibleForTesting
  void scheduleBackgroundReconnectForTest() {
    _initialized = true;
    _scheduleBackgroundReconnect();
  }

  /// Directly invoke the VM-connection-changed callback, bypassing the
  /// [simulateVmStateChangeForTest] helper's override shortcut. Used by
  /// mid-session-disconnect tests to verify that a `false` transition
  /// re-arms the background reconnect loop.
  ///
  /// **Coupling with fake clients**: in production, [VmServiceClient]
  /// flips its internal `_connected` to `false` BEFORE invoking
  /// [onConnectionChanged]. [_scheduleBackgroundReconnect]'s
  /// `client.isConnected` guard depends on that ordering — if the injected
  /// fake still reports `isConnected == true` when this hook fires, the
  /// bg schedule call short-circuits and the test is silently a no-op.
  /// Tests simulating a disconnect must flip the fake's state first
  /// (e.g. `fake.markDisconnected()`).
  @visibleForTesting
  void onVmConnectionChangedForTest(bool connected) {
    _onVmConnectionChanged(connected);
  }

  /// Inspect the background-reconnect attempt counter (for tests).
  @visibleForTesting
  int get backgroundReconnectAttemptForTest => _backgroundReconnectAttempt;

  /// Whether a background reconnect timer is currently scheduled.
  @visibleForTesting
  bool get backgroundReconnectScheduledForTest =>
      _backgroundReconnectTimer != null;

  /// Feed a synthetic frame into the controller's [FrameTimingDetector],
  /// triggering [_onFrameStats] and the fallback verdict path.
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  void addFrameForTest(FrameStats stats) => _frameTiming.addFrameForTest(stats);

  /// Mark the controller as initialized without running the full [initialize]
  /// path (which requires dart:developer). Needed by tests that exercise
  /// post-init code paths like the frameStatsNotifier throttle.
  @visibleForTesting
  void markInitializedForTest() => _initialized = true;

  /// Exposes recurrence counts for testing ranking integration.
  /// Only includes currently-present issues (last entry was present),
  /// matching the old `Map<String, int>` semantics.
  @visibleForTesting
  Map<String, int> get recurrenceCountsForTest => {
        for (final e in _recurrenceTrends.entries)
          if (e.value.entries.isNotEmpty && e.value.entries.last.present)
            e.key: e.value.presentCount,
      };

  /// Unmodifiable view of the current recurrence trend map, keyed by
  /// issue `stableId`. Intended for the floating card to render "Seen X/Y"
  /// badges. Trends update on every scan cycle; listeners should use
  /// [issuesNotifier] as the rebuild trigger.
  Map<String, RecurrenceTrend> get recurrenceTrends =>
      Map.unmodifiable(_recurrenceTrends);

  /// Current scan cycle index (for testing).
  @visibleForTesting
  int get scanCycleIndexForTest => _scanCycleIndex;

  /// Current adaptive scan interval in milliseconds (for testing).
  @visibleForTesting
  int get currentScanIntervalMsForTest => _currentScanIntervalMs;

  /// Consecutive clean-scan count (for testing).
  @visibleForTesting
  int get consecutiveCleanScansForTest => _consecutiveCleanScans;

  /// Number of live detectors in the list (for testing lazy init).
  @visibleForTesting
  int get detectorCountForTest => _detectors.length;

  /// Computed scan interval: backs off when the app is healthy.
  int get _currentScanIntervalMs {
    final baseMs = config.treeScanInterval.inMilliseconds;
    if (!config.adaptiveScanEnabled ||
        _consecutiveCleanScans < _cleanScanThreshold) {
      return baseMs;
    }
    return (baseMs * 2).clamp(0, _maxBackOffMs);
  }

  @visibleForTesting
  void runTreeScanForTest(BuildContext context) {
    _lastScanContext = context;
    _runStructuralScans(context);
    _collectHighlights();
    _aggregateIssues();
    if (issuesNotifier.value.isEmpty) {
      _consecutiveCleanScans++;
    } else {
      _consecutiveCleanScans = 0;
    }
    _updateRecurrence(issuesNotifier.value);
  }

  /// Feeds timeline data through the same path as production VM polling.
  /// Distributes data to all VM-only and hybrid detectors, then re-aggregates.
  @visibleForTesting
  void feedTimelineDataForTest(ParsedTimelineData data) =>
      _onTimelineData(data);

  @visibleForTesting
  List<PhaseEvent> get phaseEventBufferForTest =>
      List.unmodifiable(_phaseEventBuffer);

  @visibleForTesting
  List<GcEventSummary> get gcEventBufferForTest =>
      List.unmodifiable(_gcEventBuffer);

  @visibleForTesting
  List<PlatformChannelSummary> get platformChannelBufferForTest =>
      List.unmodifiable(_platformChannelBuffer);

  /// Simulates the timeline path: re-aggregates and ranks issues without
  /// updating recurrence. Mirrors what [_onTimelineData] does.
  @visibleForTesting
  void aggregateIssuesForTest() => _aggregateIssues();

  /// Exposes suppressed count for testing.
  @visibleForTesting
  int get suppressedCountForTest => suppressedCountNotifier.value;

  /// Exposes interaction state for testing.
  @visibleForTesting
  InteractionContext get interactionStateForTest => _interactionState;

  @visibleForTesting
  set interactionStateForTest(InteractionContext state) =>
      _interactionState = state;

  /// Calls the real [_scanTree] path (including [_findVisiblePageContext]
  /// null-check and navigation state handling). Unlike [runTreeScanForTest],
  /// this does NOT bypass the null-context early return.
  @visibleForTesting
  void scanTreeFullPathForTest(BuildContext context) {
    _initialized = true;
    _scanTree(context);
  }

  /// Exposes scaffold-free scan flag for testing.
  @visibleForTesting
  bool get isScaffoldFreeScanForTest => _isScaffoldFreeScan;

  /// Exposes the internal [NetworkMonitorDetector] so tests can feed synthetic
  /// [RequestRecord]s and assert buffer-clear behavior on tab switches / route
  /// transitions.
  @visibleForTesting
  NetworkMonitorDetector get networkMonitorForTest => _networkMonitor;

  /// Exposes [_lastScanContext] so tests can verify a scan went down the
  /// happy path (non-null) vs. the navigating sentinel path (null). Without
  /// this, a test that asserts "buffer cleared after tab switch" cannot
  /// distinguish the Scaffold-hash clear from a sentinel-path clear caused by
  /// a regression in the visibility filter.
  @visibleForTesting
  BuildContext? get lastScanContextForTest => _lastScanContext;

  /// Exposes navigator-found flag for testing.
  @visibleForTesting
  bool get navigatorFoundForTest => _navigatorFound;

  /// Exposes capture buffer for testing.
  @visibleForTesting
  JankCaptureBuffer get captureBufferForTest => _captureBuffer;

  /// Feeds a heap sample through the same path as the VM service callback.
  @visibleForTesting
  void feedHeapSampleForTest(HeapSample sample) => _onHeapSample(sample);

  /// Exposes the active route session for testing.
  @visibleForTesting
  RouteSession? get activeRouteSessionForTest => _activeRouteSession;

  /// Read-only snapshot of the route history deque for testing.
  @visibleForTesting
  List<RouteSession> get routeHistoryForTest =>
      List.unmodifiable(_routeHistory);

  /// Build a session snapshot for programmatic use.
  ///
  /// Includes schema version 2 fields: ranking scores on each issue,
  /// FPS percentiles, phase/GC/platform-channel event buffers, and
  /// a recent-frames time series.
  SessionSnapshot exportSnapshot() {
    final buffer =
        _initialized ? _frameTiming.frameBuffer : frameStatsNotifier.value;
    final frames = buffer.frames;
    final worstUs = frames.isEmpty
        ? 0
        : frames
            .map((f) => f.effectiveTotalDuration.inMicroseconds)
            .reduce((a, b) => a > b ? a : b);

    // Compute FPS percentiles at export time (lazy, not cached).
    // Clamp to fpsTarget so ProMotion 120Hz idle screens report ≤ target.
    final target = config.fpsTarget.toDouble();
    final rawPercentiles = buffer.length >= 2 ? buffer.fpsPercentiles() : null;
    final percentiles = rawPercentiles == null
        ? null
        : FpsPercentiles(
            p50: rawPercentiles.p50.clamp(0.0, target),
            p95: rawPercentiles.p95.clamp(0.0, target),
            p99: rawPercentiles.p99.clamp(0.0, target),
          );

    // Attach ranking scores to issues (export-only, not on the hot path).
    // Before init, _frameTiming is not available — use default context.
    final rankingContext =
        _initialized ? _buildRankingContext() : const IssueRankingContext();
    final rankedWithScores = _ranker.rankWithScores(
      issuesNotifier.value,
      rankingContext,
    );

    // Compute session summary (v3)
    final heapSamples = _initialized && _memoryPressure.heapSamples.isNotEmpty
        ? _memoryPressure.heapSamples
        : null;
    final summary = _buildSessionSummary(
      rankedWithScores,
      frames,
      heapSamples,
    );

    // Serialize route history (v4).
    final routeSessions = _routeHistory.isNotEmpty
        ? _routeHistory.map((s) => s.toJson()).toList()
        : null;

    return SessionSnapshot(
      schemaVersion: 4,
      exportedAt: DateTime.now(),
      capturedFrames: _captureBuffer.entries,
      currentIssues: List.unmodifiable(rankedWithScores),
      frameStatsSummary: FrameStatsSummary(
        totalFrames: buffer.length,
        jankFrames: buffer.jankCount,
        averageFps: buffer.averageFps.clamp(0.0, target),
        worstFrameTimeUs: worstUs,
        fpsPercentiles: percentiles,
      ),
      packageVersion: '0.14.1',
      isVmConnected: isVmConnected,
      isDebugMode: isDebugMode,
      recentRequests: _initialized &&
              _networkMonitor.isEnabled &&
              _networkMonitor.records.isNotEmpty
          ? _networkMonitor.records
          : null,
      heapSamples: heapSamples,
      suppressedCount: suppressedCountNotifier.value,
      phaseEvents: _phaseEventBuffer.isNotEmpty
          ? List.unmodifiable(_phaseEventBuffer)
          : null,
      gcEvents:
          _gcEventBuffer.isNotEmpty ? List.unmodifiable(_gcEventBuffer) : null,
      platformChannelEvents: _platformChannelBuffer.isNotEmpty
          ? List.unmodifiable(_platformChannelBuffer)
          : null,
      recentFrames: frames.isNotEmpty ? List.unmodifiable(frames) : null,
      recurrenceTrends: _recurrenceTrends.isNotEmpty
          ? {
              for (final e in _recurrenceTrends.entries)
                e.key: e.value.toJson(),
            }
          : null,
      widgetHeatMap: rankedWithScores.isNotEmpty
          ? buildWidgetHeatMap(rankedWithScores)
          : null,
      sessionSummary: summary.isNotEmpty ? summary : null,
      startupMetrics: Sleuth.startupMetrics,
      routeSessions: routeSessions,
    );
  }

  /// Export session snapshot as a formatted JSON string.
  String exportSnapshotJson() => exportSnapshot().toJsonString();

  /// Export a human-readable markdown summary suitable for pasting into
  /// Slack, a PR description, or a bug report.
  String exportSummary({required int topN}) {
    final snapshot = exportSnapshot();
    return SessionMarkdownExporter.render(snapshot, topN: topN.clamp(1, 20));
  }

  /// Builds the v3 session summary with pre-computed aggregations.
  Map<String, dynamic> _buildSessionSummary(
    List<PerformanceIssue> ranked,
    List<FrameStats> frames,
    List<HeapSample>? heapSamples,
  ) {
    final summary = <String, dynamic>{};

    // Top 5 issues by ranking score
    if (ranked.isNotEmpty) {
      final top = ranked.take(5).map((i) => {
            'stableId': i.stableId,
            'title': i.title,
            'severity': i.severity.name,
            'confidence': i.confidence.name,
            if (i.confidenceReason != null)
              'confidenceReason': i.confidenceReason,
            if (i.rankingScore != null) 'rankingScore': i.rankingScore,
            if (i.widgetName != null) 'widgetName': i.widgetName,
          });
      summary['topIssues'] = top.toList();
    }

    // Causal edges
    if (ranked.length >= 2) {
      final edges = CausalGraphRule.activeEdges(ranked);
      if (edges.isNotEmpty) {
        summary['causalEdges'] = edges;
      }
    }

    // Frame timing histogram
    if (frames.isNotEmpty) {
      final histogram = <String, int>{
        '<16ms': 0,
        '16-33ms': 0,
        '33-50ms': 0,
        '50-100ms': 0,
        '>100ms': 0,
      };
      for (final f in frames) {
        final ms = f.effectiveTotalDuration.inMilliseconds;
        if (ms < 16) {
          histogram['<16ms'] = histogram['<16ms']! + 1;
        } else if (ms < 33) {
          histogram['16-33ms'] = histogram['16-33ms']! + 1;
        } else if (ms < 50) {
          histogram['33-50ms'] = histogram['33-50ms']! + 1;
        } else if (ms < 100) {
          histogram['50-100ms'] = histogram['50-100ms']! + 1;
        } else {
          histogram['>100ms'] = histogram['>100ms']! + 1;
        }
      }
      summary['frameHistogram'] = histogram;
    }

    // Detector hit rates — count issues by stableId prefix
    if (ranked.isNotEmpty) {
      final hitRates = <String, int>{};
      for (final issue in ranked) {
        final id = issue.stableId ?? issue.title;
        final detector = _detectorNameFromStableId(id);
        hitRates[detector] = (hitRates[detector] ?? 0) + 1;
      }
      summary['detectorHitRates'] = hitRates;
    }

    // Memory trend summary
    if (heapSamples != null && heapSamples.length >= 2) {
      final first = heapSamples.first;
      final last = heapSamples.last;
      final peak =
          heapSamples.map((s) => s.heapUsage).reduce((a, b) => a > b ? a : b);
      final elapsedSecs = last.timestamp.difference(first.timestamp).inSeconds;
      final growthRate = elapsedSecs > 0
          ? (last.heapUsage - first.heapUsage) / elapsedSecs
          : 0.0;
      summary['memoryTrendSummary'] = {
        'startBytes': first.heapUsage,
        'endBytes': last.heapUsage,
        'peakBytes': peak,
        'growthRatePerSec': double.parse(growthRate.toStringAsFixed(1)),
        'sampleCount': heapSamples.length,
      };
    }

    return summary;
  }

  /// Maps a stableId to its detector name for hit rate aggregation.
  static String _detectorNameFromStableId(String stableId) {
    // StableId patterns → detector mapping
    const prefixMap = <String, String>{
      'sustained_jank': 'frameTiming',
      'jank_detected': 'frameTiming',
      'raster_cache': 'frameTiming',
      'shader_jank': 'shaderJank',
      'shader_compilation': 'shaderJank',
      'heavy_compute': 'heavyCompute',
      'platform_channel': 'platformChannel',
      'gc_pressure': 'memoryPressure',
      'heap_growing': 'memoryPressure',
      'heap_near_capacity': 'memoryPressure',
      'native_memory': 'memoryPressure',
      'excessive_repaint': 'repaint',
      'repaint_debug_': 'repaint',
      'rebuild_activity': 'rebuild',
      'rebuild_debug_': 'rebuild',
      'stateful_density': 'rebuild',
      'setstate_scope': 'setStateScope',
      'raster_dominance': 'gpuPressure',
      'expensive_gpu': 'gpuPressure',
      'shallow_rebuild': 'shallowRebuildRisk',
      'layout_bottleneck': 'layoutBottleneck',
      'wrap_layout': 'layoutBottleneck',
      'non_lazy_list': 'listview',
      'non_lazy_gridview': 'listview',
      'non_lazy_listview': 'listview',
      'sliver_': 'listview',
      'uncached_images': 'imageMemory',
      'excessive_global': 'globalKey',
      'global_key_recreation': 'globalKey',
      'nested_scroll': 'nestedScroll',
      'always_repaint_painter': 'customPainter',
      'frequent_repaint_painter': 'customPainter',
      'excessive_keep_alive': 'keepAlive',
      'animated_builder': 'animatedBuilder',
      'opacity_zero': 'opacity',
      'runtime_font': 'fontLoading',
      'multiple_custom_fonts': 'fontLoading',
      'slow_request': 'networkMonitor',
      'large_response': 'networkMonitor',
      'request_frequency': 'networkMonitor',
      'http_error_spike': 'networkMonitor',
      'high_frequency_same_path': 'networkMonitor',
      'missing_repaint_boundary': 'repaintBoundary',
      'excessive_repaint_boundary': 'repaintBoundary',
      'slow_startup': 'startup',
      'startup_phase': 'startup',
    };

    for (final entry in prefixMap.entries) {
      if (stableId.startsWith(entry.key)) return entry.value;
    }
    return 'custom';
  }

  /// Capture a baseline of current issues for fix verification.
  ///
  /// After making a code change and hot-reloading, call [compareToBaseline]
  /// to see which issues were resolved, improved, or worsened.
  void captureBaseline() {
    _fixBaseline = captureFixBaseline(issuesNotifier.value);
  }

  /// Compare current issues against the captured baseline.
  ///
  /// Returns null if no baseline has been captured.
  /// Uses a 5-cycle cooldown before declaring an issue "resolved"
  /// to avoid false positives from intermittent issues.
  FixVerificationResult? compareToBaseline() {
    final baseline = _fixBaseline;
    if (baseline == null) return null;
    return baseline.compare(
      issuesNotifier.value,
      cooldownCycles: _fixCooldownCycles,
    );
  }

  /// Whether a fix baseline has been captured.
  bool get hasBaseline => _fixBaseline != null;

  /// Clear the fix verification baseline.
  void clearBaseline() => _fixBaseline = null;

  /// Notify the controller that a hot reload (reassemble) occurred.
  /// Activates a grace period where fix verification absence tracking
  /// is paused, preventing false "resolved" reports from tree-reset artifacts.
  void notifyReassemble() {
    if (_fixBaseline != null) {
      _postReassembleGraceCycles = _reassembleGraceCycles;
      _fixBaseline!.consecutiveAbsentCycles.clear();
    }
    _reassembleInternal();
  }

  /// The overlay element — set by the overlay widget.
  BuildContext? _overlayContext;

  /// The last successfully resolved visible-page context from [_findVisiblePageContext].
  /// Used by [_currentRouteName] to stamp issues with the scanned page's route,
  /// not the overlay root. Cleared during route transitions to avoid stale stamps.
  BuildContext? _lastScanContext;

  /// True when the scan root is an overlay entry (scaffold-free Navigator path).
  /// Exempts [ShallowRebuildRiskDetector] and [SetStateScopeDetector] from the
  /// walk — their depth/ratio semantics break with overlay-entry scan roots.
  bool _isScaffoldFreeScan = false;

  /// True if [_findActiveRouteScanRoot] found a Navigator in the tree.
  /// Distinguishes "no Navigator" (static app → app child fallback) from
  /// "Navigator found but unsafe to scan" (→ navigating sentinel).
  bool _navigatorFound = false;

  /// Route name resolved from scaffold-free path via _ModalScopeStatus.
  /// Used by [_currentRouteName] when [_lastScanContext] is an overlay entry
  /// (where ModalRoute.of returns null since context is above the route).
  String? _scaffoldFreeRouteName;

  /// Identity hash of the topmost route-owned overlay entry from this scan.
  int _currentActiveEntryHash = 0;

  /// Identity hash from the previous scan — for route-stability detection.
  /// NEVER reset by the navigating sentinel — persists across sentinel cycles.
  int _lastActiveEntryHash = 0;

  /// Identity hash of the innermost visible Scaffold Element resolved on the
  /// most recent [_findVisiblePageContext] call. `null` when the path resolved
  /// without a Scaffold (scaffold-free scan) or when context was null
  /// (transition sentinel) or before the first scan.
  ///
  /// Used to detect tab switches in `IndexedStack`-based bottom nav (including
  /// `StatefulShellRoute.indexedStack`): every tab shares one Navigator route,
  /// so `_currentRouteName()` is identical across tabs. Each tab does own a
  /// distinct Scaffold Element though, so a non-null hash change between two
  /// successful scans signals that the user-visible page swapped without a
  /// route push. [_scanTree] uses this to flush the network-monitor buffer so
  /// the previous tab's HTTP records don't bleed into the new tab's frequency
  /// threshold.
  ///
  /// Also used as the `scaffoldHashKey` half of [RouteSession]'s compound key
  /// so tabs under a shared `ModalRoute` get per-tab RouteSessions.
  ///
  /// `int?` rather than `int`: `identityHashCode` nominally never returns 0,
  /// but relying on 0 as a sentinel overloaded three distinct states (unset,
  /// scaffold-free, post-transition reset) and made it impossible to
  /// distinguish them in the session-keying predicate.
  int? _currentVisibleScaffoldHash;

  /// Previous scan's value of [_currentVisibleScaffoldHash] — rolled forward
  /// at the end of each successful scan. Reset to `null` on the null-context
  /// sentinel so a real route transition (already handled by that path) is
  /// not double-counted as a tab switch on the next non-null scan.
  int? _lastVisibleScaffoldHash;

  /// Cached NotificationListener element wrapping widget.child — used as
  /// scan root for static scaffold-free apps (no Navigator).
  BuildContext? _appChildContext;

  /// Start periodic tree scanning. Call from widget with BuildContext.
  ///
  /// Uses a self-rescheduling [Timer] so the interval can adapt between
  /// firings based on [_currentScanIntervalMs] (backs off when clean).
  void startTreeScanning(BuildContext context) {
    _overlayContext = context;
    _treeScanTimer?.cancel();
    _scanTimerGeneration++;
    _scheduleNextScan();
  }

  /// Schedules the next tree scan after [_currentScanIntervalMs].
  ///
  /// Guards against two hazards:
  /// 1. **Post-dispose rescheduling**: if [dispose] runs while the timer
  ///    callback is mid-flight, the cancel() kills the pending Timer but not
  ///    the already-queued post-frame callback. [_disposed] prevents orphans.
  /// 2. **Parallel timer chains**: if [startTreeScanning] is called rapidly
  ///    (widget remount / hot reload), the old post-frame callback could still
  ///    fire after a new chain starts. [_scanTimerGeneration] ensures only the
  ///    latest chain reschedules.
  void _scheduleNextScan() {
    if (_disposed) return;
    final generation = _scanTimerGeneration;
    _treeScanTimer = Timer(
      Duration(milliseconds: _currentScanIntervalMs),
      () {
        if (_disposed || generation != _scanTimerGeneration) return;
        final ctx = _overlayContext;
        if (ctx != null) {
          final element = ctx as Element;
          if (element.mounted) {
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (_disposed || generation != _scanTimerGeneration) return;
              try {
                if (element.mounted) _scanTree(ctx);
              } catch (e, st) {
                assert(() {
                  debugPrint('Sleuth: scan error: $e\n$st');
                  return true;
                }());
              }
              _scheduleNextScan();
            });
          } else {
            _scheduleNextScan();
          }
        } else {
          _scheduleNextScan();
        }
      },
    );
  }

  void _scanTree(BuildContext context) {
    if (!_initialized || kReleaseMode) return;

    // Clear scaffold-free state — each scan path sets these independently.
    _isScaffoldFreeScan = false;
    _scaffoldFreeRouteName = null;

    // Always drain debug counts so they don't carry over across page transitions
    DebugSnapshot? debugSnapshot;
    assert(() {
      debugSnapshot = _debugCoordinator?.snapshot();
      return true;
    }());

    // Find the current visible page's context by skipping Offstage routes.
    // Returns null during route transitions (multiple Scaffolds visible).
    final scanContext = _findVisiblePageContext(context);
    if (scanContext == null) {
      _lastScanContext = null;
      // Route transition in progress — clear highlights, stale state,
      // and set interaction state to navigating.
      // debugSnapshot is drained and discarded — counts from transition
      // period are lost (intentionally: attributing them to an unknown
      // page is worse than losing them).
      _scrollIdleTimer?.cancel();
      _interactionState = InteractionContext.navigating;
      if (highlightsNotifier.value.items.isNotEmpty) {
        _highlightGeneration++;
        highlightsNotifier.value =
            (generation: _highlightGeneration, items: []);
      }
      selectedHighlightNotifier.value = null;
      for (final d in _detectors) {
        if (d is SetStateScopeDetector) d.clearSnapshots();
      }
      _networkMonitor.clearRecords();
      // Real route transition just fired clearRecords; reset the tab-switch
      // baseline so the first non-null scan after the transition doesn't
      // redundantly re-clear against a stale hash from the pre-transition
      // page.
      _lastVisibleScaffoldHash = null;
      return;
    }
    // Navigation complete — return to idle
    if (_interactionState == InteractionContext.navigating) {
      _interactionState = InteractionContext.idle;
    }
    _lastScanContext = scanContext;

    // -- Tab-switch detection (same route, different visible Scaffold) --
    //
    // IndexedStack (and StatefulShellRoute.indexedStack) swaps children via
    // its `index` property — no route push, no Navigator notification. Below,
    // the route-change block compares [_currentRouteName()], which reads
    // [ModalRoute.of] on the scan context: all tabs share one Navigator
    // route, so that comparison cannot detect the swap. The network-monitor
    // buffer would therefore persist across tab switches and any cumulative
    // traffic from the previous tab counts toward the new tab's 30-req/5s
    // frequency-spike threshold, producing misattributed issues.
    //
    // Each tab owns a distinct innermost Scaffold Element, so a hash change
    // between two successful scans (both non-null) is a reliable tab-switch
    // signal. Rebuilds of the same tab keep Element identity stable — this
    // does not false-fire on normal setState.
    final cur = _currentVisibleScaffoldHash;
    final last = _lastVisibleScaffoldHash;
    if (cur != null && last != null && cur != last) {
      _networkMonitor.clearRecords();
      _consecutiveCleanScans = 0;
    }
    _lastVisibleScaffoldHash = cur;

    // -- Route session tracking --
    // Detect session boundaries by comparing the compound key
    // (routeName, scaffoldHashKey) against the active session. Creates a new
    // RouteSession whenever either half of the key changes, so that:
    //   - a real route push triggers a new session (name change), AND
    //   - a tab swap under a shared ModalRoute — IndexedStack,
    //     StatefulShellRoute.indexedStack, CupertinoTabScaffold — also
    //     triggers a new session (scaffold-hash change) even though the name
    //     is identical.
    //
    // The unnamed-route counter is stable per scaffold hash: the first time
    // we see a null routeName under a given scaffold, we mint an ordinal and
    // cache it in [_unnamedIdByHash]. Returning to the same (null-name, hash)
    // pair reuses the cached id. Without this, tab-switching between two
    // unnamed tabs churned the counter on every back-and-forth.
    final currentName = _currentRouteName();
    final currentHashKey = _currentVisibleScaffoldHash;
    final active = _activeRouteSession;

    final bool nameChanged = active == null ||
        (currentName != null && active.routeName != currentName) ||
        (currentName == null && !active.routeName.startsWith('<unnamed-'));
    final bool hashChanged =
        active != null && active.scaffoldHashKey != currentHashKey;
    final routeChanged = nameChanged || hashChanged;

    if (routeChanged) {
      active?.endedAt = DateTime.now();
      final newRoute =
          currentName ?? '<unnamed-${_nextUnnamedId(currentHashKey)}>';
      // Skip session creation for ignored routes, but still reset back-off.
      if (!_isRouteIgnored(newRoute)) {
        final visitIndex = _computeTabVisitIndex(newRoute, currentHashKey);
        _activeRouteSession = RouteSession(
          routeName: newRoute,
          scaffoldHashKey: currentHashKey,
          tabVisitIndex: visitIndex,
          hotReloadGeneration: _hotReloadGeneration,
          startedAt: DateTime.now(),
          fpsTarget: config.fpsTarget,
        );
        if (_routeHistory.length >= config.routeHistoryCapacity) {
          _routeHistory.removeFirst();
        }
        _routeHistory.add(_activeRouteSession!);
        routeHistoryNotifier.value =
            List<RouteSession>.unmodifiable(_routeHistory.toList());
      } else {
        _activeRouteSession = null;
      }
      _consecutiveCleanScans = 0;
    }
    _activeRouteSession?.scanCycleCount++;

    // Guard _detectors iteration — enable/disable calls that arrive via
    // notifier listeners during scan/aggregation are deferred.
    _isIteratingDetectors = true;
    try {
      // Pass debug snapshot to detectors
      if (debugSnapshot != null) {
        for (final d in _detectors) {
          if (d.isEnabled) d.updateDebugSnapshot(debugSnapshot!);
        }
      }

      // Run all tree-scanning detectors
      _runStructuralScans(scanContext);

      // Aggregate and rank all issues (fires issuesNotifier listeners).
      _aggregateIssues();
    } finally {
      _isIteratingDetectors = false;
      _drainPendingDetectorMutations();
    }

    // Track consecutive clean scans for adaptive interval back-off.
    if (issuesNotifier.value.isEmpty) {
      _consecutiveCleanScans++;
    } else {
      _consecutiveCleanScans = 0;
    }

    // Update recurrence from scan path only (not timeline path) so all
    // detectors increment at the same rate regardless of lifecycle.
    _updateRecurrence(issuesNotifier.value);

    // Collect widget highlights if overlay is active
    if (highlightEnabledNotifier.value) {
      _collectHighlights();

      // Fulfill pending issue selection now that highlights are populated
      if (pendingIssueSelection != null) {
        selectHighlightForIssue(pendingIssueSelection!);
        pendingIssueSelection = null;
      }
    } else if (highlightsNotifier.value.items.isNotEmpty) {
      _highlightGeneration++;
      highlightsNotifier.value = (generation: _highlightGeneration, items: []);
    }
  }

  BuildContext? _findVisiblePageContext(BuildContext root) {
    // Reset per-scan: only set non-null after we commit to a single
    // innermost visible Scaffold below. Leaving it stale would silently
    // suppress tab-switch detection on the next scan.
    _currentVisibleScaffoldHash = null;
    final scaffolds = <Element>[];

    void visitor(Element element) {
      final widget = element.widget;

      // Skip offstage subtrees — inactive Navigator routes
      if (widget is Offstage && widget.offstage) return;

      // Skip ticker-disabled subtrees — background Navigator routes
      if (widget is TickerMode && !widget.enabled) return;

      // Skip invisible Visibility subtrees — inactive IndexedStack children.
      // IndexedStack wraps every child in Visibility(maintainSize: true, ...)
      // which uses a _Visibility render proxy (NOT Offstage/TickerMode), so
      // the Offstage/TickerMode guards above do not filter inactive tabs.
      // Without this skip, a bottom-nav app using IndexedStack for state
      // preservation exposes every tab's Scaffold as a sibling, tripping
      // the multi-scaffold guard below and aborting every scan.
      if (widget is Visibility && !widget.visible) return;

      // Skip our own overlay widgets (v9.9: zero-allocation is checks)
      if (widget is FloatingIssuesCard ||
          widget is TriggerButton ||
          widget is HighlightOverlay) {
        return;
      }

      // Stop Scaffold collection at TabBarView / PageView boundaries. Both
      // widgets keep multiple "page" children alive simultaneously (TabBarView
      // via its internal PageController, PageView via KeepAlive), and they do
      // NOT mark inactive pages with Offstage / TickerMode / Visibility(!visible)
      // — so the filters above cannot skip them. Descending collects every
      // sub-page's Scaffold as a sibling, trips the multi-scaffold guard
      // below, and aborts every scan while the user sits on an inline-tab or
      // swipeable-pager screen.
      //
      // By stopping here, the outer Scaffold becomes the innermost visible
      // one. Sub-tab swipes / TabBar changes keep that hash stable, so they
      // stay within the outer route's RouteSession (no spurious session
      // churn) and the scan root — still anchored above the outer Scaffold —
      // walks into the active sub-page as usual, so detectors run normally.
      //
      // Bottom-nav shells (IndexedStack / StatefulShellRoute.indexedStack
      // Visibility gate, CupertinoTabScaffold Offstage gate) are unaffected:
      // they mark inactive tabs explicitly and the earlier filters skip them
      // before collection ever reaches this point.
      if (widget is TabBarView || widget is PageView) {
        return;
      }

      // Collect all visible Scaffolds (Material + Cupertino)
      if (widget is Scaffold || widget is CupertinoPageScaffold) {
        scaffolds.add(element);
      }

      element.visitChildren(visitor);
    }

    try {
      root.visitChildElements(visitor);
    } catch (e, s) {
      assert(() {
        debugPrint('Sleuth: scaffold search failed: $e\n$s');
        return true;
      }());
    }

    if (scaffolds.isEmpty) {
      // No Material or Cupertino scaffold — try scaffold-free fallback.
      final scanRoot = _findActiveRouteScanRoot(root);
      if (scanRoot != null) {
        _isScaffoldFreeScan = true;
        if (_isRouteStable()) return scanRoot;
        return null; // Unstable route → navigating sentinel
      }
      // No route-owned scan root — distinguish why:
      if (_navigatorFound) return null; // Navigator exists, unsafe → sentinel
      // No Navigator at all — genuine static app.
      return _resolveAppChildContext(root);
    }

    // Multiple visible Scaffolds — distinguish nested (legitimate app
    // structure like a bottom-nav shell Scaffold wrapping a per-tab Scaffold)
    // from sibling (a real route transition mid-animation, or two unrelated
    // Scaffolds co-mounted).
    //
    // Pre-order traversal guarantees the outermost Scaffold appears first
    // and the innermost appears last. If every earlier Scaffold is an
    // ancestor of the innermost one, all visible Scaffolds lie on a single
    // ancestor chain — that is nested, not a transition. Otherwise at least
    // two Scaffolds are siblings (or in divergent subtrees), which is the
    // signature of a real transition or unsafe multi-Scaffold layout.
    if (scaffolds.length > 1) {
      final innermost = scaffolds.last;
      final ancestorSet = <Element>{};
      innermost.visitAncestorElements((a) {
        ancestorSet.add(a);
        return true;
      });
      final allNested =
          scaffolds.take(scaffolds.length - 1).every(ancestorSet.contains);
      if (!allNested) return null; // Real transition / sibling scaffolds.
      // Nested — treat the innermost Scaffold as the visible page.
      scaffolds
        ..clear()
        ..add(innermost);
    }

    // At this point [scaffolds] has exactly one entry: the innermost visible
    // Scaffold, which is the user's active page. Capture its identity so
    // [_scanTree] can detect tab swaps that don't register as route changes
    // (IndexedStack / StatefulShellRoute.indexedStack).
    _currentVisibleScaffoldHash = identityHashCode(scaffolds.first);

    // Walk up from Scaffold to include the user's page widget in the scan.
    // Go one level past the user widget so visitChildElements includes it.
    Element result = scaffolds.first;
    bool foundUserWidget = false;
    scaffolds.first.visitAncestorElements((ancestor) {
      if (foundUserWidget) {
        result = ancestor;
        return false;
      }
      if (ancestor is StatefulElement) {
        final name = ancestor.widget.runtimeType.toString();
        if (name.startsWith('_')) return false;
        if (SetStateScopeDetector.isFrameworkWidget(ancestor.widget)) {
          return false;
        }
        foundUserWidget = true;
        return true;
      }
      return true;
    });

    return result;
  }

  /// Walk from [root] to find the outermost Navigator's topmost
  /// route-owned onstage overlay entry as the scan root.
  ///
  /// Sets [_navigatorFound], [_currentActiveEntryHash], and
  /// [_scaffoldFreeRouteName]. Returns the overlay entry element
  /// or null if no suitable scan root found.
  Element? _findActiveRouteScanRoot(BuildContext root) {
    Element? navigator;
    void findNav(Element el) {
      if (navigator != null) return;
      final widget = el.widget;
      // Skip our own UI widgets (v9.9: zero-allocation is checks)
      if (widget is FloatingIssuesCard ||
          widget is TriggerButton ||
          widget is HighlightOverlay) {
        return;
      }
      if (widget is Navigator) {
        navigator = el;
        return; // outermost — don't descend
      }
      el.visitChildElements(findNav);
    }

    root.visitChildElements(findNav);
    _navigatorFound = navigator != null;
    if (navigator == null) return null;

    // Collect onstage overlay entries via TickerMode filtering.
    // _OverlayEntryWidgetState.build() wraps content in
    // TickerMode(enabled: tickerEnabled). Background maintained
    // routes have tickerEnabled: false (overlay.dart:883).
    final onstageEntries = <Element>[];
    void collectEntries(Element el) {
      final name = el.widget.runtimeType.toString();
      if (name == '_OverlayEntryWidget' || name == 'OverlayEntry') {
        bool isBackground = false;
        el.visitChildElements((child) {
          if (child.widget is TickerMode &&
              !(child.widget as TickerMode).enabled) {
            isBackground = true;
          }
        });
        if (!isBackground) onstageEntries.add(el);
        return; // don't descend into entry content for collection
      }
      el.visitChildElements(collectEntries);
    }

    navigator!.visitChildElements(collectEntries);

    // Iterate reverse (topmost first) — return first route-owned entry.
    for (final entry in onstageEntries.reversed) {
      if (_isRouteOwnedEntry(entry)) {
        if (_containsNestedNavigator(entry)) return null;
        _captureRouteName(entry);
        _currentActiveEntryHash = entry.hashCode;
        return entry;
      }
    }
    return null; // No route-owned entry (all transient UI)
  }

  /// Check if an overlay entry is route-owned by looking for `_ModalScope`
  /// within the first ~7 levels. Route entries have `_ModalScope` at depth ~5
  /// (entry, TickerMode, _EffectiveTickerMode, _RenderTheaterMarker,
  /// Builder, Semantics, `_ModalScope`).
  /// Non-route entries (tooltips, hero flights) lack it entirely.
  /// Uses startsWith because runtimeType includes the generic parameter
  /// (e.g. `_ModalScope<dynamic>`).
  bool _isRouteOwnedEntry(Element entry) {
    bool found = false;
    void check(Element el, int depth) {
      if (found || depth > 7) return;
      if (el.widget.runtimeType.toString().startsWith('_ModalScope')) {
        found = true;
        return;
      }
      el.visitChildElements((child) => check(child, depth + 1));
    }

    entry.visitChildElements((child) => check(child, 0));
    return found;
  }

  /// Walk the overlay entry subtree looking for a nested Navigator.
  /// Returns true if any Navigator element is found below the scan root.
  /// Terminates early on first match.
  bool _containsNestedNavigator(Element entry) {
    bool found = false;
    void check(Element el) {
      if (found) return;
      if (el.widget is Navigator) {
        found = true;
        return;
      }
      el.visitChildElements(check);
    }

    entry.visitChildElements(check);
    return found;
  }

  /// Resolve route name for scaffold-free scans. Walks from the overlay
  /// entry to find _ModalScopeStatus, then calls ModalRoute.of on its
  /// first child to get the route name. Stores only the String name.
  void _captureRouteName(Element entry) {
    _scaffoldFreeRouteName = null;
    Element? scopeStatusChild;
    void findScopeStatus(Element el, int depth) {
      if (scopeStatusChild != null || depth > 10) return;
      if (el.widget.runtimeType.toString() == '_ModalScopeStatus') {
        el.visitChildElements((child) {
          scopeStatusChild ??= child;
        });
        return;
      }
      el.visitChildElements((child) => findScopeStatus(child, depth + 1));
    }

    entry.visitChildElements((child) => findScopeStatus(child, 0));
    if (scopeStatusChild != null) {
      _scaffoldFreeRouteName = ModalRoute.of(scopeStatusChild!)?.settings.name;
    }
  }

  /// Check if the topmost route-owned overlay entry is stable across scans.
  /// Uses identity hash — detects push, pop, replacement, dialog open.
  bool _isRouteStable() {
    if (_lastActiveEntryHash == 0) {
      // Initial startup — record but don't accept yet.
      _lastActiveEntryHash = _currentActiveEntryHash;
      return false;
    }
    final stable = _currentActiveEntryHash == _lastActiveEntryHash;
    _lastActiveEntryHash = _currentActiveEntryHash;
    return stable;
  }

  /// Resolve the NotificationListener element wrapping widget.child in the
  /// overlay. Used as scan root for static scaffold-free apps (no Navigator).
  /// Cached after first resolution. Depth ~4 from overlay root.
  BuildContext? _resolveAppChildContext(BuildContext root) {
    if (_appChildContext != null) {
      final el = _appChildContext! as Element;
      if (el.mounted) return _appChildContext;
      _appChildContext = null;
    }
    Element? result;
    void find(Element el) {
      if (result != null) return;
      if (el.widget is NotificationListener) {
        result = el;
        return;
      }
      el.visitChildElements(find);
    }

    root.visitChildElements(find);
    _appChildContext = result;
    return result;
  }

  /// Re-collect highlights using fresh screen rects (e.g. after scroll).
  ///
  /// Re-runs structural detector scans to get fresh rects, then
  /// aggregates highlights from all detectors.
  void refreshHighlights() {
    if (!highlightEnabledNotifier.value) return;
    if (_interactionState == InteractionContext.navigating) return;
    final scanContext = _lastScanContext;
    if (scanContext == null) return;
    final element = scanContext as Element;
    if (!element.mounted) return;
    _runStructuralScans(scanContext);
    _collectHighlights();
  }

  /// Update interaction state from app scroll notifications.
  ///
  /// Called by the overlay's [NotificationListener] which is scoped to the
  /// app child only (not the dashboard). Scroll notifications from the
  /// sleuth UI are excluded.
  void onScrollActivity(ScrollNotification notification) {
    if (_interactionState == InteractionContext.navigating) return;
    // Typing has priority over scrolling — don't downgrade
    if (_interactionState == InteractionContext.typing) return;
    if (notification is ScrollStartNotification) {
      _scrollIdleTimer?.cancel();
      if (_interactionState != InteractionContext.scrolling) {
        _interactionState = InteractionContext.scrolling;
        _aggregateIssues();
      }
    } else if (notification is ScrollEndNotification) {
      _scrollIdleTimer?.cancel();
      _scrollIdleTimer = Timer(const Duration(milliseconds: 300), () {
        _interactionState = InteractionContext.idle;
        _aggregateIssues();
      });
    }
  }

  /// Update interaction state when keyboard visibility changes.
  ///
  /// Called by the overlay's [WidgetsBindingObserver.didChangeMetrics]
  /// when viewport insets change (keyboard appearing/disappearing).
  void onKeyboardVisibilityChanged({required bool visible}) {
    if (_interactionState == InteractionContext.navigating) return;
    if (visible && !_keyboardVisible) {
      _keyboardVisible = true;
      _typingIdleTimer?.cancel();
      // Typing takes priority over scrolling (priority ordering)
      _interactionState = InteractionContext.typing;
      _aggregateIssues();
    } else if (!visible && _keyboardVisible) {
      _keyboardVisible = false;
      _typingIdleTimer?.cancel();
      _typingIdleTimer = Timer(const Duration(milliseconds: 300), () {
        if (_interactionState == InteractionContext.typing) {
          _interactionState = InteractionContext.idle;
          _aggregateIssues();
        }
      });
    }
  }

  /// Update interaction state for app lifecycle transitions.
  ///
  /// Called by the overlay's [WidgetsBindingObserver.didChangeAppLifecycleState].
  void onAppLifecycleChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _interactionState = InteractionContext.appLifecycle;
      _aggregateIssues();
    } else if (state == AppLifecycleState.resumed) {
      _interactionState = InteractionContext.idle;
      _aggregateIssues();
    }
  }

  /// Run all tree-scanning detectors (hybrid + structural) in a single
  /// unified walk. Custom detectors fall back to their own scanTree().
  void _runStructuralScans(BuildContext scanContext) {
    final unified = <BaseDetector>[];
    final legacy = <BaseDetector>[];

    for (final d in _detectors) {
      if (!d.isEnabled || !d.requiresTreeScan) continue;
      if (d.type == DetectorType.custom) {
        legacy.add(d);
      } else {
        unified.add(d);
      }
    }

    // Phase 1: Preparation
    typeNameCache.clear();
    for (final d in unified) {
      d.prepareScan(scanContext);
    }

    // Phase 2: Unified walk — O(N) instead of O(detectors × N)
    // Exempt depth/ratio-dependent detectors from scaffold-free walk.
    // Also exclude startup detector — its checkElement/afterElement are no-ops
    // (one-shot metrics come from FrameTiming, not the widget tree).
    final walkDetectors = _isScaffoldFreeScan
        ? unified
            .where((d) =>
                d.type != DetectorType.startup &&
                d is! SetStateScopeDetector &&
                d is! ShallowRebuildRiskDetector)
            .toList()
        : unified.where((d) => d.type != DetectorType.startup).toList();

    void visitor(Element element) {
      for (final d in walkDetectors) {
        try {
          d.checkElement(element);
        } catch (e, s) {
          assert(() {
            debugPrint('Sleuth: ${d.name} checkElement failed: $e\n$s');
            return true;
          }());
        }
      }
      element.visitChildren(visitor);
      for (final d in walkDetectors) {
        try {
          d.afterElement(element);
        } catch (e, s) {
          assert(() {
            debugPrint('Sleuth: ${d.name} afterElement failed: $e\n$s');
            return true;
          }());
        }
      }
    }

    bool walkCompleted = false;
    try {
      scanContext.visitChildElements(visitor);
      walkCompleted = true;
    } catch (e, s) {
      assert(() {
        debugPrint('Sleuth: tree walk failed: $e\n$s');
        return true;
      }());
    }

    // Phase 3: Finalization
    // notifyWalkCompleted only for detectors that participated in the walk.
    // finalizeScan for ALL unified detectors — exempted detectors need it
    // to clear stale state (e.g. swap empty _childSnapshots, clear _usages).
    if (walkCompleted) {
      for (final d in walkDetectors) {
        d.notifyWalkCompleted();
      }
    }
    for (final d in unified) {
      d.finalizeScan();
    }

    // Phase 4: Legacy custom detectors (separate walks)
    for (final d in legacy) {
      d.scanTree(scanContext);
    }

    // Invalidate _getAllIssues cache — detectors have fresh issues.
    _issueGeneration++;
  }

  /// Aggregate highlights from all detectors that produce them.
  ///
  /// Detectors collect highlights during their scanTree() calls.
  /// This method just gathers them — no tree walking or re-detection.
  void _collectHighlights() {
    // Fast path: if no highlights existed last scan and no detector produced
    // any this scan, skip the list spread, generation increment, and notifier
    // update to avoid unnecessary overlay repaints (Pillar 2a M2).
    if (highlightsNotifier.value.items.isEmpty) {
      bool anyHighlights = false;
      for (final d in _detectors) {
        if (d.highlights.isNotEmpty) {
          anyHighlights = true;
          break;
        }
      }
      if (!anyHighlights) {
        // Defensive: clear stale selection if somehow non-null while
        // highlights are empty (shouldn't happen, but safe-guards against
        // future code paths that set selection without highlights).
        if (selectedHighlightNotifier.value != null) {
          selectedHighlightNotifier.value = null;
        }
        return;
      }
    }

    _highlightGeneration++;
    final items = [for (final d in _detectors) ...d.highlights];
    highlightsNotifier.value = (generation: _highlightGeneration, items: items);

    // Rebind selected highlight to fresh object with updated rect (v9.14).
    // After scroll/rescan, detectors produce new WidgetHighlight objects with
    // fresh rects. Match by detectorName + widgetName to track the widget's
    // current position. Clears selection if the widget is gone.
    // Note: if two highlights share the same detectorName + widgetName, the
    // first match wins — rare edge case with minimal visual impact.
    final selected = selectedHighlightNotifier.value;
    if (selected != null) {
      WidgetHighlight? refreshed;
      for (final h in items) {
        if (h.detectorName == selected.detectorName &&
            h.widgetName == selected.widgetName) {
          refreshed = h;
          break;
        }
      }
      selectedHighlightNotifier.value = refreshed;
    }
  }

  void _onStartupTimelineEvents(StartupTimelineEvents events) {
    Sleuth.enrichStartupWithVmData(
      engineEnterUs: events.engineEnterUs,
      firstFrameRasterizedUs: events.firstFrameRasterizedUs,
      vmFirstBuildScopeMs: events.firstBuildScopeDurUs != null
          ? events.firstBuildScopeDurUs! / 1000.0
          : null,
      vmFirstFlushLayoutMs: events.firstFlushLayoutDurUs != null
          ? events.firstFlushLayoutDurUs! / 1000.0
          : null,
      vmFirstFlushPaintMs: events.firstFlushPaintDurUs != null
          ? events.firstFlushPaintDurUs! / 1000.0
          : null,
      vmFirstRasterMs: events.firstRasterDurUs != null
          ? events.firstRasterDurUs! / 1000.0
          : null,
    );
  }

  void _onTimelineData(ParsedTimelineData data) {
    // FrameTimingDetector uses custom method (not processTimelineData)
    _frameTiming.updateTimelineData(data);

    // Generate verdict for slow frames (full mode with VM timeline data)
    // Local variables bridge jank decision → post-aggregation capture.
    FrameStats? captureFrame;
    FrameVerdict? captureVerdict;

    // Guard _detectors iteration against concurrent enable/disable.
    _isIteratingDetectors = true;
    try {
      // Feed timeline data to vmOnly and hybrid detectors.
      // Per-detector try/catch mirrors the structural walk's isolation so
      // a throwing custom detector cannot poison the entire VM pipeline.
      for (final d in _detectors) {
        if (d.isEnabled &&
            (d.lifecycle == DetectorLifecycle.vmOnly ||
                d.lifecycle == DetectorLifecycle.hybrid)) {
          try {
            d.processTimelineData(data);
          } catch (e, s) {
            assert(() {
              debugPrint(
                'Sleuth: ${d.name} processTimelineData failed: $e\n$s',
              );
              return true;
            }());
          }
        }
      }

      // Flush staged data so _getAllIssues() sees current state
      for (final d in _detectors) {
        if (d.isEnabled &&
            (d.lifecycle == DetectorLifecycle.vmOnly ||
                d.lifecycle == DetectorLifecycle.hybrid)) {
          try {
            d.evaluateNow();
          } catch (e, s) {
            assert(() {
              debugPrint('Sleuth: ${d.name} evaluateNow failed: $e\n$s');
              return true;
            }());
          }
        }
      }

      // Invalidate _getAllIssues cache — detectors have fresh issues.
      _issueGeneration++;

      // Try correlated mode first: match events to specific frames by
      // timestamp. Falls back to legacy full mode if correlation fails.
      if (data.phaseEvents.isNotEmpty) {
        final allFrames = _frameTiming.frameBuffer.frames;

        // Compute the batch time window from phaseEvents
        var batchStartUs = data.phaseEvents.first.timestampUs;
        var batchEndUs = data.phaseEvents.first.endUs;
        for (final e in data.phaseEvents) {
          if (e.timestampUs < batchStartUs) batchStartUs = e.timestampUs;
          if (e.endUs > batchEndUs) batchEndUs = e.endUs;
        }

        // Filter frames to those that overlap the batch window
        final batchFrames = allFrames.where((f) {
          if (!f.hasPhaseTimestamps) return false;
          return f.vsyncStartUs! < batchEndUs &&
              f.rasterFinishUs! > batchStartUs;
        }).toList();

        if (batchFrames.isNotEmpty) {
          final correlations = _correlator.correlate(
            recentFrames: batchFrames,
            phaseEvents: data.phaseEvents,
          );

          // Find worst jank frame with trustworthy correlation
          FrameStats? worstFrame;
          CorrelatedFrameData? worstCorrelation;
          for (final frame in batchFrames) {
            if (!frame.isJank) continue;
            final corr = correlations[frame.frameNumber];
            if (corr == null || !corr.isTrustworthy) continue;
            if (worstFrame == null ||
                frame.effectiveTotalDuration >
                    worstFrame.effectiveTotalDuration) {
              worstFrame = frame;
              worstCorrelation = corr;
            }
          }

          if (worstFrame != null && worstCorrelation != null) {
            final allIssues = _getAllIssues();
            var verdict = _analyzer.analyzeCorrelatedMode(
              frameStats: worstFrame,
              correlation: worstCorrelation,
              relatedIssues: allIssues,
            );
            verdict = _enrichVerdictWithNetworkContext(verdict);
            verdictNotifier.value = verdict;
            _lastVerdictPhase = verdict.suspectedPhase;
            _lastVerdictFrameNumber = verdict.frameNumber;
            captureFrame = worstFrame;
            captureVerdict = verdict;
          }
        }
      }

      // Fallback: legacy full mode (batch-attributed)
      if (captureVerdict == null) {
        final latest = _frameTiming.frameBuffer.latest;
        if (latest != null && latest.isJank) {
          final allIssues = _getAllIssues();
          var verdict = _analyzer.analyzeFullMode(
            frameStats: latest,
            timelineData: data,
            relatedIssues: allIssues,
          );
          verdict = _enrichVerdictWithNetworkContext(verdict);
          verdictNotifier.value = verdict;
          _lastVerdictPhase = verdict.suspectedPhase;
          _lastVerdictFrameNumber = verdict.frameNumber;
          captureFrame = latest;
          captureVerdict = verdict;
        }
      }

      // frameStatsNotifier is already updated by _onFrameStats callback
      _aggregateIssues();
    } finally {
      _isIteratingDetectors = false;
      _drainPendingDetectorMutations();
    }

    // Capture AFTER aggregation so relatedIssues carry route/context tags.
    if (captureFrame != null &&
        captureVerdict != null &&
        captureFrame.frameNumber != _lastCapturedFrameNumber) {
      _lastCapturedFrameNumber = captureFrame.frameNumber;
      _captureBuffer.add(CaptureEntry(
        frameStats: captureFrame,
        verdict: captureVerdict,
        relatedIssues: List.of(issuesNotifier.value),
        capturedAt: DateTime.now(),
      ));
    }

    // Two-phase verdict: enrich with CPU attribution asynchronously.
    // Phase 1 (verdict) already emitted above. Phase 2 re-emits with
    // topFunctions when CPU samples arrive (or silently skips on timeout).
    if (captureFrame != null && captureVerdict != null) {
      _enrichVerdictWithCpuAttribution(captureFrame, captureVerdict);
    }

    // Buffer events for export enrichment (rolling, bounded)
    for (final event in data.phaseEvents) {
      if (_phaseEventBuffer.length >= _phaseEventBufferCapacity) {
        _phaseEventBuffer.removeFirst();
      }
      _phaseEventBuffer.add(event);
    }
    for (final event in data.gcEvents) {
      if (_gcEventBuffer.length >= _gcEventBufferCapacity) {
        _gcEventBuffer.removeFirst();
      }
      final json = event.json!;
      _gcEventBuffer.add(GcEventSummary(
        timestampUs: json['ts'] as int? ?? 0,
        durationUs: json['dur'] as int? ?? 0,
        category: (json['cat'] as String?) ?? 'gc',
        name: (json['name'] as String?) ?? 'GC',
      ));
    }
    for (final event in data.platformChannelEvents) {
      if (_platformChannelBuffer.length >= _platformChannelBufferCapacity) {
        _platformChannelBuffer.removeFirst();
      }
      final json = event.json!;
      _platformChannelBuffer.add(PlatformChannelSummary(
        timestampUs: json['ts'] as int? ?? 0,
        durationUs: json['dur'] as int? ?? 0,
        name: (json['name'] as String?) ?? 'channel',
      ));
    }
  }

  void _onFrameStats(FrameStatsBuffer buffer) {
    // Only copy buffer for the notifier when UI is actively listening (v9.10).
    // When !_initialized, exportSnapshot() reads from the notifier (fallback),
    // so the copy is required regardless of listener state.
    //
    // Throttle to ~5 Hz (see _frameStatsNotifierThrottle doc). Note: we do
    // NOT bypass the throttle for jank frames. When initialized, the jank
    // frame path below reads `buffer.latest` directly and uses the analyzer
    // pipeline — the notifier is purely a UI signal. A previous iteration
    // bypassed on jank, but that created a self-feedback loop on already-
    // janky apps: 30+ jank frames/sec → 30+ notifier emits/sec → real UI
    // listeners (TriggerButton/_StatusRow) rebuild at 30+ Hz → RebuildDetector
    // fires `rebuild_activity`, a false positive caused by Sleuth's own UI.
    // Worst case with a steady 200 ms throttle: FPS readout lags a jank spike
    // by ≤200 ms, which is within human-perception tolerance for a debug HUD.
    final latest = buffer.latest;
    if (latest != null) _activeRouteSession?.frameStats.add(latest);
    final isJankFrame = latest != null && latest.isJank;
    // ignore: invalid_use_of_protected_member
    final hasListeners = frameStatsNotifier.hasListeners;
    if (hasListeners || !_initialized) {
      // In the !_initialized fallback path, exportSnapshot() reads directly
      // from frameStatsNotifier.value — throttling would drop buffer updates
      // from the export, so flush every emit. Throttling only applies when
      // real UI listeners are attached (avoids rebuild storms).
      if (!_initialized) {
        frameStatsNotifier.value = FrameStatsBuffer.from(buffer);
        _lastFrameStatsNotifierEmit =
            clockOverrideForTest?.call() ?? DateTime.now();
      } else {
        final now = clockOverrideForTest?.call() ?? DateTime.now();
        final sinceLast = _lastFrameStatsNotifierEmit == null
            ? null
            : now.difference(_lastFrameStatsNotifierEmit!);
        final throttleElapsed =
            sinceLast == null || sinceLast >= _frameStatsNotifierThrottle;
        if (throttleElapsed) {
          frameStatsNotifier.value = FrameStatsBuffer.from(buffer);
          _lastFrameStatsNotifierEmit = now;
        }
      }
    }

    // FrameTimingDetector may have updated its issues — invalidate cache.
    _issueGeneration++;

    // Generate FRAME-mode verdict for jank frames when VM is not connected.
    // (Explicit null check re-promotes [latest] for Dart flow analysis.)
    if (latest != null && isJankFrame && !isVmConnected) {
      final basicVerdict = _enrichVerdictWithNetworkContext(
        _analyzer.analyzeBasicMode(
          frameStats: latest,
          relatedIssues: _getAllIssues(),
        ),
      );
      verdictNotifier.value = basicVerdict;
      _lastVerdictPhase = basicVerdict.suspectedPhase;
      _lastVerdictFrameNumber = basicVerdict.frameNumber;

      // Capture inside the jank guard with most-recently-stamped issues.
      if (latest.frameNumber != _lastCapturedFrameNumber) {
        _lastCapturedFrameNumber = latest.frameNumber;
        _captureBuffer.add(CaptureEntry(
          frameStats: latest,
          verdict: verdictNotifier.value!,
          relatedIssues: List.of(issuesNotifier.value),
          capturedAt: DateTime.now(),
        ));
      }
    }
  }

  void _onHeapSample(HeapSample sample) {
    if (_disposed) return;
    final hadHeapGrowing =
        _memoryPressure.issues.any((i) => i.stableId == 'heap_growing');

    _memoryPressure.processHeapSample(sample);

    final hasHeapGrowing =
        _memoryPressure.issues.any((i) => i.stableId == 'heap_growing');

    // Trigger allocation profiling when heap growth is first detected.
    // Cooldown prevents repeated queries if slope oscillates near threshold.
    if (!hadHeapGrowing && hasHeapGrowing) {
      final now = DateTime.now();
      final cooldownExpired = _lastAllocationEnrichmentTime == null ||
          now.difference(_lastAllocationEnrichmentTime!).inSeconds >= 10;
      if (cooldownExpired) {
        _lastAllocationEnrichmentTime = now;
        _enrichWithAllocationProfile();
      }
    }
  }

  void _onGcEvent(Event event) {
    // Authoritative per-cycle GC signal from EventStreams.kGC.
    //
    // Previously this was a no-op: we relied on `data.gcEvents.length` from
    // the timeline poll, which TimelineParser inflates 5–15× because it
    // counts every GC sub-phase trace event (both 'X' complete and 'B'/'E'
    // begin/end forms) instead of distinct cycles. On an idle home screen
    // that was enough to produce bogus ~4000+/min rates and fire
    // `gc_pressure`. Now we hand a single-cycle signal to the detector,
    // which owns the sliding-window rate calculation.
    //
    // Note: [data.gcEvents] is still consumed by [_gcEventBuffer] for the
    // export-enrichment path (captured sub-phase spans), which is a
    // legitimate use of the over-counted list and intentionally unchanged.
    if (_disposed) return;
    _memoryPressure.recordGcCycle();
  }

  /// Attach pending-request context to a verdict if requests are in-flight.
  FrameVerdict _enrichVerdictWithNetworkContext(FrameVerdict verdict) {
    if (!_networkMonitor.isEnabled) return verdict;
    final (count, slowestMs) = _networkMonitor.pendingRequestSnapshot();
    if (count == 0) return verdict;
    return verdict.withNetworkContext(
      pendingRequestCount: count,
      slowestPendingMs: slowestMs,
    );
  }

  /// Non-blocking — the verdict is already emitted without attribution (phase 1).
  /// When CPU samples arrive, the verdict is re-emitted with [topFunctions]
  /// (phase 2). If the query fails or times out, the original verdict stands.
  void _enrichVerdictWithCpuAttribution(
    FrameStats frame,
    FrameVerdict verdict,
  ) {
    final client = _vmClient;
    if (client == null || !frame.hasPhaseTimestamps) return;

    final timeOriginUs = frame.vsyncStartUs!;
    final timeExtentUs = frame.rasterFinishUs! - frame.vsyncStartUs!;
    if (timeExtentUs <= 0) return;

    client
        .getCpuSamples(timeOriginUs: timeOriginUs, timeExtentUs: timeExtentUs)
        .then((cpuSamples) {
      if (_disposed || cpuSamples == null) return;
      final topFunctions = _cpuAggregator.aggregate(cpuSamples);
      if (topFunctions.isEmpty) return;

      // Re-emit verdict with CPU attribution (phase 2)
      final enriched = verdict.withTopFunctions(topFunctions);
      verdictNotifier.value = enriched;

      // Update capture buffer entry if it was captured
      _captureBuffer.updateVerdict(frame.frameNumber, enriched);
    }).catchError((Object e) {
      assert(() {
        debugPrint('Sleuth: CPU attribution failed: $e');
        return true;
      }());
    });
  }

  /// Query allocation profile when heap growth is detected and re-emit
  /// enriched issues with top allocators (phase 2).
  ///
  /// Non-blocking — the heap_growing issue is already visible (phase 1).
  /// When the profile arrives, the issue is re-emitted with [topAllocators].
  /// If the query fails or times out, the original issue stands.
  Future<void> _enrichWithAllocationProfile() async {
    final client = _vmClient;
    if (client == null) return;

    try {
      // Phase 1: establish baseline (reset accumulators)
      await client.getAllocationProfile(reset: true);
      if (_disposed) return;

      // Brief delay to accumulate meaningful deltas
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (_disposed) return;

      // Phase 2: get delta since reset
      final profile = await client.getAllocationProfile(reset: true);
      if (_disposed || profile == null) return;

      final entries = _extractTopAllocators(profile);
      if (entries.isEmpty) return;

      // Re-emit memory pressure issues with enrichment
      _memoryPressure.enrichHeapGrowingIssue(entries);
      _aggregateIssues();
    } catch (e) {
      assert(() {
        debugPrint('Sleuth: allocation enrichment failed: $e');
        return true;
      }());
    }
  }

  /// Extract top-5 allocating classes from allocation profile.
  ///
  /// Filters SDK internals unless they dominate >50% of total bytes.
  List<AllocationEntry> _extractTopAllocators(AllocationProfile profile) {
    final members = profile.members;
    if (members == null || members.isEmpty) return [];

    final stats = <_AllocStat>[];
    int totalBytes = 0;

    for (final cls in members) {
      final bytes = cls.bytesCurrent ?? 0;
      final instances = cls.instancesCurrent ?? 0;
      if (bytes <= 0) continue;

      final name = cls.classRef?.name ?? '';
      final lib = cls.classRef?.library?.uri ?? '';
      totalBytes += bytes;
      stats.add(_AllocStat(name, lib, instances, bytes));
    }

    if (totalBytes == 0) return [];

    // Sort by bytes descending
    stats.sort((a, b) => b.bytes.compareTo(a.bytes));

    // Separate framework and user classes
    final userClasses = <_AllocStat>[];
    final frameworkClasses = <_AllocStat>[];

    for (final s in stats) {
      if (_isFrameworkClass(s.name)) {
        frameworkClasses.add(s);
      } else {
        userClasses.add(s);
      }
    }

    // Use user classes preferentially; include framework classes only
    // if they dominate > 50% of total allocations
    final result = <AllocationEntry>[];

    for (final s in userClasses.take(5)) {
      result.add(AllocationEntry(
        className: s.name,
        libraryUri: s.lib,
        instancesDelta: s.instances,
        bytesDelta: s.bytes,
        percentage: (s.bytes / totalBytes * 100),
      ));
    }

    // If fewer than 5 user classes, fill with framework classes
    // that are > 50% of total
    if (result.length < 5) {
      for (final s in frameworkClasses) {
        if (result.length >= 5) break;
        final pct = s.bytes / totalBytes * 100;
        if (pct > 50) {
          result.add(AllocationEntry(
            className: s.name,
            libraryUri: s.lib,
            instancesDelta: s.instances,
            bytesDelta: s.bytes,
            percentage: pct,
          ));
        }
      }
    }

    return result;
  }

  static bool _isFrameworkClass(String name) {
    return _frameworkClassPrefixes.any((prefix) => name.startsWith(prefix));
  }

  void _onVmConnectionChanged(bool connected) {
    vmConnectedNotifier.value = connected;
    _syncVmState(connected);
    // Mid-session VM death: VmServiceClient._pollTimeline's catch path runs
    // its own 3-attempt reconnect loop. If that internal loop exhausts, we
    // previously had no recovery — the controller sat in BASIC until the
    // user manually tapped reconnect. Re-arm the background ladder so we
    // keep probing. The schedule call is idempotent (guarded by
    // _backgroundReconnectActive), so overlapping with the client's own
    // reconnect attempt is harmless — _connectInFlight coalesces them.
    if (!connected && _initialized && !_disposed) {
      _scheduleBackgroundReconnect();
    }
  }

  /// Propagate current VM connectivity to all detectors. Hybrid detectors
  /// degrade correctly on disconnect; others use the no-op default.
  void _syncVmState(bool connected) {
    for (final d in _detectors) {
      d.vmConnected = connected;
    }
  }

  String? _currentRouteName() {
    if (_scaffoldFreeRouteName != null) return _scaffoldFreeRouteName;
    final ctx = _lastScanContext;
    if (ctx == null || !(ctx as Element).mounted) return null;
    return ModalRoute.of(ctx)?.settings.name;
  }

  /// Returns a stable synthetic ordinal for an unnamed route under the given
  /// scaffold hash. First lookup mints `++_unnamedRouteCounter` and caches it;
  /// subsequent lookups for the same hash return the cached id. This keeps
  /// `<unnamed-N>` labels stable across tab switches that return to a
  /// previously-seen unnamed tab.
  int _nextUnnamedId(int? hash) =>
      _unnamedIdByHash.putIfAbsent(hash, () => ++_unnamedRouteCounter);

  /// Returns `max(tabVisitIndex) + 1` across sessions in [_routeHistory] that
  /// match the given `(routeName, scaffoldHashKey)` pair — i.e. the next
  /// 1-indexed visit ordinal that cannot collide with any live entry.
  /// Called when a new [RouteSession] is about to be created.
  ///
  /// Must use max+1, not count+1: with FIFO eviction via
  /// `_routeHistory.removeFirst()`, count can produce a value that duplicates
  /// an existing live entry. Example (cap=5): visit A seven times. After the
  /// 6th add + eviction, history holds tabVisitIndex values [2,3,4,5,6]. A
  /// count-based 7th visit would return 6, colliding with A₆. max+1 returns
  /// 7, preserving uniqueness.
  ///
  /// O(routeHistory.length). With the default cap of 50, worst case is 50
  /// comparisons per session boundary — negligible at scan frequency.
  int _computeTabVisitIndex(String routeName, int? hashKey) {
    int maxIndex = 0;
    for (final s in _routeHistory) {
      if (s.routeName == routeName && s.scaffoldHashKey == hashKey) {
        if (s.tabVisitIndex > maxIndex) maxIndex = s.tabVisitIndex;
      }
    }
    return maxIndex + 1;
  }

  /// Test-only hook that invokes the same reassemble handling as Flutter's
  /// hot reload. Production callers go through [reassemble] via the framework.
  @visibleForTesting
  void reassembleForTest() => _reassembleInternal();

  /// Read-only view of the hot-reload generation counter for tests.
  @visibleForTesting
  int get hotReloadGenerationForTest => _hotReloadGeneration;

  /// Handle a Flutter hot reload: close the active session (so post-reload
  /// frames/issues don't blend with pre-reload ones), stamp a new generation
  /// on future sessions, flush caches that key off Element identity (which
  /// may rotate on reload), and force the next scan to re-baseline the
  /// tab-switch hash.
  ///
  /// Closing the active session matters even for non-structural reloads where
  /// Element identity is preserved: without it, the session-keying predicate
  /// in [scanTree] sees unchanged `routeName` + `scaffoldHashKey` and the
  /// pre-reload session continues into post-reload, carrying a stale
  /// [RouteSession.hotReloadGeneration] stamp and mixing frame samples
  /// across the reload boundary.
  ///
  /// Does NOT purge [_routeHistory] — prior-reload sessions remain viewable,
  /// grouped by their [RouteSession.hotReloadGeneration] stamp.
  void _reassembleInternal() {
    final active = _activeRouteSession;
    if (active != null && active.endedAt == null) {
      active.endedAt = DateTime.now();
      // Republish history so listeners see the newly-closed session.
      routeHistoryNotifier.value =
          List<RouteSession>.unmodifiable(_routeHistory.toList());
    }
    _activeRouteSession = null;
    _hotReloadGeneration++;
    _unnamedIdByHash.clear();
    _lastVisibleScaffoldHash = null;
    _currentVisibleScaffoldHash = null;
  }

  /// Returns true if [routeName] matches any pattern in
  /// [SleuthConfig.routeIgnorePatterns]. Supports exact match and trailing
  /// `*` wildcard.
  bool _isRouteIgnored(String routeName) {
    for (final pattern in config.routeIgnorePatterns) {
      if (pattern.endsWith('*')) {
        if (routeName.startsWith(pattern.substring(0, pattern.length - 1))) {
          return true;
        }
      } else if (routeName == pattern) {
        return true;
      }
    }
    return false;
  }

  void _aggregateIssues() {
    final all = _getAllIssues();
    final correlated = _detectorCorrelator.correlate(all);
    final route = _currentRouteName();

    // Pull session-keying context from the active RouteSession so issues
    // stamped in this aggregation inherit its compound identity. Using the
    // session (rather than live controller fields) keeps issue stamps in
    // sync with the session record that owns their issueSnapshots entry —
    // even if the user navigates mid-aggregation, everything stamped here
    // lands on the same session.
    final activeSession = _activeRouteSession;
    final hashKey = activeSession?.scaffoldHashKey;
    final tabIdx = activeSession?.tabVisitIndex;

    // Stamp the RAW route name on each issue (no `(tab-N)` suffix). Callers
    // that need a human-facing label use `PerformanceIssue.routeDisplayName`,
    // which derives the suffix from `tabVisitIndex > 1` at render time.
    // Baking the suffix into `routeName` would poison group-by-route keys and
    // make a route literally named `"/x (tab-2)"` indistinguishable from a
    // disambiguated tab-2 of `"/x"`.
    //
    // Stamp debug disclaimer, route name, and interaction context, then
    // suppress user-dismissed issues — all in a single pass to avoid
    // intermediate list allocations (v9.12).
    final List<PerformanceIssue> visible = [];
    int suppressedCount = 0;
    for (final issue in correlated) {
      final stamped = issue.copyWith(
        debugModeDisclaimer: kDebugMode ? true : null,
        routeName: route,
        interactionContext: _interactionState,
        scaffoldHashKey: hashKey,
        tabVisitIndex: tabIdx,
      );
      if (config.suppressedIssues.isNotEmpty &&
          _matchesSuppression(stamped.stableId ?? stamped.title)) {
        suppressedCount++;
      } else {
        visible.add(stamped);
      }
    }
    suppressedCountNotifier.value = suppressedCount;

    // Upsert visible issues into the active route session so each route
    // accumulates its own issue snapshot history (M3: route-scoped aggregation).
    if (_activeRouteSession != null) {
      for (final issue in visible) {
        final id = issue.stableId ?? issue.title;
        _activeRouteSession!.issueSnapshots[id] = issue;
      }
    }

    // Duration-based severity escalation: warning → critical after 30+ cycles.
    // Uses cumulative presentCount (not consecutive) to avoid oscillation.
    _applyDurationEscalation(visible);

    // Rank by impact: severity dominates, then frame impact, confidence,
    // recurrence. See IssueRanker for score formula and tier guarantees.
    final ranked = _ranker.rank(visible, _buildRankingContext());

    // IssueCard is a StatefulWidget with ValueKey(stableId), so expansion
    // state survives list rebuilds. Safe to always update the notifier —
    // titles with live counters (e.g. "45 GC/min") will reflect fresh data.
    issuesNotifier.value = ranked;
  }

  /// Threshold for duration-based severity escalation (scan cycles).
  static const _escalationThreshold = 30;

  /// Promotes warning-severity issues to critical when they have persisted
  /// for [_escalationThreshold]+ cumulative scan cycles.
  ///
  /// Mutates [issues] in place (replaces elements via index) to avoid an
  /// extra list allocation. Only escalates warnings — ok and critical are
  /// left untouched.
  void _applyDurationEscalation(List<PerformanceIssue> issues) {
    for (var i = 0; i < issues.length; i++) {
      final issue = issues[i];
      if (issue.severity != IssueSeverity.warning) continue;

      final id = issue.stableId ?? issue.title;
      final trend = _recurrenceTrends[id];
      if (trend == null || trend.presentCount < _escalationThreshold) continue;

      final reason = issue.confidenceReason != null
          ? '${issue.confidenceReason} '
              '[Auto-escalated: persisted for ${trend.presentCount} scan cycles]'
          : 'Auto-escalated: persisted for ${trend.presentCount} scan cycles';

      issues[i] = issue.copyWith(
        severity: IssueSeverity.critical,
        confidenceReason: reason,
      );
    }
  }

  /// Splits [config.suppressedIssues] into exact matches and prefix patterns.
  void _compileSuppressions() {
    final exact = <String>{};
    final prefixes = <String>[];
    for (final pattern in config.suppressedIssues) {
      if (pattern.endsWith('*')) {
        prefixes.add(pattern.substring(0, pattern.length - 1));
      } else {
        exact.add(pattern);
      }
    }
    _exactSuppressions = exact;
    _prefixSuppressions = prefixes;
  }

  /// Returns true if [id] matches any pattern in [config.suppressedIssues].
  bool _matchesSuppression(String id) {
    if (_exactSuppressions.contains(id)) return true;
    for (final prefix in _prefixSuppressions) {
      if (id.startsWith(prefix)) return true;
    }
    return false;
  }

  IssueRankingContext _buildRankingContext() {
    final latest = _frameTiming.frameBuffer.latest;
    final latestIsJank = latest != null && latest.isJank;

    // Active frame impact: triggered by EITHER a sustained jank pattern
    // (FrameTimingDetector issues) OR the most recent frame being janky.
    // This ensures fresh single-frame jank influences ranking immediately,
    // not just after the sustained-pattern threshold is met.
    final jankActive = _frameTiming.issues.isNotEmpty || latestIsJank;

    PipelinePhase? phase;
    if (jankActive && latestIsJank) {
      // Prefer the verdict's analysed phase when available and fresh.
      final verdictAge = latest.frameNumber - (_lastVerdictFrameNumber ?? 0);
      if (_lastVerdictPhase != null &&
          _lastVerdictPhase != PipelinePhase.unknown &&
          _lastVerdictFrameNumber != null &&
          verdictAge >= 0 &&
          verdictAge <= _frameTiming.frameBuffer.capacity) {
        phase = _lastVerdictPhase;
      } else {
        // Fallback: derive from UI vs raster duration ratio.
        phase = latest.uiDuration > latest.rasterDuration
            ? PipelinePhase.build
            : PipelinePhase.raster;
      }
    }
    // If jankActive but latest is not janky (sustained pattern, current
    // frame ok), phase stays null — all categories get equal partial boost.

    return IssueRankingContext(
      jankActive: jankActive,
      suspectedPhase: phase,
      recurrenceCounts: {
        for (final e in _recurrenceTrends.entries)
          if (e.value.entries.isNotEmpty && e.value.entries.last.present)
            e.key: e.value.presentCount.clamp(0, 5),
      },
    );
  }

  /// Record presence/absence for each issue in the recurrence time-series.
  /// Called only from the scan path to keep rates consistent across lifecycles.
  void _updateRecurrence(List<PerformanceIssue> currentIssues) {
    _scanCycleIndex++;
    final currentIds = <String>{};
    for (final issue in currentIssues) {
      final id = issue.stableId ?? issue.title;
      currentIds.add(id);
      final trend = _recurrenceTrends.putIfAbsent(id, RecurrenceTrend.new);
      trend.recordPresent(
        _scanCycleIndex,
        severityIndex: _severityToIndex(issue.severity),
      );
    }
    // Record absence for tracked issues not in current scan
    for (final entry in _recurrenceTrends.entries) {
      if (!currentIds.contains(entry.key)) {
        entry.value.recordAbsent(_scanCycleIndex);
      }
    }
    // Evict stale entries (unseen for 120+ cycles)
    _recurrenceTrends.removeWhere((_, trend) => trend.isStale(_scanCycleIndex));

    // Update fix baseline absence/presence tracking
    final baseline = _fixBaseline;
    if (baseline != null) {
      // Skip tracking during post-hot-reload grace period
      if (_postReassembleGraceCycles > 0) {
        _postReassembleGraceCycles--;
        return;
      }
      for (final id in baseline.issueSnapshots.keys) {
        if (currentIds.contains(id)) {
          baseline.recordPresence(id);
        } else {
          baseline.recordAbsence(id);
        }
      }
    }
  }

  static int _severityToIndex(IssueSeverity s) => switch (s) {
        IssueSeverity.critical => 3,
        IssueSeverity.warning => 2,
        IssueSeverity.ok => 1,
      };

  List<PerformanceIssue> _getAllIssues() {
    if (_cachedIssueGeneration == _issueGeneration &&
        _cachedAllIssues != null) {
      return _cachedAllIssues!;
    }
    _cachedAllIssues = [for (final d in _detectors) ...d.issues];
    _cachedIssueGeneration = _issueGeneration;
    return _cachedAllIssues!;
  }

  // -- Debug instrumentation helpers --

  void _installDebugInstrumentation() {
    assert(() {
      if (config.enableDebugCallbacks) {
        final adv = config.advanced ?? const DebugInstrumentationConfig();
        _debugCoordinator = DebugInstrumentationCoordinator(
          maxTrackedTypes: config.maxTrackedTypes,
          installRebuild: adv.rebuildAttribution,
          installPaint: adv.paintAttribution,
        );
        _debugCoordinator!.install();
      }
      // Independent from enableDebugCallbacks.
      if (config.enableDeepDebugInstrumentation) {
        _installHeavyFlags();
      }
      return true;
    }());
  }

  void _installHeavyFlags() {
    final adv = config.advanced ?? const DebugInstrumentationConfig();
    if (adv.widgetBuildProfiling) {
      _prevProfileBuildsEnabled = debugProfileBuildsEnabledUserWidgets;
      debugProfileBuildsEnabledUserWidgets = true;
    }
    if (adv.layoutProfiling) {
      _prevProfileLayoutsEnabled = debugProfileLayoutsEnabled;
      debugProfileLayoutsEnabled = true;
    }
    if (adv.paintProfiling) {
      _prevProfilePaintsEnabled = debugProfilePaintsEnabled;
      debugProfilePaintsEnabled = true;
    }
    if (adv.timelineEnrichment) {
      _prevEnhanceBuildArgs = debugEnhanceBuildTimelineArguments;
      _prevEnhanceLayoutArgs = debugEnhanceLayoutTimelineArguments;
      _prevEnhancePaintArgs = debugEnhancePaintTimelineArguments;
      debugEnhanceBuildTimelineArguments = true;
      debugEnhanceLayoutTimelineArguments = true;
      debugEnhancePaintTimelineArguments = true;
    }
  }

  void _restoreHeavyFlags() {
    if (_prevProfileBuildsEnabled != null) {
      debugProfileBuildsEnabledUserWidgets = _prevProfileBuildsEnabled!;
      _prevProfileBuildsEnabled = null;
    }
    if (_prevProfileLayoutsEnabled != null) {
      debugProfileLayoutsEnabled = _prevProfileLayoutsEnabled!;
      _prevProfileLayoutsEnabled = null;
    }
    if (_prevProfilePaintsEnabled != null) {
      debugProfilePaintsEnabled = _prevProfilePaintsEnabled!;
      _prevProfilePaintsEnabled = null;
    }
    if (_prevEnhanceBuildArgs != null) {
      debugEnhanceBuildTimelineArguments = _prevEnhanceBuildArgs!;
      _prevEnhanceBuildArgs = null;
    }
    if (_prevEnhanceLayoutArgs != null) {
      debugEnhanceLayoutTimelineArguments = _prevEnhanceLayoutArgs!;
      _prevEnhanceLayoutArgs = null;
    }
    if (_prevEnhancePaintArgs != null) {
      debugEnhancePaintTimelineArguments = _prevEnhancePaintArgs!;
      _prevEnhancePaintArgs = null;
    }
  }

  /// Dispose all resources.
  void dispose() {
    _disposed = true;
    _treeScanTimer?.cancel();
    _scrollIdleTimer?.cancel();
    _typingIdleTimer?.cancel();
    _backgroundReconnectTimer?.cancel();
    _backgroundReconnectTimer = null;
    _backgroundReconnectActive = false;
    _overlayContext = null;
    _lastScanContext = null;
    _appChildContext = null;
    _recurrenceTrends.clear();
    _captureBuffer.clear();
    _phaseEventBuffer.clear();
    _gcEventBuffer.clear();
    _platformChannelBuffer.clear();
    _themeOverride.dispose();

    // Restore HttpOverrides before disposing detector
    if (_httpOverrides != null) {
      SleuthHttpOverrides.uninstall(_httpOverrides!);
      _httpOverrides = null;
    }

    assert(() {
      _debugCoordinator?.dispose();
      _debugCoordinator = null;
      _restoreHeavyFlags();
      return true;
    }());

    _vmClient?.dispose();
    if (_detectorsReady) {
      for (final d in _detectors) {
        d.dispose();
      }
    }
    issuesNotifier.dispose();
    frameStatsNotifier.dispose();
    verdictNotifier.dispose();
    vmConnectedNotifier.dispose();
    highlightsNotifier.dispose();
    highlightEnabledNotifier.dispose();
    selectedHighlightNotifier.dispose();
    suppressedCountNotifier.dispose();
    routeHistoryNotifier.dispose();
  }
}

/// Configuration for [SleuthController].
class SleuthConfig {
  const SleuthConfig({
    this.theme,
    this.fpsTarget = 60,
    this.rebuildThreshold = 10,
    this.maxListChildren = 50,
    this.maxGlobalKeys = 20,
    this.platformChannelLimit = 20,
    this.treeScanInterval = const Duration(seconds: 1),
    this.adaptiveScanEnabled = true,
    this.enabledDetectors = const {...DetectorType.values},
    this.captureBufferCapacity = 50,
    this.enableDebugCallbacks = false,
    this.enableDeepDebugInstrumentation = false,
    this.maxTrackedTypes = 200,
    this.advanced,
    this.enableNetworkMonitoring = true,
    this.slowRequestThresholdMs = 2000,
    this.requestFrequencyLimit = 30,
    this.largeResponseThresholdBytes = 1048576,
    this.networkExcludePatterns,
    this.memoryWarmupDurationMs = 3000,
    this.frameTimingWarmupFrameCount = 180,
    this.platformChannelDurationThresholdMs = 8,
    this.suppressedIssues = const {},
    this.customDetectors = const [],
    this.disabledCustomDetectorKeys = const {},
    this.thresholds = const DetectorThresholds(),
    this.aiChat,
    this.showDebugModeBanner = true,
    this.triggerButtonAlignment = Alignment.topRight,
    this.triggerButtonOffset = const Offset(16, 64),
    this.routeIgnorePatterns = const {},
    this.routeHistoryCapacity = 50,
  })  : assert(
          fpsTarget >= 1 && fpsTarget <= 120,
          'fpsTarget must be between 1 and 120. '
          'Common values: 60, 90, 120.',
        ),
        assert(
          rebuildThreshold >= 1,
          'rebuildThreshold must be at least 1. To disable rebuild '
          'detection entirely, exclude DetectorType.rebuild from '
          'enabledDetectors instead.',
        ),
        assert(
          maxListChildren >= 1,
          'maxListChildren must be at least 1.',
        ),
        assert(
          maxGlobalKeys >= 1,
          'maxGlobalKeys must be at least 1.',
        ),
        assert(
          platformChannelLimit >= 1,
          'platformChannelLimit must be at least 1.',
        ),
        // Note: `treeScanInterval > Duration.zero` cannot be asserted in a
        // const constructor (Duration operators are not const-evaluable).
        // Runtime validation lives in the [SleuthController] constructor
        // body and fires with the same intent.
        assert(
          captureBufferCapacity >= 0,
          'captureBufferCapacity must be >= 0. Use 0 to disable the buffer.',
        ),
        assert(
          maxTrackedTypes >= 1,
          'maxTrackedTypes must be at least 1.',
        ),
        assert(
          slowRequestThresholdMs >= 0,
          'slowRequestThresholdMs must be >= 0.',
        ),
        assert(
          requestFrequencyLimit >= 1,
          'requestFrequencyLimit must be at least 1.',
        ),
        assert(
          largeResponseThresholdBytes >= 0,
          'largeResponseThresholdBytes must be >= 0.',
        ),
        assert(
          memoryWarmupDurationMs >= 0,
          'memoryWarmupDurationMs must be >= 0.',
        ),
        assert(
          frameTimingWarmupFrameCount >= 0,
          'frameTimingWarmupFrameCount must be >= 0. '
          'Set to 0 in tests to disable warmup suppression.',
        ),
        assert(
          platformChannelDurationThresholdMs >= 0,
          'platformChannelDurationThresholdMs must be >= 0.',
        ),
        assert(
          routeHistoryCapacity >= 1,
          'routeHistoryCapacity must be at least 1.',
        );

  /// Minimal configuration for first-time integration.
  ///
  /// Enables the safe structural and runtime detectors (frame timing,
  /// rebuild, repaint, listview, image memory, global key, layout
  /// bottleneck, opacity, animated builder, custom painter, font loading,
  /// repaint boundary). Disables network monitoring, debug callbacks,
  /// deep instrumentation, and AI chat — those are opt-in because they
  /// have setup or runtime cost.
  ///
  /// Use this when you're trying Sleuth for the first time and don't
  /// want to read 25 parameter docs.
  ///
  factory SleuthConfig.minimal({SleuthThemeData? theme}) => SleuthConfig(
        theme: theme,
        enableNetworkMonitoring: false,
        enableDebugCallbacks: false,
        enableDeepDebugInstrumentation: false,
        enabledDetectors: const {
          DetectorType.frameTiming,
          DetectorType.rebuild,
          DetectorType.repaint,
          DetectorType.listview,
          DetectorType.imageMemory,
          DetectorType.globalKey,
          DetectorType.layoutBottleneck,
          DetectorType.opacity,
          DetectorType.animatedBuilder,
          DetectorType.customPainter,
          DetectorType.fontLoading,
          DetectorType.repaintBoundary,
          DetectorType.startup,
        },
      );

  /// Configuration optimized for low-overhead profiling runs.
  ///
  /// Uses structural-lifecycle detectors only (no debug callbacks, no
  /// VM-only detectors), backs off the scan interval to 2 s, and shrinks
  /// the capture buffer. Suitable for CI runs or profile-mode sessions
  /// where you want to surface anti-patterns without paying for the full
  /// diagnostic pipeline.
  ///
  /// Intentionally EXCLUDED from the enabled set:
  /// - [DetectorType.shallowRebuildRisk] — this is a
  ///   [DetectorLifecycle.hybrid] detector (reads VM timeline data), so
  ///   it does NOT belong in a structural-only preset despite the name.
  /// - [DetectorType.frameTiming] — runtime lifecycle.
  ///
  factory SleuthConfig.performance({SleuthThemeData? theme}) => SleuthConfig(
        theme: theme,
        treeScanInterval: const Duration(seconds: 2),
        adaptiveScanEnabled: true,
        captureBufferCapacity: 10,
        enableNetworkMonitoring: false,
        enableDebugCallbacks: false,
        enableDeepDebugInstrumentation: false,
        enabledDetectors: const {
          // Every structural-lifecycle detector. Verified against the
          // lifecycle fields of each detector file.
          DetectorType.listview,
          DetectorType.imageMemory,
          DetectorType.globalKey,
          DetectorType.nestedScroll,
          DetectorType.opacity,
          DetectorType.animatedBuilder,
          DetectorType.customPainter,
          DetectorType.layoutBottleneck,
          DetectorType.fontLoading,
          DetectorType.repaintBoundary,
          DetectorType.setStateScope,
          DetectorType.keepAlive,
          DetectorType.startup,
        },
      );

  /// Custom theme for the overlay UI.
  ///
  /// When null (default), the overlay auto-selects dark or light based on
  /// [MediaQuery.platformBrightness]. If no [MediaQuery] is available
  /// (rare), defaults to dark.
  ///
  /// ```dart
  /// // Force light theme
  /// SleuthConfig(theme: SleuthThemeData.light())
  ///
  /// // Light theme with custom severity colors
  /// SleuthConfig(
  ///   theme: SleuthThemeData.light().copyWith(
  ///     severityCritical: Color(0xFFDC2626),
  ///   ),
  /// )
  /// ```
  final SleuthThemeData? theme;

  /// Target frames per second. Drives the frame-budget math that every
  /// jank detector uses.
  ///
  /// **Default:** 60. Most Android and iOS devices run at 60 Hz by default;
  /// 60 FPS maps to a 16.67 ms budget per frame, which is what the
  /// [FrameTimingDetector] compares against.
  ///
  /// **Raise this** to 90 or 120 on high-refresh displays (most flagship
  /// phones from 2020+). That tightens the frame budget to 11.1 ms (90 Hz)
  /// or 8.33 ms (120 Hz) and will surface jank that was invisible at 60.
  ///
  /// **Lower this** (e.g. 30) for splash screens or idle modes where 30 FPS
  /// is an explicit product decision — otherwise the detector will pad
  /// every normal-speed frame as "jank."
  ///
  /// Valid range: 1–120 (enforced via debug-mode assert).
  final int fpsTarget;

  /// Widget rebuilds per second above which [RebuildDetector] fires.
  ///
  /// **Default:** 10 rebuilds/sec. A healthy reactive UI on a 60 FPS app
  /// does not rebuild a given widget more than once every ~6 frames —
  /// anything above that is almost always wasted work.
  ///
  /// **Raise this** if your app legitimately has high-frequency UI (live
  /// charts, game HUDs, video overlays) and you're getting noisy false
  /// positives. Try 30 first; values above 60 effectively disable the
  /// detector for most widgets on 60 Hz devices.
  ///
  /// **Lower this** (e.g. 5) during a focused performance pass. Expect
  /// more flagged widgets — `StreamBuilder`/`FutureBuilder` doing their
  /// designed job will surface, so pair with
  /// `suppressedIssues: {'rebuild_debug_StreamBuilder'}` if needed.
  final int rebuildThreshold;

  /// Maximum children in a non-lazy list/grid before [ListviewDetector]
  /// and [NestedScrollDetector] fire.
  ///
  /// **Default:** 50. This is the empirical cutoff where Flutter's lazy
  /// builder-based widgets (`ListView.builder`, `GridView.builder`) clearly
  /// beat their eager counterparts — below 50 the framework overhead of
  /// lazy realisation can cost more than it saves.
  ///
  /// **Raise this** if you're intentionally building many small static
  /// rows (e.g. settings screens with ~60 rows) and don't want the lint.
  /// Values above 200 effectively disable the detector for normal UIs.
  ///
  /// **Lower this** (e.g. 20) to enforce strict lazy-list hygiene. Many
  /// fixed-size "chip row" patterns will get flagged — consider whether
  /// the false-positive rate is worth the stricter guard.
  final int maxListChildren;

  /// Maximum [GlobalKey]s in list/grid/page scopes before
  /// [GlobalKeyDetector] fires the **excessive** branch.
  ///
  /// **Default:** 20. GlobalKey allocation in a scrollable is almost
  /// always a smell — scrollables realise items lazily, so stable identity
  /// across rebuilds usually belongs on the item model, not the widget.
  ///
  /// **Raise this** (e.g. 50) if your scrollable genuinely needs many
  /// keyed items for animation state preservation.
  ///
  /// **Lower this** (e.g. 10) for stricter GlobalKey hygiene.
  ///
  /// This threshold governs the **excessive** branch only. The
  /// **recreation** branch (GlobalKey churn across rebuilds) is gated on
  /// a separate internal threshold of 5.
  final int maxGlobalKeys;

  /// Maximum platform channel calls per second before
  /// [PlatformChannelDetector] fires on call-count alone.
  ///
  /// **Default:** 20 calls/sec. Platform channels serialise through the
  /// binary messenger and cross the Dart/native boundary; 20/sec is the
  /// point where aggregated marshalling starts to dominate a frame.
  ///
  /// **Raise this** for apps that legitimately stream data through a
  /// custom channel (e.g. sensor polling, video pipelines).
  ///
  /// **Lower this** (e.g. 10) to catch misuse earlier during development.
  ///
  /// The cumulative-duration gate ([platformChannelDurationThresholdMs])
  /// fires independently of the per-second count.
  final int platformChannelLimit;

  /// Interval between widget tree scans.
  ///
  /// **Default:** 1 second. A full scan on a ~5 K-element tree costs
  /// ~2 ms, so a 1 s interval is well below 1% of frame budget.
  ///
  /// **Raise this** (e.g. `Duration(seconds: 5)`) for low-overhead
  /// profiling runs. Structural detectors will be slower to react to
  /// anti-patterns that appear and disappear, but cumulative cost drops
  /// linearly.
  ///
  /// **Lower this** (e.g. `Duration(milliseconds: 500)`) only if you're
  /// chasing a specific transient bug — the savings from adaptive backoff
  /// usually make this unnecessary.
  ///
  /// Must be strictly greater than [Duration.zero] (enforced via
  /// debug-mode assert).
  final Duration treeScanInterval;

  /// Whether to back off the scan interval when no issues are detected.
  ///
  /// **Default:** true. When enabled, the controller doubles the scan
  /// interval (capped at 2 s) after 3 consecutive clean scan cycles, and
  /// returns to the normal interval immediately when issues appear.
  /// [FrameTimingDetector] and VM timeline paths are event-driven and
  /// unaffected.
  ///
  /// **Disable** only when you're measuring detector overhead itself and
  /// need a constant scan cadence.
  final bool adaptiveScanEnabled;

  /// Which detectors are active. Defaults to all [DetectorType] values.
  ///
  /// Only detectors whose type is in this set are constructed and
  /// scheduled. Use this to disable detectors at init time (vs. runtime
  /// toggle via `controller.disableDetector`).
  final Set<DetectorType> enabledDetectors;

  /// Maximum number of jank frames to retain in the capture buffer.
  ///
  /// **Default:** 50. Each entry holds a frame snapshot (timings +
  /// phase breakdown) at roughly a few KB, so 50 entries = ~250 KB.
  ///
  /// **Raise this** if you want a longer scrollback in the UI capture
  /// panel. **Lower this** (or set to 0) for memory-constrained devices.
  final int captureBufferCapacity;

  /// Enables debug-only rebuild/repaint attribution hooks.
  ///
  /// **Default:** false. When true, Sleuth registers widget-rebuild and
  /// repaint callbacks via `debugOnRebuildDirtyWidget` /
  /// `debugOnProfilePaint`.
  ///
  /// **WARNING:** Conflicts with DevTools "Track Widget Rebuilds" — only
  /// one can own these hooks at a time. Default false to avoid surprising
  /// DevTools users who leave Sleuth wired in permanently.
  final bool enableDebugCallbacks;

  /// Enables heavy debug flags independently of [enableDebugCallbacks].
  ///
  /// **Default:** false. Adds per-widget timeline events via
  /// `debugProfileBuildsEnabled` and related flags. Measurable overhead
  /// (~5–10% extra frame time on heavy scenes) — use sparingly.
  final bool enableDeepDebugInstrumentation;

  /// Maximum widget types to track in rebuild counters.
  ///
  /// **Default:** 200. Prevents unbounded memory in apps with thousands
  /// of distinct widget types (generated code, per-item generics).
  /// Beyond this cap, new types are dropped rather than evicting old
  /// ones.
  ///
  /// **Raise this** if you have a legitimately large type universe.
  /// **Lower this** if memory is tight and you only care about the hot
  /// types.
  final int maxTrackedTypes;

  /// Advanced sub-flag configuration for debug instrumentation.
  ///
  /// When null, equivalent to `const DebugInstrumentationConfig()` (all
  /// defaults). Sub-flags only take effect when their parent switch
  /// ([enableDebugCallbacks] or [enableDeepDebugInstrumentation]) is
  /// enabled.
  final DebugInstrumentationConfig? advanced;

  /// Master switch for HTTP network monitoring.
  ///
  /// **Default:** true. When true AND [DetectorType.networkMonitor] is
  /// in [enabledDetectors], installs an [HttpOverrides] proxy that
  /// records request timing and size.
  ///
  /// **Disable** when another library already owns `HttpOverrides.global`
  /// (common in apps that use a custom HTTP proxy or mock layer).
  final bool enableNetworkMonitoring;

  /// Slow request detection threshold in milliseconds.
  ///
  /// **Default:** 2000 ms. Anything slower than 2 s feels broken to a
  /// user and latches network jank detection.
  ///
  /// **Raise this** (e.g. 5000) if your app intentionally does long
  /// uploads/downloads. **Lower this** (e.g. 500) during a latency
  /// audit.
  final int slowRequestThresholdMs;

  /// Maximum HTTP requests allowed per 5-second window.
  ///
  /// **Default:** 30. The window is rolling — every 5 s the counter
  /// resets. Above 30/window, the detector fires a "chatty network"
  /// warning.
  ///
  /// **Raise this** for apps with legitimately heavy API usage.
  /// **Lower this** (e.g. 10) to enforce stricter network hygiene.
  final int requestFrequencyLimit;

  /// Large response detection threshold in bytes.
  ///
  /// **Default:** 1 MB (1,048,576). Responses larger than this incur
  /// JSON-decode cost that typically dominates the request pipeline,
  /// so the detector suggests paginating or streaming.
  ///
  /// **Raise this** (e.g. 5 MB) for apps that legitimately ship large
  /// payloads (media manifests, offline catalogs).
  final int largeResponseThresholdBytes;

  /// URL substring patterns to exclude from network monitoring
  /// (e.g. `['/analytics', 'crashlytics']`).
  ///
  /// Matched as substrings against the full URI string. Use this to
  /// prevent third-party telemetry from dominating the network panel.
  final List<String>? networkExcludePatterns;

  /// Duration in milliseconds to suppress heap growth alerts after the
  /// first heap sample.
  ///
  /// **Default:** 3000 ms. Normal app startup allocates aggressively as
  /// the framework, fonts, and initial screens load; without warmup
  /// suppression almost every session would false-fire.
  ///
  /// **Raise this** if your cold-start allocation is unusually spiky.
  /// **Lower this** (or 0) in tests where you want deterministic
  /// allocation tracking from sample zero.
  final int memoryWarmupDurationMs;

  /// Number of frames to suppress frame-timing jank evaluation at
  /// startup.
  ///
  /// **Default:** 180. At 60 FPS that's ~3 s — long enough to cover
  /// splash screens, first-frame shader warmups, and initial image
  /// decodes that would otherwise dominate a session's "jank" count.
  ///
  /// **Set to 0** in tests to disable warmup suppression entirely.
  final int frameTimingWarmupFrameCount;

  /// Cumulative platform channel duration threshold in milliseconds per
  /// window.
  ///
  /// **Default:** 8 ms (half a 16 ms frame budget). Fires even when the
  /// per-second call count ([platformChannelLimit]) is low, because a
  /// handful of slow channel calls can still blow a frame.
  ///
  /// **Raise this** (e.g. 16) for apps with a single legitimate
  /// synchronous channel call per frame.
  final int platformChannelDurationThresholdMs;

  /// StableId patterns to suppress from the issue list.
  ///
  /// Exact strings match directly (e.g. `'opacity_zero'`).
  /// Trailing `*` matches any stableId starting with the prefix
  /// (e.g. `'rebuild_debug_*'` suppresses `rebuild_debug_MyWidget`,
  /// `rebuild_debug_Text`, etc.).
  ///
  /// Suppressed issues still participate in inter-detector correlation
  /// but are excluded from ranking and UI display.
  final Set<String> suppressedIssues;

  /// Custom detectors to integrate into the scan/aggregation pipeline.
  ///
  /// Each detector extends [BaseDetector] and declares its [DetectorLifecycle].
  /// The controller routes data to custom detectors based on their lifecycle
  /// exactly like built-in detectors: structural → [scanTree],
  /// vmOnly → [processTimelineData], hybrid → both.
  ///
  /// Custom detectors whose [BaseDetector.key] is in
  /// [disabledCustomDetectorKeys] are constructed but start with
  /// `isEnabled == false`. Detectors with `key == null` are always enabled
  /// (they cannot be gated via config — that's the opt-out signal).
  /// The controller disposes custom detectors when it is itself disposed.
  final List<BaseDetector> customDetectors;

  /// Stable keys of custom detectors that should start disabled.
  ///
  /// **Default:** empty set. Custom detectors set their
  /// [BaseDetector.key] to a unique string (e.g. `'tooltip_usage'`). To
  /// disable one without removing it from [customDetectors], add its key
  /// to this set.
  ///
  /// **Semantics:**
  /// - **Null-key = opt-out.** Custom detectors with `key == null` are
  ///   always enabled and cannot be gated via this set. Null is the
  ///   "I don't want to participate in config-driven gating" signal.
  /// - **Init-time-only.** The gate applies exactly once, inside
  ///   `SleuthController._initializeDetectors()`. After init, runtime
  ///   flips of `detector.isEnabled = true` override the config.
  /// - **Key collision = all-affected.** If two custom detectors share a
  ///   key and that key is in the disabled set, both detectors are
  ///   disabled. Keys should be unique per logical detector.
  ///
  /// Built-in detectors are not affected by this set — use
  /// [enabledDetectors] for those.
  final Set<String> disabledCustomDetectorKeys;

  /// Detector-specific thresholds for fine-tuning performance detection.
  /// See [DetectorThresholds] for available parameters and defaults.
  final DetectorThresholds thresholds;

  /// Optional AI chat adapter. When provided, an "Ask AI" button appears on
  /// issue cards, enabling contextual AI conversations about specific issues.
  ///
  /// Use a built-in factory for zero-config setup:
  /// ```dart
  /// SleuthConfig(
  ///   aiChat: AiChatAdapter.anthropic(apiKey: myKey),
  /// )
  /// ```
  ///
  /// Built-in adapters automatically exclude their provider URLs from
  /// network monitoring. For custom adapters, set
  /// [AiChatAdapter.networkExcludePatterns] or add patterns to
  /// [networkExcludePatterns] manually.
  final AiChatAdapter? aiChat;

  /// Whether the floating card shows a "debug mode is slower" banner when
  /// running in debug mode. Defaults to `true`. Set to `false` if you have
  /// a good reason to debug with the overlay (e.g. hot-restart iteration).
  ///
  /// Default: `true` — shows the banner whenever `kDebugMode` is true.
  /// Raising it: N/A (boolean).
  /// Lowering it (false): suppresses the banner entirely.
  final bool showDebugModeBanner;

  /// Initial screen corner for the trigger button. Default [Alignment.topRight]
  /// matches the pre-Part-2 behaviour. Any standard alignment is accepted;
  /// non-corner alignments snap to the nearest edge.
  ///
  /// Users can still drag the button anywhere — this controls only where it
  /// first appears before the user has dragged it.
  ///
  /// Default: `Alignment.topRight`.
  final Alignment triggerButtonAlignment;

  /// Pixel offset applied after [triggerButtonAlignment]. Positive X pushes the
  /// button inward horizontally, positive Y pushes it inward vertically. Use
  /// this to clear an app-owned widget (e.g. a FAB at the bottom-right).
  ///
  /// Default: `Offset(16, 64)` — 16 px from the horizontal edge, 64 px below
  /// the top safe area / above the bottom safe area.
  final Offset triggerButtonOffset;

  /// Route name patterns to exclude from route session tracking.
  ///
  /// Supports exact match and trailing `*` wildcard (e.g. `/dialog*` matches
  /// `/dialog`, `/dialogConfirm`, etc.). Routes matching these patterns still
  /// trigger detector clearing (network, SetState), but no [RouteSession] is
  /// created.
  ///
  /// **Default:** empty (all routes tracked).
  final Set<String> routeIgnorePatterns;

  /// Maximum number of route sessions retained in the ring buffer.
  ///
  /// **Default:** 50 (raised from 20 in v0.14.1 to accommodate per-tab
  /// session tracking — bottom-nav apps using `IndexedStack` /
  /// `StatefulShellRoute.indexedStack` / `CupertinoTabScaffold` now produce
  /// one session per tab visit rather than one per route name, so a 5-tab
  /// app with moderate switching exhausts a 20-cap within a few minutes).
  ///
  /// At 50 sessions × ~60 frames × ~200 B per frame, the frame-data footprint
  /// is bounded to ~600 KB.
  ///
  /// **Raise this** if your app has many short-lived routes and you want to
  /// keep a longer history.
  ///
  /// **Lower this** (minimum 1) to save memory in constrained environments.
  ///
  /// Valid range: >= 1 (enforced via debug-mode assert).
  final int routeHistoryCapacity;

  /// Sentinel used by [copyWith] to distinguish "not passed" from "set to null".
  static const Object _sentinel = Object();

  /// Returns a copy of this config with the given fields replaced.
  ///
  /// For nullable fields ([theme], [advanced], [networkExcludePatterns],
  /// [aiChat]), pass the explicit value to override — including `null` to
  /// clear. Fields not passed retain their current value.
  ///
  /// ```dart
  /// final custom = SleuthConfig.minimal().copyWith(
  ///   fpsTarget: 120,
  ///   aiChat: AiChatAdapter.openAi(apiKey: 'ollama', baseUrl: '...'),
  /// );
  /// ```
  SleuthConfig copyWith({
    Object? theme = _sentinel,
    int? fpsTarget,
    int? rebuildThreshold,
    int? maxListChildren,
    int? maxGlobalKeys,
    int? platformChannelLimit,
    Duration? treeScanInterval,
    bool? adaptiveScanEnabled,
    Set<DetectorType>? enabledDetectors,
    int? captureBufferCapacity,
    bool? enableDebugCallbacks,
    bool? enableDeepDebugInstrumentation,
    int? maxTrackedTypes,
    Object? advanced = _sentinel,
    bool? enableNetworkMonitoring,
    int? slowRequestThresholdMs,
    int? requestFrequencyLimit,
    int? largeResponseThresholdBytes,
    Object? networkExcludePatterns = _sentinel,
    int? memoryWarmupDurationMs,
    int? frameTimingWarmupFrameCount,
    int? platformChannelDurationThresholdMs,
    Set<String>? suppressedIssues,
    List<BaseDetector>? customDetectors,
    Set<String>? disabledCustomDetectorKeys,
    DetectorThresholds? thresholds,
    Object? aiChat = _sentinel,
    bool? showDebugModeBanner,
    Alignment? triggerButtonAlignment,
    Offset? triggerButtonOffset,
    Set<String>? routeIgnorePatterns,
    int? routeHistoryCapacity,
  }) {
    return SleuthConfig(
      theme:
          identical(theme, _sentinel) ? this.theme : theme as SleuthThemeData?,
      fpsTarget: fpsTarget ?? this.fpsTarget,
      rebuildThreshold: rebuildThreshold ?? this.rebuildThreshold,
      maxListChildren: maxListChildren ?? this.maxListChildren,
      maxGlobalKeys: maxGlobalKeys ?? this.maxGlobalKeys,
      platformChannelLimit: platformChannelLimit ?? this.platformChannelLimit,
      treeScanInterval: treeScanInterval ?? this.treeScanInterval,
      adaptiveScanEnabled: adaptiveScanEnabled ?? this.adaptiveScanEnabled,
      enabledDetectors: enabledDetectors ?? this.enabledDetectors,
      captureBufferCapacity:
          captureBufferCapacity ?? this.captureBufferCapacity,
      enableDebugCallbacks: enableDebugCallbacks ?? this.enableDebugCallbacks,
      enableDeepDebugInstrumentation:
          enableDeepDebugInstrumentation ?? this.enableDeepDebugInstrumentation,
      maxTrackedTypes: maxTrackedTypes ?? this.maxTrackedTypes,
      advanced: identical(advanced, _sentinel)
          ? this.advanced
          : advanced as DebugInstrumentationConfig?,
      enableNetworkMonitoring:
          enableNetworkMonitoring ?? this.enableNetworkMonitoring,
      slowRequestThresholdMs:
          slowRequestThresholdMs ?? this.slowRequestThresholdMs,
      requestFrequencyLimit:
          requestFrequencyLimit ?? this.requestFrequencyLimit,
      largeResponseThresholdBytes:
          largeResponseThresholdBytes ?? this.largeResponseThresholdBytes,
      networkExcludePatterns: identical(networkExcludePatterns, _sentinel)
          ? this.networkExcludePatterns
          : networkExcludePatterns as List<String>?,
      memoryWarmupDurationMs:
          memoryWarmupDurationMs ?? this.memoryWarmupDurationMs,
      frameTimingWarmupFrameCount:
          frameTimingWarmupFrameCount ?? this.frameTimingWarmupFrameCount,
      platformChannelDurationThresholdMs: platformChannelDurationThresholdMs ??
          this.platformChannelDurationThresholdMs,
      suppressedIssues: suppressedIssues ?? this.suppressedIssues,
      customDetectors: customDetectors ?? this.customDetectors,
      disabledCustomDetectorKeys:
          disabledCustomDetectorKeys ?? this.disabledCustomDetectorKeys,
      thresholds: thresholds ?? this.thresholds,
      aiChat:
          identical(aiChat, _sentinel) ? this.aiChat : aiChat as AiChatAdapter?,
      showDebugModeBanner: showDebugModeBanner ?? this.showDebugModeBanner,
      triggerButtonAlignment:
          triggerButtonAlignment ?? this.triggerButtonAlignment,
      triggerButtonOffset: triggerButtonOffset ?? this.triggerButtonOffset,
      routeIgnorePatterns: routeIgnorePatterns ?? this.routeIgnorePatterns,
      routeHistoryCapacity: routeHistoryCapacity ?? this.routeHistoryCapacity,
    );
  }
}

/// Lightweight struct for sorting allocation profile entries.
class _AllocStat {
  _AllocStat(this.name, this.lib, this.instances, this.bytes);
  final String name;
  final String lib;
  final int instances;
  final int bytes;
}
