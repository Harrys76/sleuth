import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/utils/widget_location.dart';

void main() {
  setUp(() => sourceLocationCache.clear());

  group('buildAncestorChain with source location', () {
    testWidgets('appends file:line to leaf widget', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [TestLeafWidget()]),
        ),
      );

      final element = tester.element(find.byType(TestLeafWidget));
      final chain = buildAncestorChain(element);

      expect(chain, contains('TestLeafWidget'));
      // Chain should end with a parenthesized source location
      expect(chain, matches(RegExp(r'\(.*widget_location_test\.dart:\d+\)$')));
    });

    testWidgets('chain still contains ancestor names', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestParentWidget(child: TestLeafWidget()),
        ),
      );

      final element = tester.element(find.byType(TestLeafWidget));
      final chain = buildAncestorChain(element);

      // Non-underscore ancestor should be present in chain
      expect(chain, contains('TestParentWidget'));
      expect(chain, contains('TestLeafWidget'));
      // Source location appended
      expect(chain, contains('widget_location_test.dart:'));
    });

    testWidgets('framework widgets still filtered from chain', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestLeafWidget(),
        ),
      );

      final element = tester.element(find.byType(TestLeafWidget));
      final chain = buildAncestorChain(element);

      // Directionality is in the _frameworkNames filter set
      expect(chain, isNot(contains('Directionality')));
    });

    testWidgets('private-named widgets filtered from ancestors',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _PrivateParent(child: TestLeafWidget()),
        ),
      );

      final element = tester.element(find.byType(TestLeafWidget));
      final chain = buildAncestorChain(element);

      // Private widgets (underscore prefix) filtered from ancestors
      expect(chain, isNot(contains('_PrivateParent')));
      expect(chain, contains('TestLeafWidget'));
    });

    testWidgets('maxDepth still respected', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestA(child: TestB(child: TestC(child: TestLeafWidget()))),
        ),
      );

      final element = tester.element(find.byType(TestLeafWidget));
      final chain = buildAncestorChain(element, maxDepth: 2);

      // maxDepth=2 means leaf + 2 ancestors max = 3 names in chain.
      // The chain string has format "A > B > Leaf (...)" — split on " > "
      // and count segments. Source location is appended to the last segment.
      final segments = chain.split(' > ');
      expect(segments.length, lessThanOrEqualTo(3));
    });

    testWidgets('source location path is abbreviated', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestLeafWidget(),
        ),
      );

      final element = tester.element(find.byType(TestLeafWidget));
      final chain = buildAncestorChain(element);

      // Should not contain absolute path prefix
      expect(chain, isNot(contains('/Users/')));
    });

    testWidgets('same widget type uses cached location', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [TestLeafWidget(), TestLeafWidget()]),
        ),
      );

      final elements = tester.elementList(find.byType(TestLeafWidget)).toList();
      final chain1 = buildAncestorChain(elements[0]);
      final chain2 = buildAncestorChain(elements[1]);

      // Both should have source location (from cache on second call)
      expect(chain1, contains('widget_location_test.dart:'));
      expect(chain2, contains('widget_location_test.dart:'));
      expect(sourceLocationCache.length, 1); // Only one type cached
    });
  });

  group('getGlobalRect', () {
    testWidgets('returns rect for a RenderBox with size', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: SizedBox(width: 100, height: 50)),
        ),
      );

      // Find the inner SizedBox (not the one from Center)
      final element = tester.element(find.byType(SizedBox).first);
      final ro = element.renderObject!;
      final rect = getGlobalRect(ro);

      expect(rect, isNotNull);
      expect(rect!.width, 100);
      expect(rect.height, 50);
    });

    testWidgets('returns null for non-RenderBox', (tester) async {
      final rect = getGlobalRect(_FakeRenderObject());
      expect(rect, isNull);
    });
  });
}

// --- Test widgets (public names so they appear in ancestor chains) ---

class TestLeafWidget extends StatelessWidget {
  const TestLeafWidget({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink(key: Key('leaf'));
}

class TestParentWidget extends StatelessWidget {
  const TestParentWidget({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class TestA extends StatelessWidget {
  const TestA({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class TestB extends StatelessWidget {
  const TestB({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class TestC extends StatelessWidget {
  const TestC({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _PrivateParent extends StatelessWidget {
  const _PrivateParent({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _FakeRenderObject extends RenderObject {
  @override
  void debugAssertDoesMeetConstraints() {}

  @override
  Rect get paintBounds => Rect.zero;

  @override
  void performLayout() {}

  @override
  void performResize() {}

  @override
  Rect get semanticBounds => Rect.zero;
}
