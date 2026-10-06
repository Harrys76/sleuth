import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';

/// Public StatefulWidget page so the scan root resolves to the element
/// directly above it: the counting [Builder].
class CountedPage extends StatefulWidget {
  const CountedPage({super.key});

  @override
  State<CountedPage> createState() => _CountedPageState();
}

class _CountedPageState extends State<CountedPage> {
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: SizedBox(width: 10, height: 10));
}

void main() {
  /// Pushes `/detail` over `/home` and pops it, returning how many times
  /// the `/home` page root rebuilt after its first build.
  Future<int> pushPopRebuilds(
    WidgetTester tester, {
    required bool withSleuth,
  }) async {
    var builds = 0;
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        initialRoute: '/home',
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => settings.name == '/home'
              ? Builder(
                  builder: (_) {
                    builds++;
                    return const CountedPage();
                  },
                )
              : const Scaffold(body: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    SleuthController? controller;
    final root = tester.element(find.byType(MaterialApp));
    void scan() => controller?.scanTreeFullPathForTest(root);
    if (withSleuth) {
      controller = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      scan();
      expect(controller.activeRouteSessionForTest?.routeName, '/home');
      final scanRoot = controller.lastScanContextForTest! as Element;
      expect(scanRoot.widget, isA<Builder>());
    }
    final initial = builds;

    navKey.currentState!.pushNamed('/detail');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    scan();
    await tester.pumpAndSettle();
    scan();
    expect(
      controller?.activeRouteSessionForTest?.routeName,
      withSleuth ? '/detail' : null,
    );

    navKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    scan();
    await tester.pumpAndSettle();
    scan();
    expect(
      controller?.activeRouteSessionForTest?.routeName,
      withSleuth ? '/home' : null,
    );

    controller?.dispose();
    await tester.pumpWidget(const SizedBox());
    return builds - initial;
  }

  testWidgets('route-name lookup does not rebuild the scan root on push/pop', (
    tester,
  ) async {
    final control = await pushPopRebuilds(tester, withSleuth: false);
    final scanned = await pushPopRebuilds(tester, withSleuth: true);
    expect(scanned, control);
  });
}
