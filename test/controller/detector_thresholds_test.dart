import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/detector_thresholds.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';
import 'package:vm_service/vm_service.dart' as vm;

import '../helpers/fake_vm_service.dart';

void main() {
  group('DetectorThresholds', () {
    test('defaults match documented values', () {
      const t = DetectorThresholds();
      expect(t.shaderJankMs, 100);
      expect(t.heavyComputeGapMs, isNull);
      expect(DetectorThresholds.defaultHeavyComputeGapMs, 8);
      expect(t.gpuPressureRatio, 2.0);
      expect(t.memoryGrowthBytesPerSec, 512000);
      expect(t.memoryCapacityPercent, 0.80);
      expect(t.memoryBudgetBytes, isNull);
      expect(t.setStateScopeOwnershipPercent, 0.5);
      expect(t.keepAliveMax, 5);
      expect(t.fontLoadingMaxFamilies, 3);
    });

    test('custom values override defaults', () {
      const t = DetectorThresholds(
        shaderJankMs: 50,
        heavyComputeGapMs: 4,
        gpuPressureRatio: 3.0,
        memoryGrowthBytesPerSec: 256000,
        memoryCapacityPercent: 0.70,
        memoryBudgetBytes: 1500000000,
        setStateScopeOwnershipPercent: 0.3,
        keepAliveMax: 10,
        fontLoadingMaxFamilies: 1,
      );
      expect(t.shaderJankMs, 50);
      expect(t.heavyComputeGapMs, 4);
      expect(t.gpuPressureRatio, 3.0);
      expect(t.memoryGrowthBytesPerSec, 256000);
      expect(t.memoryCapacityPercent, 0.70);
      expect(t.memoryBudgetBytes, 1500000000);
      expect(t.setStateScopeOwnershipPercent, 0.3);
      expect(t.keepAliveMax, 10);
      expect(t.fontLoadingMaxFamilies, 1);
    });

    test('memoryBudgetBytes must be positive when set', () {
      expect(
        () => DetectorThresholds(memoryBudgetBytes: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => DetectorThresholds(memoryBudgetBytes: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('is const-constructable', () {
      // Verify const constructor works (compile-time check).
      const t = DetectorThresholds();
      expect(t, isNotNull);
    });
  });

  group('memory thresholds reach MemoryPressureDetector', () {
    test('defaults: no budget, 0.80, 180 GC/min', () {
      expect(const SleuthConfig().gcRateThresholdPerMin, 180);
      final controller = SleuthController(config: const SleuthConfig());
      addTearDown(controller.dispose);
      controller.initializeDetectorsForTest();
      final memory = controller.memoryPressureDetector!;
      expect(memory.memoryBudgetBytes, isNull);
      expect(memory.capacityThresholdPercent, 0.80);
      expect(memory.gcRateThresholdPerMin, 180);
    });

    test('configured budget and fraction are passed through', () {
      final controller = SleuthController(
        config: const SleuthConfig(
          gcRateThresholdPerMin: 90,
          thresholds: DetectorThresholds(
            memoryBudgetBytes: 1500000000,
            memoryCapacityPercent: 0.7,
          ),
        ),
      );
      addTearDown(controller.dispose);
      controller.initializeDetectorsForTest();
      final memory = controller.memoryPressureDetector!;
      expect(memory.memoryBudgetBytes, 1500000000);
      expect(memory.capacityThresholdPercent, 0.7);
      expect(memory.gcRateThresholdPerMin, 90);
    });
  });

  test('the controller passes each GC event\'s raw gcType through', () {
    final controller = SleuthController(
      config: const SleuthConfig(gcRateThresholdPerMin: 30),
    );
    addTearDown(controller.dispose);
    controller.initializeDetectorsForTest();
    for (var i = 0; i < 10; i++) {
      controller.feedGcEventForTest(
        vm.Event.parse({
          'type': 'Event',
          'kind': 'GC',
          'timestamp': i,
          'gcType': i < 4 ? 'MarkSweep' : (i < 8 ? 'Scavenge' : null),
        })!,
      );
    }
    final args = controller.memoryPressureDetector!.issues
        .singleWhere((i) => i.stableId == 'gc_pressure')
        .extraTraceArgs!;
    expect(args['observedGcEvents'], '10');
    expect(args['oldGenCount'], '4');
    expect(args['scavengeCount'], '6');
  });

  group('GC pause time from the controller', () {
    vm.Event pauseEvent(num newTime, num oldTime) => vm.Event.parse({
      'type': 'Event',
      'kind': 'GC',
      'timestamp': 0,
      'gcType': 'Scavenge',
      'isolate': {
        'type': '@Isolate',
        'id': 'isolates/1',
        'number': '1',
        'name': 'main',
        'isSystemIsolate': false,
        'isolateGroupId': 'isolateGroups/1',
      },
      'new': {'type': 'HeapSpace', 'time': newTime},
      'old': {'type': 'HeapSpace', 'time': oldTime},
    })!;

    Future<SleuthController> controllerWith({required bool verified}) async {
      final controller = SleuthController(
        config: const SleuthConfig(gcRateThresholdPerMin: 30),
      );
      addTearDown(controller.dispose);
      controller.initializeDetectorsForTest();
      final client = VmServiceClient(
        ownIsolateIdResolver: () => verified ? 'isolates/1' : null,
      );
      addTearDown(client.dispose);
      await client.startSessionForTest(FakeVmService());
      controller.setVmClientForTest(client);
      return controller;
    }

    test('sums new and old time, integer-encoded values included, when the '
        'client verified its own isolate', () async {
      final controller = await controllerWith(verified: true);
      final memory = controller.memoryPressureDetector!;
      controller.feedGcEventForTest(pauseEvent(0, 1));
      // Clears the window but keeps the pause baseline.
      memory.reset();
      for (var i = 1; i <= 6; i++) {
        controller.feedGcEventForTest(pauseEvent(i * 0.001, 1));
      }
      final args = memory.issues
          .singleWhere((i) => i.stableId == 'gc_pressure')
          .extraTraceArgs!;
      expect(args['gcPauseMs'], '6.0');
    });

    test('stamps nothing when the client did not verify its own '
        'isolate', () async {
      final controller = await controllerWith(verified: false);
      final memory = controller.memoryPressureDetector!;
      controller.feedGcEventForTest(pauseEvent(0, 1));
      memory.reset();
      for (var i = 1; i <= 6; i++) {
        controller.feedGcEventForTest(pauseEvent(i * 0.001, 1));
      }
      final args = memory.issues
          .singleWhere((i) => i.stableId == 'gc_pressure')
          .extraTraceArgs!;
      expect(args.containsKey('gcPauseMs'), isFalse);
      expect(memory.gcWindowStats.pauseAvailable, isFalse);
    });
  });

  group('time-share thresholds', () {
    test('default 10 % for build and paint', () {
      const t = DetectorThresholds();
      expect(t.buildTimePercentThreshold, 10);
      expect(t.paintTimePercentThreshold, 10);
    });

    test('reject 0 and values above 100', () {
      expect(
        () => DetectorThresholds(buildTimePercentThreshold: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => DetectorThresholds(buildTimePercentThreshold: 101),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => DetectorThresholds(paintTimePercentThreshold: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => DetectorThresholds(paintTimePercentThreshold: 101),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => DetectorThresholds(
          buildTimePercentThreshold: 100,
          paintTimePercentThreshold: 0.5,
        ),
        returnsNormally,
      );
    });

    test('SleuthConfig.copyWith keeps the thresholds object', () {
      const config = SleuthConfig(
        thresholds: DetectorThresholds(
          buildTimePercentThreshold: 25,
          paintTimePercentThreshold: 15,
        ),
      );
      final copy = config.copyWith(rebuildThreshold: 20);
      expect(copy.thresholds.buildTimePercentThreshold, 25);
      expect(copy.thresholds.paintTimePercentThreshold, 15);
      expect(copy.rebuildThreshold, 20);
    });

    test('the controller wires them into the detectors; the per-widget '
        'count knobs stay separate', () {
      final controller = SleuthController(
        config: const SleuthConfig(
          rebuildThreshold: 12,
          thresholds: DetectorThresholds(
            buildTimePercentThreshold: 25,
            paintTimePercentThreshold: 15,
          ),
        ),
      );
      addTearDown(controller.dispose);
      controller.initializeDetectorsForTest();
      expect(controller.rebuildDetector.buildTimePercentThreshold, 25);
      expect(controller.rebuildDetector.rebuildsPerSecThreshold, 12);
      expect(controller.repaintDetector!.paintTimePercentThreshold, 15);
      expect(controller.repaintDetector!.paintFrequencyThreshold, 30);
    });
  });
}
