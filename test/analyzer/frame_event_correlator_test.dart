import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/analyzer/frame_event_correlator.dart';
import 'package:widget_watchdog/src/models/frame_stats.dart';
import 'package:widget_watchdog/src/models/phase_event.dart';

void main() {
  const correlator = FrameEventCorrelator();

  /// Helper to create a frame with phase timestamps.
  FrameStats makeFrame({
    required int frameNumber,
    required int buildStartUs,
    required int buildFinishUs,
    required int rasterStartUs,
    required int rasterFinishUs,
    int uiMs = 20,
    int rasterMs = 10,
    int frameBudgetMs = 16,
  }) {
    return FrameStats(
      frameNumber: frameNumber,
      uiDuration: Duration(milliseconds: uiMs),
      rasterDuration: Duration(milliseconds: rasterMs),
      timestamp: DateTime(2026, 1, 1),
      frameBudgetMs: frameBudgetMs,
      vsyncStartUs: buildStartUs - 1000,
      buildStartUs: buildStartUs,
      buildFinishUs: buildFinishUs,
      rasterStartUs: rasterStartUs,
      rasterFinishUs: rasterFinishUs,
    );
  }

  group('FrameEventCorrelator', () {
    test('returns empty map when phaseEvents is empty', () {
      final result = correlator.correlate(
        recentFrames: [
          makeFrame(
            frameNumber: 1,
            buildStartUs: 0,
            buildFinishUs: 10000,
            rasterStartUs: 10000,
            rasterFinishUs: 20000,
          ),
        ],
        phaseEvents: [],
      );

      expect(result, isEmpty);
    });

    test('returns empty map when no frames have timestamps', () {
      final noTimestampFrame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 20),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime(2026, 1, 1),
      );

      final result = correlator.correlate(
        recentFrames: [noTimestampFrame],
        phaseEvents: const [
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 5000,
            durationUs: 3000,
          ),
        ],
      );

      expect(result, isEmpty);
    });

    test('single frame, single build event — correct match', () {
      final frame = makeFrame(
        frameNumber: 1,
        buildStartUs: 0,
        buildFinishUs: 10000,
        rasterStartUs: 10500,
        rasterFinishUs: 20000,
      );

      final result = correlator.correlate(
        recentFrames: [frame],
        phaseEvents: const [
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 2000,
            durationUs: 5000,
          ),
        ],
      );

      expect(result, hasLength(1));
      expect(result[1]!.buildScopeUs, 5000);
      expect(result[1]!.matchedEventCount, 1);
      expect(result[1]!.totalBatchEventCount, 1);
      expect(result[1]!.coverageRatio, 1.0);
    });

    test('single frame, events across all phases — correct bucketing', () {
      final frame = makeFrame(
        frameNumber: 1,
        buildStartUs: 0,
        buildFinishUs: 15000,
        rasterStartUs: 15000,
        rasterFinishUs: 30000,
      );

      final result = correlator.correlate(
        recentFrames: [frame],
        phaseEvents: const [
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 1000,
            durationUs: 3000,
          ),
          PhaseEvent(
            phase: TimelinePhase.layout,
            timestampUs: 5000,
            durationUs: 4000,
          ),
          PhaseEvent(
            phase: TimelinePhase.paint,
            timestampUs: 10000,
            durationUs: 2000,
          ),
          PhaseEvent(
            phase: TimelinePhase.raster,
            timestampUs: 16000,
            durationUs: 8000,
          ),
          PhaseEvent(
            phase: TimelinePhase.shader,
            timestampUs: 25000,
            durationUs: 1000,
          ),
        ],
      );

      final data = result[1]!;
      expect(data.buildScopeUs, 3000);
      expect(data.flushLayoutUs, 4000);
      expect(data.flushPaintUs, 2000);
      expect(data.rasterUs, 8000);
      expect(data.shaderCompileUs, 1000);
      expect(data.matchedEventCount, 5);
    });

    test('multi-frame batch — events routed to correct frames', () {
      final frame1 = makeFrame(
        frameNumber: 1,
        buildStartUs: 0,
        buildFinishUs: 10000,
        rasterStartUs: 10000,
        rasterFinishUs: 20000,
      );
      final frame2 = makeFrame(
        frameNumber: 2,
        buildStartUs: 16000,
        buildFinishUs: 26000,
        rasterStartUs: 26000,
        rasterFinishUs: 36000,
      );

      final result = correlator.correlate(
        recentFrames: [frame1, frame2],
        phaseEvents: const [
          // Belongs to frame 1 (build window 0-10000)
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 2000,
            durationUs: 3000,
          ),
          // Belongs to frame 2 (build window 16000-26000)
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 18000,
            durationUs: 5000,
          ),
          // Belongs to frame 1 (raster window 10000-20000)
          PhaseEvent(
            phase: TimelinePhase.raster,
            timestampUs: 12000,
            durationUs: 4000,
          ),
        ],
      );

      expect(result, hasLength(2));
      expect(result[1]!.buildScopeUs, 3000);
      expect(result[1]!.rasterUs, 4000);
      expect(result[2]!.buildScopeUs, 5000);
      expect(result[2]!.rasterUs, 0);
    });

    test('UI vs raster thread routing — build event in UI window only', () {
      final frame = makeFrame(
        frameNumber: 1,
        buildStartUs: 0,
        buildFinishUs: 10000,
        rasterStartUs: 10000,
        rasterFinishUs: 20000,
      );

      // Build event at timestamp 5000 — should match UI window (0-10000)
      // Raster event at timestamp 5000 — should NOT match raster window (10000-20000)
      final result = correlator.correlate(
        recentFrames: [frame],
        phaseEvents: const [
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 5000,
            durationUs: 2000,
          ),
          PhaseEvent(
            phase: TimelinePhase.raster,
            timestampUs: 5000,
            durationUs: 2000,
          ),
        ],
      );

      expect(result[1]!.buildScopeUs, 2000);
      // Raster event at 5000 is outside raster window (10000-20000)
      expect(result[1]!.rasterUs, 0);
      expect(result[1]!.matchedEventCount, 1);
    });

    test('overlapping frames — raster N concurrent with UI N+1', () {
      // Frame 1: build 0-10000, raster 10000-25000
      // Frame 2: build 16000-26000, raster 26000-36000
      // Overlap: frame 1 raster (10000-25000) overlaps frame 2 build (16000-26000)
      final frame1 = makeFrame(
        frameNumber: 1,
        buildStartUs: 0,
        buildFinishUs: 10000,
        rasterStartUs: 10000,
        rasterFinishUs: 25000,
      );
      final frame2 = makeFrame(
        frameNumber: 2,
        buildStartUs: 16000,
        buildFinishUs: 26000,
        rasterStartUs: 26000,
        rasterFinishUs: 36000,
      );

      final result = correlator.correlate(
        recentFrames: [frame1, frame2],
        phaseEvents: const [
          // Build event at 18000 — in frame 2's UI window (16000-26000)
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 18000,
            durationUs: 3000,
          ),
          // Raster event at 18000 — in frame 1's raster window (10000-25000)
          PhaseEvent(
            phase: TimelinePhase.raster,
            timestampUs: 18000,
            durationUs: 3000,
          ),
        ],
      );

      // Build event goes to frame 2 (UI thread matching)
      expect(result[2]!.buildScopeUs, 3000);
      // Raster event goes to frame 1 (raster thread matching)
      expect(result[1]!.rasterUs, 3000);
    });

    test('no matching frames — events outside all windows', () {
      final frame = makeFrame(
        frameNumber: 1,
        buildStartUs: 0,
        buildFinishUs: 10000,
        rasterStartUs: 10000,
        rasterFinishUs: 20000,
      );

      final result = correlator.correlate(
        recentFrames: [frame],
        phaseEvents: const [
          // Event at 50000 — outside all frame windows
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 50000,
            durationUs: 3000,
          ),
        ],
      );

      expect(result[1]!.matchedEventCount, 0);
      expect(result[1]!.isTrustworthy, isFalse);
    });

    test('frames without timestamps are skipped', () {
      final withTimestamps = makeFrame(
        frameNumber: 1,
        buildStartUs: 0,
        buildFinishUs: 10000,
        rasterStartUs: 10000,
        rasterFinishUs: 20000,
      );
      final noTimestamps = FrameStats(
        frameNumber: 2,
        uiDuration: const Duration(milliseconds: 20),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime(2026, 1, 1),
      );

      final result = correlator.correlate(
        recentFrames: [withTimestamps, noTimestamps],
        phaseEvents: const [
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 5000,
            durationUs: 3000,
          ),
        ],
      );

      // Only frame 1 appears (frame 2 skipped)
      expect(result, hasLength(1));
      expect(result.containsKey(1), isTrue);
      expect(result.containsKey(2), isFalse);
    });

    test('binary search handles large frame sets efficiently', () {
      // 60 frames × 500 events — verifies O(E log F) vs O(E×F)
      const frameCount = 60;
      const eventCount = 500;
      const frameDurationUs = 16000; // ~16ms per frame

      final frames = List.generate(frameCount, (i) {
        final buildStart = i * frameDurationUs;
        final buildFinish = buildStart + 10000;
        final rasterStart = buildFinish;
        final rasterFinish = rasterStart + 6000;
        return makeFrame(
          frameNumber: i + 1,
          buildStartUs: buildStart,
          buildFinishUs: buildFinish,
          rasterStartUs: rasterStart,
          rasterFinishUs: rasterFinish,
        );
      });

      final events = List.generate(eventCount, (i) {
        final frameIdx = i % frameCount;
        final buildStart = frameIdx * frameDurationUs;
        return PhaseEvent(
          phase: i.isEven ? TimelinePhase.build : TimelinePhase.raster,
          timestampUs: i.isEven
              ? buildStart + 2000 // inside build window
              : buildStart + 12000, // inside raster window
          durationUs: 500,
        );
      });

      final stopwatch = Stopwatch()..start();
      final result = correlator.correlate(
        recentFrames: frames,
        phaseEvents: events,
      );
      stopwatch.stop();

      // All 500 events should match some frame
      final totalMatched =
          result.values.fold(0, (sum, d) => sum + d.matchedEventCount);
      expect(totalMatched, eventCount);
      expect(result, hasLength(frameCount));

      // Binary search should complete well under 50ms even in debug mode
      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });

    test('coverage calculation across multiple frames', () {
      final frame = makeFrame(
        frameNumber: 1,
        buildStartUs: 0,
        buildFinishUs: 10000,
        rasterStartUs: 10000,
        rasterFinishUs: 20000,
      );

      final result = correlator.correlate(
        recentFrames: [frame],
        phaseEvents: const [
          // Matches frame 1
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 2000,
            durationUs: 1000,
          ),
          // Outside all windows
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 50000,
            durationUs: 1000,
          ),
          // Outside all windows
          PhaseEvent(
            phase: TimelinePhase.raster,
            timestampUs: 50000,
            durationUs: 1000,
          ),
        ],
      );

      // 1 matched out of 3 total
      expect(result[1]!.matchedEventCount, 1);
      expect(result[1]!.totalBatchEventCount, 3);
      expect(result[1]!.coverageRatio, closeTo(0.333, 0.01));
    });

    test('empty recentFrames returns empty map', () {
      final result = correlator.correlate(
        recentFrames: [],
        phaseEvents: const [
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 5000,
            durationUs: 3000,
          ),
        ],
      );

      expect(result, isEmpty);
    });
  });
}
