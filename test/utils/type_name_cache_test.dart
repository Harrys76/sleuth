import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/utils/type_name_cache.dart';

void main() {
  setUp(() => typeNameCache.clear());

  group('TypeNameCache', () {
    testWidgets('returns correct type name for StatelessWidget', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(),
        ),
      );
      final element = tester.element(find.byType(SizedBox));
      expect(typeNameCache.lookup(element.widget), 'SizedBox');
    });

    testWidgets('returns correct type name for StatefulWidget', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ListView(children: const []),
        ),
      );
      final element = tester.element(find.byType(ListView));
      expect(typeNameCache.lookup(element.widget), 'ListView');
    });

    testWidgets('returns same string instance for repeated lookups', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [SizedBox(), SizedBox()]),
        ),
      );
      final elements = tester.elementList(find.byType(SizedBox)).toList();
      expect(elements.length, 2);

      final name1 = typeNameCache.lookup(elements[0].widget);
      final name2 = typeNameCache.lookup(elements[1].widget);
      expect(name1, 'SizedBox');
      expect(
        identical(name1, name2),
        isTrue,
        reason: 'Cache should return the same string instance',
      );
    });

    testWidgets('clear resets cache', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(),
        ),
      );
      final element = tester.element(find.byType(SizedBox));

      typeNameCache.lookup(element.widget);
      expect(typeNameCache.length, greaterThan(0));

      typeNameCache.clear();
      expect(typeNameCache.length, 0);
    });

    testWidgets('populates lazily — only accessed types cached', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              SizedBox(),
              Padding(padding: EdgeInsets.zero),
            ],
          ),
        ),
      );

      final sizedBox = tester.element(find.byType(SizedBox));
      typeNameCache.lookup(sizedBox.widget);
      // SizedBox looked up; Padding not yet
      expect(typeNameCache.length, 1);

      final padding = tester.element(find.byType(Padding));
      typeNameCache.lookup(padding.widget);
      expect(typeNameCache.length, 2);
    });

    testWidgets('handles generic type names', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ValueListenableBuilder<int>(
            valueListenable: ValueNotifier(0),
            builder: (_, _, _) => const SizedBox(),
          ),
        ),
      );
      final element = tester.element(find.byType(ValueListenableBuilder<int>));
      expect(
        typeNameCache.lookup(element.widget),
        contains('ValueListenableBuilder'),
      );
    });
  });

  group('TypeNameCache.lookupType', () {
    test('returns the type name for a non-widget type and caches it', () {
      final first = typeNameCache.lookupType(_Probe);
      expect(first, '_Probe');
      expect(identical(typeNameCache.lookupType(_Probe), first), isTrue);
      expect(typeNameCache.length, 1);
    });
  });

  group('baseTypeName', () {
    test('empty string returns empty string', () {
      expect(baseTypeName(''), '');
    });

    test('bare name (no generic) returns input unchanged', () {
      expect(baseTypeName('StreamBuilder'), 'StreamBuilder');
      expect(baseTypeName('Scaffold'), 'Scaffold');
    });

    test('simple generic strips suffix', () {
      expect(baseTypeName('StreamBuilder<int>'), 'StreamBuilder');
    });

    test('nested generic strips at first `<`', () {
      // `Map<int, List<String>>` — outer base name is `Map`. Inner `<` after
      // `List` must NOT be the split point.
      expect(baseTypeName('Map<int, List<String>>'), 'Map');
    });

    test('private-name generic strips suffix preserving `_` prefix', () {
      expect(baseTypeName('_ModalScope<dynamic>'), '_ModalScope');
    });

    test('multi-arg generic strips entire suffix', () {
      expect(baseTypeName('Tuple<int, String, bool>'), 'Tuple');
    });
  });
  group('TypeNameCache lifetime in the controller', () {
    testWidgets('persists across scans and clears on hot reload', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [SizedBox(), Text('a')]),
        ),
      );
      final context = tester.element(find.byType(Directionality));
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      addTearDown(controller.dispose);

      controller.runTreeScanForTest(context);
      final afterFirst = typeNameCache.length;
      expect(afterFirst, greaterThan(0));

      controller.runTreeScanForTest(context);
      expect(typeNameCache.length, afterFirst);

      controller.reassembleForTest();
      expect(typeNameCache.length, 0);
    });
  });
}

class _Probe {}
