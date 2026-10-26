import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/heap_floor_tracker.dart';
import 'package:sleuth/src/detectors/memory_pressure_detector.dart';
import 'package:sleuth/src/models/heap_sample.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/measurement_matchers.dart';

const _mb = 1000000;

/// A detector on a manual clock, with both heap_growing legs fed by hand.
class _Rig {
  _Rig({bool captureMode = false, int startupWindowMs = 0, int? budget})
    : detector = MemoryPressureDetector(
        clock: () => _now,
        warmupDurationMs: 0,
        captureMode: captureMode,
        floorStartupWindowMs: startupWindowMs,
        memoryBudgetBytes: budget,
      );

  static DateTime _now = DateTime(2026, 10, 14, 9);
  static final DateTime _t0 = DateTime(2026, 10, 14, 9);

  final MemoryPressureDetector detector;

  int _sampleBytes = 50 * _mb;

  void at(double sec) =>
      _now = _t0.add(Duration(microseconds: (sec * 1e6).round()));

  /// One idle full collection at [sec] leaving [mb] in use.
  void idle(double sec, double mb, {bool verified = true}) {
    at(sec);
    detector.recordGcCycle(
      gcType: 'MarkSweep',
      reason: 'idle',
      heapUsedBytes: (mb * _mb).round(),
      eventTimestampMs: _now.millisecondsSinceEpoch,
      pauseAttributable: verified,
    );
  }

  /// Heap samples every 500 ms from [fromSec] to [toSec] rising at
  /// [bytesPerSec]; 4 MB/s keeps the sample leg sustained.
  void samples(
    double fromSec,
    double toSec, {
    int bytesPerSec = 4 * _mb,
    int? rss,
  }) {
    for (var s = fromSec; s <= toSec + 1e-9; s += 0.5) {
      at(s);
      _sampleBytes += bytesPerSec ~/ 2;
      detector.processHeapSample(
        HeapSample(
          heapUsage: _sampleBytes,
          heapCapacity: 1 << 31,
          externalUsage: 0,
          timestamp: _now,
          rssBytes: rss,
        ),
      );
    }
  }

  PerformanceIssue? get heapGrowing =>
      detector.issues.where((i) => i.stableId == 'heap_growing').firstOrNull;

  String? get leg => heapGrowing?.extraTraceArgs?['heapGrowingLeg'];
}

void main() {
  setUp(() => _Rig._now = _Rig._t0);

  group('floor leg', () {
    test('a growing floor publishes confirmed with the floor axis only', () {
      final r = _Rig()
        ..idle(0, 10)
        ..idle(10, 17)
        ..idle(20, 24);

      final issue = r.heapGrowing!;
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.extraTraceArgs, {
        'heapGrowingLeg': 'floor',
        'observedFloorSlopeBytesPerSec': '700000',
        'floorPointCount': '3',
      });
      expectMeasurement(
        issue,
        value: 700000,
        unit: MeasurementUnit.bytesPerSecond,
        warningAt: r.detector.growthThresholdBytesPerSec.toDouble(),
        tolerance: 1e-3,
      );
      expectSeverityMatchesMeasurement(issue, strict: true);
      expect(r.detector.isHeapGrowingActive(), isTrue);
      expect(r.detector.floorVerdict.state, HeapFloorState.growing);
    });

    test('collections from an unverified isolate are ignored', () {
      final r = _Rig()
        ..idle(0, 10, verified: false)
        ..idle(10, 17, verified: false)
        ..idle(20, 24, verified: false);
      expect(r.heapGrowing, isNull);
      expect(r.detector.floorVerdict.state, HeapFloorState.unknown);
    });

    test('collections inside the startup window are ignored', () {
      final r = _Rig(startupWindowMs: 30000)
        ..idle(0, 10)
        ..idle(10, 17)
        ..idle(20, 24)
        ..idle(30, 31);
      expect(r.heapGrowing, isNull);
      r
        ..idle(40, 38)
        ..idle(50, 45);
      expect(r.leg, 'floor');
    });
  });

  group('arbitration with the sample leg', () {
    test('a fresh flat floor suppresses a sustained sample leg and the '
        'capacity warning', () {
      final r = _Rig(budget: 100 * _mb)
        ..idle(0, 30)
        ..idle(5, 30)
        ..samples(5.5, 20, rss: 95 * _mb);

      expect(r.detector.floorVerdict.state, HeapFloorState.notGrowing);
      expect(r.heapGrowing, isNull);
      expect(
        r.detector.issues.where((i) => i.stableId == 'heap_near_capacity'),
        isEmpty,
      );
      expect(r.detector.isHeapGrowingActive(), isFalse);
    });

    test('without floor evidence the sample leg publishes likely', () {
      final r = _Rig()..samples(0, 12);
      expect(r.leg, 'sample');
      expect(r.heapGrowing!.confidence, IssueConfidence.likely);
      expect(
        r.heapGrowing!.extraTraceArgs!.containsKey(
          'observedFloorSlopeBytesPerSec',
        ),
        isFalse,
      );
    });

    test('an early sample warning is withdrawn when the floor shows a flat '
        'heap', () {
      final r = _Rig()..samples(0, 12);
      expect(r.leg, 'sample');
      // Points more than 1 s apart, so they do not coalesce.
      r
        ..idle(12.2, 30)
        ..idle(14, 30);
      expect(r.heapGrowing, isNull);
    });

    test('a stale floor hands back to the sample leg, still confirmed in '
        'the same episode', () {
      final r = _Rig()
        ..idle(0, 10)
        ..idle(10, 17)
        ..idle(20, 24);
      final floorIdentity = r.heapGrowing!.dedupIdentityMicros;
      final episode = r.detector.heapGrowingEpisode;

      r.samples(20.5, 51);
      expect(r.detector.floorVerdict.state, HeapFloorState.unknown);
      expect(r.leg, 'sample');
      expect(r.heapGrowing!.confidence, IssueConfidence.confirmed);
      expect(r.detector.heapGrowingEpisode, episode);
      expect(r.heapGrowing!.dedupIdentityMicros, isNot(floorIdentity));
    });

    test('a drop hands back to the sample leg at likely within the same '
        'episode, and floor regrowth restores confirmed', () {
      final r = _Rig()
        ..idle(0, 10)
        ..samples(0.5, 9.5)
        ..idle(10, 17)
        ..samples(10.5, 19.5)
        ..idle(20, 24);
      expect(r.leg, 'floor');
      expect(r.heapGrowing!.confidence, IssueConfidence.confirmed);
      final episode = r.detector.heapGrowingEpisode;

      r
        ..samples(20.5, 24.5)
        ..idle(25, 14);
      expect(r.detector.floorVerdict.state, HeapFloorState.unknown);
      expect(r.leg, 'sample');
      expect(r.heapGrowing!.confidence, IssueConfidence.likely);
      expect(r.detector.heapGrowingEpisode, episode);

      r
        ..idle(35, 21)
        ..idle(45, 28);
      expect(r.leg, 'floor');
      expect(r.heapGrowing!.confidence, IssueConfidence.confirmed);
      expect(r.detector.heapGrowingEpisode, episode);
    });

    test('a floor plateau ends the episode; the sample leg then starts a '
        'new one at likely', () {
      final r = _Rig()
        ..idle(0, 10)
        ..idle(10, 17)
        ..idle(20, 24);
      final first = r.detector.heapGrowingEpisode;
      r.samples(20.5, 30);
      r.idle(30.2, 24);
      expect(r.heapGrowing, isNull);
      expect(r.detector.isHeapGrowingActive(), isFalse);

      r.samples(30.5, 61);
      expect(r.leg, 'sample');
      expect(r.heapGrowing!.confidence, IssueConfidence.likely);
      expect(r.detector.heapGrowingEpisode, first + 1);
    });

    test('allocators from one episode do not label the next', () {
      final r = _Rig()
        ..idle(0, 10)
        ..idle(10, 17)
        ..idle(20, 24);
      r.detector.enrichHeapGrowingIssue(const []);
      expect(r.heapGrowing!.topAllocators, isNotNull);
      r.idle(30, 24);
      r.samples(30.5, 61);
      expect(r.heapGrowing!.topAllocators, isNull);
    });
  });

  group('capture switches', () {
    test('do nothing outside capture mode', () {
      final r = _Rig()
        ..idle(0, 10)
        ..idle(10, 17)
        ..idle(20, 24);
      r.detector.setLegsEnabledForCapture(floor: false);
      expect(r.leg, 'floor');
    });

    test('the floor leg off leaves the sample leg as the only publisher', () {
      final r = _Rig(captureMode: true);
      r.detector.setLegsEnabledForCapture(floor: false);
      r
        ..idle(0, 30)
        ..idle(5, 30)
        ..samples(5.5, 20);
      expect(r.leg, 'sample');
    });

    test('the sample leg off leaves the floor leg as the only publisher', () {
      final r = _Rig(captureMode: true);
      r.detector.setLegsEnabledForCapture(sample: false);
      r.samples(0, 12);
      expect(r.heapGrowing, isNull);
      r
        ..idle(12.2, 10)
        ..idle(22.2, 17)
        ..idle(32.2, 24);
      expect(r.leg, 'floor');
    });

    test('a leg switch inside one evaluation instant never reuses the '
        'other leg identity', () {
      final r = _Rig(captureMode: true)..samples(0, 12);
      r
        ..idle(12.2, 10)
        ..idle(22.2, 17)
        ..idle(32.2, 24);
      final floorIdentity = r.heapGrowing!.dedupIdentityMicros!;
      // Frozen clock: the sample leg publishes at the same micro.
      r.detector.setLegsEnabledForCapture(floor: false);
      final sample = r.heapGrowing!;
      expect(r.leg, 'sample');
      expect(sample.dedupIdentityMicros, isNot(floorIdentity));
    });
  });

  group('lifecycle', () {
    test('reset clears floor points and the episode', () {
      final r = _Rig()
        ..idle(0, 10)
        ..idle(10, 17)
        ..idle(20, 24);
      r.detector.reset();
      expect(r.detector.floorVerdict.state, HeapFloorState.unknown);
      r.idle(25, 30);
      expect(r.detector.floorVerdict.runPoints, 1);
      expect(r.heapGrowing, isNull);
    });

    test('a VM disconnect and reconnect clear floor points', () {
      final r = _Rig()
        ..idle(0, 10)
        ..idle(10, 17);
      r.detector.vmConnected = false;
      r.detector.vmConnected = true;
      r.idle(20, 24);
      expect(r.detector.floorVerdict.runPoints, 1);
    });
  });
}
