import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/layout_bottleneck_detector.dart';

/// User-authored intrinsics placed inside framework widgets that own their
/// own intrinsics must still be reported. The owner suppression is keyed to
/// the framework's placement, not to the whole subtree.
void main() {
  List<String> scan(WidgetTester tester) {
    final detector = LayoutBottleneckDetector();
    detector.scanTree(tester.element(find.byType(MaterialApp)));
    return detector.issues
        .where((i) => i.stableId == 'layout_bottleneck')
        .map((i) => i.severity.name)
        .toList();
  }

  testWidgets('user IntrinsicHeight as a MenuBar child is still reported', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MenuBar(
            children: [
              SubmenuButton(
                menuChildren: const [MenuItemButton(child: Text('a'))],
                child: const IntrinsicHeight(
                  child: Row(children: [Text('File'), Text('x')]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(IntrinsicHeight, skipOffstage: false), findsWidgets);
    expect(scan(tester), ['warning']);
  });

  testWidgets(
    'user IntrinsicWidth inside a BottomNavigationBarItem icon is still '
    'reported while the framework label intrinsic stays suppressed',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const SizedBox.shrink(),
            bottomNavigationBar: BottomNavigationBar(
              type: BottomNavigationBarType.fixed,
              landscapeLayout: BottomNavigationBarLandscapeLayout.linear,
              items: const [
                BottomNavigationBarItem(
                  icon: IntrinsicWidth(child: Icon(Icons.home)),
                  label: 'Home',
                ),
                BottomNavigationBarItem(icon: Icon(Icons.star), label: 'Star'),
                BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Map'),
              ],
            ),
          ),
        ),
      );
      // Three framework label intrinsics plus the one user intrinsic.
      expect(
        find.byType(IntrinsicWidth, skipOffstage: false),
        findsNWidgets(4),
      );
      expect(scan(tester), ['warning']);
    },
  );
}
