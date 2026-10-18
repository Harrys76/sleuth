// Hermetic reproducer for [RepaintBoundaryDetector].
//
// Pins two stableIds via real `scanTree(root)` on a `pumpWidget` tree.
//
//   - `missing_repaint_boundary` — fires when an expensive GPU widget
//     (Opacity 0<x<1, ClipPath, BackdropFilter, ShaderMask, CustomPaint,
//     ColorFiltered) has NO `RepaintBoundary` ancestor within
//     `maxAncestorDepth` parent render objects (default 5).
//   - `excessive_repaint_boundary` — fires when a CustomScrollView or
//     BoxScrollView counts more than the hardcoded 20-boundary threshold.
//     Boundaries inside a sliver list or grid whose delegate adds them
//     (the default) are framework-managed and never counted.
//
// To avoid cross-detector noise, fixtures use Opacity (not CustomPaint)
// for the missing-boundary case — CustomPaint emission is owned by
// custom_painter_reproducer_test.dart.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/src/detectors/repaint_boundary_detector.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/framework_painter_fixture.dart';
import '../helpers/measurement_matchers.dart';
import '_helpers/structural_reproducer_harness.dart';

/// User painter sharing the TabBar indicator painter's class name.
class _IndicatorPainter extends CustomPainter {
  const _IndicatorPainter();
  @override
  void paint(Canvas canvas, Size size) {}
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

void main() {
  group('RepaintBoundaryDetector reproducer', () {
    // --- missing_repaint_boundary --------------------------------------

    testWidgets(
      'missing_repaint_boundary: Opacity(0.5) without ancestor fires',
      (tester) async {
        final detector = RepaintBoundaryDetector();
        final issues = await scanAndIssues(
          tester,
          detector,
          const Opacity(opacity: 0.5, child: SizedBox(height: 10, width: 10)),
        );
        expect(issues, hasStableId('missing_repaint_boundary'));
        // One unprotected widget against a line of 1; critical is more
        // than 3.
        final issue = issues.firstWhere(
          (i) => i.stableId == 'missing_repaint_boundary',
        );
        expect(issue.severity, IssueSeverity.warning);
        expectMeasurement(
          issue,
          value: 1,
          unit: MeasurementUnit.count,
          warningAt: 1,
          criticalAt: 3,
          criticalStrict: true,
        );
      },
    );

    testWidgets('missing_repaint_boundary: four unprotected Opacity widgets '
        'are critical and measured at 4', (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        Column(
          children: [
            for (var i = 0; i < 4; i++)
              Opacity(
                key: ValueKey(i),
                opacity: 0.5,
                child: const SizedBox(height: 10, width: 10),
              ),
          ],
        ),
      );
      final issue = issues.firstWhere(
        (i) => i.stableId == 'missing_repaint_boundary',
      );
      expect(issue.severity, IssueSeverity.critical);
      expectMeasurement(
        issue,
        value: 4,
        unit: MeasurementUnit.count,
        warningAt: 1,
        criticalAt: 3,
        criticalStrict: true,
      );
      expectSeverityMatchesMeasurement(issue, criticalStrict: true);
    });

    testWidgets('missing_repaint_boundary: Opacity(0.5) WITH RepaintBoundary '
        'ancestor silent', (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const RepaintBoundary(
          child: Opacity(opacity: 0.5, child: SizedBox(height: 10, width: 10)),
        ),
      );
      expect(issues, lacksStableId('missing_repaint_boundary'));
    });

    testWidgets('missing_repaint_boundary: Opacity(1.0) silent '
        '(passthrough — no saveLayer)', (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const Opacity(opacity: 1.0, child: SizedBox(height: 10, width: 10)),
      );
      expect(issues, lacksStableId('missing_repaint_boundary'));
    });

    testWidgets('missing_repaint_boundary: Opacity(0.0) silent '
        '(no paint — saveLayer skipped)', (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const Opacity(opacity: 0.0, child: SizedBox(height: 10, width: 10)),
      );
      expect(issues, lacksStableId('missing_repaint_boundary'));
    });

    testWidgets('missing_repaint_boundary: ClipPath without ancestor fires', (
      tester,
    ) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const ClipPath(child: SizedBox(height: 10, width: 10)),
      );
      expect(issues, hasStableId('missing_repaint_boundary'));
    });

    testWidgets('missing_repaint_boundary: real Material and Cupertino '
        'widgets silent (framework-owned painters, Material clip)', (
      tester,
    ) async {
      final detector = RepaintBoundaryDetector();
      await scanAndIssues(tester, detector, materialPainterPage());
      await driveMaterialPainterPage(tester);
      expect(
        rescanIssues(tester, detector),
        lacksStableId('missing_repaint_boundary'),
      );
    });

    testWidgets('missing_repaint_boundary: user painter named '
        '_IndicatorPainter outside a TabBar fires', (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const CustomPaint(painter: _IndicatorPainter(), size: Size(10, 10)),
      );
      expect(issues, hasStableId('missing_repaint_boundary'));
    });

    // --- excessive_repaint_boundary ------------------------------------

    testWidgets('excessive_repaint_boundary: 21 RepaintBoundaries in '
        'CustomScrollView fires (> 20-boundary threshold)', (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        SizedBox(
          height: 800,
          child: CustomScrollView(
            slivers: [
              SliverList(
                delegate: SliverChildListDelegate(
                  List.generate(
                    21,
                    (i) => RepaintBoundary(
                      key: ValueKey(i),
                      child: const SizedBox(height: 10),
                    ),
                  ),
                  // Disable framework auto-wrap so our 21 boundaries are
                  // the only ones counted.
                  addRepaintBoundaries: false,
                ),
              ),
            ],
          ),
        ),
      );
      expect(issues, hasStableId('excessive_repaint_boundary'));
      // The measured count is the one the title reports: the 21 boundaries
      // plus any the scroll view adds. It is checked against the
      // detector's private 20-boundary line; there is no critical line.
      final excessive = issues.firstWhere(
        (i) => i.stableId == 'excessive_repaint_boundary',
      );
      final titleCount = int.parse(
        RegExp(r'(\d+) in scrollable').firstMatch(excessive.title)!.group(1)!,
      );
      expect(titleCount, greaterThanOrEqualTo(21));
      expectMeasurement(
        excessive,
        value: titleCount.toDouble(),
        unit: MeasurementUnit.count,
        warningAt: 20,
        strict: true,
      );
    });

    testWidgets('excessive_repaint_boundary: 5 RepaintBoundaries silent '
        '(well below 20-threshold)', (tester) async {
      // Pinning exactly at the 20-boundary strict-greater edge is out of
      // reach: the CustomScrollView/Sliver pipeline injects extra
      // RepaintBoundary nodes the detector counter observes, regardless
      // of `addRepaintBoundaries: false` on the delegate (that flag only
      // suppresses per-child KeyedSubtree wrappers). Use `5` — comfortably
      // below threshold across Flutter SDK versions.
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        SizedBox(
          height: 800,
          child: CustomScrollView(
            slivers: [
              SliverList(
                delegate: SliverChildListDelegate(
                  List.generate(
                    5,
                    (i) => RepaintBoundary(
                      key: ValueKey(i),
                      child: const SizedBox(height: 10),
                    ),
                  ),
                  addRepaintBoundaries: false,
                ),
              ),
            ],
          ),
        ),
      );
      expect(issues, lacksStableId('excessive_repaint_boundary'));
    });

    testWidgets('excessive_repaint_boundary: ListView with default '
        '`addRepaintBoundaries:true` silent (framework-managed)', (
      tester,
    ) async {
      // ListView's default delegate adds RepaintBoundary per child. Those
      // are framework-managed: its SliverList pushes a -1 frame so they are
      // not counted. Even with 30 children, no excessive_repaint fires.
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        SizedBox(
          height: 800,
          child: ListView(
            children: List.generate(
              30,
              (i) => SizedBox(key: ValueKey(i), height: 10),
            ),
          ),
        ),
      );
      expect(issues, lacksStableId('excessive_repaint_boundary'));
    });

    testWidgets('excessive_repaint_boundary: CustomScrollView with a default '
        'SliverList of 30 children silent (framework-managed)', (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        SizedBox(
          height: 800,
          child: CustomScrollView(
            slivers: [
              SliverList(
                delegate: SliverChildListDelegate(
                  List.generate(
                    30,
                    (i) => SizedBox(key: ValueKey(i), height: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      expect(issues, lacksStableId('excessive_repaint_boundary'));
    });
  });
}
