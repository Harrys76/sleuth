import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

void main() {
  group('FrameStatsBuffer.fpsPercentiles', () {
    test('empty buffer returns zero percentiles', () {
      final buffer = FrameStatsBuffer();

      final p = buffer.fpsPercentiles();
      expect(p.p50, 0);
      expect(p.p95, 0);
      expect(p.p99, 0);
    });

    test('single frame returns zero percentiles (< 2 frames)', () {
      final buffer = FrameStatsBuffer();
      buffer.add(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(microseconds: 8000),
        rasterDuration: const Duration(microseconds: 4000),
        timestamp: DateTime.now(),
      ));

      final p = buffer.fpsPercentiles();
      expect(p.p50, 0);
      expect(p.p95, 0);
      expect(p.p99, 0);
    });

    test('all-identical frames produce equal percentiles', () {
      final buffer = FrameStatsBuffer();
      // 16667us per frame = 60 FPS
      for (var i = 0; i < 20; i++) {
        buffer.add(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(microseconds: 10000),
          rasterDuration: const Duration(microseconds: 6667),
          timestamp: DateTime.now(),
        ));
      }

      final p = buffer.fpsPercentiles();
      expect(p.p50, p.p95);
      expect(p.p95, p.p99);
    });

    test('known distribution produces expected percentiles', () {
      final buffer = FrameStatsBuffer(capacity: 100);
      // 100 frames with linearly increasing durations:
      // frame 0: 10000us (~100fps clamped to 120), frame 99: 100000us (10fps)
      // Sorted ascending FPS: frame99(10fps) ... frame0(100fps)
      for (var i = 0; i < 100; i++) {
        final durationUs = 10000 + i * 909; // 10000us to ~100000us
        buffer.add(FrameStats(
          frameNumber: i,
          uiDuration: Duration(microseconds: durationUs),
          rasterDuration: Duration.zero,
          timestamp: DateTime.now(),
        ));
      }

      final p = buffer.fpsPercentiles();
      // With sorted ascending FPS values:
      // p50 (index 49): middle of the distribution
      expect(p.p50, greaterThan(15));
      expect(p.p50, lessThan(80));
      // p95 (index 94): high FPS — fast frames
      expect(p.p95, greaterThan(p.p50));
      // p99 (index 98): near the fastest frames
      expect(p.p99, greaterThanOrEqualTo(p.p95));
    });

    test('percentiles clamped to 120', () {
      final buffer = FrameStatsBuffer();
      // Very fast frames: 1us each (would be 1_000_000 FPS unclamped)
      for (var i = 0; i < 5; i++) {
        buffer.add(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(microseconds: 1),
          rasterDuration: Duration.zero,
          timestamp: DateTime.now(),
        ));
      }

      final p = buffer.fpsPercentiles();
      expect(p.p50, 120.0);
      expect(p.p95, 120.0);
      expect(p.p99, 120.0);
    });

    test('zero-duration frames treated as 120 FPS', () {
      final buffer = FrameStatsBuffer();
      for (var i = 0; i < 3; i++) {
        buffer.add(FrameStats(
          frameNumber: i,
          uiDuration: Duration.zero,
          rasterDuration: Duration.zero,
          timestamp: DateTime.now(),
        ));
      }

      final p = buffer.fpsPercentiles();
      expect(p.p50, 120.0);
    });

    test('two frames — minimum viable computation', () {
      final buffer = FrameStatsBuffer();
      // Frame 1: ~60fps, Frame 2: ~30fps
      buffer.add(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(microseconds: 10000),
        rasterDuration: const Duration(microseconds: 6667),
        timestamp: DateTime.now(),
      ));
      buffer.add(FrameStats(
        frameNumber: 2,
        uiDuration: const Duration(microseconds: 20000),
        rasterDuration: const Duration(microseconds: 13333),
        timestamp: DateTime.now(),
      ));

      final p = buffer.fpsPercentiles();
      // With 2 frames sorted ascending: [~30fps, ~60fps]
      // p50 = index 0 = ~30fps, p95 = index 0 = ~30fps, p99 = index 0 = ~30fps
      expect(p.p50, greaterThan(25));
      expect(p.p95, greaterThan(25));
      expect(p.p99, greaterThan(25));
    });
  });
}
