import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/utils/type_name_cache.dart';

void main() {
  setUp(() => typeNameCache.clear());

  group('TypeNameCache', () {
    testWidgets('returns correct type name for StatelessWidget',
        (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(),
      ));
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

    testWidgets('returns same string instance for repeated lookups',
        (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: [SizedBox(), SizedBox()]),
      ));
      final elements = tester.elementList(find.byType(SizedBox)).toList();
      expect(elements.length, 2);

      final name1 = typeNameCache.lookup(elements[0].widget);
      final name2 = typeNameCache.lookup(elements[1].widget);
      expect(name1, 'SizedBox');
      expect(identical(name1, name2), isTrue,
          reason: 'Cache should return the same string instance');
    });

    testWidgets('clear resets cache', (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(),
      ));
      final element = tester.element(find.byType(SizedBox));

      typeNameCache.lookup(element.widget);
      expect(typeNameCache.length, greaterThan(0));

      typeNameCache.clear();
      expect(typeNameCache.length, 0);
    });

    testWidgets('populates lazily — only accessed types cached',
        (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child:
            Column(children: [SizedBox(), Padding(padding: EdgeInsets.zero)]),
      ));

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
            builder: (_, __, ___) => const SizedBox(),
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
}
