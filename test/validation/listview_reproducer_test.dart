// Hermetic reproducer for [ListviewDetector].
//
// Cited by `ListviewDetector.validationMetadata.reproducerPath` as the
// single-file evidence supporting the detector's
// `EvidenceTier.reproducerOnly` claim (v0.16.3 per-detector validation
// milestone).
//
// The detector emits eight stable-id families. This reproducer pins the
// three that are cheapest to exercise hermetically and are the highest-
// value signals in practice:
//
//   - `non_lazy_listview` — ListView(children: [...]) above `childThreshold`
//   - `sliver_to_box_adapter_large` — SliverToBoxAdapter wrapping a
//     Column/Row above `childThreshold`
//   - `sliver_fill_remaining_scrollable` — SliverFillRemaining with
//     `hasScrollBody: false` wrapping a scrollable child (eager-build trap)
//
// The remaining 5 families (`non_lazy_gridview`, `non_lazy_sliver_list`,
// `non_lazy_sliver_grid`, `sliver_to_box_adapter_shrinkwrap`,
// `non_lazy_list`) remain implicitly `unvalidated` at v0.16.3 — same
// pattern as v0.16.1 Network Monitor's single-family pin. The ledger
// row calls this out explicitly.
//
// `childThreshold` defaults to 50; the reproducer constructs the
// detector with a small threshold to keep boundary tests fast.

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
}
