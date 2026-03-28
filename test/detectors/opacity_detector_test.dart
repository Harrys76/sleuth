import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/opacity_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

void main() {
  group('OpacityDetector', () {
    late OpacityDetector detector;

    setUp(() {
      detector = OpacityDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(opacity: 0.0, child: SizedBox()),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty);
    });

    testWidgets('flags Opacity with opacity 0.0', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(opacity: 0.0, child: SizedBox()),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isNotEmpty);
      expect(
        detector.issues.first.title,
        contains('Invisible Opacity Widgets Still Active'),
      );
      expect(detector.issues.first.observationSource,
          ObservationSource.structural);
      expect(detector.issues.first.fixHint, contains('Visibility'));
      expect(detector.issues.first.detail, contains('hit testing'));
    });

    testWidgets('no issues for Opacity with non-zero opacity', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(opacity: 0.5, child: SizedBox()),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty);
    });

    testWidgets('no issues for fully opaque widget', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(opacity: 1.0, child: SizedBox()),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty);
    });

    testWidgets('counts multiple Opacity(0.0) widgets', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Opacity(opacity: 0.0, child: SizedBox()),
              Opacity(opacity: 0.0, child: SizedBox()),
              Opacity(opacity: 0.5, child: SizedBox()),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains(': 2'));
    });

    testWidgets('highlights align with issues', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Opacity(opacity: 0.0, child: SizedBox(width: 10, height: 10)),
              Opacity(opacity: 0.0, child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      // Issues are generated — highlights must also be present
      expect(detector.issues, isNotEmpty);
      expect(detector.highlights, isNotEmpty);
      // One highlight per Opacity(0.0) widget found
      expect(detector.highlights.length, 2);
      expect(detector.highlights.first.detectorName, 'Opacity');
    });

    testWidgets('no highlights when no issues', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(opacity: 1.0, child: SizedBox()),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    test('dispose clears issues and highlights', () {
      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });
  });
}
