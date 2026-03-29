import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/debug/debug_snapshot.dart';
import 'package:widget_watchdog/src/detectors/custom_painter_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

void main() {
  group('CustomPainterDetector', () {
    late CustomPainterDetector detector;

    setUp(() {
      detector = CustomPainterDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: _AlwaysRepaintPainter(),
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    testWidgets('flags CustomPaint with always-true shouldRepaint',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: _AlwaysRepaintPainter(),
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('1 found'));
    });

    testWidgets('no issue for shouldRepaint returning false', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: _NeverRepaintPainter(),
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('no issue for CustomPaint without painter', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('counts multiple always-repaint painters', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              CustomPaint(
                painter: _AlwaysRepaintPainter(),
                child: const SizedBox(width: 10, height: 10),
              ),
              CustomPaint(
                painter: _AlwaysRepaintPainter(),
                child: const SizedBox(width: 10, height: 10),
              ),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('2 found'));
    });

    testWidgets('highlights produced per always-repaint painter',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              CustomPaint(
                painter: _AlwaysRepaintPainter(),
                child: const SizedBox(width: 10, height: 10),
              ),
              CustomPaint(
                painter: _AlwaysRepaintPainter(),
                child: const SizedBox(width: 10, height: 10),
              ),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, hasLength(2));
      expect(detector.highlights.first.detectorName, 'Painter');
    });

    testWidgets('stableId, confidence, and category', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: _AlwaysRepaintPainter(),
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.first;
      expect(issue.stableId, 'always_repaint_painter');
      expect(issue.confidence, IssueConfidence.possible);
      expect(issue.category, IssueCategory.paint);
      expect(issue.severity, IssueSeverity.warning);
    });

    testWidgets('no highlights when no issues', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: _NeverRepaintPainter(),
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isEmpty);
    });

    testWidgets('dispose clears issues and highlights', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            painter: _AlwaysRepaintPainter(),
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
    });

    group('debug paint confirmation', () {
      testWidgets('upgrades to likely when CustomPaint paint rate is high',
          (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          paintCounts: {'CustomPaint': 20},
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              painter: _AlwaysRepaintPainter(),
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

      testWidgets('remains possible when paint rate is low', (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 10,
          paintCounts: {'CustomPaint': 5},
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              painter: _AlwaysRepaintPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.confidence, IssueConfidence.possible);
        expect(detector.issues.first.observationSource, isNull);
      });

      testWidgets(
          'flags frequent repainting when shouldRepaint returns false for self',
          (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          paintCounts: {'CustomPaint': 50},
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              painter: _NeverRepaintPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'frequent_repaint_painter');
        expect(detector.issues.first.severity, IssueSeverity.warning);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
        expect(detector.issues.first.title, contains('50/sec'));
      });

      testWidgets(
          'no duplicate issue when always-repaint painter has high paint rate',
          (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          paintCounts: {'CustomPaint': 50},
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              painter: _AlwaysRepaintPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        // Only the always_repaint_painter issue, NOT frequent_repaint_painter
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'always_repaint_painter');
      });

      testWidgets('remains possible when paintCounts empty', (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              painter: _AlwaysRepaintPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.confidence, IssueConfidence.possible);
      });
    });
  });
}

/// Painter that always returns true from shouldRepaint(self).
class _AlwaysRepaintPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Painter that always returns false from shouldRepaint(self).
class _NeverRepaintPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
