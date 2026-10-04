import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/ui/sleuth_overlay.dart';

/// Pumps [SleuthOverlay] around [app] (a one-route [MaterialApp] by
/// default) with a test-initialised controller. The overlay owns and
/// disposes the controller.
///
/// Answers every [SystemChannels.platform] call with null, so a back that
/// reaches `SystemNavigator.pop` or `setFrameworkHandlesBack` does not
/// throw.
Future<SleuthController> pumpOverlay(
  WidgetTester tester, {
  SleuthConfig? config,
  Widget? app,
}) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  final controller = SleuthController(config: config)
    ..initializeDetectorsForTest()
    ..markInitializedForTest();
  await tester.pumpWidget(
    SleuthOverlay(
      controller: controller,
      child:
          app ??
          const MaterialApp(
            home: Scaffold(body: Center(child: Text('app'))),
          ),
    ),
  );
  await tester.pump();
  return controller;
}

/// Opens the dashboard through the controller-owned state.
Future<void> openDashboard(
  WidgetTester tester,
  SleuthController controller,
) async {
  controller.overlayUiState.dashboardOpen = true;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Sends a system back (Android back button / `didPopRoute`) and pumps.
Future<bool> systemBack(WidgetTester tester) async {
  final handled = await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return handled;
}
