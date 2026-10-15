import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../sleuth.dart' show Sleuth;
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/frame_stats.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/own_work_log.dart';
import '../vm/timeline_parser.dart';

/// Detects jank frames using [SchedulerBinding.addTimingsCallback] (fast,
/// every frame) and optionally augments with exact VM Timeline phase data.
///
/// **Runtime Detector** — near-zero overhead, always available.
///
/// **Measurement window.** Sleuth reports the frame total duration
/// (build-to-raster span) from `FrameTiming` — not vsync delivery cadence
/// (`CADisplayLink`-anchored on iOS, `Choreographer.doFrame` callback on
/// Android). The two are different metrics: `FrameTiming` reports how
/// long the engine took to produce a frame; vsync-anchored metrics report
/// when the OS displayed it. A frame produced in 3 ms still waits ~13 ms
/// for the next vsync — `FrameTiming` reports 3 ms, vsync metrics report
/// ~16 ms. Cross-framework comparison numbers that mix the two read as
/// large performance deltas where the underlying behaviour is identical.
///
/// **Lifecycle phase.** Each emission stamps
/// `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` based on whether
/// the issue EMITTED within
/// [DetectorThresholds.startupPhaseWindowSeconds] of
/// [Sleuth.dartEntryMonotonicUs]. The classification reads `Timeline.now`
/// at emission time — it is **emission-time semantics**, not event-time.
/// A startup-phase frame whose `addTimingsCallback` delivery is delayed
/// past the window boundary tags as `'steady'` even when the underlying
/// frame timestamp was inside startup. Buffer-aggregated emissions
/// (`sustained_jank` over the judged frames, raster-cache trends over
/// 30+ frames) tag from emission-time `Timeline.now`; a buffer that
/// straddles the boundary tags as `'steady'` once `Timeline.now` exceeds
/// the window even if most contributing frames landed inside startup.
///
/// This differs from `ShaderJankDetector.shaderWarmupContext`, which
/// classifies against per-event shader timestamp. The two tags are
/// related but NOT aligned at the boundary.
///
/// Hot restart resets `Sleuth.dartEntryMonotonicUs` (Dart re-initializes
/// statics; `Sleuth.init()` re-runs and writes a fresh anchor). Emissions
/// for the configured window after each hot restart tag as `'startup'`
/// even when the prior session was already past the window.
///
/// The tag is observable in capture-mode trace records and audit-gate
/// replay; it is not serialized into saved JSON snapshots.
///
/// **Route epoch.** `sustained_jank` and `jank_detected` judge only the
/// frames that arrived since the last [markRouteEpoch], which
/// `SleuthController` calls when its scan loop sees a new route, and each
/// emission carries the route it was computed on
/// (`PerformanceIssue.sourceRoute`). The epoch is set on the first scan
/// tick after navigation, so frames drawn between the push and that tick
/// (at most one scan interval, including the transition) count toward
/// the previous route. The first scan after launch is also a route
/// change, so startup frames never count toward jank. The frame buffer
/// itself is untouched: verdicts, FPS, cache trends and exports keep the
/// full window.
class FrameTimingDetector extends BaseDetector with DetectorMetadataProvider {
  FrameTimingDetector({
    int? warningThresholdMs,
    int? criticalThresholdMs,
    this.fpsTarget = 60,
    this.warmupFrameCount = 0,
    this.warmupDuration = _defaultWarmupDuration,
    this.captureMode = false,
    this.startupPhaseWindowSeconds = 5,
    this.onFrameStats,
    this.onFrame,
    String? Function()? sourceRouteProvider,
    int? Function()? appStartMonotonicUsForTest,
    int Function(int fromUs, int toUs)? ownWorkOverlapUs,
  }) : _sourceRouteProvider = sourceRouteProvider ?? (() => null),
       _ownWorkOverlapUs = ownWorkOverlapUs ?? ownWorkLog.overlapUs,
       warningBudgetUs = warningThresholdMs != null
           ? warningThresholdMs * 1000
           : _budgetUsFromFpsTarget(fpsTarget),
       criticalBudgetUs = criticalThresholdMs != null
           ? criticalThresholdMs * 1000
           : (warningThresholdMs != null
                     ? warningThresholdMs * 1000
                     : _budgetUsFromFpsTarget(fpsTarget)) *
                 2,
       _explicitThresholds =
           warningThresholdMs != null || criticalThresholdMs != null,
       _appStartForTest = appStartMonotonicUsForTest,
       super(
         type: DetectorType.frameTiming,
         lifecycle: DetectorLifecycle.runtime,
         name: 'Frame Timing',
         description:
             'Detects jank frames against the frame budget '
             '(${warningThresholdMs ?? _budgetUsFromFpsTarget(fpsTarget) ~/ 1000}ms)',
       );

  /// Microseconds of a `Timeline.now` window that Sleuth's own work
  /// covered. The detector subtracts this from each frame's start delay.
  final int Function(int fromUs, int toUs) _ownWorkOverlapUs;

  /// Validates `fpsTarget` before dividing by it. The `SleuthConfig` assert
  /// guard is stripped in profile/release, so without this check
  /// `fpsTarget: 0` would surface as an `Infinity` budget.
  static int _budgetUsFromFpsTarget(int fpsTarget) {
    if (fpsTarget < 1 || fpsTarget > 240) {
      throw ArgumentError.value(
        fpsTarget,
        'fpsTarget',
        'must be from 1 to 240',
      );
    }
    return (1e6 / fpsTarget).round();
  }

  /// Per-frame budget in microseconds. A frame whose effective duration
  /// exceeds it is jank. Defaults to `1e6 / fpsTarget` (16667 at 60);
  /// `SleuthController` moves it to the resolved budget via
  /// [updateFrameBudget].
  int warningBudgetUs;

  /// Severe-jank budget in microseconds (2x [warningBudgetUs]).
  int criticalBudgetUs;

  final bool _explicitThresholds;

  /// [warningBudgetUs] in whole milliseconds.
  int get warningThresholdMs => warningBudgetUs ~/ 1000;

  /// [criticalBudgetUs] in whole milliseconds.
  int get criticalThresholdMs => criticalBudgetUs ~/ 1000;

  /// Applies a resolved frame budget. No-op in [captureMode] (bracket
  /// recordings use the fixed `fpsTarget` budget), when explicit
  /// thresholds were passed to the constructor, or for a non-positive
  /// [budgetUs].
  void updateFrameBudget(int budgetUs) {
    if (captureMode || _explicitThresholds || budgetUs <= 0) return;
    warningBudgetUs = budgetUs;
    criticalBudgetUs = budgetUs * 2;
  }

  final int fpsTarget;

  /// Window in seconds after Dart entry within which emissions stamp
  /// `extraTraceArgs.lifecyclePhase: 'startup'`; emissions outside the
  /// window stamp `'steady'`. Default mirrors
  /// [DetectorThresholds.startupPhaseWindowSeconds] — the canonical
  /// source for users wiring via `SleuthConfig`. See class dartdoc for
  /// buffer-spanning behaviour.
  final int startupPhaseWindowSeconds;

  /// Test-only override for the app-start monotonic anchor. When supplied,
  /// `_classifyLifecyclePhase` uses the returned value in place of
  /// [Sleuth.dartEntryMonotonicUs]. Tests pass
  /// `() => Timeline.now - syntheticAgeUs` to pin a deterministic
  /// synthetic age relative to real `Timeline.now`.
  final int? Function()? _appStartForTest;

  /// Legacy frame-count gate (AND-combined with [warmupDuration]).
  ///
  /// Kept for callers that want an explicit frame-based floor. Default is 0
  /// (disabled) — the refresh-rate-independent [warmupDuration] gate is the
  /// primary warmup mechanism. A fixed frame count ends warmup faster on
  /// 120 Hz displays than on 60 Hz, misattributing startup jank as real
  /// jank on high-refresh devices.
  final int warmupFrameCount;

  /// Wall-clock gate suppressing jank evaluation during app warmup
  /// (shader compilation, route init, Dart VM JIT). Refresh-rate
  /// independent. Measured against the timestamp of the first frame the
  /// detector observes, not app-launch time.
  final Duration warmupDuration;

  /// Capture-mode short-circuit. When `true`, [_isPastWarmup] returns
  /// `true` immediately regardless of [warmupDuration] / [warmupFrameCount].
  /// Set via `SleuthConfig.captureMode` and plumbed by `SleuthController` so
  /// in-app capture screens can bracket the `jank_detected.warning` and
  /// `sustained_jank.critical` axes inside a short scenario span without
  /// waiting out the 3 s warmup.
  /// Default `false` — never engaged in normal app sessions.
  final bool captureMode;

  final void Function(FrameStatsBuffer buffer)? onFrameStats;

  /// Called once per frame, right after the frame enters the buffer and
  /// before [onFrameStats]. A batch of N timings yields N calls in
  /// presentation order. `SleuthController` uses it to fan frames out to
  /// [BaseDetector.processFrame].
  final void Function(FrameStats frame)? onFrame;

  /// Supplies the route name stamped as `sourceRoute` on jank emissions.
  final String? Function() _sourceRouteProvider;

  /// Value of [_totalFramesSeen] when [markRouteEpoch] last ran, or null
  /// when no epoch is set (the whole buffer is judged).
  int? _routeEpochFrameNumber;

  /// Starts a new jank window at the current frame and removes the
  /// `sustained_jank` / `jank_detected` issues computed on the previous
  /// window. Frames already in the buffer stay there (FPS, verdicts and
  /// exports still read them) but no longer count toward jank. Warmup,
  /// lifecycle phase and cache-trend state are untouched; [reset] is the
  /// full clear.
  void markRouteEpoch() {
    _routeEpochFrameNumber = _totalFramesSeen;
    _issues.removeWhere(
      (i) => i.stableId == 'sustained_jank' || i.stableId == 'jank_detected',
    );
  }

  /// How far back, behind the newest frame's vsync, jank looks. On a quiet
  /// screen Sleuth's own scans draw about one frame a second, so without a
  /// time limit janky frames took 4 to 8 minutes to leave the 240-frame
  /// buffer and the card stayed that long after the jank stopped.
  static const Duration jankWindow = Duration(seconds: 10);

  /// The frames jank is judged on: those since the last [markRouteEpoch]
  /// that are still in the buffer and, outside [captureMode], whose vsync
  /// is within [jankWindow] of the newest frame's. Frames without a vsync
  /// time count.
  List<FrameStats> get _jankFrames {
    final frames = _framesSinceRouteEpoch;
    if (captureMode || frames.isEmpty) return frames;
    final newest = frames.last.vsyncStartUs;
    if (newest == null) return frames;
    final cutoff = newest - jankWindow.inMicroseconds;
    final first = frames.indexWhere((f) {
      final vsync = f.vsyncStartUs;
      return vsync == null || vsync >= cutoff;
    });
    if (first <= 0) return first == 0 ? frames : const [];
    return frames.sublist(first);
  }

  /// Frames ingested since the last [markRouteEpoch] that are still in
  /// the buffer, oldest first; the whole buffer when no epoch is set.
  List<FrameStats> get _framesSinceRouteEpoch {
    final frames = _buffer.frames;
    final epoch = _routeEpochFrameNumber;
    if (epoch == null) return frames;
    final since = _totalFramesSeen - epoch;
    if (since >= frames.length) return frames;
    if (since <= 0) return const [];
    return frames.sublist(frames.length - since);
  }

  /// Returns `'startup'` when emission `Timeline.now` falls within the
  /// startup window after [Sleuth.dartEntryMonotonicUs], `'steady'`
  /// otherwise, or `null` when no app-start anchor is available
  /// (e.g. `Sleuth.init()` not yet called). A null return omits the
  /// `lifecyclePhase` key from `extraTraceArgs` rather than fabricating a
  /// phase value.
  String? _classifyLifecyclePhase() {
    final appStart = _appStartForTest?.call() ?? Sleuth.dartEntryMonotonicUs;
    if (appStart == null) return null;
    final delta = Timeline.now - appStart;
    // Defensive: a future-timestamped `_appStartForTest` value would
    // otherwise produce a negative delta. Production `Timeline.now` is
    // monotonic-from-boot and cannot land before the captured app-start.
    if (delta < 0) return null;
    final windowUs = startupPhaseWindowSeconds * 1000000;
    return delta < windowUs ? 'startup' : 'steady';
  }

  // Fixed 240 so `actualFpsRaw` reports the true device rate regardless of
  // [fpsTarget]. A target-derived capacity would cap the count below the
  // device refresh (e.g. 60 at fpsTarget=30 on a 120 Hz panel).
  static const int _bufferCapacity = 240;

  /// `jank_detected` fires when more than this percentage of the judged
  /// frames missed their deadline.
  static const int jankPercentThreshold = 15;

  /// Judged frames needed before jank is evaluated.
  static const int minJankSampleFrames = 5;

  /// Late frames `jank_detected` needs besides the percentage. A quiet
  /// screen draws only Sleuth's own scan frames, about one a second, so
  /// one late frame among the ten in [jankWindow] already reads 10 % and
  /// two read 20 %. On an animated screen the percentage needs many more.
  static const int minJankFrameCount = 3;

  /// `sustained_jank` fires at this many severe frames (see
  /// [FrameStats.severeJankBudgetMultiplier]).
  static const int sustainedSevereFrameCount = 3;
  late final FrameStatsBuffer _buffer = FrameStatsBuffer(
    capacity: _bufferCapacity,
  );
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;
  int _frameNumber = 0;
  TimingsCallback? _callback;

  // Instance-monotonic emission counter. Combined with wall-clock micros at
  // emission time to form `dedupIdentityMicros`, so back-to-back evaluations
  // of `_evaluateJank` (which rewrites `_issues` every frame callback)
  // produce DISTINCT identities even if `DateTime.now().microsecondsSinceEpoch`
  // collides under coarse system-clock granularity. Preserved across
  // [reset] so multi-leg capture flows cannot collide identities.
  int _emissionSeq = 0;

  // -- Warmup suppression --
  // First ~3 seconds of monitoring produce jank from shader compilation,
  // route initialization, and Dart VM warmup. Suppress issue evaluation
  // during this window to avoid false positives on every app launch.
  static const Duration _defaultWarmupDuration = Duration(seconds: 3);
  int _totalFramesSeen = 0;

  // Wall-clock fallback timestamp — used only when the engine's monotonic
  // vsync timestamp is unavailable (e.g. synthetic test frames without
  // `FrameStats.vsyncStartUs`). Susceptible to `addTimingsCallback`
  // batching: Flutter can deliver a queue of frames in a single callback
  // with all `DateTime.now()` stamps collapsed to one tick, which would
  // hold the gate closed far past the intended warmup window.
  DateTime? _firstFrameTimestamp;

  // Monotonic microsecond timestamp (same clock domain as
  // [FrameTiming.vsyncStart]) of the first frame observed by the detector.
  // Measured against `frames.last.vsyncStartUs` — both are derived from the
  // engine clock, so batched callback delivery no longer collapses elapsed
  // time to zero.
  int? _firstFrameVsyncUs;

  // -- Vsync cadence estimator --
  static const int _cadenceCapacity = 120;
  static const int _cadenceMinSamples = 30;
  final List<int> _cadenceDeltas = List<int>.filled(_cadenceCapacity, 0);
  int _cadenceCount = 0;
  int _cadenceWriteIndex = 0;
  int? _lastCadenceVsyncUs;
  double? _cachedCadenceHz;
  bool _cadenceDirty = false;

  /// Vsync cadence estimated from the 10th percentile of recent
  /// `vsyncStart` deltas, or null until 30 valid deltas have been seen.
  ///
  /// The 10th percentile, not the median: fast frames reveal the vsync
  /// period, while slow frames are the thing being measured. A median would
  /// absorb steady jank into the cadence and loosen the budget it is judged
  /// against. Deltas `<= 0` and idle gaps longer than two `fpsTarget`
  /// frames are ignored. The last 120 valid deltas are kept.
  double? get measuredCadenceHz {
    if (_cadenceCount < _cadenceMinSamples) return null;
    if (_cadenceDirty) {
      final sorted = _cadenceDeltas.sublist(0, _cadenceCount)..sort();
      final p10 = sorted[(_cadenceCount * 0.1).floor()];
      _cachedCadenceHz = 1e6 / p10;
      _cadenceDirty = false;
    }
    return _cachedCadenceHz;
  }

  /// Number of vsync deltas currently held by the cadence estimator.
  @visibleForTesting
  int get validCadenceSampleCount => _cadenceCount;

  void _recordVsync(int vsyncStartUs) {
    final last = _lastCadenceVsyncUs;
    _lastCadenceVsyncUs = vsyncStartUs;
    if (last == null) return;
    final delta = vsyncStartUs - last;
    // Idle gaps are judged against the fpsTarget frame, not the resolved
    // budget, so a tightened budget cannot discard the slower deltas that
    // would let the estimate fall back.
    final maxDeltaUs = 2 * (1e6 / fpsTarget).round();
    if (delta <= 0 || delta > maxDeltaUs) return;
    _cadenceDeltas[_cadenceWriteIndex] = delta;
    _cadenceWriteIndex = (_cadenceWriteIndex + 1) % _cadenceCapacity;
    if (_cadenceCount < _cadenceCapacity) _cadenceCount++;
    _cadenceDirty = true;
  }

  void _resetCadence() {
    _cadenceCount = 0;
    _cadenceWriteIndex = 0;
    _lastCadenceVsyncUs = null;
    _cachedCadenceHz = null;
    _cadenceDirty = false;
  }

  // -- Raster cache trend thresholds --
  static const int _thrashingWindowFrames = 15;
  static const double _thrashingVariationPercent = 0.20;
  static const int _growthWindowFrames = 30;
  static const int _impellerZeroWindowFrames = 30;

  int _consecutiveThrashingFrames = 0;
  int _consecutiveGrowthFrames = 0;
  int _consecutiveZeroCacheFrames = 0;
  bool _impellerDetected = false;

  // Latest VM timeline data for enrichment
  ParsedTimelineData? _lastTimelineData;

  FrameStatsBuffer get frameBuffer => _buffer;

  /// Re-reads Sleuth's own share of each buffered frame's start delay and
  /// re-judges jank when any changed. A VM stall that a later timeline poll
  /// measures can cover a frame read before it. Returns how many frames
  /// changed.
  int refreshOwnStartDelays() {
    final changed = _buffer.refreshOwnStartDelays(_ownWorkOverlapUs);
    if (changed > 0) _evaluateJank();
    return changed;
  }

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) {
    if (_isEnabled == value) return;
    _isEnabled = value;
    if (value) {
      _startListening();
    } else {
      _stopListening();
    }
  }

  /// Call this to update with latest VM Timeline data.
  void updateTimelineData(ParsedTimelineData data) {
    _lastTimelineData = data;
  }

  /// Add a synthetic frame for testing — feeds directly into the buffer
  /// and triggers jank evaluation without requiring SchedulerBinding.
  ///
  /// Auto-injects a monotonic [FrameStats.rasterFinishUs] when the caller
  /// omits one, so `actualFps`-sensitive code paths see a populated rolling
  /// window. Pass an explicit `rasterFinishUs` for tests that care about
  /// window boundaries, batched delivery, or non-monotonic timestamps.
  @visibleForTesting
  void addFrameForTest(FrameStats stats) {
    if (!_isEnabled) return;
    if (stats.rasterFinishUs == null) {
      final latest = _buffer.latest?.rasterFinishUs ?? 0;
      stats = stats.copyWith(rasterFinishUs: latest + warningBudgetUs);
    }
    _totalFramesSeen++;
    _firstFrameTimestamp ??= stats.timestamp;
    if (stats.vsyncStartUs != null) {
      _firstFrameVsyncUs ??= stats.vsyncStartUs;
    }
    _buffer.add(stats);
    onFrame?.call(stats);
    _evaluateJank();
    _evaluateCacheTrends();
    onFrameStats?.call(_buffer);
  }

  /// Test-only bridge into the real `addTimingsCallback` pipeline so
  /// callers can feed `List<FrameTiming>` batches through the exact code
  /// path the engine uses. Validates that batched delivery (one callback
  /// with many frames) no longer collapses the warmup duration gate.
  @visibleForTesting
  void handleTimingsForTest(List<FrameTiming> timings) => _onTimings(timings);

  /// Returns `true` once BOTH warmup gates have elapsed:
  ///   * frame-count floor ([warmupFrameCount]) — legacy, default 0
  ///   * wall-clock duration ([warmupDuration]) — primary, default 3 s
  ///
  /// Duration is preferably measured in engine microseconds
  /// ([FrameTiming.vsyncStart] domain) since those timestamps are
  /// immune to `addTimingsCallback` batching: the engine stamps each
  /// frame at its actual vsync, even when ten frames are delivered to
  /// Dart in a single callback. Falls back to wall-clock `timestamp` only
  /// when the frame lacks `vsyncStartUs` (synthetic test frames).
  bool _isPastWarmup() {
    // Capture-mode short-circuit: bracket captures inject jank inside a
    // bounded scenario span and cannot afford the 3 s warmup. Plumbed via
    // `SleuthConfig.captureMode`. Never engaged in production app code.
    if (captureMode) return true;
    if (_totalFramesSeen < warmupFrameCount) return false;
    if (warmupDuration > Duration.zero) {
      final frames = _buffer.frames;
      if (frames.isEmpty) return false;

      final firstVsync = _firstFrameVsyncUs;
      final lastVsync = frames.last.vsyncStartUs;
      if (firstVsync != null && lastVsync != null) {
        final elapsedUs = lastVsync - firstVsync;
        if (elapsedUs < warmupDuration.inMicroseconds) return false;
      } else {
        // Fallback: no monotonic vsync data available. Must still enforce
        // the duration gate for test frames and custom BaseDetector
        // consumers that bypass the timings callback.
        final first = _firstFrameTimestamp;
        if (first == null) return false;
        final elapsed = frames.last.timestamp.difference(first);
        if (elapsed < warmupDuration) return false;
      }
    }
    return true;
  }

  void start() {
    if (!_isEnabled) return;
    _startListening();
  }

  void _startListening() {
    if (_callback != null) return; // Already listening
    _callback = _onTimings;
    SchedulerBinding.instance.addTimingsCallback(_callback!);
  }

  void _stopListening() {
    if (_callback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_callback!);
      _callback = null;
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_isEnabled) return;

    for (final timing in timings) {
      _frameNumber++;
      _totalFramesSeen++;
      _firstFrameTimestamp ??= DateTime.now();

      // Extract all 5 phase timestamps for frame-event correlation.
      final vsyncStartUs = timing.timestampInMicroseconds(
        FramePhase.vsyncStart,
      );
      _firstFrameVsyncUs ??= vsyncStartUs;
      _recordVsync(vsyncStartUs);
      final buildStartUs = timing.timestampInMicroseconds(
        FramePhase.buildStart,
      );
      final buildFinishUs = timing.timestampInMicroseconds(
        FramePhase.buildFinish,
      );
      final rasterStartUs = timing.timestampInMicroseconds(
        FramePhase.rasterStart,
      );
      final rasterFinishRaw = timing.timestampInMicroseconds(
        FramePhase.rasterFinish,
      );
      // Treat 0 as absent — some engine/platform combos omit rasterFinish
      // when the frame never reached GPU submission. actualFps requires a
      // real rasterFinishUs timestamp, so nullify here rather than poison
      // the rolling window with a zero anchor.
      final rasterFinishUs = rasterFinishRaw > 0 ? rasterFinishRaw : null;

      // Build-to-raster gap: time the completed layer tree waits for the
      // raster thread. Computed from raw timestamps.
      final gapUs = rasterStartUs - buildFinishUs;

      final stats = FrameStats(
        frameNumber: _frameNumber,
        uiDuration: Duration(microseconds: timing.buildDuration.inMicroseconds),
        rasterDuration: Duration(
          microseconds: timing.rasterDuration.inMicroseconds,
        ),
        timestamp: DateTime.now(),
        vsyncOverhead: timing.vsyncOverhead,
        layerCacheCount: timing.layerCacheCount,
        layerCacheBytes: timing.layerCacheBytes,
        pictureCacheCount: timing.pictureCacheCount,
        pictureCacheBytes: timing.pictureCacheBytes,
        frameBudgetMs: warningBudgetUs ~/ 1000,
        frameBudgetUs: warningBudgetUs,
        totalSpan: timing.totalSpan,
        buildToRasterGap: Duration(microseconds: gapUs > 0 ? gapUs : 0),
        vsyncStartUs: vsyncStartUs,
        buildStartUs: buildStartUs,
        buildFinishUs: buildFinishUs,
        rasterStartUs: rasterStartUs,
        rasterFinishUs: rasterFinishUs,
        ownStartDelayUs: buildStartUs > vsyncStartUs
            ? _ownWorkOverlapUs(vsyncStartUs, buildStartUs)
            : 0,
      );

      _buffer.add(stats);
      onFrame?.call(stats);
    }

    // Evaluate jank based on recent buffer pattern, not individual frames.
    // This avoids noisy single-frame alerts (e.g. 16ms from the overlay itself).
    _evaluateJank();
    _evaluateCacheTrends();

    onFrameStats?.call(_buffer);
  }

  /// Only report jank as an issue when it's a sustained pattern:
  /// - Critical: ≥3 severe jank frames (>2x budget) among the judged frames
  /// - Warning: >15% of the judged frames are janky (> budget), with at
  ///   least [minJankFrameCount] of them
  ///
  /// Both judge the frames since the last [markRouteEpoch] (the whole
  /// buffer when no epoch is set) and, outside [captureMode], only those
  /// within [jankWindow] of the newest frame's vsync; when the newest frame
  /// has no vsync time the window does not apply. The 5-frame minimum,
  /// percentages and `bufferSize` apply to that slice.
  ///
  /// **Parallel emission semantics (v0.19.6+).** When both gates are
  /// satisfied (severeCount ≥ 3 AND jankPercent > 15), BOTH stableIds
  /// fire concurrently. Each describes an independent aspect of the
  /// same observation: `sustained_jank` reports the count of severe
  /// frames; `jank_detected` reports the proportion of janky frames.
  /// Pre-v0.19.6 the detector used `if/else if` and hid `jank_detected`
  /// behind `sustained_jank` whenever both gates fired — but on devices
  /// with ambient severe jank rate ≥ 3 the warning-tier signal was
  /// then structurally unreachable, blocking runtimeVerified bracket
  /// captures. Other detectors at runtimeVerified+ tier (NetworkMonitor,
  /// MemoryPressure, HeavyCompute, PlatformChannel) already produce
  /// concurrent multi-stableId emissions; the UI handles this via
  /// IssueRanker composite-score ordering (both are confirmed, so the
  /// critical tier ranks above the warning tier).
  void _evaluateJank() {
    _issues.removeWhere(
      (i) => i.stableId == 'sustained_jank' || i.stableId == 'jank_detected',
    );

    // Suppress jank evaluation during warmup period (shader compilation,
    // route init, Dart VM warmup produce non-actionable jank).
    if (!_isPastWarmup()) return;

    final frames = _jankFrames;
    if (frames.length < minJankSampleFrames) return; // Need enough data

    // Single pass: count jank categories and find the worst app frame.
    // Frames late only because of Sleuth's own work count in neither the
    // jank count nor the frames it is a percentage of.
    int severeCount = 0, jankCount = 0, overheadCount = 0;
    FrameStats? worst;
    for (final f in frames) {
      if (f.isSleuthOverhead) {
        overheadCount++;
        continue;
      }
      if (f.isSevereJank) severeCount++;
      if (f.isJank) jankCount++;
      if (worst == null || _deadlineUs(f) > _deadlineUs(worst)) worst = f;
    }
    final appFrames = frames.length - overheadCount;
    if (worst == null || appFrames < minJankSampleFrames) return;
    final jankPercent = (jankCount / appFrames * 100).round();

    // Classify jank frames by bottleneck thread for attribution.
    final bottleneck = _classifyJankBottleneck(frames);

    final lifecyclePhase = _classifyLifecyclePhase();
    final sourceRoute = _sourceRouteProvider();
    if (severeCount >= sustainedSevereFrameCount) {
      final (hint1, effort1) = FixHintBuilder.sustainedJank();
      // Wall-clock micros plus instance-monotonic counter — same shape as
      // jank_detected emission below. Audit gate's
      // `bracketRequireUniqueDetectedAtMicros: true` invariant on the
      // sustained_jank bracket needs distinct `detectedAtMicros` per
      // record so a single-issue replay cannot satisfy the multi-record
      // count threshold.
      final identity1 =
          DateTime.now().microsecondsSinceEpoch + (_emissionSeq++);
      _issues.add(
        PerformanceIssue(
          stableId: 'sustained_jank',
          severity: IssueSeverity.critical,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title:
              'Sustained Jank${bottleneck.label}: $severeCount severe frames '
              '($jankPercent% janky)',
          detail: '${_buildDetail(worst)}\n${bottleneck.summary}',
          fixHint: hint1,
          fixEffort: effort1,
          detectedAt: DateTime.fromMicrosecondsSinceEpoch(identity1),
          dedupIdentityMicros: identity1,
          sourceRoute: sourceRoute,
          extraTraceArgs: {
            'observedSevereCount': severeCount.toString(),
            'observedJankPercent': jankPercent.toStringAsFixed(2),
            'bufferSize': frames.length.toString(),
            'sleuthOverheadFrames': overheadCount.toString(),
            'lifecyclePhase': ?lifecyclePhase,
          },
          confidenceReason: 'Measured directly from FrameTiming API',
        ),
      );
    }
    if (jankPercent > jankPercentThreshold && jankCount >= minJankFrameCount) {
      final (hint2, effort2) = FixHintBuilder.jankDetected();
      final worstMs = _deadlineUs(worst) / 1000.0;
      // Wall-clock micros plus an instance-monotonic counter so back-to-back
      // emissions never collide under coarse `DateTime.now()` granularity.
      // The audit gate's `bracketRequireUniqueDetectedAtMicros: true`
      // invariant requires distinct `detectedAtMicros` per record.
      final identity = DateTime.now().microsecondsSinceEpoch + (_emissionSeq++);
      _issues.add(
        PerformanceIssue(
          stableId: 'jank_detected',
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title:
              'Jank Detected${bottleneck.label}: $jankPercent% of frames over '
              'budget',
          detail: '${_buildDetail(worst)}\n${bottleneck.summary}',
          fixHint: hint2,
          fixEffort: effort2,
          detectedAt: DateTime.fromMicrosecondsSinceEpoch(identity),
          dedupIdentityMicros: identity,
          sourceRoute: sourceRoute,
          // Detector-observed axis values exported into trace event args so
          // the audit-gate can cross-check the operator's `magnitudeObserved`
          // (operator-typed claim) against what the detector actually saw at
          // fire time. Stringified per Timeline arg-encoding contract.
          extraTraceArgs: {
            'observedJankCount': jankCount.toString(),
            'observedJankPercent': jankPercent.toStringAsFixed(2),
            'observedWorstFrameMs': worstMs.toStringAsFixed(2),
            'bufferSize': frames.length.toString(),
            'sleuthOverheadFrames': overheadCount.toString(),
            'lifecyclePhase': ?lifecyclePhase,
          },
          confidenceReason: 'Measured directly from FrameTiming API',
        ),
      );
    }
  }

  void _evaluateCacheTrends() {
    if (!_isPastWarmup()) return;

    final frames = _buffer.frames;
    if (frames.length < 2) return;

    final latest = frames.last;
    final previous = frames[frames.length - 2];

    // --- Impeller detection: all four metrics zero ---
    final allZero =
        latest.layerCacheCount == 0 &&
        latest.layerCacheBytes == 0 &&
        latest.pictureCacheCount == 0 &&
        latest.pictureCacheBytes == 0;

    if (allZero) {
      _consecutiveZeroCacheFrames++;
      if (_consecutiveZeroCacheFrames >= _impellerZeroWindowFrames) {
        _impellerDetected = true;
      }
    } else {
      _consecutiveZeroCacheFrames = 0;
      _impellerDetected = false;
    }

    // Suppress cache analysis when Impeller detected
    if (_impellerDetected) {
      _consecutiveThrashingFrames = 0;
      _consecutiveGrowthFrames = 0;
      _issues.removeWhere(
        (i) =>
            i.stableId == 'raster_cache_thrashing' ||
            i.stableId == 'raster_cache_growing',
      );
      return;
    }

    // --- Cache thrashing: pictureCacheCount fluctuates > 20% ---
    if (previous.pictureCacheCount > 5) {
      final delta = (latest.pictureCacheCount - previous.pictureCacheCount)
          .abs();
      final variation = delta / previous.pictureCacheCount;
      if (variation > _thrashingVariationPercent) {
        _consecutiveThrashingFrames++;
      } else {
        _consecutiveThrashingFrames = 0;
      }
    } else if (latest.pictureCacheCount > 5) {
      // Jump from low (<=5) to meaningful count — counts as thrashing
      _consecutiveThrashingFrames++;
    }

    // --- Cache growth: totalCacheBytes monotonically increasing ---
    if (latest.totalCacheBytes > previous.totalCacheBytes &&
        latest.totalCacheBytes > 0) {
      _consecutiveGrowthFrames++;
    } else {
      _consecutiveGrowthFrames = 0;
    }

    // --- Emit issues ---
    _issues.removeWhere(
      (i) =>
          i.stableId == 'raster_cache_thrashing' ||
          i.stableId == 'raster_cache_growing',
    );

    final lifecyclePhase = _classifyLifecyclePhase();
    if (_consecutiveThrashingFrames >= _thrashingWindowFrames) {
      final (hint, effort) = FixHintBuilder.rasterCacheThrashing();
      _issues.add(
        PerformanceIssue(
          stableId: 'raster_cache_thrashing',
          severity: IssueSeverity.warning,
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
          title:
              'Raster Cache Thrashing: '
              '$_consecutiveThrashingFrames consecutive frames',
          detail:
              'The picture cache count changed by more than 20% between '
              'consecutive frames for $_consecutiveThrashingFrames frames. '
              'The current count is ${latest.pictureCacheCount} and the '
              'previous count was ${previous.pictureCacheCount}. Either the '
              'cache is too small or the content is not reusable.',
          fixHint: hint,
          fixEffort: effort,
          detectedAt: DateTime.now(),
          extraTraceArgs: {'lifecyclePhase': ?lifecyclePhase},
          confidenceReason: 'Measured directly from FrameTiming API',
        ),
      );
    }

    if (_consecutiveGrowthFrames >= _growthWindowFrames) {
      final totalKb = latest.totalCacheBytes / 1024;
      final (hint, effort) = FixHintBuilder.rasterCacheGrowing();
      _issues.add(
        PerformanceIssue(
          stableId: 'raster_cache_growing',
          severity: IssueSeverity.warning,
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
          title:
              'Raster Cache Growing: '
              '${totalKb.toStringAsFixed(0)} KB over '
              '$_consecutiveGrowthFrames frames',
          detail:
              'Total raster cache bytes have grown monotonically for '
              '$_consecutiveGrowthFrames consecutive frames. The picture '
              'cache holds ${(latest.pictureCacheBytes / 1024).toStringAsFixed(0)} KB '
              'and the layer cache '
              '${(latest.layerCacheBytes / 1024).toStringAsFixed(0)} KB. '
              'The cache may be accumulating without bound.',
          fixHint: hint,
          fixEffort: effort,
          detectedAt: DateTime.now(),
          extraTraceArgs: {'lifecyclePhase': ?lifecyclePhase},
          confidenceReason: 'Measured directly from FrameTiming API',
        ),
      );
    }
  }

  /// Classify jank frames by which thread is the bottleneck.
  /// The time [isJank] compares with the budget: the app's start delay plus
  /// the build, or the raster, whichever is longer.
  static int _deadlineUs(FrameStats f) {
    final ui = f.appStartDelayUs + f.uiDuration.inMicroseconds;
    final raster = f.rasterDuration.inMicroseconds;
    return ui > raster ? ui : raster;
  }

  _JankBottleneck _classifyJankBottleneck(List<FrameStats> frames) {
    int uiBound = 0, rasterBound = 0, startDelay = 0;
    for (final f in frames) {
      if (!f.isJank) continue;
      final budgetUs = f.frameBudgetUs;
      final buildUs = f.uiDuration.inMicroseconds;
      final rasterUs = f.rasterDuration.inMicroseconds;
      if (buildUs <= budgetUs && rasterUs <= budgetUs) {
        // Neither thread ran over by itself, so the app's start delay
        // pushed the build past the deadline.
        startDelay++;
      } else if (buildUs > rasterUs) {
        uiBound++;
      } else {
        rasterBound++;
      }
    }

    final total = uiBound + rasterBound + startDelay;
    if (total == 0) return const _JankBottleneck.none();

    final counts =
        'Thread attribution: $uiBound UI-bound, $rasterBound raster-bound, '
        '$startDelay late start.';
    if (startDelay > uiBound && startDelay > rasterBound) {
      return _JankBottleneck(
        label: ' (late start)',
        summary:
            '$counts Each build and raster fit the budget by itself, but '
            'the time from vsync to the build plus the build ran past the '
            'deadline. A long start delay is other work on the UI thread '
            'between frames: look for long timer callbacks, platform '
            'message handlers or microtasks. A build just under the budget '
            'misses it even with the usual 1 ms delay.',
      );
    }
    if (uiBound > rasterBound) {
      return _JankBottleneck(
        label: ' (UI-bound)',
        summary: '$counts Reduce build, layout and paint work.',
      );
    }
    if (rasterBound > uiBound) {
      return _JankBottleneck(
        label: ' (raster-bound)',
        summary: '$counts Reduce GPU compositing work.',
      );
    }
    return _JankBottleneck(label: ' (mixed)', summary: counts);
  }

  String _buildDetail(FrameStats stats) {
    final buf = StringBuffer()
      ..writeln('UI Thread: ${stats.uiDuration.inMilliseconds}ms')
      ..writeln('Raster: ${stats.rasterDuration.inMilliseconds}ms');

    if (stats.totalSpan != null) {
      buf.writeln(
        'Total span: '
        '${(stats.totalSpan!.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    if (stats.vsyncOverhead.inMicroseconds > 0) {
      final own = stats.ownStartDelayUs;
      buf.writeln(
        'Start delay: '
        '${(stats.vsyncOverhead.inMicroseconds / 1000).toStringAsFixed(1)}ms'
        '${own > 0 ? ' (${(own / 1000).toStringAsFixed(1)}ms of it Sleuth\'s own work)' : ''}',
      );
    }

    if (stats.buildToRasterGap.inMicroseconds > 500) {
      buf.writeln(
        'Pipeline gap: '
        '${(stats.buildToRasterGap.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    // VM timeline sub-breakdown (only available in FULL mode)
    final tl = _lastTimelineData;
    if (tl != null && tl.hasData) {
      if (tl.buildScopeDurations.isNotEmpty) {
        final buildUs = tl.totalBuildScopeUs;
        buf.writeln('  buildScope: ${(buildUs / 1000).toStringAsFixed(1)}ms');
      }
      if (tl.flushLayoutDurations.isNotEmpty) {
        final layoutUs = tl.totalFlushLayoutUs;
        buf.writeln('  flushLayout: ${(layoutUs / 1000).toStringAsFixed(1)}ms');
      }
      if (tl.flushPaintDurations.isNotEmpty) {
        final paintUs = tl.totalFlushPaintUs;
        buf.writeln('  flushPaint: ${(paintUs / 1000).toStringAsFixed(1)}ms');
      }
    }

    // The same split as the thread attribution above.
    final budgetUs = stats.frameBudgetUs;
    if (stats.uiDuration.inMicroseconds <= budgetUs &&
        stats.rasterDuration.inMicroseconds <= budgetUs) {
      buf.writeln(
        'Bottleneck: Late start (the start delay plus the build ran past '
        'the deadline)',
      );
    } else if (stats.uiDuration > stats.rasterDuration) {
      buf.writeln('Bottleneck: UI thread (build/layout/paint)');
    } else {
      buf.writeln('Bottleneck: Raster thread (GPU compositing)');
    }

    return buf.toString().trimRight();
  }

  @override
  void dispose() {
    _stopListening();
    _buffer.clear();
    _issues.clear();
    _totalFramesSeen = 0;
    _firstFrameTimestamp = null;
    _firstFrameVsyncUs = null;
    _consecutiveThrashingFrames = 0;
    _consecutiveGrowthFrames = 0;
    _consecutiveZeroCacheFrames = 0;
    _impellerDetected = false;
    _lastTimelineData = null;
    _routeEpochFrameNumber = null;
    _resetCadence();
  }

  /// Capture-mode reset hook. Clears all per-leg state — buffer, ephemeral
  /// `_issues`, warmup anchors, cache-trend counters, the route epoch, the
  /// vsync cadence estimate — so back-to-back
  /// scenario legs cannot leak frames or counters from prior runs.
  ///
  /// **Preserves [_emissionSeq] across reset by design.** The audit gate's
  /// `bracketRequireUniqueDetectedAtMicros: true` invariant requires every
  /// emitted record across the session to carry a distinct `detectedAtMicros`;
  /// resetting the counter would risk identity collisions when two legs
  /// fire emissions at the same wall-clock microsecond. Does NOT call
  /// [_stopListening] — the timings callback stays installed.
  void reset() {
    _buffer.clear();
    _issues.clear();
    _totalFramesSeen = 0;
    _frameNumber = 0;
    _firstFrameTimestamp = null;
    _firstFrameVsyncUs = null;
    _consecutiveThrashingFrames = 0;
    _consecutiveGrowthFrames = 0;
    _consecutiveZeroCacheFrames = 0;
    _impellerDetected = false;
    _lastTimelineData = null;
    _routeEpochFrameNumber = null;
    _resetCadence();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    reproducerPath: 'test/validation/frame_timing_reproducer_test.dart',
    coveredStableIds: {
      'sustained_jank',
      'jank_detected',
      'raster_cache_thrashing',
      'raster_cache_growing',
    },
    // `jank_detected` and `sustained_jank` are raised to runtimeVerified
    // via `perStableIdTier`; the cache families stay reproducerOnly.
    // `sustained_jank` counts severe frames in the 240-frame buffer, where
    // an ambient severe frame would join the operator's injected ones.
    // Its capture screen refuses any leg whose severe frames, judged by a
    // rule at least as strict as the detector's, are not exactly the
    // injected ones, so the bracket holds only legs without ambient
    // severe frames.
    perStableIdTier: {
      'jank_detected': EvidenceTier.runtimeVerified,
      'sustained_jank': EvidenceTier.runtimeVerified,
    },
    additionalBrackets: [
      // Critical at 3 or more severe frames (the only severity). The at
      // band [3, 4.5] holds 3 or 4, the above band (4.5, 7.5] 5 to 7.
      // `last` reads the count when the span closed: a frame excused
      // later (`refreshOwnStartDelays`) lowers it instead of leaving a
      // stale peak.
      BracketSpec(
        stableId: 'sustained_jank',
        severityLabel: 'critical',
        threshold: 3,
        unit: 'frames',
        coveredThresholds: {'sustained_jank.critical'},
        profileCapturePaths: [
          'test/validation/captures/frame_timing/sustained_jank_below.json',
          'test/validation/captures/frame_timing/sustained_jank_at.json',
          'test/validation/captures/frame_timing/sustained_jank_above.json',
        ],
        atTolerance: 0.5,
        aboveCeilingMultiplier: 2.5,
        observedAxisArgKey: 'observedSevereCount',
        observedAxisTolerance: 0.25,
        observedAxisReduction: 'last',
        requireUniqueDetectedAtMicros: true,
        requireDetectorTraceRecord: true,
        // The count repeats in every timings batch after the last spin,
        // so an in-band leg holds many in-band records.
        minInBandSamples: 2,
      ),
    ],
    profileCapturePaths: [
      'test/validation/captures/frame_timing/jank_detected_below.json',
      'test/validation/captures/frame_timing/jank_detected_at.json',
      'test/validation/captures/frame_timing/jank_detected_above.json',
    ],
    bracketStableId: 'jank_detected',
    bracketSeverityLabel: 'warning',
    bracketThreshold: 16,
    bracketUnit: 'percent',
    bracketAtTolerance: 0.50,
    aboveCeilingMultiplier: 1.85,
    coveredThresholds: {'jank_detected.warning', 'sustained_jank.critical'},
    observedAxisArgKey: 'observedJankPercent',
    observedAxisTolerance: 0.25,
    observedAxisReduction: 'last',
    bracketRequireUniqueDetectedAtMicros: true,
    rationale:
        'A hermetic reproducer pins four stableIds. `sustained_jank` fires '
        'on at least 3 severe frames in a 240-frame window. `jank_detected` '
        'fires above 15% jank frames with a sample of at least 5 frames. '
        'Both judge only the frames since the last route epoch and, '
        'outside capture mode, only those within 10 s of the newest '
        'frame\'s vsync, so a card clears about 10 s after the jank stops '
        'on a screen that draws only Sleuth\'s own scan frames. '
        '`raster_cache_thrashing` fires after at least 15 consecutive '
        'frames in which the picture cache count changes by more than 20% '
        'from a previous frame that held more than 5 pictures, or jumps '
        'from 5 or fewer to more than 5. `raster_cache_growing` '
        'fires after at least 30 consecutive frames of monotonic growth '
        'in total raster cache bytes. The reproducer bypasses warmup with '
        '`warmupDuration: Duration.zero`. Every stableId has a synthetic '
        '`FrameStats` path and a real `FrameTiming` integration leg through '
        '`handleTimingsForTest`, so hand-written synthetic fixtures cannot '
        'encode the detector\'s own expected shape. A dedicated test pins '
        'Impeller-zero suppression (all four cache metrics zero for at '
        'least 30 frames). Every other cache-family test sets '
        '`pictureCacheBytes: 1` so that suppression cannot arm and clear '
        'the issues under test. `jank_detected.warning` is runtimeVerified '
        '(via `perStableIdTier`) on three on-device captures (iPhone 12, '
        'iOS 17.5, Flutter 3.47.6, 60 Hz, deadline rule) that bracket the '
        'jank-percent threshold. `sustained_jank.critical` is '
        'runtimeVerified on three iPhone 12 captures (iOS 17.5, Flutter '
        '3.47.6, 60 Hz) whose legs inject 2, 3 and 6 severe frames: the '
        'capture screen spins 40 ms inside chosen frames, counts severe '
        'frames with its own FrameTiming rule (which keeps Sleuth\'s start '
        'delay in, so it never counts fewer than the detector), and keeps a '
        'leg only when its count equals the injected count and, for the at '
        'and above legs, the detector\'s last `observedSevereCount` does '
        'too. A leg with an '
        'ambient severe frame is refused, not subtracted, and the claim '
        'covers the iPhone 12. The cache stableIds stay reproducerOnly and '
        'are not cited to Flutter engine sources. v0.17.0 extends FPS '
        'semantics. `actualFps` (a rolling count in a 1 s window anchored '
        'on the latest `rasterFinishUs`) and `throughputFps` '
        '(latency-derived capacity) are separate metrics. StableId coverage '
        'is unchanged, because FPS semantics are independent of jank '
        'classification. v0.19.6 adds the capture-mode plumbing for the '
        '`jank_detected.warning` `runtimeVerified` raise. '
        '`SleuthConfig(captureMode: true)` skips the 3 s warmup gate. Each '
        'emission carries an instance-monotonic `dedupIdentityMicros` '
        '(wall-clock micros plus an `_emissionSeq` tie-breaker, kept across '
        '`reset()` so multi-leg capture flows cannot collide identities). '
        'The detector exports its observed axis values '
        '(`observedJankCount`, `observedJankPercent`, '
        '`observedWorstFrameMs`, `bufferSize`) into trace event args, so '
        'the audit gate cross-checks the operator claim against the '
        'detector observation (`observedJankPercent`, last value in the '
        'scenario).',
  );
}

class _JankBottleneck {
  const _JankBottleneck({required this.label, required this.summary});
  const _JankBottleneck.none() : label = '', summary = '';
  final String label;
  final String summary;
}
