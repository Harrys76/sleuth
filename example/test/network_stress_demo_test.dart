// The bad gallery fills a short list on its own until it can scroll, so
// its load-on-scroll has something to scroll, and stops after a bounded
// number of pages. The payloads come from an endpoint that serves the full
// page size.

import 'dart:io';

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

  ScrollPosition galleryPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(RefreshIndicator),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  testWidgets('on a tall list a pull loads one page and then up to 10 more', (
    tester,
  ) async {
    await openGallery(tester);
    await pull(tester);

    expect(fetched, hasLength(11));
    expect(
      fetched,
      everyElement('https://speed.cloudflare.com/__down?bytes=1100000'),
    );
    expect(find.text('1074.2 KiB'), findsWidgets);
    expect(galleryPosition(tester).maxScrollExtent, 0);
    expect(find.text('Pull down to load again.'), findsOneWidget);

    // Nothing more loads on its own.
    await tester.pump(const Duration(seconds: 1));
    expect(fetched, hasLength(11));
  });

  testWidgets('with the instructions collapsed the fill runs until the list '
      'can scroll, and scrolling to the end loads the next page', (
    tester,
  ) async {
    await openGallery(tester, size: const Size(360, 800));
    await tester.tap(find.text('Instructions'));
    await tester.pumpAndSettle();
    await pull(tester);

    expect(galleryPosition(tester).maxScrollExtent, greaterThan(0));
    final filled = fetched.length;
    expect(filled, inInclusiveRange(5, 11));

    await tester.drag(find.byType(RefreshIndicator), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(fetched.length, greaterThan(filled));
  });

  testWidgets(
    'on iOS a pull on a list that cannot scroll is a refresh, not a scroll '
    'to the end',
    (tester) async {
      await openGallery(tester);
      await pull(tester);
      expect(fetched, hasLength(11));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('a second pull starts a new fill', (tester) async {
    await openGallery(tester);
    await pull(tester);
    await pull(tester);
    expect(fetched, hasLength(22));
  });

  testWidgets('at the request cap the gallery keeps its pages and offers no '
      'retry', (tester) async {
    await openGallery(tester);
    for (var i = 0; i < 3; i++) {
      await pull(tester);
    }
    expect(fetched, hasLength(30));
    expect(find.textContaining('All 30 requests used'), findsOneWidget);
    expect(find.text('Retry page'), findsNothing);
    expect(find.text('Photo #8'), findsOneWidget);

    await pull(tester);
    expect(fetched, hasLength(30));
    expect(find.text('Photo #8'), findsOneWidget);
  });

  testWidgets('an HTTP error shows its status and a retry', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: NetworkStressDemo(
          fetchBytes: (url) async => throw const HttpException('HTTP 429'),
        ),
      ),
    );
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixed Pattern'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load next page'));
    await tester.pumpAndSettle();

    expect(find.textContaining('429 (rate limited)'), findsOneWidget);
    expect(find.text('Retry page'), findsOneWidget);
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
