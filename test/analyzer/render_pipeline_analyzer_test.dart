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

    test('includes vsync wait when overhead is material', () {
      final verdict = analyzer.analyzeBasicMode(
        frameStats: makeFrame(
          uiMs: 30,
          rasterMs: 10,
          vsyncOverheadUs: 1500,
        ),
      );

      expect(verdict.reason, contains('Vsync wait: 1.5ms'));
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

    test('detects pipeline stall when gap exceeds 25% of budget', () {
      final verdict = analyzer.analyzeBasicMode(
        frameStats: makeFrame(
          uiMs: 10,
          rasterMs: 8,
          buildToRasterGapUs: 5000,
        ),
      );

      expect(verdict.suspectedPhase, PipelinePhase.pipelineStall);
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

    test('pipeline stall takes priority over scheduler delay', () {
      final verdict = analyzer.analyzeBasicMode(
        frameStats: makeFrame(
          uiMs: 10,
          rasterMs: 8,
          buildToRasterGapUs: 5000,
          vsyncOverheadUs: 5000,
        ),
      );

      expect(verdict.suspectedPhase, PipelinePhase.pipelineStall);
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

    test('falls back to pipelineStall when no phase dominates', () {
      final frame = makeFrame(
        uiMs: 10,
        rasterMs: 8,
        buildToRasterGapUs: 5000,
        totalSpan: const Duration(milliseconds: 25),
      );

      final timelineData = ParsedTimelineData(
        buildScopeDurations: [1000],
        flushLayoutDurations: [1000],
        flushPaintDurations: [1000],
        rasterDurations: [1000],
      );

      final verdict = analyzer.analyzeFullMode(
        frameStats: frame,
        timelineData: timelineData,
      );

      expect(verdict.suspectedPhase, PipelinePhase.pipelineStall);
    });

    test('full mode reason includes PIPELINE STALL label and total span', () {
      final frame = makeFrame(
        uiMs: 10,
        rasterMs: 8,
        buildToRasterGapUs: 5000,
        totalSpan: const Duration(milliseconds: 25),
      );

      final timelineData = ParsedTimelineData(
        buildScopeDurations: [1000],
        flushLayoutDurations: [1000],
        flushPaintDurations: [1000],
        rasterDurations: [1000],
      );

      final verdict = analyzer.analyzeFullMode(
        frameStats: frame,
        timelineData: timelineData,
      );

      expect(verdict.reason, contains('PIPELINE STALL'));
      expect(verdict.reason, contains('total span'));
    });

    test('falls back to pipelineStall with moderate VM phases under budget',
        () {
      // Realistic scenario: all VM phases moderate (not tiny 1ms stubs)
      // but still under budget, while gap pushes totalSpan over budget.
      final frame = makeFrame(
        uiMs: 12,
        rasterMs: 10,
        buildToRasterGapUs: 8000,
        totalSpan: const Duration(milliseconds: 30),
      );

      final timelineData = ParsedTimelineData(
        buildScopeDurations: [5000], // 5ms
        flushLayoutDurations: [4000], // 4ms
        flushPaintDurations: [3000], // 3ms
        rasterDurations: [10000], // 10ms — under 16ms budget
      );

      final verdict = analyzer.analyzeFullMode(
        frameStats: frame,
        timelineData: timelineData,
      );

      expect(verdict.suspectedPhase, PipelinePhase.pipelineStall);
      expect(verdict.reason, contains('PIPELINE STALL'));
      expect(verdict.reason, contains('total span: 30.0ms'));
      expect(verdict.reason, contains('pipeline gap: 8.0ms'));
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
          totalBatchEventCount: 5,
        ),
      );

      expect(verdict.suspectedPhase, PipelinePhase.raster);
    });

    test('pipeline stall fallback when no phase dominates', () {
      final verdict = analyzer.analyzeCorrelatedMode(
        frameStats: makeFrame(
          uiMs: 10,
          rasterMs: 8,
          buildToRasterGapUs: 5000,
          totalSpan: const Duration(milliseconds: 25),
        ),
        correlation: const CorrelatedFrameData(
          buildScopeUs: 3000,
          flushLayoutUs: 2000,
          flushPaintUs: 1000,
          rasterUs: 4000,
          matchedEventCount: 4,
          totalBatchEventCount: 4,
        ),
      );

      expect(verdict.suspectedPhase, PipelinePhase.pipelineStall);
    });

    test('correlationCoverage metadata on verdict', () {
      final verdict = analyzer.analyzeCorrelatedMode(
        frameStats: makeFrame(uiMs: 30, rasterMs: 10),
        correlation: const CorrelatedFrameData(
          buildScopeUs: 20000,
          matchedEventCount: 3,
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
          totalBatchEventCount: 10,
        ),
      );

      expect(verdict.reason, contains('Partial correlation'));
      expect(verdict.reason, contains('3 events matched'));
    });
  });
}
