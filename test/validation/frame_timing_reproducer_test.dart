// Hermetic reproducer for [FrameTimingDetector].
//
// Cited by `FrameTimingDetector.validationMetadata.reproducerPath` as the
// single-file evidence supporting the detector's `EvidenceTier.reproducerOnly`
// claim (v0.16.6 per-detector validation milestone).
//
// Four stableIds pinned:
//   - `sustained_jank` — ≥3 severe jank frames (>32 ms) in the sample
//   - `jank_detected` — >15 % jank frames (>16 ms), ≥5-frame sample,
//     strictly fewer than 3 severe frames (else `sustained_jank` wins
//     via the `else if` branch at `frame_timing_detector.dart:303`)
//   - `raster_cache_thrashing` — ≥15 consecutive frames of ≥20 %
//     `pictureCacheCount` fluctuation, seeded by
//     `previous.pictureCacheCount > 5`
//   - `raster_cache_growing` — ≥30 consecutive frames of monotonic
//     `totalCacheBytes` growth (`totalCacheBytes > 0`)
//
// Every stableId has BOTH a synthetic `FrameStats` leg (via
// [FrameTimingDetector.addFrameForTest]) AND a real `FrameTiming` leg
// (via [FrameTimingDetector.handleTimingsForTest]) so hand-written
// synthetic fixtures cannot encode the detector's own expected shape
// (anti-tautology, Tactic 9 / blocker B2).
//
// Warmup is bypassed in every `setUp` via `warmupDuration: Duration.zero`
// (blocker B1). Without it, the default 3-second gate at
// `_isPastWarmup` silences both `_evaluateJank` and
// `_evaluateCacheTrends` for the entire test run.
//
// Thresholds are chosen to survive `Duration.inMilliseconds` truncation
// (blocker B5): 17 ms for a jank frame (17 > 16) and 33 ms for a severe
// jank frame (33 > 32).
//
// A dedicated Impeller-zero suppression test documents why every other
// cache-family test sets `pictureCacheBytes: 1` as a belt-and-suspender
// (blocker F2): the moment all four cache metrics read 0 for ≥30
// consecutive frames, the detector marks the runtime as Impeller-backed
// and actively clears cache-family issues, which would silently eat
// both `raster_cache_thrashing` and `raster_cache_growing` if a future
// capture landed on an Impeller device.

import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  // Synthetic frame. Jank is purely a function of [totalMs]:
  //   totalMs > 16 → `FrameStats.isJank`
  //   totalMs > 32 → `FrameStats.isSevereJank`
  // `pictureCacheBytes` defaults to 1 so the Impeller-zero branch at
  // `_evaluateCacheTrends` cannot fire unless a test explicitly passes
  // 0 for every cache metric.
  FrameStats makeStats({
    required int frameNumber,
    int totalMs = 10,
    int pictureCacheCount = 0,
    int pictureCacheBytes = 1,
    int layerCacheCount = 0,
    int layerCacheBytes = 0,
  }) {
    return FrameStats(
      frameNumber: frameNumber,
      uiDuration: Duration(milliseconds: totalMs),
      rasterDuration: Duration.zero,
      timestamp:
          DateTime(2026, 4, 22).add(Duration(milliseconds: frameNumber * 16)),
      pictureCacheCount: pictureCacheCount,
      pictureCacheBytes: pictureCacheBytes,
      layerCacheCount: layerCacheCount,
      layerCacheBytes: layerCacheBytes,
      frameBudgetMs: 16,
    );
  }

  // Real `FrameTiming`. `totalSpan = rasterFinish - vsyncStart` drives
  // `effectiveTotalDuration` and therefore `isJank`/`isSevereJank` at the
  // production code path. Each frame's vsync is offset by 20 ms so the
  // detector's monotonic clock bookkeeping (`_firstFrameVsyncUs`) is
  // exercised realistically.
  FrameTiming makeTiming({
    required int frameNumber,
    int totalMs = 10,
    int pictureCacheCount = 0,
    int pictureCacheBytes = 1,
  }) {
    final vsyncStart = frameNumber * 20000;
    final rasterFinish = vsyncStart + totalMs * 1000;
    final midpoint = vsyncStart + (totalMs * 1000) ~/ 2;
    return FrameTiming(
      vsyncStart: vsyncStart,
      buildStart: vsyncStart,
      buildFinish: midpoint,
      rasterStart: midpoint,
      rasterFinish: rasterFinish,
      rasterFinishWallTime: rasterFinish,
      pictureCacheCount: pictureCacheCount,
      pictureCacheBytes: pictureCacheBytes,
    );
  }

  group('FrameTimingDetector reproducer — sustained_jank', () {
    late FrameTimingDetector detector;

    setUp(() {
      detector = FrameTimingDetector(warmupDuration: Duration.zero);
    });

    tearDown(() => detector.dispose());

    test('2 severe + 12 normal — neither sustained nor jank_detected fires',
        () {
      // Blocker B4: with 2 severe frames out of a 14-frame sample,
      // severeCount < 3 AND jankPercent = round(2 / 14 * 100) = 14,
      // which is NOT > 15 — so jank_detected also stays silent.
      for (var i = 0; i < 2; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 33));
      }
      for (var i = 2; i < 14; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 10));
      }

      expect(
        detector.issues.where((i) =>
            i.stableId == 'sustained_jank' || i.stableId == 'jank_detected'),
        isEmpty,
      );
    });

    test('3 severe + 17 normal — sustained_jank fires with critical', () {
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 33));
      }
      for (var i = 3; i < 20; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 10));
      }

      final sustained =
          detector.issues.where((i) => i.stableId == 'sustained_jank').toList();
      expect(sustained, hasLength(1));
      expect(sustained.first.severity, IssueSeverity.critical);
    });

    test(
        'real FrameTiming pipeline — sustained_jank fires via '
        'handleTimingsForTest', () {
      // Blocker B2: anti-tautology leg. The synthetic `addFrameForTest`
      // path bypasses the `_onTimings` FrameStats construction; this leg
      // drives the detector through the exact `addTimingsCallback` code
      // path the engine uses.
      final timings = <FrameTiming>[
        for (var i = 0; i < 3; i++) makeTiming(frameNumber: i, totalMs: 33),
        for (var i = 3; i < 20; i++) makeTiming(frameNumber: i, totalMs: 10),
      ];
      detector.handleTimingsForTest(timings);

      expect(
        detector.issues.where((i) => i.stableId == 'sustained_jank'),
        hasLength(1),
      );
    });
  });

  group('FrameTimingDetector reproducer — jank_detected', () {
    late FrameTimingDetector detector;

    setUp(() {
      detector = FrameTimingDetector(warmupDuration: Duration.zero);
    });

    tearDown(() => detector.dispose());

    test('3 jank (non-severe) out of 19 — 16 % rounds above threshold', () {
      // jankPercent = round(3 / 19 * 100) = 16 > 15 → fires.
      // No severe frames → sustained_jank does NOT fire (the `else if`
      // branch at frame_timing_detector.dart:303 only runs when
      // severeCount < 3).
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 17));
      }
      for (var i = 3; i < 19; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 10));
      }

      final jank =
          detector.issues.where((i) => i.stableId == 'jank_detected').toList();
      expect(jank, hasLength(1));
      expect(jank.first.severity, IssueSeverity.warning);
      expect(
        detector.issues.where((i) => i.stableId == 'sustained_jank'),
        isEmpty,
        reason: 'no severe frames → no sustained_jank',
      );
    });

    test('2 jank out of 14 — 14 % below threshold stays silent', () {
      for (var i = 0; i < 2; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 17));
      }
      for (var i = 2; i < 14; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 10));
      }

      expect(
        detector.issues.where((i) => i.stableId == 'jank_detected'),
        isEmpty,
      );
    });

    test(
        'real FrameTiming pipeline — jank_detected fires via '
        'handleTimingsForTest', () {
      final timings = <FrameTiming>[
        for (var i = 0; i < 3; i++) makeTiming(frameNumber: i, totalMs: 17),
        for (var i = 3; i < 19; i++) makeTiming(frameNumber: i, totalMs: 10),
      ];
      detector.handleTimingsForTest(timings);

      expect(
        detector.issues.where((i) => i.stableId == 'jank_detected'),
        hasLength(1),
      );
    });
  });

  group('FrameTimingDetector reproducer — raster_cache_thrashing', () {
    late FrameTimingDetector detector;

    setUp(() {
      detector = FrameTimingDetector(warmupDuration: Duration.zero);
    });

    tearDown(() => detector.dispose());

    test('seed + 15 consecutive >20 % fluctuations — thrashing fires', () {
      // Seed frame: pictureCacheCount = 10 (>5, so the
      // `previous.pictureCacheCount > 5` branch drives the delta check
      // on frame 1). Then 15 frames alternating 10 / 20 — each delta is
      // 10, variation is 0.5 or 1.0, both > 0.20.
      detector
          .addFrameForTest(makeStats(frameNumber: 0, pictureCacheCount: 10));
      for (var i = 1; i <= 15; i++) {
        detector.addFrameForTest(
          makeStats(
            frameNumber: i,
            pictureCacheCount: i.isOdd ? 20 : 10,
          ),
        );
      }

      final thrashing = detector.issues
          .where((i) => i.stableId == 'raster_cache_thrashing')
          .toList();
      expect(thrashing, hasLength(1));
      expect(thrashing.first.severity, IssueSeverity.warning);
    });

    test('seed + 14 fluctuations (one short of window) — silent', () {
      detector
          .addFrameForTest(makeStats(frameNumber: 0, pictureCacheCount: 10));
      for (var i = 1; i <= 14; i++) {
        detector.addFrameForTest(
          makeStats(
            frameNumber: i,
            pictureCacheCount: i.isOdd ? 20 : 10,
          ),
        );
      }

      expect(
        detector.issues.where((i) => i.stableId == 'raster_cache_thrashing'),
        isEmpty,
      );
    });

    test(
        'real FrameTiming pipeline — thrashing fires via '
        'handleTimingsForTest', () {
      // `_onTimings` evaluates cache trends ONCE per batch (comparing
      // `frames.last` to `frames[frames.length - 2]`) — submit frames
      // individually so `_consecutiveThrashingFrames` accumulates per
      // consecutive pair, matching what a real `addTimingsCallback`
      // cadence produces on-device.
      detector.handleTimingsForTest(
        [makeTiming(frameNumber: 0, pictureCacheCount: 10)],
      );
      for (var i = 1; i <= 15; i++) {
        detector.handleTimingsForTest([
          makeTiming(
            frameNumber: i,
            pictureCacheCount: i.isOdd ? 20 : 10,
          ),
        ]);
      }

      expect(
        detector.issues.where((i) => i.stableId == 'raster_cache_thrashing'),
        hasLength(1),
      );
    });
  });

  group('FrameTimingDetector reproducer — raster_cache_growing', () {
    late FrameTimingDetector detector;

    setUp(() {
      detector = FrameTimingDetector(warmupDuration: Duration.zero);
    });

    tearDown(() => detector.dispose());

    test('31 frames with monotonic totalCacheBytes growth — growing fires', () {
      // 31 frames → 30 pairwise comparisons where latest.totalCacheBytes
      // > previous.totalCacheBytes. `_consecutiveGrowthFrames` reaches
      // the window threshold of 30 → fires.
      for (var i = 0; i <= 30; i++) {
        detector.addFrameForTest(
          makeStats(
            frameNumber: i,
            // 1 KiB per frame, always > 0 so the Impeller-zero branch
            // never arms (F2 belt-and-suspender).
            pictureCacheBytes: 1024 * (i + 1),
          ),
        );
      }

      final growing = detector.issues
          .where((i) => i.stableId == 'raster_cache_growing')
          .toList();
      expect(growing, hasLength(1));
      expect(growing.first.severity, IssueSeverity.warning);
    });

    test('30 frames (one pairwise comparison short) — silent', () {
      for (var i = 0; i <= 29; i++) {
        detector.addFrameForTest(
          makeStats(
            frameNumber: i,
            pictureCacheBytes: 1024 * (i + 1),
          ),
        );
      }

      expect(
        detector.issues.where((i) => i.stableId == 'raster_cache_growing'),
        isEmpty,
      );
    });

    test(
        'real FrameTiming pipeline — growing fires via '
        'handleTimingsForTest', () {
      // Same per-frame cadence reason as the thrashing leg —
      // `_evaluateCacheTrends` fires once per batch.
      for (var i = 0; i <= 30; i++) {
        detector.handleTimingsForTest([
          makeTiming(
            frameNumber: i,
            pictureCacheBytes: 1024 * (i + 1),
          ),
        ]);
      }

      expect(
        detector.issues.where((i) => i.stableId == 'raster_cache_growing'),
        hasLength(1),
      );
    });
  });

  group('FrameTimingDetector reproducer — Impeller-zero suppression', () {
    late FrameTimingDetector detector;

    setUp(() {
      detector = FrameTimingDetector(warmupDuration: Duration.zero);
    });

    tearDown(() => detector.dispose());

    test(
        '30 consecutive all-zero cache frames after an active thrashing '
        'issue clears the issue', () {
      // Seed a thrashing pattern so `raster_cache_thrashing` is actively
      // emitted.
      detector
          .addFrameForTest(makeStats(frameNumber: 0, pictureCacheCount: 10));
      for (var i = 1; i <= 15; i++) {
        detector.addFrameForTest(
          makeStats(
            frameNumber: i,
            pictureCacheCount: i.isOdd ? 20 : 10,
          ),
        );
      }
      expect(
        detector.issues.where((i) => i.stableId == 'raster_cache_thrashing'),
        hasLength(1),
        reason: 'precondition: thrashing must be active before suppression',
      );

      // Now feed 30 all-zero cache frames. After 30 consecutive frames
      // with all four metrics zero, `_impellerDetected` flips true and
      // the thrashing issue is removed.
      for (var i = 16; i < 46; i++) {
        detector.addFrameForTest(
          FrameStats(
            frameNumber: i,
            uiDuration: const Duration(milliseconds: 10),
            rasterDuration: Duration.zero,
            timestamp:
                DateTime(2026, 4, 22).add(Duration(milliseconds: i * 16)),
            // All four cache metrics literally zero — this is the only
            // shape that arms the Impeller-detected branch. Every other
            // cache-family test in this file uses pictureCacheBytes: 1
            // precisely so this branch cannot silently eat their signal
            // (blocker F2).
            pictureCacheCount: 0,
            pictureCacheBytes: 0,
            layerCacheCount: 0,
            layerCacheBytes: 0,
            frameBudgetMs: 16,
          ),
        );
      }

      expect(
        detector.issues.where((i) =>
            i.stableId == 'raster_cache_thrashing' ||
            i.stableId == 'raster_cache_growing'),
        isEmpty,
        reason: '30 all-zero frames arm Impeller suppression, clearing '
            'cache-family issues',
      );
    });
  });
}
