/// Startup performance metrics captured by [Sleuth.init].
///
/// Contains time-to-first-frame (TTFF), optional time-to-interactive (TTI),
/// per-phase breakdown from [FrameTiming], and optional VM-enriched sub-phase
/// durations from the first timeline poll.
class StartupMetrics {
  const StartupMetrics({
    required this.dartEntryTimestamp,
    this.ttffMs,
    this.ttiMs,
    this.firstFrameVsyncOverheadMs,
    this.firstFrameBuildMs,
    this.firstFrameRasterMs,
    this.firstFrameTotalMs,
    this.vmFirstBuildScopeMs,
    this.vmFirstFlushLayoutMs,
    this.vmFirstFlushPaintMs,
    this.vmFirstRasterMs,
    this.dartEntryMonotonicUs,
    this.frameworkInitDurationUs,
    this.engineEnterUs,
    this.firstFrameRasterizedUs,
  });

  /// Wall-clock timestamp when [Sleuth.init] was called (Dart entry point).
  final DateTime dartEntryTimestamp;

  /// Time-to-first-frame in milliseconds, measured from [dartEntryTimestamp]
  /// to the first [FrameTiming] raster-end timestamp.
  ///
  /// Null when [Sleuth.init] was not called before [runApp].
  final double? ttffMs;

  /// Time-to-interactive in milliseconds, measured from [dartEntryTimestamp]
  /// to [Sleuth.markInteractive].
  ///
  /// Null when [Sleuth.markInteractive] was not called.
  final double? ttiMs;

  // ── First-frame phase breakdown (from FrameTiming) ───────────────────

  /// Vsync scheduling overhead for the first frame (ms).
  final double? firstFrameVsyncOverheadMs;

  /// Build phase duration for the first frame (ms).
  final double? firstFrameBuildMs;

  /// Raster phase duration for the first frame (ms).
  final double? firstFrameRasterMs;

  /// Total wall-clock duration for the first frame (ms).
  final double? firstFrameTotalMs;

  // ── VM-enriched sub-phases (from first getVMTimeline poll) ───────────

  /// Duration of the first `buildScope` event from VM timeline (ms).
  /// Null if VM was not connected in time for retroactive extraction.
  final double? vmFirstBuildScopeMs;

  /// Duration of the first `flushLayout` event from VM timeline (ms).
  final double? vmFirstFlushLayoutMs;

  /// Duration of the first `flushPaint` event from VM timeline (ms).
  final double? vmFirstFlushPaintMs;

  /// Duration of the first raster event from VM timeline (ms).
  final double? vmFirstRasterMs;

  // ── Engine-level timestamps (direct capture + VM extraction) ─────────

  /// Monotonic microsecond timestamp from `Timeline.now` captured at
  /// [Sleuth.init] entry. Same clock domain as engine timeline events,
  /// enabling accurate delta computation with [engineEnterUs].
  final int? dartEntryMonotonicUs;

  /// Framework initialization duration in microseconds, measured by
  /// wrapping `WidgetsFlutterBinding.ensureInitialized()` in
  /// `Timeline.now` calls. 100% reliable (direct capture, no VM needed).
  final int? frameworkInitDurationUs;

  /// Monotonic microsecond timestamp of the `FlutterEngineMainEnter`
  /// event from the VM timeline ring buffer. Represents C++ engine entry
  /// before any Dart code runs. Null if VM was not connected in time.
  final int? engineEnterUs;

  /// Monotonic microsecond timestamp of the `Rasterized first useful
  /// frame` event from the VM timeline ring buffer. Null if VM was not
  /// connected in time or the event was evicted from the ring buffer.
  final int? firstFrameRasterizedUs;

  // ── Computed engine-level getters ────────────────────────────────────

  /// Framework initialization duration in milliseconds.
  /// Null when [frameworkInitDurationUs] is not available.
  double? get frameworkInitMs => frameworkInitDurationUs != null
      ? frameworkInitDurationUs! / 1000.0
      : null;

  /// Pre-Dart overhead in milliseconds: time from engine C++ entry to
  /// Dart entry point. Requires both [engineEnterUs] and
  /// [dartEntryMonotonicUs] (same monotonic clock domain).
  /// Returns null if the computed delta is negative (clock anomaly).
  double? get preDartOverheadMs {
    if (engineEnterUs == null || dartEntryMonotonicUs == null) return null;
    final delta = (dartEntryMonotonicUs! - engineEnterUs!) / 1000.0;
    return delta >= 0 ? delta : null;
  }

  /// Engine-measured TTFF in milliseconds: time from engine C++ entry to
  /// first frame rasterized. Matches `--trace-startup` output. Requires
  /// both [engineEnterUs] and [firstFrameRasterizedUs].
  double? get engineTtffMs =>
      engineEnterUs != null && firstFrameRasterizedUs != null
          ? (firstFrameRasterizedUs! - engineEnterUs!) / 1000.0
          : null;

  /// The pipeline phase that consumed the largest share of first-frame time.
  ///
  /// Returns `'build'`, `'raster'`, `'vsync'`, or `'balanced'` if no phase
  /// exceeds 50%.
  String get dominantPhase {
    final total = firstFrameTotalMs;
    if (total == null || total <= 0) return 'unknown';

    final build = firstFrameBuildMs ?? 0;
    final raster = firstFrameRasterMs ?? 0;
    final vsync = firstFrameVsyncOverheadMs ?? 0;

    if (build / total > 0.5) return 'build';
    if (raster / total > 0.5) return 'raster';
    if (vsync / total > 0.5) return 'vsync';
    return 'balanced';
  }

  /// The percentage of first-frame time consumed by [dominantPhase].
  double get dominantPhasePercent {
    final total = firstFrameTotalMs;
    if (total == null || total <= 0) return 0;

    final build = firstFrameBuildMs ?? 0;
    final raster = firstFrameRasterMs ?? 0;
    final vsync = firstFrameVsyncOverheadMs ?? 0;

    final max = [build, raster, vsync].reduce((a, b) => a > b ? a : b);
    return (max / total * 100).clamp(0, 100);
  }

  /// Creates a copy with updated fields (typically for VM enrichment).
  StartupMetrics copyWith({
    double? ttiMs,
    double? vmFirstBuildScopeMs,
    double? vmFirstFlushLayoutMs,
    double? vmFirstFlushPaintMs,
    double? vmFirstRasterMs,
    int? dartEntryMonotonicUs,
    int? frameworkInitDurationUs,
    int? engineEnterUs,
    int? firstFrameRasterizedUs,
  }) =>
      StartupMetrics(
        dartEntryTimestamp: dartEntryTimestamp,
        ttffMs: ttffMs,
        ttiMs: ttiMs ?? this.ttiMs,
        firstFrameVsyncOverheadMs: firstFrameVsyncOverheadMs,
        firstFrameBuildMs: firstFrameBuildMs,
        firstFrameRasterMs: firstFrameRasterMs,
        firstFrameTotalMs: firstFrameTotalMs,
        vmFirstBuildScopeMs: vmFirstBuildScopeMs ?? this.vmFirstBuildScopeMs,
        vmFirstFlushLayoutMs: vmFirstFlushLayoutMs ?? this.vmFirstFlushLayoutMs,
        vmFirstFlushPaintMs: vmFirstFlushPaintMs ?? this.vmFirstFlushPaintMs,
        vmFirstRasterMs: vmFirstRasterMs ?? this.vmFirstRasterMs,
        dartEntryMonotonicUs: dartEntryMonotonicUs ?? this.dartEntryMonotonicUs,
        frameworkInitDurationUs:
            frameworkInitDurationUs ?? this.frameworkInitDurationUs,
        engineEnterUs: engineEnterUs ?? this.engineEnterUs,
        firstFrameRasterizedUs:
            firstFrameRasterizedUs ?? this.firstFrameRasterizedUs,
      );

  Map<String, dynamic> toJson() => {
        'dartEntryTimestamp': dartEntryTimestamp.toIso8601String(),
        if (ttffMs != null) 'ttffMs': double.parse(ttffMs!.toStringAsFixed(1)),
        if (ttiMs != null) 'ttiMs': double.parse(ttiMs!.toStringAsFixed(1)),
        if (firstFrameVsyncOverheadMs != null)
          'firstFrameVsyncOverheadMs':
              double.parse(firstFrameVsyncOverheadMs!.toStringAsFixed(2)),
        if (firstFrameBuildMs != null)
          'firstFrameBuildMs':
              double.parse(firstFrameBuildMs!.toStringAsFixed(2)),
        if (firstFrameRasterMs != null)
          'firstFrameRasterMs':
              double.parse(firstFrameRasterMs!.toStringAsFixed(2)),
        if (firstFrameTotalMs != null)
          'firstFrameTotalMs':
              double.parse(firstFrameTotalMs!.toStringAsFixed(2)),
        if (vmFirstBuildScopeMs != null)
          'vmFirstBuildScopeMs':
              double.parse(vmFirstBuildScopeMs!.toStringAsFixed(2)),
        if (vmFirstFlushLayoutMs != null)
          'vmFirstFlushLayoutMs':
              double.parse(vmFirstFlushLayoutMs!.toStringAsFixed(2)),
        if (vmFirstFlushPaintMs != null)
          'vmFirstFlushPaintMs':
              double.parse(vmFirstFlushPaintMs!.toStringAsFixed(2)),
        if (vmFirstRasterMs != null)
          'vmFirstRasterMs': double.parse(vmFirstRasterMs!.toStringAsFixed(2)),
        if (dartEntryMonotonicUs != null)
          'dartEntryMonotonicUs': dartEntryMonotonicUs,
        if (frameworkInitDurationUs != null)
          'frameworkInitDurationUs': frameworkInitDurationUs,
        if (engineEnterUs != null) 'engineEnterUs': engineEnterUs,
        if (firstFrameRasterizedUs != null)
          'firstFrameRasterizedUs': firstFrameRasterizedUs,
        if (frameworkInitMs != null)
          'frameworkInitMs': double.parse(frameworkInitMs!.toStringAsFixed(2)),
        if (preDartOverheadMs != null)
          'preDartOverheadMs':
              double.parse(preDartOverheadMs!.toStringAsFixed(2)),
        if (engineTtffMs != null)
          'engineTtffMs': double.parse(engineTtffMs!.toStringAsFixed(2)),
        'dominantPhase': dominantPhase,
        'dominantPhasePercent':
            double.parse(dominantPhasePercent.toStringAsFixed(1)),
      };

  factory StartupMetrics.fromJson(Map<String, dynamic> json) => StartupMetrics(
        dartEntryTimestamp:
            DateTime.parse(json['dartEntryTimestamp'] as String),
        ttffMs: (json['ttffMs'] as num?)?.toDouble(),
        ttiMs: (json['ttiMs'] as num?)?.toDouble(),
        firstFrameVsyncOverheadMs:
            (json['firstFrameVsyncOverheadMs'] as num?)?.toDouble(),
        firstFrameBuildMs: (json['firstFrameBuildMs'] as num?)?.toDouble(),
        firstFrameRasterMs: (json['firstFrameRasterMs'] as num?)?.toDouble(),
        firstFrameTotalMs: (json['firstFrameTotalMs'] as num?)?.toDouble(),
        vmFirstBuildScopeMs: (json['vmFirstBuildScopeMs'] as num?)?.toDouble(),
        vmFirstFlushLayoutMs:
            (json['vmFirstFlushLayoutMs'] as num?)?.toDouble(),
        vmFirstFlushPaintMs: (json['vmFirstFlushPaintMs'] as num?)?.toDouble(),
        vmFirstRasterMs: (json['vmFirstRasterMs'] as num?)?.toDouble(),
        dartEntryMonotonicUs: (json['dartEntryMonotonicUs'] as num?)?.toInt(),
        frameworkInitDurationUs:
            (json['frameworkInitDurationUs'] as num?)?.toInt(),
        engineEnterUs: (json['engineEnterUs'] as num?)?.toInt(),
        firstFrameRasterizedUs:
            (json['firstFrameRasterizedUs'] as num?)?.toInt(),
      );
}
