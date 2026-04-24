// Hermetic reproducer for [RepaintBoundaryDetector].
//
// Pins two stableIds via real `scanTree(root)` on a `pumpWidget` tree.
//
//   - `missing_repaint_boundary` — fires when an expensive GPU widget
//     (Opacity 0<x<1, ClipPath, BackdropFilter, ShaderMask, CustomPaint,
//     ColorFiltered) has NO `RepaintBoundary` ancestor within
//     `maxAncestorDepth` parent render objects (default 5).
//   - `excessive_repaint_boundary` — fires when a CustomScrollView (or
//     a BoxScrollView with `addRepaintBoundaries: false`) contains
//     more than the hardcoded 20-boundary threshold.
//
// To avoid cross-detector noise, fixtures use Opacity (not CustomPaint)
// for the missing-boundary case — CustomPaint emission is owned by
// custom_painter_reproducer_test.dart.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/src/detectors/repaint_boundary_detector.dart';

import '_helpers/structural_reproducer_harness.dart';

void main() {
  group('RepaintBoundaryDetector reproducer', () {
    // --- missing_repaint_boundary --------------------------------------

    testWidgets('missing_repaint_boundary: Opacity(0.5) without ancestor fires',
        (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const Opacity(opacity: 0.5, child: SizedBox(height: 10, width: 10)),
      );
      expect(issues, hasStableId('missing_repaint_boundary'));
    });

    testWidgets(
        'missing_repaint_boundary: Opacity(0.5) WITH RepaintBoundary '
        'ancestor silent', (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const RepaintBoundary(
          child: Opacity(
            opacity: 0.5,
            child: SizedBox(height: 10, width: 10),
          ),
        ),
      );
      expect(issues, lacksStableId('missing_repaint_boundary'));
    });

    testWidgets(
        'missing_repaint_boundary: Opacity(1.0) silent '
        '(passthrough — no saveLayer)', (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const Opacity(opacity: 1.0, child: SizedBox(height: 10, width: 10)),
      );
      expect(issues, lacksStableId('missing_repaint_boundary'));
    });

    testWidgets(
        'missing_repaint_boundary: Opacity(0.0) silent '
        '(no paint — saveLayer skipped)', (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const Opacity(opacity: 0.0, child: SizedBox(height: 10, width: 10)),
      );
      expect(issues, lacksStableId('missing_repaint_boundary'));
    });

    testWidgets('missing_repaint_boundary: ClipPath without ancestor fires',
        (tester) async {
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const ClipPath(child: SizedBox(height: 10, width: 10)),
      );
      expect(issues, hasStableId('missing_repaint_boundary'));
    });

    // --- excessive_repaint_boundary ------------------------------------

    testWidgets(
        'excessive_repaint_boundary: 21 RepaintBoundaries in '
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
    });

    testWidgets(
        'excessive_repaint_boundary: 5 RepaintBoundaries silent '
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

    testWidgets(
        'excessive_repaint_boundary: ListView with default '
        '`addRepaintBoundaries:true` silent (framework-managed)',
        (tester) async {
      // ListView's default delegate adds RepaintBoundary per child. Those
      // are framework-managed and the detector pushes -1 sentinel to
      // skip counting. Even with 30 children, no excessive_repaint fires.
      final detector = RepaintBoundaryDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        SizedBox(
          height: 800,
          child: ListView(
            children: List.generate(
                30, (i) => SizedBox(key: ValueKey(i), height: 10)),
          ),
        ),
      );
      expect(issues, lacksStableId('excessive_repaint_boundary'));
    });
  });
}
