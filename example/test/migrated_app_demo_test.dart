// The Migrated App demo is built on the real `material_ui` package, whose
// widgets share the SDK's class names but are distinct types. These tests
// pin that Sleuth's framework checks recognise them, and they measure the
// painter hop budgets on the package's own widget trees. The package needs
// Flutter 3.35 or later, so this lives in the example, which runs only on
// the 3.47 lane.
//
// The checks are package internals, so this test imports `src/` on
// purpose (the cookbook files, not this test, must stay on the public API).
// ignore_for_file: implementation_imports

import 'package:example/demos/migrated_app_demo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/setstate_scope_detector.dart';
import 'package:sleuth/src/utils/framework_painters.dart';
import 'package:sleuth/src/utils/framework_types.dart';
import 'package:sleuth/src/utils/type_name_cache.dart';

void main() {
  /// Every `CustomPaint` element on screen with its painter class name.
  Map<String, List<mui.Element>> paintsByPainter(WidgetTester tester) {
    final out = <String, List<mui.Element>>{};
    for (final e in tester.allElements) {
      final w = e.widget;
      if (w is! mui.CustomPaint) continue;
      for (final p in [w.painter, w.foregroundPainter]) {
        if (p == null) continue;
        final name = baseTypeName(typeNameCache.lookupType(p.runtimeType));
        (out[name] ??= []).add(e);
      }
    }
    return out;
  }

  /// Hops from [e] to the first ancestor that [isOwner] accepts.
  int hopsTo(mui.Element e, bool Function(mui.Widget) isOwner) {
    var hops = 0;
    var found = false;
    e.visitAncestorElements((a) {
      hops++;
      if (isOwner(a.widget)) found = true;
      return !found;
    });
    return found ? hops : -1;
  }

  testWidgets('material_ui widgets read as framework', (tester) async {
    await tester.pumpWidget(const MigratedAppDemo());
    await tester.pump();

    final scaffold = tester.element(find.byType(mui.Scaffold));
    expect(isScaffoldElement(scaffold), isTrue);
    expect(SetStateScopeDetector.isFrameworkElement(scaffold), isTrue);
    expect(isTabBarView(tester.widget(find.byType(mui.TabBarView))), isTrue);
    expect(isTabBar(tester.widget(find.byType(mui.TabBar))), isTrue);
    expect(
      SetStateScopeDetector.isFrameworkWidget(
        tester.widget(find.byType(mui.AppBar)),
      ),
      isTrue,
    );
  });

  testWidgets('framework painters inside material_ui widgets are framework, '
      'the app painter is not, and the hop budgets hold', (tester) async {
    await tester.pumpWidget(const MigratedAppDemo());
    await tester.pump(const Duration(milliseconds: 100));

    final paints = paintsByPainter(tester);
    // Tab indicator, input border and both progress painters come from
    // material_ui; each must be found and recognised.
    for (final name in const [
      '_IndicatorPainter',
      '_InputBorderPainter',
      '_LinearProgressIndicatorPainter',
      '_CircularProgressIndicatorPainter',
      '_ShapeBorderPainter',
    ]) {
      expect(paints[name], isNotNull, reason: '$name not found');
      for (final e in paints[name]!) {
        expect(isFrameworkPainterPaint(e), isTrue, reason: name);
      }
    }

    // Hops on material_ui 1.6.0, against the budget table in
    // framework_painters.dart (tab 28, input 5, linear 5, circular 6,
    // shape border 4). The shape border has no slack.
    for (final (name, isOwner, hops)
        in <(String, bool Function(mui.Widget), Set<int>)>[
          ('_IndicatorPainter', isTabBar, {11}),
          ('_InputBorderPainter', isInputDecorator, {4}),
          ('_LinearProgressIndicatorPainter', isProgressIndicator, {4}),
          ('_CircularProgressIndicatorPainter', isProgressIndicator, {5}),
          ('_ShapeBorderPainter', isMaterial, {3, 4}),
        ]) {
      for (final e in paints[name]!) {
        expect(hops, contains(hopsTo(e, isOwner)), reason: name);
      }
    }

    // The tab view's second page holds the app's own painter; open it.
    await tester.tap(find.text('Paint'));
    await tester.pumpAndSettle();
    final userPaints = paintsByPainter(tester)['_AlwaysRepaintPainter'];
    expect(userPaints, isNotNull);
    expect(isFrameworkPainterPaint(userPaints!.first), isFalse);
  });

  testWidgets('the scan takes the scaffold path for a material_ui app', (
    tester,
  ) async {
    await tester.pumpWidget(const MigratedAppDemo());
    await tester.pump();
    final controller = SleuthController()..initializeDetectorsForTest();
    addTearDown(controller.dispose);
    controller.scanTreeFullPathForTest(
      tester.element(find.byType(mui.MaterialApp)),
    );
    expect(controller.isScaffoldFreeScanForTest, isFalse);
  });
}
