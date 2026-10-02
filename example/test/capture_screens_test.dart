// Time-share capture screens, their shared driver, and the hands-free
// capture extensions' helpers.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:example/demos/capture_driver.dart';
import 'package:example/demos/rebuild_activity_capture_screen.dart';
import 'package:example/demos/repaint_capture_screen.dart';
import 'package:example/main.dart' show readVmAxes, startCaptureLeg;

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
