import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/layout_bottleneck_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

void main() {
  group('LayoutBottleneckDetector', () {
    late LayoutBottleneckDetector detector;

    setUp(() {
      detector = LayoutBottleneckDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    testWidgets('flags IntrinsicHeight widget', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('1 intrinsic'));
      expect(detector.issues.first.observationSource,
          ObservationSource.structural);
    });

    testWidgets('flags IntrinsicWidth widget', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicWidth(child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('1 intrinsic'));
    });

    testWidgets('counts multiple intrinsic nodes', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
              IntrinsicWidth(child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('2 intrinsic'));
    });

    testWidgets('stableId, confidence, and category', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.first;
      expect(issue.stableId, 'layout_bottleneck');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.layout);
      expect(issue.severity, IssueSeverity.warning);
    });

    testWidgets('highlights produced per intrinsic node', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
              IntrinsicWidth(child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, hasLength(2));
      expect(detector.highlights.first.detectorName, 'Layout');
    });

    testWidgets('no issues for tree without intrinsics', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              SizedBox(width: 10, height: 10),
              SizedBox(width: 20, height: 20),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    testWidgets('dispose clears issues and highlights', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isNotEmpty);
      expect(detector.highlights, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    // -----------------------------------------------------------------
    // v9.4: Nested intrinsic detection
    // -----------------------------------------------------------------

    testWidgets('nested intrinsics escalated to critical', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(
            child: IntrinsicHeight(
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expect(detector.issues.first.title, contains('Nested'));
    });

    testWidgets('nested intrinsic highlight is critical', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: IntrinsicHeight(
            child: IntrinsicHeight(
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, hasLength(2));
      // Outer = warning, inner = critical
      final severities = detector.highlights.map((h) => h.severity).toList();
      expect(severities, contains(IssueSeverity.critical));
      expect(severities, contains(IssueSeverity.warning));
    });

    testWidgets('mixed nested and non-nested reports critical', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              IntrinsicHeight(
                child: IntrinsicHeight(
                  child: SizedBox(width: 10, height: 10),
                ),
              ),
              IntrinsicWidth(child: SizedBox(width: 10, height: 10)),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expect(detector.issues.first.title, contains('3 intrinsic'));
    });
  });
}
