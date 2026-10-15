// The bad gallery fills a short list on its own, so its load-on-scroll has
// something to scroll, and stops after a bounded number of pages. The
// payloads come from an endpoint that serves the full page size.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:example/demos/network_stress_demo.dart';

void main() {
  late List<String> fetched;

  Future<int> fakeFetch(String url) async {
    fetched.add(url);
    return int.parse(Uri.parse(url).queryParameters['bytes'] ?? '0');
  }

  Future<void> openGallery(
    WidgetTester tester, {
    Size size = const Size(390, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: NetworkStressDemo(fetchBytes: fakeFetch)),
    );
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
  }

  setUp(() => fetched = []);

  Future<void> pull(WidgetTester tester) async {
    await tester.fling(
      find.byType(RefreshIndicator),
      const Offset(0, 800),
      1000,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('on a tall list a pull loads one page and then 3 more', (
    tester,
  ) async {
    await openGallery(tester);
    await pull(tester);

    expect(fetched, hasLength(4));
    expect(
      fetched,
      everyElement('https://speed.cloudflare.com/__down?bytes=1100000'),
    );
    expect(find.text('Photo #4'), findsOneWidget);
    expect(find.text('1074.2 KiB'), findsWidgets);

    // Nothing more loads on its own.
    await tester.pump(const Duration(seconds: 1));
    expect(fetched, hasLength(4));
  });

  testWidgets('the fill stops once the list can scroll, and scrolling to '
      'the end loads the next page', (tester) async {
    await openGallery(tester, size: const Size(390, 844));
    await pull(tester);

    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(RefreshIndicator),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(position.maxScrollExtent, greaterThan(0));
    final filled = fetched.length;
    expect(filled, inInclusiveRange(2, 4));

    await tester.drag(find.byType(RefreshIndicator), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(fetched.length, greaterThan(filled));
  });

  testWidgets('a second pull starts a new fill', (tester) async {
    await openGallery(tester);
    await pull(tester);
    await pull(tester);
    expect(fetched, hasLength(8));
  });

  testWidgets('the fixed gallery loads only from its button', (tester) async {
    await openGallery(tester);
    await tester.tap(find.text('Fixed Pattern'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load next page'));
    await tester.pumpAndSettle();

    expect(fetched, ['https://speed.cloudflare.com/__down?bytes=200000']);
  });
}
