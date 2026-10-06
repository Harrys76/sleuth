// Leg logic of the time-share capture screens: band edges, the decisions
// after a span and after its export, the in-span record count, the
// provenance stamp, and `runTimeShareLeg` driven with scripted detector
// peaks and exports.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

import 'package:example/demos/capture_driver.dart';

const _warning = CaptureBracket(
  stableId: 'rebuild_activity',
  severityLabel: 'warning',
  threshold: 10,
  atTolerance: 0.5,
  aboveCeilingMultiplier: 2.7,
  argKey: 'observedBuildPercent',
);

const _critical = CaptureBracket(
  stableId: 'rebuild_activity',
  severityLabel: 'critical',
  threshold: 30,
  atTolerance: 0.5,
  aboveCeilingMultiplier: 2.7,
  argKey: 'observedBuildPercent',
  minInBandSamples: 2,
);

TimeShareLeg _leg(
  String role, {
  CaptureBracket bracket = _warning,
  double? target,
  double? tierThreshold,
}) => TimeShareLeg(
  detector: 'rebuild',
  bracket: bracket,
  tier: bracket.severityLabel,
  role: role,
  scenario: 'rebuild_activity_$role',
  tierThreshold: tierThreshold ?? bracket.threshold,
  targetPercent: target ?? bracket.threshold * 1.25,
  knobName: 'work',
  calibrationKnob: 4000,
  minKnob: 1,
  maxKnob: 4000000,
  workloadDuration: const Duration(seconds: 6),
);

({double min, double max}) _band(TimeShareLeg leg) => timeShareBand(
  tier: leg.tier,
  role: leg.role,
  threshold: leg.tierThreshold,
  atTolerance: leg.bracket.atTolerance,
  aboveCeilingMultiplier: leg.bracket.aboveCeilingMultiplier,
);

/// A wrapped capture whose scenario span holds one record per entry of
/// [inSpan] (null = a record without the observed arg) and whose
/// [outside] records sit before the span. [rawInSpan] events are added
/// inside the span as given.
String _capture(
  List<Object?> inSpan, {
  List<Object?> outside = const [],
  List<Map<String, Object?>> rawInSpan = const [],
  String event = 'sleuth.issue.rebuild_activity.critical',
  String argKey = 'observedBuildPercent',
  bool dartArguments = false,
}) {
  Map<String, Object?> record(int ts, Object? value) {
    final args = value == null
        ? <String, Object?>{}
        : <String, Object?>{argKey: value};
    return {
      'name': event,
      'ph': 'n',
      'ts': ts,
      'args': dartArguments ? {'Dart Arguments': args} : args,
    };
  }

  return jsonEncode({
    'traceEvents': [
      for (var i = 0; i < outside.length; i++) record(100 + i, outside[i]),
      {
        'name': 'sleuth.scenario.begin',
        'ph': 'n',
        'ts': 1000,
        'args': {'name': 's'},
      },
      for (var i = 0; i < inSpan.length; i++)
        record(2000 + i * 1000, inSpan[i]),
      ...rawInSpan,
      {
        'name': 'sleuth.scenario.end',
        'ph': 'n',
        'ts': 99000,
        'args': {'name': 's'},
      },
    ],
    'sleuthMetadata': <String, Object?>{},
  });
}

const _approved = CaptureProvenance(
  device: 'iPhone 12',
  deviceOsVersion: 'iOS 17.5',
  flutterVersion: '3.47.6',
);

CaptureProvenanceCheck _approvedProvenance() =>
    (provenance: _approved, problem: null);

/// Scripted Sleuth calls: instant waits, a log of calls, and one export
/// result per export call.
class _FakeCalls extends CaptureLegCalls {
  _FakeCalls({this.exports = const [], this.exportFailure});

  final List<String?> exports;
  final String? exportFailure;
  final List<String> calls = [];
  final List<double> exportedObserved = [];
  final List<CaptureProvenance> exportedProvenance = [];
  int _exportIndex = 0;

  @override
  Future<void> suspendStreams() async => calls.add('suspend');

  @override
  Future<void> resumeStreams() async => calls.add('resume');

  @override
  Future<void> flushTimeline() async => calls.add('flush');

  @override
  void markScenarioBegin(String scenario) => calls.add('begin');

  @override
  void markScenarioEnd(String scenario) => calls.add('end');

  @override
  Future<String?> exportCapture({
    required TimeShareLeg leg,
    required ({double min, double max}) band,
    required double observed,
    required CaptureProvenance provenance,
  }) async {
    calls.add('export');
    exportedObserved.add(observed);
    exportedProvenance.add(provenance);
    return exports[_exportIndex++];
  }

  @override
  String? get lastExportFailure => exportFailure;

  @override
  Future<void> wait(Duration duration) async {}
}

/// Runs [leg] with [calls]: the detector reports [peaks] in turn (the
/// pre-pass first, then one per span). Returns the knobs the workload
/// started at.
Future<List<int>> _run(
  TimeShareLeg leg,
  _FakeCalls calls, {
  required List<double> peaks,
  bool Function()? isActive,
  CaptureProvenanceCheck Function() provenance = _approvedProvenance,
}) async {
  final knobs = <int>[];
  var read = 0;
  CaptureDriver.instance.begin('${leg.detector}/${leg.tier}/${leg.role}');
  await runTimeShareLeg(
    leg: leg,
    startWorkload: knobs.add,
    stopWorkload: () {},
    readPeak: () => peaks[read++],
    resetDetector: () {},
    isActive: isActive ?? () => true,
    provenance: provenance,
    calls: calls,
  );
  expect(read, lessThanOrEqualTo(peaks.length));
  return knobs;
}

void main() {
  setUp(CaptureDriver.instance.resetForTest);
  tearDown(CaptureDriver.instance.resetForTest);

  group('band edges after rounding to one decimal', () {
    bool hit(TimeShareLeg leg, double raw) =>
        inLegBand(roundPercent(raw), leg.role, _band(leg));

    test('warning tier (threshold 10)', () {
      final below = _leg('below');
      expect(hit(below, 0.44), isFalse, reason: '0.4 < 0.5');
      expect(hit(below, 0.46), isTrue, reason: '0.5');
      expect(hit(below, 9.94), isTrue, reason: '9.9');
      expect(hit(below, 9.96), isFalse, reason: '10.0 is the threshold');

      final at = _leg('at');
      expect(hit(at, 9.94), isFalse);
      expect(hit(at, 9.96), isTrue, reason: '10.0, closed lower edge');
      expect(hit(at, 15.04), isTrue, reason: '15.0, closed upper edge');
      expect(hit(at, 15.05), isFalse, reason: '15.1');

      final above = _leg('above');
      expect(hit(above, 15.04), isFalse, reason: '15.0 is the at band');
      expect(hit(above, 15.06), isTrue, reason: '15.1');
      expect(hit(above, 27.04), isTrue, reason: '27.0, closed ceiling');
      expect(hit(above, 27.05), isFalse, reason: '27.1');
    });

    test('critical tier (threshold 30)', () {
      final below = _leg('below', bracket: _critical);
      expect(hit(below, 19.44), isFalse, reason: '19.4 < 0.65 × 30');
      expect(hit(below, 19.46), isTrue);
      expect(hit(below, 29.96), isFalse);

      final at = _leg('at', bracket: _critical);
      expect(hit(at, 29.94), isFalse);
      expect(hit(at, 29.96), isTrue);
      expect(hit(at, 45.05), isTrue, reason: '45.0');
      expect(hit(at, 45.06), isFalse, reason: '45.1');

      final above = _leg('above', bracket: _critical);
      expect(hit(above, 45.05), isFalse);
      expect(hit(above, 45.06), isTrue);
      expect(hit(above, 81.04), isTrue);
      expect(hit(above, 81.06), isFalse);
    });

    test('the record band matches the leg band at and above', () {
      for (final bracket in [_warning, _critical]) {
        for (final role in ['at', 'above']) {
          final band = _band(_leg(role, bracket: bracket));
          for (final v in [band.min, band.max]) {
            expect(
              bracket.inRoleBand(v, role),
              inLegBand(v, role, band),
              reason: '${bracket.severityLabel}/$role at $v',
            );
          }
        }
      }
    });
  });

  group('decideAfterPeak', () {
    final leg = _leg('at');
    final band = _band(leg);

    test('in band exports', () {
      expect(
        decideAfterPeak(
          leg: leg,
          band: band,
          knob: 100,
          observed: 12.0,
          attempts: 1,
        ),
        isA<LegExport>(),
      );
    });

    test('a miss retries at the knob scaled by target / observed', () {
      final step = decideAfterPeak(
        leg: leg,
        band: band,
        knob: 10000,
        observed: 8.0,
        attempts: 1,
      );
      expect(step, isA<LegRetry>().having((s) => s.knob, 'knob', 15625));
    });

    test('a zero peak, a binding clamp and the last attempt fail', () {
      LegDecision decide(int knob, double observed, int attempts) =>
          decideAfterPeak(
            leg: leg,
            band: band,
            knob: knob,
            observed: observed,
            attempts: attempts,
          );
      expect(
        decide(100, 0, 1),
        isA<LegFail>().having((s) => s.reason, 'reason', contains('0 %')),
      );
      expect(
        decide(4000000, 5.0, 1),
        isA<LegFail>().having((s) => s.reason, 'reason', contains('clamp')),
      );
      expect(
        decide(100, 8.0, kMaxLegAttempts),
        isA<LegFail>().having(
          (s) => s.reason,
          'reason',
          contains('after 5 attempts'),
        ),
      );
    });
  });

  group('decideAfterExport', () {
    final at = _leg('at', bracket: _critical, target: 36.9);

    LegDecision decide(
      TimeShareLeg leg,
      double observed,
      List<Object?> records, {
      int attempts = 1,
      int knob = 10000,
    }) => decideAfterExport(
      leg: leg,
      knob: knob,
      observed: observed,
      attempts: attempts,
      records: countCaptureRecords(
        _capture(records, event: leg.bracket.eventName),
        bracket: leg.bracket,
        role: leg.role,
      ),
    );

    test('a below leg is done without counting records', () {
      expect(
        decideAfterExport(
          leg: _leg('below'),
          knob: 1,
          observed: 5,
          attempts: 1,
          records: null,
        ),
        isA<LegComplete>(),
      );
    });

    test('enough in-band records complete the leg', () {
      expect(decide(at, 40.0, ['40.0', '33.1']), isA<LegComplete>());
      expect(
        decide(_leg('at'), 12.0, ['12.0']),
        isA<LegComplete>(),
        reason: 'the warning bracket needs one',
      );
    });

    test('one in-band record against two required retries', () {
      expect(
        decide(at, 40.0, ['40.0']),
        isA<LegRetry>()
            .having((s) => s.knob, 'same knob above target', 10000)
            .having((s) => s.reason, 'reason', contains('requires 2')),
      );
      expect(
        decide(at, 31.0, ['31.0']),
        isA<LegRetry>().having(
          (s) => s.knob,
          'rescaled toward the target',
          retryKnob(
            knob: 10000,
            observed: 31.0,
            target: 36.9,
            minKnob: 1,
            maxKnob: 4000000,
          ),
        ),
      );
      expect(
        decide(at, 40.0, ['40.0'], attempts: kMaxLegAttempts),
        isA<LegFail>().having(
          (s) => s.reason,
          'reason',
          allOf(contains('requires 2'), contains('after 5 attempts')),
        ),
      );
    });

    test('records outside the role band do not count', () {
      final above = _leg('above', bracket: _critical, target: 60);
      // 44.9 is critical (> 30) but inside the at band.
      expect(
        decide(above, 70.0, ['70.0', '44.9', '45.0']),
        isA<LegRetry>().having(
          (s) => s.reason,
          'reason',
          contains('1 in-band'),
        ),
      );
      expect(decide(above, 70.0, ['70.0', '45.1']), isA<LegComplete>());
    });

    test('the reduced value must sit in band and near the peak', () {
      expect(
        decide(_leg('above'), 20.0, ['14.0']),
        isA<LegRetry>().having(
          (s) => s.reason,
          'reason',
          contains('outside the above band'),
        ),
      );
      expect(
        decide(at, 44.0, ['31.0', '30.5']),
        isA<LegRetry>().having((s) => s.reason, 'reason', contains('±25 %')),
      );
    });

    test('an unstamped in-span record fails the leg', () {
      expect(
        decide(at, 40.0, ['40.0', null, '35.0']),
        isA<LegFail>().having(
          (s) => s.reason,
          'reason',
          contains('carry no observedBuildPercent'),
        ),
      );
    });
  });

  group('countCaptureRecords', () {
    test('counts only the scenario span, as the audit does', () {
      final count = countCaptureRecords(
        _capture(['40.0', '33.0', '29.0'], outside: ['44.0', '41.0']),
        bracket: _critical,
        role: 'at',
      );
      expect(count.inSpan, 3);
      expect(count.stamped, 3);
      expect(count.inBand, 2, reason: '29.0 is below the at band');
      expect(count.reduced, 40.0);
    });

    test('reads values nested under Dart Arguments', () {
      final count = countCaptureRecords(
        _capture(
          ['12.5', '14.0'],
          dartArguments: true,
          event: _warning.eventName,
        ),
        bracket: _warning,
        role: 'at',
      );
      expect(count.inBand, 2);
      expect(count.reduced, 14.0);
    });

    test('last reduction takes the latest record', () {
      const last = CaptureBracket(
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        threshold: 30,
        atTolerance: 0.5,
        aboveCeilingMultiplier: 2.7,
        argKey: 'observedBuildPercent',
        reduction: 'last',
      );
      expect(
        countCaptureRecords(
          _capture(['40.0', '33.0']),
          bracket: last,
          role: 'at',
        ).reduced,
        33.0,
      );
    });

    test('a non-instant event with the bracket name is not a record', () {
      final count = countCaptureRecords(
        _capture(
          ['33.0'],
          rawInSpan: [
            for (final ph in ['X', 'B', 'E', 'b'])
              {
                'name': _critical.eventName,
                'ph': ph,
                'ts': 50000,
                'args': {'observedBuildPercent': '90.0'},
              },
          ],
        ),
        bracket: _critical,
        role: 'at',
      );
      expect(count.inSpan, 1, reason: 'the schema counts i, I and n only');
      expect(count.reduced, 33.0);
    });

    test('malformed captures throw', () {
      expect(
        () => countCaptureRecords('{}', bracket: _critical, role: 'at'),
        throwsFormatException,
      );
      expect(
        () => countCaptureRecords(
          jsonEncode({'traceEvents': <Object?>[]}),
          bracket: _critical,
          role: 'at',
        ),
        throwsFormatException,
        reason: 'no scenario markers',
      );
    });
  });

  group('checkCaptureRecords', () {
    CaptureRecordCheck check(
      List<Object?> inSpan,
      String role, {
      CaptureBracket bracket = _warning,
      List<Map<String, Object?>> rawInSpan = const [],
      num? observed,
    }) => checkCaptureJson(
      _capture(inSpan, event: bracket.eventName, rawInSpan: rawInSpan),
      bracket: bracket,
      role: role,
      observed: observed,
    );

    test('in-band records pass', () {
      expect(check(['12.0', '14.0'], 'at').isPassed, isTrue);
      expect(check(['12.0'], 'at', observed: 12.5).isPassed, isTrue);
      expect(check(['20.0'], 'above').isPassed, isTrue);
      final result = check(['40.0', '33.1'], 'at', bracket: _critical);
      expect(result.isPassed, isTrue);
      expect(result.problem, isNull);
      expect(result.reason, isNull);
    });

    test('a reduced value outside the role band fails', () {
      final at = check(['12.0', '16.0'], 'at');
      expect(at.problem, CaptureRecordProblem.outOfBand);
      expect(
        at.reason,
        'in-span max observedBuildPercent 16.0 lies outside the at band',
      );
      expect(
        check(['14.0'], 'above').problem,
        CaptureRecordProblem.outOfBand,
        reason: '14.0 is in the at band, not above it',
      );
      expect(
        check(['28.0'], 'above').problem,
        CaptureRecordProblem.outOfBand,
        reason: 'past the 27.0 ceiling',
      );
    });

    test('an unstamped in-span record fails', () {
      final result = check(['12.0', null], 'at');
      expect(result.problem, CaptureRecordProblem.unstamped);
      expect(
        result.reason,
        '1 of 2 in-span sleuth.issue.rebuild_activity.warning records carry '
        'no observedBuildPercent',
      );
    });

    test('a non-instant event neither counts nor needs a stamp', () {
      final unstampedSlice = {
        'name': _warning.eventName,
        'ph': 'X',
        'ts': 50000,
        'dur': 10,
        'args': <String, Object?>{},
      };
      expect(
        check(['12.0'], 'at', rawInSpan: [unstampedSlice]).isPassed,
        isTrue,
      );
      expect(
        check(const [], 'at', rawInSpan: [unstampedSlice]).problem,
        CaptureRecordProblem.noRecords,
      );
      expect(
        check(const [], 'below', rawInSpan: [unstampedSlice]).isPassed,
        isTrue,
        reason: 'a below span may hold a non-instant event of that name',
      );
    });

    test('a below span passes only without records', () {
      expect(check(const [], 'below').isPassed, isTrue);
      final result = check(['5.0'], 'below');
      expect(result.problem, CaptureRecordProblem.belowHasRecords);
      expect(result.reason, contains('a below span must hold none'));
    });

    test('an at or above span without records fails', () {
      expect(check(const [], 'at').problem, CaptureRecordProblem.noRecords);
      expect(
        check(const [], 'above').reason,
        'no in-span sleuth.issue.rebuild_activity.warning',
      );
    });

    test('the reduced value must lie near the observed magnitude', () {
      final result = check(['14.0'], 'at', observed: 10);
      expect(result.problem, CaptureRecordProblem.offObserved);
      expect(result.reason, contains('±25 % from the observed 10'));
      expect(check(['12.5'], 'at', observed: 10).isPassed, isTrue);
    });

    test('too few in-band records fail', () {
      expect(
        check(['40.0'], 'at', bracket: _critical).problem,
        CaptureRecordProblem.tooFewInBand,
      );
    });

    test('an unreadable capture fails without throwing', () {
      final result = checkCaptureJson('{}', bracket: _warning, role: 'at');
      expect(result.problem, CaptureRecordProblem.unreadable);
      expect(result.reason, contains('traceEvents'));
    });

    test('decideAfterExport keeps its decisions on the shared check', () {
      final at = _leg('at');
      LegDecision decide(List<Object?> records, {double observed = 12.0}) =>
          decideAfterExport(
            leg: at,
            knob: 100,
            observed: observed,
            attempts: 1,
            records: countCaptureRecords(
              _capture(records, event: _warning.eventName),
              bracket: _warning,
              role: 'at',
            ),
          );
      expect(decide(['12.0']), isA<LegComplete>());
      expect(decide(['12.0', null]), isA<LegFail>());
      expect(decide(['16.0']), isA<LegRetry>());
      expect(decide(const []), isA<LegRetry>());
      expect(
        decide(['14.0'], observed: 10.0),
        isA<LegRetry>().having(
          (s) => s.reason,
          'reason',
          contains('from the observed 10.0 %'),
        ),
      );
    });
  });

  group('leg refusals', () {
    const stream = CaptureBracket(
      stableId: 'stream_resource_growth',
      severityLabel: 'warning',
      threshold: 50,
      atTolerance: 0.6,
      aboveCeilingMultiplier: 3.0,
      argKey: 'topGrowthDelta',
    );

    test('bands read as the audit draws them', () {
      expect(stream.bandText('below'), '(0, 50)');
      expect(stream.bandText('at'), '[50, 80]');
      expect(stream.bandText('above'), '(80, 150]');
      expect(_warning.bandText('above'), '(15, 27]');
    });

    test('a missing or non-positive measurement is unmeasured', () {
      for (final value in <num?>[null, 0, -3]) {
        final refusal = measurementRefusal(
          value,
          role: 'below',
          bracket: stream,
          what: 'top-class growth',
        );
        expect(refusal?.verdict, 'UNMEASURED', reason: '$value');
      }
      expect(
        measurementRefusal(
          null,
          role: 'at',
          bracket: stream,
          what: 'peak',
        )?.reason,
        'no peak was measured',
      );
    });

    test('a measurement outside its role band is out of band', () {
      LegRefusal? refuse(num value, String role) => measurementRefusal(
        value,
        role: role,
        bracket: stream,
        what: 'top-class growth',
        unit: 'instances',
      );
      expect(refuse(1, 'below'), isNull);
      expect(refuse(49, 'below'), isNull);
      expect(refuse(50, 'at'), isNull);
      expect(refuse(80, 'at'), isNull);
      expect(refuse(81, 'above'), isNull);
      expect(refuse(150, 'above'), isNull);
      final below = refuse(50, 'below')!;
      expect(below.verdict, 'OUT-OF-BAND');
      expect(
        below.reason,
        'top-class growth 50 instances lies outside the below band '
        '(0, 50) instances',
      );
      expect(refuse(81, 'at')?.verdict, 'OUT-OF-BAND');
      expect(refuse(80, 'above')?.verdict, 'OUT-OF-BAND');
      expect(refuse(151, 'above')?.verdict, 'OUT-OF-BAND');
    });

    test('a failed record check is out of band and names the band', () {
      final failed = checkCaptureJson(
        _capture(['90'], event: stream.eventName, argKey: stream.argKey),
        bracket: stream,
        role: 'at',
      );
      final refusal = recordRefusal(failed, role: 'at', bracket: stream)!;
      expect(refusal.verdict, 'OUT-OF-BAND');
      expect(refusal.reason, endsWith('outside the at band [50, 80]'));
      expect(
        recordRefusal(
          const CaptureRecordCheck.passed(),
          role: 'at',
          bracket: stream,
        ),
        isNull,
      );
    });
  });

  group('runTimeShareLeg', () {
    test('retries a missed band until the rounded peak lands in it', () async {
      final calls = _FakeCalls(
        exports: [
          _capture(['15.0', '11.2'], event: _warning.eventName),
        ],
      );
      final knobs = await _run(
        _leg('at'),
        calls,
        // Pre-pass 5 % at work 4000, then three spans.
        peaks: [5.0, 8.0, 16.0, 14.96],
      );
      final driver = CaptureDriver.instance;
      expect(driver.state, CaptureLegState.done);
      expect(driver.observed, 15.0);
      expect(driver.attempts, 3);
      expect(knobs, [4000, 10000, 15625, 12207]);
      expect(calls.exportedObserved, [15.0]);
      expect(calls.exportedProvenance.single, same(_approved));
      expect(calls.calls.where((c) => c == 'begin').length, 3);
      expect(calls.calls.where((c) => c == 'end').length, 3);
      expect(calls.calls.last, 'resume');
    });

    test('a short in-band count runs another span and keeps the latest '
        'export', () async {
      final first = _capture(['40.0']);
      final latest = _capture(['33.0', '31.2', '30.0']);
      final calls = _FakeCalls(exports: [first, latest]);
      final knobs = await _run(
        _leg('at', bracket: _critical, target: 36.9),
        calls,
        peaks: [10.0, 40.0, 33.0],
      );
      final driver = CaptureDriver.instance;
      expect(driver.state, CaptureLegState.done);
      expect(driver.json, latest);
      expect(driver.observed, 33.0);
      expect(driver.attempts, 2);
      expect(knobs, [4000, 14760, 14760], reason: 'peak above target: same');
      expect(driver.log, contains(contains('requires 2')));
    });

    test('a leg that never reaches the required count fails', () async {
      final calls = _FakeCalls(
        exports: List.filled(kMaxLegAttempts, _capture(['40.0'])),
      );
      await _run(
        _leg('at', bracket: _critical, target: 36.9),
        calls,
        peaks: [10.0, ...List.filled(kMaxLegAttempts, 40.0)],
      );
      final driver = CaptureDriver.instance;
      expect(driver.state, CaptureLegState.failed);
      expect(driver.json, isNull);
      expect(driver.attempts, kMaxLegAttempts);
      expect(driver.log.last, contains('the bracket requires 2'));
    });

    test('a below leg completes on its export without counting', () async {
      final calls = _FakeCalls(exports: ['{}']);
      await _run(_leg('below', target: 5), calls, peaks: [5.0, 4.0]);
      expect(CaptureDriver.instance.state, CaptureLegState.done);
      expect(CaptureDriver.instance.json, '{}');
    });

    test('a refused export fails the leg with its reason', () async {
      final calls = _FakeCalls(
        exports: [null],
        exportFailure: 'role="below" must contain ZERO events',
      );
      await _run(_leg('below', target: 5), calls, peaks: [5.0, 4.0]);
      final driver = CaptureDriver.instance;
      expect(driver.state, CaptureLegState.failed);
      expect(driver.log.last, contains('export refused: role="below"'));
    });

    test('an unknown provenance refuses the leg before any work', () async {
      final calls = _FakeCalls();
      final knobs = await _run(
        _leg('at'),
        calls,
        peaks: const [],
        provenance: () => (provenance: null, problem: 'device model unknown'),
      );
      expect(CaptureDriver.instance.state, CaptureLegState.failed);
      expect(
        CaptureDriver.instance.log.last,
        contains('capture provenance: device model unknown'),
      );
      expect(knobs, isEmpty);
      expect(calls.calls, isEmpty);
    });

    test('a live threshold that differs from the bracket is refused', () async {
      final calls = _FakeCalls();
      await _run(_leg('at', tierThreshold: 12), calls, peaks: const []);
      expect(CaptureDriver.instance.state, CaptureLegState.failed);
      expect(CaptureDriver.instance.log.last, contains('differs from'));
      expect(calls.calls, isEmpty);
    });

    test('a screen that is not in front at the start is refused', () async {
      final calls = _FakeCalls();
      final knobs = await _run(
        _leg('at'),
        calls,
        peaks: const [],
        isActive: () => false,
      );
      expect(CaptureDriver.instance.state, CaptureLegState.failed);
      expect(CaptureDriver.instance.log.last, contains('not in front'));
      expect(knobs, isEmpty);
    });

    test('a screen covered during the scenario fails the leg and exports '
        'nothing', () async {
      final calls = _FakeCalls(
        exports: [
          _capture(['12.0']),
        ],
      );
      var scenarioRunning = false;
      var checksInScenario = 0;
      final knobs = <int>[];
      var read = 0;
      final peaks = [5.0, 12.0];
      CaptureDriver.instance.begin('rebuild/warning/at');
      await runTimeShareLeg(
        leg: _leg('at'),
        startWorkload: (knob) {
          knobs.add(knob);
          scenarioRunning = calls.calls.contains('begin');
        },
        stopWorkload: () {},
        readPeak: () => peaks[read++],
        resetDetector: () {},
        // Covered one second into the workload.
        isActive: () => !scenarioRunning || ++checksInScenario < 10,
        provenance: _approvedProvenance,
        calls: calls,
      );
      final driver = CaptureDriver.instance;
      expect(driver.state, CaptureLegState.failed);
      expect(driver.log.last, contains('not in front during the scenario'));
      expect(calls.calls, isNot(contains('export')));
      expect(
        calls.calls.where((c) => c == 'end').length,
        1,
        reason: 'the open scenario is closed on cleanup',
      );
      expect(read, 1, reason: 'only the pre-pass peak was read');
    });
  });

  group('provenance', () {
    CaptureProvenanceCheck check({
      String? device = 'iPhone 12',
      String os = 'ios',
      String osVersion = 'Version 17.5 (Build 21F79)',
      String? flutter = '3.47.6',
    }) => checkCaptureProvenance(
      device: device,
      operatingSystem: os,
      operatingSystemVersion: osVersion,
      flutterVersion: flutter,
    );

    test('approved values are stamped as read', () {
      final result = check();
      expect(result.problem, isNull);
      final stamp = result.provenance!;
      expect(stamp.device, 'iPhone 12');
      expect(stamp.deviceOsVersion, 'iOS 17.5');
      expect(stamp.flutterVersion, '3.47.6');
      expect(stamp.captureCommand, contains('--profile'));
      expect(
        stamp.captureCommand,
        contains('--dart-define=$kCaptureDeviceDefine="iPhone 12"'),
      );
      expect(check(flutter: '3.41.4').problem, isNull);
    });

    test('the values match what the capture schema approves', () {
      final stamp = check().provenance!;
      expect(
        ProfileCaptureSchema.approvedDevicePairs[stamp.device],
        contains(stamp.deviceOsVersion),
      );
      expect(ProfileCaptureSchema.approvedFlutterMajorMinors, contains('3.47'));
    });

    test('unknown or unapproved values are refused with a reason', () {
      expect(check(device: null).problem, contains(kCaptureDeviceDefine));
      expect(check(device: '').problem, contains('device model unknown'));
      expect(
        check(device: 'Pixel 8').problem,
        contains('"Pixel 8" is not an approved reference device'),
      );
      expect(
        check(osVersion: 'Version 17.5.1 (Build 21F90)').problem,
        contains('iOS 17.5.1 is not approved for "iPhone 12"'),
      );
      expect(
        check(os: 'android', osVersion: 'Linux 5.10').problem,
        contains('OS version unknown'),
      );
      expect(check(flutter: null).problem, contains('Flutter version unknown'));
      expect(
        check(flutter: '3.44.0').problem,
        contains('Flutter 3.44.0 is not an approved capture SDK'),
      );
      expect(check(flutter: 'main').problem, contains('not an approved'));
      final both = check(device: null, flutter: null);
      expect(both.provenance, isNull);
      expect(both.problem, allOf(contains('device'), contains('Flutter')));
    });

    test('iOS version strings parse to the schema form', () {
      expect(
        captureOsVersion(
          operatingSystem: 'ios',
          operatingSystemVersion: 'Version 17.5 (Build 21F79)',
        ),
        'iOS 17.5',
      );
      expect(
        captureOsVersion(operatingSystem: 'ios', operatingSystemVersion: ''),
        isNull,
      );
      expect(
        captureOsVersion(
          operatingSystem: 'macos',
          operatingSystemVersion: 'Version 14.6 (Build 23G80)',
        ),
        isNull,
      );
    });

    test('a test build without the device define cannot stamp', () {
      expect(currentCaptureProvenance().provenance, isNull);
      expect(
        currentCaptureProvenance().problem,
        contains(kCaptureDeviceDefine),
      );
    });

    test('a leg is refused with the problem text, not a placeholder', () {
      expect(provenanceRefusal('at', check: _approvedProvenance), isNull);
      final refusal = provenanceRefusal('below')!;
      expect(refusal, startsWith('[below] ABORT: capture provenance: '));
      expect(refusal, contains(currentCaptureProvenance().problem));
      expect(refusal, contains(kCaptureDeviceDefine));
    });

    test('an export without provenance throws the problem text', () {
      expect(requireCaptureProvenance(check: _approvedProvenance), _approved);
      expect(
        requireCaptureProvenance,
        throwsA(
          isA<CaptureProvenanceUnavailable>().having(
            (e) => e.toString(),
            'text',
            allOf(
              startsWith('capture provenance: '),
              contains(kCaptureDeviceDefine),
            ),
          ),
        ),
      );
    });
  });

  group('CaptureBracket.fromMetadata', () {
    test('reads the rebuild detector brackets', () {
      final metadata = RebuildDetector().validationMetadata;
      final warning = CaptureBracket.fromMetadata(
        metadata,
        stableId: 'rebuild_activity',
        severityLabel: 'warning',
      )!;
      expect(warning.threshold, 10);
      expect(warning.minInBandSamples, isNull);
      expect(warning.requiredInBand, 1);
      expect(warning.argKey, 'observedBuildPercent');

      final critical = CaptureBracket.fromMetadata(
        metadata,
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
      )!;
      expect(critical.threshold, 30);
      expect(critical.minInBandSamples, 2);
      expect(critical.requiredInBand, 2);
      expect(critical.atUpper, 45);
      expect(critical.aboveCeiling, closeTo(81, 1e-9));

      expect(
        CaptureBracket.fromMetadata(
          metadata,
          stableId: 'excessive_repaint',
          severityLabel: 'warning',
        ),
        isNull,
      );
    });

    test('reads the brackets the event-driven capture screens judge', () {
      final stream = StreamResourceDetector(
        vmClientProvider: () => null,
        heapGrowingStateProvider: () => false,
      );
      final network = NetworkMonitorDetector();
      addTearDown(stream.dispose);
      addTearDown(network.dispose);

      CaptureBracket read(
        DetectorMetadataProvider d,
        String stableId, [
        String? label,
      ]) => CaptureBracket.fromMetadata(
        d.validationMetadata,
        stableId: stableId,
        severityLabel: label ?? 'warning',
      )!;

      final growth = read(stream, 'stream_resource_growth');
      expect(growth.argKey, 'topGrowthDelta');
      expect(growth.bandText('at'), '[50, 80]');
      expect(growth.bandText('above'), '(80, 150]');

      final slow = read(network, 'slow_request');
      expect(slow.bandText('at'), '[1000, 1100]');
      expect(slow.observedAxisTolerance, 0.10);
      expect(
        read(network, 'slow_request', 'critical').bandText('at'),
        '[3000, 4200]',
      );
      expect(read(network, 'large_response').threshold, 1048576);
      expect(read(network, 'request_frequency').bandText('at'), '[30, 45]');
    });
  });
}
