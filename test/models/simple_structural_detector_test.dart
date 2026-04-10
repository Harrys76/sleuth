import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/simple_structural_detector.dart';

/// A minimal subclass that flags every [Placeholder] widget it encounters.
class _PlaceholderDetector extends SimpleStructuralDetector {
  _PlaceholderDetector({super.key})
      : super(
          name: 'Placeholder Detector',
          description: 'Flags every Placeholder widget',
        );

  int inspectCount = 0;
  int prepareCount = 0;
  bool disposed = false;

  @override
  void onPrepareScan(BuildContext context) => prepareCount++;

  @override
  void onDispose() => disposed = true;

  @override
  void inspect(Element element) {
    inspectCount++;
    if (element.widget is Placeholder) {
      report(
        stableId: 'placeholder_${identityHashCode(element)}',
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        title: 'Placeholder in production tree',
        detail: 'Placeholder widgets should be replaced before shipping.',
        fixHint: 'Swap in the real widget.',
        element: element,
      );
    }
  }
}

void main() {
  group('SimpleStructuralDetector', () {
    testWidgets('inspect is called for each element and report emits issues',
        (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            SizedBox(width: 100, height: 100, child: Placeholder()),
            SizedBox(width: 100, height: 100, child: Placeholder()),
            Text('hi'),
          ],
        ),
      ));
      final context = tester.element(find.byType(Directionality));

      final detector = _PlaceholderDetector();
      detector.scanTree(context);

      expect(detector.inspectCount, greaterThan(0));
      // Two placeholders in the tree → two issues.
      expect(detector.issues.length, 2);
      expect(
        detector.issues.first.title,
        'Placeholder in production tree',
      );
      // Both highlights have real rects because the Placeholders laid out.
      expect(detector.highlights.length, 2);
      for (final h in detector.highlights) {
        expect(h.rect.width, greaterThan(0));
        expect(h.rect.height, greaterThan(0));
        expect(h.widgetName, 'Placeholder');
        expect(h.detectorName, 'Placeholder Detector');
      }
    });

    testWidgets('issues and highlights clear between scans', (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Placeholder(),
      ));
      final context = tester.element(find.byType(Directionality));

      final detector = _PlaceholderDetector();
      detector.scanTree(context);
      expect(detector.issues, hasLength(1));
      expect(detector.highlights, hasLength(1));

      detector.scanTree(context);
      // Second scan should reset and find the same thing (not accumulate).
      expect(detector.issues, hasLength(1));
      expect(detector.highlights, hasLength(1));
      expect(detector.prepareCount, 2);
    });

    testWidgets('isEnabled=false short-circuits the entire scan',
        (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 100, height: 100, child: Placeholder()),
      ));
      final context = tester.element(find.byType(Directionality));

      final detector = _PlaceholderDetector()..isEnabled = false;
      detector.scanTree(context);

      // BaseDetector.scanTree short-circuits at the top when
      // isEnabled is false — neither prepareScan nor inspect runs.
      expect(detector.inspectCount, 0);
      expect(detector.prepareCount, 0);
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    test('dispose clears state and calls onDispose hook', () {
      final detector = _PlaceholderDetector();
      expect(detector.disposed, isFalse);

      detector.dispose();

      expect(detector.disposed, isTrue);
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    test('key is forwarded to BaseDetector.key', () {
      final keyed = _PlaceholderDetector(key: 'my_placeholder_rule');
      expect(keyed.key, 'my_placeholder_rule');

      final unkeyed = _PlaceholderDetector();
      expect(unkeyed.key, isNull);
    });

    test('lifecycle is structural and type is custom', () {
      final detector = _PlaceholderDetector();
      expect(detector.lifecycle, DetectorLifecycle.structural);
      expect(detector.type, DetectorType.custom);
    });

    testWidgets(
      'inspect throwing does not crash the detector or bypass finalizeScan',
      (tester) async {
        await tester.pumpWidget(const Directionality(
          textDirection: TextDirection.ltr,
          child: Placeholder(),
        ));
        final context = tester.element(find.byType(Directionality));

        final detector = _ThrowingDetector();
        // scanTree (the BaseDetector default) wraps the walk in a
        // try/catch — a thrown exception must not escape the detector
        // and crash the surrounding scan loop.
        expect(() => detector.scanTree(context), returnsNormally);

        // prepareScan and finalizeScan still ran. This is the critical
        // guarantee: per-element exceptions do not bypass the lifecycle
        // hooks that published accumulated state.
        expect(detector.prepareCalled, isTrue);
        expect(detector.finalizeCalled, isTrue);
      },
    );
  });
}

/// Detector whose `inspect` always throws. Used to confirm that the
/// unified walk's try/catch keeps the scan loop alive even when a custom
/// detector misbehaves.
class _ThrowingDetector extends SimpleStructuralDetector {
  _ThrowingDetector()
      : super(
          name: 'Throwing Detector',
          description: 'Intentionally throws from inspect for tests',
        );

  bool prepareCalled = false;
  bool finalizeCalled = false;

  @override
  void onPrepareScan(BuildContext context) {
    prepareCalled = true;
  }

  @override
  void inspect(Element element) {
    throw StateError('intentional cookbook test failure');
  }

  @override
  void finalizeScan() {
    finalizeCalled = true;
    super.finalizeScan();
  }
}
