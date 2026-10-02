import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/detector_thresholds.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:vm_service/vm_service.dart' as vm;

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
}
