// The slow_startup_ttff capture flow: the leg table against the
// detector's brackets, the launch request, the observed value, the
// result files, the leg runner's paths and the result screen.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:example/demos/capture_driver.dart';
import 'package:example/demos/slow_startup_capture_screen.dart';
import 'package:example/demos/startup_leg.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/startup_detector.dart';

const _provenance = CaptureProvenance(
  device: 'iPhone 12',
  deviceOsVersion: 'iOS 17.5',
  flutterVersion: '3.47.6',
);

CaptureProvenanceCheck _approved() => (provenance: _provenance, problem: null);

const _markerWallUs = 1792126320000000;

/// A first frame whose raster finished [ms] after the marker, in wall
/// time.
FrameTiming _frameAt(num ms) => FrameTiming(
  vsyncStart: 1000,
  buildStart: 1100,
  buildFinish: 2100,
  rasterStart: 2200,
  rasterFinish: 3200,
  rasterFinishWallTime: _markerWallUs + (ms * 1000).round(),
);

/// A composed capture whose span holds [records] of [event], each with
/// `observedTtffMs` [value].
String _capture({String? event, String value = '1652.0', int records = 1}) {
  return jsonEncode({
    'traceEvents': [
      {
        'name': 'sleuth.scenario.begin',
        'ph': 'n',
        'ts': 1000,
        'args': {'name': 's'},
      },
      if (event != null)
        for (var i = 0; i < records; i++)
          {
            'name': event,
            'ph': 'n',
            'ts': 2000 + i * 1000,
            'args': {'observedTtffMs': value},
          },
      {
        'name': 'sleuth.scenario.end',
        'ph': 'n',
        'ts': 99000,
        'args': {'name': 's'},
      },
    ],
  });
}

/// Leg calls that record what a leg did.
class _FakeCalls extends StartupLegCalls {
  _FakeCalls({
    this.connectAfterPolls = 0,
    this.evaluated = true,
    this.detectorMs = 1652.0,
    this.json,
  });

  /// Polls of [vmConnected] before it returns true; negative never.
  final int connectAfterPolls;
  bool evaluated;
  final double? detectorMs;

  /// The export's result; null composes nothing.
  final String? json;

  final List<String> log = [];
  ({double min, double max})? exportBand;
  double? exportObserved;
  String? exportNotes;
  int _connectPolls = 0;

  @override
  void markScenarioBegin(String scenario) => log.add('begin $scenario');

  @override
  void markScenarioEnd(String scenario) => log.add('end $scenario');

  @override
  Future<void> flushTimeline() async => log.add('flush');

  @override
  Future<void> suspendStreams() async => log.add('suspend');

  @override
  Future<void> resumeStreams() async => log.add('resume');

  @override
  bool vmConnected() =>
      connectAfterPolls >= 0 && _connectPolls++ >= connectAfterPolls;

  @override
  bool? detectorEvaluated() => evaluated;

  @override
  double? detectorTtffMs() => detectorMs;

  @override
  Future<String?> exportCapture({
    required StartupLeg leg,
    required ({double min, double max}) band,
    required double observed,
    required CaptureProvenance provenance,
    required String captureNotes,
  }) async {
    log.add('export');
    exportBand = band;
    exportObserved = observed;
    exportNotes = captureNotes;
    return json;
  }

  @override
  String? lastExportFailure() => 'no scenario span';
}

void main() {
  final metadata = StartupDetector().validationMetadata;

  group('legs', () {
    test('delays are the target minus the measured base, at most 4.5 s', () {
      expect(
        {for (final leg in StartupLeg.values) leg.scenario: leg.delayMs},
        {
          'slow_startup_ttff_below': 926,
          'slow_startup_ttff_at': 1576,
          'slow_startup_ttff_above': 2326,
          'slow_startup_ttff_critical_below': 2326,
          'slow_startup_ttff_critical_at': 3226,
          'slow_startup_ttff_critical_above': 4426,
        },
      );
      for (final leg in StartupLeg.values) {
        expect(leg.delayMs, lessThanOrEqualTo(kMaxStartupDelayMs));
        expect(StartupLeg.fromScenario(leg.scenario), leg);
      }
      expect(StartupLeg.fromScenario('slow_startup_ttff'), isNull);
    });

    test('each target lies in its role band of the detector bracket', () {
      for (final leg in StartupLeg.values) {
        final bracket = startupLegBracket(metadata, leg)!;
        expect(
          bracket.acceptsMeasurement(leg.targetMs, leg.role),
          isTrue,
          reason:
              '${leg.label} ${leg.targetMs} ms vs ${bracket.bandText(leg.role)}',
        );
      }
    });

    test('the warning above leg stays below the critical line', () {
      expect(
        StartupLeg.above.targetMs,
        lessThan(StartupDetector().ttffCriticalMs),
      );
    });

    test('export bands stay inside the role bands', () {
      for (final leg in StartupLeg.values) {
        final bracket = startupLegBracket(metadata, leg)!;
        final band = startupLegBand(bracket, leg.role);
        expect(band.min, greaterThan(0));
        expect(band.min, lessThan(band.max));
      }
    });

    test('the launch command copies the request file, then relaunches', () {
      expect(
        StartupLeg.at.launchCommand(device: 'A4DE'),
        'printf slow_startup_ttff_at > /tmp/sleuth_startup_leg_request.txt && '
        'xcrun devicectl device copy to --device A4DE '
        '--domain-type appDataContainer '
        '--domain-identifier com.example.example '
        '--source /tmp/sleuth_startup_leg_request.txt '
        '--destination tmp/sleuth_startup_leg_request.txt && '
        'xcrun devicectl device process launch --device A4DE '
        '--terminate-existing com.example.example',
      );
    });
  });

  group('request', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('startup_request');
      file = File('${dir.path}/$kStartupLegRequestFile');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('the request file names the leg and is deleted on read', () {
      file.writeAsStringSync('slow_startup_ttff_critical_at\n');
      final request = StartupLegRequest.read(
        environment: const {},
        definedLeg: '',
        definedDelay: '',
        requestFile: file,
      );
      expect(request.leg, StartupLeg.criticalAt);
      expect(file.existsSync(), isFalse);
      // A second launch finds no file and runs normally.
      final next = StartupLegRequest.read(
        environment: const {},
        definedLeg: '',
        definedDelay: '',
        requestFile: file,
      );
      expect(next.isEmpty, isTrue);
    });

    test('the environment wins over the request file, which is still '
        'deleted', () {
      file.writeAsStringSync('slow_startup_ttff_below');
      final request = StartupLegRequest.read(
        environment: const {kStartupLegVariable: 'slow_startup_ttff_above'},
        definedLeg: '',
        definedDelay: '',
        requestFile: file,
      );
      expect(request.leg, StartupLeg.above);
      expect(file.existsSync(), isFalse);
    });

    test('a request file with an unknown leg is ignored with a problem', () {
      file.writeAsStringSync('slow_startup_ttff_middle');
      final request = StartupLegRequest.read(
        environment: const {},
        definedLeg: '',
        definedDelay: '',
        requestFile: file,
      );
      expect(request.leg, isNull);
      expect(request.problem, contains('unknown startup leg'));
      expect(file.existsSync(), isFalse);
    });

    test('no variable is an ordinary launch', () {
      final request = StartupLegRequest.read(
        environment: const {},
        definedLeg: '',
        definedDelay: '',
        requestFile: file,
      );
      expect(request.isEmpty, isTrue);
      expect(request.delayMs, 0);
      expect(request.problem, isNull);
    });

    test('the environment wins over a dart-define', () {
      final request = StartupLegRequest.read(
        environment: const {kStartupLegVariable: 'slow_startup_ttff_at'},
        definedLeg: 'slow_startup_ttff_below',
        definedDelay: '',
        requestFile: file,
      );
      expect(request.leg, StartupLeg.at);
      expect(request.delayMs, 1576);
    });

    test('an unknown leg and a bad delay are ignored with a problem', () {
      final request = StartupLegRequest.read(
        environment: const {
          kStartupLegVariable: 'slow_startup_ttff_middle',
          kStartupDelayVariable: 'soon',
        },
        definedLeg: '',
        definedDelay: '',
        requestFile: file,
      );
      expect(request.leg, isNull);
      expect(request.delayMs, 0);
      expect(request.problem, contains('unknown startup leg'));
      expect(request.problem, contains('not a whole ms count'));
    });

    test('a plain delay is capped at 4.5 s', () {
      final request = StartupLegRequest.read(
        environment: const {},
        definedLeg: '',
        definedDelay: '9000',
        requestFile: file,
      );
      expect(request.leg, isNull);
      expect(request.delayMs, kMaxStartupDelayMs);
    });

    test('a leg needs capture mode and an approved provenance', () {
      expect(
        startupLegRefusal(StartupLeg.at, captureMode: false, check: _approved),
        contains('capture mode is off'),
      );
      expect(
        startupLegRefusal(
          StartupLeg.at,
          captureMode: true,
          check: () => (provenance: null, problem: 'device model unknown'),
        ),
        'capture provenance: device model unknown',
      );
      expect(
        startupLegRefusal(StartupLeg.at, captureMode: true, check: _approved),
        isNull,
      );
    });
  });

  group('launch', () {
    late Directory dir;
    late List<Duration> slept;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('startup_launch');
      slept = [];
    });

    tearDown(() => dir.deleteSync(recursive: true));

    StartupLaunch launch({
      required StartupLegRequest request,
      bool captureMode = true,
      CaptureProvenanceCheck Function() check = _approved,
    }) => StartupLaunch.read(
      captureMode: captureMode,
      request: request,
      check: check,
      sleeper: slept.add,
      results: () => StartupLegResults(dir),
    );

    test('an ordinary launch sleeps and records nothing', () {
      final startup = launch(request: const StartupLegRequest());
      startup.delay();
      expect(startup.afterRunApp(), isNull);
      expect(slept, isEmpty);
      expect(startup.markerWallUs, 0);
      expect(StartupLegResults(dir).readRecord(), isNull);
    });

    test('a plain delay sleeps with no leg', () {
      final startup = launch(
        request: const StartupLegRequest(plainDelayMs: 1800),
      );
      startup.delay();
      expect(slept, [const Duration(milliseconds: 1800)]);
      expect(startup.runsLeg, isFalse);
      expect(startup.afterRunApp(), isNull);
    });

    test('a leg in a build without capture mode gets no delay and an '
        'ABORT record', () {
      final startup = launch(
        request: const StartupLegRequest(leg: StartupLeg.at),
        captureMode: false,
      );
      startup.delay();
      expect(slept, isEmpty);
      expect(startup.afterRunApp(), isNull);
      final record = StartupLegResults(dir).readRecord()!;
      expect(record.verdict, 'ABORT');
      expect(record.reason, contains('capture mode is off'));
      expect(record.scenario, 'slow_startup_ttff_at');
    });

    test('a leg without provenance gets no delay and an ABORT record', () {
      final startup = launch(
        request: const StartupLegRequest(leg: StartupLeg.criticalAt),
        check: () => (provenance: null, problem: 'device model unknown'),
      );
      startup.delay();
      expect(slept, isEmpty);
      startup.afterRunApp();
      expect(
        StartupLegResults(dir).readRecord()!.reason,
        'capture provenance: device model unknown',
      );
    });

    test('an accepted leg sleeps its delay and takes the marker', () {
      final before = DateTime.now().microsecondsSinceEpoch;
      final startup = launch(
        request: const StartupLegRequest(leg: StartupLeg.criticalAbove),
      );
      startup.delay();
      expect(slept, [const Duration(milliseconds: 4426)]);
      expect(startup.runsLeg, isTrue);
      expect(startup.markerWallUs, greaterThanOrEqualTo(before));
    });
  });

  group('observed time to first frame', () {
    test('is the raster-finish wall time minus the marker', () {
      expect(observedTtffMs(_frameAt(1650), _markerWallUs), 1650.0);
    });

    test('is null without a timing or with an implausible wall time', () {
      expect(observedTtffMs(null, _markerWallUs), isNull);
      expect(observedTtffMs(_frameAt(0), _markerWallUs), isNull);
      expect(observedTtffMs(_frameAt(-5), _markerWallUs), isNull);
      expect(observedTtffMs(_frameAt(61000), _markerWallUs), isNull);
    });
  });

  group('results', () {
    late Directory dir;
    late StartupLegResults results;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('startup_leg_test');
      results = StartupLegResults(dir);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('a record round-trips through its file', () {
      final record = StartupLegRecord(
        launchId: '7-1',
        scenario: 'slow_startup_ttff_at',
        state: 'stashed',
        observedMs: 1650.5,
        detectorMs: 1652.25,
        delayMs: 1576,
        chars: 1234,
        updatedAt: DateTime.utc(2026, 10, 16, 12),
      );
      results.writeRecord(record);
      final read = results.readRecord()!;
      expect(read.toJson(), record.toJson());
      expect(
        dir.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('an unreadable record throws, and no file reads as no leg', () {
      expect(results.readRecord(), isNull);
      File('${dir.path}/$kStartupLegRecordFile').writeAsStringSync('{"x":');
      expect(results.readRecord, throwsFormatException);
    });

    test('a running record from another launch is repaired as FAILED', () {
      results.writeRecord(
        const StartupLegRecord(
          launchId: '7-1',
          scenario: 'slow_startup_ttff_at',
          state: 'running',
        ),
      );
      expect(results.repairStale(currentLaunchId: '7-1'), isNull);
      final repaired = results.repairStale(currentLaunchId: '8-2')!;
      expect(repaired.state, 'failed');
      expect(repaired.reason, contains('ended during the leg'));
      expect(results.readRecord()!.state, 'failed');
    });
  });

  group('runner', () {
    late Directory dir;
    late StartupLegResults results;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('startup_leg_runner');
      results = StartupLegResults(dir);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<StartupLegRecord> run(
      WidgetTester tester, {
      required StartupLeg leg,
      required _FakeCalls calls,
      FrameTiming? frame,
      Duration overallLimit = const Duration(seconds: 25),
      void Function()? midway,
      int midwayAtPump = 5,
    }) async {
      final firstFrame = FirstFrameRecorder();
      if (frame != null) firstFrame.recordForTest(frame);
      final done = StartupLegRunner(
        leg: leg,
        markerWallUs: _markerWallUs,
        firstFrame: firstFrame,
        launchId: '7-1',
        results: results,
        calls: calls,
        provenanceCheck: _approved,
        overallLimit: overallLimit,
      ).start();
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 300; i++) {
        if (i == midwayAtPump) midway?.call();
        await tester.pump(const Duration(milliseconds: 100));
      }
      return done;
    }

    testWidgets('an at leg opens the span after the first frame, narrows '
        'the streams, exports the observed value and stashes', (tester) async {
      final calls = _FakeCalls(
        json: _capture(event: 'sleuth.issue.slow_startup_ttff.warning'),
      );
      final record = await run(
        tester,
        leg: StartupLeg.at,
        calls: calls,
        frame: _frameAt(1650),
      );
      expect(record.state, 'stashed', reason: record.line);
      expect(calls.log, [
        'begin slow_startup_ttff_at',
        'suspend',
        'flush',
        'end slow_startup_ttff_at',
        'resume',
        'export',
      ]);
      expect(calls.exportObserved, 1650.0);
      expect(calls.exportBand, (min: 1500.0, max: 1800.0));
      expect(calls.exportNotes, contains('$_markerWallUs us'));
      expect(record.observedMs, 1650.0);
      expect(record.detectorMs, 1652.0);
      expect(results.readRecord()!.state, 'stashed');
      expect(results.captureFile('slow_startup_ttff_at').existsSync(), isTrue);
    });

    testWidgets('a below leg ends once the detector judged the frame and '
        'exports a span without records', (tester) async {
      final calls = _FakeCalls(detectorMs: 1002.0, json: _capture());
      final record = await run(
        tester,
        leg: StartupLeg.below,
        calls: calls,
        frame: _frameAt(1000),
      );
      expect(record.state, 'stashed', reason: record.line);
      expect(calls.exportBand, (min: 1.0, max: 1499.0));
    });

    testWidgets('a VM that never connects fails the leg and leaves nothing '
        'open', (tester) async {
      final calls = _FakeCalls(connectAfterPolls: -1);
      final record = await run(
        tester,
        leg: StartupLeg.at,
        calls: calls,
        frame: _frameAt(1650),
      );
      expect(record.verdict, 'FAILED');
      expect(record.reason, 'VM service did not connect within 15 s');
      expect(calls.log, [
        'begin slow_startup_ttff_at',
        'end slow_startup_ttff_at',
      ]);
      expect(results.captureFile('slow_startup_ttff_at').existsSync(), isFalse);
    });

    testWidgets('an observed time outside the band refuses the leg before '
        'the export', (tester) async {
      final calls = _FakeCalls(
        json: _capture(event: 'sleuth.issue.slow_startup_ttff.warning'),
      );
      final record = await run(
        tester,
        leg: StartupLeg.at,
        calls: calls,
        frame: _frameAt(1200),
      );
      expect(record.verdict, 'OUT-OF-BAND');
      expect(record.observedMs, 1200.0);
      expect(calls.log, isNot(contains('export')));
      expect(calls.log.where((l) => l == 'resume'), hasLength(1));
      expect(calls.log.where((l) => l.startsWith('end')), hasLength(1));
    });

    testWidgets('a raster wall time before the marker is unmeasured', (
      tester,
    ) async {
      final calls = _FakeCalls();
      final record = await run(
        tester,
        leg: StartupLeg.at,
        calls: calls,
        frame: _frameAt(-10),
      );
      expect(record.verdict, 'UNMEASURED');
      expect(record.reason, contains('time to first frame'));
    });

    testWidgets('a detector value off the observed one fails the capture '
        'check', (tester) async {
      final calls = _FakeCalls(
        detectorMs: 1760,
        json: _capture(
          event: 'sleuth.issue.slow_startup_ttff.warning',
          value: '1760.0',
        ),
      );
      final record = await run(
        tester,
        leg: StartupLeg.at,
        calls: calls,
        frame: _frameAt(1650),
      );
      expect(record.verdict, 'OUT-OF-BAND');
      expect(record.reason, contains('from the observed'));
      expect(results.captureFile('slow_startup_ttff_at').existsSync(), isFalse);
    });

    testWidgets('an export that composes nothing fails with the reason', (
      tester,
    ) async {
      final calls = _FakeCalls();
      final record = await run(
        tester,
        leg: StartupLeg.at,
        calls: calls,
        frame: _frameAt(1650),
      );
      expect(record.verdict, 'FAILED');
      expect(record.reason, 'capture failed to compose: no scenario span');
    });

    testWidgets('leaving the foreground mid-leg ends it unmeasured', (
      tester,
    ) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final calls = _FakeCalls(evaluated: false);
      final record = await run(
        tester,
        leg: StartupLeg.at,
        calls: calls,
        frame: _frameAt(1650),
        midway: () {
          tester.binding
            ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
            ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        },
      );
      expect(record.verdict, 'UNMEASURED');
      expect(record.reason, contains('left the foreground (hidden)'));
      expect(calls.log.where((l) => l == 'resume'), hasLength(1));
    });

    testWidgets('past the overall limit the leg fails and its late part '
        'exports nothing', (tester) async {
      final calls = _FakeCalls(
        evaluated: false,
        json: _capture(event: 'sleuth.issue.slow_startup_ttff.warning'),
      );
      final record = await run(
        tester,
        leg: StartupLeg.at,
        calls: calls,
        frame: _frameAt(1650),
        overallLimit: const Duration(seconds: 2),
        // The detector judges the frame just after the limit passed, while
        // the timed-out part still waits for it.
        midway: () => calls.evaluated = true,
        midwayAtPump: 25,
      );
      expect(record.verdict, 'FAILED');
      expect(record.reason, contains('did not finish within 2 s'));
      expect(calls.log, isNot(contains('export')));
      expect(results.captureFile('slow_startup_ttff_at').existsSync(), isFalse);
      expect(results.readRecord()!.verdict, 'FAILED');
    });
  });

  group('screen', () {
    late Directory dir;
    late StartupLegResults results;
    String? copied;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('startup_leg_screen');
      results = StartupLegResults(dir);
      copied = null;
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> pumpScreen(
      WidgetTester tester, {
      Size size = const Size(390, 844),
      int currentPid = 7,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SlowStartupCaptureScreen(
            captureModeOverride: true,
            provenanceCheck: _approved,
            results: results,
            currentPid: currentPid,
          ),
        ),
      );
      await tester.pump();
    }

    void stash() {
      results.writeCapture('slow_startup_ttff_at', '{"capture":true}');
      results.writeRecord(
        StartupLegRecord(
          launchId: '5-1',
          scenario: 'slow_startup_ttff_at',
          state: 'stashed',
          observedMs: 1650.4,
          detectorMs: 1652.1,
          delayMs: 1576,
          chars: 16,
          updatedAt: DateTime(2026, 10, 16, 12, 30),
        ),
      );
    }

    testWidgets('with no leg yet it says how to launch one', (tester) async {
      await pumpScreen(tester);
      expect(find.textContaining('No startup leg has run'), findsOneWidget);
      expect(find.text('No leg recorded yet.'), findsOneWidget);
      expect(
        find.textContaining(
          'a warning at 1500 ms to first frame, critical '
          'at 3000 ms',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a stashed leg shows its values and Export copies its '
        'capture', (tester) async {
      stash();
      await pumpScreen(tester);
      final status = find.textContaining('Last leg (at): capture stashed');
      expect(status, findsOneWidget);
      expect(
        tester
            .widget<Semantics>(
              find.ancestor(of: status, matching: find.byType(Semantics)).first,
            )
            .properties
            .liveRegion,
        isTrue,
      );
      expect(find.text('Time to first frame: 1650.4 ms'), findsOneWidget);
      expect(find.text('Detector ttffMs: 1652.1 ms'), findsOneWidget);
      expect(find.text('Band: [1500, 1800] ms'), findsOneWidget);
      await tester.tap(find.text('Export last leg'));
      await tester.pump();
      expect(copied, '{"capture":true}');
      expect(find.textContaining('[at] copied 16 chars'), findsOneWidget);
    });

    testWidgets('a refused leg shows its verdict and Export says why it '
        'has nothing', (tester) async {
      results.writeRecord(
        const StartupLegRecord(
          launchId: '5-1',
          scenario: 'slow_startup_ttff_at',
          state: 'refused',
          verdict: 'OUT-OF-BAND',
          reason: 'time to first frame 1200 ms lies outside the at band',
        ),
      );
      await pumpScreen(tester);
      expect(
        find.textContaining('Last leg (at): OUT-OF-BAND: time to first frame'),
        findsOneWidget,
      );
      await tester.tap(find.text('Export last leg'));
      await tester.pump();
      expect(copied, isNull);
      expect(find.textContaining('Export: no stashed leg'), findsOneWidget);
    });

    testWidgets('a running record from an earlier process reads as FAILED', (
      tester,
    ) async {
      results.writeRecord(
        const StartupLegRecord(
          launchId: '5-1',
          scenario: 'slow_startup_ttff_at',
          state: 'running',
        ),
      );
      await pumpScreen(tester, currentPid: 7);
      expect(
        find.textContaining('FAILED: the app ended during the leg'),
        findsOneWidget,
      );
    });

    testWidgets('an unreadable record says so', (tester) async {
      dir.createSync(recursive: true);
      File('${dir.path}/$kStartupLegRecordFile').writeAsStringSync('{"x":');
      await pumpScreen(tester);
      expect(
        find.textContaining('The last result could not be read'),
        findsOneWidget,
      );
    });

    testWidgets('each leg row copies its launch command', (tester) async {
      await pumpScreen(tester);
      final button = find.text('Copy launch command (critical/at)');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      expect(copied, StartupLeg.criticalAt.launchCommand());
      expect(
        find.textContaining('[critical/at] launch command copied'),
        findsOneWidget,
      );
    });

    for (final size in const [Size(390, 844), Size(360, 800), Size(844, 390)]) {
      for (final textScale in const [1.0, 1.65, 2.0]) {
        testWidgets('at $size and text scale $textScale Export and the '
            'status stay in view, or the body scrolls as one column', (
          tester,
        ) async {
          tester.platformDispatcher.textScaleFactorTestValue = textScale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          stash();
          await pumpScreen(tester, size: size);
          expect(tester.takeException(), isNull);
          final log = tester.getSize(find.byType(ListView)).height;
          final body = size.height - kToolbarHeight - 32;
          final split = body >= CaptureBodyLayout.minSplitHeight(textScale);
          if (size == const Size(390, 844) && textScale == 1.0) {
            expect(split, isTrue);
          }
          if (!split) {
            expect(log, CaptureBodyLayout.compactLogHeight);
            return;
          }
          for (final finder in [
            find.text('Export last leg'),
            find.textContaining('Last leg (at)'),
          ]) {
            expect(tester.getRect(finder).bottom, lessThan(size.height));
          }
          expect(log, greaterThan(48));
        });
      }
    }
  });
}
