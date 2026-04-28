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

    // Parallel-emission semantics: when both gates are true (severeCount
    // >= 3 AND jankPercent > 15) BOTH stableIds fire. Pre-v0.19.6 used
    // `if/else if` which suppressed `jank_detected` whenever
    // `sustained_jank` fired — on devices with ambient severeCount >= 3
    // that made warning-tier signal structurally unreachable, blocking
    // runtimeVerified bracket captures. Overlap fixture pins the
    // parallel-emission contract so a future regression to mutual
    // exclusion is caught.
    test('overlap (severe + jank both gates true) — both stableIds fire', () {
      // 5 severe frames (>33ms) AND remaining 15 frames at 20ms
      // (jank but not severe). Total 20 frames: severeCount=5
      // (>=3 critical gate) AND jankCount=20 (jankPercent=100%, >15
      // warning gate). Both gates satisfied — both stableIds fire
      // concurrently.
      for (var i = 0; i < 5; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 50));
      }
      for (var i = 5; i < 20; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 20));
      }

      final sustained =
          detector.issues.where((i) => i.stableId == 'sustained_jank');
      final jankDetected =
          detector.issues.where((i) => i.stableId == 'jank_detected');
      expect(sustained, hasLength(1),
          reason: 'severeCount >= 3 → sustained_jank.critical fires');
      expect(jankDetected, hasLength(1),
          reason: 'jankPercent > 15 → jank_detected.warning fires '
              'concurrently (Option B parallel emission)');
      expect(sustained.first.severity, IssueSeverity.critical);
      expect(jankDetected.first.severity, IssueSeverity.warning);
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

  // v0.17.0 FPS semantics (count-based actualFps, rolling 1-s window
  // anchored on latest rasterFinishUs). Every test uses the real
  // `handleTimingsForTest` path so hand-written synthetic fixtures
  // cannot encode the detector's own expected shape (Tactic 9).
  group('FrameTimingDetector reproducer — FPS semantics', () {
    // Build one `FrameTiming` per intended-presented frame with rasterFinish
    // timestamps stepping at `1_000_000 / fps` microseconds. Matches the
    // engine's real monotonic rasterFinishUs contract.
    FrameTiming makeFpsTiming({
      required int frameNumber,
      required int rasterFinishUs,
    }) {
      // 10 ms synthetic frame — not jank. vsyncStart anchored so each frame
      // is ≥ 10 ms after the previous raster finish.
      final vsyncStart = rasterFinishUs - 10000;
      final midpoint = vsyncStart + 5000;
      return FrameTiming(
        vsyncStart: vsyncStart,
        buildStart: vsyncStart,
        buildFinish: midpoint,
        rasterStart: midpoint,
        rasterFinish: rasterFinishUs,
        rasterFinishWallTime: rasterFinishUs,
        pictureCacheCount: 0,
        pictureCacheBytes: 1,
      );
    }

    test('60 monotonic frames over 1s → actualFps == 60', () {
      final detector = FrameTimingDetector(warmupDuration: Duration.zero);
      final stepUs = 1000000 ~/ 60;
      final timings = List.generate(
        60,
        (i) => makeFpsTiming(
          frameNumber: i + 1,
          rasterFinishUs: 1000000 + i * stepUs,
        ),
      );
      detector.handleTimingsForTest(timings);
      expect(detector.frameBuffer.actualFps, 60);
      expect(detector.frameBuffer.windowSampleCount, 60);
    });

    test('120 monotonic frames @ fpsTarget=120 → actualFps == 120', () {
      final detector = FrameTimingDetector(
        fpsTarget: 120,
        warmupDuration: Duration.zero,
      );
      // Capacity must auto-size to (120 * 2).clamp(60, 240) = 240 so a
      // full 1-s window of 120 frames is retained without eviction.
      expect(detector.frameBuffer.capacity, 240);
      final stepUs = 1000000 ~/ 120;
      final timings = List.generate(
        120,
        (i) => makeFpsTiming(
          frameNumber: i + 1,
          rasterFinishUs: 1000000 + i * stepUs,
        ),
      );
      detector.handleTimingsForTest(timings);
      expect(detector.frameBuffer.actualFps, 120);
    });

    test('batched delivery — all 60 timings in one callback → actualFps == 60',
        () {
      final detector = FrameTimingDetector(warmupDuration: Duration.zero);
      final stepUs = 1000000 ~/ 60;
      // Single call with all 60 — the engine can batch on slow hardware.
      // Window math is anchored on rasterFinishUs, so arrival pattern is
      // irrelevant.
      detector.handleTimingsForTest(
        List.generate(
          60,
          (i) => makeFpsTiming(
            frameNumber: i + 1,
            rasterFinishUs: 1000000 + i * stepUs,
          ),
        ),
      );
      expect(detector.frameBuffer.actualFps, 60);
    });

    test('window slides — 90 frames over 1.5s, newest stays ~60', () {
      final detector = FrameTimingDetector(warmupDuration: Duration.zero);
      final stepUs = 1000000 ~/ 60; // 60 FPS cadence, 1.5 s total
      final timings = List.generate(
        90,
        (i) => makeFpsTiming(
          frameNumber: i + 1,
          rasterFinishUs: 1000000 + i * stepUs,
        ),
      );
      detector.handleTimingsForTest(timings);
      // Oldest frames fell out of the 1-s window, newest ~60 in.
      // ±1 tolerance for the integer step rounding (stepUs = 16666 μs).
      expect(detector.frameBuffer.actualFps, closeTo(60, 1));
    });

    test('zero frames → actualFps == 0, windowSampleCount == 0', () {
      final detector = FrameTimingDetector(warmupDuration: Duration.zero);
      expect(detector.frameBuffer.actualFps, 0);
      expect(detector.frameBuffer.windowSampleCount, 0);
    });

    test('null rasterFinishUs → frame present but not counted', () {
      final detector = FrameTimingDetector(warmupDuration: Duration.zero);
      // Synthetic FrameStats with no rasterFinishUs.
      detector.addFrameForTest(
        FrameStats(
          frameNumber: 1,
          uiDuration: const Duration(milliseconds: 10),
          rasterDuration: Duration.zero,
          timestamp: DateTime(2026, 4, 22),
        ).copyWith(rasterFinishUs: null),
      );
      // `addFrameForTest` auto-injects rasterFinishUs when null.
      // To pin "null propagates through buffer math" directly, clear and
      // add one frame via the raw buffer on a fresh buffer instance.
      final buffer = FrameStatsBuffer();
      buffer.add(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: Duration.zero,
        timestamp: DateTime(2026, 4, 22),
      ));
      expect(buffer.latest, isNotNull);
      expect(buffer.windowSampleCount, 0);
      expect(buffer.actualFps, 0);
    });
  });

  // -- v0.19.6 — runtimeVerified raise plumbing --
  // These four groups pin the structural plumbing that supports the
  // `jank_detected` perStableIdTier raise: capture-mode warmup short-circuit,
  // emission-seq monotonicity (audit-gate uniqueness invariant), reset()
  // semantics with `_emissionSeq` preservation, and `extraTraceArgs` shape.
  group('FrameTimingDetector v0.19.6 — captureMode warmup short-circuit', () {
    test(
        'captureMode=true bypasses 3 s warmup — fires on synthetic frames '
        'without elapsing warmupDuration', () {
      final detector = FrameTimingDetector(captureMode: true);
      addTearDown(detector.dispose);
      // Inject 3 jank + 16 normal at a timestamp 0 baseline. With captureMode
      // OFF the default 3 s warmupDuration would suppress this entirely.
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 17));
      }
      for (var i = 3; i < 19; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 10));
      }
      expect(
        detector.issues.where((i) => i.stableId == 'jank_detected'),
        hasLength(1),
        reason: 'captureMode short-circuits warmup',
      );
    });

    test(
        'captureMode=false preserves warmupDuration suppression — synthetic '
        'frames at default 3 s gate stay silent', () {
      final detector = FrameTimingDetector(); // captureMode=false default
      addTearDown(detector.dispose);
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 17));
      }
      for (var i = 3; i < 19; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 10));
      }
      expect(detector.issues, isEmpty,
          reason: 'default warmup gate suppresses');
    });
  });

  group('FrameTimingDetector v0.19.6 — extraTraceArgs shape', () {
    test(
        'jank_detected emission carries observedJankCount, '
        'observedJankPercent, observedWorstFrameMs, bufferSize as String args',
        () {
      final detector = FrameTimingDetector(warmupDuration: Duration.zero);
      addTearDown(detector.dispose);
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 22));
      }
      for (var i = 3; i < 19; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 10));
      }
      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'jank_detected');
      expect(issue.extraTraceArgs, isNotNull);
      expect(
          issue.extraTraceArgs!.keys,
          containsAll(<String>{
            'observedJankCount',
            'observedJankPercent',
            'observedWorstFrameMs',
            'bufferSize',
          }));
      // Per Timeline arg-encoding contract values are stringified.
      for (final v in issue.extraTraceArgs!.values) {
        expect(v, isA<String>());
      }
      expect(int.parse(issue.extraTraceArgs!['observedJankCount']!), 3);
      expect(int.parse(issue.extraTraceArgs!['bufferSize']!), 19);
      // Worst frame must reflect the 22 ms injected jank.
      final worstMs =
          double.parse(issue.extraTraceArgs!['observedWorstFrameMs']!);
      expect(worstMs, closeTo(22.0, 0.5));
    });
  });

  group('FrameTimingDetector v0.19.6 — _emissionSeq monotonicity', () {
    test(
        'back-to-back evaluations across multiple emissions produce '
        'STRICTLY-INCREASING dedupIdentityMicros (audit-gate uniqueness '
        'invariant)', () {
      final detector = FrameTimingDetector(warmupDuration: Duration.zero);
      addTearDown(detector.dispose);

      final identities = <int>[];
      for (var leg = 0; leg < 5; leg++) {
        // Each cycle: clear + repopulate to force a fresh _evaluateJank
        // emission. Without the +(_emissionSeq++) tie-breaker the same
        // microsecond clock could collide across consecutive evaluations.
        detector.reset();
        for (var i = 0; i < 3; i++) {
          detector.addFrameForTest(
              makeStats(frameNumber: i + leg * 100, totalMs: 17));
        }
        for (var i = 3; i < 19; i++) {
          detector.addFrameForTest(
              makeStats(frameNumber: i + leg * 100, totalMs: 10));
        }
        final issue =
            detector.issues.firstWhere((i) => i.stableId == 'jank_detected');
        expect(issue.dedupIdentityMicros, isNotNull);
        identities.add(issue.dedupIdentityMicros!);
      }
      // Strictly increasing across legs — `_emissionSeq` MUST persist
      // through `reset()` so the audit-gate uniqueness invariant holds.
      for (var i = 1; i < identities.length; i++) {
        expect(identities[i], greaterThan(identities[i - 1]),
            reason: 'identities should strictly increase across reset()s');
      }
    });
  });

  group('FrameTimingDetector v0.19.6 — reset() semantics', () {
    test('reset clears buffer, issues, warmup anchors, cache-trend counters',
        () {
      final detector = FrameTimingDetector(warmupDuration: Duration.zero);
      addTearDown(detector.dispose);
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 17));
      }
      for (var i = 3; i < 19; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 10));
      }
      expect(detector.frameBuffer.frames, isNotEmpty);
      expect(detector.issues, isNotEmpty);

      detector.reset();

      expect(detector.frameBuffer.frames, isEmpty, reason: 'buffer cleared');
      expect(detector.issues, isEmpty, reason: 'issues cleared');
      // Re-priming after reset must work — warmup anchors cleared.
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 17));
      }
      for (var i = 3; i < 19; i++) {
        detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 10));
      }
      expect(
        detector.issues.where((i) => i.stableId == 'jank_detected'),
        hasLength(1),
        reason: 'detector functional after reset',
      );
    });
  });
}
