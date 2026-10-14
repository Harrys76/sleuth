// The controller's two paths into PlatformChannelDetector's buffer: a VM
// connection change and a capture scenario reset.
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/platform_channel_detector.dart';
import 'package:sleuth/src/utils/own_work_log.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';
import 'package:vm_service/vm_service.dart' show TimelineEvent;

ParsedTimelineData _calls(List<int> tsUs) => ParsedTimelineData(
  platformChannelEvents: [
    for (final ts in tsUs)
      TimelineEvent.parse({
        'name': 'PlatformChannel',
        'cat': '',
        'ph': 'X',
        'dur': 100,
        'ts': ts,
        'pid': 1,
        'tid': 1,
      })!,
  ],
);

void main() {
  late SleuthController controller;
  late PlatformChannelDetector detector;

  setUp(() {
    controller = SleuthController(config: const SleuthConfig(captureMode: true))
      ..initializeDetectorsForTest();
    detector = controller.detectorsForAudit
        .whereType<PlatformChannelDetector>()
        .single;
  });

  tearDown(() => controller.dispose());

  test('a VM connection change drops the calls the detector holds', () {
    controller.simulateVmStateChangeForTest(true);
    final now = OwnWorkLog.now();
    controller.feedTimelineDataForTest(_calls([now, now + 1000]));
    expect(detector.windowCallCount, 2);

    controller.simulateVmStateChangeForTest(false);
    controller.simulateVmStateChangeForTest(true);
    expect(detector.windowCallCount, 0);
    // The reconnect's full read delivers them again.
    controller.feedTimelineDataForTest(_calls([now, now + 1000]));
    expect(detector.windowCallCount, 0);
  });

  test('a capture reset keeps calls made before it out of the scenario', () {
    controller.simulateVmStateChangeForTest(true);
    final before = OwnWorkLog.now();
    controller.resetCaptureState();
    controller.feedTimelineDataForTest(_calls([before - 500000, before]));
    expect(detector.windowCallCount, 0);
    final after = OwnWorkLog.now() + 1000;
    controller.feedTimelineDataForTest(_calls([after]));
    expect(detector.windowCallCount, 1);
  });
}
