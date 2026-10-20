import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';

void main() {
  testWidgets('a hot reload drops the previous counts for Why it rebuilds', (
    tester,
  ) async {
    final controller = SleuthController(
      config: const SleuthConfig(enableDebugCallbacks: true),
    )..initializeDetectorsForTest();
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final root = tester.element(find.byType(Scaffold));

    controller
      ..scanTreeFullPathForTest(root)
      ..scanTreeFullPathForTest(root);
    expect(controller.lastDebugSnapshot, isNotNull);

    controller
      ..reassembleForTest()
      ..scanTreeFullPathForTest(root);
    expect(controller.lastDebugSnapshot, isNull);

    controller.scanTreeFullPathForTest(root);
    expect(controller.lastDebugSnapshot, isNotNull);
    // Disposed here: debug callbacks set rendering debug variables that
    // the test binding checks before tear-down.
    controller.dispose();
  });
}
