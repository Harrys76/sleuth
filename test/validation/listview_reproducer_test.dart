// Hermetic reproducer for [ListviewDetector].
//
// Cited by `ListviewDetector.validationMetadata.reproducerPath` as the
// single-file evidence supporting the detector's
// `EvidenceTier.reproducerOnly` claim.
//
// The detector emits nine stable-id families, all pinned here:
//
//   - `non_lazy_listview` — ListView(children: [...]) above
//     `childThreshold`; `.builder` is the lazy-path negative control.
//   - `non_lazy_gridview` — GridView(children: [...]) above threshold;
//     `.builder` negative.
//   - `non_lazy_sliver_list` — SliverList(SliverChildListDelegate)
//     inside CustomScrollView above threshold; SliverChildBuilderDelegate
//     negative.
//   - `non_lazy_sliver_grid` — SliverGrid(SliverChildListDelegate)
//     inside CustomScrollView above threshold; builder negative.
//   - `non_lazy_list` — SingleChildScrollView wrapping a Column/Row
//     above threshold; at-threshold negative.
//   - `sliver_to_box_adapter_large` — SliverToBoxAdapter wrapping a
//     Column/Row above `childThreshold`.
//   - `sliver_to_box_adapter_shrinkwrap` — SliverToBoxAdapter wrapping
//     a ListView/GridView with `shrinkWrap: true` AND `!isNonLazy` AND a
//     delegate child count that is null (unbounded builder) or > 20.
//     Tests pin the gate: 25 list-delegate children fire, 5 stay silent,
//     an unbounded builder fires, shrinkWrap false is silent, and
//     many-children-via-list-delegate fires Check A
//     (`non_lazy_listview`) NOT Check C (isNonLazy bypass).
//   - `non_lazy_shrinkwrap` — ListView/GridView with `shrinkWrap: true`
//     under a Column/Row (Flex depth stack), outside any
//     SliverToBoxAdapter, with a delegate child count that is null or
//     > 20; critical above 100. 25 children fire, 20 stay silent, no Flex
//     is silent, and the same list in a SliverToBoxAdapter fires the
//     Check C id instead. It replaces `non_lazy_listview` for the same
//     element.
//   - `sliver_fill_remaining_scrollable` — SliverFillRemaining with
//     `hasScrollBody: false` wrapping a scrollable child. Structural
//     adjacency check only — the real anti-pattern throws a layout
//     error in flutter_test and is wrapped in a bounded SizedBox.
//
// `childThreshold` defaults to 50; the reproducer constructs the
// detector with a small threshold (5) so boundary tests are cheap.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/listview_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  group('ListviewDetector reproducer — non_lazy_listview', () {
    late ListviewDetector detector;

    setUp(() {
      // Tiny threshold (5) keeps below/at/above boundary pumps fast.
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets('5 children (at threshold, inclusive skip) does NOT fire', (
      tester,
    ) async {
      // Check condition is `delegate.children.length > childThreshold` —
      // strictly greater than, so 5 at threshold-5 is NOT a fire.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: ListView(
              children: List.generate(
                5,
                (i) => SizedBox(height: 40, child: Text('$i')),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'non_lazy_listview'),
        isEmpty,
        reason: 'threshold comparison is strictly greater-than.',
      );
    });

    testWidgets('6 children (just above threshold) fires non_lazy_listview', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: ListView(
              children: List.generate(
                6,
                (i) => SizedBox(height: 40, child: Text('$i')),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'non_lazy_listview')
          .toList();
      expect(issues, hasLength(1));
      expect(issues.single.title, contains('6 children'));
    });

    testWidgets('20 children (well above, > 3×threshold) fires critical', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: ListView(
              children: List.generate(
                20,
                (i) => SizedBox(height: 40, child: Text('$i')),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'non_lazy_listview')
          .toList();
      expect(issues, hasLength(1));
      // 20 > 5×3 = 15 so severity escalates to critical.
      expect(issues.single.severity.name, 'critical');
    });

    testWidgets('ListView.builder (lazy) does NOT fire at any count', (
      tester,
    ) async {
      // Documents the fix: .builder uses SliverChildBuilderDelegate which
      // is NOT SliverChildListDelegate, so the detector's isNonLazy gate
      // short-circuits regardless of itemCount.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: ListView.builder(
              itemCount: 100,
              itemBuilder: (_, i) => SizedBox(height: 40, child: Text('$i')),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'non_lazy_listview'),
        isEmpty,
      );
    });
  });

  group('ListviewDetector reproducer — sliver_to_box_adapter_large', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets('SliverToBoxAdapter + Column(6 children) fires '
        'sliver_to_box_adapter_large', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: List.generate(
                      6,
                      (i) => SizedBox(height: 40, child: Text('$i')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'sliver_to_box_adapter_large')
          .toList();
      expect(issues, hasLength(1));
      expect(issues.single.title, contains('6 children'));
    });

    testWidgets(
      'SliverToBoxAdapter + Column(5 children) at-threshold does NOT fire',
      (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 200,
              height: 400,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      children: List.generate(
                        5,
                        (i) => SizedBox(height: 40, child: Text('$i')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues.where(
            (i) => i.stableId == 'sliver_to_box_adapter_large',
          ),
          isEmpty,
        );
      },
    );
  });

  group('ListviewDetector reproducer — sliver_fill_remaining_scrollable', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets('SliverFillRemaining(hasScrollBody: false) with ListView fires '
        'sliver_fill_remaining_scrollable', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  // Wrap in SizedBox to avoid Flutter's own layout error
                  // on the anti-pattern under test — the detector walks
                  // structure only, not rendering output.
                  child: SizedBox(
                    height: 200,
                    child: ListView.builder(
                      itemCount: 3,
                      itemBuilder: (_, i) => SizedBox(
                        key: ValueKey(i),
                        height: 40,
                        child: Text('$i'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'sliver_fill_remaining_scrollable')
          .toList();
      expect(issues, hasLength(1));
    });

    testWidgets(
      'SliverFillRemaining(hasScrollBody: true) wrapping a scrollable '
      'does NOT fire',
      (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 200,
              height: 400,
              child: CustomScrollView(
                slivers: [
                  SliverFillRemaining(
                    // hasScrollBody defaults to true — the ListView is the
                    // intended scroll surface, no layout error here.
                    child: ListView.builder(
                      itemCount: 3,
                      itemBuilder: (_, i) => SizedBox(
                        key: ValueKey(i),
                        height: 40,
                        child: Text('$i'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues.where(
            (i) => i.stableId == 'sliver_fill_remaining_scrollable',
          ),
          isEmpty,
          reason:
              'hasScrollBody: true is the correct use — the depth counter '
              '_insideSliverFillNoScroll stays 0.',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // v0.16.6 backfill — 5 remaining families raised from unvalidated to
  // reproducerOnly alongside FrameTiming.
  // -------------------------------------------------------------------------

  group('ListviewDetector reproducer — non_lazy_gridview', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets('6 children (just above threshold) fires non_lazy_gridview', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: GridView(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
              ),
              children: List.generate(
                6,
                (i) => SizedBox(height: 40, child: Text('$i')),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'non_lazy_gridview')
          .toList();
      expect(issues, hasLength(1));
      expect(issues.single.title, contains('6 children'));
    });

    testWidgets('GridView.builder (lazy) does NOT fire at any count', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
              ),
              itemCount: 100,
              itemBuilder: (_, i) => SizedBox(height: 40, child: Text('$i')),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'non_lazy_gridview'),
        isEmpty,
      );
    });
  });

  group('ListviewDetector reproducer — non_lazy_sliver_list', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets('SliverList(SliverChildListDelegate) with 6 children fires '
        'non_lazy_sliver_list', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: CustomScrollView(
              slivers: [
                SliverList(
                  delegate: SliverChildListDelegate(
                    List.generate(
                      6,
                      (i) => SizedBox(height: 40, child: Text('$i')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'non_lazy_sliver_list')
          .toList();
      expect(issues, hasLength(1));
      expect(issues.single.title, contains('6 children'));
    });

    testWidgets(
      'SliverList.builder (SliverChildBuilderDelegate) does NOT fire at '
      'any count',
      (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 200,
              height: 400,
              child: CustomScrollView(
                slivers: [
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => SizedBox(height: 40, child: Text('$i')),
                      childCount: 100,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues.where((i) => i.stableId == 'non_lazy_sliver_list'),
          isEmpty,
        );
      },
    );
  });

  group('ListviewDetector reproducer — non_lazy_sliver_grid', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets('SliverGrid(SliverChildListDelegate) with 6 children fires '
        'non_lazy_sliver_grid', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: CustomScrollView(
              slivers: [
                SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                  ),
                  delegate: SliverChildListDelegate(
                    List.generate(
                      6,
                      (i) => SizedBox(height: 40, child: Text('$i')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'non_lazy_sliver_grid')
          .toList();
      expect(issues, hasLength(1));
      expect(issues.single.title, contains('6 children'));
    });

    testWidgets(
      'SliverGrid.builder (SliverChildBuilderDelegate) does NOT fire at '
      'any count',
      (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 200,
              height: 400,
              child: CustomScrollView(
                slivers: [
                  SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => SizedBox(height: 40, child: Text('$i')),
                      childCount: 100,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues.where((i) => i.stableId == 'non_lazy_sliver_grid'),
          isEmpty,
        );
      },
    );
  });

  group('ListviewDetector reproducer — sliver_to_box_adapter_shrinkwrap', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    Future<List<PerformanceIssue>> pumpShrinkWrap(
      WidgetTester tester,
      ListView inner,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: 200, child: inner)),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      return detector.issues
          .where((i) => i.stableId == 'sliver_to_box_adapter_shrinkwrap')
          .toList();
    }

    testWidgets('shrinkWrap: true + 5 list-delegate children stays silent '
        '(count gate: > 20)', (tester) async {
      final issues = await pumpShrinkWrap(
        tester,
        ListView(
          shrinkWrap: true,
          children: List.generate(
            5,
            (i) => SizedBox(height: 40, child: Text('$i')),
          ),
        ),
      );
      expect(issues, isEmpty);
    });

    testWidgets('shrinkWrap: true + unbounded builder (childCount null) '
        'fires', (tester) async {
      final issues = await pumpShrinkWrap(
        tester,
        ListView.builder(
          shrinkWrap: true,
          itemBuilder: (_, i) => SizedBox(height: 40, child: Text('$i')),
        ),
      );
      expect(issues, hasLength(1));
    });

    testWidgets('shrinkWrap: true + 25 list-delegate children inside '
        'SliverToBoxAdapter fires', (tester) async {
      // Check C gate: `_insideSliverToBoxAdapter > 0 && shrinkWrap &&
      // !isNonLazy && (childCount == null || childCount > 20)`. Default
      // childThreshold (50) keeps 25 list-delegate children non-lazy-false
      // so Check C, not Check A, owns the finding.
      detector = ListviewDetector();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  // SizedBox wraps the INNER ListView (layout
                  // constraints), not the outer SliverToBoxAdapter.
                  child: SizedBox(
                    height: 200,
                    child: ListView(
                      shrinkWrap: true,
                      children: List.generate(
                        25,
                        (i) => SizedBox(height: 40, child: Text('$i')),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'sliver_to_box_adapter_shrinkwrap')
          .toList();
      expect(issues, hasLength(1));
    });

    testWidgets('shrinkWrap: false inside SliverToBoxAdapter does NOT fire', (
      tester,
    ) async {
      // shrinkWrap=false disables the gate regardless of delegate shape.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 200,
                    child: ListView(
                      shrinkWrap: false,
                      children: List.generate(
                        3,
                        (i) => SizedBox(height: 40, child: Text('$i')),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where(
          (i) => i.stableId == 'sliver_to_box_adapter_shrinkwrap',
        ),
        isEmpty,
        reason: 'shrinkWrap false disables Check C.',
      );
    });

    testWidgets(
      'many list-delegate children + shrinkWrap: true routes to Check A '
      '(isNonLazy bypass — non_lazy_listview fires, Check C silent)',
      (tester) async {
        // Many (6 > 5) children in SliverChildListDelegate makes isNonLazy
        // true, which means `!isNonLazy` is false and Check C is silent —
        // Check A (`non_lazy_listview`) fires instead. Pins the gate's
        // mutual-exclusion semantics: the same widget cannot produce both
        // shrinkwrap AND non_lazy_listview issues.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 200,
              height: 400,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 200,
                      child: ListView(
                        shrinkWrap: true,
                        children: List.generate(
                          6,
                          (i) => SizedBox(height: 40, child: Text('$i')),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues.where(
            (i) => i.stableId == 'sliver_to_box_adapter_shrinkwrap',
          ),
          isEmpty,
          reason: 'isNonLazy=true bypasses Check C via !isNonLazy=false.',
        );
        expect(
          detector.issues.where((i) => i.stableId == 'non_lazy_listview'),
          hasLength(1),
          reason: 'Check A fires in place of Check C on the same widget.',
        );
      },
    );
  });

  group('ListviewDetector reproducer — non_lazy_list', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets(
      'SingleChildScrollView + Column(6 children) fires non_lazy_list',
      (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 200,
              height: 400,
              child: SingleChildScrollView(
                child: Column(
                  children: List.generate(
                    6,
                    (i) => SizedBox(height: 40, child: Text('$i')),
                  ),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final issues = detector.issues
            .where((i) => i.stableId == 'non_lazy_list')
            .toList();
        expect(issues, hasLength(1));
        expect(issues.single.title, contains('6 children'));
      },
    );

    testWidgets(
      'SingleChildScrollView + Column(5 children) at-threshold silent',
      (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 200,
              height: 400,
              child: SingleChildScrollView(
                child: Column(
                  children: List.generate(
                    5,
                    (i) => SizedBox(height: 40, child: Text('$i')),
                  ),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues.where((i) => i.stableId == 'non_lazy_list'),
          isEmpty,
          reason: 'threshold comparison strictly greater-than.',
        );
      },
    );
  });

  group('ListviewDetector reproducer — non_lazy_shrinkwrap', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector();
    });

    List<Widget> rows(int n) =>
        List.generate(n, (i) => SizedBox(key: ValueKey(i), height: 2));

    Future<void> scan(WidgetTester tester, Widget body) async {
      await tester.pumpWidget(
        Directionality(textDirection: TextDirection.ltr, child: body),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
    }

    Iterable<PerformanceIssue> shrinkWrapIssues() =>
        detector.issues.where((i) => i.stableId == 'non_lazy_shrinkwrap');

    testWidgets('25 children in a Column fires as a warning', (tester) async {
      await scan(
        tester,
        Column(children: [ListView(shrinkWrap: true, children: rows(25))]),
      );
      expect(shrinkWrapIssues().single.severity, IssueSeverity.warning);
    });

    testWidgets('20 children (at the gate) silent', (tester) async {
      await scan(
        tester,
        Column(children: [ListView(shrinkWrap: true, children: rows(20))]),
      );
      expect(shrinkWrapIssues(), isEmpty);
    });

    testWidgets('bounded height (Expanded) silent', (tester) async {
      await scan(
        tester,
        Column(
          children: [
            Expanded(child: ListView(shrinkWrap: true, children: rows(25))),
          ],
        ),
      );
      expect(shrinkWrapIssues(), isEmpty);
    });

    testWidgets('101 builder items critical', (tester) async {
      await scan(
        tester,
        Column(
          children: [
            ListView.builder(
              shrinkWrap: true,
              itemCount: 101,
              itemBuilder: (_, i) => const SizedBox(height: 2),
            ),
          ],
        ),
      );
      expect(shrinkWrapIssues().single.severity, IssueSeverity.critical);
    });

    testWidgets('100 builder items warning', (tester) async {
      await scan(
        tester,
        Column(
          children: [
            ListView.builder(
              shrinkWrap: true,
              itemCount: 100,
              itemBuilder: (_, i) => const SizedBox(height: 2),
            ),
          ],
        ),
      );
      expect(shrinkWrapIssues().single.severity, IssueSeverity.warning);
    });

    testWidgets('no Flex ancestor silent', (tester) async {
      await scan(
        tester,
        SizedBox(
          height: 300,
          child: ListView(shrinkWrap: true, children: rows(25)),
        ),
      );
      expect(shrinkWrapIssues(), isEmpty);
    });

    testWidgets('inside a SliverToBoxAdapter the Check C id wins', (
      tester,
    ) async {
      await scan(
        tester,
        CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [ListView(shrinkWrap: true, children: rows(25))],
              ),
            ),
          ],
        ),
      );
      expect(shrinkWrapIssues(), isEmpty);
      expect(
        detector.issues.where(
          (i) => i.stableId == 'sliver_to_box_adapter_shrinkwrap',
        ),
        hasLength(1),
      );
    });

    testWidgets('above the non-lazy threshold it replaces non_lazy_listview', (
      tester,
    ) async {
      await scan(
        tester,
        Column(children: [ListView(shrinkWrap: true, children: rows(60))]),
      );
      expect(shrinkWrapIssues(), hasLength(1));
      expect(
        detector.issues.where((i) => i.stableId == 'non_lazy_listview'),
        isEmpty,
      );
    });
  });
}
