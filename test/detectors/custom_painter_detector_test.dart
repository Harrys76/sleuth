import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/custom_painter_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/decoded_image_helpers.dart';
import '../helpers/framework_painter_fixture.dart';

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

    testWidgets('flags CustomPaint with always-true shouldRepaint', (
      tester,
    ) async {
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
          child: CustomPaint(child: SizedBox(width: 10, height: 10)),
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

    testWidgets('highlights produced per always-repaint painter', (
      tester,
    ) async {
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
      testWidgets('upgrades to likely when CustomPaint paint rate is high', (
        tester,
      ) async {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 50,
            paintCounts: {'CustomPaint': 20},
            paintOrigins: {'CustomPaint': PaintOriginStats(maxCount: 20)},
            elapsed: Duration(seconds: 1),
          ),
        );

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
        expect(
          detector.issues.first.observationSource,
          ObservationSource.debugCallbackAndStructural,
        );
      });

      testWidgets('remains possible when paint rate is low', (tester) async {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 10,
            paintCounts: {'CustomPaint': 5},
            paintOrigins: {'CustomPaint': PaintOriginStats(maxCount: 5)},
            elapsed: Duration(seconds: 1),
          ),
        );

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
          detector.updateDebugSnapshot(
            const DebugSnapshot(
              rebuildCounts: {},
              totalPaintCount: 50,
              paintCounts: {'CustomPaint': 50},
              paintOrigins: {'CustomPaint': PaintOriginStats(maxCount: 50)},
              elapsed: Duration(seconds: 1),
            ),
          );

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
          expect(
            detector.issues.first.detail,
            contains('likely origin of 50 repaints/sec'),
          );
        },
      );

      testWidgets('a CustomPaint that only shares a repainting layer is not '
          'blamed', (tester) async {
        // It painted 60 times because a neighbour repainted the layer,
        // but it was never where a repaint started.
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 180,
            paintCounts: {'CustomPaint': 60, 'Text': 60},
            paintOrigins: {'Text': PaintOriginStats(maxCount: 60)},
            elapsed: Duration(seconds: 1),
          ),
        );

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

      testWidgets(
        'no duplicate issue when always-repaint painter has high paint rate',
        (tester) async {
          detector.updateDebugSnapshot(
            const DebugSnapshot(
              rebuildCounts: {},
              totalPaintCount: 50,
              paintCounts: {'CustomPaint': 50},
              paintOrigins: {'CustomPaint': PaintOriginStats(maxCount: 50)},
              elapsed: Duration(seconds: 1),
            ),
          );

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
        },
      );

      testWidgets('remains possible when paintCounts empty', (tester) async {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 50,
            elapsed: Duration(seconds: 1),
          ),
        );

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

    group('animation-owned paints are excluded from the rate', () {
      DebugSnapshot snapshot({required int raw, required int owned}) =>
          DebugSnapshot(
            rebuildCounts: const {},
            totalPaintCount: raw,
            paintCounts: {'CustomPaint': raw},
            animationOwnedPaintCounts: {'CustomPaint': owned},
            totalAnimationOwnedPaintCount: owned,
            paintOrigins: {
              if (raw > owned)
                'CustomPaint': PaintOriginStats(
                  maxCount: raw - owned,
                  animationOwnedCount: owned,
                ),
            },
            elapsed: const Duration(seconds: 1),
          );

      Future<void> pumpPainter(WidgetTester tester, CustomPainter p) =>
          tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: CustomPaint(
                painter: p,
                child: const SizedBox(width: 10, height: 10),
              ),
            ),
          );

      testWidgets('raw 40/sec with 35 owned stays silent (residual 5)', (
        tester,
      ) async {
        detector.updateDebugSnapshot(snapshot(raw: 40, owned: 35));
        await pumpPainter(tester, _NeverRepaintPainter());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isEmpty);
      });

      testWidgets('raw 40/sec with 0 owned fires frequent_repaint_painter', (
        tester,
      ) async {
        detector.updateDebugSnapshot(snapshot(raw: 40, owned: 0));
        await pumpPainter(tester, _NeverRepaintPainter());
        detector.scanTree(tester.element(find.byType(Directionality)));

        final issue = detector.issues.single;
        expect(issue.stableId, 'frequent_repaint_painter');
        expect(issue.title, contains('40/sec'));
      });

      testWidgets('raw 40/sec with 35 owned does not upgrade '
          'always_repaint_painter to likely', (tester) async {
        detector.updateDebugSnapshot(snapshot(raw: 40, owned: 35));
        await pumpPainter(tester, _AlwaysRepaintPainter());
        detector.scanTree(tester.element(find.byType(Directionality)));

        final issue = detector.issues.single;
        expect(issue.stableId, 'always_repaint_painter');
        expect(issue.confidence, IssueConfidence.possible);
      });

      testWidgets('raw 40/sec with 0 owned upgrades always_repaint_painter '
          'to likely', (tester) async {
        detector.updateDebugSnapshot(snapshot(raw: 40, owned: 0));
        await pumpPainter(tester, _AlwaysRepaintPainter());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues.single.confidence, IssueConfidence.likely);
      });
    });

    group('foregroundPainter support', () {
      testWidgets('detects always-repaint foregroundPainter', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              foregroundPainter: _AlwaysRepaintPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.highlights, hasLength(1));
      });

      testWidgets('detects both painter and foregroundPainter', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              painter: _AlwaysRepaintPainter(),
              foregroundPainter: _AlwaysRepaintPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('2 found'));
        expect(detector.highlights, hasLength(2));
      });

      testWidgets('ignores good foregroundPainter', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: CustomPaint(
              foregroundPainter: _NeverRepaintPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isEmpty);
        expect(detector.highlights, isEmpty);
      });
    });

    group('framework toggle and scrollbar painters', () {
      const hotSnapshot = DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 40,
        paintCounts: {'CustomPaint': 40},
        paintOrigins: {'CustomPaint': PaintOriginStats(maxCount: 40)},
        elapsed: Duration(seconds: 1),
      );

      testWidgets('Checkbox, Switch, Radio, CupertinoSwitch, Scrollbar emit '
          'no painter issue even at a high CustomPaint rate', (tester) async {
        detector.updateDebugSnapshot(hotSnapshot);
        await tester.pumpWidget(frameworkPainterPage());

        final painters = countFrameworkPainters();
        expect(painters.toggleable, greaterThanOrEqualTo(4));
        expect(painters.scrollbar, greaterThanOrEqualTo(1));

        detector.scanTree(tester.element(find.byType(MaterialApp)));

        final ids = detector.issues.map((i) => i.stableId);
        expect(ids, isNot(contains('always_repaint_painter')));
        expect(ids, isNot(contains('frequent_repaint_painter')));
      });

      testWidgets('user always-repaint painter beside them still fires', (
        tester,
      ) async {
        await tester.pumpWidget(
          frameworkPainterPage(
            extra: CustomPaint(
              painter: _AlwaysRepaintPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(MaterialApp)));

        final issue = detector.issues.singleWhere(
          (i) => i.stableId == 'always_repaint_painter',
        );
        expect(issue.title, contains('1 found'));
      });

      testWidgets('user painter beside them gets the frequent-repaint '
          'heuristic', (tester) async {
        detector.updateDebugSnapshot(hotSnapshot);
        await tester.pumpWidget(
          frameworkPainterPage(
            extra: CustomPaint(
              painter: _NeverRepaintPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(MaterialApp)));

        expect(
          detector.issues.map((i) => i.stableId),
          contains('frequent_repaint_painter'),
        );
      });
    });

    group('framework-owned painters on real widgets', () {
      const hotSnapshot = DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 40,
        paintCounts: {'CustomPaint': 40},
        paintOrigins: {'CustomPaint': PaintOriginStats(maxCount: 40)},
        elapsed: Duration(seconds: 1),
      );

      testWidgets('Material and Cupertino widgets emit no painter issue even '
          'at a high CustomPaint rate', (tester) async {
        detector.updateDebugSnapshot(hotSnapshot);
        await tester.pumpWidget(materialPainterPage());
        await driveMaterialPainterPage(tester);

        detector.scanTree(tester.element(find.byType(MaterialApp)));

        final ids = detector.issues.map((i) => i.stableId);
        expect(ids, isNot(contains('always_repaint_painter')));
        expect(ids, isNot(contains('frequent_repaint_painter')));
      });

      testWidgets('open DropdownButton menu emits no painter issue', (
        tester,
      ) async {
        detector.updateDebugSnapshot(hotSnapshot);
        await tester.pumpWidget(materialPainterPage());
        await driveMaterialPainterPage(tester, openDropdown: true);

        detector.scanTree(tester.element(find.byType(MaterialApp)));

        expect(detector.issues, isEmpty);
      });

      testWidgets('TabBar image indicator that just loaded '
          '(shouldRepaint(self) true) is not always_repaint_painter', (
        tester,
      ) async {
        final bytes = await pngBytes(tester, width: 8, height: 8);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: DefaultTabController(
              length: 2,
              child: Scaffold(
                body: TabBar(
                  indicator: BoxDecoration(
                    image: DecorationImage(image: MemoryImage(bytes)),
                  ),
                  tabs: const [
                    Tab(text: 'A'),
                    Tab(text: 'B'),
                  ],
                ),
              ),
            ),
          ),
        );
        // The decode finishes outside fake async; the indicator painter
        // then needs paint until the next frame.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        expect(paintersByName()['_IndicatorPainter']?.repaintsSelf, isTrue);

        detector.scanTree(tester.element(find.byType(MaterialApp)));

        expect(detector.issues, isEmpty);
      });

      testWidgets('user painter named like a framework painter, outside its '
          'owner, still emits always_repaint_painter', (tester) async {
        await tester.pumpWidget(
          materialPainterPage(
            extra: Container(
              padding: const EdgeInsets.all(1),
              child: CustomPaint(
                painter: _IndicatorPainter(),
                child: const SizedBox(width: 10, height: 10),
              ),
            ),
          ),
        );
        await driveMaterialPainterPage(tester);
        detector.scanTree(tester.element(find.byType(MaterialApp)));

        final issue = detector.issues.singleWhere(
          (i) => i.stableId == 'always_repaint_painter',
        );
        expect(issue.title, contains('1 found'));
      });

      testWidgets('frequent_repaint_painter gate stays closed with only '
          'framework paints, and opens for a same-named user painter', (
        tester,
      ) async {
        detector.updateDebugSnapshot(hotSnapshot);
        await tester.pumpWidget(materialPainterPage());
        await driveMaterialPainterPage(tester);
        detector.scanTree(tester.element(find.byType(MaterialApp)));
        expect(detector.issues, isEmpty);

        await tester.pumpWidget(
          materialPainterPage(
            extra: CustomPaint(
              painter: _ShapeBorderPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(MaterialApp)));
        expect(
          detector.issues.map((i) => i.stableId),
          contains('frequent_repaint_painter'),
        );
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

/// User painter sharing the TabBar indicator painter's class name; always
/// returns true from shouldRepaint(self).
class _IndicatorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// User painter sharing Material's shape-border painter's class name.
class _ShapeBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
