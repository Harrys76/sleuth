// Hermetic reproducer for [ImageMemoryDetector].
//
// Cited by `ImageMemoryDetector.validationMetadata.reproducerPath` as the
// single-file evidence supporting the detector's
// `EvidenceTier.reproducerOnly` claim (v0.16.3 per-detector validation
// milestone). Covers the `uncached_images` stable-id family.
//
// The detector is a pure structural scan over the element tree — no VM
// timeline, no decode dependency. It triggers when:
//   1. widget is Image (or DecoratedBox with BoxDecoration.image)
//   2. provider is NOT a ResizeImage
//   3. render-object size is NOT within the 50dp×50dp small-image skip
//      (zero / unconstrained sizes are treated as NOT small so they still
//      fire — a 0-size Image almost always means the parent forgot to
//      constrain it, which is the bug we want surfaced)
//
// Boundary triad:
//   - 40×40 (below)  → _isSmallImage returns true → NO fire
//   - 51×51 (at)     → above 50dp threshold → fires
//   - 100×100 (above) → fires
//
// Plus: ResizeImage wrapper at any size suppresses; and a zero-size
// unconstrained Image still fires (documents the "zero is not small"
// policy the detector's docstring commits to).

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/image_memory_detector.dart';

// 1×1 transparent PNG — the minimum-byte real PNG a MemoryImage will
// accept without erroring at decode. Enough to make Image widget happy;
// the detector fires purely on widget shape + RO size, so decode
// completion is irrelevant.
final Uint8List _kTransparentPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, //
  0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, //
  0x78, 0x9C, 0x62, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0xE5, //
  0x27, 0xDE, 0xFC, //
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, //
  0xAE, 0x42, 0x60, 0x82, //
]);

Widget _wrapSized({required double size, required Widget child}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(width: size, height: size, child: child),
    ),
  );
}

void main() {
  group('ImageMemoryDetector reproducer — uncached_images threshold', () {
    late ImageMemoryDetector detector;

    setUp(() {
      detector = ImageMemoryDetector();
    });

    tearDown(() => detector.dispose());

    testWidgets('40×40 Image (below 50dp threshold) does NOT fire', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapSized(
        size: 40,
        child: Image(image: MemoryImage(_kTransparentPng)),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'uncached_images'),
        isEmpty,
        reason: 'images at or below 50dp are suppressed to avoid noise on '
            'icon-sized assets — savings from cacheWidth/cacheHeight are '
            'negligible at this size (< 10 KB).',
      );
    });

    testWidgets('50×50 Image (exactly at threshold) does NOT fire', (
      tester,
    ) async {
      // Boundary contract: `size.width <= 50 && size.height <= 50` is
      // small. Exactly-50 is inclusive of the skip band.
      await tester.pumpWidget(_wrapSized(
        size: 50,
        child: Image(image: MemoryImage(_kTransparentPng)),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'uncached_images'),
        isEmpty,
        reason: 'threshold is inclusive at 50dp.',
      );
    });

    testWidgets('51×51 Image (just above threshold) fires uncached_images', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapSized(
        size: 51,
        child: Image(image: MemoryImage(_kTransparentPng)),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'uncached_images')
          .toList();
      expect(issues, hasLength(1));
      expect(issues.single.title, contains('1 found'));
    });

    testWidgets('100×100 Image (well above threshold) fires uncached_images', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapSized(
        size: 100,
        child: Image(image: MemoryImage(_kTransparentPng)),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'uncached_images')
          .toList();
      expect(issues, hasLength(1));
    });

    testWidgets('100×100 ResizeImage wrapper suppresses (any size)', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapSized(
        size: 100,
        child: Image(
          image: ResizeImage(MemoryImage(_kTransparentPng), width: 100),
        ),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'uncached_images'),
        isEmpty,
        reason: 'ResizeImage wrapping is the documented fix — its presence '
            'suppresses the detector unconditionally.',
      );
    });

    testWidgets('unconstrained (zero-size) Image still fires', (tester) async {
      // Documents the "zero is NOT small" policy: a 0-size Image is
      // almost always a bug (unconstrained parent, not-yet-decoded
      // provider), not a real tiny image — keep firing.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: MemoryImage(_kTransparentPng)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues = detector.issues
          .where((i) => i.stableId == 'uncached_images')
          .toList();
      expect(issues, hasLength(1));
    });
  });
}
