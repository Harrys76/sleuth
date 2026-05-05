import 'frame_event_correlator.dart';
import '../models/frame_stats.dart';
import '../models/frame_verdict.dart';
import '../models/performance_issue.dart';
import '../vm/timeline_parser.dart';

/// Analyzes rendering pipeline data to produce per-frame verdicts.
///
/// Uses exact VM Timeline buildScope/flushLayout/flushPaint durations
/// to pinpoint the bottleneck phase when VM data is available, and falls back
/// to SchedulerBinding UI/raster timings in FRAME mode.
class RenderPipelineAnalyzer {
  RenderPipelineAnalyzer();

  FrameVerdict? _lastVerdict;
  FrameVerdict? get lastVerdict => _lastVerdict;

  /// Analyze a frame with SchedulerBinding UI/raster timings only.
  FrameVerdict analyzeBasicMode({
    required FrameStats frameStats,
    List<PerformanceIssue> relatedIssues = const [],
  }) {
    final budgetUs = frameStats.frameBudgetMs * 1000;
    final gapUs = frameStats.buildToRasterGap.inMicroseconds;
    final vsyncUs = frameStats.vsyncOverhead.inMicroseconds;
    final uiUs = frameStats.uiDuration.inMicroseconds;
    final rasterUs = frameStats.rasterDuration.inMicroseconds;

    PipelinePhase suspected;
    if (gapUs > budgetUs ~/ 4 && uiUs < budgetUs && rasterUs < budgetUs) {
      suspected = PipelinePhase.pipelineStall;
    } else if (vsyncUs > budgetUs ~/ 4 &&
        uiUs < budgetUs &&
        rasterUs < budgetUs) {
      suspected = PipelinePhase.schedulerDelay;
    } else {
      suspected = uiUs > rasterUs ? PipelinePhase.build : PipelinePhase.raster;
    }

    _lastVerdict = FrameVerdict(
      frameNumber: frameStats.frameNumber,
      totalFrameTime: frameStats.totalDuration,
      totalSpan: frameStats.totalSpan,
      buildToRasterGapTime:
          frameStats.totalSpan != null ? frameStats.buildToRasterGap : null,
      uiThreadTime: frameStats.uiDuration,
      rasterThreadTime: frameStats.rasterDuration,
      suspectedPhase: suspected,
      reason: _buildBasicReason(frameStats),
      relatedIssues: relatedIssues,
      isFullMode: false,
    );

    return _lastVerdict!;
  }

  /// Analyze a frame with full VM Timeline data.
  FrameVerdict analyzeFullMode({
    required FrameStats frameStats,
    required ParsedTimelineData timelineData,
    List<PerformanceIssue> relatedIssues = const [],
  }) {
    final buildUs = timelineData.totalBuildScopeUs;
    final layoutUs = timelineData.totalFlushLayoutUs;
    final paintUs = timelineData.totalFlushPaintUs;
    // Raster aggregate includes idle vsync compositor scopes (60/sec)
    // that UI phase aggregates do not, so raster only qualifies as a
    // phase-ranking candidate when one frame's raster crossed half the
    // 60Hz frame budget (8000us). Below that, the aggregate carries
    // no per-frame pressure signal.
    final rasterAggregateUs = timelineData.rasterDurations.isNotEmpty
        ? timelineData.rasterDurations.fold<int>(0, (s, d) => s + d)
        : frameStats.rasterDuration.inMicroseconds;
    final maxRasterFrameUs = timelineData.rasterDurations.isNotEmpty
        ? timelineData.rasterDurations.reduce((a, b) => a > b ? a : b)
        : frameStats.rasterDuration.inMicroseconds;
    final rasterUs = maxRasterFrameUs > 8000 ? rasterAggregateUs : 0;

    // Determine which phase is the widest
    final phases = {
      PipelinePhase.build: buildUs,
      PipelinePhase.layout: layoutUs,
      PipelinePhase.paint: paintUs,
      PipelinePhase.raster: rasterUs,
    };

    PipelinePhase suspected = PipelinePhase.unknown;
    int maxUs = 0;

    for (final entry in phases.entries) {
      if (entry.value > maxUs) {
        maxUs = entry.value;
        suspected = entry.key;
      }
    }

    // If no VM-derived phase dominates but totalSpan exceeds budget,
    // check for pipeline stall or scheduler delay.
    final budgetUs = frameStats.frameBudgetMs * 1000;
    if (suspected == PipelinePhase.unknown || maxUs < budgetUs) {
      final gapUs = frameStats.buildToRasterGap.inMicroseconds;
      final vsyncUs = frameStats.vsyncOverhead.inMicroseconds;
      if (gapUs > budgetUs ~/ 4) {
        suspected = PipelinePhase.pipelineStall;
      } else if (vsyncUs > budgetUs ~/ 4) {
        suspected = PipelinePhase.schedulerDelay;
      }
    }

    // Build reason string
    final reason = _buildFullReason(
      suspected: suspected,
      buildUs: buildUs,
      layoutUs: layoutUs,
      paintUs: paintUs,
      rasterUs: rasterUs,
      frameStats: frameStats,
      relatedIssues: relatedIssues,
    );

    _lastVerdict = FrameVerdict(
      frameNumber: frameStats.frameNumber,
      totalFrameTime: frameStats.totalDuration,
      totalSpan: frameStats.totalSpan,
      buildToRasterGapTime:
          frameStats.totalSpan != null ? frameStats.buildToRasterGap : null,
      uiThreadTime: frameStats.uiDuration,
      rasterThreadTime: frameStats.rasterDuration,
      buildScopeTime: Duration(microseconds: buildUs),
      flushLayoutTime: Duration(microseconds: layoutUs),
      flushPaintTime: Duration(microseconds: paintUs),
      suspectedPhase: suspected,
      reason: reason,
      relatedIssues: relatedIssues,
      isFullMode: true,
    );

    return _lastVerdict!;
  }

  /// Analyze a frame with per-frame correlated VM Timeline data.
  ///
  /// Uses only the events that belong to this specific frame (via timestamp
  /// correlation), producing accurate per-frame verdicts instead of
  /// batch-attributed ones.
  FrameVerdict analyzeCorrelatedMode({
    required FrameStats frameStats,
    required CorrelatedFrameData correlation,
    List<PerformanceIssue> relatedIssues = const [],
  }) {
    final buildUs = correlation.buildScopeUs;
    final layoutUs = correlation.flushLayoutUs;
    final paintUs = correlation.flushPaintUs;
    final rasterUs = correlation.rasterUs > 0
        ? correlation.rasterUs
        : frameStats.rasterDuration.inMicroseconds;

    // Determine which phase is the widest
    final phases = {
      PipelinePhase.build: buildUs,
      PipelinePhase.layout: layoutUs,
      PipelinePhase.paint: paintUs,
      PipelinePhase.raster: rasterUs,
    };

    PipelinePhase suspected = PipelinePhase.unknown;
    int maxUs = 0;

    for (final entry in phases.entries) {
      if (entry.value > maxUs) {
        maxUs = entry.value;
        suspected = entry.key;
      }
    }

    // If no correlated phase dominates, check for pipeline stall or scheduler delay.
    final budgetUs = frameStats.frameBudgetMs * 1000;
    if (suspected == PipelinePhase.unknown || maxUs < budgetUs) {
      final gapUs = frameStats.buildToRasterGap.inMicroseconds;
      final vsyncUs = frameStats.vsyncOverhead.inMicroseconds;
      if (gapUs > budgetUs ~/ 4) {
        suspected = PipelinePhase.pipelineStall;
      } else if (vsyncUs > budgetUs ~/ 4) {
        suspected = PipelinePhase.schedulerDelay;
      }
    }

    final reason = _buildCorrelatedReason(
      suspected: suspected,
      buildUs: buildUs,
      layoutUs: layoutUs,
      paintUs: paintUs,
      rasterUs: rasterUs,
      frameStats: frameStats,
      correlation: correlation,
      relatedIssues: relatedIssues,
    );

    _lastVerdict = FrameVerdict(
      frameNumber: frameStats.frameNumber,
      totalFrameTime: frameStats.totalDuration,
      totalSpan: frameStats.totalSpan,
      buildToRasterGapTime:
          frameStats.totalSpan != null ? frameStats.buildToRasterGap : null,
      uiThreadTime: frameStats.uiDuration,
      rasterThreadTime: frameStats.rasterDuration,
      buildScopeTime: Duration(microseconds: buildUs),
      flushLayoutTime: Duration(microseconds: layoutUs),
      flushPaintTime: Duration(microseconds: paintUs),
      suspectedPhase: suspected,
      reason: reason,
      relatedIssues: relatedIssues,
      isFullMode: true,
      isCorrelated: true,
      correlationCoverage: correlation.coverageRatio,
    );

    return _lastVerdict!;
  }

  String _buildCorrelatedReason({
    required PipelinePhase suspected,
    required int buildUs,
    required int layoutUs,
    required int paintUs,
    required int rasterUs,
    required FrameStats frameStats,
    required CorrelatedFrameData correlation,
    required List<PerformanceIssue> relatedIssues,
  }) {
    final buf = StringBuffer();

    const phaseNames = {
      PipelinePhase.build: 'BUILD',
      PipelinePhase.layout: 'LAYOUT',
      PipelinePhase.paint: 'PAINT',
      PipelinePhase.raster: 'RASTER',
      PipelinePhase.pipelineStall: 'PIPELINE STALL',
      PipelinePhase.schedulerDelay: 'SCHEDULER DELAY',
    };

    // Confidence-dependent wording
    if (correlation.coverageRatio >= 0.5) {
      buf.writeln(
        'Correlated to frame #${frameStats.frameNumber}: '
        '${phaseNames[suspected] ?? "UNKNOWN"}',
      );
    } else {
      buf.writeln(
        'Partial correlation (${correlation.matchedEventCount} events matched): '
        '${phaseNames[suspected] ?? "UNKNOWN"}',
      );
    }

    buf.writeln('  build:  ${(buildUs / 1000).toStringAsFixed(1)}ms');
    buf.writeln('  layout: ${(layoutUs / 1000).toStringAsFixed(1)}ms');
    buf.writeln('  paint:  ${(paintUs / 1000).toStringAsFixed(1)}ms');
    buf.writeln('  raster: ${(rasterUs / 1000).toStringAsFixed(1)}ms');

    if (frameStats.totalSpan != null) {
      buf.writeln(
        '  total span: '
        '${(frameStats.totalSpan!.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    if (frameStats.vsyncOverhead.inMicroseconds > 500) {
      buf.writeln(
        '  vsync wait: '
        '${(frameStats.vsyncOverhead.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    if (frameStats.buildToRasterGap.inMicroseconds > 500) {
      buf.writeln(
        '  pipeline gap: '
        '${(frameStats.buildToRasterGap.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    if (relatedIssues.isNotEmpty) {
      buf.writeln('Related: ${relatedIssues.first.title}');
    }

    return buf.toString().trimRight();
  }

  String _buildFullReason({
    required PipelinePhase suspected,
    required int buildUs,
    required int layoutUs,
    required int paintUs,
    required int rasterUs,
    required FrameStats frameStats,
    required List<PerformanceIssue> relatedIssues,
  }) {
    final buf = StringBuffer();

    const phaseNames = {
      PipelinePhase.build: 'BUILD',
      PipelinePhase.layout: 'LAYOUT',
      PipelinePhase.paint: 'PAINT',
      PipelinePhase.raster: 'RASTER',
      PipelinePhase.pipelineStall: 'PIPELINE STALL',
      PipelinePhase.schedulerDelay: 'SCHEDULER DELAY',
    };

    buf.writeln('Suspected bottleneck: ${phaseNames[suspected] ?? "UNKNOWN"}');
    buf.writeln('  build:  ${(buildUs / 1000).toStringAsFixed(1)}ms');
    buf.writeln('  layout: ${(layoutUs / 1000).toStringAsFixed(1)}ms');
    buf.writeln('  paint:  ${(paintUs / 1000).toStringAsFixed(1)}ms');
    buf.writeln('  raster: ${(rasterUs / 1000).toStringAsFixed(1)}ms');

    if (frameStats.totalSpan != null) {
      buf.writeln(
        '  total span: '
        '${(frameStats.totalSpan!.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    if (frameStats.vsyncOverhead.inMicroseconds > 500) {
      buf.writeln(
        '  vsync wait: '
        '${(frameStats.vsyncOverhead.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    if (frameStats.buildToRasterGap.inMicroseconds > 500) {
      buf.writeln(
        '  pipeline gap: '
        '${(frameStats.buildToRasterGap.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    if (relatedIssues.isNotEmpty) {
      buf.writeln('Related: ${relatedIssues.first.title}');
    }

    return buf.toString().trimRight();
  }

  String _buildBasicReason(FrameStats frameStats) {
    final buf = StringBuffer()
      ..write('UI: ${frameStats.uiDuration.inMilliseconds}ms, ')
      ..write('Raster: ${frameStats.rasterDuration.inMilliseconds}ms');

    if (frameStats.totalSpan != null) {
      buf.write(
        ', Total: '
        '${(frameStats.totalSpan!.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    if (frameStats.vsyncOverhead.inMicroseconds > 500) {
      buf.write(
        ', Vsync wait: '
        '${(frameStats.vsyncOverhead.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    if (frameStats.buildToRasterGap.inMicroseconds > 500) {
      buf.write(
        ', Pipeline gap: '
        '${(frameStats.buildToRasterGap.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      );
    }

    return buf.toString();
  }
}
