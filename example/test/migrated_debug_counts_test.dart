// Debug per-widget counts on a `material_ui` app. Flutter counts every
// widget created outside `packages/flutter/` as the app's until DevTools
// sets the project's root directories, so the widgets `material_ui` builds
// inside its own widgets would get rebuild cards. Sleuth reads their
// creation location and leaves them out.
//
// The checks are package internals, so this test imports `src/` on
// purpose.
// ignore_for_file: implementation_imports

import 'package:example/demos/migrated_app_demo.dart';
import 'package:flutter/rendering.dart' show debugOnProfilePaint;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/utils/framework_types.dart';

void main() {
  setUp(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });
  tearDown(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });

  testWidgets('a widget material_ui builds is read as created in the '
      'package; the demo\'s own widgets are not', (tester) async {
    await tester.pumpWidget(const MigratedAppDemo());
    await tester.pump();

    final inIndicator = tester.allElements
        .where(
          (e) =>
              e.widget is AnimatedBuilder &&
              e
                      .findAncestorWidgetOfExactType<
                        mui.CircularProgressIndicator
                      >() !=
                  null,
        )
        .toList();
    expect(inIndicator, isNotEmpty);
    for (final e in inIndicator) {
      // Flutter's own rule calls it the app's.
      expect(debugIsWidgetLocalCreation(e.widget), isTrue);
      expect(createdInMovedFrameworkPackage(e.widget), isTrue);
      expect(widgetCreationFile(e.widget), contains('material_ui'));
    }

    final demo = tester.widget(find.byType(MigratedAppDemo));
    final pumped = tester.allElements
        .firstWhere((e) => identical(e.widget, demo))
        .widget;
    expect(createdInMovedFrameworkPackage(pumped), isFalse);
    expect(widgetCreationFile(pumped), contains('migrated_debug_counts_test'));
  });

  testWidgets('animated material_ui indicators get no per-widget rebuild '
      'or paint counts', (tester) async {
    await tester.pumpWidget(const MigratedAppDemo());
    var now = DateTime(2026);
    final coord = DebugInstrumentationCoordinator(clock: () => now);
    coord.install();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    now = now.add(const Duration(seconds: 1));
    final snap = coord.snapshot();
    coord.dispose();

    // The indicators animate every frame, so the paint aggregate sees them.
    expect(snap.totalPaintCount, greaterThan(0));
    expect(snap.rebuildCounts.containsKey('AnimatedBuilder'), isFalse);
    expect(snap.paintCounts.containsKey('AnimatedBuilder'), isFalse);
    expect(snap.paintCounts.containsKey('CustomPaint'), isFalse);
  });

  testWidgets('an app widget inside a material_ui app still gets its '
      'counts', (tester) async {
    await tester.pumpWidget(
      const mui.MaterialApp(
        home: mui.Scaffold(
          body: Column(children: [_Ticking(), mui.CircularProgressIndicator()]),
        ),
      ),
    );
    var now = DateTime(2026);
    final coord = DebugInstrumentationCoordinator(clock: () => now);
    coord.install();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    now = now.add(const Duration(seconds: 1));
    final snap = coord.snapshot();
    coord.dispose();

    expect(snap.rebuildCounts['_Ticking'], greaterThanOrEqualTo(20));
    expect(snap.rebuildCounts.containsKey('AnimatedBuilder'), isFalse);
  });
}

/// An app widget that rebuilds itself every frame.
class _Ticking extends StatefulWidget {
  const _Ticking();

  @override
  State<_Ticking> createState() => _TickingState();
}

class _TickingState extends State<_Ticking>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _frames = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() {}))..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Text('${_frames++}', textDirection: TextDirection.ltr);
}
