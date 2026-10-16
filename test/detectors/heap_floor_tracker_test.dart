import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/heap_floor_tracker.dart';

const _mb = 1000000;

/// Feeds idle full collections at (seconds, megabytes) and returns the
/// verdict after each point, read at the point's own time. A point is one
/// idle `MarkSweep`; [arrivalOffsets] delays individual arrivals.
List<HeapFloorVerdict> _feed(
  HeapFloorTracker tracker,
  List<(double, double)> points, {
  Map<int, double> arrivalOffsets = const {},
}) {
  final out = <HeapFloorVerdict>[];
  for (var i = 0; i < points.length; i++) {
    final (sec, mb) = points[i];
    final eventMs = (sec * 1000).round();
    final arrivalMs = eventMs + ((arrivalOffsets[i] ?? 0) * 1000).round();
    tracker.addCollection(
      gcType: 'MarkSweep',
      reason: 'idle',
      heapUsedBytes: (mb * _mb).round(),
      eventMs: eventMs,
      arrivalMs: arrivalMs,
    );
    out.add(tracker.verdict(arrivalMs));
  }
  return out;
}

HeapFloorTracker _tracker() => HeapFloorTracker(thresholdBytesPerSec: 512000);

List<HeapFloorState> _states(List<HeapFloorVerdict> v) => [
  for (final x in v) x.state,
];

const _g = HeapFloorState.growing;
const _n = HeapFloorState.notGrowing;
const _u = HeapFloorState.unknown;

void main() {
  group('points', () {
    test('an idle MarkSweep is a point', () {
      final t = _tracker();
      _feed(t, [(0, 10)]);
      expect(t.verdict(0).newestBytes, 10 * _mb);
    });

    test('a finalize that closes an idle StartCMark within 100 ms is a '
        'point; 101 ms is not', () {
      final t = _tracker()
        ..addCollection(
          gcType: 'StartCMark',
          reason: 'idle',
          heapUsedBytes: 1,
          eventMs: 1000,
          arrivalMs: 1000,
        )
        ..addCollection(
          gcType: 'MarkSweep',
          reason: 'finalize',
          heapUsedBytes: 5 * _mb,
          eventMs: 1100,
          arrivalMs: 1100,
        );
      expect(t.verdict(1100).newestBytes, 5 * _mb);

      final late = _tracker()
        ..addCollection(
          gcType: 'StartCMark',
          reason: 'idle',
          heapUsedBytes: 1,
          eventMs: 1000,
          arrivalMs: 1000,
        )
        ..addCollection(
          gcType: 'MarkSweep',
          reason: 'finalize',
          heapUsedBytes: 5 * _mb,
          eventMs: 1101,
          arrivalMs: 1101,
        );
      expect(late.verdict(1101).newestBytes, isNull);
    });

    test('an idle MarkCompact is a point (synthetic: iOS never reported '
        'one)', () {
      final t = _tracker()
        ..addCollection(
          gcType: 'MarkCompact',
          reason: 'idle',
          heapUsedBytes: 7 * _mb,
          eventMs: 0,
          arrivalMs: 0,
        );
      expect(t.verdict(0).newestBytes, 7 * _mb);
    });

    test('a non-idle StartCMark cancels the idle opener', () {
      final t = _tracker()
        ..addCollection(
          gcType: 'StartCMark',
          reason: 'idle',
          heapUsedBytes: 1,
          eventMs: 1000,
          arrivalMs: 1000,
        )
        ..addCollection(
          gcType: 'StartCMark',
          reason: 'promotion',
          heapUsedBytes: 1,
          eventMs: 1010,
          arrivalMs: 1010,
        )
        ..addCollection(
          gcType: 'MarkSweep',
          reason: 'finalize',
          heapUsedBytes: 5 * _mb,
          eventMs: 1020,
          arrivalMs: 1020,
        );
      expect(t.verdict(1020).newestBytes, isNull);
    });

    test('a finalize of a non-idle cycle and scavenges are not points', () {
      final t = _tracker()
        ..addCollection(
          gcType: 'Scavenge',
          reason: 'idle',
          heapUsedBytes: 5 * _mb,
          eventMs: 0,
          arrivalMs: 0,
        )
        ..addCollection(
          gcType: 'MarkSweep',
          reason: 'finalize',
          heapUsedBytes: 5 * _mb,
          eventMs: 10,
          arrivalMs: 10,
        );
      expect(t.verdict(10).newestBytes, isNull);
    });
  });

  group('verdict sequences (seconds, MB)', () {
    test('a steady 700 KB/s rise is growing once 3 points span 10 s', () {
      final v = _feed(_tracker(), [(0, 10), (10, 17), (20, 24)]);
      expect(_states(v), [_u, _u, _g]);
      expect(v.last.slopeBytesPerSec, closeTo(700000, 1));
    });

    test('a plateau after growth is not growing, and noise of 1 KB does '
        'not release it', () {
      final v = _feed(_tracker(), [
        (0, 10),
        (10, 30),
        (20, 50),
        (30, 50),
        (40, 50.001024),
      ]);
      expect(_states(v), [_u, _u, _g, _n, _n]);
    });

    test('a drop is unknown; the 10 KB/s regrowth after it is not '
        'growing', () {
      final v = _feed(_tracker(), [
        (0, 10),
        (10, 17),
        (20, 24),
        (30, 14),
        (40, 14.1),
        (50, 14.2),
      ]);
      expect(_states(v).skip(3), [_u, _n, _n]);
    });

    test('a plateau then 300 KB/s regrowth stays not growing', () {
      final v = _feed(_tracker(), [
        (0, 10),
        (10, 30),
        (20, 50),
        (30, 50),
        (40, 53),
        (50, 56),
        (60, 59),
      ]);
      expect(_states(v).skip(3), everyElement(_n));
    });

    test('a second plateau during recovery keeps suppression', () {
      final v = _feed(_tracker(), [
        (0, 10),
        (10, 10),
        (20, 10),
        (30, 30),
        (40, 30),
        (50, 33),
        (60, 36),
      ]);
      expect(_states(v), isNot(contains(_g)));
    });

    test('a plateau inside an incomplete recovery run keeps suppression', () {
      final v = _feed(_tracker(), [
        (0, 10),
        (10, 10),
        (20, 10),
        (24, 20),
        (28, 20),
        (32, 21.2),
        (36, 22.4),
        (40, 23.6),
      ]);
      expect(_states(v), isNot(contains(_g)));
    });

    test('genuine 700 KB/s regrowth after a plateau releases at 50 s', () {
      final v = _feed(_tracker(), [
        (0, 10),
        (10, 30),
        (20, 50),
        (30, 50),
        (40, 57),
        (50, 64),
        (60, 71),
      ]);
      expect(_states(v), [_u, _u, _g, _n, _n, _g, _g]);
      expect(v[5].slopeBytesPerSec, closeTo(700000, 1));
    });

    test('after a flush the floor is unknown (the sample leg decides) '
        'until recovery releases at 89 s', () {
      final v = _feed(_tracker(), [
        (0, 10),
        (10, 17),
        (20, 24),
        (30, 14),
        (59.5, 34.65),
        (89, 55.3),
      ]);
      expect(_states(v), [_u, _u, _g, _u, _u, _g]);
    });

    test('a deceleration that stays above half the threshold keeps the '
        'window slope (documented limitation)', () {
      final v = _feed(_tracker(), [
        (0, 10),
        (10, 30),
        (20, 50),
        (30, 53),
        (40, 56),
        (50, 59),
        (60, 62),
      ]);
      expect(_states(v).skip(2), everyElement(_g));
      expect(v.last.slopeBytesPerSec, greaterThan(512000));
    });

    test('a complete run below the threshold is not growing', () {
      final v = _feed(_tracker(), [(0, 10), (10, 13.5), (20, 17)]);
      expect(_states(v), [_u, _u, _n]);
    });
  });

  group('guards', () {
    test('a batch delivered after a drop is judged by event time', () {
      final v = _feed(
        _tracker(),
        [(0, 10), (10, 17), (20, 24), (30, 14), (35, 17.5), (40, 21)],
        arrivalOffsets: {3: 10, 4: 5.1, 5: 0.2},
      );
      expect(_states(v), [_u, _u, _g, _u, _u, _g]);
    });

    test('points more than 30 s old on arrival are ignored', () {
      final v = _feed(
        _tracker(),
        [(0, 10), (10, 17), (20, 24)],
        arrivalOffsets: {0: 120, 1: 110.1, 2: 100.2},
      );
      expect(_states(v), [_u, _u, _u]);
    });

    test('duplicate and out-of-order points are ignored', () {
      final t = _tracker();
      _feed(t, [(0, 10), (10, 17), (20, 24)]);
      _feed(t, [(20, 99), (15, 99)]);
      expect(t.verdict(20000).state, _g);
      expect(t.verdict(20000).newestBytes, 24 * _mb);
    });

    test('a point within 1 s of the newest replaces it', () {
      final v = _feed(_tracker(), [(0, 10), (10, 17), (20, 30), (20.5, 24)]);
      expect(v.last.state, _g);
      expect(v.last.runPoints, 3);
      expect(v.last.newestBytes, 24 * _mb);
    });

    test('a point within 1 s of the run\'s only point joins the run, and a '
        'pair that close is not a plateau', () {
      final v = _feed(_tracker(), [(0, 10), (0.5, 10), (2, 10)]);
      expect(_states(v), [_u, _u, _n]);
      expect(v[1].runPoints, 2);
    });

    test('a drop counts once; a plateau and a clear do not', () {
      final t = _tracker();
      _feed(t, [(0, 10), (10, 17), (20, 24), (30, 14)]);
      expect(t.dropCount, 1);
      _feed(t, [(40, 14)]);
      t.clear(notBeforeMs: 50000);
      expect(t.dropCount, 1);
    });

    test('a verdict goes unknown 30 s after the newest point', () {
      final t = _tracker();
      _feed(t, [(0, 10), (10, 17), (20, 24)]);
      expect(t.verdict(50000).state, _g);
      expect(t.verdict(50001).state, _u);
    });

    test('an arrival gap over 30 s starts over', () {
      final v = _feed(_tracker(), [(0, 10), (10, 17), (20, 24), (51, 25)]);
      expect(v.last.state, _u);
      expect(v.last.runPoints, 1);
    });

    test('points before the clear boundary are ignored', () {
      final t = _tracker()..clear(notBeforeMs: 15000);
      final v = _feed(t, [(0, 10), (10, 17), (20, 24), (30, 31)]);
      expect(_states(v), [_u, _u, _u, _u]);
      expect(v.last.runPoints, 2);
    });
  });

  group('collections every half second', () {
    // Flat at 20 MB until 20 s, 700 KB/s until 60 s, flat after.
    List<HeapFloorVerdict> dense({required double untilSec}) {
      final points = <(double, double)>[];
      for (var ms = 500; ms <= untilSec * 1000; ms += 500) {
        final sec = ms / 1000;
        final growthSec = (sec.clamp(20, 60) - 20).toDouble();
        points.add((sec, 20 + growthSec * 0.7));
      }
      return _feed(_tracker(), points);
    }

    double? firstSec(
      List<HeapFloorVerdict> v,
      HeapFloorState state,
      double from,
    ) {
      for (final x in v) {
        final sec = x.newestEventMs! / 1000;
        if (sec >= from && x.state == state) return sec;
      }
      return null;
    }

    test('growth that starts after a plateau is found', () {
      final v = dense(untilSec: 60);
      expect(firstSec(v, _n, 0), lessThan(20));
      expect(firstSec(v, _g, 20), lessThanOrEqualTo(35));
      expect(v.last.state, _g);
      expect(v.last.slopeBytesPerSec, closeTo(700000, 35000));
    });

    test('a flat heap after the growth is not growing within 15 s', () {
      final v = dense(untilSec: 100);
      expect(firstSec(v, _n, 60), lessThanOrEqualTo(75));
      expect(firstSec(v, _g, 75), isNull);
    });
  });

  group('pair noise (12 % per pair, points 5 to 18 s apart)', () {
    List<HeapFloorState> run(int rate, Random rng) {
      final points = <(double, double)>[(0, 20)];
      var t = 0.0;
      var mb = 20.0;
      for (var i = 0; i < 12; i++) {
        final dt = 5 + rng.nextDouble() * 13;
        t += dt;
        mb += rate * dt * (1 + (rng.nextDouble() * 0.24 - 0.12)) / _mb;
        points.add((t, mb));
      }
      return _states(_feed(_tracker(), points));
    }

    test('450 KB/s never grows and 600 KB/s always does', () {
      final rng = Random(7);
      for (var i = 0; i < 100; i++) {
        expect(run(450000, rng), isNot(contains(_g)));
        expect(run(600000, rng), contains(_g));
      }
    });
  });

  group('device dumps (iPhone 12, Flutter 3.47.6)', () {
    // First floor-leg verdict per leg, replayed from the dump's own-isolate
    // GC events with arrival equal to event time. The run starts at the
    // leg's scenario begin, as `markScenarioBegin` resets the detector.
    ({double sec, double slope})? firstGrowing(String name) {
      final dump =
          jsonDecode(
                File(
                  'test/detectors/_fixtures/heap_floor/$name.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final replay = dump['replay'] as Map<String, dynamic>;
      final own =
          (dump['provenance'] as Map<String, dynamic>)['appIsolateId']
              as String;
      final beginMs =
          (replay['tapMs'] as int) +
          ((replay['scenarioBeginSec'] as num) * 1000).round();
      final endMs =
          (replay['tapMs'] as int) +
          ((replay['phaseEndSec'] as num) * 1000).round() +
          2000;
      final t = _tracker()..clear(notBeforeMs: beginMs);
      for (final e in (dump['events'] as List).cast<Map<String, dynamic>>()) {
        if ((e['isolate'] as Map?)?['id'] != own) continue;
        final ts = e['timestamp'] as int;
        if (ts > endMs) break;
        final newSpace = e['new'] as Map<String, dynamic>;
        final oldSpace = e['old'] as Map<String, dynamic>;
        t.addCollection(
          gcType: e['gcType'] as String?,
          reason: e['reason'] as String?,
          heapUsedBytes:
              (newSpace['used'] as num).toInt() +
              (oldSpace['used'] as num).toInt(),
          eventMs: ts,
          arrivalMs: ts,
        );
        final v = t.verdict(ts);
        if (v.state == _g) {
          return (sec: (ts - beginMs) / 1000, slope: v.slopeBytesPerSec!);
        }
      }
      return null;
    }

    // Every verdict the dump produces, one per idle-collection point.
    List<HeapFloorState> statesOf(String name) {
      final dump =
          jsonDecode(
                File(
                  'test/detectors/_fixtures/heap_floor/$name.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final own =
          (dump['provenance'] as Map<String, dynamic>)['appIsolateId']
              as String;
      final t = _tracker();
      final states = <HeapFloorState>[];
      for (final e in (dump['events'] as List).cast<Map<String, dynamic>>()) {
        if ((e['isolate'] as Map?)?['id'] != own) continue;
        final ts = e['timestamp'] as int;
        final newSpace = e['new'] as Map<String, dynamic>;
        final oldSpace = e['old'] as Map<String, dynamic>;
        t.addCollection(
          gcType: e['gcType'] as String?,
          reason: e['reason'] as String?,
          heapUsedBytes:
              (newSpace['used'] as num).toInt() +
              (oldSpace['used'] as num).toInt(),
          eventMs: ts,
          arrivalMs: ts,
        );
        final v = t.verdict(ts);
        if (v.newestEventMs == ts) states.add(v.state);
      }
      return states;
    }

    test('legs above the threshold fire within 1 % of the operator rate', () {
      for (final (name, sec, operator) in [
        ('memleg', 28.3, 781312),
        ('at1', 31.7, 572374),
        ('above1', 19.2, 781733),
      ]) {
        final first = firstGrowing(name);
        expect(first, isNotNull, reason: name);
        expect(first!.sec, closeTo(sec, 0.1), reason: name);
        expect(first.slope, closeTo(operator, operator * 0.01), reason: name);
      }
    });

    test('a heavy page pushed and popped every 1.5 s while 600 KB/s is '
        'retained never reads as not growing, and the floor still sees '
        'the growth', () {
      final states = statesOf('route');
      expect(states, isNot(contains(_n)));
      expect(states, contains(_g));
    });

    test('continuous animation keeps idle collections coming', () {
      expect(firstGrowing('busy'), isNotNull);
    });

    test('legs below the threshold and the idle app never grow', () {
      for (final name in ['atleg3', 'below2', 'idle']) {
        expect(firstGrowing(name), isNull, reason: name);
      }
    });
  });
}
