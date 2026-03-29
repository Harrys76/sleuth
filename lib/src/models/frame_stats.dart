import 'dart:collection';

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

  List<FrameStats> get frames => _buffer.toList();
  int get length => _buffer.length;
  bool get isEmpty => _buffer.isEmpty;

  FrameStats? get latest => _buffer.isEmpty ? null : _buffer.last;

  double get averageFps {
    if (_buffer.isEmpty) return 0;
    final totalMs = _buffer.fold<int>(
      0,
      (sum, f) => sum + f.effectiveTotalDuration.inMilliseconds,
    );
    if (totalMs == 0) return 60;
    final fps = 1000.0 / (totalMs / _buffer.length);
    // Cap at display refresh rate — processing time can be <16ms
    // but the screen only refreshes at 60Hz (or 120Hz).
    return fps.clamp(0, 120);
  }

  int get jankCount => _buffer.where((f) => f.isJank).length;

  void add(FrameStats frame) {
    if (_buffer.length >= capacity) {
      _buffer.removeFirst();
    }
    _buffer.add(frame);
  }

  void clear() => _buffer.clear();
}
