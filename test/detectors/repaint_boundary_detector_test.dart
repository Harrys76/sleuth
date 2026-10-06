import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/repaint_boundary_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/utils/framework_painters.dart';

import '../helpers/framework_painter_fixture.dart';
import '../validation/_helpers/structural_reproducer_harness.dart';

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

    testWidgets('flags CustomPaint without RepaintBoundary ancestor', (
      tester,
    ) async {
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
          child: Opacity(opacity: 1.0, child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(
        detector.issues,
        isEmpty,
        reason: 'Opacity 1.0 is a passthrough — no saveLayer',
      );
    });

    testWidgets('skips Opacity when opacity is 0.0', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(opacity: 0.0, child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(
        detector.issues,
        isEmpty,
        reason: 'Opacity 0.0 short-circuits paint — no saveLayer',
      );
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
      testWidgets('upgrades to likely with moderate paint rate', (
        tester,
      ) async {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 30,
            paintCounts: {'CustomPaint': 15},
            elapsed: Duration(seconds: 1),
          ),
        );

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
        expect(
          detector.issues.first.observationSource,
          ObservationSource.debugCallbackAndStructural,
        );
      });

      testWidgets(
        'high type-level paint rate caps at likely, never confirmed',
        (tester) async {
          detector.updateDebugSnapshot(
            const DebugSnapshot(
              rebuildCounts: {},
              totalPaintCount: 50,
              paintCounts: {'Opacity': 35},
              elapsed: Duration(seconds: 1),
            ),
          );

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
          expect(
            detector.issues.first.confidence,
            IssueConfidence.likely,
            reason:
                '35 paints/sec is a type-level rate; it cannot attribute to '
                'the unprotected instance',
          );
          expect(
            detector.issues.first.observationSource,
            ObservationSource.debugCallbackAndStructural,
          );
        },
      );

      testWidgets('hot paint rate on an unrelated expensive type does not '
          'escalate confidence for a cold unprotected widget', (tester) async {
        // A hot Opacity elsewhere (35 paints/sec) must NOT lift the
        // confidence of an unprotected CustomPaint that is itself cold.
        // This is the Finding 4 per-type confidence guarantee: the paint
        // rate lookup is keyed by the types actually in `_found`, not the
        // full `_expensiveTypeNames` universe.
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 35,
            paintCounts: {'Opacity': 35},
            elapsed: Duration(seconds: 1),
          ),
        );

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

    testWidgets('dispose clears issues, highlights, and debug snapshot', (
      tester,
    ) async {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 30,
          paintCounts: {'CustomPaint': 15},
          elapsed: Duration(seconds: 1),
        ),
      );

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

      testWidgets('flags ListView with >20 RepaintBoundary children', (
        tester,
      ) async {
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

      testWidgets('no issue for ListView with <=20 RepaintBoundary children', (
        tester,
      ) async {
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

      testWidgets('flags GridView with >20 RepaintBoundary children', (
        tester,
      ) async {
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
                itemBuilder: (_, i) =>
                    SizedBox(key: ValueKey(i), height: 10, width: 10),
              ),
            ),
          );
          detector.scanTree(tester.element(find.byType(Directionality)));

          final excessiveIssues = detector.issues
              .where((i) => i.stableId == 'excessive_repaint_boundary')
              .toList();
          expect(
            excessiveIssues,
            isEmpty,
            reason:
                'Framework-added RepaintBoundaries should not count toward threshold',
          );
        },
      );

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

    group('sliver boundary frames', () {
      Iterable<PerformanceIssue> excessive(List<PerformanceIssue> issues) =>
          issues.where((i) => i.stableId == 'excessive_repaint_boundary');

      // The default overscroll glow adds two framework boundaries around
      // the viewport; turning it off keeps counts exact.
      Widget noGlow(Widget child) => ScrollConfiguration(
        behavior: const ScrollBehavior().copyWith(overscroll: false),
        child: child,
      );

      List<Widget> userBoundaries(int n) => List.generate(
        n,
        (i) => RepaintBoundary(
          key: ValueKey('rb$i'),
          child: const SizedBox(height: 5, width: 5),
        ),
      );

      testWidgets('CustomScrollView with a default SliverList of 30 children '
          'raises nothing', (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          CustomScrollView(
            slivers: [
              SliverList(
                delegate: SliverChildListDelegate(
                  List.generate(30, (i) => const SizedBox(height: 5)),
                ),
              ),
            ],
          ),
        );
        expect(find.byType(RepaintBoundary), findsAtLeastNWidgets(30));
        expect(excessive(issues), isEmpty);
      });

      testWidgets('SliverList with addRepaintBoundaries: false counts user '
          'boundaries toward the CustomScrollView', (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          noGlow(
            CustomScrollView(
              slivers: [
                SliverList(
                  delegate: SliverChildListDelegate(
                    userBoundaries(30),
                    addRepaintBoundaries: false,
                  ),
                ),
              ],
            ),
          ),
        );
        final issue = excessive(issues).single;
        expect(issue.title, contains(': 30 in scrollable'));
        expect(issue.detail, contains('CustomScrollView'));
      });

      testWidgets('default SliverGrid raises nothing', (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          CustomScrollView(
            slivers: [
              SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 6,
                  mainAxisExtent: 5,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, i) => const SizedBox(),
                  childCount: 30,
                ),
              ),
            ],
          ),
        );
        expect(excessive(issues), isEmpty);
      });

      testWidgets('user boundaries under SliverToBoxAdapter count toward the '
          'CustomScrollView; a nested default ListView pops its own frames', (
        tester,
      ) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          noGlow(
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 100,
                    child: ListView(
                      children: List.generate(
                        30,
                        (i) => const SizedBox(height: 2),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: Column(children: userBoundaries(25))),
              ],
            ),
          ),
        );
        final issue = excessive(issues).single;
        expect(issue.title, contains(': 25 in scrollable'));
        expect(issue.detail, isNot(contains('ListView')));
      });

      testWidgets('unknown SliverChildDelegate subclass is treated as adding '
          'boundaries', (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          CustomScrollView(
            slivers: [
              SliverList(delegate: _ForwardingDelegate(userBoundaries(30))),
            ],
          ),
        );
        expect(excessive(issues), isEmpty);
      });

      testWidgets('custom BoxScrollView subclass does not throw', (
        tester,
      ) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          _PlainBoxScrollView(children: userBoundaries(30)),
        );
        // Its SliverList uses the default delegate, so the 30 user
        // boundaries sit inside the framework-managed frame.
        expect(excessive(issues), isEmpty);
      });
    });

    group('framework toggle and scrollbar painters', () {
      testWidgets('Checkbox, Switch, Radio, CupertinoSwitch, Scrollbar are '
          'not missing_repaint_boundary', (tester) async {
        await tester.pumpWidget(frameworkPainterPage());

        final painters = countFrameworkPainters();
        expect(painters.toggleable, greaterThanOrEqualTo(4));
        expect(painters.scrollbar, greaterThanOrEqualTo(1));

        detector.scanTree(tester.element(find.byType(MaterialApp)));

        expect(
          detector.issues.map((i) => i.stableId),
          isNot(contains('missing_repaint_boundary')),
        );
      });

      testWidgets('user CustomPaint beside them is still flagged', (
        tester,
      ) async {
        await tester.pumpWidget(
          frameworkPainterPage(
            extra: CustomPaint(
              painter: _StubPainter(),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(MaterialApp)));

        final issue = detector.issues.singleWhere(
          (i) => i.stableId == 'missing_repaint_boundary',
        );
        expect(issue.title, contains('1 expensive widget'));
      });
    });

    group('framework-owned painters on real widgets', () {
      // Painters that render with no RepaintBoundary within the detector's
      // 5 render ancestors on the driven page: each is a candidate the
      // owner table must silence.
      const unprotectedOnPage = [
        '_ShapeBorderPainter',
        '_IndicatorPainter',
        '_DividerPainter',
        '_LinearProgressIndicatorPainter',
        '_CircularProgressIndicatorPainter',
        '_RefreshProgressIndicatorPainter',
        '_InputBorderPainter',
        '_CupertinoActivityIndicatorPainter',
        '_AnimatedIconPainter',
        '_PlaceholderPainter',
        '_GridPaperPainter',
      ];

      testWidgets('Material and Cupertino widgets raise no '
          'missing_repaint_boundary', (tester) async {
        await tester.pumpWidget(materialPainterPage());
        await driveMaterialPainterPage(tester);

        final painters = paintersByName();
        for (final name in unprotectedOnPage) {
          expect(
            painters[name]?.unprotected ?? 0,
            greaterThan(0),
            reason: name,
          );
        }
        expect(painters['_GlowingOverscrollIndicatorPainter'], isNotNull);
        expect(materialClipPaths().unprotected, greaterThan(0));

        detector.scanTree(tester.element(find.byType(MaterialApp)));

        expect(
          detector.issues.map((i) => i.stableId),
          isNot(contains('missing_repaint_boundary')),
        );
      });

      testWidgets('open DropdownButton menu raises no '
          'missing_repaint_boundary', (tester) async {
        await tester.pumpWidget(materialPainterPage());
        await driveMaterialPainterPage(tester, openDropdown: true);

        expect(paintersByName()['_DropdownMenuPainter'], isNotNull);

        detector.scanTree(tester.element(find.byType(MaterialApp)));

        expect(
          detector.issues.map((i) => i.stableId),
          isNot(contains('missing_repaint_boundary')),
        );
      });

      testWidgets('every reproducible owner-table painter is on the page', (
        tester,
      ) async {
        final seen = <String>{};
        await tester.pumpWidget(materialPainterPage());
        await driveMaterialPainterPage(tester);
        seen.addAll(paintersByName().keys);
        await driveMaterialPainterPage(tester, openDropdown: true);
        seen.addAll(paintersByName().keys);

        // Stretch needs shader filters, absent from the test engine;
        // CupertinoLinearActivityIndicator is not on every supported SDK.
        final expected = frameworkPainterNames.toSet()
          ..remove('_StretchEffectPainter')
          ..remove('_CupertinoLinearActivityIndicator');
        expect(seen, containsAll(expected));
      });

      testWidgets('user painter named like a framework painter, outside its '
          'owner, is still flagged', (tester) async {
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
          (i) => i.stableId == 'missing_repaint_boundary',
        );
        expect(issue.title, contains('1 expensive widget'));
      });

      testWidgets('user _ShapeBorderPainter inside a Card is still flagged: '
          'its parent is not _ShapeBorderPaint', (tester) async {
        await tester.pumpWidget(
          materialPainterPage(
            extra: Card(
              child: CustomPaint(
                painter: _ShapeBorderPainter(),
                child: const SizedBox(width: 10, height: 10),
              ),
            ),
          ),
        );
        await driveMaterialPainterPage(tester);
        detector.scanTree(tester.element(find.byType(MaterialApp)));

        final issue = detector.issues.singleWhere(
          (i) => i.stableId == 'missing_repaint_boundary',
        );
        expect(issue.title, contains('1 expensive widget'));
      });

      testWidgets('user ClipPath under a Container is still flagged', (
        tester,
      ) async {
        await tester.pumpWidget(
          materialPainterPage(
            extra: Container(
              padding: const EdgeInsets.all(1),
              child: const ClipPath(child: SizedBox(width: 10, height: 10)),
            ),
          ),
        );
        await driveMaterialPainterPage(tester);
        detector.scanTree(tester.element(find.byType(MaterialApp)));

        final issue = detector.issues.singleWhere(
          (i) => i.stableId == 'missing_repaint_boundary',
        );
        expect(issue.title, contains('1 expensive widget'));
      });

      testWidgets('user ClipPath as the child of a transparency Material is '
          'still flagged: Material builds its own clip above it', (
        tester,
      ) async {
        await tester.pumpWidget(
          materialPainterPage(
            extra: const Material(
              type: MaterialType.transparency,
              child: ClipPath(child: SizedBox(width: 10, height: 10)),
            ),
          ),
        );
        await driveMaterialPainterPage(tester);

        final userClip = find.byWidgetPredicate(
          (w) => w is ClipPath && w.child is SizedBox,
        );
        var userClipParentIsMaterial = false;
        tester.element(userClip).visitAncestorElements((a) {
          userClipParentIsMaterial = a.widget is Material;
          return false;
        });
        expect(userClipParentIsMaterial, isFalse);

        detector.scanTree(tester.element(find.byType(MaterialApp)));

        final issue = detector.issues.singleWhere(
          (i) => i.stableId == 'missing_repaint_boundary',
        );
        expect(issue.title, contains('1 expensive widget'));
        expect(issue.detail, contains('ClipPath'));
      });
    });

    testWidgets('sibling scroll views with excessive boundaries carry their '
        'own element ids, kept across scans', (tester) async {
      Widget lists(int a, int b) => Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          children: [
            for (final (key, n) in [('a', a), ('b', b)])
              Expanded(
                child: ListView(
                  key: ValueKey(key),
                  addRepaintBoundaries: false,
                  children: List.generate(
                    n,
                    (i) => const RepaintBoundary(
                      child: SizedBox(height: 10, width: 10),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
      List<int?> scanIds() {
        detector.scanTree(tester.element(find.byType(Directionality)));
        return [
          for (final i in detector.issues)
            if (i.stableId == 'excessive_repaint_boundary') i.occurrenceId,
        ];
      }

      await tester.pumpWidget(lists(25, 25));
      final first = scanIds();
      expect(first, [
        identityHashCode(tester.element(find.byKey(const ValueKey('a')))),
        identityHashCode(tester.element(find.byKey(const ValueKey('b')))),
      ]);
      expect(first[0], isNot(first[1]));

      await tester.pumpWidget(lists(25, 30));
      expect(scanIds(), first);
    });
  });
}

class _StubPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// User painter sharing the TabBar indicator painter's class name.
class _IndicatorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// User painter sharing Material's shape-border painter's class name.
class _ShapeBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Third-party style delegate: not one of the framework delegates, so its
/// boundary wrapping is unknown.
class _ForwardingDelegate extends SliverChildDelegate {
  _ForwardingDelegate(this.children);

  final List<Widget> children;

  @override
  Widget? build(BuildContext context, int index) =>
      index < children.length ? children[index] : null;

  @override
  int? get estimatedChildCount => children.length;

  @override
  bool shouldRebuild(covariant SliverChildDelegate oldDelegate) => true;
}

/// A [BoxScrollView] that is neither a ListView nor a GridView.
class _PlainBoxScrollView extends BoxScrollView {
  const _PlainBoxScrollView({required this.children});

  final List<Widget> children;

  @override
  Widget buildChildLayout(BuildContext context) =>
      SliverList(delegate: SliverChildListDelegate(children));
}
