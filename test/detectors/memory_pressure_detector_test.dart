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
}) =>
    HeapSample(
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
        // Existing tests in this group exercise the GC pressure mechanism
        // around 60 GC/min (10 cycles in the 10 s window). Pin the
        // threshold to 30/min — the pre-v0.26.0 default — so the
        // 60-vs-threshold relationship remains "above" and these
        // mechanism-focused assertions continue to hold. The new 60/min
        // default lives in its own group below.
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
      detector.processHeapSample(_sample(
        heapUsage: 50000000,
        timestamp: fakeNow,
      ));
      final gcIssues =
          detector.issues.where((i) => i.stableId == 'gc_pressure');
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
      expect(detector.issues.first.observationSource,
          ObservationSource.vmTimeline);
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

    // -- GC threshold parameterisation (default 60/min + opt-in 30/min) --

    test('default 60/min threshold suppresses normal-cadence GC', () {
      // 10 cycles in 10 s = exactly 60/min. Strict-greater-than the
      // default threshold means this MUST NOT fire.
      final defaultDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
      );
      for (var i = 0; i < 10; i++) {
        defaultDetector.recordGcCycle();
      }
      expect(
        defaultDetector.issues.where((i) => i.stableId == 'gc_pressure'),
        isEmpty,
        reason: 'gcPerMinute == 60 must not fire when threshold is 60 '
            '(strictly-greater-than gate). Young-gen scavenges at this '
            'cadence are normal Dart UI behaviour.',
      );
    });

    test('default 60/min threshold fires above baseline', () {
      // 11 cycles in 10 s = 66/min, above the default 60/min threshold.
      final defaultDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
      );
      for (var i = 0; i < 11; i++) {
        defaultDetector.recordGcCycle();
      }
      expect(
        defaultDetector.issues.where((i) => i.stableId == 'gc_pressure'),
        hasLength(1),
        reason: 'gcPerMinute > 60 must fire at the new default.',
      );
    });

    test('opt-in 30/min threshold restores pre-v0.26.0 sensitivity', () {
      // 6 cycles in 10 s = 36/min — above 30, below 60. Confirms the
      // escape valve for users on the older sensitivity actually engages
      // and is not silently overridden by another gate.
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

    // -- Heap Trend (heap_growing) --

    test('no heap_growing issue with flat heap samples', () {
      // 30 samples at 500ms intervals, all same heap size
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000,
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing');
      expect(heapIssues, isEmpty);
    });

    test('no heap_growing issue with declining heap', () {
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 80000000 - i * 500000,
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing');
      expect(heapIssues, isEmpty);
    });

    test('no heap_growing issue when growth < 500KB/s', () {
      // ~400KB/s = 200KB per 500ms interval — below 512000 bytes/sec threshold
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 200000, // 200KB per step
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing');
      expect(heapIssues, isEmpty);
    });

    test('no heap_growing issue when growth < 10 seconds sustained', () {
      // 1MB/s growth but only for 8 seconds (16 samples at 500ms)
      for (var i = 0; i < 16; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 512000, // ~1MB/s
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing');
      expect(heapIssues, isEmpty);
    });

    test('flags heap_growing when growth > 500KB/s sustained 10+ seconds', () {
      // 1MB/s growth for 12 seconds (24 samples at 500ms)
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 512000, // ~1MB/s
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing').toList();
      expect(heapIssues, hasLength(1));
    });

    test('heap_growing stableId, confidence, category correct', () {
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 512000,
          timestamp: fakeNow,
        ));
      }

      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'heap_growing');
      expect(issue.stableId, 'heap_growing');
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.category, IssueCategory.memory);
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.observationSource, ObservationSource.vmTimeline);
    });

    test('heap_growing detail contains rate and duration', () {
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 512000,
          timestamp: fakeNow,
        ));
      }

      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'heap_growing');
      expect(issue.detail, contains('KB/sec'));
      expect(issue.detail, contains('seconds'));
      expect(issue.title, contains('KB/s'));
    });

    test('heap_growing fix hint is actionable', () {
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 512000,
          timestamp: fakeNow,
        ));
      }

      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'heap_growing');
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
        detector.processHeapSample(_sample(
          heapUsage: heap,
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing');
      expect(heapIssues, isEmpty);
    });

    test('no false positive on step function', () {
      // Sharp rise for 3s, then flat for 12s
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 2000000, // 4MB/s rise
          timestamp: fakeNow,
        ));
      }
      // Plateau
      final plateauValue = 50000000 + 6 * 2000000;
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: plateauValue,
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing');
      expect(heapIssues, isEmpty);
    });

    test('sustained growth resets when slope drops below threshold', () {
      // Phase 1: Grow for 12s (24 samples) — triggers heap_growing
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 600000,
          timestamp: fakeNow,
        ));
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
        detector.processHeapSample(_sample(
          heapUsage: plateau,
          timestamp: fakeNow,
        ));
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
        detector.processHeapSample(_sample(
          heapUsage: plateau + i * 2000000,
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing');
      expect(heapIssues, isEmpty,
          reason: 'Phase 3: <10s sustained growth should not trigger');
    });

    // -- Heap Capacity (heap_near_capacity) --
    //
    // Under the Phase 1 fix, heap_near_capacity requires three guards:
    //   1. Warmup elapsed (set to 0 ms in test setUp so this is trivially met).
    //   2. At least 5 consecutive heap samples with ratio > capacityThreshold.
    //   3. `_sustainedGrowthStart != null` — i.e. `_evaluateHeapTrend` must
    //      have observed slope > growthThresholdBytesPerSec on the current
    //      window, so the issue only fires when the heap is still actively
    //      growing (not on a steady-state committed arena).
    //
    // Tests that want the issue to fire feed 6 samples on a 500 ms cadence
    // with a ~1.2 MB/s slope, each ending at the target percentage.

    test('no heap_near_capacity when usage < 80%', () {
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processHeapSample(_sample(
        heapUsage: 70000000,
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));

      final capIssues =
          detector.issues.where((i) => i.stableId == 'heap_near_capacity');
      expect(capIssues, isEmpty);
    });

    test('flags heap_near_capacity when usage > 80% and heap growing', () {
      // 6 samples at 500 ms intervals, all > 80 %, growing 600 KB/step
      // (~1.2 MB/s) — satisfies the 5-consecutive counter AND sets
      // `_sustainedGrowthStart` on the slope check at sample 4.
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 82000000 + i * 600000, // 82M → 85M
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final capIssues = detector.issues
          .where((i) => i.stableId == 'heap_near_capacity')
          .toList();
      expect(capIssues, hasLength(1));
    });

    test('heap_near_capacity severity is critical', () {
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 87000000 + i * 600000, // 87M → 90M
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'heap_near_capacity');
      expect(issue.severity, IssueSeverity.critical);
    });

    test('heap_near_capacity confidence is confirmed', () {
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 87000000 + i * 600000,
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'heap_near_capacity');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.memory);
      expect(issue.observationSource, ObservationSource.vmTimeline);
    });

    test('heap_near_capacity detail shows usage percentage', () {
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 92000000 + i * 600000, // 92M → 95M
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'heap_near_capacity');
      expect(issue.title, contains('95%'));
      expect(issue.detail, contains('MB'));
    });

    test('no heap_near_capacity at exact 80% boundary (uses strict >)', () {
      // Feed 6 samples all at exactly 80 % of a 100 MB committed arena.
      // Even though other guards (growth slope, counter) may or may not
      // pass, the strict `> 0.80` comparison must keep the counter at zero
      // and prevent any heap_near_capacity issue from firing.
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 80000000,
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final capIssues =
          detector.issues.where((i) => i.stableId == 'heap_near_capacity');
      expect(capIssues, isEmpty,
          reason: 'Exactly 80% should not trigger (strict > comparison)');
    });

    test('no heap_near_capacity when ratio > 80% but heap flat (no growth)',
        () {
      // Phase 1 growth correlation guard: a steady-state high committed
      // arena must not fire heap_near_capacity, even with 5+ consecutive
      // samples over the threshold. This is the exact false-positive the
      // Phase 0 diagnostic captured on the idle home screen.
      for (var i = 0; i < 10; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 92000000, // flat at 92 %
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final capIssues =
          detector.issues.where((i) => i.stableId == 'heap_near_capacity');
      expect(capIssues, isEmpty,
          reason:
              'Flat heap over threshold is steady-state — growth correlation '
              'guard must suppress heap_near_capacity.');
    });

    test(
        'no heap_near_capacity when growing but < 5 samples in capacity window',
        () {
      // 4 growing samples above the threshold — window reaches size 4,
      // below the required window size of 5. Sustained growth is set on
      // sample 4 (slope check), but the window-size guard must still
      // suppress heap_near_capacity until a full window of samples has
      // been observed.
      for (var i = 0; i < 4; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 85000000 + i * 600000,
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final capIssues =
          detector.issues.where((i) => i.stableId == 'heap_near_capacity');
      expect(capIssues, isEmpty,
          reason: 'Window-size guard should suppress until 5 samples '
              'have been observed');
    });

    test(
        'heap_near_capacity tolerates one sub-threshold dip within 5-sample '
        'window', () {
      // Phase 1 / M2 fix: a "K of N" window (4 of last 5) replaces the
      // strict consecutive counter so the normal Dart GC sawtooth
      // oscillation around the committed arena boundary doesn't reset the
      // guard indefinitely and mask real pressure on apps that genuinely
      // live near capacity. Feed 5 samples with ratios roughly
      // [82, 83, 79, 85, 86] — 4 of 5 over threshold — while heap also
      // grows at >1 MB/s. The dip at sample 3 must not block firing.
      final heapValues = [82000000, 83000000, 79000000, 85000000, 86000000];
      for (var i = 0; i < heapValues.length; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: heapValues[i],
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final capIssues =
          detector.issues.where((i) => i.stableId == 'heap_near_capacity');
      expect(capIssues, hasLength(1),
          reason: 'A single sub-threshold dip in a 5-sample window should '
              'not block firing when 4 of 5 samples are still over and '
              'the heap is growing.');
    });

    test('two sub-threshold samples in window suppresses heap_near_capacity',
        () {
      // Complement to the K-of-N tolerance test above: when the window
      // has only 3 of 5 over-threshold samples, the guard must suppress
      // even if growth is active. Verifies the required-hits threshold
      // actually bites.
      final heapValues = [82000000, 78000000, 83000000, 77000000, 86000000];
      for (var i = 0; i < heapValues.length; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: heapValues[i],
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final capIssues =
          detector.issues.where((i) => i.stableId == 'heap_near_capacity');
      expect(capIssues, isEmpty,
          reason: 'Only 3 of 5 samples over threshold — below the required '
              '4-of-5 hit count, must not fire.');
    });

    test('heap_near_capacity does not fire on first post-warmup sample', () {
      // Phase 1 / M4 fix: the capacity window is cleared on every sample
      // received during warmup so post-warmup evaluation cannot inherit
      // pre-warmup over-threshold samples. Without this clearing, an app
      // that allocated heavily during warmup would see heap_near_capacity
      // fire on the first post-warmup poll with no observed grace period.
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 3000,
      );

      // 6 warmup samples all > 80 % and growing — enough to pre-charge
      // both a legacy consecutive counter and sustainedGrowthStart.
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        warmupDetector.processHeapSample(_sample(
          heapUsage: 82000000 + i * 1000000,
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      // First post-warmup sample: warmup guard has just released. The
      // capacity window must be empty here (cleared across the entire
      // warmup window) so a single sample cannot satisfy the 5-sample
      // window-size guard.
      fakeNow = fakeNow.add(const Duration(milliseconds: 500));
      warmupDetector.processHeapSample(_sample(
        heapUsage: 88000000,
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));

      expect(
        warmupDetector.issues.where((i) => i.stableId == 'heap_near_capacity'),
        isEmpty,
        reason: 'Capacity window must start empty at the warmup boundary — '
            'the first post-warmup sample alone cannot fire.',
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
        reason: 'vmConnected=false must both clear the sliding window '
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
        reason: 'Post-disconnect cycle must contribute to an empty '
            'window — a single cycle is 6/min, below the threshold.',
      );
    });

    test('zero heapCapacity does not cause division-by-zero crash', () {
      fakeNow = fakeNow.add(const Duration(seconds: 1));

      // Should not throw — guard returns early when heapCapacity <= 0
      expect(
        () => detector.processHeapSample(_sample(
          heapUsage: 50000000,
          heapCapacity: 0,
          timestamp: fakeNow,
        )),
        returnsNormally,
      );

      final capIssues =
          detector.issues.where((i) => i.stableId == 'heap_near_capacity');
      expect(capIssues, isEmpty);
    });

    // -- Rolling Window --

    test('rolling window evicts oldest sample at capacity', () {
      // Fill to capacity (60) + 1 extra
      for (var i = 0; i <= 60; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 1000,
          timestamp: fakeNow,
        ));
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
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 600000,
          timestamp: fakeNow,
        ));
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
      // Feed 6 growing samples at 90 % of a 100 MB arena — satisfies the
      // Phase 1 guards (warmup elapsed, 5 consecutive over 80 %, sustained
      // growth).
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 87000000 + i * 600000, // 87 M → 90 M
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }
      // Feed enough GC cycles for gc_pressure.
      for (var i = 0; i < 10; i++) {
        detector.recordGcCycle();
      }

      final stableIds = detector.issues.map((i) => i.stableId).toSet();
      expect(stableIds, contains('gc_pressure'));
      expect(stableIds, contains('heap_near_capacity'));
    });

    // -- Lifecycle --

    test('processHeapSample ignored when disabled', () {
      detector.isEnabled = false;
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processHeapSample(_sample(
        heapUsage: 95000000,
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));

      expect(detector.issues, isEmpty);
      expect(detector.heapSamples, isEmpty);
    });

    test('reset clears heap samples and sustained growth tracking', () {
      // Build up state
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 600000,
          timestamp: fakeNow,
        ));
      }
      expect(detector.issues, isNotEmpty);
      expect(detector.heapSamples, isNotEmpty);

      detector.reset();
      expect(detector.issues, isEmpty);
      expect(detector.heapSamples, isEmpty);

      // Re-feed with no growth — should produce no issues
      for (var i = 0; i < 10; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000,
          timestamp: fakeNow,
        ));
      }
      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing');
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
        warmupDetector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 512000,
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          warmupDetector.issues.where((i) => i.stableId == 'heap_growing');
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
        warmupDetector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 512000,
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          warmupDetector.issues.where((i) => i.stableId == 'heap_growing');
      expect(heapIssues, hasLength(1),
          reason: 'Should alert after warmup + sustained threshold');
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

      final gcIssues =
          warmupDetector.issues.where((i) => i.stableId == 'gc_pressure');
      expect(gcIssues, hasLength(1),
          reason: 'GC pressure should not be affected by warmup');
    });

    test('heap_near_capacity is suppressed during warmup', () {
      // Phase 1 behaviour change: heap_near_capacity now shares the same
      // warmup guard as heap_growing / native_memory_growing. Normal
      // startup allocation (class loading, widget tree, image decodes)
      // often pushes the ratio high on a still-small committed arena; we
      // must not fire during that window.
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 5000,
      );

      // Feed 6 growing samples at 90 % inside the warmup window.
      // Total elapsed = 6 × 300 ms = 1.8 s, well under the 5 s warmup.
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 300));
        warmupDetector.processHeapSample(_sample(
          heapUsage: 87000000 + i * 600000,
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final capacityIssues = warmupDetector.issues
          .where((i) => i.stableId == 'heap_near_capacity');
      expect(capacityIssues, isEmpty,
          reason:
              'heap_near_capacity must be suppressed during warmup to avoid '
              'firing on startup allocation spikes');
    });

    test('heap_near_capacity fires after warmup ends', () {
      // Complement to the suppression test above: once the warmup window
      // has passed AND the Phase 1 guards are satisfied (5 consecutive
      // samples over threshold + sustained growth), heap_near_capacity
      // must fire.
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 5000,
      );

      // Burn 6 seconds inside the warmup window with flat sub-threshold
      // samples so the first-sample timestamp is past warmup before we
      // start pushing the ratio high.
      for (var i = 0; i < 12; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        warmupDetector.processHeapSample(_sample(
          heapUsage: 50000000,
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      // Now feed 6 growing samples at 90 % after warmup has elapsed.
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        warmupDetector.processHeapSample(_sample(
          heapUsage: 87000000 + i * 600000,
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final capacityIssues = warmupDetector.issues
          .where((i) => i.stableId == 'heap_near_capacity');
      expect(capacityIssues, hasLength(1),
          reason:
              'heap_near_capacity should fire after warmup + guards satisfied');
    });

    test('dispose clears heap samples and issues', () {
      // Feed enough GC cycles to fire gc_pressure, plus a heap sample so
      // heapSamples is non-empty. gc_pressure alone produces the issue we
      // assert on — heap_near_capacity is not required here and would
      // need the three-guard setup to fire under Phase 1.
      for (var i = 0; i < 10; i++) {
        detector.recordGcCycle();
      }
      detector.processHeapSample(_sample(
        heapUsage: 50000000,
        timestamp: fakeNow,
      ));
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
      final heapIssues = detector.issues.where((i) =>
          i.stableId == 'heap_growing' || i.stableId == 'heap_near_capacity');
      expect(heapIssues, isEmpty);
    });

    // -- Native Memory Growth (native_memory_growing) --

    test('no native_memory_growing when rssBytes is null', () {
      // 24 samples with growing heap but no rssBytes
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 512000,
          timestamp: fakeNow,
        ));
      }

      final nativeIssues =
          detector.issues.where((i) => i.stableId == 'native_memory_growing');
      expect(nativeIssues, isEmpty);
    });

    test('no native_memory_growing with flat native memory', () {
      // RSS and heap grow together — native gap stays constant
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        final heap = 50000000 + i * 512000;
        detector.processHeapSample(_sample(
          heapUsage: heap,
          rssBytes: heap + 100000000, // constant 100MB native
          timestamp: fakeNow,
        ));
      }

      final nativeIssues =
          detector.issues.where((i) => i.stableId == 'native_memory_growing');
      expect(nativeIssues, isEmpty);
    });

    test('no native_memory_growing when growth < 1MB/s', () {
      // ~800KB/s native growth (below 1MB/s threshold)
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000, // flat heap
          rssBytes: 150000000 + i * 400000, // ~800KB/s native
          timestamp: fakeNow,
        ));
      }

      final nativeIssues =
          detector.issues.where((i) => i.stableId == 'native_memory_growing');
      expect(nativeIssues, isEmpty);
    });

    test('no native_memory_growing when growth < 10s sustained', () {
      // 2MB/s native growth but only 8 seconds (16 samples)
      for (var i = 0; i < 16; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000, // flat heap
          rssBytes: 150000000 + i * 1048576, // ~2MB/s native
          timestamp: fakeNow,
        ));
      }

      final nativeIssues =
          detector.issues.where((i) => i.stableId == 'native_memory_growing');
      expect(nativeIssues, isEmpty);
    });

    test(
        'flags native_memory_growing when growth > 1MB/s sustained 10+ seconds',
        () {
      // 2MB/s native growth for 12 seconds (24 samples), flat heap
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000, // flat heap
          rssBytes: 150000000 + i * 1048576, // ~2MB/s native
          timestamp: fakeNow,
        ));
      }

      final nativeIssues = detector.issues
          .where((i) => i.stableId == 'native_memory_growing')
          .toList();
      expect(nativeIssues, hasLength(1));
    });

    test('native_memory_growing stableId, confidence, category correct', () {
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000,
          rssBytes: 150000000 + i * 1048576,
          timestamp: fakeNow,
        ));
      }

      final issue = detector.issues
          .firstWhere((i) => i.stableId == 'native_memory_growing');
      expect(issue.stableId, 'native_memory_growing');
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.category, IssueCategory.memory);
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.observationSource, ObservationSource.vmTimeline);
    });

    test('native_memory_growing detail contains rate and native estimate', () {
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000,
          rssBytes: 150000000 + i * 1048576,
          timestamp: fakeNow,
        ));
      }

      final issue = detector.issues
          .firstWhere((i) => i.stableId == 'native_memory_growing');
      expect(issue.detail, contains('MB/sec'));
      expect(issue.detail, contains('native estimate'));
      expect(issue.title, contains('MB/s'));
    });

    test('native_memory_growing coexists with heap_growing', () {
      // Both heap and native growing
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 600000, // ~1.2MB/s heap growth
          rssBytes: 200000000 + i * 2000000, // ~4MB/s RSS growth
          timestamp: fakeNow,
        ));
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
        warmupDetector.processHeapSample(_sample(
          heapUsage: 50000000,
          rssBytes: 150000000 + i * 1048576,
          timestamp: fakeNow,
        ));
      }

      final nativeIssues = warmupDetector.issues
          .where((i) => i.stableId == 'native_memory_growing');
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
        warmupDetector.processHeapSample(_sample(
          heapUsage: 50000000,
          rssBytes: 150000000 + i * 1048576,
          timestamp: fakeNow,
        ));
      }

      final nativeIssues = warmupDetector.issues
          .where((i) => i.stableId == 'native_memory_growing');
      expect(nativeIssues, hasLength(1),
          reason: 'Should alert after warmup + sustained threshold');
    });

    test('reset clears native sustained growth tracking', () {
      // Trigger native_memory_growing
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000,
          rssBytes: 150000000 + i * 1048576,
          timestamp: fakeNow,
        ));
      }
      expect(
        detector.issues.where((i) => i.stableId == 'native_memory_growing'),
        isNotEmpty,
      );

      detector.reset();

      // Re-feed with < 10s native growth — should NOT trigger
      for (var i = 0; i < 16; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000,
          rssBytes: 150000000 + i * 1048576,
          timestamp: fakeNow,
        ));
      }

      final nativeIssues =
          detector.issues.where((i) => i.stableId == 'native_memory_growing');
      expect(nativeIssues, isEmpty,
          reason: '<10s sustained growth after reset should not trigger');
    });

    // -- Allocation Enrichment --

    test('enrichHeapGrowingIssue adds topAllocators to existing issue', () {
      // Trigger heap_growing first
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 600000,
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing');
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

      final enriched =
          detector.issues.where((i) => i.stableId == 'heap_growing');
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
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 600000,
          timestamp: fakeNow,
        ));
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
      detector.processHeapSample(_sample(
        heapUsage: 50000000 + 24 * 600000 + 600000,
        timestamp: fakeNow,
      ));

      // Enrichment should survive the rebuild
      final heapIssue =
          detector.issues.firstWhere((i) => i.stableId == 'heap_growing');
      expect(heapIssue.topAllocators, isNotNull);
      expect(heapIssue.topAllocators, hasLength(1));
      expect(heapIssue.topAllocators![0].className, 'Item');
    });

    test('enrichment cleared when heap growth stops', () {
      // Trigger heap_growing
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 600000,
          timestamp: fakeNow,
        ));
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
        detector.processHeapSample(_sample(
          heapUsage: plateau,
          timestamp: fakeNow,
        ));
      }

      // heap_growing should be gone (slope dropped)
      expect(
        detector.issues.where((i) => i.stableId == 'heap_growing'),
        isEmpty,
      );

      // Now trigger growth again — should NOT have stale enrichment
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: plateau + i * 600000,
          timestamp: fakeNow,
        ));
      }

      final regrown =
          detector.issues.where((i) => i.stableId == 'heap_growing');
      if (regrown.isNotEmpty) {
        expect(regrown.first.topAllocators, isNull,
            reason: 'Stale enrichment from prior episode should be cleared');
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
        custom.processHeapSample(_sample(
          heapUsage: 50000000 + i * 150000, // 300KB/s
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          custom.issues.where((i) => i.stableId == 'heap_growing');
      expect(heapIssues, hasLength(1));
    });

    test('custom capacityThresholdPercent lowers detection sensitivity', () {
      final custom = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 0,
        capacityThresholdPercent: 0.60,
      );

      // 6 growing samples at ~65 % — above the custom 60 % threshold, below
      // the default 80 %. Satisfies the Phase 1 guards: 5 consecutive over
      // threshold and sustained growth.
      for (var i = 0; i < 6; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        custom.processHeapSample(_sample(
          heapUsage: 62000000 + i * 600000, // 62 M → 65 M
          heapCapacity: 100000000,
          timestamp: fakeNow,
        ));
      }

      final capIssues =
          custom.issues.where((i) => i.stableId == 'heap_near_capacity');
      expect(capIssues, hasLength(1));
    });

    test('default thresholds do not fire at sub-default levels', () {
      // Verify default 512KB/s threshold does NOT fire at 300KB/s
      for (var i = 0; i < 24; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        detector.processHeapSample(_sample(
          heapUsage: 50000000 + i * 150000,
          timestamp: fakeNow,
        ));
      }

      final heapIssues =
          detector.issues.where((i) => i.stableId == 'heap_growing');
      expect(heapIssues, isEmpty);
    });
  });
}
