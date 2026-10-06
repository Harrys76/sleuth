// Capture screens (the provenance preflight every screen runs when a leg
// starts, and the stream leg's judgement), their shared driver, and the
// hands-free capture extensions' helpers.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

import 'package:example/demos/capture_driver.dart';
import 'package:example/demos/frame_timing_capture_screen.dart';
import 'package:example/demos/heavy_compute_capture_screen.dart';
import 'package:example/demos/memory_pressure_capture_screen.dart';
import 'package:example/demos/network_monitor_capture_screen.dart';
import 'package:example/demos/platform_channel_capture_screen.dart';
import 'package:example/demos/rebuild_activity_capture_screen.dart';
import 'package:example/demos/repaint_capture_screen.dart';
import 'package:example/demos/stream_resource_capture_screen.dart';
import 'package:example/demos/tracked_resource_capture_screen.dart';
import 'package:example/main.dart' show readVmAxes, startCaptureLeg;

/// Leg calls whose stream suspension never answers.
class _StalledSuspend extends CaptureLegCalls {
  @override
  Future<void> suspendStreams() => Completer<void>().future;

  @override
  Future<void> resumeStreams() async {}
}

void main() {
  setUp(CaptureDriver.instance.resetForTest);
  tearDown(CaptureDriver.instance.resetForTest);

  group('pre-flight banner', () {
    testWidgets('rebuild screen shows it while capture mode is off', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: RebuildActivityCaptureScreen()),
      );
      expect(find.byType(CapturePreflightBanner), findsOneWidget);
      expect(find.textContaining('Capture mode is off'), findsOneWidget);
      expect(find.text('Run warning/below'), findsOneWidget);
    });

    testWidgets('repaint screen shows it while capture mode is off', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: RepaintCaptureScreen()));
      expect(find.byType(CapturePreflightBanner), findsOneWidget);
      expect(find.textContaining('Capture mode is off'), findsOneWidget);
      expect(find.text('Run warning/at'), findsOneWidget);
    });

    testWidgets('screens register a leg runner while mounted', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: RebuildActivityCaptureScreen()),
      );
      expect(CaptureDriver.instance.runnerFor('rebuild'), isNotNull);
      await tester.pumpWidget(const MaterialApp(home: RepaintCaptureScreen()));
      expect(CaptureDriver.instance.runnerFor('rebuild'), isNull);
      expect(CaptureDriver.instance.runnerFor('repaint'), isNotNull);
    });

    testWidgets('the banner names a provenance problem and is empty when '
        'every check passes', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RepaintCaptureScreen()));
      expect(find.textContaining('Capture provenance:'), findsOneWidget);
      expect(find.textContaining('SLEUTH_CAPTURE_DEVICE'), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CapturePreflightBanner(captureMode: true, vmConnected: true),
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('the FrameTiming screen shows why it cannot stamp a '
        'provenance', (tester) async {
      // iPhone 12 logical size.
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(home: FrameTimingCaptureScreen()),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('Provenance: device model unknown'),
        findsOneWidget,
      );
    });
  });

  group('provenance preflight', () {
    // Tests build without `--dart-define=SLEUTH_CAPTURE_DEVICE`, so every
    // leg must be refused when it starts, with the problem on screen.
    Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
      // The test font draws every glyph a full em wide, so these
      // phone-sized screens get a tablet-sized surface to lay out on.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: screen));
      await tester.pump();
    }

    Future<void> tapLeg(WidgetTester tester, Finder button) async {
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
    }

    void expectRefused(String label) {
      expect(
        find.textContaining('[$label] ABORT: capture provenance: '),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'relaunch with --dart-define=$kCaptureDeviceDefine',
        ),
        findsOneWidget,
      );
    }

    testWidgets('stream: a leg is refused before its warmup', (tester) async {
      await pumpScreen(tester, const StreamResourceCaptureScreen());
      await tapLeg(tester, find.text('below\nΔ 1-49'));
      expectRefused('below');
      expect(find.textContaining('start ==='), findsNothing);
      expect(find.text('Phase: idle'), findsOneWidget);
      expect(find.textContaining('refused: capture provenance'), findsOne);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tracked resource: a leg is refused before its wait', (
      tester,
    ) async {
      await pumpScreen(tester, const TrackedResourceCaptureScreen());
      await tapLeg(tester, find.text('Below (wait 250 s ≈ 4 min), passes'));
      expectRefused('below');
      expect(find.textContaining('pre-leg'), findsNothing);
      expect(find.textContaining('long-lived leg'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('heavy compute: a leg is refused before its workload', (
      tester,
    ) async {
      await pumpScreen(tester, const HeavyComputeCaptureScreen());
      expect(find.textContaining('Calibrated:'), findsOneWidget);
      await tapLeg(tester, find.textContaining('Below ('));
      expectRefused('warning/below');
      expect(find.textContaining('scenario.begin'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('platform channel: a leg is refused before its calls', (
      tester,
    ) async {
      await pumpScreen(tester, const PlatformChannelCaptureScreen());
      await tapLeg(tester, find.textContaining('Below ('));
      expectRefused('below');
      expect(
        find.textContaining('captureMode is OFF'),
        findsOneWidget,
        reason: 'both build problems are reported at once',
      );
      expect(find.textContaining('attempt 1/'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('memory pressure: a leg is refused before its allocation', (
      tester,
    ) async {
      await pumpScreen(tester, const MemoryPressureCaptureScreen());
      // Calibration times a 1 s allocation run on a real stopwatch.
      await tapLeg(tester, find.text('Calibrate'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.textContaining('Calibrated:'), findsOneWidget);
      await tapLeg(tester, find.textContaining('Below ('));
      expectRefused('below');
      expect(find.textContaining('attempt 1/'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('network monitor: a leg is refused before its request', (
      tester,
    ) async {
      await pumpScreen(tester, const NetworkMonitorCaptureScreen());
      // The loopback server binds on a real socket.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(find.textContaining('Server ready'), findsOneWidget);
      await tapLeg(tester, find.textContaining('Below ('));
      expectRefused('warning/below');
      expect(find.textContaining('scenario.begin'), findsNothing);
      expect(tester.takeException(), isNull);
      // Release the socket before the test ends.
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    });
  });

  group('stream leg judgement', () {
    final detector = StreamResourceDetector(
      vmClientProvider: () => null,
      heapGrowingStateProvider: () => false,
    );
    tearDownAll(detector.dispose);
    final bracket = streamResourceBracket(detector.validationMetadata)!;

    test('a below leg with no measured growth is refused, not exported '
        'as 0', () {
      final refusal = streamBelowRefusal(null, bracket)!;
      expect(refusal.verdict, 'UNMEASURED');
      expect(refusal.reason, 'no top-class growth was measured');
    });

    test('a below leg exports only a growth under the threshold', () {
      expect(streamBelowRefusal(1, bracket), isNull);
      expect(streamBelowRefusal(49, bracket), isNull);
      final refusal = streamBelowRefusal(50, bracket)!;
      expect(refusal.verdict, 'OUT-OF-BAND');
      expect(refusal.reason, contains('below band (0, 50)'));
    });

    test('the above leg is judged on the audit band, not its export '
        'minimum', () {
      expect(bracket.acceptsMeasurement(70, 'above'), isFalse);
      expect(bracket.acceptsMeasurement(81, 'above'), isTrue);
      expect(bracket.acceptsMeasurement(151, 'above'), isFalse);
    });
  });

  group('capture screen in front', () {
    Future<NavigatorState> pushScreens(
      WidgetTester tester,
      List<Widget> screens,
    ) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          home: const Scaffold(body: Text('home')),
        ),
      );
      for (final screen in screens) {
        unawaited(
          key.currentState!.push(
            MaterialPageRoute<void>(builder: (_) => screen),
          ),
        );
        await tester.pumpAndSettle();
      }
      return key.currentState!;
    }

    /// Runs [bringCaptureScreenToFront] while pumping frames.
    Future<({CaptureScreenHandle? screen, String? error})> bring(
      WidgetTester tester,
      NavigatorState navigator, {
      required VoidCallback pushScreen,
      Duration timeout = const Duration(seconds: 3),
    }) async {
      ({CaptureScreenHandle? screen, String? error})? result;
      unawaited(
        bringCaptureScreenToFront(
          detector: 'rebuild',
          navigator: navigator,
          pushScreen: pushScreen,
          timeout: timeout,
        ).then((r) => result = r),
      );
      for (var i = 0; i < 100 && result == null; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return result!;
    }

    testWidgets('a covered screen is not in front', (tester) async {
      final navigator = await pushScreens(tester, const [
        RebuildActivityCaptureScreen(),
      ]);
      final rebuild = CaptureDriver.instance.screenFor('rebuild')!;
      expect(rebuild.inFront(), isTrue);

      unawaited(
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const Text('cover')),
        ),
      );
      await tester.pumpAndSettle();
      expect(rebuild.inFront(), isFalse);
      expect(rebuild.route()!.isCurrent, isFalse);

      navigator.pop();
      await tester.pumpAndSettle();
      expect(rebuild.inFront(), isTrue);
    });

    testWidgets('a covered screen is brought back by popping the routes '
        'above it', (tester) async {
      final navigator = await pushScreens(tester, const [
        RebuildActivityCaptureScreen(),
        RepaintCaptureScreen(),
      ]);
      final rebuild = CaptureDriver.instance.screenFor('rebuild')!;
      expect(rebuild.inFront(), isFalse);
      var pushes = 0;
      final result = await bring(tester, navigator, pushScreen: () => pushes++);
      expect(result.error, isNull);
      expect(result.screen, same(rebuild));
      expect(rebuild.inFront(), isTrue);
      expect(pushes, 0);
      await tester.pumpAndSettle();
      expect(CaptureDriver.instance.screenFor('repaint'), isNull);
      expect(find.text('RebuildActivity capture helper'), findsOneWidget);
    });

    testWidgets('a screen in front is used without navigating', (tester) async {
      final navigator = await pushScreens(tester, const [
        RebuildActivityCaptureScreen(),
      ]);
      var pushes = 0;
      final result = await bring(tester, navigator, pushScreen: () => pushes++);
      expect(result.screen, same(CaptureDriver.instance.screenFor('rebuild')));
      expect(pushes, 0);
      expect(navigator.canPop(), isTrue);
    });

    testWidgets('with no screen one is pushed and awaited', (tester) async {
      final navigator = await pushScreens(tester, const []);
      final result = await bring(
        tester,
        navigator,
        pushScreen: () => navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const RebuildActivityCaptureScreen(),
          ),
        ),
      );
      expect(result.error, isNull);
      expect(result.screen!.inFront(), isTrue);
    });

    testWidgets('a screen that never registers times out', (tester) async {
      final navigator = await pushScreens(tester, const []);
      final result = await bring(
        tester,
        navigator,
        pushScreen: () {},
        timeout: const Duration(milliseconds: 200),
      );
      expect(result.screen, isNull);
      expect(result.error, 'screen_not_ready');
    });

    test('no navigator and no screen is an error', () async {
      final result = await bringCaptureScreenToFront(
        detector: 'rebuild',
        navigator: null,
        pushScreen: null,
      );
      expect(result.error, 'no_navigator');
    });

    test('a route that is current with muted tickers is not in front', () {
      expect(
        isCaptureScreenInFront(route: null, tickersEnabled: false),
        isFalse,
      );
      expect(isCaptureScreenInFront(route: null, tickersEnabled: true), isTrue);
    });
  });

  group('CaptureDriver', () {
    test('idle → running → done; a second leg is refused while running', () {
      final driver = CaptureDriver.instance;
      expect(driver.state, CaptureLegState.idle);
      expect(driver.begin('rebuild/warning/at'), isTrue);
      expect(driver.state, CaptureLegState.running);
      expect(driver.begin('repaint/warning/at'), isFalse);
      expect(driver.leg, 'rebuild/warning/at');

      expect(driver.result()['attempts'], 0);
      driver.recordAttempt();
      driver.recordAttempt();
      driver.complete(observed: 12.4, json: '{}');
      expect(driver.state, CaptureLegState.done);
      final result = driver.result();
      expect(result['state'], 'done');
      expect(result['observed'], 12.4);
      expect(result['attempts'], 2);
      expect(result['json'], '{}');
      expect(driver.json, '{}', reason: 'a plain read keeps the stash');

      driver.result(consume: true);
      expect(driver.state, CaptureLegState.idle);
      expect(driver.json, isNull);
      expect(driver.attempts, 0);
      expect(driver.begin('repaint/warning/at'), isTrue);
    });

    test('failure releases the busy flag and keeps the reason', () {
      final driver = CaptureDriver.instance;
      driver.begin('rebuild/critical/above');
      driver.fail('pre-pass measured 0 %');
      expect(driver.isBusy, isFalse);
      final result = driver.result(consume: true);
      expect(result['state'], 'failed');
      expect(result.containsKey('json'), isFalse);
      expect((result['log']! as List).last, contains('pre-pass measured 0'));
      expect(driver.state, CaptureLegState.idle);
    });

    test('a throwing scenario end on cleanup is logged, not rethrown', () {
      final driver = CaptureDriver.instance;
      expect(
        () => endScenarioInCleanup(
          'excessive_repaint_at',
          'warning/at',
          markEnd: (_) => throw StateError('timeline gone'),
        ),
        returnsNormally,
      );
      expect((driver.result()['log']! as List).last, contains('timeline gone'));
    });

    test('a runner that throws before its own error handling fails the '
        'leg', () async {
      final driver = CaptureDriver.instance;
      driver.begin('repaint/warning/at');
      Future<void> throwing(String tier, String role) =>
          throw StateError('detector gone');
      await driver.runLeg(throwing, 'warning', 'at');
      expect(driver.isBusy, isFalse);
      expect(driver.state, CaptureLegState.failed);
      expect(driver.log.last, contains('detector gone'));
    });

    test('a runner that returns without a result fails the leg', () async {
      final driver = CaptureDriver.instance;
      driver.begin('rebuild/warning/at');
      await driver.runLeg((_, _) async {}, 'warning', 'at');
      expect(driver.state, CaptureLegState.failed);
      expect(driver.log.last, contains('without a result'));
    });

    test('a completed leg keeps its result', () async {
      final driver = CaptureDriver.instance;
      driver.begin('rebuild/warning/at');
      await driver.runLeg(
        (_, _) async => driver.complete(observed: 9.0, json: '{}'),
        'warning',
        'at',
      );
      expect(driver.state, CaptureLegState.done);
      expect(driver.json, '{}');
    });

    test('a VM call past its limit throws a named timeout', () async {
      expect(kVmCallTimeout, const Duration(seconds: 10));
      await expectLater(
        withCallTimeout(
          Completer<void>().future,
          'exportCaptureJson',
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(
          isA<CaptureCallTimeout>().having(
            (e) => e.toString(),
            'message',
            'exportCaptureJson timed out after 0.01 s',
          ),
        ),
      );
      expect(await withCallTimeout(Future.value(3), 'x'), 3);
    });

    test('a stream suspension that never answers fails the leg', () async {
      final driver = CaptureDriver.instance;
      driver.begin('repaint/warning/at');
      var stops = 0;
      var starts = 0;
      await runTimeShareLeg(
        leg: const TimeShareLeg(
          detector: 'repaint',
          bracket: CaptureBracket(
            stableId: 'excessive_repaint',
            severityLabel: 'warning',
            threshold: 10,
            atTolerance: 0.5,
            aboveCeilingMultiplier: 2.7,
            argKey: 'observedPaintPercent',
          ),
          tier: 'warning',
          role: 'at',
          scenario: 'excessive_repaint_at',
          tierThreshold: 10,
          targetPercent: 12,
          knobName: 'ops',
          calibrationKnob: 10,
          minKnob: 1,
          maxKnob: 100,
          workloadDuration: Duration(seconds: 6),
        ),
        startWorkload: (_) => starts++,
        stopWorkload: () => stops++,
        readPeak: () => 0,
        resetDetector: () {},
        isActive: () => true,
        provenance: () => (
          provenance: const CaptureProvenance(
            device: 'iPhone 12',
            deviceOsVersion: 'iOS 17.5',
            flutterVersion: '3.47.6',
          ),
          problem: null,
        ),
        calls: _StalledSuspend(),
        callTimeout: const Duration(milliseconds: 20),
      );
      expect(driver.state, CaptureLegState.failed);
      expect(
        driver.log.last,
        contains('suspendNonEssentialTimelineStreams timed out'),
      );
      expect(starts, 0);
      expect(stops, greaterThan(0));
    });

    test('consume leaves a running leg untouched', () {
      final driver = CaptureDriver.instance;
      driver.begin('rebuild/warning/below');
      driver.result(consume: true);
      expect(driver.state, CaptureLegState.running);
    });
  });

  group('extension helpers without a controller', () {
    test('vmAxes reports zeros and vmConnected false', () {
      expect(readVmAxes(reset: true), {
        'buildLast': 0.0,
        'buildPeak': 0.0,
        'paintLast': 0.0,
        'paintPeak': 0.0,
        'vmConnected': false,
      });
    });

    test('vmAxes refuses a reset while a leg runs', () {
      CaptureDriver.instance.begin('repaint/warning/above');
      expect(readVmAxes(reset: true), {'error': 'busy'});
      expect(readVmAxes(), containsPair('paintPeak', 0.0));
    });

    test('captureLeg refuses outside capture mode and on bad args', () async {
      expect(
        await startCaptureLeg(detector: 'rebuild', tier: 'warning', role: 'at'),
        {'error': 'not_capture_mode'},
      );
      expect(
        await startCaptureLeg(detector: 'gpu', tier: 'warning', role: 'at'),
        {'error': 'bad_args'},
      );
      expect(
        await startCaptureLeg(
          detector: 'repaint',
          tier: 'critical',
          role: 'at',
        ),
        {'error': 'bad_args'},
      );
      CaptureDriver.instance.begin('rebuild/warning/at');
      expect(
        await startCaptureLeg(detector: 'rebuild', tier: 'warning', role: 'at'),
        {'error': 'busy'},
      );
    });
  });

  group('timeShareBand', () {
    test('every lower bound is positive and bands follow the role rules', () {
      for (final threshold in [0.2, 1.0, 10.0, 30.0, 75.0]) {
        for (final tier in ['warning', 'critical']) {
          for (final role in ['below', 'at', 'above']) {
            final band = timeShareBand(
              tier: tier,
              role: role,
              threshold: threshold,
            );
            expect(band.min, greaterThan(0), reason: '$tier/$role/$threshold');
            expect(band.max, greaterThan(band.min));
          }
        }
      }
      expect(timeShareBand(tier: 'warning', role: 'below', threshold: 10), (
        min: 0.5,
        max: 10.0,
      ));
      expect(timeShareBand(tier: 'critical', role: 'below', threshold: 30), (
        min: 19.5,
        max: 30.0,
      ));
      expect(timeShareBand(tier: 'warning', role: 'at', threshold: 10), (
        min: 10.0,
        max: 15.0,
      ));
      final above = timeShareBand(
        tier: 'critical',
        role: 'above',
        threshold: 30,
      );
      expect(above.min, closeTo(45, 1e-9));
      expect(above.max, closeTo(81, 1e-9));
    });

    test('scaleKnob refuses a zero measurement and a binding clamp', () {
      expect(
        scaleKnob(
          calibrationKnob: 4000,
          measured: 2,
          target: 12.5,
          minKnob: 1,
          maxKnob: 4000000,
        ),
        25000,
      );
      expect(
        scaleKnob(
          calibrationKnob: 4000,
          measured: 0,
          target: 12.5,
          minKnob: 1,
          maxKnob: 4000000,
        ),
        isNull,
      );
      expect(
        scaleKnob(
          calibrationKnob: 4000,
          measured: 0.05,
          target: 60,
          minKnob: 1,
          maxKnob: 4000000,
        ),
        isNull,
      );
      expect(
        scaleKnob(
          calibrationKnob: 32,
          measured: 0.005,
          target: 21,
          minKnob: 1,
          maxKnob: 131072,
        ),
        isNull,
        reason: '134400 ops exceeds the paint clamp',
      );
    });

    test('retryKnob rescales by target / observed and clamps', () {
      // work 40000 measured 7.8 % against a 21 % target.
      expect(
        retryKnob(
          knob: 40000,
          observed: 7.8,
          target: 21,
          minKnob: 1,
          maxKnob: 4000000,
        ),
        107692,
      );
      // Overshoot scales down.
      expect(
        retryKnob(
          knob: 100,
          observed: 20,
          target: 12.5,
          minKnob: 1,
          maxKnob: 131072,
        ),
        63,
      );
      expect(
        retryKnob(
          knob: 3000000,
          observed: 16.2,
          target: 60,
          minKnob: 1,
          maxKnob: 4000000,
        ),
        4000000,
        reason: 'clamped to maxKnob',
      );
      expect(
        retryKnob(
          knob: 2,
          observed: 40,
          target: 5,
          minKnob: 1,
          maxKnob: 131072,
        ),
        1,
        reason: 'clamped to minKnob',
      );
      expect(
        retryKnob(
          knob: 4000,
          observed: 0,
          target: 12.5,
          minKnob: 1,
          maxKnob: 4000000,
        ),
        isNull,
      );
    });
  });

  group('workloads', () {
    int leafResult(WidgetTester tester, Finder result) {
      final node = tester.widget(result).toDiagnosticsNode();
      return node.getProperties().firstWhere((p) => p.name == 'value').value
          as int;
    }

    testWidgets('CaptureBuildLoad keeps 64 leaves at every work', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final leaf = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_CostLeaf',
      );
      final result = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_CostResult',
      );
      for (final work in [1, 4000]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(child: CaptureBuildLoad(work: work)),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        final leafBefore = tester.widget(leaf.first);
        final resultBefore = leafResult(tester, result.at(5));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.takeException(), isNull);
        expect(leaf, findsNWidgets(64), reason: 'work $work');
        expect(result, findsNWidgets(64));
        expect(
          tester.widget(leaf.first),
          isNot(same(leafBefore)),
          reason: 'each tick builds fresh leaf instances',
        );
        expect(
          leafResult(tester, result.at(5)),
          isNot(resultBefore),
          reason: 'the loop result depends on the tick',
        );
        expect(find.byType(Positioned), findsNothing);

        // One zero-size box per leaf under the Stack.
        final stack = tester.renderObject<RenderStack>(
          find.descendant(
            of: find.byType(CaptureBuildLoad),
            matching: find.byType(Stack),
          ),
        );
        expect(stack.childCount, 64);
        expect(stack.firstChild, isA<RenderConstrainedBox>());
        expect(stack.firstChild!.debugDescribeChildren(), isEmpty);
        await tester.pumpWidget(const SizedBox());
      }
    });

    test('CapturePaintLoad spreads ops across the 32 tiles', () {
      final load = CapturePaintLoad(ops: 1);
      addTearDown(load.dispose);
      List<int> perTile(int ops) {
        load.ops = ops;
        return [for (var i = 0; i < 32; i++) load.opsForTile(i)];
      }

      expect(perTile(1), [1, for (var i = 1; i < 32; i++) 0]);
      expect(perTile(16), [
        for (var i = 0; i < 16; i++) 1,
        for (var i = 16; i < 32; i++) 0,
      ]);
      expect(perTile(32), List.filled(32, 1));
      expect(perTile(33), [2, for (var i = 1; i < 32; i++) 1]);
      expect(perTile(131072), List.filled(32, 4096));
      for (final ops in [1, 16, 32, 33, 131072]) {
        expect(perTile(ops).reduce((a, b) => a + b), ops);
      }
    });

    testWidgets('paint tiles repaint on tick without rebuilding', (
      tester,
    ) async {
      final load = CapturePaintLoad(ops: 3);
      addTearDown(load.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CapturePaintWorkload(load: load)),
        ),
      );
      final tile = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_PT00',
      );
      expect(tile, findsOneWidget);
      final boundary = find.descendant(
        of: tile,
        matching: find.byType(RepaintBoundary),
      );
      final elementBefore = tester.element(tile);
      final boundaryBefore = tester.widget(boundary);
      final paintsBefore = load.paintCalls;

      load.tick();
      await tester.pump();

      expect(load.ticks, 1);
      expect(load.paintCalls, paintsBefore + 32);
      expect(tester.takeException(), isNull);
      expect(tester.element(tile), same(elementBefore));
      expect(
        tester.widget(boundary),
        same(boundaryBefore),
        reason: 'a rebuild would create a new RepaintBoundary widget',
      );
    });
  });
}
