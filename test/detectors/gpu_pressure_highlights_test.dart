import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/gpu_pressure_detector.dart';

void main() {
  group('GpuPressureDetector highlights', () {
    late GpuPressureDetector detector;

    setUp(() {
      detector = GpuPressureDetector();
    });

    testWidgets('produces highlights with GPU detectorName for expensive nodes',
        (tester) async {
      await tester.pumpWidget(const _OpacityDeepTree());
      detector.scanTree(tester.element(find.byType(Directionality)));

      // Opacity with >5 descendants must produce highlights
      expect(detector.highlights, isNotEmpty,
          reason: 'RenderOpacity with deep subtree should produce highlights');
      for (final h in detector.highlights) {
        expect(h.detectorName, 'GPU');
      }
    });

    testWidgets('highlights cleared on each scanTree', (tester) async {
      await tester.pumpWidget(const _OpacityDeepTree());
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, isNotEmpty,
          reason: 'First scan should produce highlights');
      final firstScanCount = detector.highlights.length;

      // Second scan clears and repopulates
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isNotEmpty,
          reason: 'Second scan should repopulate highlights');
      // Should be same count (repopulated, not accumulated)
      expect(detector.highlights.length, firstScanCount);
    });

    test('highlights cleared on dispose', () {
      detector.dispose();
      expect(detector.highlights, isEmpty);
    });

    testWidgets('no highlights when detector disabled', (tester) async {
      detector.isEnabled = false;

      await tester.pumpWidget(const _OpacityDeepTree());
      detector.scanTree(tester.element(find.byType(_OpacityDeepTree)));

      expect(detector.highlights, isEmpty);
    });

    testWidgets('no highlights for simple tree without expensive nodes',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 10, height: 10),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, isEmpty);
    });
  });
}

/// Widget tree with Opacity wrapping many descendants to trigger detection.
class _OpacityDeepTree extends StatelessWidget {
  const _OpacityDeepTree();

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Opacity(
        opacity: 0.5,
        child: Column(
          children: List.generate(
            10,
            (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
          ),
        ),
      ),
    );
  }
}
