// Hermetic reproducer for [StartupDetector].
//
// Pins `slow_startup_ttff` via `prepareScan` (the detector's one-shot
// path — element methods are no-ops because startup timing is
// FrameTiming/wall-clock-based, not tree-structural).
//
// The first group injects [StartupMetrics] through the
// `@visibleForTesting` hooks on [Sleuth] (`setStartupMetricsForTest` /
// `resetStartupForTest`). The second runs the real measurement. It calls
// `Sleuth.init()` with `Sleuth.startupClockForTest` set and delivers a
// first-frame timing report through the binding's `onReportTimings`, so
// the timings callback that the app uses computes `ttffMs`. Each test
// uses a fresh detector instance to keep the `_consumed` one-shot guard
// isolated.

import 'dart:ui' show FrameTiming;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/sleuth.dart';
import 'package:sleuth/src/detectors/startup_detector.dart';

Future<void> _pumpEmpty(WidgetTester tester) => tester.pumpWidget(
  const Directionality(textDirection: TextDirection.ltr, child: SizedBox()),
);

BuildContext _root(WidgetTester tester) =>
    tester.element(find.byType(Directionality));

void main() {
  tearDown(Sleuth.resetStartupForTest);

  group('StartupDetector reproducer', () {
    // --- slow_startup_ttff ---------------------------------------------

    testWidgets('slow_startup_ttff: ttffMs above warning threshold fires '
        '(confirmed confidence)', (tester) async {
      Sleuth.setStartupMetricsForTest(
        StartupMetrics(
          dartEntryTimestamp: DateTime.utc(2026),
          ttffMs: 2000, // > 1500 warning, < 3000 critical → warning
        ),
      );
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      expect(
        detector.issues.any((i) => i.stableId == 'slow_startup_ttff'),
        isTrue,
      );
      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'slow_startup_ttff',
      );
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.confidence, IssueConfidence.confirmed);
    });

    testWidgets(
      'slow_startup_ttff: ttffMs >= critical threshold emits critical',
      (tester) async {
        Sleuth.setStartupMetricsForTest(
          StartupMetrics(
            dartEntryTimestamp: DateTime.utc(2026),
            ttffMs: 3500, // >= 3000 critical
          ),
        );
        final detector = StartupDetector();
        await _pumpEmpty(tester);
        detector.prepareScan(_root(tester));
        final issue = detector.issues.firstWhere(
          (i) => i.stableId == 'slow_startup_ttff',
        );
        expect(issue.severity, IssueSeverity.critical);
      },
    );

    testWidgets('slow_startup_ttff: ttffMs below warning threshold silent '
        '(strict-less: `ttff < ttffWarningMs` early-returns)', (tester) async {
      Sleuth.setStartupMetricsForTest(
        StartupMetrics(
          dartEntryTimestamp: DateTime.utc(2026),
          ttffMs: 1499, // just under warning (1500)
        ),
      );
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      expect(detector.issues, isEmpty);
    });

    testWidgets('slow_startup_ttff: ttffMs null → silent', (tester) async {
      // Models the "`Sleuth.init` not called before `runApp`" case — the
      // detector's `_checkTtff` early-returns on null ttffMs.
      Sleuth.setStartupMetricsForTest(
        StartupMetrics(dartEntryTimestamp: DateTime.utc(2026), ttffMs: null),
      );
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      expect(detector.issues, isEmpty);
    });

    testWidgets('slow_startup_ttff: no StartupMetrics at all → silent', (
      tester,
    ) async {
      // `Sleuth.startupMetrics == null` path — prepareScan short-circuits
      // before touching _consumed.
      Sleuth.resetStartupForTest();
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      expect(detector.issues, isEmpty);
    });

    testWidgets('slow_startup_ttff: second prepareScan is a no-op '
        '(one-shot `_consumed` guard)', (tester) async {
      Sleuth.setStartupMetricsForTest(
        StartupMetrics(dartEntryTimestamp: DateTime.utc(2026), ttffMs: 2000),
      );
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      expect(detector.issues.length, 1);

      // Mutate metrics to something that WOULD emit a different outcome
      // if the detector re-evaluated — one-shot must ignore.
      Sleuth.setStartupMetricsForTest(
        StartupMetrics(dartEntryTimestamp: DateTime.utc(2026), ttffMs: 100),
      );
      detector.prepareScan(_root(tester));
      expect(
        detector.issues.length,
        1,
        reason: 'Second prepareScan must be a no-op.',
      );
    });
  });

  group('Sleuth.init measurement path', () {
    late DateTime now;

    setUp(() {
      Sleuth.resetStartupForTest();
      now = DateTime.utc(2026, 10, 16, 12);
      Sleuth.startupClockForTest = () => now;
    });

    // Delivers one first-frame timing report to every registered timings
    // callback, as the engine does after the first frame's raster.
    void reportFirstFrame(WidgetTester tester) {
      tester.binding.platformDispatcher.onReportTimings?.call([
        FrameTiming(
          vsyncStart: 1000,
          buildStart: 1100,
          buildFinish: 2100,
          rasterStart: 2200,
          rasterFinish: 3200,
          rasterFinishWallTime: 3200,
        ),
      ]);
    }

    Future<StartupDetector> scan(WidgetTester tester) async {
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      return detector;
    }

    for (final (ms, severity) in [
      (1499.9, null),
      (1500.0, IssueSeverity.warning),
      (2999.9, IssueSeverity.warning),
      (3000.0, IssueSeverity.critical),
    ]) {
      testWidgets('$ms ms from init to the first timing report gives '
          '${severity?.name ?? 'no issue'}', (tester) async {
        Sleuth.init();
        now = now.add(Duration(microseconds: (ms * 1000).round()));
        reportFirstFrame(tester);
        expect(Sleuth.startupMetrics!.ttffMs, ms);

        final detector = await scan(tester);
        expect(detector.evaluated, isTrue);
        if (severity == null) {
          expect(detector.issues, isEmpty);
        } else {
          final issue = detector.issues.single;
          expect(issue.severity, severity);
          expect(
            issue.extraTraceArgs?['observedTtffMs'],
            ms.toStringAsFixed(1),
          );
        }
      });
    }

    testWidgets('a second timing report leaves the measurement alone', (
      tester,
    ) async {
      Sleuth.init();
      now = now.add(const Duration(milliseconds: 1600));
      reportFirstFrame(tester);
      now = now.add(const Duration(milliseconds: 900));
      reportFirstFrame(tester);
      expect(Sleuth.startupMetrics!.ttffMs, 1600.0);
    });

    testWidgets('a clock that moves backward gives no time and no issue', (
      tester,
    ) async {
      Sleuth.init();
      now = now.subtract(const Duration(seconds: 1));
      reportFirstFrame(tester);
      expect(Sleuth.startupMetrics!.ttffMs, isNull);

      final detector = await scan(tester);
      expect(detector.evaluated, isTrue);
      expect(detector.issues, isEmpty);
    });

    testWidgets('a reset removes a timings callback that has not fired', (
      tester,
    ) async {
      Sleuth.init();
      Sleuth.resetStartupForTest();
      reportFirstFrame(tester);
      expect(Sleuth.startupMetrics, isNull);
    });
  });
}
