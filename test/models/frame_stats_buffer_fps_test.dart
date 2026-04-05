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
  });
}
