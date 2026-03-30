import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/detector_thresholds.dart';

void main() {
  group('DetectorThresholds', () {
    test('defaults match documented values', () {
      const t = DetectorThresholds();
      expect(t.shaderJankMs, 100);
      expect(t.heavyComputeGapMs, 8);
      expect(t.gpuPressureRatio, 1.5);
      expect(t.memoryGrowthBytesPerSec, 512000);
      expect(t.memoryCapacityPercent, 0.80);
      expect(t.shallowRebuildMaxDepth, 3);
      expect(t.setStateScopeOwnershipPercent, 0.5);
      expect(t.keepAliveMax, 5);
      expect(t.animatedBuilderMinSubtreeSize, 20);
      expect(t.fontLoadingMaxFamilies, 3);
    });

    test('custom values override defaults', () {
      const t = DetectorThresholds(
        shaderJankMs: 50,
        heavyComputeGapMs: 4,
        gpuPressureRatio: 2.0,
        memoryGrowthBytesPerSec: 256000,
        memoryCapacityPercent: 0.70,
        shallowRebuildMaxDepth: 5,
        setStateScopeOwnershipPercent: 0.3,
        keepAliveMax: 10,
        animatedBuilderMinSubtreeSize: 10,
        fontLoadingMaxFamilies: 1,
      );
      expect(t.shaderJankMs, 50);
      expect(t.heavyComputeGapMs, 4);
      expect(t.gpuPressureRatio, 2.0);
      expect(t.memoryGrowthBytesPerSec, 256000);
      expect(t.memoryCapacityPercent, 0.70);
      expect(t.shallowRebuildMaxDepth, 5);
      expect(t.setStateScopeOwnershipPercent, 0.3);
      expect(t.keepAliveMax, 10);
      expect(t.animatedBuilderMinSubtreeSize, 10);
      expect(t.fontLoadingMaxFamilies, 1);
    });

    test('is const-constructable', () {
      // Verify const constructor works (compile-time check).
      const t = DetectorThresholds();
      expect(t, isNotNull);
    });
  });
}
