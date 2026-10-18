// Hermetic reproducer for `event_loop_stall`. Timer events go through a fake
// VM service into the real `VmServiceClient` subscription and the
// controller's handler, or straight into the detector with injected clocks.
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/event_loop_stall_detector.dart';
import 'package:sleuth/src/models/base_detector.dart' show DetectorType;
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/utils/own_work_log.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';
import 'package:vm_service/vm_service.dart';

import '../helpers/fake_vm_service.dart';
import '../helpers/measurement_matchers.dart';
import '_helpers/structural_reproducer_harness.dart' show hasStableId;

/// Wall clock in epoch microseconds and a monotonic clock that runs in
/// step with it, 1e12 µs behind.
class _Clocks {
  int wallUs = DateTime.utc(2026, 10, 14, 9).microsecondsSinceEpoch;
  static const int offsetUs = 1000000000000;
  DateTime wall() => DateTime.fromMicrosecondsSinceEpoch(wallUs, isUtc: true);
  int monotonic() => wallUs - offsetUs;
  int get nowMs => wallUs ~/ 1000;
  void advanceMs(int ms) => wallUs += ms * 1000;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('detector', () {
    late _Clocks clocks;
    late List<(int, int)> ownWork;
    late String route;

    EventLoopStallDetector detector() => EventLoopStallDetector(
      clock: clocks.wall,
      monotonicNowUs: clocks.monotonic,
      sourceRouteProvider: () => route,
      ownWorkOverlapUs: (from, to) {
        var covered = 0;
        for (final (start, end) in ownWork) {
          final s = start > from ? start : from;
          final e = end < to ? end : to;
          if (e > s) covered += e - s;
        }
        return covered;
      },
    );

    /// A stall that ends now and lasted [overdueMs] by the VM's reading.
    void stall(EventLoopStallDetector d, int overdueMs, {String? details}) {
      d.recordOverdueTimer(
        details:
            details ??
            'A timer should have fired $overdueMs ms ago, but just fired now.',
        eventTimestampMs: clocks.nowMs,
      );
    }

    String? observed(EventLoopStallDetector d) =>
        d.issues.single.extraTraceArgs!['observedStallMs'];

    setUp(() {
      clocks = _Clocks();
      ownWork = [];
      route = '/home';
    });

    test('the details text gives the delay; other text gives none', () {
      expect(
        EventLoopStallDetector.parseOverdueMs(
          'A timer should have fired 812 ms ago, but just fired now.',
        ),
        812,
      );
      expect(EventLoopStallDetector.parseOverdueMs('Timer was late'), isNull);
      expect(EventLoopStallDetector.parseOverdueMs(null), isNull);
    });

    test('150 ms is a warning and 800 ms is critical', () {
      final d = detector();
      stall(d, 150);
      expect(d.issues.single.severity, IssueSeverity.warning);
      expect(observed(d), '150');
      expectMeasurement(
        d.issues.single,
        value: 150,
        unit: MeasurementUnit.milliseconds,
        warningAt: d.warningMs.toDouble(),
        criticalAt: d.criticalMs.toDouble(),
      );

      final c = detector();
      stall(c, 800);
      expect(c.issues.single.severity, IssueSeverity.critical);
      expect(c.issues, hasStableId('event_loop_stall'));
      expect(c.issues.single.confidence, IssueConfidence.confirmed);
      expectMeasurement(
        c.issues.single,
        value: 800,
        unit: MeasurementUnit.milliseconds,
        warningAt: c.warningMs.toDouble(),
        criticalAt: c.criticalMs.toDouble(),
      );
    });

    test('699 ms stays a warning; 700 ms is critical', () {
      final d = detector();
      stall(d, 699);
      expect(d.issues.single.severity, IssueSeverity.warning);
      expectSeverityMatchesMeasurement(d.issues.single);
      final c = detector();
      stall(c, 700);
      expect(c.issues.single.severity, IssueSeverity.critical);
      expectSeverityMatchesMeasurement(c.issues.single);
    });

    test('events within 50 ms are one stall as long as the longest delay', () {
      final d = detector();
      stall(d, 300);
      clocks.advanceMs(10);
      stall(d, 820);
      expect(d.issues.single.extraTraceArgs!['stallCount'], '1');
      expect(observed(d), '820');
      expect(d.issues.single.severity, IssueSeverity.critical);

      clocks.advanceMs(500);
      stall(d, 150);
      expect(d.issues.single.extraTraceArgs!['stallCount'], '2');
      expect(d.issues.single.title, contains('Stalls: 2'));
    });

    test('an unparsable text is a warning of unknown length', () {
      final d = detector();
      stall(d, 0, details: 'Timer was late');
      expect(d.issues.single.severity, IssueSeverity.warning);
      expect(
        d.issues.single.extraTraceArgs!.containsKey('observedStallMs'),
        isFalse,
      );
      expect(d.issues.single.title, contains('unknown length'));
      expect(d.issues.single.measurement, isNull);
    });

    group('lifecycle', () {
      test('events while hidden or paused are ignored', () {
        final d = detector()..onAppLifecycleChanged(AppLifecycleState.hidden);
        stall(d, 5000);
        d.onAppLifecycleChanged(AppLifecycleState.paused);
        stall(d, 5000);
        expect(d.issues, isEmpty);
        expect(d.ignoredForLifecycleCount, 2);
      });

      test('a timer late only from a 30 s suspension stays silent', () {
        final d = detector()..onAppLifecycleChanged(AppLifecycleState.paused);
        clocks.advanceMs(30000);
        d
          ..onAppLifecycleChanged(AppLifecycleState.hidden)
          ..onAppLifecycleChanged(AppLifecycleState.inactive)
          ..onAppLifecycleChanged(AppLifecycleState.resumed);
        clocks.advanceMs(20);
        stall(d, 30010);
        expect(d.issues, isEmpty);
      });

      test('a 600 ms resumed handler counts from the first change after '
          'the suspension, with no grace period', () {
        final d = detector()..onAppLifecycleChanged(AppLifecycleState.paused);
        clocks.advanceMs(30000);
        // Dart handles the change from hidden to inactive first, and that
        // stamps the boundary.
        d.onAppLifecycleChanged(AppLifecycleState.inactive);
        // The change from inactive to resumed does not move it.
        clocks.advanceMs(5);
        d.onAppLifecycleChanged(AppLifecycleState.resumed);
        // The app's resumed handler runs 600 ms. The first timer that fires
        // after it came due during the suspension.
        clocks.advanceMs(600);
        stall(d, 30600);
        expect(observed(d), '605');
        expect(d.issues.single.severity, IssueSeverity.warning);
      });

      test('a timer event handled before the lifecycle change is ignored, '
          'and the next stall after it counts', () {
        final d = detector()..onAppLifecycleChanged(AppLifecycleState.paused);
        clocks.advanceMs(30000);
        stall(d, 30000);
        expect(d.issues, isEmpty);
        d.onAppLifecycleChanged(AppLifecycleState.inactive);
        clocks.advanceMs(1000);
        stall(d, 400);
        expect(observed(d), '400');
      });

      test('a stall while inactive counts', () {
        final d = detector()..onAppLifecycleChanged(AppLifecycleState.inactive);
        stall(d, 600);
        expect(observed(d), '600');
      });
    });

    group('what is not the app\'s is taken off', () {
      test('Sleuth\'s own work: the rest is reported, a stall it explains '
          'is not', () {
        final d = detector();
        final endUs = clocks.monotonic();
        ownWork = [(endUs - 100000, endUs)];
        stall(d, 400);
        expect(observed(d), '300');

        final e = detector();
        clocks.advanceMs(1000);
        final end2 = clocks.monotonic();
        ownWork = [(end2 - 350000, end2)];
        stall(e, 400);
        expect(e.issues, isEmpty);
        expect(e.excusedStallCount, 1);
      });

      test('a debugger pause: the pause alone is silent, work after '
          'Continue is reported', () {
        final d = detector();
        final pausedAt = clocks.nowMs;
        d.onDebuggerPaused(pausedAt);
        clocks.advanceMs(5000);
        d.onDebuggerResumed(clocks.nowMs);
        clocks.advanceMs(40);
        stall(d, 5040);
        expect(d.issues, isEmpty);
        expect(d.excusedStallCount, 1);

        final e = detector()..onDebuggerPaused(clocks.nowMs);
        clocks.advanceMs(5000);
        e.onDebuggerResumed(clocks.nowMs);
        clocks.advanceMs(300);
        stall(e, 5300);
        expect(observed(e), '300');
      });

      test('a timer event that arrives before the Resume event still has '
          'the pause taken off', () {
        final d = detector()..onDebuggerPaused(clocks.nowMs);
        clocks.advanceMs(5000);
        stall(d, 5000);
        expect(d.issues, isEmpty);
      });

      test('a hot reload window', () {
        final d = detector();
        d.excludeWindow(clocks.nowMs - 3000, clocks.nowMs + 2000);
        clocks.advanceMs(500);
        stall(d, 800);
        expect(d.issues, isEmpty);
        clocks.advanceMs(5000);
        stall(d, 800);
        expect(observed(d), '800');
      });

      test('the decision holds when a burst of merged events follows', () {
        // A 400 ms stall that Sleuth's own work explains delays 100 timers;
        // each event re-evaluates the same stall and none publishes it.
        final d = detector();
        final endUs = clocks.monotonic();
        ownWork = [(endUs - 400000, endUs)];
        for (var i = 0; i < 100; i++) {
          stall(d, 400 - i % 3);
        }
        expect(d.issues, isEmpty);
        expect(d.excusedStallCount, 1);
      });
    });

    test('the issue holds 10 s after the latest stall with one identity', () {
      final d = detector();
      stall(d, 200);
      final identity = d.issues.single.dedupIdentityMicros;
      clocks.advanceMs(6000);
      stall(d, 250);
      expect(d.issues.single.dedupIdentityMicros, identity);
      clocks.advanceMs(9000);
      expect(d.issues, hasLength(1));
      clocks.advanceMs(1001);
      expect(d.issues, isEmpty);

      stall(d, 200);
      expect(d.issues.single.dedupIdentityMicros, isNot(identity));
    });

    test('a stall on another route starts a new episode with that '
        'route', () {
      final d = detector();
      stall(d, 200);
      final first = d.issues.single;
      expect(first.sourceRoute, '/home');
      route = '/detail';
      clocks.advanceMs(2000);
      stall(d, 900);
      final second = d.issues.single;
      expect(second.sourceRoute, '/detail');
      expect(second.dedupIdentityMicros, isNot(first.dedupIdentityMicros));
      expect(second.extraTraceArgs!['stallCount'], '1');
      expect(second.severity, IssueSeverity.critical);
    });

    test('a VM disconnect and reset clear it', () {
      final d = detector();
      stall(d, 200);
      d.vmConnected = false;
      expect(d.issues, isEmpty);
      stall(d, 200);
      d.reset();
      expect(d.issues, isEmpty);
    });
  });

  group('VM client subscription', () {
    test(
      'own-isolate events reach the callback; other isolates do not',
      () async {
        final received = <Event>[];
        final service = FakeVmService(
          isolates: [isolateRef('isolates/1'), isolateRef('isolates/2')],
        );
        final client = VmServiceClient(
          ownIsolateIdResolver: () => 'isolates/1',
          onTimerEvent: received.add,
        );
        addTearDown(client.dispose);
        await client.startSessionForTest(service);
        expect(service.streamListenCalls, contains('Timer'));
        expect(client.timerStreamAvailable, isTrue);

        service.timerController
          ..add(timerOverdueEvent(isolateId: 'isolates/1'))
          ..add(timerOverdueEvent(isolateId: 'isolates/2'));
        expect(received, hasLength(1));
        expect(received.single.isolate?.id, 'isolates/1');
      },
    );

    test('own-isolate pauses, resumes and reloads reach the pause '
        'callback', () async {
      final received = <String?>[];
      final service = FakeVmService(
        isolates: [isolateRef('isolates/1'), isolateRef('isolates/2')],
      );
      final client = VmServiceClient(
        ownIsolateIdResolver: () => 'isolates/1',
        onTimerEvent: (_) {},
        onPauseEvent: (e) => received.add(e.kind),
      );
      addTearDown(client.dispose);
      await client.startSessionForTest(service);
      expect(service.streamListenCalls, containsAll(['Debug', 'Isolate']));

      service.debugController
        ..add(
          isolateStateEvent(kind: 'PauseBreakpoint', isolateId: 'isolates/1'),
        )
        ..add(isolateStateEvent(kind: 'Resume', isolateId: 'isolates/1'))
        ..add(
          isolateStateEvent(kind: 'PauseBreakpoint', isolateId: 'isolates/2'),
        );
      service.isolateController
        ..add(isolateStateEvent(kind: 'IsolateReload', isolateId: 'isolates/1'))
        ..add(isolateStateEvent(kind: 'IsolateStart', isolateId: 'isolates/1'));
      expect(received, ['PauseBreakpoint', 'Resume', 'IsolateReload']);
    });

    test('a VM without the Timer stream (RPC -32602) marks it unavailable '
        'and the session still starts', () async {
      final service = FakeVmService()
        ..streamListenErrors['Timer'] = RPCError(
          'streamListen',
          RPCErrorKind.kInvalidParams.code,
          "streamListen: invalid 'streamId' parameter: Timer",
        );
      final client = VmServiceClient(
        ownIsolateIdResolver: () => 'isolates/1',
        onTimerEvent: (_) {},
        onPauseEvent: (_) {},
      );
      addTearDown(client.dispose);
      expect(await client.startSessionForTest(service), isTrue);
      expect(client.timerStreamAvailable, isFalse);
      expect(service.streamListenCalls, isNot(contains('Debug')));
    });

    test('no callback, no subscription', () async {
      final service = FakeVmService();
      final client = VmServiceClient(ownIsolateIdResolver: () => 'isolates/1');
      addTearDown(client.dispose);
      await client.startSessionForTest(service);
      expect(service.streamListenCalls, isNot(contains('Timer')));
      expect(client.timerStreamAvailable, isNull);
    });
  });

  group('controller probe timer', () {
    Future<(SleuthController, VmServiceClient)> connected({
      bool timerStream = true,
    }) async {
      final controller = SleuthController()..initializeDetectorsForTest();
      final service = FakeVmService();
      if (!timerStream) {
        service.streamListenErrors['Timer'] = RPCError(
          'streamListen',
          RPCErrorKind.kInvalidParams.code,
          'no Timer stream',
        );
      }
      final client = VmServiceClient(
        ownIsolateIdResolver: () => 'isolates/1',
        onTimerEvent: (_) {},
      );
      await client.startSessionForTest(service);
      controller
        ..setVmClientForTest(client)
        ..onVmConnectionChangedForTest(true);
      return (controller, client);
    }

    test(
      'runs while connected with a Timer stream and the detector on',
      () async {
        final (controller, client) = await connected();
        addTearDown(client.dispose);
        expect(controller.stallProbeRunningForTest, isTrue);

        controller.disableDetector(DetectorType.eventLoopStall);
        expect(controller.stallProbeRunningForTest, isFalse);
        controller.enableDetector(DetectorType.eventLoopStall);
        expect(controller.stallProbeRunningForTest, isTrue);

        controller.onVmConnectionChangedForTest(false);
        expect(controller.stallProbeRunningForTest, isFalse);
        controller.onVmConnectionChangedForTest(true);
        controller.dispose();
        expect(controller.stallProbeRunningForTest, isFalse);
      },
    );

    test('stops while the app is in the background', () async {
      final (controller, client) = await connected();
      addTearDown(client.dispose);
      addTearDown(controller.dispose);
      expect(controller.stallProbeRunningForTest, isTrue);
      controller.onAppLifecycleChanged(AppLifecycleState.paused);
      expect(controller.stallProbeRunningForTest, isFalse);
      controller.onAppLifecycleChanged(AppLifecycleState.inactive);
      expect(controller.stallProbeRunningForTest, isTrue);
      controller.onAppLifecycleChanged(AppLifecycleState.resumed);
      expect(controller.stallProbeRunningForTest, isTrue);
    });

    test('does not run without a Timer stream', () async {
      final (controller, client) = await connected(timerStream: false);
      addTearDown(client.dispose);
      addTearDown(controller.dispose);
      expect(controller.stallProbeRunningForTest, isFalse);
    });
  });

  group('controller', () {
    late SleuthController controller;
    EventLoopStallDetector stallDetector() =>
        controller.detectorsForAudit.whereType<EventLoopStallDetector>().single;

    setUp(() {
      ownWorkLog.clear();
      controller = SleuthController()..initializeDetectorsForTest();
    });
    tearDown(() {
      controller.dispose();
      ownWorkLog.clear();
    });

    int nowMs() => DateTime.now().millisecondsSinceEpoch;

    test('a Timer event becomes an event_loop_stall issue', () {
      controller.feedTimerEventForTest(
        timerOverdueEvent(
          isolateId: 'isolates/1',
          overdueMs: 900,
          timestampMs: nowMs(),
        ),
      );
      expect(stallDetector().issues.single.severity, IssueSeverity.critical);
    });

    test('a debugger pause routed through the controller is taken off', () {
      // The isolate paused for 5 s and resumed 40 ms ago, so 40 ms of the
      // 5040 ms is left.
      final now = nowMs();
      controller
        ..feedPauseEventForTest(
          isolateStateEvent(kind: 'PauseBreakpoint', timestampMs: now - 5040),
        )
        ..feedPauseEventForTest(
          isolateStateEvent(kind: 'Resume', timestampMs: now - 40),
        )
        ..feedTimerEventForTest(
          timerOverdueEvent(overdueMs: 5040, timestampMs: now),
        );
      expect(stallDetector().issues, isEmpty);
      expect(controller.eventLoopStallExcused, 1);
    });

    test('a hot reload, from the VM event or the reassemble, is taken '
        'off', () {
      controller.feedPauseEventForTest(
        isolateStateEvent(kind: 'IsolateReload', timestampMs: nowMs()),
      );
      controller.feedTimerEventForTest(
        timerOverdueEvent(overdueMs: 900, timestampMs: nowMs()),
      );
      expect(stallDetector().issues, isEmpty);

      final other = SleuthController()..initializeDetectorsForTest();
      addTearDown(other.dispose);
      other
        ..reassembleForTest()
        ..feedTimerEventForTest(
          timerOverdueEvent(overdueMs: 900, timestampMs: nowMs()),
        );
      expect(
        other.detectorsForAudit
            .whereType<EventLoopStallDetector>()
            .single
            .issues,
        isEmpty,
      );
    });

    test('a fake VM event reaches the detector through the client and the '
        'real own-work log', () async {
      final service = FakeVmService();
      final client = VmServiceClient(
        ownIsolateIdResolver: () => 'isolates/1',
        onTimerEvent: controller.feedTimerEventForTest,
        onPauseEvent: controller.feedPauseEventForTest,
      );
      addTearDown(client.dispose);
      await client.startSessionForTest(service);

      // A 400 ms stall that Sleuth's own work covered is not reported.
      final endUs = OwnWorkLog.now();
      ownWorkLog.record(endUs - 400000, endUs);
      service.timerController.add(
        timerOverdueEvent(
          isolateId: 'isolates/1',
          overdueMs: 400,
          timestampMs: nowMs(),
        ),
      );
      expect(stallDetector().issues, isEmpty);
      expect(controller.eventLoopStallExcused, 1);

      // The app's own 400 ms stall two seconds later is.
      service.timerController.add(
        timerOverdueEvent(
          isolateId: 'isolates/1',
          overdueMs: 400,
          timestampMs: nowMs() + 2000,
        ),
      );
      expect(
        stallDetector().issues.single.extraTraceArgs!['observedStallMs'],
        '400',
      );
    });
  });
}
