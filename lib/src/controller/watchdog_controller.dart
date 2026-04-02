import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:vm_service/vm_service.dart' show AllocationProfile, Event;

import '../ui/watchdog_theme.dart';
import '../analyzer/detector_correlator.dart';
import '../analyzer/frame_event_correlator.dart';
import '../analyzer/render_pipeline_analyzer.dart';
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
import '../models/session_snapshot.dart';
import '../models/widget_highlight.dart';
import '../network/http_monitor.dart';
import '../ranking/issue_ranker.dart';
import '../vm/cpu_sample_aggregator.dart';
import '../vm/vm_service_client.dart';
import '../vm/timeline_parser.dart';

/// Central controller aggregating all detectors and the pipeline analyzer.
class WatchdogController {
  WatchdogController({WatchdogConfig? config})
      : config = config ?? const WatchdogConfig(),
        _captureBuffer = JankCaptureBuffer(
          capacity: (config ?? const WatchdogConfig()).captureBufferCapacity,
        ) {
    _compileSuppressions();
  }

  final WatchdogConfig config;

  // Precompiled suppression patterns (v6.15).
  late final Set<String> _exactSuppressions;
  late final List<String> _prefixSuppressions;

  // Capture buffer — eager init so exportSnapshot() is safe before initialize()
  final JankCaptureBuffer _captureBuffer;
  int _lastCapturedFrameNumber = -1;

  // VM layer
  VmServiceClient? _vmClient;

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
  WatchdogHttpOverrides? _httpOverrides;

  // Ranking & correlation
  final DetectorCorrelator _detectorCorrelator = const DetectorCorrelator();
  final IssueRanker _ranker = const IssueRanker();
  final Map<String, int> _recurrenceCounts = {};

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

  // Allocation enrichment
  DateTime? _lastAllocationEnrichmentTime;

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
  final ValueNotifier<List<WidgetHighlight>> highlightsNotifier = ValueNotifier(
    [],
  );

  /// Whether the highlight overlay is active.
  final ValueNotifier<bool> highlightEnabledNotifier = ValueNotifier(false);

  /// The currently selected/focused highlight (from tapping an issue).
  final ValueNotifier<WidgetHighlight?> selectedHighlightNotifier =
      ValueNotifier(null);

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
    if (highlightsNotifier.value.isEmpty) {
      _collectHighlights();
    }
    final highlights = highlightsNotifier.value;
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

  /// Initialize all detectors and connect to VM service.
  Future<void> initialize() async {
    if (_initialized || kReleaseMode) return;

    _initializeDetectors();

    // Install HTTP monitoring proxy before any network requests start
    if (config.enableNetworkMonitoring &&
        config.enabledDetectors.contains(DetectorType.networkMonitor)) {
      _httpOverrides = WatchdogHttpOverrides(
        onRecord: _networkMonitor.processRecord,
        onRequestStarted: _networkMonitor.startRequest,
        onRequestEnded: _networkMonitor.endRequest,
        excludePatterns: config.networkExcludePatterns,
      );
      WatchdogHttpOverrides.install(_httpOverrides!);
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
    );
    _vmClient = client;

    final connected = await client.connect();
    vmConnectedNotifier.value = connected;
    _syncVmState(connected);

    _initialized = true;
  }

  void _initializeDetectors() {
    final enabled = config.enabledDetectors;

    _frameTiming = FrameTimingDetector(
      fpsTarget: config.fpsTarget,
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

    _detectors = [
      _frameTiming,
      ShaderJankDetector(
        thresholdMs: config.thresholds.shaderJankMs,
      )..isEnabled = enabled.contains(DetectorType.shaderJank),
      HeavyComputeDetector(
        lagThresholdMs: config.thresholds.heavyComputeGapMs,
      )..isEnabled = enabled.contains(DetectorType.heavyCompute),
      PlatformChannelDetector(
        callsPerSecThreshold: config.platformChannelLimit,
        durationThresholdUs: config.platformChannelDurationThresholdMs * 1000,
      )..isEnabled = enabled.contains(DetectorType.platformChannel),
      _memoryPressure,
      RepaintDetector()..isEnabled = enabled.contains(DetectorType.repaint),
      RebuildDetector(rebuildsPerSecThreshold: config.rebuildThreshold)
        ..isEnabled = enabled.contains(DetectorType.rebuild),
      SetStateScopeDetector(
        dirtyRatioThreshold: config.thresholds.setStateScopeOwnershipPercent,
      )..isEnabled = enabled.contains(DetectorType.setStateScope),
      GpuPressureDetector(
        rasterMultiplierThreshold: config.thresholds.gpuPressureRatio,
      )..isEnabled = enabled.contains(DetectorType.gpuPressure),
      ShallowRebuildRiskDetector(
        depthThreshold: config.thresholds.shallowRebuildMaxDepth,
      )..isEnabled = enabled.contains(DetectorType.shallowRebuildRisk),
      LayoutBottleneckDetector()
        ..isEnabled = enabled.contains(DetectorType.layoutBottleneck),
      ListviewDetector(childThreshold: config.maxListChildren)
        ..isEnabled = enabled.contains(DetectorType.listview),
      ImageMemoryDetector()
        ..isEnabled = enabled.contains(DetectorType.imageMemory),
      GlobalKeyDetector(threshold: config.maxGlobalKeys)
        ..isEnabled = enabled.contains(DetectorType.globalKey),
      NestedScrollDetector(childThreshold: config.maxListChildren)
        ..isEnabled = enabled.contains(DetectorType.nestedScroll),
      CustomPainterDetector()
        ..isEnabled = enabled.contains(DetectorType.customPainter),
      KeepAliveDetector(
        threshold: config.thresholds.keepAliveMax,
      )..isEnabled = enabled.contains(DetectorType.keepAlive),
      AnimatedBuilderDetector(
        minSubtreeSize: config.thresholds.animatedBuilderMinSubtreeSize,
      )..isEnabled = enabled.contains(DetectorType.animatedBuilder),
      OpacityDetector()..isEnabled = enabled.contains(DetectorType.opacity),
      FontLoadingDetector(
        maxFamilies: config.thresholds.fontLoadingMaxFamilies,
      )..isEnabled = enabled.contains(DetectorType.fontLoading),
      RepaintBoundaryDetector()
        ..isEnabled = enabled.contains(DetectorType.repaintBoundary),
      _networkMonitor,
      // Custom detectors — always enabled (explicitly opted-in via config)
      for (final d in config.customDetectors) d..isEnabled = true,
    ];
    _detectorsReady = true;
  }

  /// Initialize detectors without VM client or SchedulerBinding.
  @visibleForTesting
  void initializeDetectorsForTest() {
    _initializeDetectors();
    _installDebugInstrumentation();
  }

  /// Feed a synthetic frame into the controller's [FrameTimingDetector],
  /// triggering [_onFrameStats] and the fallback verdict path.
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  void addFrameForTest(FrameStats stats) => _frameTiming.addFrameForTest(stats);

  /// Exposes recurrence counts for testing ranking integration.
  @visibleForTesting
  Map<String, int> get recurrenceCountsForTest =>
      Map.unmodifiable(_recurrenceCounts);

  @visibleForTesting
  void runTreeScanForTest(BuildContext context) {
    _lastScanContext = context;
    _runStructuralScans(context);
    _collectHighlights();
    _aggregateIssues();
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

  /// Exposes capture buffer for testing.
  @visibleForTesting
  JankCaptureBuffer get captureBufferForTest => _captureBuffer;

  /// Feeds a heap sample through the same path as the VM service callback.
  @visibleForTesting
  void feedHeapSampleForTest(HeapSample sample) => _onHeapSample(sample);

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

    // Compute FPS percentiles at export time (lazy, not cached)
    final percentiles = buffer.length >= 2 ? buffer.fpsPercentiles() : null;

    // Attach ranking scores to issues (export-only, not on the hot path).
    // Before init, _frameTiming is not available — use default context.
    final rankingContext =
        _initialized ? _buildRankingContext() : const IssueRankingContext();
    final rankedWithScores = _ranker.rankWithScores(
      issuesNotifier.value,
      rankingContext,
    );

    return SessionSnapshot(
      schemaVersion: 2,
      exportedAt: DateTime.now(),
      capturedFrames: _captureBuffer.entries,
      currentIssues: List.unmodifiable(rankedWithScores),
      frameStatsSummary: FrameStatsSummary(
        totalFrames: buffer.length,
        jankFrames: buffer.jankCount,
        averageFps: buffer.averageFps,
        worstFrameTimeUs: worstUs,
        fpsPercentiles: percentiles,
      ),
      packageVersion: '0.5.2',
      isVmConnected: isVmConnected,
      isDebugMode: isDebugMode,
      recentRequests: _initialized &&
              _networkMonitor.isEnabled &&
              _networkMonitor.records.isNotEmpty
          ? _networkMonitor.records
          : null,
      heapSamples: _initialized && _memoryPressure.heapSamples.isNotEmpty
          ? _memoryPressure.heapSamples
          : null,
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
    );
  }

  /// Export session snapshot as a formatted JSON string.
  String exportSnapshotJson() => exportSnapshot().toJsonString();

  /// The overlay element — set by the overlay widget.
  BuildContext? _overlayContext;

  /// The last successfully resolved visible-page context from [_findVisiblePageContext].
  /// Used by [_currentRouteName] to stamp issues with the scanned page's route,
  /// not the overlay root. Cleared during route transitions to avoid stale stamps.
  BuildContext? _lastScanContext;

  /// Start periodic tree scanning. Call from widget with BuildContext.
  void startTreeScanning(BuildContext context) {
    _overlayContext = context;
    _treeScanTimer?.cancel();
    _treeScanTimer = Timer.periodic(
      Duration(milliseconds: config.treeScanIntervalMs),
      (_) {
        final ctx = _overlayContext;
        if (ctx != null) {
          final element = ctx as Element;
          if (element.mounted) {
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (element.mounted) _scanTree(ctx);
            });
          }
        }
      },
    );
  }

  void _scanTree(BuildContext context) {
    if (!_initialized || kReleaseMode) return;

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
      if (highlightsNotifier.value.isNotEmpty) {
        highlightsNotifier.value = [];
      }
      selectedHighlightNotifier.value = null;
      for (final d in _detectors) {
        if (d is SetStateScopeDetector) d.clearSnapshots();
      }
      return;
    }
    // Navigation complete — return to idle
    if (_interactionState == InteractionContext.navigating) {
      _interactionState = InteractionContext.idle;
    }
    _lastScanContext = scanContext;

    // Pass debug snapshot to detectors
    if (debugSnapshot != null) {
      for (final d in _detectors) {
        if (d.isEnabled) d.updateDebugSnapshot(debugSnapshot!);
      }
    }

    // Run all tree-scanning detectors
    _runStructuralScans(scanContext);

    // Aggregate and rank all issues
    _aggregateIssues();

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
    } else if (highlightsNotifier.value.isNotEmpty) {
      highlightsNotifier.value = [];
    }
  }

  BuildContext? _findVisiblePageContext(BuildContext root) {
    final scaffolds = <Element>[];

    void visitor(Element element) {
      final widget = element.widget;

      // Skip offstage subtrees — inactive Navigator routes
      if (widget is Offstage && widget.offstage) return;

      // Skip ticker-disabled subtrees — background Navigator routes
      if (widget is TickerMode && !widget.enabled) return;

      // Skip our own overlay widgets
      final name = widget.runtimeType.toString();
      if (name == 'FloatingIssuesCard' ||
          name == 'TriggerButton' ||
          name == 'HighlightOverlay') {
        return;
      }

      // Collect all visible Scaffolds
      if (name == 'Scaffold') {
        scaffolds.add(element);
      }

      element.visitChildren(visitor);
    }

    try {
      root.visitChildElements(visitor);
    } catch (_) {}

    if (scaffolds.isEmpty) return null;

    // Multiple visible Scaffolds = route transition in progress.
    // Return null so the caller skips scanning during transitions.
    if (scaffolds.length > 1) return null;

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

  /// Re-collect highlights using fresh screen rects (e.g. after scroll).
  ///
  /// Re-runs structural detector scans to get fresh rects, then
  /// aggregates highlights from all detectors.
  void refreshHighlights() {
    if (!highlightEnabledNotifier.value) return;
    if (_interactionState == InteractionContext.navigating) return;
    final ctx = _overlayContext;
    if (ctx == null) return;
    final element = ctx as Element;
    if (!element.mounted) return;
    final scanContext = _findVisiblePageContext(ctx) ?? ctx;
    _lastScanContext = scanContext;
    _runStructuralScans(scanContext);
    _collectHighlights();
  }

  /// Update interaction state from app scroll notifications.
  ///
  /// Called by the overlay's [NotificationListener] which is scoped to the
  /// app child only (not the dashboard). Scroll notifications from the
  /// watchdog UI are excluded.
  void onScrollActivity(ScrollNotification notification) {
    if (_interactionState == InteractionContext.navigating) return;
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
    for (final d in unified) {
      d.prepareScan(scanContext);
    }

    // Phase 2: Unified walk — O(N) instead of O(detectors × N)
    void visitor(Element element) {
      for (final d in unified) {
        d.checkElement(element);
      }
      element.visitChildren(visitor);
      for (final d in unified) {
        d.afterElement(element);
      }
    }

    bool walkCompleted = false;
    try {
      scanContext.visitChildElements(visitor);
      walkCompleted = true;
    } catch (_) {}

    // Phase 3: Finalization
    if (walkCompleted) {
      for (final d in unified) {
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
  }

  /// Aggregate highlights from all detectors that produce them.
  ///
  /// Detectors collect highlights during their scanTree() calls.
  /// This method just gathers them — no tree walking or re-detection.
  void _collectHighlights() {
    highlightsNotifier.value = [for (final d in _detectors) ...d.highlights];
  }

  void _onTimelineData(ParsedTimelineData data) {
    // FrameTimingDetector uses custom method (not processTimelineData)
    _frameTiming.updateTimelineData(data);

    // Feed timeline data to vmOnly and hybrid detectors
    for (final d in _detectors) {
      if (d.isEnabled &&
          (d.lifecycle == DetectorLifecycle.vmOnly ||
              d.lifecycle == DetectorLifecycle.hybrid)) {
        d.processTimelineData(data);
      }
    }

    // Flush staged data so _getAllIssues() sees current state
    for (final d in _detectors) {
      if (d.isEnabled &&
          (d.lifecycle == DetectorLifecycle.vmOnly ||
              d.lifecycle == DetectorLifecycle.hybrid)) {
        d.evaluateNow();
      }
    }

    // Generate verdict for slow frames (full mode with VM timeline data)
    // Local variables bridge jank decision → post-aggregation capture.
    FrameStats? captureFrame;
    FrameVerdict? captureVerdict;

    // Try correlated mode first: match events to specific frames by timestamp.
    // Falls back to legacy full mode if correlation fails.
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
        return f.vsyncStartUs! < batchEndUs && f.rasterFinishUs! > batchStartUs;
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
        captureFrame = latest;
        captureVerdict = verdict;
      }
    }

    // frameStatsNotifier is already updated by _onFrameStats callback
    _aggregateIssues();

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
    frameStatsNotifier.value = FrameStatsBuffer.from(buffer);

    // Generate FRAME-mode verdict for jank frames when VM is not connected.
    final latest = buffer.latest;
    if (latest != null && latest.isJank && !isVmConnected) {
      verdictNotifier.value = _enrichVerdictWithNetworkContext(
        _analyzer.analyzeBasicMode(
          frameStats: latest,
          relatedIssues: _getAllIssues(),
        ),
      );

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
    // GC events are already counted via timeline data.
    // No fake empty signal needed — MemoryPressureDetector
    // evaluates only when real GC events arrive in timeline data.
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
        debugPrint('Watchdog: CPU attribution failed: $e');
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
        debugPrint('Watchdog: allocation enrichment failed: $e');
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
  }

  /// Propagate current VM connectivity to all detectors. Hybrid detectors
  /// degrade correctly on disconnect; others use the no-op default.
  void _syncVmState(bool connected) {
    for (final d in _detectors) {
      d.vmConnected = connected;
    }
  }

  String? _currentRouteName() {
    final ctx = _lastScanContext;
    if (ctx == null) return null;
    return ModalRoute.of(ctx)?.settings.name;
  }

  void _aggregateIssues() {
    final all = _getAllIssues();
    final correlated = _detectorCorrelator.correlate(all);
    final route = _currentRouteName();

    // Stamp debug disclaimer, route name, and interaction context.
    // For VM-only issues arriving via _onTimelineData, routeName reflects the
    // last successfully scanned page (best-effort, not real-time).
    // interactionContext reflects the current interaction state at stamp time.
    final stamped = correlated
        .map((i) => i.copyWith(
              debugModeDisclaimer: kDebugMode ? true : null,
              routeName: route,
              interactionContext: _interactionState,
            ))
        .toList();

    // ── v4.1: Suppress user-dismissed issues post-correlate, pre-rank ──
    final List<PerformanceIssue> visible;
    if (config.suppressedIssues.isEmpty) {
      visible = stamped;
      suppressedCountNotifier.value = 0;
    } else {
      visible = stamped
          .where((i) => !_matchesSuppression(i.stableId ?? i.title))
          .toList();
      suppressedCountNotifier.value = stamped.length - visible.length;
    }

    // Rank by impact: severity dominates, then frame impact, confidence,
    // recurrence. See IssueRanker for score formula and tier guarantees.
    final ranked = _ranker.rank(visible, _buildRankingContext());

    // IssueCard is a StatefulWidget with ValueKey(stableId), so expansion
    // state survives list rebuilds. Safe to always update the notifier —
    // titles with live counters (e.g. "45 GC/min") will reflect fresh data.
    issuesNotifier.value = ranked;
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
      // Derive phase from the latest janky frame — same approach as the
      // verdict paths. Reflects the current bottleneck.
      phase = latest.uiDuration > latest.rasterDuration
          ? PipelinePhase.build
          : PipelinePhase.raster;
    }
    // If jankActive but latest is not janky (sustained pattern, current
    // frame ok), phase stays null — all categories get equal partial boost.

    return IssueRankingContext(
      jankActive: jankActive,
      suspectedPhase: phase,
      recurrenceCounts: _recurrenceCounts,
    );
  }

  /// Increment recurrence for present issues, remove absent ones.
  /// Called only from the scan path to keep rates consistent across lifecycles.
  void _updateRecurrence(List<PerformanceIssue> currentIssues) {
    final currentIds = <String>{};
    for (final issue in currentIssues) {
      final id = issue.stableId ?? issue.title;
      currentIds.add(id);
      _recurrenceCounts[id] = (_recurrenceCounts[id] ?? 0) + 1;
    }
    _recurrenceCounts.removeWhere((id, _) => !currentIds.contains(id));
  }

  List<PerformanceIssue> _getAllIssues() {
    return [for (final d in _detectors) ...d.issues];
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
    _overlayContext = null;
    _lastScanContext = null;
    _recurrenceCounts.clear();
    _captureBuffer.clear();
    _phaseEventBuffer.clear();
    _gcEventBuffer.clear();
    _platformChannelBuffer.clear();

    // Restore HttpOverrides before disposing detector
    if (_httpOverrides != null) {
      WatchdogHttpOverrides.uninstall(_httpOverrides!);
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
  }
}

/// Configuration for [WatchdogController].
class WatchdogConfig {
  const WatchdogConfig({
    this.theme,
    this.fpsTarget = 60,
    this.rebuildThreshold = 10,
    this.maxListChildren = 50,
    this.maxGlobalKeys = 20,
    this.platformChannelLimit = 20,
    this.treeScanIntervalMs = 1000,
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
    this.platformChannelDurationThresholdMs = 8,
    this.suppressedIssues = const {},
    this.customDetectors = const [],
    this.thresholds = const DetectorThresholds(),
  });

  /// Custom theme for the overlay UI.
  ///
  /// When null (default), the overlay auto-selects dark or light based on
  /// [MediaQuery.platformBrightness]. If no [MediaQuery] is available
  /// (rare), defaults to dark.
  ///
  /// ```dart
  /// // Force light theme
  /// WatchdogConfig(theme: WatchdogThemeData.light())
  ///
  /// // Light theme with custom severity colors
  /// WatchdogConfig(
  ///   theme: WatchdogThemeData.light().copyWith(
  ///     severityCritical: Color(0xFFDC2626),
  ///   ),
  /// )
  /// ```
  final WatchdogThemeData? theme;

  /// Target frames per second (60 or 120). Drives jank detection thresholds.
  final int fpsTarget;

  /// Rebuild count per second above which the rebuild detector fires.
  final int rebuildThreshold;

  /// Maximum children in a non-lazy list before the ListView detector fires.
  final int maxListChildren;

  /// Maximum GlobalKeys in scrollable contexts before the detector fires.
  final int maxGlobalKeys;

  /// Maximum platform channel calls per second before the detector fires.
  final int platformChannelLimit;

  /// Interval in milliseconds between widget tree scans.
  final int treeScanIntervalMs;

  /// Which detectors are active. Defaults to all [DetectorType] values.
  final Set<DetectorType> enabledDetectors;

  /// Maximum number of jank frames to retain in the capture buffer.
  final int captureBufferCapacity;

  /// Enables debug-only rebuild/repaint attribution hooks.
  ///
  /// WARNING: Conflicts with DevTools "Track Widget Rebuilds" — only one can
  /// be active at a time. Default false to avoid surprising DevTools users.
  final bool enableDebugCallbacks;

  /// Enables heavy debug flags independently of [enableDebugCallbacks].
  /// Adds per-widget timeline events with higher overhead than callbacks alone.
  final bool enableDeepDebugInstrumentation;

  /// Maximum widget types to track in rebuild counters.
  /// Prevents unbounded memory in apps with many widget types.
  final int maxTrackedTypes;

  /// Advanced sub-flag configuration for debug instrumentation.
  /// When null, equivalent to `const DebugInstrumentationConfig()` (all
  /// defaults). Sub-flags only take effect when their parent switch is enabled.
  final DebugInstrumentationConfig? advanced;

  /// Master switch for HTTP network monitoring.
  /// When true and [DetectorType.networkMonitor] is in [enabledDetectors],
  /// installs an [HttpOverrides] proxy that records request timing and size.
  final bool enableNetworkMonitoring;

  /// Slow request detection threshold in milliseconds.
  final int slowRequestThresholdMs;

  /// Maximum HTTP requests allowed per 5-second window.
  final int requestFrequencyLimit;

  /// Large response detection threshold in bytes (default 1MB).
  final int largeResponseThresholdBytes;

  /// URL substring patterns to exclude from monitoring
  /// (e.g. `['/analytics', 'crashlytics']`).
  final List<String>? networkExcludePatterns;

  /// Duration in milliseconds to suppress heap growth alerts after the first
  /// heap sample. Prevents false positives from normal app startup allocation.
  final int memoryWarmupDurationMs;

  /// Cumulative platform channel duration threshold in milliseconds per window.
  /// Fires when total channel call time exceeds this even if call count is low.
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
  /// Custom detectors are always enabled regardless of [enabledDetectors].
  /// The controller disposes custom detectors when it is itself disposed.
  final List<BaseDetector> customDetectors;

  /// Detector-specific thresholds for fine-tuning performance detection.
  /// See [DetectorThresholds] for available parameters and defaults.
  final DetectorThresholds thresholds;
}

/// Lightweight struct for sorting allocation profile entries.
class _AllocStat {
  _AllocStat(this.name, this.lib, this.instances, this.bytes);
  final String name;
  final String lib;
  final int instances;
  final int bytes;
}
