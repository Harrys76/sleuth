import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/image_memory_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

// 1x1 transparent PNG bytes for creating test Image widgets.
final Uint8List _kTransparentPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, // RGBA
  0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, // IDAT chunk
  0x78, 0x9C, 0x62, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0xE5,
  0x27, 0xDE, 0xFC,
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND chunk
  0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  group('ImageMemoryDetector', () {
    late ImageMemoryDetector detector;

    setUp(() {
      detector = ImageMemoryDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: MemoryImage(_kTransparentPng)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('flags Image without ResizeImage', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: MemoryImage(_kTransparentPng)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('1 found'));
      expect(detector.issues.first.observationSource,
          ObservationSource.structural);
    });

    testWidgets('no issue when Image uses ResizeImage', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(
            image: ResizeImage(MemoryImage(_kTransparentPng), width: 100),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('counts multiple uncached images', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Image(image: MemoryImage(_kTransparentPng)),
              Image(image: MemoryImage(_kTransparentPng)),
              Image(image: MemoryImage(_kTransparentPng)),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('3 found'));
    });

    testWidgets('warning severity when count <= 5', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              3,
              (_) => Image(image: MemoryImage(_kTransparentPng)),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    testWidgets('critical severity when count > 5', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              6,
              (_) => Image(image: MemoryImage(_kTransparentPng)),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    testWidgets('stableId, confidence, and category', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: MemoryImage(_kTransparentPng)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.first;
      expect(issue.stableId, 'uncached_images');
      expect(issue.confidence, IssueConfidence.possible);
      expect(issue.category, IssueCategory.memory);
    });

    testWidgets('highlights produced per uncached image', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Image(image: MemoryImage(_kTransparentPng)),
              Image(image: MemoryImage(_kTransparentPng)),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, hasLength(2));
      expect(detector.highlights.first.detectorName, 'Image');
    });

    testWidgets('uncachedImages list populated', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: MemoryImage(_kTransparentPng)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.uncachedImages, hasLength(1));
      expect(detector.uncachedImages.first.sourceName, contains('MemoryImage'));
    });

    testWidgets('no highlights when all images use ResizeImage',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(
            image: ResizeImage(MemoryImage(_kTransparentPng), width: 100),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isEmpty);
    });

    testWidgets('highlight detail includes provider type for MemoryImage',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: MemoryImage(_kTransparentPng)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, hasLength(1));
      expect(
          detector.highlights.first.detail, contains('Uncached MemoryImage'));
      expect(detector.highlights.first.detail, contains('ResizeImage'));
    });

    test('extractSourceName returns correct names for provider types', () {
      expect(
        ImageMemoryDetector.extractSourceName(const AssetImage('photo.png')),
        'photo.png',
      );
      expect(
        ImageMemoryDetector.extractSourceName(MemoryImage(_kTransparentPng)),
        contains('MemoryImage'),
      );
      expect(
        ImageMemoryDetector.extractSourceName(
            const ExactAssetImage('icon.png')),
        'icon.png',
      );
    });

    testWidgets('dispose clears issues, highlights, and uncachedImages',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: MemoryImage(_kTransparentPng)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isNotEmpty);
      expect(detector.highlights, isNotEmpty);
      expect(detector.uncachedImages, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
      expect(detector.uncachedImages, isEmpty);
    });

    // -----------------------------------------------------------------
    // v10.3: DecorationImage in BoxDecoration detection
    // -----------------------------------------------------------------

    group('DecorationImage detection', () {
      testWidgets('flags DecoratedBox with DecorationImage without ResizeImage',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: DecoratedBox(
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: MemoryImage(_kTransparentPng),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'uncached_images');
        expect(detector.uncachedImages, hasLength(1));
      });

      testWidgets(
          'no issue for DecoratedBox with DecorationImage using ResizeImage',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: DecoratedBox(
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: ResizeImage(
                    MemoryImage(_kTransparentPng),
                    width: 100,
                  ),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isEmpty);
        expect(detector.uncachedImages, isEmpty);
      });

      testWidgets('no issue for DecoratedBox without image', (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: DecoratedBox(
              decoration: BoxDecoration(color: Color(0xFFFF0000)),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isEmpty);
        expect(detector.uncachedImages, isEmpty);
      });

      testWidgets('highlight widgetName is DecoratedBox for decoration images',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: DecoratedBox(
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: MemoryImage(_kTransparentPng),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.highlights, hasLength(1));
        expect(detector.highlights.first.widgetName, 'DecoratedBox');
      });

      testWidgets(
          'mixed Image widgets and DecoratedBox images are counted together',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                Image(image: MemoryImage(_kTransparentPng)),
                SizedBox(
                  width: 100,
                  height: 100,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      image: DecorationImage(
                        image: MemoryImage(_kTransparentPng),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('2 found'));
        expect(detector.uncachedImages, hasLength(2));
        expect(detector.highlights, hasLength(2));
      });
    });

    // -----------------------------------------------------------------
    // v11.9: Small image suppression
    // -----------------------------------------------------------------

    group('small image suppression', () {
      // Center converts the root's tight viewport constraints to loose
      // constraints, allowing SizedBox to apply the intended size.
      testWidgets('small image (24x24) not flagged', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: Image(image: MemoryImage(_kTransparentPng)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isEmpty,
            reason: 'Small images (<= 50px) should be suppressed');
      });

      testWidgets('image at boundary (50x50) not flagged', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 50,
                height: 50,
                child: Image(image: MemoryImage(_kTransparentPng)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isEmpty,
            reason: '50x50 is at threshold — should be suppressed');
      });

      testWidgets('large image (300x300) still flagged', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 300,
                height: 300,
                child: Image(image: MemoryImage(_kTransparentPng)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1),
            reason: 'Large images should still be flagged');
      });

      testWidgets('image at 51x51 still flagged', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 51,
                height: 51,
                child: Image(image: MemoryImage(_kTransparentPng)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1),
            reason: '51x51 is above threshold — should be flagged');
      });

      testWidgets('small DecoratedBox image also suppressed', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 40,
                height: 40,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: MemoryImage(_kTransparentPng),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isEmpty,
            reason: 'Small DecoratedBox images should also be suppressed');
      });
    });
  });
}
