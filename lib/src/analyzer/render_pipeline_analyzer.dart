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
    final budgetUs = frameStats.frameBudgetUs;
    final uiUs = frameStats.uiDuration.inMicroseconds;
    final rasterUs = frameStats.rasterDuration.inMicroseconds;

    // A jank frame misses its deadline on the UI thread (start delay plus
    // build) or the raster thread; the hand-off wait never counts. When
    // neither thread ran over by itself, the start delay did it.
    PipelinePhase suspected;
    if (uiUs <= budgetUs && rasterUs <= budgetUs) {
      suspected = PipelinePhase.schedulerDelay;
    } else {
      suspected = uiUs > rasterUs ? PipelinePhase.build : PipelinePhase.raster;
    }

    _lastVerdict = FrameVerdict(
      frameNumber: frameStats.frameNumber,
      totalFrameTime: frameStats.totalDuration,
      totalSpan: frameStats.totalSpan,
      buildToRasterGapTime: frameStats.totalSpan != null
          ? frameStats.buildToRasterGap
          : null,
      uiThreadTime: frameStats.uiDuration,
      rasterThreadTime: frameStats.rasterDuration,
      suspectedPhase: suspected,
      reason: _buildBasicReason(frameStats),
      relatedIssues: relatedIssues,
      isFullMode: false,
    );

    return _lastVerdict!;
  }

  /// The phase that made [frameStats] miss its deadline, from the frame's
  /// own threads. When build and raster each fit, the start delay pushed
  /// the frame past it ([PipelinePhase.schedulerDelay]); the hand-off wait
  /// between them never counts. A raster thread that ran longer than the
  /// UI thread is the raster phase. Otherwise the UI thread ran over, and
  /// the largest of its measured phases (build, layout, paint) names it,
  /// or build when none was measured.
  ///
  /// [phases] only ranks the UI thread's phases. In the full tier they are
  /// totals over the whole poll batch, so they never decide which thread
  /// ran over.
  static PipelinePhase _framePhase(
    FrameStats frameStats,
    Map<PipelinePhase, int> phases,
  ) {
    final budgetUs = frameStats.frameBudgetUs;
    final uiUs = frameStats.uiDuration.inMicroseconds;
    final rasterUs = frameStats.rasterDuration.inMicroseconds;
    if (uiUs <= budgetUs && rasterUs <= budgetUs) {
      return PipelinePhase.schedulerDelay;
    }
    if (rasterUs > uiUs) return PipelinePhase.raster;
    var best = PipelinePhase.build;
    var bestUs = 0;
    for (final phase in const [
      PipelinePhase.build,
      PipelinePhase.layout,
      PipelinePhase.paint,
    ]) {
      final us = phases[phase] ?? 0;
      if (us > bestUs) {
        bestUs = us;
        best = phase;
      }
    }
    return best;
  }

  /// The start delay with Sleuth's own share, as the reasons print it.
  static String _startDelayText(FrameStats frameStats) {
    final totalMs = frameStats.vsyncOverhead.inMicroseconds / 1000;
    final ownMs = frameStats.ownStartDelayUs / 1000;
    return '${totalMs.toStringAsFixed(1)}ms'
        '${ownMs > 0 ? ' (${ownMs.toStringAsFixed(1)}ms of it Sleuth\'s own work)' : ''}';
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
    // frame budget (8000us at a 16 ms budget). Below that, the aggregate
    // carries no per-frame pressure signal.
    final rasterAggregateUs = timelineData.rasterDurations.isNotEmpty
        ? timelineData.rasterDurations.fold<int>(0, (s, d) => s + d)
        : frameStats.rasterDuration.inMicroseconds;
    final maxRasterFrameUs = timelineData.rasterDurations.isNotEmpty
        ? timelineData.rasterDurations.reduce((a, b) => a > b ? a : b)
        : frameStats.rasterDuration.inMicroseconds;
    final rasterUs = maxRasterFrameUs > frameStats.frameBudgetUs ~/ 2
        ? rasterAggregateUs
        : 0;

    // The frame's own threads decide; the phases only rank the UI side.
    final suspected = _framePhase(frameStats, {
      PipelinePhase.build: buildUs,
      PipelinePhase.layout: layoutUs,
      PipelinePhase.paint: paintUs,
    });

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
      buildToRasterGapTime: frameStats.totalSpan != null
          ? frameStats.buildToRasterGap
          : null,
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

    // The frame's own threads decide; the phases only rank the UI side.
    final suspected = _framePhase(frameStats, {
      PipelinePhase.build: buildUs,
      PipelinePhase.layout: layoutUs,
      PipelinePhase.paint: paintUs,
    });

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
      buildToRasterGapTime: frameStats.totalSpan != null
          ? frameStats.buildToRasterGap
          : null,
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
      correlationCoverage: correlation.batchCoverageRatio,
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
    if (correlation.batchCoverageRatio >= 0.5) {
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
      buf.writeln('  start delay: ${_startDelayText(frameStats)}');
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
      buf.writeln('  start delay: ${_startDelayText(frameStats)}');
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
      buf.write(', Start delay: ${_startDelayText(frameStats)}');
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
