import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';

void main() {
  group('SleuthConfig.minimal', () {
    test('disables opt-in subsystems', () {
      final config = SleuthConfig.minimal();
      expect(config.enableNetworkMonitoring, isFalse);
      expect(config.enableDebugCallbacks, isFalse);
      expect(config.enableDeepDebugInstrumentation, isFalse);
      expect(config.aiChat, isNull);
    });

    test('enables only the safe default detector set', () {
      final config = SleuthConfig.minimal();
      expect(config.enabledDetectors, {
        DetectorType.frameTiming,
        DetectorType.rebuild,
        DetectorType.repaint,
        DetectorType.listview,
        DetectorType.imageMemory,
        DetectorType.globalKey,
        DetectorType.layoutBottleneck,
        DetectorType.opacity,
        DetectorType.animatedBuilder,
        DetectorType.customPainter,
        DetectorType.fontLoading,
        DetectorType.repaintBoundary,
        DetectorType.startup,
      });
      // VM-only / hybrid / advanced detectors should NOT be enabled.
      expect(
        config.enabledDetectors.contains(DetectorType.shallowRebuildRisk),
        isFalse,
      );
      expect(
        config.enabledDetectors.contains(DetectorType.heavyCompute),
        isFalse,
      );
      expect(
        config.enabledDetectors.contains(DetectorType.shaderJank),
        isFalse,
      );
      expect(
        config.enabledDetectors.contains(DetectorType.networkMonitor),
        isFalse,
      );
    });

    test('inherits the default tree scan interval', () {
      final config = SleuthConfig.minimal();
      expect(config.treeScanInterval, const Duration(seconds: 1));
      expect(config.adaptiveScanEnabled, isTrue);
    });
  });

  group('SleuthConfig.performance', () {
    test('uses a relaxed scan cadence', () {
      final config = SleuthConfig.performance();
      expect(config.treeScanInterval, const Duration(seconds: 2));
      expect(config.adaptiveScanEnabled, isTrue);
    });

    test('only enables structural-lifecycle detectors', () {
      final config = SleuthConfig.performance();
      // Every enabled type must correspond to a structural detector —
      // no runtime, vmOnly, or hybrid members allowed.
      for (final type in config.enabledDetectors) {
        expect(
          _lifecycleOf(type),
          DetectorLifecycle.structural,
          reason: '$type is not structural — preset must exclude it',
        );
      }
    });

    test('excludes frameTiming and shallowRebuildRisk explicitly', () {
      final config = SleuthConfig.performance();
      expect(
        config.enabledDetectors.contains(DetectorType.frameTiming),
        isFalse,
        reason: 'frameTiming is runtime-lifecycle, not structural',
      );
      expect(
        config.enabledDetectors.contains(DetectorType.shallowRebuildRisk),
        isFalse,
        reason: 'shallowRebuildRisk is hybrid-lifecycle, not structural',
      );
    });

    test('shrinks capture buffer and disables opt-in subsystems', () {
      final config = SleuthConfig.performance();
      expect(config.captureBufferCapacity, 10);
      expect(config.enableNetworkMonitoring, isFalse);
      expect(config.enableDebugCallbacks, isFalse);
      expect(config.enableDeepDebugInstrumentation, isFalse);
    });
  });

  group('presets can be used with a controller', () {
    test('minimal constructs a controller without error', () {
      final controller = SleuthController(config: SleuthConfig.minimal());
      controller.dispose();
    });

    test('performance constructs a controller without error', () {
      final controller = SleuthController(config: SleuthConfig.performance());
      controller.dispose();
    });
  });
}

/// Maps DetectorType to its canonical DetectorLifecycle.
///
/// Mirrors the classification declared in each detector file. Used by
/// `performance` preset tests to verify we never leak a non-structural
/// detector into the preset set. Keep in sync with detector source.
DetectorLifecycle _lifecycleOf(DetectorType type) {
  switch (type) {
    case DetectorType.frameTiming:
    case DetectorType.networkMonitor:
      return DetectorLifecycle.runtime;
    case DetectorType.shaderJank:
    case DetectorType.heavyCompute:
    case DetectorType.platformChannel:
    case DetectorType.memoryPressure:
      return DetectorLifecycle.vmOnly;
    case DetectorType.repaint:
    case DetectorType.rebuild:
    case DetectorType.shallowRebuildRisk:
    case DetectorType.gpuPressure:
      return DetectorLifecycle.hybrid;
    case DetectorType.setStateScope:
    case DetectorType.layoutBottleneck:
    case DetectorType.listview:
    case DetectorType.imageMemory:
    case DetectorType.globalKey:
    case DetectorType.nestedScroll:
    case DetectorType.customPainter:
    case DetectorType.keepAlive:
    case DetectorType.animatedBuilder:
    case DetectorType.opacity:
    case DetectorType.fontLoading:
    case DetectorType.repaintBoundary:
      return DetectorLifecycle.structural;
    case DetectorType.startup:
      return DetectorLifecycle.structural;
    case DetectorType.custom:
      return DetectorLifecycle.structural;
  }
}
