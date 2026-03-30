import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/debug/debug_snapshot.dart';
import 'package:widget_watchdog/src/detectors/repaint_boundary_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

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
      // Boundary is 4 parent hops up from RenderCustomPaint, beyond
      // maxAncestorDepth=3:
      // RenderRepaintBoundary > RenderConstrainedBox > RenderConstrainedBox
      //   > RenderConstrainedBox > RenderCustomPaint
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
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
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('1 expensive'));
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
  });
}

class _StubPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
