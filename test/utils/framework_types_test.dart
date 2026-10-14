import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/material.dart' as material;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/setstate_scope_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart'
    show InteractionContext;
import 'package:sleuth/src/utils/framework_painters.dart';
import 'package:sleuth/src/utils/framework_types.dart';

import '../helpers/app_named_widgets.dart' as app;
import '../helpers/migrated_widgets.dart' as migrated;

void main() {
  group('SDK widgets match by type', () {
    test('widget checks', () {
      expect(isTabBarView(const material.TabBarView(children: [])), isTrue);
      expect(isTabBar(const material.TabBar(tabs: [])), isTrue);
      expect(isMaterial(const material.Material()), isTrue);
      expect(
        isInputDecorator(
          const material.InputDecorator(decoration: material.InputDecoration()),
        ),
        isTrue,
      );
      expect(
        isProgressIndicator(const material.LinearProgressIndicator()),
        isTrue,
      );
      expect(
        isCupertinoActivityIndicator(
          const cupertino.CupertinoActivityIndicator(),
        ),
        isTrue,
      );
      expect(
        isAnimatedIcon(
          const material.AnimatedIcon(
            icon: material.AnimatedIcons.menu_arrow,
            progress: AlwaysStoppedAnimation(0),
          ),
        ),
        isTrue,
      );
    });

    testWidgets('scaffold elements', (tester) async {
      await tester.pumpWidget(
        const material.MaterialApp(home: material.Scaffold()),
      );
      expect(
        isScaffoldElement(tester.element(find.byType(material.Scaffold))),
        isTrue,
      );
    });
  });

  group('material_ui / cupertino_ui copies match by name', () {
    test('widget checks', () {
      expect(isTabBarView(const migrated.TabBarView(children: [])), isTrue);
      expect(isTabBar(const migrated.TabBar()), isTrue);
      expect(isMaterial(const migrated.Material(child: SizedBox())), isTrue);
      expect(isInputDecorator(const migrated.InputDecorator()), isTrue);
      expect(
        isProgressIndicator(const migrated.LinearProgressIndicator()),
        isTrue,
      );
    });

    testWidgets('a copy with the framework state class is a scaffold', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              migrated.Scaffold(body: SizedBox()),
              migrated.CupertinoPageScaffold(child: SizedBox()),
            ],
          ),
        ),
      );
      expect(
        isScaffoldElement(tester.element(find.byType(migrated.Scaffold))),
        isTrue,
      );
      expect(
        isScaffoldElement(
          tester.element(find.byType(migrated.CupertinoPageScaffold)),
        ),
        isTrue,
      );
    });

    testWidgets('an app class named Scaffold with its own state is not a '
        'scaffold', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: app.Scaffold(body: SizedBox()),
        ),
      );
      final element = tester.element(find.byType(app.Scaffold));
      expect(isScaffoldElement(element), isFalse);
    });

    testWidgets('a copied Scaffold is a framework owner through its state '
        'class', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: migrated.Scaffold(body: SizedBox()),
        ),
      );
      final element = tester.element(find.byType(migrated.Scaffold));
      expect(SetStateScopeDetector.isFrameworkWidget(element.widget), isFalse);
      expect(SetStateScopeDetector.isFrameworkElement(element), isTrue);
    });

    test('framework owners for setState scope', () {
      for (final widget in const <Widget>[
        migrated.AppBar(),
        migrated.Material(child: SizedBox()),
        migrated.TabBar(),
        migrated.TabBarView(children: []),
      ]) {
        expect(
          SetStateScopeDetector.isFrameworkWidget(widget),
          isTrue,
          reason: '${widget.runtimeType}',
        );
      }
    });
  });

  group('framework painters and clips', () {
    testWidgets('the input-border painter under a copied InputDecorator is '
        'a framework painter; the same painter outside is not', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              migrated.InputDecorator(),
              SizedBox(
                width: 100,
                height: 40,
                child: CustomPaint(painter: migrated.InputBorderPainter()),
              ),
            ],
          ),
        ),
      );
      final paints = tester
          .elementList(
            find.byWidgetPredicate(
              (w) =>
                  w is CustomPaint && w.painter is migrated.InputBorderPainter,
            ),
          )
          .toList();
      expect(paints, hasLength(2));
      expect(isFrameworkPainterPaint(paints[0]), isTrue);
      expect(isFrameworkPainterPaint(paints[1]), isFalse);
    });

    testWidgets('a ClipPath directly under a copied Material is its own '
        'clip', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: migrated.Material(child: ClipPath(child: SizedBox())),
        ),
      );
      expect(isMaterialOwnClip(tester.element(find.byType(ClipPath))), isTrue);
    });
  });

  group('scan root', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController()..initializeDetectorsForTest();
    });

    tearDown(() => controller.dispose());

    testWidgets('a copied Scaffold takes the scaffold path', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: migrated.Scaffold(body: SizedBox()),
        ),
      );
      controller.scanTreeFullPathForTest(
        tester.element(find.byType(Directionality)),
      );
      expect(controller.isScaffoldFreeScanForTest, isFalse);
      expect(controller.interactionStateForTest, InteractionContext.idle);
    });

    testWidgets('a copied TabBarView stops the scaffold search, so the '
        'outer copied Scaffold stays the page', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: migrated.Scaffold(
            body: migrated.TabBarView(
              children: [migrated.Scaffold(body: SizedBox())],
            ),
          ),
        ),
      );
      controller.scanTreeFullPathForTest(
        tester.element(find.byType(Directionality)),
      );
      expect(controller.isScaffoldFreeScanForTest, isFalse);
      expect(controller.interactionStateForTest, InteractionContext.idle);
    });

    testWidgets('an app StatefulWidget named Scaffold above the page stays '
        'in the scan', (tester) async {
      // The app wrapper builds a banner next to the SDK Scaffold.
      await tester.pumpWidget(
        const MaterialAppStub(
          child: app.Scaffold(
            body: Column(
              children: [
                Text('banner', textDirection: TextDirection.ltr),
                Expanded(child: material.Scaffold(body: SizedBox())),
              ],
            ),
          ),
        ),
      );
      controller.scanTreeFullPathForTest(
        tester.element(find.byType(MaterialAppStub)),
      );
      final root = controller.lastScanContextForTest! as Element;
      // The walk went past the app wrapper, so the wrapper and its banner
      // are inside the scanned subtree.
      var sawWrapper = false;
      root.visitChildElements((child) {
        void visit(Element e) {
          if (e.widget is app.Scaffold) sawWrapper = true;
          e.visitChildElements(visit);
        }

        visit(child);
      });
      expect(sawWrapper, isTrue);
      expect(
        SetStateScopeDetector.isFrameworkElement(
          tester.element(find.byType(app.Scaffold)),
        ),
        isFalse,
      );
      expect(
        SetStateScopeDetector.isFrameworkElement(
          tester.element(find.byType(material.Scaffold)),
        ),
        isTrue,
      );
    });
  });

  group('creation location', () {
    test('material_ui and cupertino_ui paths match; other packages and the '
        'app do not', () {
      for (final file in [
        '/Users/me/.pub-cache/hosted/pub.dev/material_ui-1.6.0/lib/src/progress_indicator.dart',
        r'C:\Users\me\AppData\Local\Pub\Cache\hosted\pub.dev\cupertino_ui-1.1.2\lib\src\nav_bar.dart',
        '/work/monorepo/third_party/material_ui/lib/material_ui.dart',
        'package:cupertino_ui/src/route.dart',
        '/Users/me/.pub-cache/git/material_ui-a1b2c3d4e5f60718293a4b5c6d7e8f9012345678/lib/src/app.dart',
      ]) {
        expect(isMovedFrameworkFile(file), isTrue, reason: file);
      }
      for (final file in [
        '/Users/me/app/lib/main.dart',
        '/Users/me/.pub-cache/hosted/pub.dev/provider-6.1.2/lib/src/provider.dart',
        '/flutter/packages/flutter/lib/src/material/scaffold.dart',
        '/Users/me/my_material_ui_theme/lib/theme.dart',
        '/Users/me/app/lib/material_ui/home.dart',
        '/Users/me/material_ui-sample/lib/main.dart',
      ]) {
        expect(isMovedFrameworkFile(file), isFalse, reason: file);
      }
    });

    testWidgets('a widget this test creates reads its own file', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox(width: 10));
      final widget = tester.widget(find.byType(SizedBox));
      expect(widgetCreationFile(widget), contains('framework_types_test'));
      expect(createdInMovedFrameworkPackage(widget), isFalse);
    });
  });
}

/// Directionality, MediaQuery and a Navigator-free Material ancestor for
/// the SDK Scaffold.
class MaterialAppStub extends StatelessWidget {
  const MaterialAppStub({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: const MediaQueryData(),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: material.Material(child: child),
    ),
  );
}
