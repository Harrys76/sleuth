import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';

void main() {
  group('DBG badge', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
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
            body: FloatingIssuesCard(
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
            body: FloatingIssuesCard(
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
      final dbgController = SleuthController(
        config: const SleuthConfig(enableDebugCallbacks: true),
      );
      dbgController.initializeDetectorsForTest();

      expect(dbgController.isDebugCallbacksActive, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(
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
