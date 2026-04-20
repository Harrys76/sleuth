// Hermetic reproducer for [GlobalKeyDetector].
//
// Cited by `GlobalKeyDetector.validationMetadata.reproducerPath` as the
// single-file evidence supporting the detector's
// `EvidenceTier.reproducerOnly` claim (v0.16.3 per-detector validation
// milestone). Covers both stable-id families:
//
//   - `excessive_global_keys:<i>` — parameterized by scrollable index.
//     The `coveredStableIds` set uses the canonical prefix form
//     `excessive_global_keys` per the convention noted in
//     `doc/validation_ledger.md`. Fires when a scrollable
//     (ListView / GridView / PageView) contains more than
//     `threshold` user-assigned GlobalKey children (framework-internal
//     GlobalKeys on KeyedSubtree, Focus, etc. are excluded).
//
//   - `global_key_recreation` — fires when `>= recreationThreshold`
//     keys symmetrically churn between two scans on the SAME scan root.
//     Symmetric min(newKeys, goneKeys) filters out navigation (which is
//     asymmetric — one page's keys vanish, another's appear) from
//     in-place rebuild-driven recreation.
//
// Both require a scrollable context. The detector ONLY counts keys
// while a ListView/GridView/PageView is on its internal stack.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/global_key_detector.dart';

Widget _scrollableWith(List<Widget> children) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: SizedBox(
      width: 300,
      height: 600,
      child: ListView(children: children),
    ),
  );
}

void main() {
  group('GlobalKeyDetector reproducer — excessive_global_keys', () {
    late GlobalKeyDetector detector;

    setUp(() {
      // Low threshold keeps below/at/above fast. Production default is 20.
      detector = GlobalKeyDetector(threshold: 3);
    });

    testWidgets('3 keys (at threshold, inclusive skip) does NOT fire', (
      tester,
    ) async {
      // Check condition is `data.count > threshold` — strictly greater-
      // than, so 3 at threshold-3 is NOT a fire.
      await tester.pumpWidget(_scrollableWith([
        for (var i = 0; i < 3; i++)
          SizedBox(
            key: GlobalKey(debugLabel: 'k$i'),
            height: 40,
            child: Text('$i'),
          ),
      ]));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where(
            (i) => (i.stableId ?? '').startsWith('excessive_global_keys')),
        isEmpty,
        reason: 'threshold comparison is strictly greater-than.',
      );
    });

    testWidgets('4 keys (just above threshold) fires excessive_global_keys', (
      tester,
    ) async {
      await tester.pumpWidget(_scrollableWith([
        for (var i = 0; i < 4; i++)
          SizedBox(
            key: GlobalKey(debugLabel: 'k$i'),
            height: 40,
            child: Text('$i'),
          ),
      ]));
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => (i.stableId ?? '').startsWith('excessive_global_keys'))
          .toList();
      expect(issues, hasLength(1));
      expect(issues.single.stableId, 'excessive_global_keys:0');
      expect(issues.single.title, contains('4'));
    });

    testWidgets('10 keys (> 3×threshold) fires critical severity', (
      tester,
    ) async {
      await tester.pumpWidget(_scrollableWith([
        for (var i = 0; i < 10; i++)
          SizedBox(
            key: GlobalKey(debugLabel: 'k$i'),
            height: 40,
            child: Text('$i'),
          ),
      ]));
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => (i.stableId ?? '').startsWith('excessive_global_keys'))
          .toList();
      expect(issues, hasLength(1));
      expect(issues.single.severity.name, 'critical');
    });

    testWidgets('GlobalKeys OUTSIDE a scrollable do NOT fire', (tester) async {
      // Detector only counts keys while a ListView/GridView/PageView is
      // on its internal scrollable stack — bare-tree keys are ignored.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              for (var i = 0; i < 10; i++)
                SizedBox(
                  key: GlobalKey(debugLabel: 'bare$i'),
                  height: 40,
                  child: Text('$i'),
                ),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where(
            (i) => (i.stableId ?? '').startsWith('excessive_global_keys')),
        isEmpty,
      );
    });
  });

  group('GlobalKeyDetector reproducer — global_key_recreation', () {
    late GlobalKeyDetector detector;

    setUp(() {
      // Threshold 3 for excessive_global_keys so scan-1 itself does not
      // also fire that family (we want clean recreation-only attribution).
      // recreationThreshold: 2 keeps the scan-2 churn count small.
      detector = GlobalKeyDetector(threshold: 100, recreationThreshold: 2);
    });

    List<Widget> freshChildren() => [
          for (var i = 0; i < 4; i++)
            SizedBox(
              key: GlobalKey(debugLabel: 'scan$i'),
              height: 40,
              child: Text('$i'),
            ),
        ];

    testWidgets(
        'two scans with fresh GlobalKey instances on SAME scan root '
        'fires global_key_recreation', (tester) async {
      // Scan 1: prime _prevKeyIds with 4 fresh keys.
      await tester.pumpWidget(_scrollableWith(freshChildren()));
      final root1 = tester.element(find.byType(Directionality));
      detector.scanTree(root1);

      // Scan 2: pump a DIFFERENT tree of 4 fresh keys. Same scan root
      // (Directionality Element survives pumpWidget when top-level type
      // is stable). Reset issue buffer happens in prepareScan. Churn is
      // 4 new + 4 gone → min=4, >= recreationThreshold=2 → fires.
      await tester.pumpWidget(_scrollableWith(freshChildren()));
      final root2 = tester.element(find.byType(Directionality));
      detector.scanTree(root2);

      final issues = detector.issues
          .where((i) => i.stableId == 'global_key_recreation')
          .toList();
      expect(issues, hasLength(1));
      expect(issues.single.title, contains('4 keys recreated'));
    });

    testWidgets(
        'two scans reusing the SAME GlobalKey instances does NOT fire '
        'global_key_recreation', (tester) async {
      // Hold keys stable across pumps — exactly the contract developers
      // satisfy by storing GlobalKeys in State fields, not building them
      // inside build().
      final stableKeys = [for (var i = 0; i < 4; i++) GlobalKey()];

      Widget build() => _scrollableWith([
            for (var i = 0; i < 4; i++)
              SizedBox(key: stableKeys[i], height: 40, child: Text('$i')),
          ]);

      await tester.pumpWidget(build());
      detector.scanTree(tester.element(find.byType(Directionality)));

      await tester.pumpWidget(build());
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'global_key_recreation'),
        isEmpty,
        reason: 'identity hashes are unchanged across scans — no churn.',
      );
    });

    testWidgets(
        'first scan alone does NOT fire — recreation needs a prior '
        '_prevKeyIds set', (tester) async {
      // Documents the initial-scan grace period: with _prevKeyIds empty
      // we cannot compute churn, so the first scan is always silent
      // even with many fresh keys.
      await tester.pumpWidget(_scrollableWith(freshChildren()));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'global_key_recreation'),
        isEmpty,
      );
    });
  });
}
