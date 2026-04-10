// Regression test for `lib/demos/global_key_demo.dart`.
//
// Why this exists: `GlobalKeyDetector` counts only *realized* children
// of a scrollable (viewport + cacheExtent). With the default 72pt
// Card+ListTile items this demo used to ship with, a typical phone
// body area only realizes ~13 items — well below the strict >20
// threshold the detector uses. The demo *looked* correct in source
// (25 keys in a list) but never actually fired on device.
//
// The fix uses a 40pt itemExtent with a compact public `CompactRow`
// widget so ~24 items are realized on the smallest phone viewport.
// This test locks that behaviour in by loading the demo inside a
// phone-sized MediaQuery and counting realized CompactRow elements
// directly under the bad ListView.

import 'package:example/demos/global_key_demo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Smallest modern phone body area we care about — iPhone SE third
  // generation (667pt tall) minus status bar, app bar, demo description,
  // and toggle row. ~480pt is a realistic worst case for DemoScaffold.
  const phoneBodySize = Size(375, 667);

  testWidgets(
    'GlobalKey demo bad path realizes >20 CompactRow items on a phone '
    'viewport so GlobalKeyDetector (strict >20) actually fires',
    (tester) async {
      tester.view.physicalSize = phoneBodySize * tester.view.devicePixelRatio;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const MaterialApp(home: GlobalKeyDemo()));
      await tester.pumpAndSettle();

      // Count every CompactRow actually mounted under the ListView in
      // the bad path. Each CompactRow carries one GlobalKey, so this is
      // a faithful proxy for the count GlobalKeyDetector would see.
      final realizedRows = find.byType(CompactRow);
      expect(
        realizedRows,
        findsAtLeast(21),
        reason:
            'GlobalKeyDetector uses strict >20 (threshold=20), so the '
            'demo must realize at least 21 keyed rows to fire. '
            'Realized count was ${realizedRows.evaluate().length}.',
      );

      // Every realized row must carry a GlobalKey in the bad path —
      // otherwise GlobalKeyDetector would skip it during counting.
      for (final element in realizedRows.evaluate()) {
        expect(
          element.widget.key,
          isA<GlobalKey>(),
          reason:
              'Bad-path CompactRow must carry a GlobalKey, '
              'not ${element.widget.key.runtimeType}',
        );
      }
    },
  );
}
