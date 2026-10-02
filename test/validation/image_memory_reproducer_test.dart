// Hermetic reproducer for [ImageMemoryDetector].
//
// Cited by `ImageMemoryDetector.validationMetadata.reproducerPath` as the
// single-file evidence supporting the detector's
// `EvidenceTier.reproducerOnly` claim for `uncached_images`.
//
// Every image is a real engine-encoded PNG shown through `Image` over a
// `MemoryImage`, decoded with `precacheImage` inside `runAsync`, at an
// explicit device pixel ratio of 2.0. The rule:
//
//   needed  = display box (dp) × dpr, per axis
//   ratio   = min(decodedW / neededW, decodedH / neededH)
//   wasted  = (decodedW × decodedH − neededW × neededH) × 4 bytes
//
//   - an image qualifies when ratio >= 1.5 (min, so a BoxFit.cover crop in
//     one axis is not waste);
//   - the issue emits when qualifying images waste >= 1 MiB in total;
//   - severity is critical at >= 16 MiB in total, else warning.
//
// Boundaries pinned below:
//   - ratio: 560 px at 200 dp (1.4) never qualifies; 600 px (1.5) does.
//   - total: two 400 px images at 100 dp (960,000 B) silent; three
//     (1,440,000 B) fire.
//   - severity: one 2048 px image at 100 dp (16,617,216 B) is a warning;
//     two (33,234,432 B) are critical.
//
// Skips: ResizeImage providers, BoxFit.none, centerSlice, repeat, an image
// not yet decoded (first scan silent, fires after decode), and
// BoxDecoration images (no decoded image reachable).

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/image_memory_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/decoded_image_helpers.dart';
import '_helpers/structural_reproducer_harness.dart';

Widget _page(List<Widget> images) => Align(
  alignment: Alignment.topLeft,
  child: Wrap(children: images),
);

Widget _image(
  Uint8List bytes,
  double dp, {
  BoxFit? fit,
  Rect? centerSlice,
  ImageRepeat repeat = ImageRepeat.noRepeat,
}) => Image(
  image: MemoryImage(bytes),
  width: dp,
  height: dp,
  fit: fit,
  centerSlice: centerSlice,
  repeat: repeat,
);

/// Mounts [images], decodes them, and returns the issues of a scan over
/// the decoded tree.
Future<List<PerformanceIssue>> _scanDecoded(
  WidgetTester tester,
  ImageMemoryDetector detector,
  List<Widget> images,
) async {
  await scanAndIssues(tester, detector, _page(images));
  await decodeImages(tester);
  return rescanIssues(tester, detector);
}

void main() {
  group('ImageMemoryDetector reproducer — uncached_images measured rule', () {
    late ImageMemoryDetector detector;

    setUp(() {
      detector = ImageMemoryDetector();
    });

    tearDown(() => detector.dispose());

    testWidgets('ratio 1.4 (560 px at 200 dp) never qualifies, 10 copies '
        'silent', (tester) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 560, height: 560);
      final issues = await _scanDecoded(tester, detector, [
        for (var i = 0; i < 10; i++) _image(bytes, 200),
      ]);
      expect(issues, lacksStableId('uncached_images'));
      expect(detector.uncachedImages, isEmpty);
    });

    testWidgets('ratio 1.5 (600 px at 200 dp) qualifies; two images '
        '(1.6 MB) fire', (tester) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 600, height: 600);
      final issues = await _scanDecoded(tester, detector, [
        _image(bytes, 200),
        _image(bytes, 200),
      ]);
      expect(issues, hasStableId('uncached_images'));
    });

    testWidgets('total below 1 MiB (two 400 px at 100 dp) silent', (
      tester,
    ) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 400, height: 400);
      final issues = await _scanDecoded(tester, detector, [
        _image(bytes, 100),
        _image(bytes, 100),
      ]);
      expect(detector.uncachedImages, hasLength(2));
      expect(issues, lacksStableId('uncached_images'));
    });

    testWidgets('total above 1 MiB (three 400 px at 100 dp) fires as a '
        'likely warning', (tester) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 400, height: 400);
      final issues = await _scanDecoded(tester, detector, [
        for (var i = 0; i < 3; i++) _image(bytes, 100),
      ]);
      final issue = issues.singleWhere((i) => i.stableId == 'uncached_images');
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.extraTraceArgs?['wastedBytes'], '1440000');
    });

    testWidgets('one 2048 px image at 100 dp (just under 16 MiB) is a '
        'warning', (tester) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 2048, height: 2048);
      final issues = await _scanDecoded(tester, detector, [_image(bytes, 100)]);
      final issue = issues.singleWhere((i) => i.stableId == 'uncached_images');
      expect(issue.severity, IssueSeverity.warning);
    });

    testWidgets('two 2048 px images at 100 dp (over 16 MiB) are critical', (
      tester,
    ) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 2048, height: 2048);
      final issues = await _scanDecoded(tester, detector, [
        _image(bytes, 100),
        _image(bytes, 100),
      ]);
      final issue = issues.singleWhere((i) => i.stableId == 'uncached_images');
      expect(issue.severity, IssueSeverity.critical);
    });

    testWidgets('BoxFit.cover crop whose smaller axis matches the box '
        'silent', (tester) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 1600, height: 400);
      final issues = await _scanDecoded(tester, detector, [
        for (var i = 0; i < 3; i++) _image(bytes, 200, fit: BoxFit.cover),
      ]);
      expect(issues, lacksStableId('uncached_images'));
    });

    testWidgets('BoxFit.none, centerSlice, and repeat silent', (tester) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 2000, height: 2000);
      final issues = await _scanDecoded(tester, detector, [
        _image(bytes, 100, fit: BoxFit.none),
        _image(
          bytes,
          100,
          centerSlice: const Rect.fromLTWH(10, 10, 1980, 1980),
        ),
        _image(bytes, 100, repeat: ImageRepeat.repeat),
      ]);
      expect(issues, lacksStableId('uncached_images'));
    });

    testWidgets('ResizeImage provider silent', (tester) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 2000, height: 2000);
      final issues = await _scanDecoded(tester, detector, [
        Image(
          image: ResizeImage(MemoryImage(bytes), width: 1000),
          width: 100,
          height: 100,
        ),
      ]);
      expect(issues, lacksStableId('uncached_images'));
    });

    testWidgets('not yet decoded silent, then fires after decode', (
      tester,
    ) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 2048, height: 2048);
      final before = await scanAndIssues(
        tester,
        detector,
        _page([_image(bytes, 100)]),
      );
      expect(before, lacksStableId('uncached_images'));

      await decodeImages(tester);
      expect(rescanIssues(tester, detector), hasStableId('uncached_images'));
    });

    testWidgets('BoxDecoration image silent (no decoded image reachable)', (
      tester,
    ) async {
      setDevicePixelRatio(tester, 2.0);
      final bytes = await pngBytes(tester, width: 2000, height: 2000);
      await scanAndIssues(
        tester,
        detector,
        _page([
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              image: DecorationImage(image: MemoryImage(bytes)),
            ),
          ),
        ]),
      );
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(bytes),
          tester.element(find.byType(Container)),
        ),
      );
      await tester.pump();
      expect(rescanIssues(tester, detector), lacksStableId('uncached_images'));
    });
  });
}
