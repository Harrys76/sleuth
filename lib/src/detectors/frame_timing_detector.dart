import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/frame_stats.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Detects jank frames using [SchedulerBinding.addTimingsCallback] (fast,
/// every frame) and optionally augments with exact VM Timeline phase data.
///
/// **Runtime Detector** — near-zero overhead, always available.
class FrameTimingDetector extends BaseDetector {
  FrameTimingDetector({
    int? warningThresholdMs,
    int? criticalThresholdMs,
    this.fpsTarget = 60,
    this.onFrameStats,
  })  : warningThresholdMs = warningThresholdMs ?? (1000 ~/ fpsTarget),
        criticalThresholdMs = criticalThresholdMs ?? ((1000 ~/ fpsTarget) * 2),
        super(
          type: DetectorType.frameTiming,
          lifecycle: DetectorLifecycle.runtime,
          name: 'Frame Timing',
          description: 'Detects jank frames via frame budget '
              '(${warningThresholdMs ?? 1000 ~/ fpsTarget}ms)',
        );

  final int warningThresholdMs;
  final int criticalThresholdMs;
  final int fpsTarget;
  final void Function(FrameStatsBuffer buffer)? onFrameStats;

  final FrameStatsBuffer _buffer = FrameStatsBuffer();
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;
  int _frameNumber = 0;
  TimingsCallback? _callback;

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
  @visibleForTesting
  void addFrameForTest(FrameStats stats) {
    if (!_isEnabled) return;
    _buffer.add(stats);
    _evaluateJank();
    _evaluateCacheTrends();
    onFrameStats?.call(_buffer);
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

      // Extract all 5 phase timestamps for frame-event correlation.
      final vsyncStartUs =
          timing.timestampInMicroseconds(FramePhase.vsyncStart);
      final buildStartUs =
          timing.timestampInMicroseconds(FramePhase.buildStart);
      final buildFinishUs =
          timing.timestampInMicroseconds(FramePhase.buildFinish);
      final rasterStartUs =
          timing.timestampInMicroseconds(FramePhase.rasterStart);
      final rasterFinishUs =
          timing.timestampInMicroseconds(FramePhase.rasterFinish);

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
  void _evaluateJank() {
    _issues.removeWhere(
        (i) => i.stableId == 'sustained_jank' || i.stableId == 'jank_detected');

    final frames = _buffer.frames;
    if (frames.length < 5) return; // Need enough data

    final severeCount = frames.where((f) => f.isSevereJank).length;
    final jankCount = frames.where((f) => f.isJank).length;
    final jankPercent = (jankCount / frames.length * 100).round();

    if (severeCount >= 3) {
      final worstFrame = frames.reduce(
        (a, b) => a.effectiveTotalDuration > b.effectiveTotalDuration ? a : b,
      );
      final (hint1, effort1) = FixHintBuilder.sustainedJank();
      _issues.add(
        PerformanceIssue(
          stableId: 'sustained_jank',
          severity: IssueSeverity.critical,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title:
              'Sustained Jank: $severeCount severe frames ($jankPercent% janky)',
          detail: _buildDetail(worstFrame),
          fixHint: hint1,
          fixEffort: effort1,
          detectedAt: DateTime.now(),
        ),
      );
    } else if (jankPercent > 15) {
      final worstFrame = frames.reduce(
        (a, b) => a.effectiveTotalDuration > b.effectiveTotalDuration ? a : b,
      );
      final (hint2, effort2) = FixHintBuilder.jankDetected();
      _issues.add(
        PerformanceIssue(
          stableId: 'jank_detected',
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title: 'Jank Detected: $jankPercent% of frames over budget',
          detail: _buildDetail(worstFrame),
          fixHint: hint2,
          fixEffort: effort2,
          detectedAt: DateTime.now(),
        ),
      );
    }
  }

  void _evaluateCacheTrends() {
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
    if (previous.pictureCacheCount > 0) {
      final delta =
          (latest.pictureCacheCount - previous.pictureCacheCount).abs();
      final variation = delta / previous.pictureCacheCount;
      if (variation > _thrashingVariationPercent) {
        _consecutiveThrashingFrames++;
      } else {
        _consecutiveThrashingFrames = 0;
      }
    } else if (latest.pictureCacheCount > 0) {
      // Jump from 0 to non-zero counts as thrashing
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
      ));
    }
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
    _consecutiveThrashingFrames = 0;
    _consecutiveGrowthFrames = 0;
    _consecutiveZeroCacheFrames = 0;
    _impellerDetected = false;
    _lastTimelineData = null;
  }
}
