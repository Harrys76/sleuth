import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/ui/dashboard_sheet.dart';

void main() {
  group('DBG badge', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('DBG badge is absent when enableDebugCallbacks is false',
        (tester) async {
      // Default config has enableDebugCallbacks = false
      expect(controller.isDebugCallbacksActive, isFalse);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardSheet(
              controller: controller,
              onClose: () {},
            ),
          ),
        ),
      );

      // DBG text should not be in the widget tree
      expect(find.text('DBG'), findsNothing);
    });

    testWidgets('VM+/FRAME badge is always present', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardSheet(
              controller: controller,
              onClose: () {},
            ),
          ),
        ),
      );

      // FRAME badge should be visible (not connected to VM)
      expect(find.text('FRAME'), findsOneWidget);
    });

    testWidgets('DBG badge is present when enableDebugCallbacks is true',
        (tester) async {
      final dbgController = WatchdogController(
        config: const WatchdogConfig(enableDebugCallbacks: true),
      );
      dbgController.initializeDetectorsForTest();

      expect(dbgController.isDebugCallbacksActive, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardSheet(
              controller: dbgController,
              onClose: () {},
            ),
          ),
        ),
      );

      expect(find.text('DBG'), findsOneWidget);

      dbgController.dispose();
    });

    test('isDebugCallbacksActive returns false by default', () {
      expect(controller.isDebugCallbacksActive, isFalse);
    });

    test('kDebugMode is true in test environment', () {
      // Confirms that the only missing condition for DBG badge is
      // isDebugCallbacksActive, not kDebugMode.
      expect(kDebugMode, isTrue);
    });
  });
}
