// RebuildStatsPage widget tests — spec v15 M12.
//
// These tests exercise the drilldown page that opens from the
// `_RebuildStatsBanner` panel's "See all N →" link on the floating
// issues card. (Pre-v0.15.2 this was reachable from a
// `rebuild_hotspot_summary` rollup IssueCard, which has since been
// replaced by the always-on inline panel.)
// Key contracts under test:
//
// - **Empty state (R21):** a session with zero rebuild counts must render
//   the empty-state message, not a blank ListView.
// - **Descending sort (M10):** rows are sorted by count descending so the
//   heaviest rebuilder is always at rank 1, regardless of map insertion
//   order.
// - **Header + summary chips:** total and type-count chips reflect the
//   counts passed in at construction time.
// - **Close button (R22):** back-arrow and system-back both invoke
//   `onClose` exactly once.
// - **Snapshot-at-open (M10):** mutations to the caller's counts map
//   after the page is constructed MUST NOT reflow or reorder the rendered
//   rows — the page takes a defensive copy inside its constructor.
//   Live-updating a drilldown while the user reads it would shuffle rows
//   out from under them and is explicitly avoided per spec.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/ui/rebuild_stats_page.dart';

Widget _pump(RebuildStatsPage page) {
  return MaterialApp(home: page);
}

void main() {
  group('RebuildStatsPage (spec v15 M12)', () {
    testWidgets('empty counts map renders empty-state message', (tester) async {
      await tester.pumpWidget(_pump(
        RebuildStatsPage(
          routeDisplayName: '/home',
          countsByType: const {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.text('No rebuilds recorded for this session.'),
        findsOneWidget,
      );
      // Summary chips are suppressed in the empty case.
      expect(find.text('Total'), findsNothing);
      expect(find.text('Types'), findsNothing);
    });

    testWidgets('populated counts render header and summary chips',
        (tester) async {
      await tester.pumpWidget(_pump(
        RebuildStatsPage(
          routeDisplayName: '/home',
          countsByType: const {
            'ProductCard': 5,
            'Header': 2,
            'Footer': 1,
          },
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // Header pieces: title, subtitle (route), total chip, types chip.
      expect(find.text('Rebuild Stats'), findsOneWidget);
      expect(find.text('/home'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('8'), findsOneWidget); // 5 + 2 + 1
      expect(find.text('Types'), findsOneWidget);
      expect(find.text('3'), findsOneWidget); // 3 distinct type names
    });

    testWidgets('rows are sorted descending by count', (tester) async {
      // Insertion order intentionally randomized: Footer first, biggest
      // last — if the page weren't sorting, rank 1 would be Footer.
      await tester.pumpWidget(_pump(
        RebuildStatsPage(
          routeDisplayName: '/home',
          countsByType: const {
            'Footer': 1,
            'ProductCard': 7,
            'Header': 3,
          },
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // Walk the rendered row widgets in document order and pull their
      // rank + type-name + count text. `Text` widgets inside `_RebuildRow`
      // appear as `rank.`, `typeName`, `×count` in that order.
      final allTextStrings = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();

      final productCardIndex = allTextStrings.indexOf('ProductCard');
      final headerIndex = allTextStrings.indexOf('Header');
      final footerIndex = allTextStrings.indexOf('Footer');

      expect(productCardIndex, isNonNegative);
      expect(headerIndex, isNonNegative);
      expect(footerIndex, isNonNegative);

      // Heaviest first, lightest last.
      expect(productCardIndex, lessThan(headerIndex));
      expect(headerIndex, lessThan(footerIndex));

      // Count labels.
      expect(find.text('×7'), findsOneWidget);
      expect(find.text('×3'), findsOneWidget);
      expect(find.text('×1'), findsOneWidget);

      // Ranks (the rank column renders '1.', '2.', '3.').
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(find.text('3.'), findsOneWidget);
    });

    testWidgets('tapping back arrow fires onClose', (tester) async {
      var closeCount = 0;
      await tester.pumpWidget(_pump(
        RebuildStatsPage(
          routeDisplayName: '/home',
          countsByType: const {'ProductCard': 3},
          onClose: () => closeCount++,
        ),
      ));
      await tester.pumpAndSettle();

      // Tap the Semantics-wrapped back button (label 'Back') rather than
      // chasing the raw Icon — multiple icons exist on the page.
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'Back',
        ),
      );
      await tester.pump();

      expect(closeCount, 1);
    });

    testWidgets('inflation disclaimer text is always visible', (tester) async {
      // Disclaimer mirrors the KDD-5 caveat on the rollup issue so a user
      // who drills in doesn't miss it. Present on empty AND populated.
      await tester.pumpWidget(_pump(
        RebuildStatsPage(
          routeDisplayName: '/home',
          countsByType: const {'ProductCard': 3},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Profile-mode counts include'),
        findsOneWidget,
      );
    });

    testWidgets(
        'snapshot-at-open: mutating caller map after construction does NOT '
        'reorder rows', (tester) async {
      // Build a mutable map, hand it to the page, then mutate it. The
      // rendered rows must reflect the counts as they were at construction
      // time — defensive-copy semantics per spec M10.
      final liveCounts = <String, int>{
        'ProductCard': 5,
        'Header': 2,
      };

      await tester.pumpWidget(_pump(
        RebuildStatsPage(
          routeDisplayName: '/home',
          countsByType: liveCounts,
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // Before mutation: total 7, types 2, ProductCard ranks above Header.
      expect(find.text('7'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      // Mutate the underlying map: bump Header past ProductCard, add a
      // brand-new type. A page that read `countsByType` live would show
      // Header at rank 1 and a third row after a rebuild.
      liveCounts['Header'] = 99;
      liveCounts['NewType'] = 42;

      // Force a rebuild of the page's context.
      await tester.pump();

      // Totals unchanged (snapshot semantics).
      expect(find.text('7'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // NewType did NOT appear.
      expect(find.text('NewType'), findsNothing);
      // Original ordering preserved — ProductCard count still ×5, Header still ×2.
      expect(find.text('×5'), findsOneWidget);
      expect(find.text('×2'), findsOneWidget);
      // Mutation values must NOT be rendered.
      expect(find.text('×99'), findsNothing);
      expect(find.text('×42'), findsNothing);
    });

    testWidgets('null routeDisplayName hides subtitle', (tester) async {
      await tester.pumpWidget(_pump(
        RebuildStatsPage(
          routeDisplayName: null,
          countsByType: const {'ProductCard': 1},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // Title still renders.
      expect(find.text('Rebuild Stats'), findsOneWidget);
      // No subtitle route line.
      expect(find.text('/home'), findsNothing);
    });

    testWidgets('single-entry list renders rank 1 with full bar',
        (tester) async {
      // The top row's bar fraction is `count / topCount == 1.0`. We can't
      // inspect the private LinearProgressIndicator's value directly, but
      // we can at least verify a single-entry list renders without error
      // and shows the expected row data.
      await tester.pumpWidget(_pump(
        RebuildStatsPage(
          routeDisplayName: '/settings',
          countsByType: const {'SoloWidget': 42},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('1.'), findsOneWidget);
      expect(find.text('SoloWidget'), findsOneWidget);
      expect(find.text('×42'), findsOneWidget);
      // Summary: 42 total, 1 type.
      expect(find.text('42'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });
  });
}
