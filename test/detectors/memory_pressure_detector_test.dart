import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/memory_pressure_detector.dart';
import 'package:sleuth/src/models/allocation_entry.dart';
import 'package:sleuth/src/models/heap_sample.dart';
import 'package:sleuth/src/models/performance_issue.dart';

HeapSample _sample({
  int heapUsage = 50000000,
  int heapCapacity = 100000000,
  int externalUsage = 0,
  int? rssBytes,
  required DateTime timestamp,
}) => HeapSample(
  heapUsage: heapUsage,
  heapCapacity: heapCapacity,
  externalUsage: externalUsage,
  timestamp: timestamp,
  rssBytes: rssBytes,
);

void main() {
  group('MemoryPressureDetector', () {
    late MemoryPressureDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0, // Disable warmup for existing tests.
        // Mechanism tests in this group drive 10 cycles in the 10 s window
        // (60 GC/min). Pin the threshold to 30/min so 60 stays "above";
        // the 180/min default has its own tests below.
        gcRateThresholdPerMin: 30,
      );
    });

    // -- Disabled / No-Data --

    test('no issues when disabled', () {
      detector.isEnabled = false;
      for (var i = 0; i < 20; i++) {
        detector.recordGcCycle();
      }
      expect(detector.issues, isEmpty);
    });

    test('no issues with no GC events', () {
      // No recordGcCycle calls → empty sliding window → no gc_pressure.
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      detector.processHeapSample(
        _sample(heapUsage: 50000000, timestamp: fakeNow),
      );
      final gcIssues = detector.issues.where(
        (i) => i.stableId == 'gc_pressure',
      );
      expect(gcIssues, isEmpty);
    });

    // -- GC Pressure --

    test('no issues with low GC frequency', () {
      // 2 GC cycles in the sliding window = (2/10)*60 = 12/min,
      // well below the 30/min threshold.
      detector.recordGcCycle();
      detector.recordGcCycle();
      expect(detector.issues, isEmpty);
    });

    test('flags high GC pressure (>30 GC/min)', () {
      // 10 GC cycles in the 10-second sliding window = 60/min > 30.
      for (var i = 0; i < 10; i++) {
        detector.recordGcCycle();
      }

      expect(detector.issues, isNotEmpty);
      expect(detector.issues.first.title, contains('GC Pressure'));
      expect(
        detector.issues.first.observationSource,
        ObservationSource.vmTimeline,
      );
    });

    test('GC severity uses warning level', () {
      for (var i = 0; i < 10; i++) {
        detector.recordGcCycle();
      }

      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    test('GC issue confidence is likely', () {
      for (var i = 0; i < 10; i++) {
        detector.recordGcCycle();
      }

      expect(detector.issues.first.confidence, IssueConfidence.likely);
    });

    test('GC issue detail contains frequency', () {
      for (var i = 0; i < 10; i++) {
        detector.recordGcCycle();
      }

      expect(detector.issues.first.detail, contains('/min'));
    });

    // -- GC threshold parameterisation (default 180/min + opt-in lower) --

    /// Feeds [count] GC cycles spread evenly across 9 s, all inside the
    /// 10 s window at the last call.
    void feedCycles(
      MemoryPressureDetector d,
      int count, {
      String? Function(int i)? gcType,
    }) {
      final stepMs = 9000 ~/ count;
      for (var i = 0; i < count; i++) {
        fakeNow = fakeNow.add(Duration(milliseconds: stepMs));
        d.recordGcCycle(gcType: gcType?.call(i));
      }
    }

    test('default threshold is 180/min', () {
      expect(MemoryPressureDetector().gcRateThresholdPerMin, 180);
    });

    test('default 180/min threshold suppresses the idle GC band', () {
      // 28 cycles in 10 s = 168/min, inside the band an idle app with
      // VM-service polling produces.
      final defaultDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
      );
      feedCycles(defaultDetector, 28);
      expect(
        defaultDetector.issues.where((i) => i.stableId == 'gc_pressure'),
        isEmpty,
      );
    });

    test('default 180/min threshold is strict-greater (30 cycles silent)', () {
      final defaultDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
      );
      feedCycles(defaultDetector, 30);
      expect(
        defaultDetector.issues.where((i) => i.stableId == 'gc_pressure'),
        isEmpty,
        reason: 'gcPerMinute == 180 must not fire when the threshold is 180.',
      );
    });

    test('default 180/min threshold fires above the idle band', () {
      // 32 cycles in 10 s = 192/min.
      final defaultDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
      );
      feedCycles(defaultDetector, 32);
      final issue = defaultDetector.issues.singleWhere(
        (i) => i.stableId == 'gc_pressure',
      );
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.extraTraceArgs!['observedGcEvents'], '32');
    });

    test('opt-in 30/min threshold fires below the default', () {
      // 6 cycles in 10 s = 36/min — above 30, far below 180. Confirms the
      // knob engages and is not overridden by another gate.
      final legacyDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
        gcRateThresholdPerMin: 30,
      );
      for (var i = 0; i < 6; i++) {
        legacyDetector.recordGcCycle();
      }
      expect(
        legacyDetector.issues.where((i) => i.stableId == 'gc_pressure'),
        hasLength(1),
        reason: 'gcPerMinute == 36 must fire when threshold is 30.',
      );
    });

    // -- GC type split (scavenge vs old generation) --

    test('emission stamps scavengeCount + oldGenCount summing to total', () {
      final defaultDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
      );
      // 32 cycles: 20 Scavenge, 5 MarkSweep, 3 MarkCompact, 2 null,
      // 2 unknown.
      String? type(int i) {
        if (i < 20) return 'Scavenge';
        if (i < 25) return 'MarkSweep';
        if (i < 28) return 'MarkCompact';
        if (i < 30) return null;
        return 'SomethingNew';
      }

      feedCycles(defaultDetector, 32, gcType: type);
      final args = defaultDetector.issues
          .singleWhere((i) => i.stableId == 'gc_pressure')
          .extraTraceArgs!;
      expect(args['observedGcEvents'], '32');
      expect(args['scavengeCount'], '24');
      expect(args['oldGenCount'], '8');
      expect(
        int.parse(args['scavengeCount']!) + int.parse(args['oldGenCount']!),
        int.parse(args['observedGcEvents']!),
      );
    });

    test('null and unknown gcType count as scavenges', () {
      for (var i = 0; i < 10; i++) {
        detector.recordGcCycle(gcType: i.isEven ? null : 'Evacuate');
      }
      final args = detector.issues
          .singleWhere((i) => i.stableId == 'gc_pressure')
          .extraTraceArgs!;
      expect(args['scavengeCount'], '10');
      expect(args['oldGenCount'], '0');
    });

    test('MarkSweep, MarkCompact and StartConcurrentMark count as old-gen', () {
      const types = ['MarkSweep', 'MarkCompact', 'StartConcurrentMark'];
      for (var i = 0; i < 9; i++) {
        detector.recordGcCycle(gcType: types[i % 3]);
      }
      detector.recordGcCycle(gcType: 'Scavenge');
      final issue = detector.issues.singleWhere(
        (i) => i.stableId == 'gc_pressure',
      );
      expect(issue.extraTraceArgs!['oldGenCount'], '9');
      expect(issue.extraTraceArgs!['scavengeCount'], '1');
      expect(issue.detail, contains('1 scavenges, 9 old-generation'));
    });

    test('old cycles age out of the split with the window', () {
      for (var i = 0; i < 6; i++) {
        detector.recordGcCycle(gcType: 'MarkSweep');
      }
      fakeNow = fakeNow.add(const Duration(seconds: 11));
      for (var i = 0; i < 6; i++) {
        detector.recordGcCycle(gcType: 'Scavenge');
      }
      final args = detector.issues
          .singleWhere((i) => i.stableId == 'gc_pressure')
          .extraTraceArgs!;
      expect(args['observedGcEvents'], '6');
      expect(args['oldGenCount'], '0');
    });

    // -- Heap Trend (heap_growing) --

    test('no heap_growing issue with flat heap samples', () {
      // 30 samples at 500ms intervals, all same heap size
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000, timestamp: fakeNow),
        );
      }

      final heapIssues = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, isEmpty);
    });

    test('no heap_growing issue with declining heap', () {
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 80000000 - i * 500000, timestamp: fakeNow),
        );
      }

      final heapIssues = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, isEmpty);
    });

    test('no heap_growing issue when growth < 500KB/s', () {
      // ~400KB/s = 200KB per 500ms interval — below 512000 bytes/sec threshold
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000 + i * 200000, // 200KB per step
            timestamp: fakeNow,
          ),
        );
      }

      final heapIssues = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, isEmpty);
    });

    test('no heap_growing issue when growth < 10 seconds sustained', () {
      // 1MB/s growth but only for 8 seconds (16 samples at 500ms)
      for (var i = 0; i < 16; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000 + i * 512000, // ~1MB/s
            timestamp: fakeNow,
          ),
        );
      }

      final heapIssues = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, isEmpty);
    });

    test('flags heap_growing when growth > 500KB/s sustained 10+ seconds', () {
      // 1MB/s growth for 12 seconds (24 samples at 500ms)
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000 + i * 512000, // ~1MB/s
            timestamp: fakeNow,
          ),
        );
      }

      final heapIssues = detector.issues
          .where((i) => i.stableId == 'heap_growing')
          .toList();
      expect(heapIssues, hasLength(1));
    });

    test('heap_growing stableId, confidence, category correct', () {
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 512000, timestamp: fakeNow),
        );
      }

      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'heap_growing',
      );
      expect(issue.stableId, 'heap_growing');
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.category, IssueCategory.memory);
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.observationSource, ObservationSource.vmTimeline);
    });

    test('heap_growing detail contains rate and duration', () {
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 512000, timestamp: fakeNow),
        );
      }

      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'heap_growing',
      );
      expect(issue.detail, contains('KB/sec'));
      expect(issue.detail, contains('seconds'));
      expect(issue.title, contains('KB/s'));
    });

    test('heap_growing fix hint is actionable', () {
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 512000, timestamp: fakeNow),
        );
      }

      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'heap_growing',
      );
      expect(issue.fixHint, contains('undisposed'));
      expect(issue.fixHint, contains('DevTools'));
    });

    test('no false positive on GC sawtooth pattern', () {
      // Simulate GC sawtooth: rise 1MB, drop 800KB, repeat
      var heap = 50000000;
      for (var i = 0; i < 40; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        if (i % 4 < 3) {
          heap += 350000; // Rise ~700KB/s
        } else {
          heap -= 800000; // GC drops 800KB
        }
        detector.processHeapSample(
          _sample(heapUsage: heap, timestamp: fakeNow),
        );
      }

      final heapIssues = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, isEmpty);
    });

    test('no false positive on step function', () {
      // Sharp rise for 3s, then flat for 12s
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000 + i * 2000000, // 4MB/s rise
            timestamp: fakeNow,
          ),
        );
      }
      // Plateau
      final plateauValue = 50000000 + 6 * 2000000;
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: plateauValue, timestamp: fakeNow),
        );
      }

      final heapIssues = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, isEmpty);
    });

    test('sustained growth resets when slope drops below threshold', () {
      // Phase 1: Grow for 12s (24 samples) — triggers heap_growing
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 600000, timestamp: fakeNow),
        );
      }
      expect(
        detector.issues.where((i) => i.stableId == 'heap_growing'),
        isNotEmpty,
        reason: 'Phase 1: sustained growth should trigger heap_growing',
      );

      final plateau = 50000000 + 24 * 600000;

      // Phase 2: Flatten for 30s (60 samples) — fills entire rolling window
      // with flat data so slope drops to ~0 and _sustainedGrowthStart resets
      for (var i = 0; i < 60; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: plateau, timestamp: fakeNow),
        );
      }
      expect(
        detector.issues.where((i) => i.stableId == 'heap_growing'),
        isEmpty,
        reason: 'Phase 2: flat period should clear heap_growing',
      );

      // Phase 3: Grow again for 8s (16 samples) at high rate.
      // Even if slope exceeds threshold, sustained counter was reset in
      // Phase 2, so this 8s growth period is under the 10s threshold.
      for (var i = 0; i < 16; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: plateau + i * 2000000, timestamp: fakeNow),
        );
      }

      final heapIssues = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(
        heapIssues,
        isEmpty,
        reason: 'Phase 3: <10s sustained growth should not trigger',
      );
    });

    // -- Memory budget (heap_near_capacity) --
    //
    // heap_near_capacity measures process RSS against the opt-in
    // memoryBudgetBytes. It needs: a budget, RSS >= capacityThresholdPercent
    // x budget in 4 of the last 5 samples (RSS-null samples never count),
    // and heap_growing emitted in the same evaluation.
    //
    // [feedGrowth] drives 500 ms samples with the heap growing 600 KB per
    // sample (1.2 MB/s): the slope crosses at sample index 3 and
    // heap_growing first emits at index 23 (10 s sustained).

    const mb = 1024 * 1024;
    const budget = 100 * mb;

    MemoryPressureDetector budgetDetector({
      int? memoryBudgetBytes = budget,
      double capacityThresholdPercent = 0.80,
      int warmupDurationMs = 0,
    }) => MemoryPressureDetector(
      clock: () => fakeNow,
      warmupDurationMs: warmupDurationMs,
      memoryBudgetBytes: memoryBudgetBytes,
      capacityThresholdPercent: capacityThresholdPercent,
    );

    /// Feeds [count] growing samples; returns their timestamps.
    List<DateTime> feedGrowth(
      MemoryPressureDetector d,
      int count, {
      required int? Function(int i) rss,
      int startIndex = 0,
      int heapCapacity = 100000000,
      bool flat = false,
    }) {
      final stamps = <DateTime>[];
      for (var i = startIndex; i < startIndex + count; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        stamps.add(fakeNow);
        d.processHeapSample(
          _sample(
            heapUsage: flat ? 50000000 : 50000000 + i * 600000,
            heapCapacity: heapCapacity,
            rssBytes: rss(i),
            timestamp: fakeNow,
          ),
        );
      }
      return stamps;
    }

    PerformanceIssue? nearCapacity(MemoryPressureDetector d) => d.issues
        .where((i) => i.stableId == 'heap_near_capacity')
        .cast<PerformanceIssue?>()
        .firstWhere((_) => true, orElse: () => null);

    test('never emits without memoryBudgetBytes, even at heap ratio 0.97 '
        'with sustained growth', () {
      // Default detector: no budget. Heap used/capacity at 97 % while the
      // heap grows for 13 s and RSS is large.
      for (var i = 0; i < 26; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        final heap = 50000000 + i * 600000;
        detector.processHeapSample(
          _sample(
            heapUsage: heap,
            heapCapacity: (heap / 0.97).round(),
            rssBytes: 900 * mb,
            timestamp: fakeNow,
          ),
        );
      }
      expect(detector.issues.map((i) => i.stableId), contains('heap_growing'));
      expect(nearCapacity(detector), isNull);
    });

    test('silent with RSS over budget but a flat heap', () {
      final d = budgetDetector();
      feedGrowth(d, 30, rss: (_) => 85 * mb, flat: true);
      expect(nearCapacity(d), isNull);
    });

    test('silent before heap_growing has sustained 10 s (slope crossed '
        'only)', () {
      final d = budgetDetector();
      // 12 samples: slope crossed at index 3, 4 s short of the sustain.
      feedGrowth(d, 12, rss: (_) => 85 * mb);
      expect(d.issues.map((i) => i.stableId), isNot(contains('heap_growing')));
      expect(nearCapacity(d), isNull);
    });

    test('fires critical/likely with sustained heap_growing', () {
      final d = budgetDetector();
      feedGrowth(d, 26, rss: (_) => 85 * mb);
      final issue = nearCapacity(d);
      expect(issue, isNotNull);
      expect(issue!.severity, IssueSeverity.critical);
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.category, IssueCategory.memory);
      expect(issue.observationSource, ObservationSource.vmTimeline);
      expect(issue.title, contains('85%'));
      expect(issue.detail, contains('85.0MB'));
      expect(issue.detail, contains('100.0MB'));
      expect(issue.extraTraceArgs!['observedRssBytes'], '${85 * mb}');
      expect(issue.extraTraceArgs!['memoryBudgetBytes'], '$budget');
      expect(issue.fixHint, contains('DevTools'));
    });

    test('heap_growing is evaluated before the budget rule in the same '
        'tick', () {
      // The first evaluation that emits heap_growing must also emit
      // heap_near_capacity; a reversed order would lag one sample.
      final d = budgetDetector();
      var sawGrowing = false;
      for (var i = 0; i < 26 && !sawGrowing; i++) {
        feedGrowth(d, 1, rss: (_) => 85 * mb, startIndex: i);
        final ids = d.issues.map((it) => it.stableId).toSet();
        if (ids.contains('heap_growing')) {
          sawGrowing = true;
          expect(ids, contains('heap_near_capacity'));
        } else {
          expect(ids, isNot(contains('heap_near_capacity')));
        }
      }
      expect(sawGrowing, isTrue);
    });

    test('identity equals the first crossing across evaluations', () {
      final d = budgetDetector();
      // RSS over from the first sample: the window fills at index 4, which
      // is the first crossing.
      final stamps = feedGrowth(d, 26, rss: (_) => 85 * mb);
      final firstCrossing = stamps[4].microsecondsSinceEpoch;
      final identities = <int?>[nearCapacity(d)!.dedupIdentityMicros];
      for (var k = 0; k < 2; k++) {
        feedGrowth(d, 1, rss: (_) => 85 * mb, startIndex: 26 + k);
        identities.add(nearCapacity(d)!.dedupIdentityMicros);
      }
      // A GC-driven evaluation re-reads the same samples.
      d.recordGcCycle();
      identities.add(nearCapacity(d)!.dedupIdentityMicros);
      expect(identities, everyElement(firstCrossing));
    });

    test('cleared when RSS drops to 70 MB; a re-cross gets a fresh '
        'identity', () {
      final d = budgetDetector();
      feedGrowth(d, 26, rss: (_) => 85 * mb);
      final firstIdentity = nearCapacity(d)!.dedupIdentityMicros;

      // Two samples at 70 MB: 3 of the last 5 over the line.
      feedGrowth(d, 2, rss: (_) => 70 * mb, startIndex: 26);
      expect(nearCapacity(d), isNull);
      expect(
        d.issues.map((i) => i.stableId),
        contains('heap_growing'),
        reason: 'Only the budget window dropped; growth continues.',
      );

      // Back over: the window holds 4 of 5 after four more samples.
      final stamps = feedGrowth(d, 4, rss: (_) => 85 * mb, startIndex: 28);
      final second = nearCapacity(d);
      expect(second, isNotNull);
      expect(second!.dedupIdentityMicros, isNot(firstIdentity));
      expect(second.dedupIdentityMicros, stamps[3].microsecondsSinceEpoch);
    });

    test('3 of 5 samples over the line stays silent', () {
      final d = budgetDetector();
      // Indexes with i % 5 in {0, 2, 4} are over: every 5-sample window
      // holds exactly 3.
      feedGrowth(d, 30, rss: (i) => (i % 5).isEven ? 85 * mb : 70 * mb);
      expect(d.issues.map((i) => i.stableId), contains('heap_growing'));
      expect(nearCapacity(d), isNull);
    });

    test('4 of 5 samples over (one dip) fires', () {
      final d = budgetDetector();
      feedGrowth(d, 26, rss: (i) => i == 24 ? 70 * mb : 85 * mb);
      final issue = nearCapacity(d);
      expect(issue, isNotNull);
      // The newest measured RSS is reported.
      expect(issue!.extraTraceArgs!['observedRssBytes'], '${85 * mb}');
    });

    test('RSS exactly at the line counts (>=)', () {
      final d = budgetDetector();
      feedGrowth(d, 26, rss: (_) => (0.80 * budget).ceil());
      expect(nearCapacity(d), isNotNull);
    });

    test('samples without RSS never count', () {
      final allNull = budgetDetector();
      feedGrowth(allNull, 26, rss: (_) => null);
      expect(allNull.issues.map((i) => i.stableId), contains('heap_growing'));
      expect(nearCapacity(allNull), isNull);

      // Three measured samples over the line plus two without RSS in the
      // last five: 3 hits, below the required 4.
      final mixed = budgetDetector();
      feedGrowth(mixed, 26, rss: (i) => (i == 22 || i == 24) ? null : 85 * mb);
      expect(nearCapacity(mixed), isNull);
    });

    test('capacityThresholdPercent 0.5 is honoured', () {
      final half = budgetDetector(capacityThresholdPercent: 0.5);
      feedGrowth(half, 26, rss: (_) => 55 * mb);
      expect(nearCapacity(half), isNotNull);

      final standard = budgetDetector();
      feedGrowth(standard, 26, rss: (_) => 55 * mb);
      expect(nearCapacity(standard), isNull);
    });

    test('reset and dispose clear the identity', () {
      for (final clear in <void Function(MemoryPressureDetector)>[
        (d) => d.reset(),
        (d) => d.dispose(),
      ]) {
        final d = budgetDetector();
        feedGrowth(d, 26, rss: (_) => 85 * mb);
        final before = nearCapacity(d)!.dedupIdentityMicros;
        clear(d);
        expect(d.issues, isEmpty);
        final stamps = feedGrowth(d, 26, rss: (_) => 85 * mb);
        final after = nearCapacity(d)!.dedupIdentityMicros;
        expect(after, isNot(before));
        expect(after, stamps[4].microsecondsSinceEpoch);
      }
    });

    test('memoryBudgetBytes must be positive when set', () {
      expect(
        () => MemoryPressureDetector(memoryBudgetBytes: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('vmConnected = false immediately clears stale gc_pressure issue', () {
      // Phase 1 / M3 fix: on VM disconnect, the GC sliding window is
      // cleared AND `_evaluate()` is re-run so any `gc_pressure` issue
      // emitted just before the disconnect is removed from the live
      // issues list. Without the re-evaluate, the stale issue would
      // persist in the UI until the next GC event or heap sample
      // arrives, which may be never on a failed-reconnect path.
      for (var i = 0; i < 40; i++) {
        detector.recordGcCycle();
      }
      expect(
        detector.issues.where((i) => i.stableId == 'gc_pressure'),
        hasLength(1),
        reason: '40 cycles in the 10 s window should fire gc_pressure',
      );

      detector.vmConnected = false;

      expect(
        detector.issues.where((i) => i.stableId == 'gc_pressure'),
        isEmpty,
        reason:
            'vmConnected=false must both clear the sliding window '
            'and re-evaluate so the stale gc_pressure issue is removed '
            'immediately (not on the next incoming event).',
      );
    });

    test('post-disconnect GC cycle cannot inherit rate from stale events', () {
      // Complement to the immediate-clear test above: after disconnect,
      // the next GC cycle that comes in on reconnect must start from a
      // fresh 10 s window. A single cycle gives 6/min, well below the
      // 30/min threshold, so gc_pressure must not fire.
      for (var i = 0; i < 40; i++) {
        detector.recordGcCycle();
      }
      detector.vmConnected = false;
      detector.recordGcCycle();

      expect(
        detector.issues.where((i) => i.stableId == 'gc_pressure'),
        isEmpty,
        reason:
            'Post-disconnect cycle must contribute to an empty '
            'window — a single cycle is 6/min, below the threshold.',
      );
    });

    test('zero heapCapacity does not cause division-by-zero crash', () {
      fakeNow = fakeNow.add(const Duration(seconds: 1));

      // Should not throw — guard returns early when heapCapacity <= 0
      expect(
        () => detector.processHeapSample(
          _sample(heapUsage: 50000000, heapCapacity: 0, timestamp: fakeNow),
        ),
        returnsNormally,
      );

      final capIssues = detector.issues.where(
        (i) => i.stableId == 'heap_near_capacity',
      );
      expect(capIssues, isEmpty);
    });

    // -- Rolling Window --

    test('rolling window evicts oldest sample at capacity', () {
      // Fill to capacity (60) + 1 extra
      for (var i = 0; i <= 60; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 1000, timestamp: fakeNow),
        );
      }

      expect(detector.heapSamples, hasLength(60));
      // First sample should be the second one fed (index 1), not index 0
      expect(detector.heapSamples.first.heapUsage, 50000000 + 1 * 1000);
    });

    test('heapSamples getter returns unmodifiable list', () {
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processHeapSample(_sample(timestamp: fakeNow));

      expect(
        () => (detector.heapSamples as List).add(_sample(timestamp: fakeNow)),
        throwsUnsupportedError,
      );
    });

    // -- Coexistence --

    test('GC pressure and heap_growing can coexist', () {
      // Feed enough heap growth for heap_growing
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 600000, timestamp: fakeNow),
        );
      }
      // Feed enough GC cycles for gc_pressure (10 cycles in the 10 s window
      // → 60 GC/min, above the 30/min threshold).
      for (var i = 0; i < 10; i++) {
        detector.recordGcCycle();
      }

      final stableIds = detector.issues.map((i) => i.stableId).toSet();
      expect(stableIds, contains('gc_pressure'));
      expect(stableIds, contains('heap_growing'));
    });

    test('GC pressure and heap_near_capacity can coexist', () {
      final d = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
        memoryBudgetBytes: 100 * 1024 * 1024,
        gcRateThresholdPerMin: 30,
      );
      for (var i = 0; i < 26; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        d.processHeapSample(
          _sample(
            heapUsage: 50000000 + i * 600000,
            rssBytes: 85 * 1024 * 1024,
            timestamp: fakeNow,
          ),
        );
      }
      for (var i = 0; i < 10; i++) {
        d.recordGcCycle();
      }

      final stableIds = d.issues.map((i) => i.stableId).toSet();
      expect(stableIds, contains('gc_pressure'));
      expect(stableIds, contains('heap_near_capacity'));
    });

    // -- Lifecycle --

    test('processHeapSample ignored when disabled', () {
      detector.isEnabled = false;
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processHeapSample(
        _sample(
          heapUsage: 95000000,
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ),
      );

      expect(detector.issues, isEmpty);
      expect(detector.heapSamples, isEmpty);
    });

    test('reset clears heap samples and sustained growth tracking', () {
      // Build up state
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 600000, timestamp: fakeNow),
        );
      }
      expect(detector.issues, isNotEmpty);
      expect(detector.heapSamples, isNotEmpty);

      detector.reset();
      expect(detector.issues, isEmpty);
      expect(detector.heapSamples, isEmpty);

      // Re-feed with no growth — should produce no issues
      for (var i = 0; i < 10; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000, timestamp: fakeNow),
        );
      }
      final heapIssues = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, isEmpty);
    });

    // -- Warmup exclusion --

    test('no heap_growing during warmup period', () {
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 5000,
      );

      // Feed 1MB/s growth for 4 seconds (within warmup)
      for (var i = 0; i < 8; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        warmupDetector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 512000, timestamp: fakeNow),
        );
      }

      final heapIssues = warmupDetector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, isEmpty, reason: 'Should not alert during warmup');
    });

    test('heap_growing fires after warmup ends', () {
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 5000,
      );

      // Feed 1MB/s growth for 20 seconds (warmup expires at 5s,
      // sustained threshold of 10s met at ~15s)
      for (var i = 0; i < 40; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        warmupDetector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 512000, timestamp: fakeNow),
        );
      }

      final heapIssues = warmupDetector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(
        heapIssues,
        hasLength(1),
        reason: 'Should alert after warmup + sustained threshold',
      );
    });

    test('GC pressure still fires during warmup', () {
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 5000,
        gcRateThresholdPerMin: 30,
      );

      // Advance clock and feed GC cycles during warmup period.
      fakeNow = fakeNow.add(const Duration(seconds: 3));
      for (var i = 0; i < 10; i++) {
        warmupDetector.recordGcCycle();
      }

      final gcIssues = warmupDetector.issues.where(
        (i) => i.stableId == 'gc_pressure',
      );
      expect(
        gcIssues,
        hasLength(1),
        reason: 'GC pressure should not be affected by warmup',
      );
    });

    test('heap_near_capacity is suppressed during warmup', () {
      // heap_growing cannot emit during warmup, so the budget rule, which
      // needs it in the same evaluation, stays silent too.
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 30000,
        memoryBudgetBytes: 100 * 1024 * 1024,
      );
      for (var i = 0; i < 26; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        warmupDetector.processHeapSample(
          _sample(
            heapUsage: 50000000 + i * 600000,
            rssBytes: 90 * 1024 * 1024,
            timestamp: fakeNow,
          ),
        );
      }
      expect(
        warmupDetector.issues.where((i) => i.stableId == 'heap_near_capacity'),
        isEmpty,
      );
    });

    test('heap_near_capacity fires after warmup ends', () {
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 5000,
        memoryBudgetBytes: 100 * 1024 * 1024,
      );
      // 5 s of warmup, then 13 s of growth with RSS over the line.
      for (var i = 0; i < 40; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        warmupDetector.processHeapSample(
          _sample(
            heapUsage: 50000000 + i * 600000,
            rssBytes: 90 * 1024 * 1024,
            timestamp: fakeNow,
          ),
        );
      }
      expect(
        warmupDetector.issues.where((i) => i.stableId == 'heap_near_capacity'),
        hasLength(1),
      );
    });

    test('dispose clears heap samples and issues', () {
      // Feed enough GC cycles to fire gc_pressure, plus a heap sample so
      // heapSamples is non-empty.
      for (var i = 0; i < 10; i++) {
        detector.recordGcCycle();
      }
      detector.processHeapSample(
        _sample(heapUsage: 50000000, timestamp: fakeNow),
      );
      expect(detector.issues, isNotEmpty);
      expect(detector.heapSamples, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.heapSamples, isEmpty);
    });

    // -- No heap issues when no samples --

    test('no heap issues when no samples provided', () {
      for (var i = 0; i < 10; i++) {
        detector.recordGcCycle();
      }

      // Only GC issue, no heap trend or capacity.
      final heapIssues = detector.issues.where(
        (i) =>
            i.stableId == 'heap_growing' || i.stableId == 'heap_near_capacity',
      );
      expect(heapIssues, isEmpty);
    });

    // -- Native Memory Growth (native_memory_growing) --

    test('no native_memory_growing when rssBytes is null', () {
      // 24 samples with growing heap but no rssBytes
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 512000, timestamp: fakeNow),
        );
      }

      final nativeIssues = detector.issues.where(
        (i) => i.stableId == 'native_memory_growing',
      );
      expect(nativeIssues, isEmpty);
    });

    test('no native_memory_growing with flat native memory', () {
      // RSS and heap grow together — native gap stays constant
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        final heap = 50000000 + i * 512000;
        detector.processHeapSample(
          _sample(
            heapUsage: heap,
            rssBytes: heap + 100000000, // constant 100MB native
            timestamp: fakeNow,
          ),
        );
      }

      final nativeIssues = detector.issues.where(
        (i) => i.stableId == 'native_memory_growing',
      );
      expect(nativeIssues, isEmpty);
    });

    test('no native_memory_growing when growth < 1MB/s', () {
      // ~800KB/s native growth (below 1MB/s threshold)
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000, // flat heap
            rssBytes: 150000000 + i * 400000, // ~800KB/s native
            timestamp: fakeNow,
          ),
        );
      }

      final nativeIssues = detector.issues.where(
        (i) => i.stableId == 'native_memory_growing',
      );
      expect(nativeIssues, isEmpty);
    });

    test('no native_memory_growing when growth < 10s sustained', () {
      // 2MB/s native growth but only 8 seconds (16 samples)
      for (var i = 0; i < 16; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000, // flat heap
            rssBytes: 150000000 + i * 1048576, // ~2MB/s native
            timestamp: fakeNow,
          ),
        );
      }

      final nativeIssues = detector.issues.where(
        (i) => i.stableId == 'native_memory_growing',
      );
      expect(nativeIssues, isEmpty);
    });

    test(
      'flags native_memory_growing when growth > 1MB/s sustained 10+ seconds',
      () {
        // 2MB/s native growth for 12 seconds (24 samples), flat heap
        for (var i = 0; i < 24; i++) {
          fakeNow = fakeNow.add(const Duration(milliseconds: 500));
          detector.processHeapSample(
            _sample(
              heapUsage: 50000000, // flat heap
              rssBytes: 150000000 + i * 1048576, // ~2MB/s native
              timestamp: fakeNow,
            ),
          );
        }

        final nativeIssues = detector.issues
            .where((i) => i.stableId == 'native_memory_growing')
            .toList();
        expect(nativeIssues, hasLength(1));
      },
    );

    test('native_memory_growing stableId, confidence, category correct', () {
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000,
            rssBytes: 150000000 + i * 1048576,
            timestamp: fakeNow,
          ),
        );
      }

      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'native_memory_growing',
      );
      expect(issue.stableId, 'native_memory_growing');
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.category, IssueCategory.memory);
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.observationSource, ObservationSource.vmTimeline);
    });

    test('native_memory_growing detail contains rate and native estimate', () {
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000,
            rssBytes: 150000000 + i * 1048576,
            timestamp: fakeNow,
          ),
        );
      }

      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'native_memory_growing',
      );
      expect(issue.detail, contains('MB/sec'));
      expect(issue.detail, contains('native estimate'));
      expect(issue.title, contains('MB/s'));
    });

    test('native_memory_growing coexists with heap_growing', () {
      // Both heap and native growing
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000 + i * 600000, // ~1.2MB/s heap growth
            rssBytes: 200000000 + i * 2000000, // ~4MB/s RSS growth
            timestamp: fakeNow,
          ),
        );
      }

      final stableIds = detector.issues.map((i) => i.stableId).toSet();
      expect(stableIds, contains('heap_growing'));
      expect(stableIds, contains('native_memory_growing'));
    });

    test('native_memory_growing suppressed during warmup', () {
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 5000,
      );

      // 2MB/s native growth for 4 seconds (within warmup)
      for (var i = 0; i < 8; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        warmupDetector.processHeapSample(
          _sample(
            heapUsage: 50000000,
            rssBytes: 150000000 + i * 1048576,
            timestamp: fakeNow,
          ),
        );
      }

      final nativeIssues = warmupDetector.issues.where(
        (i) => i.stableId == 'native_memory_growing',
      );
      expect(nativeIssues, isEmpty, reason: 'Should not alert during warmup');
    });

    test('native_memory_growing fires after warmup ends', () {
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 5000,
      );

      // 2MB/s native growth for 20 seconds (warmup expires at 5s,
      // sustained threshold of 10s met at ~15s)
      for (var i = 0; i < 40; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        warmupDetector.processHeapSample(
          _sample(
            heapUsage: 50000000,
            rssBytes: 150000000 + i * 1048576,
            timestamp: fakeNow,
          ),
        );
      }

      final nativeIssues = warmupDetector.issues.where(
        (i) => i.stableId == 'native_memory_growing',
      );
      expect(
        nativeIssues,
        hasLength(1),
        reason: 'Should alert after warmup + sustained threshold',
      );
    });

    test('reset clears native sustained growth tracking', () {
      // Trigger native_memory_growing
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000,
            rssBytes: 150000000 + i * 1048576,
            timestamp: fakeNow,
          ),
        );
      }
      expect(
        detector.issues.where((i) => i.stableId == 'native_memory_growing'),
        isNotEmpty,
      );

      detector.reset();

      // Re-feed with < 10s native growth — should NOT trigger
      for (var i = 0; i < 16; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(
            heapUsage: 50000000,
            rssBytes: 150000000 + i * 1048576,
            timestamp: fakeNow,
          ),
        );
      }

      final nativeIssues = detector.issues.where(
        (i) => i.stableId == 'native_memory_growing',
      );
      expect(
        nativeIssues,
        isEmpty,
        reason: '<10s sustained growth after reset should not trigger',
      );
    });

    // -- Allocation Enrichment --

    test('enrichHeapGrowingIssue adds topAllocators to existing issue', () {
      // Trigger heap_growing first
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 600000, timestamp: fakeNow),
        );
      }

      final heapIssues = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, hasLength(1));
      expect(heapIssues.first.topAllocators, isNull);

      // Enrich with allocation data
      const allocators = [
        AllocationEntry(
          className: 'MyWidget',
          libraryUri: 'package:app/w.dart',
          instancesDelta: 100,
          bytesDelta: 50000,
          percentage: 35.0,
        ),
      ];
      detector.enrichHeapGrowingIssue(allocators);

      final enriched = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(enriched, hasLength(1));
      expect(enriched.first.topAllocators, hasLength(1));
      expect(enriched.first.topAllocators![0].className, 'MyWidget');
    });

    test('enrichHeapGrowingIssue no-ops when heap_growing not present', () {
      // No issues present
      expect(detector.issues, isEmpty);

      const allocators = [
        AllocationEntry(
          className: 'A',
          libraryUri: '',
          instancesDelta: 1,
          bytesDelta: 100,
          percentage: 100.0,
        ),
      ];

      // Should not throw
      detector.enrichHeapGrowingIssue(allocators);
      expect(detector.issues, isEmpty);
    });

    test('enrichment survives _evaluate() rebuild', () {
      // Trigger heap_growing
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 600000, timestamp: fakeNow),
        );
      }

      expect(
        detector.issues.where((i) => i.stableId == 'heap_growing'),
        hasLength(1),
      );

      // Enrich
      const allocators = [
        AllocationEntry(
          className: 'Item',
          libraryUri: 'package:app/item.dart',
          instancesDelta: 200,
          bytesDelta: 80000,
          percentage: 60.0,
        ),
      ];
      detector.enrichHeapGrowingIssue(allocators);

      // Process another sample (triggers _evaluate() → _issues.clear() → rebuild)
      fakeNow = fakeNow.add(const Duration(milliseconds: 500));
      detector.processHeapSample(
        _sample(heapUsage: 50000000 + 24 * 600000 + 600000, timestamp: fakeNow),
      );

      // Enrichment should survive the rebuild
      final heapIssue = detector.issues.firstWhere(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssue.topAllocators, isNotNull);
      expect(heapIssue.topAllocators, hasLength(1));
      expect(heapIssue.topAllocators![0].className, 'Item');
    });

    test('enrichment cleared when heap growth stops', () {
      // Trigger heap_growing
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 600000, timestamp: fakeNow),
        );
      }

      // Enrich
      const allocators = [
        AllocationEntry(
          className: 'Leaky',
          libraryUri: 'package:app/leaky.dart',
          instancesDelta: 50,
          bytesDelta: 40000,
          percentage: 45.0,
        ),
      ];
      detector.enrichHeapGrowingIssue(allocators);

      // Stabilize heap — growth stops, slope drops
      final plateau = 50000000 + 24 * 600000;
      for (var i = 0; i < 60; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: plateau, timestamp: fakeNow),
        );
      }

      // heap_growing should be gone (slope dropped)
      expect(
        detector.issues.where((i) => i.stableId == 'heap_growing'),
        isEmpty,
      );

      // Now trigger growth again — should NOT have stale enrichment
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: plateau + i * 600000, timestamp: fakeNow),
        );
      }

      final regrown = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      if (regrown.isNotEmpty) {
        expect(
          regrown.first.topAllocators,
          isNull,
          reason: 'Stale enrichment from prior episode should be cleared',
        );
      }
    });

    // -----------------------------------------------------------------
    // Custom thresholds
    // -----------------------------------------------------------------

    test('custom growthThresholdBytesPerSec lowers detection sensitivity', () {
      // Lower threshold: 256000 bytes/sec (~256KB/s)
      final custom = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
        growthThresholdBytesPerSec: 256000,
      );

      // ~300KB/s growth for 12 seconds — above 256KB/s but below default 512KB/s
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        custom.processHeapSample(
          _sample(
            heapUsage: 50000000 + i * 150000, // 300KB/s
            timestamp: fakeNow,
          ),
        );
      }

      final heapIssues = custom.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, hasLength(1));
    });

    test('custom capacityThresholdPercent lowers detection sensitivity', () {
      final custom = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
        memoryBudgetBytes: 100 * 1024 * 1024,
        capacityThresholdPercent: 0.60,
      );
      // RSS at 65 % of the budget — above the custom 60 % line, below the
      // default 80 % — while the heap grows for 13 s.
      for (var i = 0; i < 26; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        custom.processHeapSample(
          _sample(
            heapUsage: 50000000 + i * 600000,
            rssBytes: 65 * 1024 * 1024,
            timestamp: fakeNow,
          ),
        );
      }

      final capIssues = custom.issues.where(
        (i) => i.stableId == 'heap_near_capacity',
      );
      expect(capIssues, hasLength(1));
    });

    test('default thresholds do not fire at sub-default levels', () {
      // Verify default 512KB/s threshold does NOT fire at 300KB/s
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(
          _sample(heapUsage: 50000000 + i * 150000, timestamp: fakeNow),
        );
      }

      final heapIssues = detector.issues.where(
        (i) => i.stableId == 'heap_growing',
      );
      expect(heapIssues, isEmpty);
    });
  });
}
