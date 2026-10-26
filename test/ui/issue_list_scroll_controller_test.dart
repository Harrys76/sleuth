import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/ui/issue_list_scroll_controller.dart';

void main() {
  testWidgets('a keep with no list attached leaves the recorded offset', (
    tester,
  ) async {
    final controller = IssueListScrollController();
    addTearDown(controller.dispose);
    Widget list() => MaterialApp(
      home: ListView.builder(
        controller: controller,
        itemCount: 100,
        itemBuilder: (_, i) => SizedBox(height: 50, child: Text('$i')),
      ),
    );
    await tester.pumpWidget(list());
    controller.jumpTo(400);
    await tester.pump();
    controller.keepOffset();

    // The list unmounts under a page; a later keep finds nothing attached.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    controller.keepOffset();
    expect(controller.keptOffset, 400);

    // The next list starts there, once.
    await tester.pumpWidget(list());
    expect(controller.offset, 400);
    expect(controller.keptOffset, 0);
  });
}
