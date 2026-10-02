// Radio's groupValue/onChanged are deprecated on newer SDKs but required
// on the oldest supported one.
// ignore_for_file: deprecated_member_use
import 'package:flutter/cupertino.dart'
    show CupertinoActivityIndicator, CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// MaterialApp page with framework toggle and scrollbar painters only:
/// Checkbox, Switch, Radio, CupertinoSwitch, and a Scrollbar over a
/// ListView. Pass [extra] to add a user widget alongside them.
Widget frameworkPainterPage({Widget? extra}) => MaterialApp(
  // The debug banner is itself an unprotected CustomPaint.
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    body: Column(
      children: [
        Checkbox(value: true, onChanged: (_) {}),
        Switch(value: true, onChanged: (_) {}),
        Radio<int>(value: 1, groupValue: 1, onChanged: (_) {}),
        CupertinoSwitch(value: true, onChanged: (_) {}),
        ?extra,
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            child: ListView(
              primary: true,
              children: List.generate(
                40,
                (i) => SizedBox(key: ValueKey(i), height: 40),
              ),
            ),
          ),
        ),
      ],
    ),
  ),
);

/// Proves the framework painters are actually in the tree: returns the
/// number of CustomPaint widgets using a [ToggleablePainter] and a
/// [ScrollbarPainter] respectively.
({int toggleable, int scrollbar}) countFrameworkPainters() {
  int toggleable = 0;
  int scrollbar = 0;
  for (final e in find.byType(CustomPaint, skipOffstage: false).evaluate()) {
    final w = e.widget as CustomPaint;
    for (final p in [w.painter, w.foregroundPainter]) {
      if (p is ToggleablePainter) toggleable++;
      if (p is ScrollbarPainter) scrollbar++;
    }
  }
  return (toggleable: toggleable, scrollbar: scrollbar);
}

/// Key on the overscrolling list in [materialPainterPage].
const glowListKey = ValueKey('glow-list');

/// Key on the dropdown button in [materialPainterPage].
const dropdownKey = ValueKey('dropdown');

/// MaterialApp page built only from real Material and Cupertino widgets
/// whose private painters and clips are framework-owned: Card,
/// ElevatedButton, TextButton, FloatingActionButton, Linear / Circular /
/// Refresh progress indicators, a fixed and a scrollable TabBar under a
/// DefaultTabController (3 tabs), TextField, CupertinoActivityIndicator,
/// AnimatedIcon mid-animation, Placeholder, GridPaper, a transparency
/// Material with an InkWell, a DropdownButton, and a ListView under a
/// Material 2 theme so it overscrolls with the glow painter.
///
/// Pass [extra] to add a user widget alongside them. Drive it with
/// [driveMaterialPainterPage] before scanning.
Widget materialPainterPage({Widget? extra}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: DefaultTabController(
    length: 3,
    child: Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'A'),
              Tab(text: 'B'),
              Tab(text: 'C'),
            ],
          ),
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'D'),
              Tab(text: 'E'),
              Tab(text: 'F'),
            ],
          ),
          Wrap(
            children: [
              const Card(child: SizedBox(width: 20, height: 20)),
              ElevatedButton(onPressed: () {}, child: const Text('elevated')),
              TextButton(onPressed: () {}, child: const Text('text')),
              const SizedBox(width: 60, child: LinearProgressIndicator()),
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(),
              ),
              const RefreshProgressIndicator(),
              const SizedBox(width: 120, child: TextField()),
              const CupertinoActivityIndicator(),
              const AnimatedIcon(
                icon: AnimatedIcons.menu_arrow,
                progress: AlwaysStoppedAnimation(0.5),
              ),
              const SizedBox.square(dimension: 20, child: Placeholder()),
              const SizedBox.square(dimension: 20, child: GridPaper()),
              Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () {},
                  child: const SizedBox.square(dimension: 20),
                ),
              ),
              DropdownButton<int>(
                key: dropdownKey,
                value: 1,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('one')),
                  DropdownMenuItem(value: 2, child: Text('two')),
                ],
                onChanged: (_) {},
              ),
              ?extra,
            ],
          ),
          Expanded(
            child: Theme(
              data: ThemeData(useMaterial3: false),
              child: ListView(
                key: glowListKey,
                children: List.generate(
                  3,
                  (i) => SizedBox(height: 20, child: Text('row $i')),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  ),
);

/// Puts [materialPainterPage] into its painting state: taps the second
/// tab of the fixed TabBar and pumps once so its indicator is
/// mid-animation (`shouldRepaint` true), then drags the list past its
/// leading edge and pumps once so the glow painter is active. With
/// [openDropdown], also taps the DropdownButton and lets its menu route
/// finish opening.
Future<void> driveMaterialPainterPage(
  WidgetTester tester, {
  bool openDropdown = false,
}) async {
  if (openDropdown) {
    await tester.tap(find.byKey(dropdownKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return;
  }
  await tester.tap(find.text('B'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(glowListKey)),
  );
  await gesture.moveBy(const Offset(0, 120));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

/// Framework painters in the tree by painter class name, with how many
/// of them have no [RenderRepaintBoundary] within [maxAncestorDepth]
/// render ancestors and whether any of them returns true from
/// `shouldRepaint(self)` right now. Proves a "silent" assertion is not
/// vacuous.
Map<String, ({int count, int unprotected, bool repaintsSelf})> paintersByName({
  int maxAncestorDepth = 5,
}) {
  final result = <String, ({int count, int unprotected, bool repaintsSelf})>{};
  for (final e in find.byType(CustomPaint, skipOffstage: false).evaluate()) {
    final w = e.widget as CustomPaint;
    final unprotected = !_hasBoundaryWithin(e.renderObject, maxAncestorDepth);
    for (final p in [w.painter, w.foregroundPainter]) {
      if (p == null) continue;
      final name = p.runtimeType.toString();
      final prior = result[name];
      result[name] = (
        count: (prior?.count ?? 0) + 1,
        unprotected: (prior?.unprotected ?? 0) + (unprotected ? 1 : 0),
        repaintsSelf: (prior?.repaintsSelf ?? false) || p.shouldRepaint(p),
      );
    }
  }
  return result;
}

/// Number of [ClipPath] elements whose parent element widget is a
/// [Material], and how many of them have no [RenderRepaintBoundary] within
/// [maxAncestorDepth] render ancestors.
({int count, int unprotected}) materialClipPaths({int maxAncestorDepth = 5}) {
  var count = 0;
  var unprotected = 0;
  for (final e in find.byType(ClipPath, skipOffstage: false).evaluate()) {
    var parentIsMaterial = false;
    e.visitAncestorElements((a) {
      parentIsMaterial = a.widget is Material;
      return false;
    });
    if (!parentIsMaterial) continue;
    count++;
    if (!_hasBoundaryWithin(e.renderObject, maxAncestorDepth)) unprotected++;
  }
  return (count: count, unprotected: unprotected);
}

bool _hasBoundaryWithin(RenderObject? ro, int maxAncestorDepth) {
  var current = ro?.parent;
  for (var i = 0; i < maxAncestorDepth && current != null; i++) {
    if (current is RenderRepaintBoundary) return true;
    current = current.parent;
  }
  return false;
}
