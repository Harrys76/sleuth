// Leg logic of the raster_dominance capture screen: the screen's dominant
// rule and span count against the detector's, the leg table, the frame
// refusals, and the screen's pre-flight, lifecycle and stash behaviour.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' show FrameTiming;

import 'package:example/demos/capture_driver.dart';
import 'package:example/demos/raster_dominance_capture_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

const _provenance = CaptureProvenance(
  device: 'iPhone 12',
  deviceOsVersion: 'iOS 17.5',
  flutterVersion: '3.47.6',
);

CaptureProvenanceCheck _approved() => (provenance: _provenance, problem: null);

/// A frame starting at [vsync] µs with [buildUs] of build and [rasterUs]
/// of raster right after it.
FrameTiming _timing({
  required int number,
  required int vsync,
  int buildUs = 500,
  int rasterUs = 2000,
}) {
  final buildFinish = vsync + buildUs;
  return FrameTiming(
    vsyncStart: vsync,
    buildStart: vsync,
    buildFinish: buildFinish,
    rasterStart: buildFinish,
    rasterFinish: buildFinish + rasterUs,
    rasterFinishWallTime: buildFinish + rasterUs,
    frameNumber: number,
  );
}

RasterFrame _frame(
  int number,
  int vsync, {
  int uiUs = 500,
  int rasterUs = 2000,
}) => (number: number, vsyncUs: vsync, uiUs: uiUs, rasterUs: rasterUs);

CaptureBracket _bracket(String tier) =>
    rasterBracket(GpuPressureDetector().validationMetadata, tier)!;

/// Leg calls that record what a leg did and answer from fields.
class _FakeCalls extends RasterLegCalls {
  _FakeCalls();

  final List<String> log = [];
  int? entryUs;
  int nowUs = 600000000;
  bool vm = true;
  bool dashboard = false;
  int restoreRefusals = 0;

  /// The detector max the fake export stamps; null exports no record.
  int? Function(int observed)? stamp = (observed) => observed;

  /// Holds the suspension open until completed, when set.
  Completer<bool>? suspendGate;

  /// Holds the export open until completed, when set.
  Completer<void>? exportGate;

  @override
  Future<bool> suspendStreams() async {
    log.add('suspend');
    final gate = suspendGate;
    if (gate != null) {
      final accepted = await gate.future;
      log.add('suspend landed');
      return accepted;
    }
    return true;
  }

  @override
  Future<bool> resumeStreams() async {
    log.add('resume');
    if (restoreRefusals > 0) {
      restoreRefusals--;
      return false;
    }
    return true;
  }

  @override
  Future<void> flushTimeline() async => log.add('flush');

  @override
  void markScenarioBegin(String scenario) => log.add('begin $scenario');

  @override
  void markScenarioEnd(String scenario) => log.add('end $scenario');

  @override
  bool vmConnected() => vm;

  @override
  bool dashboardOpen() => dashboard;

  @override
  int? dartEntryMonotonicUs() => entryUs;

  @override
  int timelineNowUs() => nowUs;

  @override
  String? lastExportFailure() => null;

  @override
  Future<String?> exportCapture({
    required RasterLeg leg,
    required ({double min, double max}) band,
    required int observed,
    required CaptureProvenance provenance,
    required String captureNotes,
  }) async {
    log.add('export ${leg.scenario} $observed');
    final gate = exportGate;
    if (gate != null) await gate.future;
    final value = stamp?.call(observed);
    return jsonEncode({
      'traceEvents': [
        {'name': 'sleuth.scenario.begin', 'ph': 'n', 'ts': 1000},
        if (value != null && leg.role != 'below')
          {
            'name': 'sleuth.issue.raster_dominance.${leg.tier}',
            'ph': 'n',
            'ts': 2000,
            'args': {'observedDominantFrames': '$value'},
          },
        {'name': 'sleuth.scenario.end', 'ph': 'n', 'ts': 9000},
      ],
    });
  }
}

const _fastTiming = RasterLegTiming(
  settle: Duration(milliseconds: 20),
  runTimeout: Duration(seconds: 2),
  hideTimingTimeout: Duration(milliseconds: 500),
  dwell: Duration(milliseconds: 40),
  endBarrier: Duration(milliseconds: 20),
  restoreRetry: Duration(milliseconds: 10),
  attemptLimit: Duration(seconds: 20),
  burstTail: Duration(milliseconds: 20),
  frontCheck: Duration(milliseconds: 50),
);

void main() {
  group('isRasterDominant', () {
    test('raster must exceed the 16,667 µs budget', () {
      expect(isRasterDominant(uiUs: 1000, rasterUs: 16667), isFalse);
      expect(isRasterDominant(uiUs: 1000, rasterUs: 16668), isTrue);
    });

    test('raster must exceed twice the UI time', () {
      expect(isRasterDominant(uiUs: 10000, rasterUs: 20000), isFalse);
      expect(isRasterDominant(uiUs: 9999, rasterUs: 20000), isTrue);
    });

    test('a frame with no UI or no raster time does not count', () {
      expect(isRasterDominant(uiUs: 0, rasterUs: 30000), isFalse);
      expect(isRasterDominant(uiUs: 1000, rasterUs: 0), isFalse);
    });

    test('the floor applies when it is above the budget', () {
      expect(
        isRasterDominant(uiUs: 500, rasterUs: 8000, budgetUs: 4000),
        isFalse,
      );
      expect(
        isRasterDominant(uiUs: 500, rasterUs: 8001, budgetUs: 4000),
        isTrue,
      );
    });

    test('reads build and raster durations from a FrameTiming', () {
      final f = rasterFrameOf(
        _timing(number: 7, vsync: 1000, buildUs: 900, rasterUs: 29000),
      );
      expect(f, (number: 7, vsyncUs: 1000, uiUs: 900, rasterUs: 29000));
    });
  });

  group('busiestSpanCount', () {
    test('frames under a second apart share a span; a second apart do not', () {
      expect(busiestSpanCount([_frame(1, 0), _frame(2, 999999)]).count, 2);
      expect(busiestSpanCount([_frame(1, 0), _frame(2, 1000000)]).count, 1);
    });

    test('sorts by vsync and reports the span edges', () {
      final span = busiestSpanCount([
        _frame(3, 1500000),
        _frame(1, 0),
        _frame(2, 600000),
        _frame(4, 1550000),
      ]);
      expect(span.count, 3);
      expect(span.firstUs, 600000);
      expect(span.lastUs, 1550000);
    });

    test('empty input counts 0', () {
      expect(busiestSpanCount(const []).count, 0);
    });
  });

  group('RasterLeg', () {
    test('H and H + 1 dominant frames both land in each leg band', () {
      for (final leg in RasterLeg.values) {
        final bracket = _bracket(leg.tier);
        for (final count in [leg.heavyFrames, leg.heavyFrames + 1]) {
          expect(
            bracket.acceptsMeasurement(count, leg.role),
            isTrue,
            reason: '${leg.name}: $count',
          );
        }
      }
    });

    test('scenarios match the capture file names and labels are unique', () {
      expect(RasterLeg.at.scenario, 'raster_dominance_at');
      expect(
        RasterLeg.criticalAbove.scenario,
        'raster_dominance_critical_above',
      );
      final labels = RasterLeg.values.map((l) => l.buttonLabel).toSet();
      expect(labels, hasLength(RasterLeg.values.length));
      expect(RasterLeg.criticalAt.buttonLabel, 'Critical at: 11 heavy frames');
      expect(RasterLeg.below.buttonLabel, 'Below: 1 heavy frame');
    });

    test('the bands read from the detector metadata', () {
      expect(_bracket('warning').bandText('at'), '[3, 4.5]');
      expect(_bracket('warning').bandText('above'), '(4.5, 9]');
      expect(_bracket('critical').bandText('at'), '[10, 15]');
      expect(_bracket('critical').bandText('above'), '(15, 25]');
    });
  });

  group('rasterFrameRefusal', () {
    List<RasterFrame> run(int first, int heavy, {bool hideDominant = false}) =>
        [
          for (var i = 0; i < heavy; i++)
            _frame(first + i, i * 33333, rasterUs: 29000),
          _frame(
            first + heavy,
            heavy * 33333,
            rasterUs: hideDominant ? 20000 : 2000,
          ),
        ];

    test('counts the run and accepts a dominant hide frame', () {
      final judged = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [10, 11, 12],
        hideFrame: 13,
        frames: run(10, 3, hideDominant: true),
        bracket: _bracket('warning'),
      );
      expect(judged.refusal, isNull);
      expect(judged.count, 4);
    });

    test('refuses a dominant frame before the run', () {
      final judged = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [10, 11, 12],
        hideFrame: 13,
        frames: [_frame(5, -500000, rasterUs: 30000), ...run(10, 3)],
        bracket: _bracket('warning'),
      );
      expect(judged.refusal!.verdict, 'OUT-OF-BAND');
      expect(judged.refusal!.reason, contains('#5'));
    });

    test('a dominant frame within 250 ms after the hide frame belongs to '
        'the run', () {
      // The hide frame starts at 99,999 µs; this one 250 ms after it.
      final judged = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [10, 11, 12],
        hideFrame: 13,
        frames: [...run(10, 3), _frame(16, 349999, rasterUs: 30000)],
        bracket: _bracket('warning'),
      );
      expect(judged.refusal, isNull);
      expect(judged.count, 4);
    });

    test('refuses a dominant frame more than 250 ms after the hide frame', () {
      final judged = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [10, 11, 12],
        hideFrame: 13,
        frames: [...run(10, 3), _frame(16, 350000, rasterUs: 30000)],
        bracket: _bracket('warning'),
      );
      expect(judged.refusal!.reason, contains('#16'));
    });

    test('refuses a dominant frame after a light frame that follows the '
        'hide frame, even within 250 ms', () {
      // Hide #13 and the next frame #14 are light; #15, 100 ms after the
      // hide frame, is dominant and cannot belong to the run.
      final judged = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [10, 11, 12],
        hideFrame: 13,
        frames: [
          ...run(10, 3),
          _frame(14, 149999),
          _frame(15, 199999, rasterUs: 30000),
        ],
        bracket: _bracket('warning'),
      );
      expect(judged.refusal!.verdict, 'OUT-OF-BAND');
      expect(judged.refusal!.reason, contains('#15'));
    });

    test('refuses a run with a heavy frame that is not dominant', () {
      final judged = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [10, 11, 12],
        hideFrame: 13,
        frames: [
          _frame(10, 0, rasterUs: 29000),
          _frame(11, 33333, rasterUs: 12000),
          _frame(12, 66666, rasterUs: 29000),
          _frame(13, 99999, rasterUs: 20000),
          _frame(14, 133333, rasterUs: 20000),
        ],
        bracket: _bracket('warning'),
      );
      expect(judged.refusal!.verdict, 'UNMEASURED');
      expect(judged.refusal!.reason, contains('#11'));
    });

    test('refuses a run whose heavy frame reported no timing', () {
      final judged = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [10, 11, 12],
        hideFrame: 13,
        frames: [
          _frame(10, 0, rasterUs: 29000),
          _frame(12, 66666, rasterUs: 29000),
          _frame(13, 99999),
        ],
        bracket: _bracket('warning'),
      );
      expect(judged.refusal!.reason, contains('#11 reported no timing'));
    });

    test('rasterContinuationFrame picks the first frame after the hide frame '
        'within 250 ms', () {
      final frames = [
        _frame(13, 1000000),
        _frame(16, 1300000),
        _frame(15, 1100000),
      ];
      expect(
        rasterContinuationFrame(frames, hideFrame: 13, hideVsyncUs: 1000000),
        15,
      );
      expect(
        rasterContinuationFrame(
          [_frame(13, 1000000), _frame(14, 1250001)],
          hideFrame: 13,
          hideVsyncUs: 1000000,
        ),
        isNull,
      );
    });

    test('refuses a run whose hide frame reported no timing', () {
      final judged = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [10, 11, 12],
        hideFrame: 13,
        frames: run(10, 3).sublist(0, 3),
        bracket: _bracket('warning'),
      );
      expect(judged.refusal!.verdict, 'UNMEASURED');
    });

    test('refuses a run without frame numbers', () {
      final judged = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [-1, -1, -1],
        hideFrame: -1,
        frames: run(10, 3),
        bracket: _bracket('warning'),
      );
      expect(judged.refusal!.verdict, 'UNMEASURED');
    });

    test('refuses a run that did not draw every heavy frame', () {
      final judged = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [10, 11],
        hideFrame: null,
        frames: run(10, 2),
        bracket: _bracket('warning'),
      );
      expect(judged.refusal!.verdict, 'UNMEASURED');
      expect(judged.refusal!.reason, contains('2 of 3'));
    });

    test('refuses a count outside the band', () {
      final judged = rasterFrameRefusal(
        RasterLeg.below,
        heavyFrames: [10],
        hideFrame: 11,
        frames: [
          ...run(10, 1, hideDominant: true),
          _frame(9, -33333, rasterUs: 29000),
        ],
        bracket: _bracket('warning'),
      );
      // Frame 9 sits before the run, so it refuses as ambient first.
      expect(judged.refusal!.verdict, 'OUT-OF-BAND');

      final wide = rasterFrameRefusal(
        RasterLeg.at,
        heavyFrames: [10, 11, 12],
        hideFrame: 13,
        frames: [
          for (var i = 0; i < 3; i++) _frame(10 + i, i * 33333, rasterUs: 2000),
          _frame(13, 99999, rasterUs: 2000),
        ],
        bracket: _bracket('warning'),
      );
      // Light heavy frames: the run did not draw what it should.
      expect(wide.refusal!.verdict, 'UNMEASURED');
      expect(wide.refusal!.reason, contains('was not raster-dominant'));
      expect(wide.count, isNull);
    });
  });

  group('the screen count equals the detector stamp', () {
    // The FrameTiming batches go through FrameTimingDetector's real
    // conversion to FrameStats, as in the app.
    Future<(int screen, int detector)> replay(
      WidgetTester tester,
      List<List<FrameTiming>> batches,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final gpu = GpuPressureDetector(
        appStartMonotonicUsForTest: () => developer.Timeline.now - 60000000,
      );
      final frames = FrameTimingDetector(
        captureMode: true,
        onFrame: gpu.processFrame,
      );
      addTearDown(gpu.dispose);
      addTearDown(frames.dispose);
      var stamped = 0;
      final judged = <RasterFrame>[];
      for (final batch in batches) {
        frames.handleTimingsForTest(batch);
        judged.addAll(batch.map(rasterFrameOf));
        gpu.scanTree(tester.element(find.byType(SizedBox)));
        for (final issue in gpu.issues) {
          if (issue.stableId != 'raster_dominance') continue;
          final n = int.parse(issue.extraTraceArgs!['observedDominantFrames']!);
          if (n > stamped) stamped = n;
          expect(issue.observationSource, ObservationSource.frameTiming);
        }
      }
      final dominant = [
        for (final f in judged)
          if (isRasterDominant(uiUs: f.uiUs, rasterUs: f.rasterUs)) f,
      ];
      return (busiestSpanCount(dominant).count, stamped);
    }

    List<FrameTiming> heavy(int first, int count, int startUs, int gapUs) => [
      for (var i = 0; i < count; i++)
        _timing(number: first + i, vsync: startUs + i * gapUs, rasterUs: 29000),
    ];

    testWidgets('a run split by a scan, with a dominant hide frame', (
      tester,
    ) async {
      final run = [
        ...heavy(1, 11, 1000000, 33333),
        _timing(number: 12, vsync: 1000000 + 11 * 33333, rasterUs: 20000),
      ];
      final (screen, detector) = await replay(tester, [
        run.sublist(0, 5),
        run.sublist(5),
      ]);
      expect(screen, 12);
      expect(detector, screen);
    });

    testWidgets('a run longer than a second, split twice', (tester) async {
      final run = heavy(1, 22, 1000000, 56000);
      final (screen, detector) = await replay(tester, [
        run.sublist(0, 7),
        run.sublist(7, 15),
        run.sublist(15),
      ]);
      expect(screen, lessThan(22));
      expect(detector, screen);
    });

    testWidgets('light frames between batches and a straggler batch', (
      tester,
    ) async {
      final run = heavy(10, 3, 5000000, 33333);
      final (screen, detector) = await replay(tester, [
        [_timing(number: 1, vsync: 4000000)],
        run.sublist(0, 2),
        [run[2], _timing(number: 13, vsync: 5100000)],
        [_timing(number: 14, vsync: 7000000)],
      ]);
      expect(screen, 3);
      expect(detector, screen);
    });
  });

  group('screen', () {
    late DateTime now;

    Widget app(_FakeCalls calls, {bool captureMode = true}) => MaterialApp(
      home: RasterDominanceCaptureScreen(
        captureModeOverride: captureMode,
        provenanceCheck: _approved,
        calls: calls,
        frameNumber: _nextFrameNumber,
        clock: () => now,
        timing: _fastTiming,
      ),
    );

    setUp(() {
      now = DateTime(2026, 10, 16, 12);
      _frameCounter = 100;
    });

    Future<void> open(WidgetTester tester, _FakeCalls calls) async {
      _prepareView(tester);
      await tester.pumpWidget(app(calls));
      await tester.pump();
      now = now.add(const Duration(seconds: 4));
    }

    Future<void> tapLeg(WidgetTester tester, RasterLeg leg) async {
      final button = find.text(leg.buttonLabel);
      await tester.ensureVisible(button);
      await tester.tap(button);
    }

    List<String> logLines(WidgetTester tester) => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .toList();

    bool logged(WidgetTester tester, String part) =>
        logLines(tester).any((l) => l.contains(part));

    /// Drives a leg: pumps the run's ticker frames, then delivers timings
    /// for the heavy frames (raster [heavyRasterUs]) and the hide frame
    /// (raster [hideRasterUs]), then lets the leg finish.
    Future<void> driveLeg(
      WidgetTester tester,
      RasterLeg leg, {
      int heavyRasterUs = 29000,
      int hideRasterUs = 2000,
      List<FrameTiming> extra = const [],
    }) async {
      final first = _frameCounter;
      await tapLeg(tester, leg);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 17));
      }
      final timings = [
        for (var i = 0; i < leg.heavyFrames; i++)
          _timing(
            number: first + i,
            vsync: 1000000 + i * 33333,
            rasterUs: heavyRasterUs,
          ),
        _timing(
          number: first + leg.heavyFrames,
          vsync: 1000000 + leg.heavyFrames * 33333,
          rasterUs: hideRasterUs,
        ),
        ...extra,
      ];
      tester.binding.platformDispatcher.onReportTimings?.call(timings);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('without an approved provenance the legs stay disabled and '
        'the banner names the problem', (tester) async {
      _prepareView(tester);
      final calls = _FakeCalls();
      await tester.pumpWidget(
        MaterialApp(
          home: RasterDominanceCaptureScreen(
            captureModeOverride: true,
            provenanceCheck: () =>
                (provenance: null, problem: 'device model unknown'),
            calls: calls,
            clock: () => now,
            timing: _fastTiming,
          ),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('Capture provenance: device model unknown'),
        findsOneWidget,
      );
      for (final leg in RasterLeg.values) {
        final button = tester.widget<FilledButton>(
          find.ancestor(
            of: find.text(leg.buttonLabel),
            matching: find.byType(FilledButton),
          ),
        );
        expect(button.onPressed, isNull, reason: leg.name);
      }
      expect(calls.log, isEmpty);
    });

    testWidgets('capture mode off refuses before any burst', (tester) async {
      final calls = _FakeCalls();
      await tester.pumpWidget(app(calls, captureMode: false));
      await tester.pump();
      await tapLeg(tester, RasterLeg.at);
      await tester.pump();
      expect(calls.log, isEmpty);
    });

    testWidgets('a leg right after the screen opens is refused', (
      tester,
    ) async {
      final calls = _FakeCalls();
      _prepareView(tester);
      await tester.pumpWidget(app(calls));
      await tester.pump();
      await tapLeg(tester, RasterLeg.at);
      await tester.pump();
      expect(calls.log, isEmpty);
      expect(logged(tester, 'route-change scan'), isTrue);
    });

    testWidgets('VM disconnected, startup window and dashboard each refuse', (
      tester,
    ) async {
      final calls = _FakeCalls()..vm = false;
      await open(tester, calls);
      await tapLeg(tester, RasterLeg.at);
      await tester.pump();
      expect(logged(tester, 'VM service not connected'), isTrue);

      calls
        ..vm = true
        ..entryUs = calls.nowUs - 2000000;
      await tapLeg(tester, RasterLeg.at);
      await tester.pump();
      expect(logged(tester, 'inside the window'), isTrue);

      calls
        ..entryUs = null
        ..dashboard = true;
      await tapLeg(tester, RasterLeg.at);
      await tester.pump();
      expect(logged(tester, 'dashboard is open'), isTrue);
      expect(calls.log, isEmpty);
    });

    testWidgets('a clean at leg is stashed and exported with its count', (
      tester,
    ) async {
      final calls = _FakeCalls();
      await open(tester, calls);
      await driveLeg(tester, RasterLeg.at);
      expect(calls.log, [
        'suspend',
        'begin raster_dominance_at',
        'flush',
        'end raster_dominance_at',
        'resume',
        'export raster_dominance_at 3',
      ]);
      expect(logged(tester, 'capture stashed: 3 dominant frames'), isTrue);
    });

    testWidgets('a detector max one lower refuses the leg', (tester) async {
      final calls = _FakeCalls()..stamp = (observed) => observed - 1;
      await open(tester, calls);
      await driveLeg(tester, RasterLeg.at, hideRasterUs: 20000);
      expect(logged(tester, 'capture stashed'), isFalse);
      expect(logged(tester, 'OUT-OF-BAND'), isTrue);
    });

    testWidgets('an ambient dominant frame refuses the leg before export', (
      tester,
    ) async {
      final calls = _FakeCalls();
      await open(tester, calls);
      await driveLeg(
        tester,
        RasterLeg.at,
        extra: [_timing(number: 50, vsync: 500000, rasterUs: 30000)],
      );
      expect(calls.log.where((l) => l.startsWith('export')), isEmpty);
      expect(logged(tester, 'outside the run'), isTrue);
      expect(calls.log.where((l) => l.startsWith('end')), hasLength(1));
    });

    testWidgets('a restore the VM never accepts fails the leg', (tester) async {
      final calls = _FakeCalls()..restoreRefusals = 6;
      await open(tester, calls);
      await driveLeg(tester, RasterLeg.at);
      expect(calls.log.where((l) => l.startsWith('export')), isEmpty);
      expect(logged(tester, 'did not restore the timeline streams'), isTrue);
      expect(calls.log.where((l) => l == 'resume'), hasLength(6));
    });

    testWidgets('leaving the foreground during the run ends it UNMEASURED', (
      tester,
    ) async {
      final calls = _FakeCalls();
      await open(tester, calls);
      await tapLeg(tester, RasterLeg.at);
      await tester.pump(const Duration(milliseconds: 30));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(logged(tester, 'UNMEASURED: the app left the foreground'), isTrue);
      expect(calls.log.where((l) => l.startsWith('end')), hasLength(1));
      expect(calls.log.where((l) => l == 'resume'), hasLength(1));
    });

    testWidgets('closing the screen mid-leg ends the scenario once and '
        'restores the streams', (tester) async {
      final calls = _FakeCalls();
      await open(tester, calls);
      await tapLeg(tester, RasterLeg.at);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls.log.where((l) => l.startsWith('end')), hasLength(1));
      expect(calls.log.where((l) => l == 'resume'), hasLength(1));
      expect(calls.log.where((l) => l.startsWith('export')), isEmpty);
    });

    testWidgets('a refused leg keeps the earlier stash', (tester) async {
      final calls = _FakeCalls();
      await open(tester, calls);
      await driveLeg(tester, RasterLeg.at);
      calls.stamp = (observed) => observed - 1;
      await driveLeg(tester, RasterLeg.above);
      expect(logged(tester, 'Stashed: At'), isTrue);
    });

    testWidgets('a tap refused before an attempt sets the status line and '
        'rasterState', (tester) async {
      final calls = _FakeCalls()..dashboard = true;
      await open(tester, calls);
      await tapLeg(tester, RasterLeg.at);
      await tester.pump();
      final status = tester.widget<Text>(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is Semantics && (w.properties.liveRegion ?? false),
          ),
          matching: find.byType(Text),
        ),
      );
      expect(status.data, contains('dashboard is open'));
      final runner =
          tester.state(find.byType(RasterDominanceCaptureScreen))
              as RasterBurstRunner;
      expect(
        runner.harnessState()['lastRefusal'],
        contains('dashboard is open'),
      );
    });

    testWidgets('a rejected refresh rate leaves the legs tappable and is '
        'read again at the tap', (tester) async {
      final calls = _FakeCalls();
      await open(tester, calls);
      tester.view.display.refreshRate = 120;
      await tapLeg(tester, RasterLeg.at);
      await tester.pump();
      expect(logged(tester, 'Set the display to 60 Hz'), isTrue);
      expect(calls.log, isEmpty);

      tester.view.display.refreshRate = 60;
      await driveLeg(tester, RasterLeg.at);
      expect(logged(tester, 'capture stashed: 3 dominant frames'), isTrue);
    });

    testWidgets('pulling down Control Center after the span closes does not '
        'drop the leg', (tester) async {
      final calls = _FakeCalls()..exportGate = Completer<void>();
      await open(tester, calls);
      await driveLeg(tester, RasterLeg.at);
      expect(calls.log.last, 'export raster_dominance_at 3');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      calls.exportGate!.complete();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(logged(tester, 'capture stashed: 3 dominant frames'), isTrue);
    });

    testWidgets('closing the screen while the suspension is unanswered '
        'restores the streams after it lands', (tester) async {
      final calls = _FakeCalls()..suspendGate = Completer<bool>();
      await open(tester, calls);
      await tapLeg(tester, RasterLeg.at);
      await tester.pump();
      expect(calls.log, ['suspend']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls.log, ['suspend'], reason: 'no restore before it lands');
      calls.suspendGate!.complete(true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls.log, ['suspend', 'suspend landed', 'resume']);
    });

    testWidgets('a suspension still unanswered after the wait is followed by '
        'one more restore when it lands', (tester) async {
      final calls = _FakeCalls()..suspendGate = Completer<bool>();
      await open(tester, calls);
      await tapLeg(tester, RasterLeg.at);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      // Past the 5 s wait the restore goes ahead.
      await tester.pump(const Duration(seconds: 6));
      expect(calls.log, ['suspend', 'resume']);
      calls.suspendGate!.complete(true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls.log, ['suspend', 'resume', 'suspend landed', 'resume']);
    });

    testWidgets('a burst outside a leg refuses inside the route settle', (
      tester,
    ) async {
      final calls = _FakeCalls();
      _prepareView(tester);
      await tester.pumpWidget(app(calls));
      await tester.pump();
      final runner =
          tester.state(find.byType(RasterDominanceCaptureScreen))
              as RasterBurstRunner;
      final result = await runner.runBurst(
        frames: 3,
        paths: 10,
        budgetUs: 16667,
      );
      expect(result['error'], contains('route-change scan'));
    });
  });
}

int _frameCounter = 100;

/// A 390 x 2000 logical view at 60 Hz, tall enough that every control and
/// many log lines are laid out.
void _prepareView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 6000);
  tester.view.devicePixelRatio = 3.0;
  tester.view.display.refreshRate = 60;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.display.resetRefreshRate);
}

int _nextFrameNumber() => _frameCounter++;
