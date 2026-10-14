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
    int? frameBudgetMs,
    int? frameBudgetUs,
    this.totalSpan,
    this.buildToRasterGap = Duration.zero,
    this.vsyncStartUs,
    this.buildStartUs,
    this.buildFinishUs,
    this.rasterStartUs,
    this.rasterFinishUs,
    this.ownStartDelayUs = 0,
  }) : frameBudgetMs =
           frameBudgetMs ??
           (frameBudgetUs == null ? 16 : frameBudgetUs ~/ 1000),
       frameBudgetUs = frameBudgetUs ?? (frameBudgetMs ?? 16) * 1000;

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

  /// Frame time budget in whole milliseconds (`frameBudgetUs ~/ 1000`
  /// when only [frameBudgetUs] is given; default 16). Kept for display and
  /// JSON compatibility; jank classification uses [frameBudgetUs].
  final int frameBudgetMs;

  /// Frame time budget in microseconds. Defaults to `frameBudgetMs * 1000`
  /// when omitted. Frames from `FrameTimingDetector` carry the resolved
  /// budget (16667 at 60 Hz, 8333 at 120 Hz).
  final int frameBudgetUs;

  /// End-to-end frame latency (vsyncStart → rasterFinish).
  /// Null for test-created frames; populated from [FrameTiming.totalSpan].
  final Duration? totalSpan;

  /// Pipeline handoff latency (buildFinish → rasterStart).
  /// Indicates the raster thread was busy with the previous frame.
  final Duration buildToRasterGap;

  /// Absolute monotonic timestamps (μs) from [FrameTiming.timestampInMicroseconds].
  /// Null for test-created frames; populated from real [FrameTiming] callbacks.
  /// Used by `FrameEventCorrelator` to match VM timeline events to specific frames.
  final int? vsyncStartUs;
  final int? buildStartUs;
  final int? buildFinishUs;
  final int? rasterStartUs;
  final int? rasterFinishUs;

  /// Microseconds of [vsyncOverhead] during which Sleuth itself kept the UI
  /// isolate busy (scanning the tree, decoding a VM response), from
  /// `OwnWorkLog`. Zero for frames built outside `FrameTimingDetector`.
  final int ownStartDelayUs;

  /// The app's share of the start delay: [vsyncOverhead] minus
  /// [ownStartDelayUs].
  int get appStartDelayUs {
    final delay = vsyncOverhead.inMicroseconds - ownStartDelayUs;
    return delay > 0 ? delay : 0;
  }

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
    'frameBudgetUs': frameBudgetUs,
    if (totalSpan != null) 'totalSpanUs': totalSpan!.inMicroseconds,
    if (buildToRasterGap != Duration.zero)
      'buildToRasterGapUs': buildToRasterGap.inMicroseconds,
    if (vsyncStartUs != null) 'vsyncStartUs': vsyncStartUs,
    if (buildStartUs != null) 'buildStartUs': buildStartUs,
    if (buildFinishUs != null) 'buildFinishUs': buildFinishUs,
    if (rasterStartUs != null) 'rasterStartUs': rasterStartUs,
    if (rasterFinishUs != null) 'rasterFinishUs': rasterFinishUs,
    if (ownStartDelayUs != 0) 'ownStartDelayUs': ownStartDelayUs,
  };

  factory FrameStats.fromJson(Map<String, dynamic> json) => FrameStats(
    frameNumber: json['frameNumber'] as int,
    uiDuration: Duration(microseconds: json['uiDurationUs'] as int),
    rasterDuration: Duration(microseconds: json['rasterDurationUs'] as int),
    timestamp: DateTime.parse(json['timestamp'] as String),
    vsyncOverhead: Duration(microseconds: json['vsyncOverheadUs'] as int? ?? 0),
    layerCacheCount: json['layerCacheCount'] as int? ?? 0,
    layerCacheBytes: json['layerCacheBytes'] as int? ?? 0,
    pictureCacheCount: json['pictureCacheCount'] as int? ?? 0,
    pictureCacheBytes: json['pictureCacheBytes'] as int? ?? 0,
    frameBudgetMs: json['frameBudgetMs'] as int? ?? 16,
    frameBudgetUs:
        json['frameBudgetUs'] as int? ??
        (json['frameBudgetMs'] as int? ?? 16) * 1000,
    totalSpan: json['totalSpanUs'] != null
        ? Duration(microseconds: json['totalSpanUs'] as int)
        : null,
    buildToRasterGap: Duration(
      microseconds: json['buildToRasterGapUs'] as int? ?? 0,
    ),
    vsyncStartUs: json['vsyncStartUs'] as int?,
    buildStartUs: json['buildStartUs'] as int?,
    buildFinishUs: json['buildFinishUs'] as int?,
    rasterStartUs: json['rasterStartUs'] as int?,
    rasterFinishUs: json['rasterFinishUs'] as int?,
    ownStartDelayUs: json['ownStartDelayUs'] as int? ?? 0,
  );

  Duration get totalDuration {
    final ui = uiDuration.inMicroseconds;
    final raster = rasterDuration.inMicroseconds;
    return Duration(microseconds: ui > raster ? ui : raster);
  }

  /// End-to-end frame latency for display (FPS, percentiles, the worst
  /// frame). Uses [totalSpan] when available (real frames from
  /// [FrameTiming]), falls back to [totalDuration] (max of UI/raster) for
  /// test-created frames. Jank does not use it; see [isJank].
  Duration get effectiveTotalDuration => totalSpan ?? totalDuration;

  /// A frame over this many times its budget is a severe jank frame.
  static const int severeJankBudgetMultiplier = 2;

  /// Whether the frame missed its deadline on one thread: the app's start
  /// delay plus the build ran over the budget on the UI thread, or the
  /// raster ran over it on the raster thread.
  ///
  /// The wait between build finish and raster start does not count. In
  /// that wait the raster thread was finishing the previous frame, and that
  /// frame already counts when its own raster ran over. The start delay
  /// does count, because a UI thread busy with timers, platform messages or
  /// microtasks when the vsync arrives delays the frame on screen. Sleuth's
  /// own share of it ([ownStartDelayUs]) is left out. A negative raster
  /// duration (no raster finish recorded) only leaves the raster side
  /// unjudged.
  bool get isJank => _missedDeadline(1, appDelayOnly: true);

  /// [isJank] at [severeJankBudgetMultiplier] times the budget.
  bool get isSevereJank =>
      _missedDeadline(severeJankBudgetMultiplier, appDelayOnly: true);

  /// Whether the frame is late only because of Sleuth's own work. It
  /// misses the deadline with the full start delay and meets it with the
  /// app's share alone.
  bool get isSleuthOverhead =>
      !isJank && _missedDeadline(1, appDelayOnly: false);

  bool _missedDeadline(int multiplier, {required bool appDelayOnly}) {
    final budgetUs = frameBudgetUs * multiplier;
    if (rasterDuration.inMicroseconds > budgetUs) return true;
    final delayUs = appDelayOnly
        ? appStartDelayUs
        : vsyncOverhead.inMicroseconds;
    return delayUs + uiDuration.inMicroseconds > budgetUs;
  }

  /// Sentinel distinguishing "caller omitted the field" from "caller
  /// passed null". Nullable fields in [copyWith] accept this sentinel as
  /// default; any other value (including explicit `null`) overwrites.
  static const Object _unset = Object();

  FrameStats copyWith({
    int? frameNumber,
    Duration? uiDuration,
    Duration? rasterDuration,
    DateTime? timestamp,
    Duration? vsyncOverhead,
    int? layerCacheCount,
    int? layerCacheBytes,
    int? pictureCacheCount,
    int? pictureCacheBytes,
    int? frameBudgetMs,
    int? frameBudgetUs,
    Object? totalSpan = _unset,
    Duration? buildToRasterGap,
    Object? vsyncStartUs = _unset,
    Object? buildStartUs = _unset,
    Object? buildFinishUs = _unset,
    Object? rasterStartUs = _unset,
    Object? rasterFinishUs = _unset,
    int? ownStartDelayUs,
  }) {
    return FrameStats(
      frameNumber: frameNumber ?? this.frameNumber,
      uiDuration: uiDuration ?? this.uiDuration,
      rasterDuration: rasterDuration ?? this.rasterDuration,
      timestamp: timestamp ?? this.timestamp,
      vsyncOverhead: vsyncOverhead ?? this.vsyncOverhead,
      layerCacheCount: layerCacheCount ?? this.layerCacheCount,
      layerCacheBytes: layerCacheBytes ?? this.layerCacheBytes,
      pictureCacheCount: pictureCacheCount ?? this.pictureCacheCount,
      pictureCacheBytes: pictureCacheBytes ?? this.pictureCacheBytes,
      frameBudgetMs:
          frameBudgetMs ??
          (frameBudgetUs != null ? frameBudgetUs ~/ 1000 : this.frameBudgetMs),
      frameBudgetUs:
          frameBudgetUs ??
          (frameBudgetMs != null ? frameBudgetMs * 1000 : this.frameBudgetUs),
      totalSpan: identical(totalSpan, _unset)
          ? this.totalSpan
          : totalSpan as Duration?,
      buildToRasterGap: buildToRasterGap ?? this.buildToRasterGap,
      vsyncStartUs: identical(vsyncStartUs, _unset)
          ? this.vsyncStartUs
          : vsyncStartUs as int?,
      buildStartUs: identical(buildStartUs, _unset)
          ? this.buildStartUs
          : buildStartUs as int?,
      buildFinishUs: identical(buildFinishUs, _unset)
          ? this.buildFinishUs
          : buildFinishUs as int?,
      rasterStartUs: identical(rasterStartUs, _unset)
          ? this.rasterStartUs
          : rasterStartUs as int?,
      rasterFinishUs: identical(rasterFinishUs, _unset)
          ? this.rasterFinishUs
          : rasterFinishUs as int?,
      ownStartDelayUs: ownStartDelayUs ?? this.ownStartDelayUs,
    );
  }
}

/// Circular buffer holding the last [capacity] frames for live display.
class FrameStatsBuffer {
  FrameStatsBuffer({int? capacity, int fpsTarget = 60})
    : capacity = capacity ?? (fpsTarget * 2).clamp(60, 240);

  /// Shallow copy — shares [FrameStats] instances (they're immutable).
  ///
  /// Copies the memoised `actualFps` and `fpsPercentiles` values and
  /// their dirty flags so the copy's first read does not redundantly
  /// recompute values the source already cached. Throttled notifier
  /// emission (5 Hz × 240-entry buffer) previously re-scanned the buffer
  /// on every UI rebuild.
  factory FrameStatsBuffer.from(FrameStatsBuffer other) {
    final copy = FrameStatsBuffer(capacity: other.capacity);
    copy._buffer.addAll(other._buffer);
    copy._cachedActualFps = other._cachedActualFps;
    copy._actualFpsDirty = other._actualFpsDirty;
    copy._cachedPercentiles = other._cachedPercentiles;
    copy._percentilesDirty = other._percentilesDirty;
    return copy;
  }

  final int capacity;
  final Queue<FrameStats> _buffer = Queue<FrameStats>();
  List<FrameStats>? _cachedFrames;
  bool _percentilesDirty = true;
  FpsPercentiles? _cachedPercentiles;
  bool _actualFpsDirty = true;
  double? _cachedActualFps;

  List<FrameStats> get frames => _cachedFrames ??= List.unmodifiable(_buffer);
  int get length => _buffer.length;
  bool get isEmpty => _buffer.isEmpty;

  FrameStats? get latest => _buffer.isEmpty ? null : _buffer.last;

  /// Recomputes each buffered frame's [FrameStats.ownStartDelayUs] from
  /// [overlapUs] over its start delay, for own work logged after the frame
  /// was read (a stall measured from the next timeline poll). Returns how
  /// many frames changed.
  int refreshOwnStartDelays(int Function(int fromUs, int toUs) overlapUs) {
    var changed = 0;
    final refreshed = <FrameStats>[];
    for (final frame in _buffer) {
      final vsyncStart = frame.vsyncStartUs;
      final buildStart = frame.buildStartUs;
      if (vsyncStart != null && buildStart != null && buildStart > vsyncStart) {
        final own = overlapUs(vsyncStart, buildStart);
        if (own != frame.ownStartDelayUs) {
          refreshed.add(frame.copyWith(ownStartDelayUs: own));
          changed++;
          continue;
        }
      }
      refreshed.add(frame);
    }
    if (changed > 0) {
      _buffer
        ..clear()
        ..addAll(refreshed);
      _cachedFrames = null;
    }
    return changed;
  }

  /// Presented frames per second in the last 1 second of engine time.
  ///
  /// Counts buffer frames whose [FrameStats.rasterFinishUs] falls in
  /// `[latest - 1_000_000, latest]` (inclusive). Anchors on the latest
  /// rasterFinishUs, so batched `addTimingsCallback` delivery does not
  /// distort the count.
  ///
  /// Returns 0 when:
  ///   * no frame has a non-null rasterFinishUs, or
  ///   * `latestVsyncStartUs - latestRasterFinishUs > 1 s` (null-tail decay
  ///     — newer frames arrived without rasterFinish so the anchor is
  ///     stale and the UI warm-up gate should re-engage).
  double get actualFps {
    if (!_actualFpsDirty && _cachedActualFps != null) return _cachedActualFps!;
    final count = _countInWindow();
    _actualFpsDirty = false;
    return _cachedActualFps = count.toDouble();
  }

  /// Number of frames with non-null rasterFinishUs inside the 1-s window.
  /// UI reads this to gate the warm-up placeholder. Null-tail decay ⇒ 0
  /// for the same condition as [actualFps].
  int get windowSampleCount => _countInWindow();

  /// Shared counter for [actualFps] and [windowSampleCount].
  int _countInWindow() {
    var latestRaster = -1;
    var latestVsync = -1;
    for (final f in _buffer) {
      final raster = f.rasterFinishUs;
      if (raster != null && raster > latestRaster) latestRaster = raster;
      final vsync = f.vsyncStartUs;
      if (vsync != null && vsync > latestVsync) latestVsync = vsync;
    }
    if (latestRaster < 0) return 0;
    // Null-tail decay: engine clock advanced >1s past freshest rasterFinish.
    if (latestVsync >= 0 && latestVsync - latestRaster > 1000000) return 0;
    final windowStart = latestRaster - 1000000;
    var count = 0;
    for (final f in _buffer) {
      final ts = f.rasterFinishUs;
      if (ts != null && ts >= windowStart && ts <= latestRaster) count++;
    }
    return count;
  }

  /// Latency-derived throughput (capacity estimate):
  /// `1e6 / average(effectiveTotalDuration_us)`, clamped to ``0, 120``.
  ///
  /// Capped at 120. The UI further caps at [SleuthConfig.fpsTarget] so an
  /// idle screen in profile mode shows the target (e.g. 60).
  ///
  /// In debug mode, idle screens may show lower FPS due to debug overhead —
  /// this is expected. Always use profile mode for reliable FPS readings.
  double get throughputFps {
    if (_buffer.isEmpty) return 0;
    final totalUs = _buffer.fold<int>(
      0,
      (sum, f) => sum + f.effectiveTotalDuration.inMicroseconds,
    );
    if (totalUs == 0) return 0;
    return (1000000.0 / (totalUs / _buffer.length)).clamp(0, 120);
  }

  /// Alias for [throughputFps] retained for backward compatibility.
  double get averageFps => throughputFps;

  int get jankCount => _buffer.where((f) => f.isJank).length;

  /// Frames late only because of Sleuth's own work
  /// ([FrameStats.isSleuthOverhead]).
  int get sleuthOverheadCount =>
      _buffer.where((f) => f.isSleuthOverhead).length;

  void add(FrameStats frame) {
    if (_buffer.length >= capacity) {
      _buffer.removeFirst();
    }
    _buffer.add(frame);
    _cachedFrames = null;
    _percentilesDirty = true;
    _actualFpsDirty = true;
    _cachedActualFps = null;
  }

  /// Computes FPS percentiles from the current buffer contents.
  ///
  /// Converts each frame's [FrameStats.effectiveTotalDuration] to an
  /// instantaneous FPS value, then picks p50/p95/p99 from the sorted list.
  /// All values clamped to `0, 120` to match [averageFps] behavior.
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
    }).toList()..sort();

    double percentile(double p) {
      final index = ((fpsValues.length - 1) * p).floor();
      return double.parse(
        fpsValues[math.min(index, fpsValues.length - 1)].toStringAsFixed(1),
      );
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
    _actualFpsDirty = true;
    _cachedActualFps = null;
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
