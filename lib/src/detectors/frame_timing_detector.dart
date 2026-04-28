import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/frame_stats.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Detects jank frames using [SchedulerBinding.addTimingsCallback] (fast,
/// every frame) and optionally augments with exact VM Timeline phase data.
///
/// **Runtime Detector** — near-zero overhead, always available.
class FrameTimingDetector extends BaseDetector with DetectorMetadataProvider {
  FrameTimingDetector({
    int? warningThresholdMs,
    int? criticalThresholdMs,
    this.fpsTarget = 60,
    this.warmupFrameCount = 0,
    this.warmupDuration = _defaultWarmupDuration,
    this.captureMode = false,
    this.onFrameStats,
  })  : warningThresholdMs = warningThresholdMs ??
            _thresholdFromFpsTarget(fpsTarget, criticalMultiplier: 1),
        criticalThresholdMs = criticalThresholdMs ??
            _thresholdFromFpsTarget(fpsTarget, criticalMultiplier: 2),
        super(
          type: DetectorType.frameTiming,
          lifecycle: DetectorLifecycle.runtime,
          name: 'Frame Timing',
          description: 'Detects jank frames via frame budget '
              '(${warningThresholdMs ?? _thresholdFromFpsTarget(fpsTarget, criticalMultiplier: 1)}ms)',
        );

  /// Validates `fpsTarget` before integer-dividing by it. The
  /// `SleuthConfig` assert guard is stripped in profile/release, so without
  /// this check `fpsTarget: 0` would surface as
  /// `UnsupportedError: Result of truncating division is Infinity`.
  static int _thresholdFromFpsTarget(int fpsTarget,
      {required int criticalMultiplier}) {
    if (fpsTarget < 1 || fpsTarget > 240) {
      throw ArgumentError.value(
        fpsTarget,
        'fpsTarget',
        'must be in [1, 240]',
      );
    }
    return (1000 ~/ fpsTarget) * criticalMultiplier;
  }

  final int warningThresholdMs;
  final int criticalThresholdMs;
  final int fpsTarget;

  /// Legacy frame-count gate (AND-combined with [warmupDuration]).
  ///
  /// Kept for callers that want an explicit frame-based floor. Default is 0
  /// (disabled) — the refresh-rate-independent [warmupDuration] gate is the
  /// primary warmup mechanism as of v0.16.0. See v0.16.0 C1 fix: the old
  /// default of 180 frames meant warmup ended in 1.5 s on 120 Hz displays,
  /// which misattributed startup jank as real jank on every iPad Pro /
  /// Pixel 8 Pro session.
  final int warmupFrameCount;

  /// Wall-clock gate suppressing jank evaluation during app warmup
  /// (shader compilation, route init, Dart VM JIT). Refresh-rate
  /// independent. Measured against the timestamp of the first frame the
  /// detector observes, not app-launch time.
  final Duration warmupDuration;

  /// Capture-mode short-circuit. When `true`, [_isPastWarmup] returns
  /// `true` immediately regardless of [warmupDuration] / [warmupFrameCount].
  /// Set via `SleuthConfig.captureMode` and plumbed by `SleuthController` so
  /// in-app capture screens can bracket the `jank_detected.warning` axis
  /// inside a 4 s scenario span without waiting out the 3 s warmup.
  /// Default `false` — never engaged in normal app sessions.
  final bool captureMode;

  final void Function(FrameStatsBuffer buffer)? onFrameStats;

  // Fixed 240 so `actualFpsRaw` reports the true device rate regardless of
  // [fpsTarget]. A target-derived capacity would cap the count below the
  // device refresh (e.g. 60 at fpsTarget=30 on a 120 Hz panel).
  static const int _bufferCapacity = 240;
  late final FrameStatsBuffer _buffer =
      FrameStatsBuffer(capacity: _bufferCapacity);
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
      final budgetUs = (1000000 / fpsTarget).round();
      stats = stats.copyWith(rasterFinishUs: latest + budgetUs);
    }
    _totalFramesSeen++;
    _firstFrameTimestamp ??= stats.timestamp;
    if (stats.vsyncStartUs != null) {
      _firstFrameVsyncUs ??= stats.vsyncStartUs;
    }
    _buffer.add(stats);
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
      final vsyncStartUs =
          timing.timestampInMicroseconds(FramePhase.vsyncStart);
      _firstFrameVsyncUs ??= vsyncStartUs;
      final buildStartUs =
          timing.timestampInMicroseconds(FramePhase.buildStart);
      final buildFinishUs =
          timing.timestampInMicroseconds(FramePhase.buildFinish);
      final rasterStartUs =
          timing.timestampInMicroseconds(FramePhase.rasterStart);
      final rasterFinishRaw =
          timing.timestampInMicroseconds(FramePhase.rasterFinish);
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
        frameBudgetMs: warningThresholdMs,
        totalSpan: timing.totalSpan,
        buildToRasterGap: Duration(microseconds: gapUs > 0 ? gapUs : 0),
        vsyncStartUs: vsyncStartUs,
        buildStartUs: buildStartUs,
        buildFinishUs: buildFinishUs,
        rasterStartUs: rasterStartUs,
        rasterFinishUs: rasterFinishUs,
      );

      _buffer.add(stats);
    }

    // Evaluate jank based on recent buffer pattern, not individual frames.
    // This avoids noisy single-frame alerts (e.g. 16ms from the overlay itself).
    _evaluateJank();
    _evaluateCacheTrends();

    onFrameStats?.call(_buffer);
  }

  /// Only report jank as an issue when it's a sustained pattern:
  /// - Critical: ≥3 severe jank frames (>33ms) in the last 60 frames
  /// - Warning: >15% of recent frames are janky (>16ms)
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
  /// IssueRanker composite-score ordering (severity weight 100 keeps
  /// critical above warning regardless).
  void _evaluateJank() {
    _issues.removeWhere(
        (i) => i.stableId == 'sustained_jank' || i.stableId == 'jank_detected');

    // Suppress jank evaluation during warmup period (shader compilation,
    // route init, Dart VM warmup produce non-actionable jank).
    if (!_isPastWarmup()) return;

    final frames = _buffer.frames;
    if (frames.length < 5) return; // Need enough data

    // Single-pass: count jank categories and find worst frame (v9.10).
    int severeCount = 0, jankCount = 0;
    FrameStats worst = frames.first;
    for (final f in frames) {
      if (f.isSevereJank) severeCount++;
      if (f.isJank) jankCount++;
      if (f.effectiveTotalDuration > worst.effectiveTotalDuration) worst = f;
    }
    final jankPercent = (jankCount / frames.length * 100).round();

    // Classify jank frames by bottleneck thread for attribution.
    final bottleneck = _classifyJankBottleneck(frames);

    if (severeCount >= 3) {
      final (hint1, effort1) = FixHintBuilder.sustainedJank();
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
          detectedAt: DateTime.now(),
          confidenceReason: 'Measured directly from FrameTiming API',
        ),
      );
    }
    if (jankPercent > 15) {
      final (hint2, effort2) = FixHintBuilder.jankDetected();
      final worstMs = worst.effectiveTotalDuration.inMicroseconds / 1000.0;
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
          // Detector-observed axis values exported into trace event args so
          // the audit-gate can cross-check the operator's `magnitudeObserved`
          // (operator-typed claim) against what the detector actually saw at
          // fire time. Stringified per Timeline arg-encoding contract.
          extraTraceArgs: {
            'observedJankCount': jankCount.toString(),
            'observedJankPercent': jankPercent.toStringAsFixed(2),
            'observedWorstFrameMs': worstMs.toStringAsFixed(2),
            'bufferSize': frames.length.toString(),
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
    final allZero = latest.layerCacheCount == 0 &&
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
      _issues.removeWhere((i) =>
          i.stableId == 'raster_cache_thrashing' ||
          i.stableId == 'raster_cache_growing');
      return;
    }

    // --- Cache thrashing: pictureCacheCount fluctuates > 20% ---
    if (previous.pictureCacheCount > 5) {
      final delta =
          (latest.pictureCacheCount - previous.pictureCacheCount).abs();
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
    _issues.removeWhere((i) =>
        i.stableId == 'raster_cache_thrashing' ||
        i.stableId == 'raster_cache_growing');

    if (_consecutiveThrashingFrames >= _thrashingWindowFrames) {
      final (hint, effort) = FixHintBuilder.rasterCacheThrashing();
      _issues.add(PerformanceIssue(
        stableId: 'raster_cache_thrashing',
        severity: IssueSeverity.warning,
        category: IssueCategory.raster,
        confidence: IssueConfidence.confirmed,
        title: 'Raster Cache Thrashing: '
            '$_consecutiveThrashingFrames consecutive frames',
        detail: 'Picture cache count is fluctuating by >20% between '
            'consecutive frames for $_consecutiveThrashingFrames frames. '
            'Current count: ${latest.pictureCacheCount}, '
            'previous: ${previous.pictureCacheCount}. '
            'The cache is too small or content is not reusable.',
        fixHint: hint,
        fixEffort: effort,
        detectedAt: DateTime.now(),
        confidenceReason: 'Measured directly from FrameTiming API',
      ));
    }

    if (_consecutiveGrowthFrames >= _growthWindowFrames) {
      final totalKb = latest.totalCacheBytes / 1024;
      final (hint, effort) = FixHintBuilder.rasterCacheGrowing();
      _issues.add(PerformanceIssue(
        stableId: 'raster_cache_growing',
        severity: IssueSeverity.warning,
        category: IssueCategory.raster,
        confidence: IssueConfidence.confirmed,
        title: 'Raster Cache Growing: '
            '${totalKb.toStringAsFixed(0)} KB over '
            '$_consecutiveGrowthFrames frames',
        detail: 'Total raster cache bytes have been growing monotonically '
            'for $_consecutiveGrowthFrames consecutive frames. '
            'Picture cache: ${(latest.pictureCacheBytes / 1024).toStringAsFixed(0)} KB, '
            'Layer cache: ${(latest.layerCacheBytes / 1024).toStringAsFixed(0)} KB. '
            'This may indicate unbounded cache accumulation.',
        fixHint: hint,
        fixEffort: effort,
        detectedAt: DateTime.now(),
        confidenceReason: 'Measured directly from FrameTiming API',
      ));
    }
  }

  /// Classify jank frames by which thread is the bottleneck.
  _JankBottleneck _classifyJankBottleneck(List<FrameStats> frames) {
    int uiBound = 0, rasterBound = 0, pipelineStall = 0;
    final budgetUs = warningThresholdMs * 1000;

    for (final f in frames) {
      if (!f.isJank) continue;
      if (f.buildToRasterGap.inMicroseconds > budgetUs ~/ 4 &&
          f.uiDuration.inMicroseconds < budgetUs &&
          f.rasterDuration.inMicroseconds < budgetUs) {
        pipelineStall++;
      } else if (f.uiDuration > f.rasterDuration) {
        uiBound++;
      } else {
        rasterBound++;
      }
    }

    final total = uiBound + rasterBound + pipelineStall;
    if (total == 0) return const _JankBottleneck.none();

    if (pipelineStall > uiBound && pipelineStall > rasterBound) {
      return _JankBottleneck(
        label: ' (pipeline stall)',
        summary: 'Thread attribution: $uiBound UI-bound, '
            '$rasterBound raster-bound, $pipelineStall pipeline stall '
            '— raster thread backed up from previous frames.',
      );
    }
    if (uiBound > rasterBound) {
      return _JankBottleneck(
        label: ' (UI-bound)',
        summary: 'Thread attribution: $uiBound UI-bound, '
            '$rasterBound raster-bound, $pipelineStall pipeline stall '
            '— focus on reducing build/layout/paint work.',
      );
    }
    if (rasterBound > uiBound) {
      return _JankBottleneck(
        label: ' (raster-bound)',
        summary: 'Thread attribution: $uiBound UI-bound, '
            '$rasterBound raster-bound, $pipelineStall pipeline stall '
            '— focus on reducing GPU compositing work.',
      );
    }
    return _JankBottleneck(
      label: ' (mixed)',
      summary: 'Thread attribution: $uiBound UI-bound, '
          '$rasterBound raster-bound, $pipelineStall pipeline stall.',
    );
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
      buf.writeln(
        'Vsync overhead: '
        '${(stats.vsyncOverhead.inMicroseconds / 1000).toStringAsFixed(1)}ms',
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

    // Bottleneck hint with pipeline stall detection
    final budgetUs = stats.frameBudgetMs * 1000;
    if (stats.buildToRasterGap.inMicroseconds > budgetUs ~/ 4 &&
        stats.uiDuration.inMicroseconds < budgetUs &&
        stats.rasterDuration.inMicroseconds < budgetUs) {
      buf.writeln(
        'Bottleneck: Pipeline stall '
        '(raster thread backed up from previous frame)',
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
  }

  /// Capture-mode reset hook. Clears all per-leg state — buffer, ephemeral
  /// `_issues`, warmup anchors, cache-trend counters — so back-to-back
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
        // jank_detected raised to runtimeVerified via perStableIdTier.
        // Other 3 stableIds stay implicit reproducerOnly.
        perStableIdTier: {
          'jank_detected': EvidenceTier.runtimeVerified,
        },
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
        coveredThresholds: {'jank_detected.warning'},
        observedAxisArgKey: 'observedJankPercent',
        observedAxisTolerance: 0.25,
        observedAxisReduction: 'last',
        bracketRequireUniqueDetectedAtMicros: true,
        rationale: 'Four stableIds pinned by hermetic reproducer: '
            '`sustained_jank` (≥3 severe frames in a 60-frame window), '
            '`jank_detected` (>15% jank frames, ≥5-frame sample), '
            '`raster_cache_thrashing` (≥15 consecutive frames of '
            '≥20% picture-cache-count fluctuation, seeded by '
            '`previous.pictureCacheCount > 5`), and `raster_cache_growing` '
            '(≥30 consecutive frames of monotonic picture-cache-count '
            'growth). Reproducer bypasses warmup via '
            '`warmupDuration: Duration.zero`; every stableId has a synthetic '
            '`FrameStats` path plus a real `FrameTiming` integration leg via '
            '`handleTimingsForTest` so hand-written synthetic fixtures cannot '
            'encode the detector\'s own expected shape (anti-tautology, '
            'Tactic 9). Impeller-zero suppression (all four cache metrics '
            'zero for ≥30 frames) pinned by a dedicated `pictureCacheBytes: 1` '
            'belt-and-suspender test so cache-family issues are not '
            'silently suppressed. Not yet cited to Flutter engine sources or '
            'verified via a profile-mode capture on a reference device; '
            'v0.16.N re-raise to `externallyCited` requires either a Flutter '
            'docs citation matching the 16.67 ms budget semantics or a '
            'runtime-verified capture triad with a detector-emitted '
            'trace record inside the scenario window. '
            'v0.17.0 extends FPS semantics: `actualFps` (rolling count in '
            '1-s window anchored on latest `rasterFinishUs`) and '
            '`throughputFps` (latency-derived capacity) are exposed as '
            'distinct metrics. StableId coverage unchanged — FPS semantics '
            'are orthogonal to jank classification. '
            'v0.19.6 lands the capture-mode plumbing for a future '
            '`jank_detected.warning` `runtimeVerified` raise: '
            '`SleuthConfig(captureMode: true)` short-circuits the 3 s '
            'warmup gate; emission carries an instance-monotonic '
            '`dedupIdentityMicros` (wall-clock micros + `_emissionSeq` '
            'tie-breaker, preserved across `reset()` so multi-leg capture '
            'flows cannot collide identities); detector-observed axis '
            'values (`observedJankCount`, `observedJankPercent`, '
            '`observedWorstFrameMs`, `bufferSize`) are exported into '
            'trace event args so a future audit-gate cross-check can '
            'validate operator claim against detector observation. The '
            'tier raise itself is deferred until three on-device captures '
            '(iPhone 12 / iOS 17.5 / Flutter 3.41.x, 60 Hz) land at '
            '`test/validation/captures/frame_timing/jank_detected_'
            '{below,at,above}.json` bracketing 36 jank-frames in a '
            'steady-state 240-frame buffer.',
      );
}

class _JankBottleneck {
  const _JankBottleneck({required this.label, required this.summary});
  const _JankBottleneck.none()
      : label = '',
        summary = '';
  final String label;
  final String summary;
}
