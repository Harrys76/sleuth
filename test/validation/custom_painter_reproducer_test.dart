// Hermetic reproducer for [CustomPainterDetector].
//
// Pins two stableIds via a real widget-tree scan:
//   - `always_repaint_painter` — CustomPaint with a painter whose
//     `shouldRepaint(painter)` self-comparison returns true.
//   - `frequent_repaint_painter` — no `always_repaint_painter` AND
//     `DebugSnapshot.paintsPerSecondForType('CustomPaint') > 30`.
//
// `DebugSnapshot` is constructed inline — no mocking of debug callbacks.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/sleuth.dart' show IssueConfidence, ObservationSource;
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/custom_painter_detector.dart';

import '_helpers/structural_reproducer_harness.dart';

/// Always-repaint painter: self-comparison returns true. Reproduces the
/// trivial "does nothing" shouldRepaint bug.
class _AlwaysRepaintPainter extends CustomPainter {
  const _AlwaysRepaintPainter();
  @override
  void paint(Canvas canvas, Size size) {}
  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

/// Correct painter: self-comparison returns false. Negative control.
class _WellBehavedPainter extends CustomPainter {
  const _WellBehavedPainter();
  @override
  void paint(Canvas canvas, Size size) {}
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

void main() {
  group('CustomPainterDetector reproducer', () {
    // --- always_repaint_painter ----------------------------------------

    testWidgets('always_repaint_painter: shouldRepaint=true fires',
        (tester) async {
      final detector = CustomPainterDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(
          painter: _AlwaysRepaintPainter(),
          size: Size(10, 10),
        ),
      );
      expect(issues, hasStableId('always_repaint_painter'));
    });

    testWidgets('always_repaint_painter: shouldRepaint=false silent',
        (tester) async {
      final detector = CustomPainterDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(
          painter: _WellBehavedPainter(),
          size: Size(10, 10),
        ),
      );
      expect(issues, lacksStableId('always_repaint_painter'));
    });

    testWidgets('always_repaint_painter: null painter silent', (tester) async {
      final detector = CustomPainterDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(size: Size(10, 10)),
      );
      expect(issues, lacksStableId('always_repaint_painter'));
    });

    testWidgets('always_repaint_painter: foregroundPainter slot also exercised',
        (tester) async {
      final detector = CustomPainterDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(
          foregroundPainter: _AlwaysRepaintPainter(),
          size: Size(10, 10),
        ),
      );
      expect(issues, hasStableId('always_repaint_painter'));
    });

    // --- frequent_repaint_painter --------------------------------------

    testWidgets(
        'frequent_repaint_painter: well-behaved painter + high paint rate fires',
        (tester) async {
      final detector = CustomPainterDetector();
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 60,
        elapsed: Duration(seconds: 1),
        paintCounts: {'CustomPaint': 60}, // 60 paints/sec > 30 threshold
      ));
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(
          painter: _WellBehavedPainter(),
          size: Size(10, 10),
        ),
      );
      expect(issues, hasStableId('frequent_repaint_painter'));
    });

    testWidgets(
        'frequent_repaint_painter: paint rate at threshold (30) silent '
        '(strict-greater: `> 30`)', (tester) async {
      final detector = CustomPainterDetector();
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 30,
        elapsed: Duration(seconds: 1),
        paintCounts: {'CustomPaint': 30},
      ));
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(
          painter: _WellBehavedPainter(),
          size: Size(10, 10),
        ),
      );
      expect(issues, lacksStableId('frequent_repaint_painter'));
    });

    testWidgets(
        'frequent_repaint_painter: high paint rate + always-repaint fires '
        "first → frequent suppressed (emits always_repaint only)",
        (tester) async {
      final detector = CustomPainterDetector();
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 100,
        elapsed: Duration(seconds: 1),
        paintCounts: {'CustomPaint': 100},
      ));
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(
          painter: _AlwaysRepaintPainter(),
          size: Size(10, 10),
        ),
      );
      expect(issues, hasStableId('always_repaint_painter'));
      expect(issues, lacksStableId('frequent_repaint_painter'),
          reason: 'frequent_repaint_painter fires only when _found is empty.');
      // paintCounts=100 crosses > 10 but the frequent branch is suppressed
      // by a non-empty `_found`, so confidence lands at `likely`, not
      // `confirmed`. The exact > 10 boundary is pinned by the 10/11 pair
      // below.
      final issue =
          issues.firstWhere((i) => i.stableId == 'always_repaint_painter');
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.observationSource,
          ObservationSource.debugCallbackAndStructural);
    });

    testWidgets(
        'always_repaint_painter: paintCounts=10 at-threshold stays possible '
        '(strict-greater `> 10` boundary pin)', (tester) async {
      // `custom_painter_detector.dart:108` uses `cpRate > 10`. At
      // paintCounts=10 with elapsed=1s, cpRate=10.0 → check fails →
      // confidence stays at `possible`, observationSource null.
      final detector = CustomPainterDetector();
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 10,
        elapsed: Duration(seconds: 1),
        paintCounts: {'CustomPaint': 10},
      ));
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(
          painter: _AlwaysRepaintPainter(),
          size: Size(10, 10),
        ),
      );
      final issue =
          issues.firstWhere((i) => i.stableId == 'always_repaint_painter');
      expect(issue.confidence, IssueConfidence.possible,
          reason: 'cpRate == 10 fails the strict-greater `> 10` check; '
              'confidence must stay at possible, not upgrade to likely.');
      expect(issue.observationSource, isNull,
          reason: 'No upgrade path taken → observationSource stays null.');
    });

    testWidgets(
        'always_repaint_painter: paintCounts=11 just above threshold upgrades '
        'to likely (strict-greater `> 10` boundary pin)', (tester) async {
      // paintCounts=11 → cpRate=11.0 > 10 → confidence upgrades to
      // `likely`. 11 is the smallest integer strictly above 10; pairs
      // with the paintCounts=10 silent test above to pin the boundary.
      final detector = CustomPainterDetector();
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 11,
        elapsed: Duration(seconds: 1),
        paintCounts: {'CustomPaint': 11},
      ));
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(
          painter: _AlwaysRepaintPainter(),
          size: Size(10, 10),
        ),
      );
      final issue =
          issues.firstWhere((i) => i.stableId == 'always_repaint_painter');
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.observationSource,
          ObservationSource.debugCallbackAndStructural);
    });

    testWidgets('frequent_repaint_painter: no DebugSnapshot → silent',
        (tester) async {
      final detector = CustomPainterDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(
          painter: _WellBehavedPainter(),
          size: Size(10, 10),
        ),
      );
      expect(issues, lacksStableId('frequent_repaint_painter'));
    });
  });
}
