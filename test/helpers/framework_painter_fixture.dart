// Radio's groupValue/onChanged are deprecated on newer SDKs but required
// on the oldest supported one.
// ignore_for_file: deprecated_member_use
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
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
