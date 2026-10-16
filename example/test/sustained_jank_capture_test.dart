// Leg logic of the sustained_jank capture screen: the screen's severe
// rule, the spin schedule, the frame and last-record refusals, and the
// bracket it reads from the detector.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';

import 'package:example/demos/capture_driver.dart';
import 'package:example/demos/frame_timing_sustained_jank_capture_screen.dart';

/// A frame starting at 1 s with [delayUs] from vsync to build start,
/// [buildUs] of build, a 1 ms hand-off and [rasterUs] of raster.
FrameTiming _frame({
  int delayUs = 500,
  int buildUs = 4000,
  int rasterUs = 3000,
  int frameNumber = -1,
}) {
  const vsync = 1000000;
  final buildStart = vsync + delayUs;
  final buildFinish = buildStart + buildUs;
  final rasterStart = buildFinish + 1000;
  return FrameTiming(
    vsyncStart: vsync,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterStart + rasterUs,
    rasterFinishWallTime: rasterStart + rasterUs,
    frameNumber: frameNumber,
  );
}

/// A capture whose span holds `sustained_jank.critical` records with the
/// given `(observedSevereCount, bufferSize)` args, 1 ms apart, written in
/// time order or, with [reverseFileOrder], newest first.
String _capture(
  List<(Object?, Object?)> records, {
  bool dartArguments = false,
  String ph = 'n',
  bool reverseFileOrder = false,
}) {
  Map<String, Object?> record(int ts, (Object?, Object?) r) {
    final args = <String, Object?>{
      'observedSevereCount': ?r.$1,
      'bufferSize': ?r.$2,
    };
    return {
      'name': 'sleuth.issue.sustained_jank.critical',
      'ph': ph,
      'ts': ts,
      'args': dartArguments ? {'Dart Arguments': args} : args,
    };
  }

  final order = [for (var i = 0; i < records.length; i++) i];
  return jsonEncode({
    'traceEvents': [
      {
        'name': 'sleuth.scenario.begin',
        'ph': 'n',
        'ts': 1000,
        'args': {'name': 's'},
      },
      for (final i in reverseFileOrder ? order.reversed : order)
        record(2000 + i * 1000, records[i]),
      {
        'name': 'sleuth.scenario.end',
        'ph': 'n',
        'ts': 99000,
        'args': {'name': 's'},
      },
    ],
  });
}

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

void main() {
  final bracket = sustainedJankBracket(
    FrameTimingDetector().validationMetadata,
  )!;

  group('isCaptureSevere', () {
    test('build alone crosses twice the 60 Hz budget above 33,334 µs', () {
      expect(isCaptureSevere(_frame(delayUs: 0, buildUs: 33334)), isFalse);
      expect(isCaptureSevere(_frame(delayUs: 0, buildUs: 33335)), isTrue);
    });

    test('raster alone crosses the same line', () {
      expect(isCaptureSevere(_frame(rasterUs: 33334)), isFalse);
      expect(isCaptureSevere(_frame(rasterUs: 33335)), isTrue);
    });

    test('the whole start delay counts, Sleuth share included', () {
      // The detector would subtract Sleuth's share of the 30 ms delay;
      // the screen does not, so it is the stricter judge.
      expect(isCaptureSevere(_frame(delayUs: 30000, buildUs: 4000)), isTrue);
      expect(isCaptureSevere(_frame(delayUs: 29000, buildUs: 4000)), isFalse);
    });

    test('a 40 ms spin frame is severe', () {
      expect(isCaptureSevere(_frame(buildUs: 42000)), isTrue);
    });
  });

  group('SustainedJankLeg', () {
    test('spins 2, 3 and 6 times on ticks 30, 50, 70, ...', () {
      expect(SustainedJankLeg.values.map((l) => l.spins), [2, 3, 6]);
      expect(
        [for (var i = 0; i < 6; i++) SustainedJankLeg.above.spinTick(i)],
        [30, 50, 70, 90, 110, 130],
      );
    });

    test('stops 30 ticks after the last spin, inside the 240-frame '
        'buffer', () {
      expect(SustainedJankLeg.below.stopTick, 80);
      expect(SustainedJankLeg.at.stopTick, 100);
      expect(SustainedJankLeg.above.stopTick, 160);
    });

    test('scenario names match the capture file names', () {
      expect(SustainedJankLeg.values.map((l) => l.scenario), [
        'frame_timing_sustained_jank_below',
        'frame_timing_sustained_jank_at',
        'frame_timing_sustained_jank_above',
      ]);
    });
  });

  group('sustainedJankFrameRefusal', () {
    test('the spin frames and nothing else pass', () {
      expect(
        sustainedJankFrameRefusal(
          SustainedJankLeg.at,
          spinFrames: [40, 60, 80],
          severeFrames: [40, 60, 80],
          ambientSevere: 0,
        ),
        isNull,
      );
    });

    test('a severe frame before the first spin refuses the leg', () {
      final refusal = sustainedJankFrameRefusal(
        SustainedJankLeg.at,
        spinFrames: [40, 60, 80],
        severeFrames: [12, 40, 60, 80],
        ambientSevere: 1,
      );
      expect(refusal?.verdict, 'OUT-OF-BAND');
      expect(refusal?.reason, contains('before the first spin'));
    });

    test('missing spins are unmeasured', () {
      final refusal = sustainedJankFrameRefusal(
        SustainedJankLeg.above,
        spinFrames: [40, 60],
        severeFrames: [40, 60],
        ambientSevere: 0,
      );
      expect(refusal?.verdict, 'UNMEASURED');
      expect(refusal?.reason, '2 of 6 spins ran');
    });

    test('a severe frame after a spin refuses the leg', () {
      final refusal = sustainedJankFrameRefusal(
        SustainedJankLeg.below,
        spinFrames: [40, 60],
        severeFrames: [40, 41, 60],
        ambientSevere: 0,
      );
      expect(refusal?.reason, contains('3 severe frame(s)'));
    });

    test('the right count on the wrong frames refuses the leg', () {
      final refusal = sustainedJankFrameRefusal(
        SustainedJankLeg.below,
        spinFrames: [40, 60],
        severeFrames: [40, 61],
        ambientSevere: 0,
      );
      expect(refusal?.reason, contains('are not the spin frames'));
    });

    test('without frame numbers only the counts are compared', () {
      expect(
        sustainedJankFrameRefusal(
          SustainedJankLeg.below,
          spinFrames: [-1, -1],
          severeFrames: [-1, -1],
          ambientSevere: 0,
        ),
        isNull,
      );
    });
  });

  group('sustainedJankLastRecordRefusal', () {
    test('the last record at the spin count with room in the buffer '
        'passes', () {
      final json = _capture([('3', '120'), ('4', '130'), ('6', '170')]);
      expect(
        sustainedJankLastRecordRefusal(
          json,
          SustainedJankLeg.above,
          bracket: bracket,
        ),
        isNull,
      );
    });

    test('the last record, not the largest, is judged', () {
      final json = _capture([('6', '170'), ('5', '171')]);
      expect(
        sustainedJankLastRecordRefusal(
          json,
          SustainedJankLeg.above,
          bracket: bracket,
        )?.reason,
        contains('observedSevereCount is 5'),
      );
    });

    test('the latest record by time wins over file order', () {
      // The 6 is written first but stamped last.
      final json = _capture([
        ('5', '160'),
        ('6', '170'),
      ], reverseFileOrder: true);
      expect(
        sustainedJankLastRecordRefusal(
          json,
          SustainedJankLeg.above,
          bracket: bracket,
        ),
        isNull,
      );
    });

    test('a full buffer is refused', () {
      final json = _capture([('3', '240')]);
      expect(
        sustainedJankLastRecordRefusal(
          json,
          SustainedJankLeg.at,
          bracket: bracket,
        )?.reason,
        contains('bufferSize is 240'),
      );
    });

    test('a record without bufferSize is refused', () {
      final json = _capture([('3', null)]);
      expect(
        sustainedJankLastRecordRefusal(
          json,
          SustainedJankLeg.at,
          bracket: bracket,
        )?.reason,
        contains('bufferSize is null'),
      );
    });

    test('values under Dart Arguments are read', () {
      final json = _capture([('3', '110')], dartArguments: true);
      expect(
        sustainedJankLastRecordRefusal(
          json,
          SustainedJankLeg.at,
          bracket: bracket,
        ),
        isNull,
      );
    });

    test('only instant events are records', () {
      final json = _capture([('3', '110')], ph: 'X');
      expect(
        sustainedJankLastRecordRefusal(
          json,
          SustainedJankLeg.at,
          bracket: bracket,
        )?.reason,
        contains('no in-span'),
      );
    });

    test('below legs are not judged on a record', () {
      expect(
        sustainedJankLastRecordRefusal(
          _capture([]),
          SustainedJankLeg.below,
          bracket: bracket,
        ),
        isNull,
      );
    });
  });

  group('bracket', () {
    test('reads the detector bracket: threshold 3, at [3, 4.5], above '
        '(4.5, 7.5], last record, two in band', () {
      expect(bracket.eventName, 'sleuth.issue.sustained_jank.critical');
      expect(bracket.argKey, 'observedSevereCount');
      expect(bracket.bandText('below'), '(0, 3)');
      expect(bracket.bandText('at'), '[3, 4.5]');
      expect(bracket.bandText('above'), '(4.5, 7.5]');
      expect(bracket.reduction, 'last');
      expect(bracket.requiredInBand, 2);
      expect(bracket.observedAxisTolerance, 0.25);
    });

    test('each leg spin count is a measurement its role accepts', () {
      for (final leg in SustainedJankLeg.values) {
        expect(
          bracket.acceptsMeasurement(leg.spins, leg.label),
          isTrue,
          reason: leg.label,
        );
      }
    });

    test('an at leg with repeated records at 3 passes the record check', () {
      final check = checkCaptureJson(
        _capture([('3', '100'), ('3', '104'), ('3', '108')]),
        bracket: bracket,
        role: 'at',
        observed: 3,
        unit: 'frames',
      );
      expect(check.isPassed, isTrue, reason: check.reason);
    });

    test('an above leg needs two records in its band', () {
      final check = checkCaptureJson(
        _capture([('3', '100'), ('4', '120'), ('6', '160')]),
        bracket: bracket,
        role: 'above',
        observed: 6,
        unit: 'frames',
      );
      expect(check.problem, CaptureRecordProblem.tooFewInBand);
    });
  });

  group('leg lifecycle', () {
    // The test runs outside capture mode, without a VM link and without a
    // Sleuth instance, and the seams let a leg run anyway. No frame
    // timings arrive in a widget test, so a finished leg is refused for
    // its severe count.
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
          home: FrameTimingSustainedJankCaptureScreen(
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

    Future<void> runBelowLeg(WidgetTester tester) async {
      await tester.tap(find.text('Below: 2 severe frames'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('a leg without a VM link is refused before its workload', (
      tester,
    ) async {
      await pumpScreen(tester, vmConnected: false);
      await tester.tap(find.text('At: 3 severe frames'));
      await tester.pump();
      expect(
        find.textContaining('[at] ABORT: VM service not connected'),
        findsOneWidget,
      );
      expect(find.textContaining('[at] attempt'), findsNothing);
    });

    testWidgets('two legs in a row run on one screen', (tester) async {
      await pumpScreen(tester);
      await runBelowLeg(tester);
      await runBelowLeg(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('[below] attempt 1/5'), findsOneWidget);
      expect(find.textContaining('[below] attempt 2/5'), findsOneWidget);
      expect(
        find.textContaining('[below] OUT-OF-BAND: 0 severe frame(s)'),
        findsNWidgets(2),
      );
    });

    testWidgets('closing the screen during the flush ends the scenario '
        'and restores the streams at once', (tester) async {
      final calls = _RecordingCalls();
      await pumpScreen(tester, calls: calls);
      await runBelowLeg(tester);
      // The leg now waits on a flush that has not answered.
      expect(calls.log, [
        'suspend',
        'begin frame_timing_sustained_jank_below',
        'flush',
      ]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.log.skip(3), [
        'end frame_timing_sustained_jank_below',
        'resume',
      ]);
      // The flush answering late must not end or resume anything again.
      calls.flush!.complete();
      await tester.pump();
      expect(calls.log, hasLength(5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a finished leg ends its scenario and restores the streams '
        'once', (tester) async {
      final calls = _RecordingCalls()..flush = (Completer<void>()..complete());
      await pumpScreen(tester, calls: calls);
      await runBelowLeg(tester);
      expect(calls.log, [
        'suspend',
        'begin frame_timing_sustained_jank_below',
        'flush',
        'end frame_timing_sustained_jank_below',
        'resume',
      ]);
    });

    testWidgets('a flush that times out ends the leg with a FAILED line', (
      tester,
    ) async {
      final calls = _RecordingCalls()..flushTimesOut = true;
      await pumpScreen(tester, calls: calls);
      await runBelowLeg(tester);
      expect(
        find.textContaining('[below] FAILED: TimeoutException'),
        findsOneWidget,
      );
      expect(calls.log, [
        'suspend',
        'begin frame_timing_sustained_jank_below',
        'flush',
        'end frame_timing_sustained_jank_below',
        'resume',
      ]);
    });

    testWidgets('closing the screen mid-leg ends the leg at once', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tester.tap(find.text('Above: 6 severe frames'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // The ticker is running. Closing the screen must not leave the
      // leg waiting on its ticker timeout, because a pending timer fails
      // the test when it ends.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the screen lays out at phone size and names the '
      'preflight problems', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: FrameTimingSustainedJankCaptureScreen()),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Capture mode is off'), findsOneWidget);
    expect(
      find.textContaining('Capture provenance: device model unknown'),
      findsOneWidget,
    );
    // Outside capture mode every leg stays disabled.
    for (final label in [
      'Below: 2 severe frames',
      'At: 3 severe frames',
      'Above: 6 severe frames',
    ]) {
      final button = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );
      expect(button.onPressed, isNull, reason: label);
    }
  });
}
