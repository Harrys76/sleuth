// The Cupertino Blur demo shows one panel per filter shape, including
// `ImageFilterConfig` (Flutter 3.41 and later), which package tests on the
// 3.32 floor cannot build. These tests pin the blur sigma Sleuth's reader
// returns for each real filter, and for the framework's own chrome.
//
// The reader is a package internal, so this test imports `src/` on purpose.
// ignore_for_file: implementation_imports

import 'package:example/demos/cupertino_blur_demo.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show RenderBackdropFilter;
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/utils/blur_sigma.dart';

void main() {
  /// The (sigma, enabled) of each BackdropFilter under [owner].
  List<(double?, bool)> filtersUnder(WidgetTester tester, Finder owner) => [
    for (final e
        in find
            .descendant(of: owner, matching: find.byType(BackdropFilter))
            .evaluate())
      (
        maxBlurSigma(e.widget as BackdropFilter),
        (e.renderObject! as RenderBackdropFilter).enabled,
      ),
  ];

  /// A tall view builds every panel; [phone] uses an iPhone 12 screen, on
  /// which the list scrolls under the navigation bar.
  Future<void> pumpDemo(WidgetTester tester, {bool phone = false}) async {
    tester.view.physicalSize = Size(1170, phone ? 2532 : 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CupertinoApp(home: CupertinoBlurDemo()));
    await tester.pump();
  }

  testWidgets('each panel reads its sigma; a matrix composition is unknown', (
    tester,
  ) async {
    await pumpDemo(tester);
    (double?, bool) panel(String label) => filtersUnder(
      tester,
      // The nearest Stack is the panel's own.
      find.ancestor(of: find.text(label), matching: find.byType(Stack)).first,
    ).single;

    expect(panel('Blur sigma 2 (too weak to report)'), (2.0, true));
    expect(panel('Blur sigma 20'), (20.0, true));
    expect(panel('Blur sigma 20 composed with a scale'), (null, true));
    final (composed, composedOn) = panel('Blurs sigma 1 and 2 composed');
    expect(composed, closeTo(2.236, 0.001));
    expect(composedOn, isTrue);
    expect(panel('Configured blur sigma 1.5'), (1.5, true));
    expect(panel('Disabled blur sigma 20'), (20.0, false));
  });

  testWidgets('translucent bars blur at a known sigma; opaque bars switch '
      'their blur off', (tester) async {
    await pumpDemo(tester, phone: true);
    final nav = find.byType(CupertinoNavigationBar);
    final tab = find.byType(CupertinoTabBar);
    // The navigation bar shows its background, and its blur, only once
    // content scrolls under it (`automaticBackgroundVisibility`).
    expect(filtersUnder(tester, nav).single.$2, isFalse);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(filtersUnder(tester, nav), [(10.0, true)]);
    expect(filtersUnder(tester, tab), [(10.0, true)]);

    // Back to the top for the switch, then under the bar again.
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CupertinoSwitch));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    // Opaque bars either keep their filter switched off or build none.
    expect(filtersUnder(tester, nav).where((f) => f.$2), isEmpty);
    expect(filtersUnder(tester, tab).where((f) => f.$2), isEmpty);
  });

  testWidgets('the alert dialog blur reads as its blur sigma', (tester) async {
    await pumpDemo(tester);
    await tester.tap(find.text('Show alert'));
    await tester.pumpAndSettle();
    final dialog = filtersUnder(tester, find.byType(CupertinoAlertDialog));
    expect(dialog, isNotEmpty);
    for (final (sigma, enabled) in dialog) {
      expect(sigma, greaterThan(2));
      expect(enabled, isTrue);
    }
  });
}
