import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/image_memory_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/decoded_image_helpers.dart';

/// A copy of [bytes] that decodes as its own image cache entry
/// (`MemoryImage` keys on the byte buffer).
Uint8List _copy(Uint8List bytes) => Uint8List.fromList(bytes);

/// Images in a non-scrolling, wrapping layout under the test view.
Widget _page(List<Widget> images) => Directionality(
  textDirection: TextDirection.ltr,
  child: Align(
    alignment: Alignment.topLeft,
    child: Wrap(children: images),
  ),
);

/// `Image` over a [MemoryImage] displayed at [dp] x [dp] logical pixels.
Widget _image(
  Uint8List bytes,
  double dp, {
  BoxFit? fit,
  Rect? centerSlice,
  ImageRepeat repeat = ImageRepeat.noRepeat,
  bool excludeFromSemantics = false,
  ImageFrameBuilder? frameBuilder,
  ImageLoadingBuilder? loadingBuilder,
}) => Image(
  image: MemoryImage(bytes),
  width: dp,
  height: dp,
  fit: fit,
  centerSlice: centerSlice,
  repeat: repeat,
  excludeFromSemantics: excludeFromSemantics,
  frameBuilder: frameBuilder,
  loadingBuilder: loadingBuilder,
);

void main() {
  group('ImageMemoryDetector', () {
    late ImageMemoryDetector detector;

    setUp(() {
      detector = ImageMemoryDetector();
    });

    void scan(WidgetTester tester) =>
        detector.scanTree(tester.element(find.byType(Directionality).first));

    PerformanceIssue? issue() => detector.issues
        .where((i) => i.stableId == 'uncached_images')
        .firstOrNull;

    testWidgets('flutter_tester renders at a device pixel ratio of 3.0 by '
        'default', (tester) async {
      expect(tester.view.devicePixelRatio, 3.0);
    });

    group('measured rule @ 2x', () {
      testWidgets('one 400 px image at 100 dp: ratio 2.0, 480 KB wasted, '
          'below the 1 MiB total, silent', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 400, height: 400);
        await pumpDecoded(tester, _page([_image(bytes, 100)]));
        scan(tester);

        final img = detector.uncachedImages.single;
        expect(img.ratio, 2.0);
        expect(img.wastedBytes, (160000 - 40000) * 4);
        expect(img.decodedWidth, 400);
        expect(img.displayedWidth, 100);
        expect(img.devicePixelRatio, 2.0);
        expect(issue(), isNull);
        expect(detector.highlights, isEmpty);
      });

      testWidgets('three 400 px images at 100 dp: 1.4 MB total, warning '
          'listing 3', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 400, height: 400);
        await pumpDecoded(
          tester,
          _page([for (var i = 0; i < 3; i++) _image(_copy(bytes), 100)]),
        );
        scan(tester);

        final found = issue()!;
        expect(found.severity, IssueSeverity.warning);
        expect(found.confidence, IssueConfidence.likely);
        expect(found.observationSource, ObservationSource.structural);
        expect(found.category, IssueCategory.memory);
        expect(found.title, contains('3 decoded above display size'));
        expect(found.title, contains('worst 2.0×'));
        expect(found.title, contains('~1.4 MB wasted'));
        expect(
          'decoded 400×400 px, shown at 100×100 dp @ 2x'
              .allMatches(found.detail)
              .length,
          3,
        );
        expect(detector.highlights, hasLength(3));
        expect(detector.highlights.first.detail, contains('MemoryImage'));
      });

      testWidgets('1200 px at 100 dp: ratio 6, 5.6 MB, warning', (
        tester,
      ) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await pumpDecoded(tester, _page([_image(bytes, 100)]));
        scan(tester);

        final found = issue()!;
        expect(found.severity, IssueSeverity.warning);
        expect(found.title, contains('worst 6.0×'));
        expect(detector.uncachedImages.single.wastedBytes, 5600000);
      });

      testWidgets('four 2048 px images at 100 dp: 66 MB, critical', (
        tester,
      ) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 2048, height: 2048);
        await pumpDecoded(
          tester,
          _page([for (var i = 0; i < 4; i++) _image(_copy(bytes), 100)]),
        );
        scan(tester);

        final found = issue()!;
        expect(found.severity, IssueSeverity.critical);
        expect(found.title, contains('4 decoded'));
      });

      testWidgets('600 px at 200 dp: ratio 1.5 qualifies, 800 KB alone is '
          'silent', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 600, height: 600);
        await pumpDecoded(tester, _page([_image(bytes, 200)]));
        scan(tester);

        final img = detector.uncachedImages.single;
        expect(img.ratio, 1.5);
        expect(img.wastedBytes, 800000);
        expect(issue(), isNull);
      });

      testWidgets('560 px at 200 dp: ratio 1.4 never qualifies, even with '
          '10 copies', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 560, height: 560);
        await pumpDecoded(
          tester,
          _page([for (var i = 0; i < 10; i++) _image(bytes, 200)]),
        );
        scan(tester);

        expect(detector.uncachedImages, isEmpty);
        expect(issue(), isNull);
      });

      testWidgets('BoxFit.cover crop of 1600x400 in a 200 dp box: smaller '
          'axis ratio 1.0, silent', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1600, height: 400);
        await pumpDecoded(
          tester,
          _page([_image(bytes, 200, fit: BoxFit.cover)]),
        );
        scan(tester);

        expect(detector.uncachedImages, isEmpty);
        expect(issue(), isNull);
      });

      testWidgets('seven oversized images produce one issue', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await pumpDecoded(
          tester,
          _page([for (var i = 0; i < 7; i++) _image(_copy(bytes), 50)]),
        );
        scan(tester);

        expect(
          detector.issues.where((i) => i.stableId == 'uncached_images'),
          hasLength(1),
        );
        expect(issue()!.title, contains('7 decoded'));
        // Detail lists the top 5 by wasted bytes.
        expect('decoded 1200×1200 px'.allMatches(issue()!.detail).length, 5);
      });

      testWidgets('extraTraceArgs carry imageCount, worstRatio, wastedBytes', (
        tester,
      ) async {
        setDevicePixelRatio(tester, 2.0);
        final big = await pngBytes(tester, width: 1200, height: 1200);
        final small = await pngBytes(tester, width: 400, height: 400);
        await pumpDecoded(
          tester,
          _page([_image(big, 100), _image(small, 100)]),
        );
        scan(tester);

        expect(issue()!.extraTraceArgs, {
          'imageCount': '2',
          'widgetCount': '2',
          'worstRatio': '6.00',
          'wastedBytes': '${5600000 + 480000}',
        });
      });
    });

    group('images whose decode cannot simply shrink are skipped', () {
      late Uint8List bytes;

      Future<void> expectSilent(WidgetTester tester, Widget image) async {
        await pumpDecoded(tester, _page([image]));
        scan(tester);
        expect(detector.uncachedImages, isEmpty);
        expect(issue(), isNull);
      }

      testWidgets('BoxFit.none', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        bytes = await pngBytes(tester, width: 2000, height: 2000);
        await expectSilent(tester, _image(bytes, 100, fit: BoxFit.none));
      });

      testWidgets('centerSlice (nine-patch)', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        bytes = await pngBytes(tester, width: 2000, height: 2000);
        await expectSilent(
          tester,
          _image(
            bytes,
            100,
            centerSlice: const Rect.fromLTWH(10, 10, 1980, 1980),
          ),
        );
      });

      testWidgets('ImageRepeat.repeat', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        bytes = await pngBytes(tester, width: 2000, height: 2000);
        await expectSilent(
          tester,
          _image(bytes, 100, repeat: ImageRepeat.repeat),
        );
      });

      testWidgets('ResizeImage provider', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        bytes = await pngBytes(tester, width: 2000, height: 2000);
        await expectSilent(
          tester,
          Image(
            image: ResizeImage(MemoryImage(bytes), width: 1000),
            width: 100,
            height: 100,
          ),
        );
      });

      testWidgets('BoxDecoration image is not reported (no decoded image '
          'reachable)', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        bytes = await pngBytes(tester, width: 2000, height: 2000);
        await tester.pumpWidget(
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
        scan(tester);
        expect(detector.issues, isEmpty);
        expect(detector.highlights, isEmpty);
      });
    });

    group('decode timing', () {
      testWidgets('not yet decoded is silent; emits once decoded', (
        tester,
      ) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await tester.pumpWidget(_page([_image(bytes, 100)]));
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
        scan(tester);
        expect(detector.issues, isEmpty);

        await decodeImages(tester);
        scan(tester);
        expect(issue(), isNotNull);
      });
    });

    group('pairing', () {
      testWidgets('excludeFromSemantics: true still pairs', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await pumpDecoded(
          tester,
          _page([_image(bytes, 100, excludeFromSemantics: true)]),
        );
        scan(tester);
        expect(issue(), isNotNull);
      });

      testWidgets('frameBuilder wrapper still pairs', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await pumpDecoded(
          tester,
          _page([
            _image(
              bytes,
              100,
              frameBuilder: (_, child, _, _) =>
                  Padding(padding: const EdgeInsets.all(2), child: child),
            ),
          ]),
        );
        scan(tester);
        expect(detector.uncachedImages, hasLength(1));
        expect(issue(), isNotNull);
      });

      testWidgets('a second RawImage under the same Image is not counted', (
        tester,
      ) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await pumpDecoded(
          tester,
          _page([
            _image(
              bytes,
              100,
              frameBuilder: (_, child, _, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [child, child],
              ),
            ),
          ]),
        );
        expect(find.byType(RawImage), findsNWidgets(2));
        scan(tester);
        expect(detector.uncachedImages, hasLength(1));
      });

      testWidgets('a RawImage without a decode leaves the pair open for '
          'the next RawImage', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await pumpDecoded(
          tester,
          _page([
            _image(
              bytes,
              100,
              frameBuilder: (_, child, _, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [const RawImage(width: 10, height: 10), child],
              ),
            ),
          ]),
          expectDecoded: false,
        );
        expect(find.byType(RawImage), findsNWidgets(2));
        scan(tester);
        expect(detector.uncachedImages.single.decodedWidth, 1200);
      });

      testWidgets("an Image inside another Image's loadingBuilder pairs with "
          'the inner one only', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final outer = await pngBytes(tester, width: 2048, height: 2048);
        final inner = await pngBytes(tester, width: 1200, height: 1200);
        await pumpDecoded(
          tester,
          _page([
            _image(
              outer,
              100,
              // Always shows the inner image: the outer RawImage is never
              // built.
              loadingBuilder: (_, _, _) => _image(inner, 100),
            ),
          ]),
        );
        expect(find.byType(Image), findsNWidgets(2));
        expect(find.byType(RawImage), findsOneWidget);
        scan(tester);

        final img = detector.uncachedImages.single;
        expect(img.decodedWidth, 1200);
      });
    });

    group('device pixel ratio', () {
      testWidgets('at the default 3x the same image needs more pixels', (
        tester,
      ) async {
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await pumpDecoded(tester, _page([_image(bytes, 100)]));
        scan(tester);

        final img = detector.uncachedImages.single;
        expect(img.devicePixelRatio, 3.0);
        expect(img.ratio, 4.0);
        expect(img.wastedBytes, (1440000 - 90000) * 4);
      });

      testWidgets('nearest MediaQuery wins over the view', (tester) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await pumpDecoded(
          tester,
          Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(devicePixelRatio: 1.0),
              child: Align(
                alignment: Alignment.topLeft,
                child: _image(bytes, 100),
              ),
            ),
          ),
        );
        scan(tester);
        expect(detector.uncachedImages.single.devicePixelRatio, 1.0);
      });

      testWidgets('without a MediaQuery the root RenderView ratio is used', (
        tester,
      ) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await tester.pumpWidget(
          RawView(
            view: tester.view,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: _image(bytes, 100),
              ),
            ),
          ),
          wrapWithView: false,
        );
        expect(find.byType(MediaQuery), findsNothing);
        await decodeImages(tester);
        scan(tester);
        expect(detector.uncachedImages.single.devicePixelRatio, 2.0);
      });

      testWidgets('with neither a MediaQuery nor a RenderView the pair is '
          'not measured', (tester) async {
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        final provider = MemoryImage(bytes);
        await pumpDecoded(
          tester,
          _page([Image(image: provider, width: 100, height: 100)]),
        );

        // A tree built off screen: its render root is not a RenderView.
        final root = RenderPositionedBox(alignment: Alignment.topLeft);
        final pipelineOwner = PipelineOwner()..rootNode = root;
        final buildOwner = BuildOwner(focusManager: FocusManager());
        final rootElement = RenderObjectToWidgetAdapter<RenderBox>(
          container: root,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Image(image: provider, width: 100, height: 100),
          ),
        ).attachToRenderTree(buildOwner);
        buildOwner.buildScope(rootElement);
        root.layout(BoxConstraints.loose(const Size(800, 600)));
        addTearDown(() {
          buildOwner.finalizeTree();
          pipelineOwner.rootNode = null;
        });

        RawImage? raw;
        void find(Element e) {
          if (e.widget is RawImage) raw = e.widget as RawImage;
          e.visitChildren(find);
        }

        rootElement.visitChildren(find);
        expect(raw?.image, isNotNull, reason: 'decode not delivered');

        detector.scanTree(rootElement);
        expect(detector.uncachedImages, isEmpty);
        expect(detector.issues, isEmpty);
      });

      testWidgets('the scan registers no MediaQuery dependency', (
        tester,
      ) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 1200, height: 1200);
        await pumpDecoded(tester, _page([_image(bytes, 100)]));
        scan(tester);

        final raw = tester.element(find.byType(RawImage));
        final mq =
            tester.element(find.byType(MediaQuery).first) as InheritedElement;
        // ignore: invalid_use_of_protected_member
        expect(raw.doesDependOnInheritedElement(mq), isFalse);
      });
    });

    group('lifecycle', () {
      testWidgets('no issues when disabled', (tester) async {
        detector.isEnabled = false;
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 2048, height: 2048);
        await pumpDecoded(tester, _page([_image(bytes, 100)]));
        scan(tester);
        expect(detector.issues, isEmpty);
      });

      testWidgets('dispose clears issues, highlights, and uncachedImages', (
        tester,
      ) async {
        setDevicePixelRatio(tester, 2.0);
        final bytes = await pngBytes(tester, width: 2048, height: 2048);
        await pumpDecoded(tester, _page([_image(bytes, 100)]));
        scan(tester);
        expect(detector.issues, isNotEmpty);
        expect(detector.highlights, isNotEmpty);
        expect(detector.uncachedImages, isNotEmpty);

        detector.dispose();
        expect(detector.issues, isEmpty);
        expect(detector.highlights, isEmpty);
        expect(detector.uncachedImages, isEmpty);
      });

      test('extractSourceName returns correct names for provider types', () {
        expect(
          ImageMemoryDetector.extractSourceName(const AssetImage('photo.png')),
          'photo.png',
        );
        expect(
          ImageMemoryDetector.extractSourceName(MemoryImage(Uint8List(4))),
          'MemoryImage(4 bytes)',
        );
        expect(
          ImageMemoryDetector.extractSourceName(
            const ExactAssetImage('icon.png'),
          ),
          'icon.png',
        );
      });
    });
  });
}
