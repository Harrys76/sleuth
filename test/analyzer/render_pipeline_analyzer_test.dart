import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/analyzer/frame_event_correlator.dart';
import 'package:sleuth/src/analyzer/render_pipeline_analyzer.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/frame_verdict.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

void main() {
  group('RenderPipelineAnalyzer basic mode', () {
    late RenderPipelineAnalyzer analyzer;

    setUp(() {
      analyzer = RenderPipelineAnalyzer();
    });

    FrameStats makeFrame({
      required int uiMs,
      required int rasterMs,
      int frameNumber = 1,
      int vsyncOverheadUs = 0,
      Duration? totalSpan,
      int buildToRasterGapUs = 0,
    }) {
      return FrameStats(
        frameNumber: frameNumber,
        uiDuration: Duration(milliseconds: uiMs),
        rasterDuration: Duration(milliseconds: rasterMs),
        timestamp: DateTime(2026, 1, 1),
        vsyncOverhead: Duration(microseconds: vsyncOverheadUs),
        frameBudgetMs: 16,
        totalSpan: totalSpan,
        buildToRasterGap: Duration(microseconds: buildToRasterGapUs),
      );
    }

    test('suspects build when UI is slower than raster', () {
      final verdict = analyzer.analyzeBasicMode(
        frameStats: makeFrame(uiMs: 30, rasterMs: 10),
      );

      expect(verdict.isFullMode, isFalse);
      expect(verdict.suspectedPhase, PipelinePhase.build);
      expect(verdict.reason, 'UI: 30ms, Raster: 10ms');
    });

    test('suspects raster when raster is at least as slow as UI', () {
      final verdict = analyzer.analyzeBasicMode(
        frameStats: makeFrame(uiMs: 20, rasterMs: 20),
      );

      expect(verdict.suspectedPhase, PipelinePhase.raster);
    });

    test('includes the start delay when it is material', () {
      final verdict = analyzer.analyzeBasicMode(
        frameStats: makeFrame(uiMs: 30, rasterMs: 10, vsyncOverheadUs: 1500),
      );

      expect(verdict.reason, contains('Start delay: 1.5ms'));
    });
  });

  group('RenderPipelineAnalyzer pipeline stall detection', () {
    late RenderPipelineAnalyzer analyzer;

    setUp(() {
      analyzer = RenderPipelineAnalyzer();
    });

    FrameStats makeFrame({
      required int uiMs,
      required int rasterMs,
      int frameNumber = 1,
      int vsyncOverheadUs = 0,
      Duration? totalSpan,
      int buildToRasterGapUs = 0,
    }) {
      return FrameStats(
        frameNumber: frameNumber,
        uiDuration: Duration(milliseconds: uiMs),
        rasterDuration: Duration(milliseconds: rasterMs),
        timestamp: DateTime(2026, 1, 1),
        vsyncOverhead: Duration(microseconds: vsyncOverheadUs),
        frameBudgetMs: 16,
        totalSpan: totalSpan,
        buildToRasterGap: Duration(microseconds: buildToRasterGapUs),
      );
    }

    test('a hand-off gap is never the cause: with both threads within '
        'the budget the start delay is', () {
      final verdict = analyzer.analyzeBasicMode(
        frameStats: makeFrame(uiMs: 10, rasterMs: 8, buildToRasterGapUs: 5000),
      );

      expect(verdict.suspectedPhase, PipelinePhase.schedulerDelay);
    });

    test('detects scheduler delay when vsync exceeds 25% of budget', () {
      final verdict = analyzer.analyzeBasicMode(
        frameStats: makeFrame(
          uiMs: 10,
          rasterMs: 8,
          vsyncOverheadUs: 5000,
          buildToRasterGapUs: 0,
        ),
      );

      expect(verdict.suspectedPhase, PipelinePhase.schedulerDelay);
    });

    test('a thread over the budget wins over the start delay and the gap', () {
      final verdict = analyzer.analyzeBasicMode(
        frameStats: makeFrame(
          uiMs: 20,
          rasterMs: 8,
          buildToRasterGapUs: 5000,
          vsyncOverheadUs: 5000,
        ),
      );

      expect(verdict.suspectedPhase, PipelinePhase.build);
    });

    test('reason includes total span and gap text', () {
      final verdict = analyzer.analyzeBasicMode(
        frameStats: makeFrame(
          uiMs: 10,
          rasterMs: 8,
          totalSpan: const Duration(milliseconds: 25),
          buildToRasterGapUs: 5000,
        ),
      );

      expect(verdict.reason, contains('Total: 25.0ms'));
      expect(verdict.reason, contains('Pipeline gap: 5.0ms'));
    });
  });

  group('RenderPipelineAnalyzer full mode stall fallback', () {
    late RenderPipelineAnalyzer analyzer;

    setUp(() {
      analyzer = RenderPipelineAnalyzer();
    });

    FrameStats makeFrame({
      required int uiMs,
      required int rasterMs,
      int frameNumber = 1,
      int vsyncOverheadUs = 0,
      Duration? totalSpan,
      int buildToRasterGapUs = 0,
    }) {
      return FrameStats(
        frameNumber: frameNumber,
        uiDuration: Duration(milliseconds: uiMs),
        rasterDuration: Duration(milliseconds: rasterMs),
        timestamp: DateTime(2026, 1, 1),
        vsyncOverhead: Duration(microseconds: vsyncOverheadUs),
        frameBudgetMs: 16,
        totalSpan: totalSpan,
        buildToRasterGap: Duration(microseconds: buildToRasterGapUs),
      );
    }

    test('a late start is the cause when no phase dominates and both '
        'threads fit; the hand-off gap is not', () {
      // 8 ms start delay + 10 ms build misses the 16 ms deadline.
      final frame = makeFrame(
        uiMs: 10,
        rasterMs: 8,
        vsyncOverheadUs: 8000,
        buildToRasterGapUs: 5000,
        totalSpan: const Duration(milliseconds: 31),
      );

      final verdict = analyzer.analyzeFullMode(
        frameStats: frame,
        timelineData: ParsedTimelineData(
          buildScopeDurations: [1000],
          flushLayoutDurations: [1000],
          flushPaintDurations: [1000],
          rasterDurations: [1000],
        ),
      );

      expect(verdict.suspectedPhase, PipelinePhase.schedulerDelay);
      expect(verdict.reason, contains('SCHEDULER DELAY'));
      expect(verdict.reason, isNot(contains('PIPELINE STALL')));
      expect(verdict.reason, contains('total span'));
    });

    test('with every VM phase under budget, the thread that ran over '
        'decides: its largest phase', () {
      final frame = makeFrame(
        uiMs: 18,
        rasterMs: 10,
        buildToRasterGapUs: 8000,
        totalSpan: const Duration(milliseconds: 36),
      );

      final verdict = analyzer.analyzeFullMode(
        frameStats: frame,
        timelineData: ParsedTimelineData(
          buildScopeDurations: [9000],
          flushLayoutDurations: [4000],
          flushPaintDurations: [3000],
          rasterDurations: [10000],
        ),
      );

      // Raster's 10 ms is the largest phase, but the UI thread ran over.
      expect(verdict.suspectedPhase, PipelinePhase.build);
    });

    test('no measured phase and a thread over budget: the longer thread', () {
      final verdict = analyzer.analyzeFullMode(
        frameStats: makeFrame(uiMs: 20, rasterMs: 6, buildToRasterGapUs: 6000),
        timelineData: ParsedTimelineData(),
      );

      expect(verdict.suspectedPhase, PipelinePhase.build);
    });
  });

  group('RenderPipelineAnalyzer buildToRasterGapTime nullability', () {
    late RenderPipelineAnalyzer analyzer;

    setUp(() {
      analyzer = RenderPipelineAnalyzer();
    });

    test('basic mode: buildToRasterGapTime is null when totalSpan is null', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 20),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime(2026, 1, 1),
        vsyncOverhead: Duration.zero,
        frameBudgetMs: 16,
        buildToRasterGap: const Duration(milliseconds: 5),
      );

      final verdict = analyzer.analyzeBasicMode(frameStats: frame);
      expect(verdict.buildToRasterGapTime, isNull);
    });

    test('basic mode: buildToRasterGapTime set when totalSpan is present', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 20),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime(2026, 1, 1),
        vsyncOverhead: Duration.zero,
        frameBudgetMs: 16,
        totalSpan: const Duration(milliseconds: 30),
        buildToRasterGap: const Duration(milliseconds: 5),
      );

      final verdict = analyzer.analyzeBasicMode(frameStats: frame);
      expect(verdict.buildToRasterGapTime, const Duration(milliseconds: 5));
    });

    test('full mode: buildToRasterGapTime is null when totalSpan is null', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 20),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime(2026, 1, 1),
        vsyncOverhead: Duration.zero,
        frameBudgetMs: 16,
        buildToRasterGap: const Duration(milliseconds: 5),
      );

      final timelineData = ParsedTimelineData(
        buildScopeDurations: [10000],
        flushLayoutDurations: [5000],
        flushPaintDurations: [3000],
        rasterDurations: [8000],
      );

      final verdict = analyzer.analyzeFullMode(
        frameStats: frame,
        timelineData: timelineData,
      );
      expect(verdict.buildToRasterGapTime, isNull);
    });
  });

  group('RenderPipelineAnalyzer correlated mode', () {
    late RenderPipelineAnalyzer analyzer;

    setUp(() {
      analyzer = RenderPipelineAnalyzer();
    });

    FrameStats makeFrame({
      required int uiMs,
      required int rasterMs,
      int frameNumber = 1,
      int vsyncOverheadUs = 0,
      Duration? totalSpan,
      int buildToRasterGapUs = 0,
    }) {
      return FrameStats(
        frameNumber: frameNumber,
        uiDuration: Duration(milliseconds: uiMs),
        rasterDuration: Duration(milliseconds: rasterMs),
        timestamp: DateTime(2026, 1, 1),
        vsyncOverhead: Duration(microseconds: vsyncOverheadUs),
        frameBudgetMs: 16,
        totalSpan: totalSpan,
        buildToRasterGap: Duration(microseconds: buildToRasterGapUs),
      );
    }

    test('build-dominant correlated verdict', () {
      final verdict = analyzer.analyzeCorrelatedMode(
        frameStats: makeFrame(uiMs: 30, rasterMs: 10),
        correlation: const CorrelatedFrameData(
          buildScopeUs: 20000,
          flushLayoutUs: 3000,
          flushPaintUs: 2000,
          rasterUs: 5000,
          matchedEventCount: 5,
          batchMatchedEventCount: 5,
          totalBatchEventCount: 5,
        ),
      );

      expect(verdict.suspectedPhase, PipelinePhase.build);
      expect(verdict.isCorrelated, isTrue);
      expect(verdict.isFullMode, isTrue);
      expect(verdict.buildScopeTime!.inMicroseconds, 20000);
      expect(verdict.flushLayoutTime!.inMicroseconds, 3000);
      expect(verdict.flushPaintTime!.inMicroseconds, 2000);
    });

    test('raster-dominant correlated verdict', () {
      final verdict = analyzer.analyzeCorrelatedMode(
        frameStats: makeFrame(uiMs: 10, rasterMs: 30),
        correlation: const CorrelatedFrameData(
          buildScopeUs: 3000,
          flushLayoutUs: 2000,
          flushPaintUs: 1000,
          rasterUs: 25000,
          matchedEventCount: 5,
          batchMatchedEventCount: 5,
          totalBatchEventCount: 5,
        ),
      );

      expect(verdict.suspectedPhase, PipelinePhase.raster);
    });

    test('late start fallback when no phase dominates', () {
      final verdict = analyzer.analyzeCorrelatedMode(
        frameStats: makeFrame(
          uiMs: 10,
          rasterMs: 8,
          vsyncOverheadUs: 8000,
          buildToRasterGapUs: 5000,
          totalSpan: const Duration(milliseconds: 31),
        ),
        correlation: const CorrelatedFrameData(
          buildScopeUs: 3000,
          flushLayoutUs: 2000,
          flushPaintUs: 1000,
          rasterUs: 4000,
          matchedEventCount: 4,
          batchMatchedEventCount: 4,
          totalBatchEventCount: 4,
        ),
      );

      expect(verdict.suspectedPhase, PipelinePhase.schedulerDelay);
    });

    test('correlationCoverage metadata on verdict', () {
      final verdict = analyzer.analyzeCorrelatedMode(
        frameStats: makeFrame(uiMs: 30, rasterMs: 10),
        correlation: const CorrelatedFrameData(
          buildScopeUs: 20000,
          matchedEventCount: 3,
          batchMatchedEventCount: 3,
          totalBatchEventCount: 10,
        ),
      );

      expect(verdict.correlationCoverage, closeTo(0.3, 0.01));
    });

    test('isCorrelated flag set correctly', () {
      final verdict = analyzer.analyzeCorrelatedMode(
        frameStats: makeFrame(uiMs: 30, rasterMs: 10),
        correlation: const CorrelatedFrameData(
          buildScopeUs: 20000,
          matchedEventCount: 5,
          batchMatchedEventCount: 5,
          totalBatchEventCount: 5,
        ),
      );

      expect(verdict.isCorrelated, isTrue);
    });

    test('high coverage uses "Correlated to frame" wording', () {
      final verdict = analyzer.analyzeCorrelatedMode(
        frameStats: makeFrame(uiMs: 30, rasterMs: 10, frameNumber: 42),
        correlation: const CorrelatedFrameData(
          buildScopeUs: 20000,
          matchedEventCount: 5,
          batchMatchedEventCount: 5,
          totalBatchEventCount: 5,
        ),
      );

      expect(verdict.reason, contains('Correlated to frame #42'));
    });

    test('low coverage uses "Partial correlation" wording', () {
      final verdict = analyzer.analyzeCorrelatedMode(
        frameStats: makeFrame(uiMs: 30, rasterMs: 10),
        correlation: const CorrelatedFrameData(
          buildScopeUs: 20000,
          matchedEventCount: 3,
          batchMatchedEventCount: 3,
          totalBatchEventCount: 10,
        ),
      );

      expect(verdict.reason, contains('Partial correlation'));
      expect(verdict.reason, contains('3 events matched'));
    });
  });

  group('RenderPipelineAnalyzer full tier: batch totals never pick the '
      'thread', () {
    // A poll batch covers about 500 ms of frames, so its phase totals add up
    // many frames; only the judged frame's own threads say which one ran
    // over.
    FrameStats frame({
      required int startDelayMs,
      required int buildMs,
      required int rasterMs,
    }) => FrameStats(
      frameNumber: 1,
      uiDuration: Duration(milliseconds: buildMs),
      rasterDuration: Duration(milliseconds: rasterMs),
      vsyncOverhead: Duration(milliseconds: startDelayMs),
      timestamp: DateTime(2026, 1, 1),
      frameBudgetUs: 16667,
    );

    test('a late start in a batch of twenty 2 ms builds is a scheduler '
        'delay', () {
      final verdict = RenderPipelineAnalyzer().analyzeFullMode(
        frameStats: frame(startDelayMs: 12, buildMs: 8, rasterMs: 4),
        timelineData: ParsedTimelineData(
          buildScopeDurations: List.filled(20, 2000),
        ),
      );
      expect(verdict.suspectedPhase, PipelinePhase.schedulerDelay);
    });

    test('a UI-bound frame in a batch heavy with raster events is build', () {
      final verdict = RenderPipelineAnalyzer().analyzeFullMode(
        frameStats: frame(startDelayMs: 0, buildMs: 25, rasterMs: 3),
        timelineData: ParsedTimelineData(
          buildScopeDurations: List.filled(30, 1000),
          rasterDurations: List.filled(30, 9000),
        ),
      );
      expect(verdict.suspectedPhase, PipelinePhase.build);
    });

    test('a raster-bound frame in a batch without raster events is '
        'raster', () {
      final verdict = RenderPipelineAnalyzer().analyzeFullMode(
        frameStats: frame(startDelayMs: 0, buildMs: 5, rasterMs: 25),
        timelineData: ParsedTimelineData(
          buildScopeDurations: List.filled(30, 1500),
        ),
      );
      expect(verdict.suspectedPhase, PipelinePhase.raster);
    });

    test('a UI-bound frame is named by its largest UI phase', () {
      final verdict = RenderPipelineAnalyzer().analyzeFullMode(
        frameStats: frame(startDelayMs: 0, buildMs: 25, rasterMs: 3),
        timelineData: ParsedTimelineData(
          buildScopeDurations: List.filled(10, 1000),
          flushLayoutDurations: List.filled(10, 2500),
          flushPaintDurations: List.filled(10, 500),
        ),
      );
      expect(verdict.suspectedPhase, PipelinePhase.layout);
    });

    test('the reason splits the start delay into the app\'s and '
        'Sleuth\'s', () {
      final verdict = RenderPipelineAnalyzer().analyzeFullMode(
        frameStats: frame(
          startDelayMs: 14,
          buildMs: 8,
          rasterMs: 4,
        ).copyWith(ownStartDelayUs: 6000),
        timelineData: ParsedTimelineData(buildScopeDurations: [8000]),
      );
      expect(verdict.reason, contains('start delay: 14.0ms'));
      expect(verdict.reason, contains("6.0ms of it Sleuth's own work"));
    });
  });
}
