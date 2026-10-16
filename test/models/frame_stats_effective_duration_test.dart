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

    test('a long total span from the hand-off wait alone is not jank', () {
      // A 10 ms build, a 2 ms wait for the raster thread and an 8 ms raster
      // make 20 ms end to end, but neither thread missed its 16 ms deadline.
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 8),
        timestamp: DateTime.utc(2026),
        frameBudgetMs: 16,
        totalSpan: const Duration(milliseconds: 20),
        buildToRasterGap: const Duration(milliseconds: 2),
      );
      expect(frame.isJank, isFalse);
    });

    test('start delay plus build over the budget is jank', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 4),
        timestamp: DateTime.utc(2026),
        frameBudgetMs: 16,
        vsyncOverhead: const Duration(milliseconds: 8),
      );
      expect(frame.isJank, isTrue);
    });

    test('a raster over the budget is jank', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 2),
        rasterDuration: const Duration(milliseconds: 17),
        timestamp: DateTime.utc(2026),
        frameBudgetMs: 16,
      );
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

    test('isSevereJank uses the same deadlines at twice the budget', () {
      FrameStats frame({required int delayMs, required int buildMs}) =>
          FrameStats(
            frameNumber: 1,
            uiDuration: Duration(milliseconds: buildMs),
            rasterDuration: const Duration(milliseconds: 8),
            timestamp: DateTime.utc(2026),
            frameBudgetMs: 16,
            vsyncOverhead: Duration(milliseconds: delayMs),
            totalSpan: const Duration(milliseconds: 40),
          );
      // 20 + 14 = 34 ms, over the 32 ms severe line.
      expect(frame(delayMs: 20, buildMs: 14).isSevereJank, isTrue);
      // A 40 ms total span with 10 + 14 = 24 ms on the UI thread is jank,
      // not severe.
      expect(frame(delayMs: 10, buildMs: 14).isJank, isTrue);
      expect(frame(delayMs: 10, buildMs: 14).isSevereJank, isFalse);
    });

    group('start delay from Sleuth\'s own work', () {
      FrameStats frame({required int ownUs, int buildMs = 2}) => FrameStats(
        frameNumber: 1,
        uiDuration: Duration(milliseconds: buildMs),
        rasterDuration: const Duration(milliseconds: 1),
        timestamp: DateTime.utc(2026),
        frameBudgetMs: 16,
        vsyncOverhead: const Duration(milliseconds: 30),
        ownStartDelayUs: ownUs,
      );

      test('fully covered: Sleuth overhead, not jank', () {
        final f = frame(ownUs: 30000);
        expect(f.appStartDelayUs, 0);
        expect(f.isJank, isFalse);
        expect(f.isSleuthOverhead, isTrue);
      });

      test('half covered with an 8 ms build: still the app\'s jank', () {
        final f = frame(ownUs: 15000, buildMs: 8);
        expect(f.appStartDelayUs, 15000);
        expect(f.isJank, isTrue);
        expect(f.isSleuthOverhead, isFalse);
      });

      test('a frame within the budget is neither', () {
        final f = frame(
          ownUs: 0,
        ).copyWith(vsyncOverhead: const Duration(milliseconds: 4));
        expect(f.isJank, isFalse);
        expect(f.isSleuthOverhead, isFalse);
      });

      test('ownStartDelayUs round-trips through JSON; absent reads 0', () {
        final f = frame(ownUs: 12345);
        expect(FrameStats.fromJson(f.toJson()).ownStartDelayUs, 12345);
        final json = frame(ownUs: 0).toJson();
        expect(json.containsKey('ownStartDelayUs'), isFalse);
        expect(FrameStats.fromJson(json).ownStartDelayUs, 0);
      });
    });

    test('a negative raster duration leaves only the UI side judged', () {
      final frame = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 4),
        rasterDuration: const Duration(milliseconds: -100),
        timestamp: DateTime.utc(2026),
        frameBudgetMs: 16,
      );
      expect(frame.isJank, isFalse);
      expect(
        frame.copyWith(uiDuration: const Duration(milliseconds: 20)).isJank,
        isTrue,
      );
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
    FrameStats make({int? ms, int? us, Duration? build}) => FrameStats(
      frameNumber: 1,
      uiDuration: build ?? Duration.zero,
      rasterDuration: Duration.zero,
      timestamp: DateTime.utc(2026),
      frameBudgetMs: ms,
      frameBudgetUs: us,
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
        make(us: us, build: const Duration(microseconds: 16667)).isJank,
        isFalse,
      );
      expect(
        make(us: us, build: const Duration(microseconds: 16668)).isJank,
        isTrue,
      );
      expect(
        make(us: us, build: const Duration(microseconds: 16800)).isJank,
        isTrue,
      );
      expect(
        make(us: us, build: const Duration(milliseconds: 33)).isSevereJank,
        isFalse,
      );
      expect(
        make(us: us, build: const Duration(microseconds: 33335)).isSevereJank,
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
