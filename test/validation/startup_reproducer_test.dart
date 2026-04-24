// Hermetic reproducer for [StartupDetector].
//
// Pins `slow_startup_ttff` via `prepareScan` (the detector's one-shot
// path — element methods are no-ops because startup timing is
// FrameTiming/wall-clock-based, not tree-structural).
//
// Injects [StartupMetrics] through the `@visibleForTesting` hooks on
// [Sleuth] (`setStartupMetricsForTest` / `resetStartupForTest`) so the
// detector reads deterministic values without booting the real
// `Sleuth.init` pipeline. Each test uses a fresh detector instance to
// keep the `_consumed` one-shot guard isolated.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/sleuth.dart';
import 'package:sleuth/src/detectors/startup_detector.dart';

Future<void> _pumpEmpty(WidgetTester tester) => tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(),
      ),
    );

BuildContext _root(WidgetTester tester) =>
    tester.element(find.byType(Directionality));

void main() {
  tearDown(Sleuth.resetStartupForTest);

  group('StartupDetector reproducer', () {
    // --- slow_startup_ttff ---------------------------------------------

    testWidgets(
        'slow_startup_ttff: ttffMs above warning threshold fires '
        '(confirmed confidence)', (tester) async {
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.utc(2026),
        ttffMs: 2000, // > 1500 warning, < 3000 critical → warning
      ));
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      expect(
        detector.issues.any((i) => i.stableId == 'slow_startup_ttff'),
        isTrue,
      );
      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'slow_startup_ttff');
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.confidence, IssueConfidence.confirmed);
    });

    testWidgets(
        'slow_startup_ttff: ttffMs >= critical threshold emits critical',
        (tester) async {
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.utc(2026),
        ttffMs: 3500, // >= 3000 critical
      ));
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'slow_startup_ttff');
      expect(issue.severity, IssueSeverity.critical);
    });

    testWidgets(
        'slow_startup_ttff: ttffMs below warning threshold silent '
        '(strict-less: `ttff < ttffWarningMs` early-returns)', (tester) async {
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.utc(2026),
        ttffMs: 1499, // just under warning (1500)
      ));
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      expect(detector.issues, isEmpty);
    });

    testWidgets('slow_startup_ttff: ttffMs null → silent', (tester) async {
      // Models the "`Sleuth.init` not called before `runApp`" case — the
      // detector's `_checkTtff` early-returns on null ttffMs.
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.utc(2026),
        ttffMs: null,
      ));
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      expect(detector.issues, isEmpty);
    });

    testWidgets('slow_startup_ttff: no StartupMetrics at all → silent',
        (tester) async {
      // `Sleuth.startupMetrics == null` path — prepareScan short-circuits
      // before touching _consumed.
      Sleuth.resetStartupForTest();
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      expect(detector.issues, isEmpty);
    });

    testWidgets(
        'slow_startup_ttff: second prepareScan is a no-op '
        '(one-shot `_consumed` guard)', (tester) async {
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.utc(2026),
        ttffMs: 2000,
      ));
      final detector = StartupDetector();
      await _pumpEmpty(tester);
      detector.prepareScan(_root(tester));
      expect(detector.issues.length, 1);

      // Mutate metrics to something that WOULD emit a different outcome
      // if the detector re-evaluated — one-shot must ignore.
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.utc(2026),
        ttffMs: 100,
      ));
      detector.prepareScan(_root(tester));
      expect(detector.issues.length, 1,
          reason: 'Second prepareScan must be a no-op.');
    });
  });
}
