import 'dart:collection';
import 'dart:math' as math;

/// A single frame's timing data from [SchedulerBinding.addTimingsCallback].
class FrameStats {
  const FrameStats({
    required this.frameNumber,
    required this.uiDuration,
    required this.rasterDuration,
    required this.timestamp,
    this.vsyncOverhead = Duration.zero,
    this.layerCacheCount = 0,
    this.layerCacheBytes = 0,
    this.pictureCacheCount = 0,
    this.pictureCacheBytes = 0,
    this.frameBudgetMs = 16,
    this.totalSpan,
    this.buildToRasterGap = Duration.zero,
    this.vsyncStartUs,
    this.buildStartUs,
    this.buildFinishUs,
    this.rasterStartUs,
    this.rasterFinishUs,
  });

  /// Sequential frame number since monitoring started.
  final int frameNumber;

  /// Time spent on the UI thread (build + layout + paint).
  final Duration uiDuration;

  /// Time spent on the raster thread (compositing + GPU submission).
  final Duration rasterDuration;

  /// Wall-clock time when this frame was recorded.
  final DateTime timestamp;

  /// Time waiting for vsync before build starts — indicates scheduler pressure.
  final Duration vsyncOverhead;

  /// Number of layers stored in the raster cache during this frame.
  final int layerCacheCount;

  /// Raster cache size in bytes for layer cache.
  final int layerCacheBytes;

  /// Number of pictures stored in the raster cache during this frame.
  final int pictureCacheCount;

  /// Raster cache size in bytes for picture cache.
  final int pictureCacheBytes;

  /// Combined raster cache size: picture cache + layer cache.
  int get totalCacheBytes => pictureCacheBytes + layerCacheBytes;

  /// Frame time budget in milliseconds, derived from target FPS.
  /// 60 fps → 16ms, 120 fps → 8ms.
  final int frameBudgetMs;

  /// End-to-end frame latency (vsyncStart → rasterFinish).
  /// Null for test-created frames; populated from [FrameTiming.totalSpan].
  final Duration? totalSpan;

  /// Pipeline handoff latency (buildFinish → rasterStart).
  /// Indicates the raster thread was busy with the previous frame.
  final Duration buildToRasterGap;

  /// Absolute monotonic timestamps (μs) from [FrameTiming.timestampInMicroseconds].
  /// Null for test-created frames; populated from real [FrameTiming] callbacks.
  /// Used by [FrameEventCorrelator] to match VM timeline events to specific frames.
  final int? vsyncStartUs;
  final int? buildStartUs;
  final int? buildFinishUs;
  final int? rasterStartUs;
  final int? rasterFinishUs;

  /// Whether all phase timestamps are available for frame-event correlation.
  bool get hasPhaseTimestamps =>
      vsyncStartUs != null &&
      buildStartUs != null &&
      buildFinishUs != null &&
      rasterStartUs != null &&
      rasterFinishUs != null;

  Map<String, dynamic> toJson() => {
        'frameNumber': frameNumber,
        'uiDurationUs': uiDuration.inMicroseconds,
        'rasterDurationUs': rasterDuration.inMicroseconds,
        'timestamp': timestamp.toIso8601String(),
        'vsyncOverheadUs': vsyncOverhead.inMicroseconds,
        'layerCacheCount': layerCacheCount,
        'layerCacheBytes': layerCacheBytes,
        'pictureCacheCount': pictureCacheCount,
        'pictureCacheBytes': pictureCacheBytes,
        'frameBudgetMs': frameBudgetMs,
        if (totalSpan != null) 'totalSpanUs': totalSpan!.inMicroseconds,
        if (buildToRasterGap != Duration.zero)
          'buildToRasterGapUs': buildToRasterGap.inMicroseconds,
        if (vsyncStartUs != null) 'vsyncStartUs': vsyncStartUs,
        if (buildStartUs != null) 'buildStartUs': buildStartUs,
        if (buildFinishUs != null) 'buildFinishUs': buildFinishUs,
        if (rasterStartUs != null) 'rasterStartUs': rasterStartUs,
        if (rasterFinishUs != null) 'rasterFinishUs': rasterFinishUs,
      };

  factory FrameStats.fromJson(Map<String, dynamic> json) => FrameStats(
        frameNumber: json['frameNumber'] as int,
        uiDuration: Duration(microseconds: json['uiDurationUs'] as int),
        rasterDuration: Duration(microseconds: json['rasterDurationUs'] as int),
        timestamp: DateTime.parse(json['timestamp'] as String),
        vsyncOverhead:
            Duration(microseconds: json['vsyncOverheadUs'] as int? ?? 0),
        layerCacheCount: json['layerCacheCount'] as int? ?? 0,
        layerCacheBytes: json['layerCacheBytes'] as int? ?? 0,
        pictureCacheCount: json['pictureCacheCount'] as int? ?? 0,
        pictureCacheBytes: json['pictureCacheBytes'] as int? ?? 0,
        frameBudgetMs: json['frameBudgetMs'] as int? ?? 16,
        totalSpan: json['totalSpanUs'] != null
            ? Duration(microseconds: json['totalSpanUs'] as int)
            : null,
        buildToRasterGap:
            Duration(microseconds: json['buildToRasterGapUs'] as int? ?? 0),
        vsyncStartUs: json['vsyncStartUs'] as int?,
        buildStartUs: json['buildStartUs'] as int?,
        buildFinishUs: json['buildFinishUs'] as int?,
        rasterStartUs: json['rasterStartUs'] as int?,
        rasterFinishUs: json['rasterFinishUs'] as int?,
      );

  Duration get totalDuration {
    final ui = uiDuration.inMicroseconds;
    final raster = rasterDuration.inMicroseconds;
    return Duration(microseconds: ui > raster ? ui : raster);
  }

  /// End-to-end frame duration for jank detection and display.
  /// Uses [totalSpan] when available (real frames from [FrameTiming]),
  /// falls back to [totalDuration] (max of UI/raster) for test-created frames.
  Duration get effectiveTotalDuration => totalSpan ?? totalDuration;

  bool get isJank => effectiveTotalDuration.inMilliseconds > frameBudgetMs;
  bool get isSevereJank =>
      effectiveTotalDuration.inMilliseconds > frameBudgetMs * 2;
}

/// Circular buffer holding the last [capacity] frames for live display.
class FrameStatsBuffer {
  FrameStatsBuffer({this.capacity = 60});

  /// Shallow copy — shares [FrameStats] instances (they're immutable).
  factory FrameStatsBuffer.from(FrameStatsBuffer other) {
    final copy = FrameStatsBuffer(capacity: other.capacity);
    copy._buffer.addAll(other._buffer);
    return copy;
  }

  final int capacity;
  final Queue<FrameStats> _buffer = Queue<FrameStats>();
  List<FrameStats>? _cachedFrames;
  bool _percentilesDirty = true;
  FpsPercentiles? _cachedPercentiles;

  List<FrameStats> get frames => _cachedFrames ??= List.unmodifiable(_buffer);
  int get length => _buffer.length;
  bool get isEmpty => _buffer.isEmpty;

  FrameStats? get latest => _buffer.isEmpty ? null : _buffer.last;

  /// Processing-throughput FPS: how many frames/sec the engine could produce
  /// given the average [effectiveTotalDuration].
  ///
  /// Capped at 120. The UI further caps at [SleuthConfig.fpsTarget] so an
  /// idle screen in profile mode shows the target (e.g. 60).
  ///
  /// In debug mode, idle screens may show lower FPS due to debug overhead —
  /// this is expected. Always use profile mode for reliable FPS readings.
  double get averageFps {
    if (_buffer.isEmpty) return 0;
    final totalUs = _buffer.fold<int>(
      0,
      (sum, f) => sum + f.effectiveTotalDuration.inMicroseconds,
    );
    if (totalUs == 0) return 0;
    return (1000000.0 / (totalUs / _buffer.length)).clamp(0, 120);
  }

  int get jankCount => _buffer.where((f) => f.isJank).length;

  void add(FrameStats frame) {
    if (_buffer.length >= capacity) {
      _buffer.removeFirst();
    }
    _buffer.add(frame);
    _cachedFrames = null;
    _percentilesDirty = true;
  }

  /// Computes FPS percentiles from the current buffer contents.
  ///
  /// Converts each frame's [FrameStats.effectiveTotalDuration] to an
  /// instantaneous FPS value, then picks p50/p95/p99 from the sorted list.
  /// All values clamped to [0, 120] to match [averageFps] behavior.
  ///
  /// Returns zero percentiles when the buffer has fewer than 2 frames
  /// (statistically meaningless). Consumers should check
  /// [FrameStatsSummary.totalFrames] to judge significance.
  FpsPercentiles fpsPercentiles() {
    if (_buffer.length < 2) {
      return const FpsPercentiles(p50: 0, p95: 0, p99: 0);
    }
    if (!_percentilesDirty && _cachedPercentiles != null) {
      return _cachedPercentiles!;
    }
    final fpsValues = _buffer.map((f) {
      final us = f.effectiveTotalDuration.inMicroseconds;
      if (us <= 0) return 120.0;
      return (1000000.0 / us).clamp(0.0, 120.0);
    }).toList()
      ..sort();

    double percentile(double p) {
      final index = ((fpsValues.length - 1) * p).floor();
      return double.parse(
          fpsValues[math.min(index, fpsValues.length - 1)].toStringAsFixed(1));
    }

    _cachedPercentiles = FpsPercentiles(
      p50: percentile(0.5),
      p95: percentile(0.95),
      p99: percentile(0.99),
    );
    _percentilesDirty = false;
    return _cachedPercentiles!;
  }

  void clear() {
    _buffer.clear();
    _cachedFrames = null;
    _percentilesDirty = true;
    _cachedPercentiles = null;
  }
}

/// FPS percentile values computed from a [FrameStatsBuffer].
class FpsPercentiles {
  const FpsPercentiles({
    required this.p50,
    required this.p95,
    required this.p99,
  });

  /// Median FPS — 50th percentile.
  final double p50;

  /// 95th percentile FPS — tail latency indicator.
  final double p95;

  /// 99th percentile FPS — worst-case indicator.
  final double p99;

  Map<String, dynamic> toJson() => {
        'p50': double.parse(p50.toStringAsFixed(1)),
        'p95': double.parse(p95.toStringAsFixed(1)),
        'p99': double.parse(p99.toStringAsFixed(1)),
      };

  factory FpsPercentiles.fromJson(Map<String, dynamic> json) => FpsPercentiles(
        p50: (json['p50'] as num).toDouble(),
        p95: (json['p95'] as num).toDouble(),
        p99: (json['p99'] as num).toDouble(),
      );
}
