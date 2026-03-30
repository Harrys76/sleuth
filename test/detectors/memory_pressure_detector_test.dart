import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/memory_pressure_detector.dart';
import 'package:widget_watchdog/src/models/allocation_entry.dart';
import 'package:widget_watchdog/src/models/heap_sample.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

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
        warmupDurationMs: 0, // Disable warmup for existing tests
      );
    });

    // -- Disabled / No-Data --

    test('no issues when disabled', () {
      detector.isEnabled = false;
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      detector.processTimelineData(gcHeavyData(gcCount: 20));
      expect(detector.issues, isEmpty);
    });

    test('no issues with no GC events', () {
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    // -- GC Pressure --

    test('no issues with low GC frequency', () {
      // 2 GC events over 60 seconds = 2/min — well below 30/min threshold
      fakeNow = fakeNow.add(const Duration(seconds: 60));
      detector.processTimelineData(gcHeavyData(gcCount: 2));
      expect(detector.issues, isEmpty);
    });

    test('flags high GC pressure (>30 GC/min)', () {
      // 10 GC events over 10 seconds = 60/min
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      expect(detector.issues, isNotEmpty);
      expect(detector.issues.first.title, contains('GC Pressure'));
      expect(detector.issues.first.observationSource,
          ObservationSource.vmTimeline);
    });

    test('GC severity uses warning level', () {
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    test('GC issue confidence is likely', () {
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      expect(detector.issues.first.confidence, IssueConfidence.likely);
    });

    test('GC issue detail contains frequency', () {
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      expect(detector.issues.first.detail, contains('/min'));
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

    test('flags heap_near_capacity when usage > 80%', () {
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processHeapSample(_sample(
        heapUsage: 85000000,
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));

      final capIssues = detector.issues
          .where((i) => i.stableId == 'heap_near_capacity')
          .toList();
      expect(capIssues, hasLength(1));
    });

    test('heap_near_capacity severity is critical', () {
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processHeapSample(_sample(
        heapUsage: 90000000,
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));

      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'heap_near_capacity');
      expect(issue.severity, IssueSeverity.critical);
    });

    test('heap_near_capacity confidence is confirmed', () {
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processHeapSample(_sample(
        heapUsage: 90000000,
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));

      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'heap_near_capacity');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.memory);
      expect(issue.observationSource, ObservationSource.vmTimeline);
    });

    test('heap_near_capacity detail shows usage percentage', () {
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processHeapSample(_sample(
        heapUsage: 95000000,
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));

      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'heap_near_capacity');
      expect(issue.title, contains('95%'));
      expect(issue.detail, contains('MB'));
    });

    test('no heap_near_capacity at exact 80% boundary (uses strict >)', () {
      // Threshold comparison is `ratio > 0.80`, so exactly 80% should NOT fire
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processHeapSample(_sample(
        heapUsage: 80000000,
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));

      final capIssues =
          detector.issues.where((i) => i.stableId == 'heap_near_capacity');
      expect(capIssues, isEmpty,
          reason: 'Exactly 80% should not trigger (strict > comparison)');
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
      // Feed enough GC events for gc_pressure
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      final stableIds = detector.issues.map((i) => i.stableId).toSet();
      expect(stableIds, contains('gc_pressure'));
      expect(stableIds, contains('heap_growing'));
    });

    test('GC pressure and heap_near_capacity can coexist', () {
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      // Feed a heap sample at 90% capacity
      detector.processHeapSample(_sample(
        heapUsage: 90000000,
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));
      // Feed GC events
      detector.processTimelineData(gcHeavyData(gcCount: 10));

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
      );

      // Advance clock and feed GC events during warmup period
      fakeNow = fakeNow.add(const Duration(seconds: 3));
      warmupDetector.processTimelineData(gcHeavyData(gcCount: 10));

      final gcIssues =
          warmupDetector.issues.where((i) => i.stableId == 'gc_pressure');
      expect(gcIssues, hasLength(1),
          reason: 'GC pressure should not be affected by warmup');
    });

    test('heap_near_capacity still fires during warmup', () {
      final warmupDetector = MemoryPressureDetector(
        clock: () => fakeNow,
        warmupDurationMs: 5000,
      );

      // Feed a near-capacity sample during warmup
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      warmupDetector.processHeapSample(_sample(
        heapUsage: 90000000,
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));

      final capacityIssues = warmupDetector.issues
          .where((i) => i.stableId == 'heap_near_capacity');
      expect(capacityIssues, hasLength(1),
          reason: 'Heap capacity should not be affected by warmup');
    });

    test('dispose clears heap samples and issues', () {
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));
      detector.processHeapSample(_sample(
        heapUsage: 90000000,
        heapCapacity: 100000000,
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
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processTimelineData(gcHeavyData(gcCount: 10));

      // Only GC issue, no heap trend or capacity
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

      fakeNow = fakeNow.add(const Duration(seconds: 1));
      custom.processHeapSample(_sample(
        heapUsage: 65000000, // 65% — above 60%, below default 80%
        heapCapacity: 100000000,
        timestamp: fakeNow,
      ));

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
