import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';

void main() {
  late SleuthController controller;

  setUp(() {
    controller = SleuthController();
    controller.initializeDetectorsForTest();
  });

  tearDown(() {
    controller.dispose();
  });

  Widget pumpCard({
    bool isDebugMode = true,
    SleuthConfig? config,
  }) {
    if (config != null) {
      controller.dispose();
      controller = SleuthController(config: config);
      controller.initializeDetectorsForTest();
    }
    return MaterialApp(
      home: Scaffold(
        body: FloatingIssuesCard(
          controller: controller,
          onClose: () {},
          isDebugMode: isDebugMode,
        ),
      ),
    );
  }

  // Use specific text to distinguish our banner from the existing
  // debug-mode disclaimer in _WarningBanners.
  const bannerText = 'timings are';

  group('M2: Minimize/maximize/restore', () {
    testWidgets('minimize hides body, shows only header', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Body content should be present initially
      expect(find.textContaining('No issues detected'), findsOneWidget);

      // Tap minimize
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();

      // Body content should be gone
      expect(find.textContaining('No issues detected'), findsNothing);
      // Header title should still be there
      expect(find.text('Sleuth'), findsOneWidget);
      // Restore button should appear (replaces minimize/maximize)
      expect(find.byIcon(Icons.filter_none), findsOneWidget);
      expect(find.byIcon(Icons.minimize), findsNothing);
      expect(find.byIcon(Icons.crop_square), findsNothing);
    });

    testWidgets('maximize expands card, body still present', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Tap maximize
      await tester.tap(find.byIcon(Icons.crop_square));
      await tester.pump();

      // Body content should still be present
      expect(find.textContaining('No issues detected'), findsOneWidget);
      // Restore button should appear
      expect(find.byIcon(Icons.filter_none), findsOneWidget);
      expect(find.byIcon(Icons.minimize), findsNothing);
    });

    testWidgets('restore after minimize brings back body', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Minimize
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();
      expect(find.textContaining('No issues detected'), findsNothing);

      // Restore
      await tester.tap(find.byIcon(Icons.filter_none));
      await tester.pump();

      // Body should be back
      expect(find.textContaining('No issues detected'), findsOneWidget);
      // Minimize/maximize buttons should be back
      expect(find.byIcon(Icons.minimize), findsOneWidget);
      expect(find.byIcon(Icons.crop_square), findsOneWidget);
      expect(find.byIcon(Icons.filter_none), findsNothing);
    });

    testWidgets('restore after maximize returns to normal', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Maximize
      await tester.tap(find.byIcon(Icons.crop_square));
      await tester.pump();
      expect(find.byIcon(Icons.filter_none), findsOneWidget);

      // Restore
      await tester.tap(find.byIcon(Icons.filter_none));
      await tester.pump();

      // Normal state buttons restored
      expect(find.byIcon(Icons.minimize), findsOneWidget);
      expect(find.byIcon(Icons.crop_square), findsOneWidget);
      expect(find.byIcon(Icons.filter_none), findsNothing);
    });

    testWidgets('minimize→maximize→restore cycle works', (tester) async {
      await tester.pumpWidget(pumpCard());

      // Minimize
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();
      expect(find.textContaining('No issues detected'), findsNothing);

      // Restore to normal
      await tester.tap(find.byIcon(Icons.filter_none));
      await tester.pump();
      expect(find.textContaining('No issues detected'), findsOneWidget);

      // Maximize
      await tester.tap(find.byIcon(Icons.crop_square));
      await tester.pump();
      expect(find.textContaining('No issues detected'), findsOneWidget);

      // Restore to normal again
      await tester.tap(find.byIcon(Icons.filter_none));
      await tester.pump();
      expect(find.byIcon(Icons.minimize), findsOneWidget);
      expect(find.byIcon(Icons.crop_square), findsOneWidget);
    });

    testWidgets('close button works in all states', (tester) async {
      var closed = false;
      controller.dispose();
      controller = SleuthController();
      controller.initializeDetectorsForTest();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FloatingIssuesCard(
            controller: controller,
            onClose: () => closed = true,
            isDebugMode: false,
          ),
        ),
      ));

      // Minimize first
      await tester.tap(find.byIcon(Icons.minimize));
      await tester.pump();

      // Close button should still work
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(closed, isTrue);
    });
  });

  group('M6: Debug-mode banner', () {
    testWidgets('banner present in debug mode with default config',
        (tester) async {
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      expect(find.textContaining(bannerText), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);
    });

    testWidgets('tap dismiss hides banner', (tester) async {
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      expect(find.textContaining(bannerText), findsOneWidget);

      // Tap the close icon on the banner (last, since header also has close)
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();

      expect(find.textContaining(bannerText), findsNothing);
    });

    testWidgets('showDebugModeBanner:false hides banner', (tester) async {
      await tester.pumpWidget(pumpCard(
        isDebugMode: true,
        config: const SleuthConfig(showDebugModeBanner: false),
      ));

      expect(find.textContaining(bannerText), findsNothing);
    });

    testWidgets('isDebugMode:false hides banner', (tester) async {
      await tester.pumpWidget(pumpCard(isDebugMode: false));

      expect(find.textContaining(bannerText), findsNothing);
    });

    testWidgets('new widget instance shows banner again after dismiss',
        (tester) async {
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      // Dismiss (last close icon — first is the header's)
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();
      expect(find.textContaining(bannerText), findsNothing);

      // Force state disposal by pumping a different widget, then rebuild
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpWidget(pumpCard(isDebugMode: true));

      // Banner should reappear (per-instance, not persisted)
      expect(find.textContaining(bannerText), findsOneWidget);
    });
  });
}
