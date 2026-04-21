// Hermetic reproducer for [ListviewDetector].
//
// Cited by `ListviewDetector.validationMetadata.reproducerPath` as the
// single-file evidence supporting the detector's
// `EvidenceTier.reproducerOnly` claim.
//
// The detector emits eight stable-id families; v0.16.6 raises coverage
// from 3 to all 8:
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
//     a ListView/GridView with `shrinkWrap: true` AND `!isNonLazy` (few
//     children in a SliverChildListDelegate, OR any count via .builder).
//     Three-test triad pins the gate: shrinkWrap true fires, shrinkWrap
//     false silent, many-children-via-list-delegate fires Check A
//     (`non_lazy_listview`) NOT Check C (isNonLazy bypass).
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

    testWidgets(
        'SliverToBoxAdapter + Column(6 children) fires '
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
        'SliverToBoxAdapter + Column(5 children) at-threshold does NOT fire', (
      tester,
    ) async {
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
        detector.issues
            .where((i) => i.stableId == 'sliver_to_box_adapter_large'),
        isEmpty,
      );
    });
  });

  group('ListviewDetector reproducer — sliver_fill_remaining_scrollable', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets(
        'SliverFillRemaining(hasScrollBody: false) with ListView fires '
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
        'does NOT fire', (tester) async {
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
        detector.issues
            .where((i) => i.stableId == 'sliver_fill_remaining_scrollable'),
        isEmpty,
        reason: 'hasScrollBody: true is the correct use — the depth counter '
            '_insideSliverFillNoScroll stays 0.',
      );
    });
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

    testWidgets(
        'SliverList(SliverChildListDelegate) with 6 children fires '
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
        'any count', (tester) async {
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
    });
  });

  group('ListviewDetector reproducer — non_lazy_sliver_grid', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets(
        'SliverGrid(SliverChildListDelegate) with 6 children fires '
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
        'any count', (tester) async {
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
    });
  });

  group('ListviewDetector reproducer — sliver_to_box_adapter_shrinkwrap', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets(
        'shrinkWrap: true + few list-delegate children inside '
        'SliverToBoxAdapter fires', (tester) async {
      // Check C gate: `_insideSliverToBoxAdapter > 0 && shrinkWrap &&
      // !isNonLazy`. Few children (3 < 5) in SliverChildListDelegate keeps
      // isNonLazy false so !isNonLazy is true and the gate fires.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 400,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  // F1: SizedBox wraps the INNER ListView (layout
                  // constraints), not the outer SliverToBoxAdapter.
                  child: SizedBox(
                    height: 200,
                    child: ListView(
                      shrinkWrap: true,
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
        detector.issues
            .where((i) => i.stableId == 'sliver_to_box_adapter_shrinkwrap'),
        isEmpty,
        reason: 'shrinkWrap false disables Check C.',
      );
    });

    testWidgets(
        'many list-delegate children + shrinkWrap: true routes to Check A '
        '(isNonLazy bypass — non_lazy_listview fires, Check C silent)', (
      tester,
    ) async {
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
        detector.issues
            .where((i) => i.stableId == 'sliver_to_box_adapter_shrinkwrap'),
        isEmpty,
        reason: 'isNonLazy=true bypasses Check C via !isNonLazy=false.',
      );
      expect(
        detector.issues.where((i) => i.stableId == 'non_lazy_listview'),
        hasLength(1),
        reason: 'Check A fires in place of Check C on the same widget.',
      );
    });
  });

  group('ListviewDetector reproducer — non_lazy_list', () {
    late ListviewDetector detector;

    setUp(() {
      detector = ListviewDetector(childThreshold: 5);
    });

    testWidgets(
        'SingleChildScrollView + Column(6 children) fires non_lazy_list', (
      tester,
    ) async {
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

      final issues =
          detector.issues.where((i) => i.stableId == 'non_lazy_list').toList();
      expect(issues, hasLength(1));
      expect(issues.single.title, contains('6 children'));
    });

    testWidgets(
        'SingleChildScrollView + Column(5 children) at-threshold silent', (
      tester,
    ) async {
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
    });
  });
}
