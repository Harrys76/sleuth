// Leg lifecycle of the jank_detected capture screen: the VM check, legs in
// a row on one screen, and closing the screen during a leg.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:example/demos/capture_driver.dart';
import 'package:example/demos/frame_timing_capture_screen.dart';

/// Leg calls that record what a leg did and hold the flush open until
/// [flush] completes.
class _RecordingCalls extends CaptureLegCalls {
  final List<String> log = [];
  Completer<void>? flush;

  /// Whether the flush fails the way `flushTimelineNow` does past its
  /// 2 s limit.
  bool flushTimesOut = false;

  @override
  Future<void> suspendStreams() async => log.add('suspend');

  @override
  Future<void> resumeStreams() async => log.add('resume');

  @override
  Future<void> flushTimeline() {
    log.add('flush');
    if (flushTimesOut) {
      return Future.error(
        TimeoutException('flush', const Duration(seconds: 2)),
      );
    }
    return (flush ??= Completer<void>()).future;
  }

  @override
  void markScenarioBegin(String scenario) => log.add('begin $scenario');

  @override
  void markScenarioEnd(String scenario) => log.add('end $scenario');
}

const _below = 'Below (5% target), silent';
const _at = 'At (20% target), warning';
const _belowScenario = 'frame_timing_jank_detected_below';
const _atScenario = 'frame_timing_jank_detected_at';

void main() {
  // The test runs outside capture mode, without a VM link and without a
  // Sleuth instance, and the seams let a leg run anyway. With no Sleuth
  // instance the export returns null, so a finished leg ends with
  // "capture FAILED to compose".
  Future<void> pumpScreen(
    WidgetTester tester, {
    bool vmConnected = true,
    CaptureLegCalls calls = const CaptureLegCalls(),
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: FrameTimingCaptureScreen(
          captureModeOverride: true,
          provenanceCheck: () => (
            provenance: const CaptureProvenance(
              device: 'iPhone 12',
              deviceOsVersion: 'iOS 17.5',
              flutterVersion: '3.47.6',
            ),
            problem: null,
          ),
          vmConnected: () => vmConnected,
          calls: calls,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> startLeg(WidgetTester tester, String label) async {
    final button = find.text(label);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
  }

  /// Runs the 6 s span, the barrier and the post-end wait of a leg.
  Future<void> finishLeg(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
  }

  testWidgets('a leg without a VM link is refused before its workload', (
    tester,
  ) async {
    await pumpScreen(tester, vmConnected: false);
    await startLeg(tester, _at);
    expect(
      find.textContaining('[at] ABORT: VM service not connected'),
      findsOneWidget,
    );
    expect(find.textContaining('[at] attempt'), findsNothing);
  });

  testWidgets('two legs in a row run on one screen', (tester) async {
    final calls = _RecordingCalls()..flush = (Completer<void>()..complete());
    await pumpScreen(tester, calls: calls);
    await startLeg(tester, _below);
    await finishLeg(tester);
    await startLeg(tester, _below);
    await finishLeg(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('[below] attempt 1/3'), findsOneWidget);
    expect(find.textContaining('[below] attempt 2/3'), findsOneWidget);
    expect(
      find.textContaining('[below] capture FAILED to compose'),
      findsNWidgets(2),
    );
    expect(calls.log, [
      for (var leg = 0; leg < 2; leg++) ...[
        'suspend',
        'begin $_belowScenario',
        'flush',
        'end $_belowScenario',
        'resume',
      ],
    ]);
  });

  testWidgets('a flush that times out ends the leg with a FAILED line', (
    tester,
  ) async {
    final calls = _RecordingCalls()..flushTimesOut = true;
    await pumpScreen(tester, calls: calls);
    await startLeg(tester, _below);
    await finishLeg(tester);
    expect(find.textContaining('[below] FAILED: TimeoutException'), findsOne);
    expect(calls.log, [
      'suspend',
      'begin $_belowScenario',
      'flush',
      'end $_belowScenario',
      'resume',
    ]);
    // The buttons are enabled again.
    await startLeg(tester, _below);
    expect(find.textContaining('[below] attempt 2/3'), findsOneWidget);
    await finishLeg(tester);
  });

  testWidgets('closing the screen during the span ends the scenario and '
      'restores the streams at once', (tester) async {
    final calls = _RecordingCalls();
    await pumpScreen(tester, calls: calls);
    await startLeg(tester, _at);
    await tester.pump(const Duration(seconds: 1));
    expect(calls.log, ['suspend', 'begin $_atScenario']);
    // A pending span timer would fail the test when it ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls.log, [
      'suspend',
      'begin $_atScenario',
      'end $_atScenario',
      'resume',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the screen during the flush ends the scenario and '
      'restores the streams at once', (tester) async {
    final calls = _RecordingCalls();
    await pumpScreen(tester, calls: calls);
    await startLeg(tester, _below);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 300));
    // The leg now waits on a flush that has not answered.
    expect(calls.log, ['suspend', 'begin $_belowScenario', 'flush']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls.log.skip(3), ['end $_belowScenario', 'resume']);
    // The flush answering late must not end or resume anything again.
    calls.flush!.complete();
    await tester.pump();
    expect(calls.log, hasLength(5));
    expect(tester.takeException(), isNull);
  });
}
