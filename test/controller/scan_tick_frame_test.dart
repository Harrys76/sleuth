import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';

void main() {
  testWidgets('a scan tick on a static screen schedules its own frame', (
    tester,
  ) async {
    final controller = SleuthController(
      config: const SleuthConfig(treeScanInterval: Duration(seconds: 1)),
    )..initializeDetectorsForTest();
    controller.markInitializedForTest();

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('static'))),
    );
    controller.startTreeScanning(tester.element(find.byType(Scaffold)));
    final ticksBefore = controller.scanTickNotifier.value;

    // Let the timer fire without pumping a frame.
    await tester.binding.delayed(const Duration(milliseconds: 1100));

    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: 'the tick must request a frame when none is pending',
    );
    expect(controller.scanTickNotifier.value, ticksBefore);

    await tester.pump();
    expect(controller.scanTickNotifier.value, ticksBefore + 1);
    controller.dispose();
  });
}
