// The device harness's tap, type, scroll and fling target what a finger
// would reach: the current route over the ones below, the shown
// IndexedStack tab, an overlay page over the app, a demo's body over its
// instruction header, and the focused field first.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:example/demo_scaffold.dart';
import 'package:example/harness_targeting.dart';

void main() {
  /// Pumps frames until [future] completes, within 5 s of fake time.
  Future<T> pumpUntilDone<T>(WidgetTester tester, Future<T> future) async {
    T? value;
    var done = false;
    unawaited(
      future.then((v) {
        value = v;
        done = true;
      }),
    );
    for (var i = 0; i < 100 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done, isTrue, reason: 'did not complete');
    return value as T;
  }

  /// [count] 50 px rows labelled `<prefix> row <i>`.
  List<Widget> rows(String prefix, int count) => [
    for (var i = 0; i < count; i++)
      SizedBox(height: 50, child: Text('$prefix row $i')),
  ];

  /// The [ScrollableState] built by the scroll view keyed [key].
  ScrollableState scrollableOf(WidgetTester tester, Key key) =>
      tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(key, skipOffstage: false),
          matching: find.byType(Scrollable, skipOffstage: false),
        ),
      );

  /// An app list with a full-screen page laid over it in a Stack after the
  /// app, as Sleuth's overlay sits over the app it tracks.
  Widget appUnderPage({required Widget app, required Widget page}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            app,
            Positioned.fill(
              child: ColoredBox(color: Colors.white, child: page),
            ),
          ],
        ),
      );

  group('routes', () {
    testWidgets('the current route wins over a covered copy of its label', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Center(child: Text('Open'))),
        ),
      );
      final home = tester.element(find.text('Open'));
      expect(findText('Open'), same(home));

      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('Open'))),
        ),
      );
      await tester.pumpAndSettle();
      final pushed = tester.element(find.text('Open'));
      expect(home.mounted, isTrue);
      expect(isForeground(home), isFalse);
      expect(findText('Open'), same(pushed));
    });

    testWidgets('a page under a dialog is not a target', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: ListView(
              key: const ValueKey('page'),
              children: rows('P', 40),
            ),
          ),
        ),
      );
      final page = tester.element(find.text('P row 1'));
      expect(isForeground(page), isTrue);

      showDialog<void>(
        context: navigatorKey.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Dialog')),
      );
      await tester.pumpAndSettle();
      // The page stays onstage under a dialog; its route is not current.
      expect(find.text('P row 1'), findsOneWidget);
      expect(isForeground(page), isFalse);
      expect(findText('P row 1'), isNull);
      expect(findText('Dialog'), isNotNull);
      expect(findScrollable(horizontal: false), isNull);
    });
  });

  testWidgets('a hidden IndexedStack tab is not a target', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IndexedStack(
            index: 0,
            children: [
              ListView(key: const ValueKey('a'), children: rows('Tab', 40)),
              ListView(key: const ValueKey('b'), children: rows('Tab', 40)),
            ],
          ),
        ),
      ),
    );
    final shown = scrollableOf(tester, const ValueKey('a'));
    final label = findText('Tab row 2');
    expect(label, isNotNull);
    expect(label!.findAncestorStateOfType<ScrollableState>(), same(shown));
    // Same size, and the hidden tab comes later in the tree.
    expect(findScrollable(horizontal: false), same(shown));
  });

  group('overlay page over the app', () {
    testWidgets('the page copy of a label wins; the app copy is obscured', (
      tester,
    ) async {
      await tester.pumpWidget(
        appUnderPage(
          app: const MaterialApp(
            home: Scaffold(
              body: Column(children: [Text('Settings'), Text('Behind')]),
            ),
          ),
          page: const Column(children: [Text('Settings'), Text('Front')]),
        ),
      );
      final settings = findText('Settings');
      expect(settings, same(tester.element(find.text('Settings').last)));

      // The app's label is in the foreground route, but the page takes
      // any touch at its centre.
      final behind = findText('Behind')!;
      final refused = await pumpUntilDone(tester, prepareTap(behind));
      expect(refused.position, isNull);
      expect(refused.error, 'obscured');

      final front = await pumpUntilDone(tester, prepareTap(findText('Front')!));
      expect(front.error, isNull);
      expect(front.position, tester.getCenter(find.text('Front')));
    });

    testWidgets('scroll drives the page list, not the larger app list', (
      tester,
    ) async {
      await tester.pumpWidget(
        appUnderPage(
          app: MaterialApp(
            home: Scaffold(
              body: ListView(
                key: const ValueKey('app'),
                children: rows('App', 60),
              ),
            ),
          ),
          page: Center(
            child: SizedBox(
              width: 300,
              height: 200,
              child: ListView(
                key: const ValueKey('page'),
                children: rows('Page', 30),
              ),
            ),
          ),
        ),
      );
      expect(
        findScrollable(horizontal: false),
        same(scrollableOf(tester, const ValueKey('page'))),
      );
    });

    testWidgets('type skips a field behind the page', (tester) async {
      await tester.pumpWidget(
        appUnderPage(
          app: const MaterialApp(home: Scaffold(body: TextField())),
          page: const SizedBox.expand(),
        ),
      );
      expect(findTypingTarget(), isNull);
    });
  });

  testWidgets('scroll skips the demo header for the body list', (tester) async {
    tester.view.physicalSize = const Size(683, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: DemoScaffold(
          title: 'Demo',
          description: List.filled(30, 'A long instruction line.').join(' '),
          // Narrower than the header, which would win on area alone.
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: ListView(
              key: const ValueKey('body'),
              children: rows('Body', 40),
            ),
          ),
        ),
      ),
    );
    final header = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(DemoScaffold.headerKey),
        matching: find.byType(Scrollable),
      ),
    );
    expect(header.position.maxScrollExtent, greaterThan(0));
    expect(
      findScrollable(horizontal: false),
      same(scrollableOf(tester, const ValueKey('body'))),
    );
  });

  testWidgets('type writes to the focused field, else the last one', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(key: ValueKey('first')),
              TextField(key: ValueKey('second')),
            ],
          ),
        ),
      ),
    );
    EditableTextState fieldOf(String key) => tester.state<EditableTextState>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(EditableText),
      ),
    );

    expect(findTypingTarget(), same(fieldOf('second')));
    await tester.tap(find.byKey(const ValueKey('first')));
    await tester.pump();
    expect(findTypingTarget(), same(fieldOf('first')));
  });

  testWidgets('a reveal that never finishes is refused, not tapped late', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // Muted tickers, as a covered route has: the reveal's scroll
          // animation never advances.
          body: TickerMode(
            enabled: false,
            child: SingleChildScrollView(
              child: Column(children: rows('Muted', 60)),
            ),
          ),
        ),
      ),
    );
    final element = findText('Muted row 40');
    expect(element, isNotNull);
    final result = await pumpUntilDone(tester, prepareTap(element!));
    expect(result.error, 'reveal_timeout');
    await tester.pumpWidget(const SizedBox());
  });
}
