// The Tabbed Shell demo relies on IndexedStack painting exactly one tab;
// Sleuth's structural scan follows the same onstage child. These tests pin
// that the selected index decides which tab's Scaffold is onstage.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderIndexedStack;
import 'package:flutter_test/flutter_test.dart';

import 'package:example/demos/tabbed_shell_demo.dart';

void main() {
  /// The IndexedStack's onstage children, as Sleuth's scan sees them
  /// (the element whose render object is the [RenderIndexedStack]).
  Element onstageChild(WidgetTester tester) {
    final stack = tester.element(
      find.byElementPredicate(
        (e) => e is RenderObjectElement && e.renderObject is RenderIndexedStack,
      ),
    );
    final onstage = <Element>[];
    stack.debugVisitOnstageChildren(onstage.add);
    expect(onstage, hasLength(1));
    return onstage.single;
  }

  bool isUnder(Element node, Element ancestor) {
    var found = identical(node, ancestor);
    node.visitAncestorElements((e) {
      if (identical(e, ancestor)) found = true;
      return !found;
    });
    return found;
  }

  /// The tab Scaffold that contains [text].
  Element tabScaffold(WidgetTester tester, Finder text) => tester.element(
    find
        .ancestor(
          of: text,
          matching: find.byType(Scaffold, skipOffstage: false),
        )
        .first,
  );

  Future<void> pumpDemo(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: TabbedShellDemo()));
    await tester.pump();
  }

  testWidgets('every tab is a Scaffold built inside the IndexedStack', (
    tester,
  ) async {
    await pumpDemo(tester);
    expect(
      find.descendant(
        of: find.byType(IndexedStack),
        matching: find.byType(Scaffold, skipOffstage: false),
        skipOffstage: false,
      ),
      findsNWidgets(3),
    );
    expect(find.byType(IntrinsicHeight, skipOffstage: false), findsNWidgets(8));
  });

  testWidgets('switching the index changes which tab Scaffold is onstage', (
    tester,
  ) async {
    await pumpDemo(tester);

    final listTab = tabScaffold(
      tester,
      find.text('Row 0', skipOffstage: false),
    );
    final imagesTab = tabScaffold(
      tester,
      find.textContaining('uncached_images', skipOffstage: false),
    );
    final layoutTab = tabScaffold(
      tester,
      find.text('Left 0\nTwo lines', skipOffstage: false),
    );

    Future<void> expectOnstage(Element visible) async {
      final child = onstageChild(tester);
      for (final tab in [listTab, imagesTab, layoutTab]) {
        expect(isUnder(tab, child), identical(tab, visible));
      }
    }

    await expectOnstage(listTab);

    await tester.tap(find.text('Images'));
    await tester.pump();
    await expectOnstage(imagesTab);

    await tester.tap(find.text('Layout'));
    await tester.pump();
    await expectOnstage(layoutTab);

    await tester.tap(find.text('List'));
    await tester.pump();
    await expectOnstage(listTab);
  });

  testWidgets('every tab fits a phone in landscape at 2x text', (tester) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const MaterialApp(home: TabbedShellDemo()));
    for (final tab in ['Images', 'Layout', 'List']) {
      await tester.tap(find.text(tab));
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });
}
