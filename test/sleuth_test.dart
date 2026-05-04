import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

void main() {
  group('PerformanceIssue', () {
    test('creates with required fields', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Test Issue',
        detail: 'Detail text',
        fixHint: 'Fix this',
      );

      expect(issue.severity, IssueSeverity.warning);
      expect(issue.category, IssueCategory.build);
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.title, 'Test Issue');
    });

    test('copyWith preserves original values', () {
      const original = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Original',
        detail: 'Detail',
        fixHint: 'Fix',
      );

      final copy = original.copyWith(severity: IssueSeverity.critical);
      expect(copy.severity, IssueSeverity.critical);
      expect(copy.title, 'Original'); // Preserved
    });
  });

  group('FrameStats', () {
    test('detects jank correctly', () {
      final stats = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 20),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
      );

      expect(stats.isJank, true);
      expect(stats.isSevereJank, false);
    });

    test('detects severe jank', () {
      final stats = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 40),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
      );

      expect(stats.isSevereJank, true);
    });

    test('frameBudgetMs drives jank thresholds', () {
      // 120fps → 8ms budget. A 10ms frame is jank at 120fps but not at 60fps.
      final at120fps = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 5),
        timestamp: DateTime.now(),
        frameBudgetMs: 8, // 120fps
      );

      final at60fps = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 5),
        timestamp: DateTime.now(),
        frameBudgetMs: 16, // 60fps (default)
      );

      expect(at120fps.isJank, true);
      expect(at60fps.isJank, false);

      // Severe jank = 2x budget. 20ms is severe at 120fps (>16ms) but not at 60fps (>32ms).
      final severe120 = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 20),
        rasterDuration: const Duration(milliseconds: 5),
        timestamp: DateTime.now(),
        frameBudgetMs: 8,
      );

      expect(severe120.isSevereJank, true);
      expect(at60fps.isSevereJank, false);
    });
  });

  group('FrameStatsBuffer', () {
    test('maintains capacity limit', () {
      final buffer = FrameStatsBuffer(capacity: 3);

      for (var i = 0; i < 5; i++) {
        buffer.add(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 8),
          rasterDuration: const Duration(milliseconds: 4),
          timestamp: DateTime.now(),
        ));
      }

      expect(buffer.length, 3);
      expect(buffer.frames.first.frameNumber, 2);
    });
  });

  group('TimelineParser', () {
    test('parses empty list', () {
      final result = TimelineParser.parse([]);
      expect(result.hasData, false);
    });
  });

  group('Sleuth.flushTimelineNow (v0.18.1)', () {
    test('returns immediately when no controller is registered', () async {
      // Cold state: no Sleuth.track(...) call has registered a controller.
      // The public API must return without throwing or hanging.
      final sw = Stopwatch()..start();
      await Sleuth.flushTimelineNow();
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(50),
          reason: 'flushTimelineNow with no controller must noop fast — '
              'production sessions hit this path every poll-cadence tick.');
    });

    test('accepts a timeout parameter without controller side effects',
        () async {
      // Verifies the public-API signature is the contract we shipped.
      // With no controller registered the timeout is irrelevant — the
      // gate returns before ever building a timeout future.
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 1));
    });
  });

  group('Sleuth.track auto-init', () {
    // The documented quick-start `runApp(Sleuth.track(child: MyApp()))` must
    // populate `Sleuth.dartEntryMonotonicUs` so detectors that compare
    // timeline timestamps against app-start (e.g. ShaderJankDetector
    // cold_start branch) reach a non-null clock. Without `track()` invoking
    // `init()`, that integration silently no-ops.
    setUp(Sleuth.resetStartupForTest);
    tearDown(Sleuth.resetStartupForTest);

    testWidgets('Sleuth.track() captures dartEntryMonotonicUs', (tester) async {
      // Stage 1: confirm the reset hook actually cleared static state.
      // Without this, a Stage-2 non-null assertion is vacuous when prior
      // tests left the static populated.
      expect(
        Sleuth.dartEntryMonotonicUs,
        isNull,
        reason: 'reset hook left dartEntryMonotonicUs populated; '
            'Stage-2 assertion would be vacuous.',
      );

      // Stage 2: track() must call init() so dartEntryMonotonicUs is set.
      // pumpWidget mounts SleuthOverlay so the framework calls its
      // dispose() at test teardown, which clears the static `_controller`
      // via Sleuth.notifyControllerDisposed. A plain `test` body with a
      // bare `Sleuth.track(...)` call would leak `_controller` into the
      // suite, breaking later tests that assume cold state under shuffle.
      await tester.pumpWidget(Sleuth.track(child: const SizedBox()));

      expect(
        Sleuth.dartEntryMonotonicUs,
        isNotNull,
        reason: 'Sleuth.track() must call Sleuth.init() so '
            'dartEntryMonotonicUs is populated for downstream detectors.',
      );
      expect(Sleuth.dartEntryMonotonicUs, greaterThan(0));
    });
  });

  group('lifecyclePhase production-anchor integration', () {
    // The lifecyclePhase tag is observable in capture-mode trace records
    // and audit-gate replay, but reproducer tests pin classification via
    // the `appStartMonotonicUsForTest` ctor override. This integration
    // test covers the production code path: `Sleuth.track()` populates
    // `Sleuth.dartEntryMonotonicUs`, a detector constructed WITHOUT the
    // override reads the same static, and the resulting emission stamps
    // `lifecyclePhase: 'startup'`.
    //
    // Catches regressions in: import cycle between detector and Sleuth
    // class, static-state setup race, controller construction wire-up.
    setUp(Sleuth.resetStartupForTest);
    tearDown(Sleuth.resetStartupForTest);

    FrameStats makeStats({required int frameNumber, int totalMs = 10}) =>
        FrameStats(
          frameNumber: frameNumber,
          uiDuration: Duration(milliseconds: totalMs),
          rasterDuration: Duration.zero,
          timestamp: DateTime(2026, 5, 5)
              .add(Duration(milliseconds: frameNumber * 16)),
          pictureCacheCount: 0,
          pictureCacheBytes: 1,
          layerCacheCount: 0,
          layerCacheBytes: 0,
          frameBudgetMs: 16,
        );

    testWidgets(
      'jank_detected stamps lifecyclePhase via Sleuth.dartEntryMonotonicUs '
      '(no test override)',
      (tester) async {
        await tester.pumpWidget(Sleuth.track(child: const SizedBox()));
        expect(
          Sleuth.dartEntryMonotonicUs,
          isNotNull,
          reason: 'Sleuth.track() must populate the production anchor.',
        );

        final detector = FrameTimingDetector(warmupDuration: Duration.zero);
        addTearDown(detector.dispose);

        // 3 jank (>16 ms) out of 19 frames → 16 % rounds above the 15 %
        // gate → jank_detected fires (sustained_jank requires ≥3 severe
        // (>32 ms) frames, which 17-ms frames do not satisfy).
        for (var i = 0; i < 3; i++) {
          detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 17));
        }
        for (var i = 3; i < 19; i++) {
          detector.addFrameForTest(makeStats(frameNumber: i, totalMs: 10));
        }

        final issue =
            detector.issues.firstWhere((i) => i.stableId == 'jank_detected');
        expect(
          issue.extraTraceArgs?['lifecyclePhase'],
          'startup',
          reason: 'lifecyclePhase must populate via the production '
              'Sleuth.dartEntryMonotonicUs anchor without an explicit '
              'appStartMonotonicUsForTest override. A missing or null '
              'value indicates a wire-up regression in controller '
              'construction or Sleuth static-state setup.',
        );
      },
    );
  });
}
