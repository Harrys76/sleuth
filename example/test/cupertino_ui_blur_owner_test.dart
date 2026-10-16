// The `cupertino_ui` package copies the SDK's Cupertino bars and dialogs as
// distinct types. Sleuth names the widget that draws a blur by class name
// within a measured hop budget; this pins that the budget, measured on the
// SDK trees, also holds for the package's trees.
//
// The lookup is a package internal, so this test imports `src/` on purpose.
// ignore_for_file: implementation_imports

import 'package:cupertino_ui/cupertino_ui.dart' as cui;
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/utils/framework_types.dart';

void main() {
  List<String?> owners(WidgetTester tester) => [
    for (final e in find.byType(cui.BackdropFilter).evaluate())
      cupertinoBlurOwner(e),
  ];

  testWidgets('navigation and tab bars', (tester) async {
    await tester.pumpWidget(
      cui.CupertinoApp(
        home: cui.CupertinoPageScaffold(
          navigationBar: const cui.CupertinoNavigationBar(
            middle: cui.Text('Title'),
            automaticBackgroundVisibility: false,
          ),
          child: cui.Column(
            children: [
              const cui.Expanded(child: cui.SizedBox()),
              cui.CupertinoTabBar(
                items: const [
                  cui.BottomNavigationBarItem(
                    icon: cui.Icon(cui.CupertinoIcons.info),
                    label: 'One',
                  ),
                  cui.BottomNavigationBarItem(
                    icon: cui.Icon(cui.CupertinoIcons.info),
                    label: 'Two',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      owners(tester),
      unorderedEquals(['CupertinoNavigationBar', 'CupertinoTabBar']),
    );
  });

  testWidgets('alert dialog', (tester) async {
    await tester.pumpWidget(
      cui.CupertinoApp(
        home: cui.Builder(
          builder: (context) => cui.CupertinoButton(
            child: const cui.Text('Open'),
            onPressed: () => cui.showCupertinoDialog<void>(
              context: context,
              builder: (_) => const cui.CupertinoAlertDialog(
                title: cui.Text('Title'),
                actions: [cui.CupertinoDialogAction(child: cui.Text('OK'))],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(owners(tester), contains('CupertinoPopupSurface'));
  });
}
