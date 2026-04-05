import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/frame_stats.dart';

void main() {
  group('effectiveTotalDuration', () {
    test('returns totalSpan when populated', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 8),
        timestamp: DateTime.utc(2026),
        totalSpan: const Duration(milliseconds: 25),
      );

      expect(frame.effectiveTotalDuration, const Duration(milliseconds: 25));
    });

    test('falls back to max(ui, raster) when totalSpan is null', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 8),
        timestamp: DateTime.utc(2026),
      );

      expect(frame.effectiveTotalDuration, const Duration(milliseconds: 10));
    });

    test('isJank uses totalSpan when available', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 8),
        timestamp: DateTime.utc(2026),
        frameBudgetMs: 16,
        totalSpan: const Duration(milliseconds: 20),
      );

      // totalSpan (20ms) > budget (16ms) → jank
      expect(frame.isJank, isTrue);
    });

    test('isJank falls back without totalSpan', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 8),
        timestamp: DateTime.utc(2026),
        frameBudgetMs: 16,
      );

      // max(10, 8) = 10ms < budget (16ms) → no jank
      expect(frame.isJank, isFalse);
    });

    test('isSevereJank with totalSpan', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 8),
        timestamp: DateTime.utc(2026),
        frameBudgetMs: 16,
        totalSpan: const Duration(milliseconds: 35),
      );

      // totalSpan (35ms) > 2 * budget (32ms) → severe jank
      expect(frame.isSevereJank, isTrue);
    });

    test('buildToRasterGap defaults to zero', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 8),
        timestamp: DateTime.utc(2026),
      );

      expect(frame.buildToRasterGap, Duration.zero);
    });
  });
}
