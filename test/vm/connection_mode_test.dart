import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/frame_verdict.dart';
import 'package:sleuth/src/vm/connection_mode.dart';

const _config = SleuthConfig(
  treeScanInterval: Duration(seconds: 1),
  enabledDetectors: {DetectorType.frameTiming},
  frameTimingWarmupDuration: Duration(seconds: 3),
);

FrameVerdict _verdict({bool full = false, bool correlated = false}) =>
    FrameVerdict(
      frameNumber: 1,
      totalFrameTime: const Duration(milliseconds: 16),
      uiThreadTime: const Duration(milliseconds: 8),
      rasterThreadTime: const Duration(milliseconds: 8),
      suspectedPhase: PipelinePhase.unknown,
      reason: 'test',
      isFullMode: full,
      isCorrelated: correlated,
    );

void main() {
  group('computeConnectionMode', () {
    test('disconnected when not initialised and VM not connected', () {
      final c = SleuthController(config: _config);
      addTearDown(c.dispose);
      expect(c.initializedAt, isNull);
      expect(c.isVmConnected, isFalse);
      expect(computeConnectionMode(c), ConnectionMode.disconnected);
    });

    test('warmup when initialised but warmup window not elapsed', () {
      final c = SleuthController(config: _config);
      addTearDown(c.dispose);
      c.initializeDetectorsForTest();
      c.markInitializedAtForTest(DateTime.now());
      expect(computeConnectionMode(c), ConnectionMode.warmup);
    });

    test('basic when warmup elapsed and no VM', () {
      final c = SleuthController(config: _config);
      addTearDown(c.dispose);
      c.initializeDetectorsForTest();
      c.markInitializedAtForTest(
        DateTime.now().subtract(const Duration(seconds: 10)),
      );
      expect(computeConnectionMode(c), ConnectionMode.basic);
    });

    test('basic when VM connected but no FrameVerdict yet', () {
      final c = SleuthController(config: _config);
      addTearDown(c.dispose);
      c.initializeDetectorsForTest();
      c.markInitializedAtForTest(
        DateTime.now().subtract(const Duration(seconds: 10)),
      );
      c.vmConnectedForTest = true;
      expect(c.verdictNotifier.value, isNull);
      expect(computeConnectionMode(c), ConnectionMode.basic);
    });

    test('full when verdict.isFullMode and not correlated', () {
      final c = SleuthController(config: _config);
      addTearDown(c.dispose);
      c.initializeDetectorsForTest();
      c.markInitializedAtForTest(
        DateTime.now().subtract(const Duration(seconds: 10)),
      );
      c.vmConnectedForTest = true;
      c.verdictNotifier.value = _verdict(full: true);
      expect(computeConnectionMode(c), ConnectionMode.full);
    });

    test('correlated overrides isFullMode', () {
      final c = SleuthController(config: _config);
      addTearDown(c.dispose);
      c.initializeDetectorsForTest();
      c.markInitializedAtForTest(
        DateTime.now().subtract(const Duration(seconds: 10)),
      );
      c.vmConnectedForTest = true;
      c.verdictNotifier.value = _verdict(full: true, correlated: true);
      expect(computeConnectionMode(c), ConnectionMode.correlated);
    });

    test('correlated wins even without isFullMode', () {
      final c = SleuthController(config: _config);
      addTearDown(c.dispose);
      c.initializeDetectorsForTest();
      c.markInitializedAtForTest(
        DateTime.now().subtract(const Duration(seconds: 10)),
      );
      c.vmConnectedForTest = true;
      c.verdictNotifier.value = _verdict(correlated: true);
      expect(computeConnectionMode(c), ConnectionMode.correlated);
    });

    test('basic when VM connected and verdict has neither flag', () {
      final c = SleuthController(config: _config);
      addTearDown(c.dispose);
      c.initializeDetectorsForTest();
      c.markInitializedAtForTest(
        DateTime.now().subtract(const Duration(seconds: 10)),
      );
      c.vmConnectedForTest = true;
      c.verdictNotifier.value = _verdict();
      expect(computeConnectionMode(c), ConnectionMode.basic);
    });

    test('warmup takes precedence when VM connected but warmup not elapsed',
        () {
      final c = SleuthController(config: _config);
      addTearDown(c.dispose);
      c.initializeDetectorsForTest();
      c.markInitializedAtForTest(DateTime.now());
      c.vmConnectedForTest = true;
      expect(computeConnectionMode(c), ConnectionMode.warmup);
    });

    test('warmup wins even when verdict says correlated', () {
      final c = SleuthController(config: _config);
      addTearDown(c.dispose);
      c.initializeDetectorsForTest();
      c.markInitializedAtForTest(DateTime.now());
      c.vmConnectedForTest = true;
      c.verdictNotifier.value = _verdict(full: true, correlated: true);
      expect(computeConnectionMode(c), ConnectionMode.warmup);
    });
  });
}
