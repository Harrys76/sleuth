import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/frame_stats.dart';

/// Helper: create a [FrameStats] with configurable durations (in microseconds).
FrameStats _frame({
  required int number,
  int uiUs = 4000,
  int rasterUs = 3000,
}) {
  return FrameStats(
    frameNumber: number,
    uiDuration: Duration(microseconds: uiUs),
    rasterDuration: Duration(microseconds: rasterUs),
    timestamp: DateTime.now(),
  );
}

void main() {
  group('FrameStatsBuffer.averageFps (throughput)', () {
    test('empty buffer returns 0', () {
      final buffer = FrameStatsBuffer();
      expect(buffer.averageFps, 0);
    });

    test('single fast frame — clamped to 120', () {
      final buffer = FrameStatsBuffer();
      buffer.add(_frame(number: 1, uiUs: 4000, rasterUs: 3000));
      // 1,000,000 / 4,000 = 250 → clamped to 120
      expect(buffer.averageFps, 120);
    });

    test('frames at 60Hz budget (16ms) — ~62.5 FPS', () {
      final buffer = FrameStatsBuffer(capacity: 60);
      for (var i = 0; i < 60; i++) {
        buffer.add(_frame(number: i + 1, uiUs: 16000, rasterUs: 10000));
      }
      // effectiveTotalDuration = max(16ms, 10ms) = 16ms → 1,000,000/16,000 = 62.5
      expect(buffer.averageFps, closeTo(62.5, 1.0));
    });

    test('janky frames (33ms) — ~30 FPS', () {
      final buffer = FrameStatsBuffer(capacity: 30);
      for (var i = 0; i < 30; i++) {
        buffer.add(_frame(number: i + 1, uiUs: 33000, rasterUs: 10000));
      }
      // 1,000,000 / 33,000 ≈ 30.3
      expect(buffer.averageFps, closeTo(30.3, 1.0));
    });

    test('severe jank (100ms) — 10 FPS', () {
      final buffer = FrameStatsBuffer(capacity: 10);
      for (var i = 0; i < 10; i++) {
        buffer.add(_frame(number: i + 1, uiUs: 100000, rasterUs: 50000));
      }
      // 1,000,000 / 100,000 = 10
      expect(buffer.averageFps, closeTo(10.0, 0.5));
    });

    test('mixed fast and janky frames — blended throughput', () {
      final buffer = FrameStatsBuffer(capacity: 10);
      // 5 fast frames (4ms) + 5 janky frames (40ms)
      for (var i = 0; i < 5; i++) {
        buffer.add(_frame(number: i + 1, uiUs: 4000, rasterUs: 3000));
      }
      for (var i = 5; i < 10; i++) {
        buffer.add(_frame(number: i + 1, uiUs: 40000, rasterUs: 10000));
      }
      // avg = (5*4000 + 5*40000) / 10 = 22,000μs → 1,000,000/22,000 ≈ 45.5
      expect(buffer.averageFps, closeTo(45.5, 1.0));
    });

    test('zero durations returns 0', () {
      final buffer = FrameStatsBuffer(capacity: 5);
      for (var i = 0; i < 3; i++) {
        buffer.add(_frame(number: i + 1, uiUs: 0, rasterUs: 0));
      }
      expect(buffer.averageFps, 0);
    });

    test('clamped to 120 maximum', () {
      final buffer = FrameStatsBuffer(capacity: 10);
      // 1ms frames → 1,000,000/1,000 = 1000 → clamped to 120
      for (var i = 0; i < 10; i++) {
        buffer.add(_frame(number: i + 1, uiUs: 1000, rasterUs: 500));
      }
      expect(buffer.averageFps, 120);
    });

    test('raster-bottleneck frames use raster duration', () {
      final buffer = FrameStatsBuffer(capacity: 10);
      for (var i = 0; i < 10; i++) {
        buffer.add(_frame(number: i + 1, uiUs: 5000, rasterUs: 25000));
      }
      // effectiveTotalDuration = max(5ms, 25ms) = 25ms → 1,000,000/25,000 = 40
      expect(buffer.averageFps, closeTo(40.0, 1.0));
    });

    test('sub-millisecond precision — no truncation artifacts', () {
      final buffer = FrameStatsBuffer(capacity: 10);
      // 6,500μs (6.5ms) — with millisecond truncation this would be 6ms
      // giving 167 FPS instead of the correct 154 FPS
      for (var i = 0; i < 10; i++) {
        buffer.add(_frame(number: i + 1, uiUs: 6500, rasterUs: 3000));
      }
      // 1,000,000 / 6,500 ≈ 153.8 → clamped to 120
      expect(buffer.averageFps, 120);
    });

    test('averageFps is an alias for throughputFps', () {
      final buffer = FrameStatsBuffer(capacity: 10);
      for (var i = 0; i < 10; i++) {
        buffer.add(_frame(number: i + 1, uiUs: 16000, rasterUs: 10000));
      }
      expect(buffer.averageFps, buffer.throughputFps);
    });
  });

  // v0.17.0 actualFps semantics — rolling 1-second window anchored on
  // latest rasterFinishUs.
  group('FrameStatsBuffer.actualFps (count-based)', () {
    FrameStats frameAt({required int frameNumber, required int rasterUs}) {
      return FrameStats(
        frameNumber: frameNumber,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: Duration.zero,
        timestamp: DateTime(2026, 4, 22),
        rasterFinishUs: rasterUs,
      );
    }

    test('window boundary — left-inclusive', () {
      final buffer = FrameStatsBuffer();
      // Frame at latest - 1,000,000 counts; one at latest - 1,000,001 does not.
      buffer.add(frameAt(frameNumber: 1, rasterUs: 0));
      buffer.add(frameAt(frameNumber: 2, rasterUs: 999999));
      buffer.add(frameAt(frameNumber: 3, rasterUs: 1000000));
      // latest = 1_000_000; window = [0, 1_000_000].
      // Frame 1 (0) is inside. Frame 2 (999_999) inside. Frame 3 inside.
      expect(buffer.actualFps, 3);
      expect(buffer.windowSampleCount, 3);
    });

    test('window boundary — frame just outside is excluded', () {
      final buffer = FrameStatsBuffer();
      buffer.add(frameAt(frameNumber: 1, rasterUs: 0));
      buffer.add(frameAt(frameNumber: 2, rasterUs: 1000001));
      // latest = 1_000_001; window = [1, 1_000_001].
      // Frame 1 (0) is below window start → excluded.
      expect(buffer.actualFps, 1);
    });

    test('non-monotonic rasterFinishUs — latest stays latest', () {
      final buffer = FrameStatsBuffer();
      buffer.add(frameAt(frameNumber: 1, rasterUs: 500000));
      buffer.add(frameAt(frameNumber: 2, rasterUs: 1000000));
      // Out-of-order frame arrives with an older stamp — buffer keeps the
      // highest rasterFinishUs as the window anchor.
      buffer.add(frameAt(frameNumber: 3, rasterUs: 700000));
      // latest = 1_000_000; window = [0, 1_000_000] → all 3 in window.
      expect(buffer.actualFps, 3);
    });

    test('fpsTarget=120 capacity retains 240 frames in window', () {
      final buffer = FrameStatsBuffer(fpsTarget: 120);
      expect(buffer.capacity, 240);
      final stepUs = 1000000 ~/ 120;
      for (var i = 0; i < 240; i++) {
        buffer.add(frameAt(frameNumber: i + 1, rasterUs: 1000000 + i * stepUs));
      }
      // latest = 1_000_000 + 239 * 8333 ≈ 2_991_587.
      // window = [1_991_587, 2_991_587].
      // First-in-window is the frame whose rasterUs is ≥ 1_991_587.
      // That's roughly frame 120 onwards → ~120 frames in window.
      expect(buffer.actualFps, closeTo(120, 1));
    });

    test('clear() resets both FPS metrics and sample count', () {
      final buffer = FrameStatsBuffer();
      for (var i = 0; i < 60; i++) {
        buffer.add(frameAt(
          frameNumber: i + 1,
          rasterUs: 1000000 + i * 16666,
        ));
      }
      expect(buffer.actualFps, greaterThan(0));
      buffer.clear();
      expect(buffer.actualFps, 0);
      expect(buffer.windowSampleCount, 0);
      expect(buffer.throughputFps, 0);
      expect(buffer.averageFps, 0);
    });

    test('memoization — repeated reads return consistent value', () {
      final buffer = FrameStatsBuffer();
      for (var i = 0; i < 60; i++) {
        buffer.add(frameAt(
          frameNumber: i + 1,
          rasterUs: 1000000 + i * 16666,
        ));
      }
      final first = buffer.actualFps;
      final second = buffer.actualFps;
      final third = buffer.actualFps;
      expect(first, second);
      expect(second, third);
      // Adding a new frame invalidates cache and may change value.
      buffer.add(frameAt(frameNumber: 1000, rasterUs: 2000000));
      final afterAdd = buffer.actualFps;
      expect(afterAdd, isNot(equals(first)));
    });

    test('empty buffer → actualFps 0 / windowSampleCount 0', () {
      final buffer = FrameStatsBuffer();
      expect(buffer.actualFps, 0);
      expect(buffer.windowSampleCount, 0);
    });

    test('auto-sized capacity at fpsTarget=60 is 120', () {
      final buffer = FrameStatsBuffer(fpsTarget: 60);
      expect(buffer.capacity, 120);
    });

    test('explicit capacity overrides fpsTarget derivation', () {
      final buffer = FrameStatsBuffer(capacity: 60, fpsTarget: 120);
      expect(buffer.capacity, 60);
    });
  });

  // v0.17.0 C3 regression: null-tail decay. If newer frames arrive without
  // rasterFinishUs, the window anchor must not freeze on old valid
  // timestamps while the engine clock (vsyncStartUs) keeps advancing.
  group('FrameStatsBuffer.actualFps — C3 null-tail decay', () {
    FrameStats frameAt({
      required int number,
      int? rasterUs,
      int? vsyncUs,
    }) {
      return FrameStats(
        frameNumber: number,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: Duration.zero,
        timestamp: DateTime(2026, 4, 24),
        vsyncStartUs: vsyncUs,
        rasterFinishUs: rasterUs,
      );
    }

    test('healthy buffer (valid raster + valid vsync) counts normally', () {
      final buffer = FrameStatsBuffer();
      for (var i = 0; i < 60; i++) {
        final raster = 1000000 + i * 16666;
        buffer.add(frameAt(
          number: i + 1,
          rasterUs: raster,
          vsyncUs: raster - 10000,
        ));
      }
      expect(buffer.actualFps, 60);
      expect(buffer.windowSampleCount, 60);
    });

    test('null-raster tail >1s past last valid raster → actualFps decays to 0',
        () {
      final buffer = FrameStatsBuffer();
      // 30 healthy frames at 60 fps, rasterUs [1_000_000 .. 1_483_300].
      for (var i = 0; i < 30; i++) {
        final raster = 1000000 + i * 16666;
        buffer.add(frameAt(
          number: i + 1,
          rasterUs: raster,
          vsyncUs: raster - 10000,
        ));
      }
      // Now the engine stops presenting but vsyncStart keeps advancing.
      // Five frames arrive with null rasterFinishUs, latest vsync jumps
      // 2 seconds past the last valid rasterFinishUs.
      final lastRaster = 1000000 + 29 * 16666;
      for (var i = 0; i < 5; i++) {
        buffer.add(frameAt(
          number: 31 + i,
          rasterUs: null,
          vsyncUs: lastRaster + 2000000 + i * 16666,
        ));
      }
      // Both getters must decay to 0 so the UI warm-up re-engages.
      expect(buffer.actualFps, 0);
      expect(buffer.windowSampleCount, 0);
    });

    test('null-raster tail within 1s keeps counting in-window valid frames',
        () {
      // Short null tail (~100 ms) is not a freeze — transient missing
      // rasterFinish should not clobber the otherwise-valid window.
      final buffer = FrameStatsBuffer();
      for (var i = 0; i < 30; i++) {
        final raster = 1000000 + i * 16666;
        buffer.add(frameAt(
          number: i + 1,
          rasterUs: raster,
          vsyncUs: raster - 10000,
        ));
      }
      final lastRaster = 1000000 + 29 * 16666;
      // One null-raster frame 100 ms past last valid raster → inside 1 s
      // threshold, window stays live.
      buffer.add(frameAt(
        number: 31,
        rasterUs: null,
        vsyncUs: lastRaster + 100000,
      ));
      expect(buffer.actualFps, 30);
      expect(buffer.windowSampleCount, 30);
    });

    test('all frames have null rasterFinishUs → actualFps 0 (empty anchor)',
        () {
      final buffer = FrameStatsBuffer();
      for (var i = 0; i < 10; i++) {
        buffer.add(frameAt(
          number: i + 1,
          rasterUs: null,
          vsyncUs: 1000000 + i * 16666,
        ));
      }
      expect(buffer.actualFps, 0);
      expect(buffer.windowSampleCount, 0);
    });

    test('no vsyncStartUs data available → anchor fallback, no decay trigger',
        () {
      // If frames carry rasterFinishUs but no vsyncStartUs, the decay
      // sentinel cannot fire (latestVsync stays -1). Preserve v0.17.0 baseline
      // behavior — count rasterFinishUs window as before.
      final buffer = FrameStatsBuffer();
      for (var i = 0; i < 60; i++) {
        buffer.add(frameAt(
          number: i + 1,
          rasterUs: 1000000 + i * 16666,
          vsyncUs: null,
        ));
      }
      expect(buffer.actualFps, 60);
    });
  });
}
