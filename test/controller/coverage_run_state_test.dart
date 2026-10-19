import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/coverage_report.dart';
import 'package:sleuth/src/controller/run_state.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';

void main() {
  group('CoverageReport for the controller', () {
    test('default config without the VM', () {
      final controller = SleuthController()..initializeDetectorsForTest();
      addTearDown(controller.dispose);
      final report = controller.coverageNotifier.value;

      expect(report.typesWith(CheckCoverage.needsVm), [
        DetectorType.shaderJank,
        DetectorType.heavyCompute,
        DetectorType.platformChannel,
        DetectorType.memoryPressure,
        DetectorType.streamResource,
        DetectorType.eventLoopStall,
      ]);
      expect(report.typesWith(CheckCoverage.partial), [
        DetectorType.repaint,
        DetectorType.rebuild,
        DetectorType.gpuPressure,
      ]);
      expect(report.typesWith(CheckCoverage.optInOff), [
        DetectorType.trackedResource,
      ]);
      expect(report.count(CheckCoverage.on), 11);
      expect(report.count(CheckCoverage.disabled), 0);
      expect(report.byType, hasLength(DetectorType.values.length - 1));
    });

    test('default config with the VM', () {
      final controller = SleuthController()..initializeDetectorsForTest();
      addTearDown(controller.dispose);
      controller.simulateVmStateChangeForTest(true);
      final report = controller.coverageNotifier.value;

      expect(report.count(CheckCoverage.on), 19);
      expect(report.typesWith(CheckCoverage.optInOff), [
        DetectorType.platformChannel,
        DetectorType.trackedResource,
      ]);

      controller.simulateVmStateChangeForTest(false);
      expect(controller.coverageNotifier.value.count(CheckCoverage.needsVm), 6);
    });

    test('a custom enabledDetectors set marks the rest disabled', () {
      final controller = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {
            DetectorType.frameTiming,
            DetectorType.memoryPressure,
            DetectorType.rebuild,
          },
        ),
      )..initializeDetectorsForTest();
      addTearDown(controller.dispose);
      final report = controller.coverageNotifier.value;

      expect(report.byType[DetectorType.frameTiming], CheckCoverage.on);
      expect(report.byType[DetectorType.memoryPressure], CheckCoverage.needsVm);
      expect(report.byType[DetectorType.rebuild], CheckCoverage.partial);
      expect(
        report.count(CheckCoverage.disabled),
        DetectorType.values.length - 1 - 3,
      );
    });

    test('opt-ins switched on', () {
      final controller = SleuthController(
        config: const SleuthConfig(profilePlatformChannels: true),
      )..initializeDetectorsForTest();
      addTearDown(controller.dispose);
      controller.simulateVmStateChangeForTest(true);
      expect(
        controller.coverageNotifier.value.byType[DetectorType.platformChannel],
        CheckCoverage.on,
      );

      final notified = <CoverageReport>[];
      controller.coverageNotifier.addListener(
        () => notified.add(controller.coverageNotifier.value),
      );
      final resource = Object();
      controller.trackResource('cache', resource);
      expect(notified, hasLength(1));
      expect(
        notified.single.byType[DetectorType.trackedResource],
        CheckCoverage.on,
      );
      expect(notified.single.count(CheckCoverage.on), 21);

      // Later registrations leave the report alone.
      controller.trackResource('cache', Object());
      expect(notified, hasLength(1));
    });

    test('debug callbacks feed rebuild and repaint without the VM', () {
      final controller = SleuthController(
        config: const SleuthConfig(enableDebugCallbacks: true),
      )..initializeDetectorsForTest();
      addTearDown(controller.dispose);
      final report = controller.coverageNotifier.value;

      expect(report.byType[DetectorType.rebuild], CheckCoverage.on);
      expect(report.byType[DetectorType.repaint], CheckCoverage.on);
      expect(report.byType[DetectorType.gpuPressure], CheckCoverage.partial);
    });

    test('equal reports compare equal', () {
      CoverageReport build(bool vm) => CoverageReport.compute(
        enabled: {DetectorType.memoryPressure},
        lifecycleOf: (_) => DetectorLifecycle.vmOnly,
        vmConnected: vm,
        profilePlatformChannels: false,
        resourcesTracked: false,
      );
      expect(build(true), build(true));
      expect(build(true).hashCode, build(true).hashCode);
      expect(build(true), isNot(build(false)));
    });
  });

  group('SleuthRunState', () {
    test('starting, then warming up, then running', () {
      fakeAsync((async) {
        final controller = SleuthController()..initializeDetectorsForTest();
        expect(
          controller.runStateNotifier.value.phase,
          SleuthRunPhase.starting,
        );

        controller.markInitializedAtForTest(DateTime.now());
        controller.refreshRunStateForTest();
        expect(
          controller.runStateNotifier.value.phase,
          SleuthRunPhase.warmingUp,
        );
        expect(controller.warmupTimerActiveForTest, isTrue);

        async.elapse(controller.config.frameTimingWarmupDuration);
        expect(controller.runStateNotifier.value.phase, SleuthRunPhase.running);
        expect(controller.warmupTimerActiveForTest, isFalse);
        controller.dispose();
      });
    });

    test('dispose cancels the warm-up timer', () {
      fakeAsync((async) {
        final controller = SleuthController()..initializeDetectorsForTest();
        controller.markInitializedAtForTest(DateTime.now());
        controller.refreshRunStateForTest();
        expect(controller.warmupTimerActiveForTest, isTrue);
        controller.dispose();
        expect(controller.warmupTimerActiveForTest, isFalse);
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('a lost VM counts reconnect attempts until it stops retrying', () {
      fakeAsync((async) {
        final controller = SleuthController()..initializeDetectorsForTest();
        final fake = _FailingVmClient();
        controller
          ..setVmClientForTest(fake)
          ..markInitializedAtForTest(DateTime(2026))
          ..markInitializedForTest();

        controller.onVmConnectionChangedForTest(false);
        var state = controller.runStateNotifier.value;
        expect(state.vmConnected, isFalse);
        expect(state.reconnectAttempt, 1);
        expect(state.maxReconnectAttempts, 7);
        expect(state.stoppedRetrying, isFalse);

        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        expect(controller.runStateNotifier.value.reconnectAttempt, 2);

        async.elapse(const Duration(seconds: 70));
        async.flushMicrotasks();
        state = controller.runStateNotifier.value;
        expect(fake.connectCallCount, 7);
        expect(state.reconnectAttempt, isNull);
        expect(state.stoppedRetrying, isTrue);
        controller.dispose();
      });
    });

    test('a connected VM clears the attempt count', () {
      final controller = SleuthController()..initializeDetectorsForTest();
      addTearDown(controller.dispose);
      controller.simulateVmStateChangeForTest(true);
      final state = controller.runStateNotifier.value;
      expect(state.vmConnected, isTrue);
      expect(state.reconnectAttempt, isNull);
      expect(state.stoppedRetrying, isFalse);
    });
  });

  test('the debug banner dismissal lives for the session', () {
    final controller = SleuthController();
    addTearDown(controller.dispose);
    expect(controller.debugBannerDismissed, isFalse);
    controller.debugBannerDismissed = true;
    expect(controller.debugBannerDismissed, isTrue);
  });
}

/// A VM client whose connects always fail, so the background ladder runs
/// to its end.
class _FailingVmClient extends VmServiceClient {
  int connectCallCount = 0;

  @override
  bool get isConnected => false;

  @override
  bool get isDisposed => false;

  @override
  Future<bool> connect({
    int maxRetries = 3,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    connectCallCount++;
    return false;
  }

  @override
  Future<bool> reconnect() async => false;

  @override
  void dispose() {}
}
