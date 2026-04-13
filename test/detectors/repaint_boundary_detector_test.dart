import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/repaint_boundary_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  group('RepaintBoundaryDetector', () {
    late RepaintBoundaryDetector detector;

    setUp(() {
      detector = RepaintBoundaryDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: _StubPainter(),
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    testWidgets('flags CustomPaint without RepaintBoundary ancestor',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: _StubPainter(),
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.stableId, 'missing_repaint_boundary');
      expect(detector.issues.first.category, IssueCategory.paint);
      expect(detector.issues.first.confidence, IssueConfidence.possible);
      expect(detector.issues.first.title, contains('1 expensive widget'));
    });

    testWidgets('no flag when direct RepaintBoundary parent', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _StubPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('no flag when boundary 2 levels up', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            child: SizedBox(
              child: CustomPaint(
                painter: _StubPainter(),
                child: const SizedBox(width: 10, height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('flags when boundary beyond maxAncestorDepth', (tester) async {
      // Boundary is 6 parent hops up from RenderCustomPaint, beyond
      // maxAncestorDepth=5:
      // RenderRepaintBoundary > RenderConstrainedBox × 5 > RenderCustomPaint
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            child: SizedBox(
              child: SizedBox(
                child: SizedBox(
                  child: SizedBox(
                    child: SizedBox(
                      child: CustomPaint(
                        painter: _StubPainter(),
                        child: const SizedBox(width: 10, height: 10),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('1 expensive'));
    });

    testWidgets('skips Opacity when opacity is 1.0', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(
            opacity: 1.0,
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty,
          reason: 'Opacity 1.0 is a passthrough — no saveLayer');
    });

    testWidgets('skips Opacity when opacity is 0.0', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(
            opacity: 0.0,
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty,
          reason: 'Opacity 0.0 short-circuits paint — no saveLayer');
    });

    testWidgets('flags multiple expensive widget types', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Opacity(
                opacity: 0.5,
                child: const SizedBox(width: 10, height: 10),
              ),
              ClipPath(child: const SizedBox(width: 10, height: 10)),
              CustomPaint(
                painter: _StubPainter(),
                child: const SizedBox(width: 10, height: 10),
              ),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('3 expensive'));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    testWidgets('shared boundary covers siblings', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            child: Column(
              children: [
                Opacity(
                  opacity: 0.5,
                  child: const SizedBox(width: 10, height: 10),
                ),
                CustomPaint(
                  painter: _StubPainter(),
                  child: const SizedBox(width: 10, height: 10),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    group('debug paint escalation', () {
      testWidgets('upgrades to likely with moderate paint rate',
          (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 30,
          paintCounts: {'CustomPaint': 15},
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              painter: _StubPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.confidence, IssueConfidence.likely);
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallbackAndStructural);
      });

      testWidgets('upgrades to confirmed with high paint rate', (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          paintCounts: {'Opacity': 35},
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Opacity(
              opacity: 0.5,
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallbackAndStructural);
      });

      testWidgets(
          'hot paint rate on an unrelated expensive type does not '
          'escalate confidence for a cold unprotected widget', (tester) async {
        // A hot Opacity elsewhere (35 paints/sec) must NOT lift the
        // confidence of an unprotected CustomPaint that is itself cold.
        // This is the Finding 4 per-type confidence guarantee: the paint
        // rate lookup is keyed by the types actually in `_found`, not the
        // full `_expensiveTypeNames` universe.
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 35,
          paintCounts: {'Opacity': 35},
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              painter: _StubPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.confidence, IssueConfidence.possible);
      });
    });

    testWidgets('dispose clears issues, highlights, and debug snapshot',
        (tester) async {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 30,
        paintCounts: {'CustomPaint': 15},
        elapsed: Duration(seconds: 1),
      ));

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: _StubPainter(),
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isNotEmpty);
      expect(detector.highlights, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);

      // After dispose, scanning again should not use stale debug data.
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues.first.confidence, IssueConfidence.possible);
    });
    // -----------------------------------------------------------------
    // v11.6: Excessive RepaintBoundary in scrollables
    // -----------------------------------------------------------------

    group('excessive RepaintBoundary', () {
      // Note: addRepaintBoundaries: false on ListViews/GridViews to avoid
      // counting framework-added internal boundaries, testing only explicit ones.

      testWidgets('flags ListView with >20 RepaintBoundary children',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView(
              addRepaintBoundaries: false,
              children: List.generate(
                25,
                (i) => RepaintBoundary(
                  key: ValueKey(i),
                  child: SizedBox(height: 10, width: 10),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final excessiveIssues = detector.issues
            .where((i) => i.stableId == 'excessive_repaint_boundary')
            .toList();
        expect(excessiveIssues, hasLength(1));
        // Count includes 25 explicit + framework-internal boundaries
        expect(excessiveIssues.first.stableId, 'excessive_repaint_boundary');
        expect(excessiveIssues.first.category, IssueCategory.paint);
      });

      testWidgets('no issue for ListView with <=20 RepaintBoundary children',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView(
              addRepaintBoundaries: false,
              children: List.generate(
                5,
                (i) => RepaintBoundary(
                  key: ValueKey(i),
                  child: SizedBox(height: 10, width: 10),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final excessiveIssues = detector.issues
            .where((i) => i.stableId == 'excessive_repaint_boundary')
            .toList();
        expect(excessiveIssues, isEmpty);
      });

      testWidgets('flags GridView with >20 RepaintBoundary children',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: GridView.count(
              addRepaintBoundaries: false,
              crossAxisCount: 5,
              children: List.generate(
                25,
                (i) => RepaintBoundary(
                  key: ValueKey(i),
                  child: SizedBox(height: 10, width: 10),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final excessiveIssues = detector.issues
            .where((i) => i.stableId == 'excessive_repaint_boundary')
            .toList();
        expect(excessiveIssues, hasLength(1));
      });

      testWidgets('nested scrollables tracked independently', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView(
              addRepaintBoundaries: false,
              children: [
                // Outer has only 1 RepaintBoundary — below threshold
                RepaintBoundary(
                  child: SizedBox(
                    height: 200,
                    child: ListView(
                      addRepaintBoundaries: false,
                      children: List.generate(
                        25,
                        (i) => RepaintBoundary(
                          key: ValueKey(i),
                          child: SizedBox(height: 10, width: 10),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final excessiveIssues = detector.issues
            .where((i) => i.stableId == 'excessive_repaint_boundary')
            .toList();
        // Inner ListView has 25 boundaries — flagged.
        // Outer ListView has 1 boundary — not flagged.
        expect(excessiveIssues, hasLength(1));
      });

      testWidgets(
          'framework-added boundaries (addRepaintBoundaries: true) are NOT counted',
          (tester) async {
        // Default ListView adds RepaintBoundary per child automatically.
        // 25 items → 25 framework boundaries. These should NOT trigger
        // the excessive threshold.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ListView.builder(
              itemCount: 25,
              itemBuilder: (_, i) => SizedBox(
                key: ValueKey(i),
                height: 10,
                width: 10,
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final excessiveIssues = detector.issues
            .where((i) => i.stableId == 'excessive_repaint_boundary')
            .toList();
        expect(excessiveIssues, isEmpty,
            reason:
                'Framework-added RepaintBoundaries should not count toward threshold');
      });

      testWidgets('existing missing-boundary tests still pass', (tester) async {
        // Verify no interference: CustomPaint without boundary still detected
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              painter: _StubPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'missing_repaint_boundary');
      });
    });
  });
}

class _StubPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
