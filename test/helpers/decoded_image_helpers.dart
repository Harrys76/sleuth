import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real-decode harness for image tests.
///
/// Images are engine-encoded PNGs ([pngBytes]) shown through
/// `Image.memory`, decoded with [precacheImage] inside
/// [WidgetTester.runAsync] (decoding completes on the engine, outside the
/// fake-async zone), and the device pixel ratio is set explicitly with
/// [setDevicePixelRatio].

/// PNG bytes of a real [width] x [height] image, encoded by the engine.
Future<Uint8List> pngBytes(
  WidgetTester tester, {
  required int width,
  required int height,
}) async {
  final bytes = await tester.runAsync(() async {
    final image = await createTestImage(
      width: width,
      height: height,
      cache: false,
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  });
  return bytes!;
}

/// Sets the test view's device pixel ratio to [dpr] and restores the
/// default when the test ends.
void setDevicePixelRatio(WidgetTester tester, double dpr) {
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Decodes the provider of every [Image] currently in the tree, then pumps
/// so each [RawImage] receives its decoded image.
///
/// With [expectDecoded] (the default), asserts that every [RawImage] in the
/// tree now holds a decoded image, so a later "silent" assertion cannot
/// pass only because nothing was decoded.
Future<void> decodeImages(
  WidgetTester tester, {
  bool expectDecoded = true,
}) async {
  final images = find.byType(Image, skipOffstage: false).evaluate().toList();
  await tester.runAsync(() async {
    for (final element in images) {
      await precacheImage((element.widget as Image).image, element);
    }
  });
  await tester.pump();
  if (expectDecoded) {
    final raws = find.byType(RawImage, skipOffstage: false).evaluate();
    expect(raws, isNotEmpty, reason: 'no RawImage in the tree');
    for (final raw in raws) {
      expect(
        (raw.widget as RawImage).image,
        isNotNull,
        reason: 'RawImage not decoded before the scan',
      );
    }
  }
}

/// Pumps [widget] and decodes every image in it. See [decodeImages].
Future<void> pumpDecoded(
  WidgetTester tester,
  Widget widget, {
  bool expectDecoded = true,
}) async {
  await tester.pumpWidget(widget);
  await decodeImages(tester, expectDecoded: expectDecoded);
}
