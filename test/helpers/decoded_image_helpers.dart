import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// PNG bytes of a real [width] x [height] image, encoded by the engine.
///
/// Runs inside [WidgetTester.runAsync] because image encoding completes on
/// the engine, outside the fake-async zone.
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
