import 'cpu_attribution.dart';
import 'performance_issue.dart';

/// Rendering pipeline phase suspected as bottleneck.
enum PipelinePhase {
  build,
  layout,
  paint,
  raster,
  schedulerDelay,
  pipelineStall,
  unknown,
}

/// A per-frame performance verdict combining SchedulerBinding + VM Timeline.
///
/// When VM service is available, [buildScopeTime], [flushLayoutTime], and
/// [flushPaintTime] are populated with exact durations from the VM Timeline.
/// When unavailable, these are null and only [uiThreadTime] / [rasterThreadTime]
/// from SchedulerBinding are available (basic mode).
class FrameVerdict {
  const FrameVerdict({
    required this.frameNumber,
    required this.totalFrameTime,
    required this.uiThreadTime,
    required this.rasterThreadTime,
    this.buildScopeTime,
    this.flushLayoutTime,
    this.flushPaintTime,
    this.totalSpan,
    this.buildToRasterGapTime,
    required this.suspectedPhase,
    required this.reason,
    this.relatedIssues = const [],
    this.isFullMode = false,
    this.isCorrelated = false,
    this.correlationCoverage,
    this.topFunctions,
  });

  final int frameNumber;
  final Duration totalFrameTime;

  /// End-to-end frame latency (vsyncStart → rasterFinish).
  final Duration? totalSpan;

  /// Build-to-raster pipeline handoff gap.
  final Duration? buildToRasterGapTime;

  /// UI thread total — always available from SchedulerBinding.
  final Duration uiThreadTime;

  /// Raster thread total — always available from SchedulerBinding.
  final Duration rasterThreadTime;

  /// Exact build phase duration from VM Timeline (null in basic mode).
  final Duration? buildScopeTime;

  /// Exact layout phase duration from VM Timeline (null in basic mode).
  final Duration? flushLayoutTime;

  /// Exact paint phase duration from VM Timeline (null in basic mode).
  final Duration? flushPaintTime;

  /// Which pipeline phase is the suspected bottleneck.
  final PipelinePhase suspectedPhase;

  /// Human-readable explanation of the verdict.
  final String reason;

  /// Issues detected that relate to this frame.
  final List<PerformanceIssue> relatedIssues;

  /// Whether this verdict was generated with full VM Timeline data.
  final bool isFullMode;

  /// Whether this verdict used per-frame event correlation.
  final bool isCorrelated;

  /// Fraction of batch events that matched this frame (null when not correlated).
  final double? correlationCoverage;

  /// Top CPU-consuming functions during this frame (null when unavailable).
  ///
  /// Populated asynchronously via two-phase verdict emission when VM is
  /// connected and CPU samples are available for the frame's time window.
  final List<CpuAttribution>? topFunctions;

  /// Returns a copy with [topFunctions] attached.
  FrameVerdict withTopFunctions(List<CpuAttribution>? topFunctions) =>
      FrameVerdict(
        frameNumber: frameNumber,
        totalFrameTime: totalFrameTime,
        uiThreadTime: uiThreadTime,
        rasterThreadTime: rasterThreadTime,
        buildScopeTime: buildScopeTime,
        flushLayoutTime: flushLayoutTime,
        flushPaintTime: flushPaintTime,
        totalSpan: totalSpan,
        buildToRasterGapTime: buildToRasterGapTime,
        suspectedPhase: suspectedPhase,
        reason: reason,
        relatedIssues: relatedIssues,
        isFullMode: isFullMode,
        isCorrelated: isCorrelated,
        correlationCoverage: correlationCoverage,
        topFunctions: topFunctions,
      );

  Map<String, dynamic> toJson() => {
        'frameNumber': frameNumber,
        'totalFrameTimeUs': totalFrameTime.inMicroseconds,
        'uiThreadTimeUs': uiThreadTime.inMicroseconds,
        'rasterThreadTimeUs': rasterThreadTime.inMicroseconds,
        if (buildScopeTime != null)
          'buildScopeTimeUs': buildScopeTime!.inMicroseconds,
        if (flushLayoutTime != null)
          'flushLayoutTimeUs': flushLayoutTime!.inMicroseconds,
        if (flushPaintTime != null)
          'flushPaintTimeUs': flushPaintTime!.inMicroseconds,
        if (totalSpan != null) 'totalSpanUs': totalSpan!.inMicroseconds,
        if (buildToRasterGapTime != null)
          'buildToRasterGapTimeUs': buildToRasterGapTime!.inMicroseconds,
        'suspectedPhase': suspectedPhase.name,
        'reason': reason,
        'relatedIssues': relatedIssues.map((i) => i.toJson()).toList(),
        'isFullMode': isFullMode,
        'isCorrelated': isCorrelated,
        if (correlationCoverage != null)
          'correlationCoverage': correlationCoverage,
        if (topFunctions != null && topFunctions!.isNotEmpty)
          'topFunctions': topFunctions!.map((f) => f.toJson()).toList(),
      };

  factory FrameVerdict.fromJson(Map<String, dynamic> json) => FrameVerdict(
        frameNumber: json['frameNumber'] as int,
        totalFrameTime: Duration(microseconds: json['totalFrameTimeUs'] as int),
        uiThreadTime: Duration(microseconds: json['uiThreadTimeUs'] as int),
        rasterThreadTime:
            Duration(microseconds: json['rasterThreadTimeUs'] as int),
        buildScopeTime: json['buildScopeTimeUs'] != null
            ? Duration(microseconds: json['buildScopeTimeUs'] as int)
            : null,
        flushLayoutTime: json['flushLayoutTimeUs'] != null
            ? Duration(microseconds: json['flushLayoutTimeUs'] as int)
            : null,
        flushPaintTime: json['flushPaintTimeUs'] != null
            ? Duration(microseconds: json['flushPaintTimeUs'] as int)
            : null,
        totalSpan: json['totalSpanUs'] != null
            ? Duration(microseconds: json['totalSpanUs'] as int)
            : null,
        buildToRasterGapTime: json['buildToRasterGapTimeUs'] != null
            ? Duration(microseconds: json['buildToRasterGapTimeUs'] as int)
            : null,
        suspectedPhase:
            PipelinePhase.values.byName(json['suspectedPhase'] as String),
        reason: json['reason'] as String,
        relatedIssues: (json['relatedIssues'] as List<dynamic>?)
                ?.map(
                    (e) => PerformanceIssue.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        isFullMode: json['isFullMode'] as bool? ?? false,
        isCorrelated: json['isCorrelated'] as bool? ?? false,
        correlationCoverage: (json['correlationCoverage'] as num?)?.toDouble(),
        topFunctions: (json['topFunctions'] as List<dynamic>?)
            ?.map((e) => CpuAttribution.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  @override
  String toString() {
    final mode = isCorrelated ? 'CORRELATED' : (isFullMode ? 'FULL' : 'BASIC');
    return 'FrameVerdict(#$frameNumber, ${totalFrameTime.inMilliseconds}ms, '
        '$suspectedPhase, $mode)';
  }
}
