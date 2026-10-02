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

  group('frameBudgetUs', () {
    FrameStats make({int? ms, int? us, Duration? span}) => FrameStats(
      frameNumber: 1,
      uiDuration: Duration.zero,
      rasterDuration: Duration.zero,
      timestamp: DateTime.utc(2026),
      frameBudgetMs: ms,
      frameBudgetUs: us,
      totalSpan: span,
    );

    test('defaults to frameBudgetMs * 1000', () {
      expect(make().frameBudgetUs, 16000);
      expect(make(ms: 8).frameBudgetUs, 8000);
    });

    test('frameBudgetUs alone derives frameBudgetMs', () {
      final f = make(us: 16667);
      expect(f.frameBudgetMs, 16);
      expect(f.frameBudgetUs, 16667);
    });

    test('isJank and isSevereJank compare in microseconds', () {
      const us = 16667;
      expect(
        make(us: us, span: const Duration(microseconds: 16667)).isJank,
        isFalse,
      );
      expect(
        make(us: us, span: const Duration(microseconds: 16668)).isJank,
        isTrue,
      );
      expect(
        make(us: us, span: const Duration(microseconds: 16800)).isJank,
        isTrue,
      );
      expect(
        make(us: us, span: const Duration(milliseconds: 33)).isSevereJank,
        isFalse,
      );
      expect(
        make(us: us, span: const Duration(microseconds: 33335)).isSevereJank,
        isTrue,
      );
    });

    test('toJson carries frameBudgetUs; fromJson round-trips', () {
      final f = make(us: 8333);
      final json = f.toJson();
      expect(json['frameBudgetUs'], 8333);
      expect(json['frameBudgetMs'], 8);
      expect(FrameStats.fromJson(json).frameBudgetUs, 8333);
    });

    test('fromJson without frameBudgetUs derives it from frameBudgetMs', () {
      final json = make(ms: 16).toJson()..remove('frameBudgetUs');
      expect(FrameStats.fromJson(json).frameBudgetUs, 16000);
      json.remove('frameBudgetMs');
      expect(FrameStats.fromJson(json).frameBudgetUs, 16000);
    });

    test('copyWith keeps the two units in step', () {
      final f = make(us: 16667);
      expect(f.copyWith(frameBudgetUs: 8333).frameBudgetMs, 8);
      expect(f.copyWith(frameBudgetMs: 8).frameBudgetUs, 8000);
      expect(f.copyWith().frameBudgetUs, 16667);
    });
  });
}
