// The Shrink-wrapped Sections demo shows two shrink-wrapped lists of equal
// length in a Column inside a SingleChildScrollView: Sleuth reports one
// non_lazy_shrinkwrap card per list, both with the same title.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:example/demos/shrink_wrapped_sections_demo.dart';

void main() {
  List<ListView> shrinkWrapped(WidgetTester tester) => [
    for (final list in tester.widgetList<ListView>(find.byType(ListView)))
      if (list.shrinkWrap) list,
  ];

  testWidgets('the bad pattern has two equal shrink-wrapped lists in a '
      'Column inside a SingleChildScrollView', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ShrinkWrappedSectionsDemo()),
    );

    final lists = shrinkWrapped(tester);
    expect(lists, hasLength(2));
    expect(
      [
        for (final list in lists)
          (list.childrenDelegate as SliverChildListDelegate).children.length,
      ],
      [30, 30],
    );
    for (final list in lists) {
      final column = find.ancestor(
        of: find.byWidget(list),
        matching: find.byType(Column),
      );
      expect(
        find.ancestor(
          of: column.first,
          matching: find.byType(SingleChildScrollView),
        ),
        findsWidgets,
      );
    }
  });

  testWidgets('the fixed pattern has no shrink-wrapped list', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ShrinkWrappedSectionsDemo()),
    );
    await tester.tap(find.text('Fixed Pattern'));
    await tester.pumpAndSettle();

    expect(shrinkWrapped(tester), isEmpty);
    expect(find.byType(CustomScrollView), findsOneWidget);
  });
}
