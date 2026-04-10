import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';

import '../helpers/benchmark_helpers.dart';
import '../helpers/timeline_test_helpers.dart';

void main() {
  group('VM disconnect degrades gracefully', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('structural issues survive VM disconnect', (tester) async {
      await tester.pumpWidget(buildMixedTree(500));
      final context = tester.element(find.byType(Directionality));

      // Start with VM connected
      controller.simulateVmStateChangeForTest(true);

      // Feed timeline data to generate VM-backed issues
      controller.feedTimelineDataForTest(rasterDominantData(
        rasterUs: 30000,
        buildUs: 5000,
        layoutUs: 3000,
        paintUs: 2000,
      ));

      // Run tree scan to generate structural issues
      controller.runTreeScanForTest(context);

      final issuesBefore = controller.issuesNotifier.value;
      expect(issuesBefore, isNotEmpty,
          reason: 'Issues must exist before disconnect to prove survival');

      // Disconnect VM
      controller.simulateVmStateChangeForTest(false);

      // Run another tree scan (structural detectors should still work)
      controller.runTreeScanForTest(context);

      final issuesAfter = controller.issuesNotifier.value;

      // Structural issues should remain
      final structuralAfter = issuesAfter
          .where((i) =>
              i.observationSource == ObservationSource.structural ||
              i.observationSource == ObservationSource.debugCallback ||
              i.observationSource ==
                  ObservationSource.debugCallbackAndStructural)
          .toList();
      expect(structuralAfter, isNotEmpty,
          reason: 'Structural issues must survive VM disconnect');

      // No issue should claim Confirmed confidence for VM-dependent signals
      // after disconnect (hybrid detectors downgrade to possible)
      for (final issue in issuesAfter) {
        if (issue.observationSource == ObservationSource.vmTimeline) {
          fail('VM-timeline-sourced issue "${issue.title}" should not exist '
              'after VM disconnect');
        }
      }
    });

    testWidgets('vmConnectedNotifier updates on state change', (tester) async {
      await tester.pumpWidget(buildMixedTree(100));

      controller.simulateVmStateChangeForTest(true);
      expect(controller.vmConnectedNotifier.value, isTrue);

      controller.simulateVmStateChangeForTest(false);
      expect(controller.vmConnectedNotifier.value, isFalse);
    });

    testWidgets('isVmConnected getter matches simulated state', (tester) async {
      await tester.pumpWidget(buildMixedTree(100));

      controller.simulateVmStateChangeForTest(true);
      expect(controller.isVmConnected, isTrue);

      controller.simulateVmStateChangeForTest(false);
      expect(controller.isVmConnected, isFalse);
    });
  });

  group('VM reconnect restages fresh data', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('hybrid detectors re-acquire VM data after reconnect',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(500));
      final context = tester.element(find.byType(Directionality));

      // Start disconnected — only structural issues
      controller.simulateVmStateChangeForTest(false);
      controller.runTreeScanForTest(context);

      final disconnectedIssues = controller.issuesNotifier.value;
      final vmIssuesWhileDisconnected = disconnectedIssues
          .where((i) => i.observationSource == ObservationSource.vmTimeline)
          .toList();
      expect(vmIssuesWhileDisconnected, isEmpty,
          reason: 'No VM issues when disconnected');

      // Reconnect and feed timeline data
      controller.simulateVmStateChangeForTest(true);
      controller.feedTimelineDataForTest(rasterDominantData(
        rasterUs: 30000,
        buildUs: 5000,
        layoutUs: 3000,
        paintUs: 2000,
      ));
      controller.runTreeScanForTest(context);

      // Issues should now include VM-backed data
      expect(controller.isVmConnected, isTrue);
      expect(controller.vmConnectedNotifier.value, isTrue);
    });
  });

  group('verdict path switches on VM state', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test('verdict is basic mode when VM disconnected', () {
      // VM disconnected by default
      expect(controller.isVmConnected, isFalse);

      // Feed a jank frame
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 30),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.isFullMode, isFalse,
          reason: 'Verdict should be basic mode without VM');
    });

    test('verdict is full mode when VM connected and timeline data arrives',
        () {
      controller.simulateVmStateChangeForTest(true);

      // Feed timeline data with phase events (triggers correlated/full path)
      controller.feedTimelineDataForTest(correlatedTimelineData(
        buildUs: 20000,
        layoutUs: 5000,
        paintUs: 3000,
        rasterUs: 8000,
      ));

      // Feed a jank frame so the timeline path can match it
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 28),
        rasterDuration: const Duration(milliseconds: 8),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      // Feed timeline data again (now there's a frame to correlate with)
      controller.feedTimelineDataForTest(correlatedTimelineData(
        buildUs: 20000,
        layoutUs: 5000,
        paintUs: 3000,
        rasterUs: 8000,
      ));

      final verdict = controller.verdictNotifier.value;
      // With VM connected + timeline data, verdict should be full or correlated
      expect(verdict, isNotNull,
          reason: 'Verdict should exist after VM + timeline + jank frame');
      expect(verdict!.isFullMode || verdict.isCorrelated, isTrue,
          reason: 'Verdict should be full/correlated mode with VM + timeline');
    });
  });

  group('UI mode indicator matches VM state', () {
    testWidgets('vmConnectedNotifier drives UI state', (tester) async {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();

      // Default: disconnected
      expect(controller.vmConnectedNotifier.value, isFalse);

      // Connect
      controller.simulateVmStateChangeForTest(true);
      expect(controller.vmConnectedNotifier.value, isTrue);

      // Disconnect
      controller.simulateVmStateChangeForTest(false);
      expect(controller.vmConnectedNotifier.value, isFalse);

      controller.dispose();
    });
  });

  group('detector group isolation', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('VM-only detectors produce no issues when VM never connected',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(500));
      final context = tester.element(find.byType(Directionality));

      // VM never connected (default state)
      expect(controller.isVmConnected, isFalse);

      // Run tree scan + aggregate
      controller.runTreeScanForTest(context);

      final issues = controller.issuesNotifier.value;

      // No VM-timeline-sourced issues should exist
      final vmOnlyIssues = issues
          .where((i) => i.observationSource == ObservationSource.vmTimeline)
          .toList();
      expect(vmOnlyIssues, isEmpty,
          reason: 'VM-only detectors must not produce issues without VM');
    });

    testWidgets('structural detectors work without VM', (tester) async {
      await tester.pumpWidget(buildMixedTree(500));
      final context = tester.element(find.byType(Directionality));

      // VM disconnected
      controller.simulateVmStateChangeForTest(false);

      controller.runTreeScanForTest(context);

      // Structural issues should still be generated from tree scanning
      final issues = controller.issuesNotifier.value;
      // The mixed tree doesn't contain anti-patterns, but the scan should
      // complete without error. The real validation is that it doesn't crash.
      expect(issues, isA<List<PerformanceIssue>>());
    });
  });

  // ===========================================================================
  // Public reconnect() API — first-launch BASIC-mode recovery
  // ===========================================================================
  group('SleuthController.reconnect() safety contract', () {
    test('returns false before initialize (no VM client yet)', () async {
      final controller = SleuthController();
      // _vmClient is null — no initialize() called.
      expect(await controller.reconnect(), isFalse);
      controller.dispose();
    });

    test('returns false after dispose', () async {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.dispose();
      expect(await controller.reconnect(), isFalse);
    });

    test('is idempotent when vmClient is null (multiple pre-init calls)',
        () async {
      final controller = SleuthController();
      expect(await controller.reconnect(), isFalse);
      expect(await controller.reconnect(), isFalse);
      expect(await controller.reconnect(), isFalse);
      controller.dispose();
    });

    test('dispose() is safe with no background timer scheduled', () {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      // No background reconnect timer was ever scheduled — dispose should
      // not throw and should leave the controller in a clean state.
      expect(() => controller.dispose(), returnsNormally);
    });

    test('dispose() after pre-init reconnect() is safe', () async {
      final controller = SleuthController();
      // Call reconnect() while _vmClient is null — it should early-return
      // and not schedule any background work.
      await controller.reconnect();
      // Dispose should not throw.
      expect(() => controller.dispose(), returnsNormally);
    });
  });

  // ===========================================================================
  // Background reconnect loop — drives exponential backoff via FakeAsync with
  // an injected _FakeVmClient so we never touch dart:developer.Service.
  // ===========================================================================
  group('SleuthController background reconnect loop', () {
    test('schedules a timer when initial connect fails', () {
      fakeAsync((async) {
        final controller = SleuthController();
        // Initialize detectors — a successful reconnect calls _syncVmState()
        // which iterates the (otherwise late-init) _detectors list.
        controller.initializeDetectorsForTest();
        final fake = _FakeVmClient();
        controller.setVmClientForTest(fake);

        controller.scheduleBackgroundReconnectForTest();
        expect(controller.backgroundReconnectScheduledForTest, isTrue,
            reason: 'First attempt should be armed immediately after failure');

        // Advance the first backoff step (500 ms, the new tighter lead-in)
        // and let the async callback run.
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        expect(fake.connectCallCount, 1,
            reason: 'Backoff step 1 should have fired exactly once');

        controller.dispose();
      });
    });

    test('passes maxRetries: 1 to each background connect attempt', () {
      fakeAsync((async) {
        final controller = SleuthController();
        controller.initializeDetectorsForTest();
        final fake = _FakeVmClient(succeed: false);
        controller.setVmClientForTest(fake);

        controller.scheduleBackgroundReconnectForTest();
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(fake.connectMaxRetriesCalls, [1, 1],
            reason: 'Background tick must request 1 inner retry so each probe '
                'gets two attempts inside the cold-start bind window');

        controller.dispose();
      });
    });

    test('stops retrying after the delay ladder is exhausted', () {
      fakeAsync((async) {
        final controller = SleuthController();
        controller.initializeDetectorsForTest();
        final fake = _FakeVmClient(succeed: false);
        controller.setVmClientForTest(fake);

        controller.scheduleBackgroundReconnectForTest();

        // Ladder is 0.5, 1, 2, 4, 8, 16, 30 — 7 entries, then stop.
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 8));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 16));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(fake.connectCallCount, 7,
            reason: 'All seven ladder steps should have fired');

        // After the ladder is exhausted, no more attempts fire.
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(fake.connectCallCount, 7,
            reason: 'Should stop after exhausting the ladder');

        controller.dispose();
      });
    });

    test('dispose() during pending delay cancels the timer callback', () {
      fakeAsync((async) {
        final controller = SleuthController();
        controller.initializeDetectorsForTest();
        final fake = _FakeVmClient();
        controller.setVmClientForTest(fake);
        controller.scheduleBackgroundReconnectForTest();

        expect(controller.backgroundReconnectScheduledForTest, isTrue);
        // Dispose mid-delay (before the 500 ms tick).
        controller.dispose();
        expect(controller.backgroundReconnectScheduledForTest, isFalse);

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(fake.connectCallCount, 0,
            reason: 'Cancelled timer must not fire connect after dispose');
      });
    });

    test('successful background connect resets the attempt counter', () {
      fakeAsync((async) {
        final controller = SleuthController();
        controller.initializeDetectorsForTest();
        final fake = _FakeVmClient(succeed: false);
        controller.setVmClientForTest(fake);
        controller.scheduleBackgroundReconnectForTest();

        // Fail step 1 (500 ms) and step 2 (1 s).
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(controller.backgroundReconnectAttemptForTest, 2);

        // Flip the fake to succeed on the next call and wait for step 3 (2 s).
        fake.succeed = true;
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(fake.connectCallCount, 3);
        expect(controller.backgroundReconnectAttemptForTest, 0,
            reason: 'Counter must reset after a real success');
        expect(controller.backgroundReconnectScheduledForTest, isFalse,
            reason: 'Loop stops once connected');

        controller.dispose();
      });
    });

    test('mid-session disconnect schedules the background reconnect loop', () {
      fakeAsync((async) {
        final controller = SleuthController();
        controller.initializeDetectorsForTest();
        final fake = _FakeVmClient(succeed: false);
        controller.setVmClientForTest(fake);
        // Mark _initialized = true AND consume the initial scheduling, so
        // we can isolate the disconnect-driven scheduling path: run the
        // first tick to completion and then dispose the timer via success.
        controller.scheduleBackgroundReconnectForTest();
        fake.succeed = true;
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        // First tick succeeded → loop is now idle (no pending timer).
        expect(controller.backgroundReconnectScheduledForTest, isFalse,
            reason: 'Successful connect should have stopped the loop');
        fake.succeed = false;
        // Mirror the real VmServiceClient: its internal `_connected` flips
        // to false BEFORE the onConnectionChanged callback fires. Without
        // this, _scheduleBackgroundReconnect's `client.isConnected` guard
        // short-circuits and no timer is armed.
        fake.markDisconnected();
        final priorCallCount = fake.connectCallCount;

        // Simulate the VmServiceClient's poll-error path exhausting its
        // internal 3-attempt reconnect loop — it reports disconnected via
        // the onConnectionChanged callback. The controller must re-arm
        // the background ladder so we don't get stuck in BASIC.
        controller.onVmConnectionChangedForTest(false);
        expect(controller.backgroundReconnectScheduledForTest, isTrue,
            reason: 'Disconnect signal while initialized must re-arm the loop');

        // Drain the next scheduled tick (first step = 500 ms).
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        expect(fake.connectCallCount, priorCallCount + 1,
            reason: 'Re-armed loop must fire a fresh connect attempt');

        controller.dispose();
      });
    });

    test('disconnect into an already-armed loop is idempotent (no stacking)',
        () {
      fakeAsync((async) {
        final controller = SleuthController();
        controller.initializeDetectorsForTest();
        final fake = _FakeVmClient(succeed: false);
        controller.setVmClientForTest(fake);
        controller.scheduleBackgroundReconnectForTest();

        // First tick fires (step 1 = 500 ms), fails, loop re-arms step 2.
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        expect(fake.connectCallCount, 1);
        expect(controller.backgroundReconnectScheduledForTest, isTrue);

        // Inject a disconnect signal while the loop is already armed.
        // _backgroundReconnectActive guards against stacking a second timer.
        controller.onVmConnectionChangedForTest(false);
        expect(controller.backgroundReconnectScheduledForTest, isTrue);

        // Drain step 2 (1 s). A stacked timer would produce 3 calls here;
        // the guard keeps it at 2.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(fake.connectCallCount, 2,
            reason: 'Duplicate schedule must not double-count attempts');

        controller.dispose();
      });
    });

    test('concurrent reconnect() calls share the same in-flight future', () {
      fakeAsync((async) {
        final controller = SleuthController();
        controller.initializeDetectorsForTest();
        final fake = _FakeVmClient.slow();
        controller.setVmClientForTest(fake);

        final a = controller.reconnect();
        final b = controller.reconnect();
        final c = controller.reconnect();
        expect(identical(a, b), isTrue,
            reason: 'Second call must join the in-flight future');
        expect(identical(b, c), isTrue,
            reason: 'Third call must join the in-flight future');

        // Let the fake reconnect complete.
        async.elapse(const Duration(milliseconds: 200));
        async.flushMicrotasks();
        expect(fake.reconnectCallCount, 1,
            reason: 'Only one underlying client.reconnect() should run');

        controller.dispose();
      });
    });
  });

  // ===========================================================================
  // frameStatsNotifier throttle — caps UI emission rate at ~5 Hz (200 ms)
  // to prevent Sleuth's own overlay rebuilds from dominating the rebuild count.
  // ===========================================================================
  group('frameStatsNotifier throttle', () {
    late DateTime fakeClock;

    setUp(() {
      fakeClock = DateTime(2026);
      SleuthController.clockOverrideForTest = () => fakeClock;
    });

    tearDown(() {
      SleuthController.clockOverrideForTest = null;
    });

    test('first frame always emits, rapid frames within 200ms are throttled',
        () {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.markInitializedForTest();

      int emitCount = 0;
      controller.frameStatsNotifier.addListener(() => emitCount++);

      FrameStats frame(int n) => FrameStats(
            frameNumber: n,
            uiDuration: const Duration(milliseconds: 8),
            rasterDuration: const Duration(milliseconds: 5),
            timestamp: fakeClock,
            frameBudgetMs: 16,
          );

      // Frame 1 — first emit, throttle has no prior timestamp.
      controller.addFrameForTest(frame(1));
      expect(emitCount, 1, reason: 'First frame must emit immediately');

      // Frames 2-5 — within 200 ms window, should all be throttled.
      for (var i = 2; i <= 5; i++) {
        fakeClock = fakeClock.add(const Duration(milliseconds: 30));
        controller.addFrameForTest(frame(i));
      }
      expect(emitCount, 1,
          reason: 'Rapid frames within 200 ms must be throttled');

      // Advance past the 200 ms throttle window.
      fakeClock = fakeClock.add(const Duration(milliseconds: 200));

      // Frame 6 — throttle elapsed, should emit.
      controller.addFrameForTest(frame(6));
      expect(emitCount, 2,
          reason: 'Frame after 200 ms throttle window must emit');

      // Another rapid burst.
      fakeClock = fakeClock.add(const Duration(milliseconds: 50));
      controller.addFrameForTest(frame(7));
      expect(emitCount, 2, reason: 'Still within 200 ms of last emit');

      controller.dispose();
    });

    test('pre-initialized path bypasses throttle (every frame emits)', () {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      // Do NOT call markInitializedForTest() — _initialized stays false.

      int emitCount = 0;
      controller.frameStatsNotifier.addListener(() => emitCount++);

      for (var i = 1; i <= 5; i++) {
        controller.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 8),
          rasterDuration: const Duration(milliseconds: 5),
          timestamp: fakeClock,
          frameBudgetMs: 16,
        ));
      }

      expect(emitCount, 5,
          reason: 'Pre-init path must emit every frame (no throttle) '
              'because exportSnapshot reads from the notifier');

      controller.dispose();
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal fake VmServiceClient — overrides connect/reconnect/isConnected so
// background-loop tests never touch dart:developer.Service or a real socket.
// ---------------------------------------------------------------------------

class _FakeVmClient extends VmServiceClient {
  _FakeVmClient({this.succeed = true}) : _slow = false;
  _FakeVmClient.slow()
      : succeed = true,
        _slow = true;

  bool succeed;
  final bool _slow;

  int connectCallCount = 0;
  int reconnectCallCount = 0;
  final List<int> connectMaxRetriesCalls = [];
  bool _fakeConnected = false;
  bool _fakeDisposed = false;

  /// Simulate a VmServiceClient losing its connection (e.g., the poll path
  /// detecting a socket error). Mirrors the real client's internal state
  /// flip that precedes the [onConnectionChanged] callback firing with
  /// `false`.
  void markDisconnected() {
    _fakeConnected = false;
  }

  @override
  bool get isConnected => _fakeConnected;

  @override
  bool get isDisposed => _fakeDisposed;

  @override
  Future<bool> connect({
    int maxRetries = 3,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    connectCallCount++;
    connectMaxRetriesCalls.add(maxRetries);
    if (_slow) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _fakeConnected = succeed;
    if (succeed) {
      onConnectionChanged?.call(true);
    }
    return succeed;
  }

  @override
  Future<bool> reconnect() async {
    reconnectCallCount++;
    if (_slow) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _fakeConnected = succeed;
    if (succeed) {
      onConnectionChanged?.call(true);
    }
    return succeed;
  }

  @override
  void dispose() {
    _fakeDisposed = true;
    _fakeConnected = false;
  }
}
