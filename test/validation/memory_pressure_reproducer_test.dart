// Hermetic reproducer for `MemoryPressureDetector`.
//
// Drives the detector at its two entrypoints — `processHeapSample`
// (heap timeseries) and `recordGcCycle` (per-cycle GC signal). Four
// stableIds pinned with independent axes: `gc_pressure` (rate),
// `heap_near_capacity` (RSS against the opt-in budget + correlated
// growth), `heap_growing`
// (sustained slope), `native_memory_growing` (RSS-heap gap slope).
//
// Two upstream hops are skipped and disclosed in the ledger row:
//   (1) `VmServiceClient.getMemoryUsage` repacks `vm_service.MemoryUsage`
//       into `HeapSample` with `null → 0` fallback on heap/capacity/
//       external fields. The zero-heap edge case is exercised here.
//   (2) `EventStreams.kGC → _onGcEvent → recordGcCycle` is the
//       authoritative per-cycle signal. `TimelineParser` over-counts GC
//       sub-phase events 5–15× and would fire false positives if used;
//       the reproducer exercises `recordGcCycle` directly, same entry
//       the controller uses in production.
//
// `warmupDurationMs: 0` bypasses the 3-second warmup guard so each test
// can set up thresholds in a few hundred fake milliseconds.

import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/src/detectors/memory_pressure_detector.dart';
import 'package:sleuth/src/models/heap_sample.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '_helpers/vm_reproducer_harness.dart';

void main() {
  group('MemoryPressureDetector reproducer', () {
    late MemoryPressureDetector detector;
    late DateTime now;

    setUp(() {
      now = DateTime(2026, 4, 25, 12);
      // Default GC threshold (180/min = 30 cycles in the 10 s window).
      detector = MemoryPressureDetector(clock: () => now, warmupDurationMs: 0);
      detector.vmConnected = true;
    });

    group('gc_pressure (rate axis, > 180/min over 10s window)', () {
      /// Records [count] cycles 300 ms apart (all inside the window).
      void cycles(int count, {String? gcType}) {
        for (var i = 0; i < count; i++) {
          now = now.add(const Duration(milliseconds: 300));
          detector.recordGcCycle(gcType: gcType);
        }
      }

      test('31 GC cycles in window fires gc_pressure (rate 186/min)', () {
        cycles(31);
        expect(detector.issues, hasStableId('gc_pressure'));
      });

      test(
        '30 GC cycles in window does NOT fire (rate 180/min equals threshold)',
        () {
          cycles(30);
          expect(detector.issues, lacksStableId('gc_pressure'));
        },
      );

      test('old cycles age out of 10s sliding window', () {
        cycles(31);
        expect(detector.issues, hasStableId('gc_pressure'));

        now = now.add(const Duration(seconds: 15));
        detector.recordGcCycle();
        expect(detector.issues, lacksStableId('gc_pressure'));
      });

      test('emission stamps observedGcEvents and the scavenge / old-gen '
          'split', () {
        cycles(25, gcType: 'Scavenge');
        cycles(6, gcType: 'MarkSweep');
        final issue = detector.issues.firstWhere(
          (i) => i.stableId == 'gc_pressure',
        );
        expect(
          issue.extraTraceArgs,
          isNotNull,
          reason: 'gc_pressure stamps its window counts in extraTraceArgs.',
        );
        expect(
          issue.extraTraceArgs!['observedGcEvents'],
          equals('31'),
          reason:
              'Detector stamps raw windowEvents count (integer string) so '
              'the trace record carries the value the threshold gates on.',
        );
        expect(issue.extraTraceArgs!['scavengeCount'], equals('25'));
        expect(issue.extraTraceArgs!['oldGenCount'], equals('6'));
        expect(
          issue.dedupIdentityMicros,
          isNotNull,
          reason:
              'dedupIdentityMicros derived from _gcOverageStart '
              '(first event timestamp at threshold cross) so consecutive '
              'in-overage emissions collapse to one trace record.',
        );
      });

      test(
        're-emission inside same overage carries SAME dedupIdentityMicros',
        () {
          cycles(31);
          final firstIdentity = detector.issues
              .firstWhere((i) => i.stableId == 'gc_pressure')
              .dedupIdentityMicros;
          expect(firstIdentity, isNotNull);
          // _evaluate() clears _issues each call and re-builds them, so
          // detector.issues only ever shows the latest evaluation's
          // emissions. Drive one more in-overage cycle, capture identity
          // again, assert equal — proves _gcOverageStart persists across
          // consecutive evaluations during a single overage so
          // CaptureHelper composite-key dedup can collapse re-emissions.
          cycles(1);
          final secondIdentity = detector.issues
              .firstWhere((i) => i.stableId == 'gc_pressure')
              .dedupIdentityMicros;
          expect(
            secondIdentity,
            equals(firstIdentity),
            reason:
                'Same overage episode → same _gcOverageStart → '
                'same dedupIdentityMicros. Without this, CaptureHelper '
                'cannot collapse re-emissions to one trace record per '
                'episode.',
          );
        },
      );

      test('distinct overage episodes carry DISTINCT dedupIdentityMicros '
          '(_gcOverageStart cleared on no-emit branch)', () {
        // First overage: 31 cycles in 10s → fires.
        cycles(31);
        final firstIdentity = detector.issues
            .firstWhere((i) => i.stableId == 'gc_pressure')
            .dedupIdentityMicros;
        expect(firstIdentity, isNotNull);

        // Advance past the sliding window so the first overage's events
        // age out, then drive a single sub-threshold cycle. NO reset()
        // between episodes — `reset()` would null `_gcOverageStart` via
        // its own clear path and mask the only behavior under test:
        // the no-emit else-branch clear at `windowEvents <= 30`.
        now = now.add(const Duration(seconds: 30));
        detector.recordGcCycle();
        expect(
          detector.issues,
          lacksStableId('gc_pressure'),
          reason:
              'Single isolated cycle (windowEvents == 1) does not '
              'breach threshold; the no-emit else-branch must clear '
              '_gcOverageStart here so the next overage gets a fresh '
              'identity.',
        );

        // Second overage: 31 more cycles → fires with NEW identity.
        cycles(31);
        final secondIdentity = detector.issues
            .firstWhere((i) => i.stableId == 'gc_pressure')
            .dedupIdentityMicros;
        expect(secondIdentity, isNotNull);
        expect(
          secondIdentity,
          isNot(equals(firstIdentity)),
          reason:
              'Two distinct overage episodes must carry distinct '
              'dedup identities. If _gcOverageStart were only cleared on '
              'windowEvents == 0 (instead of <= 30), the second '
              'overage would inherit stale identity and silent dedup '
              'collapse would mask the second episode in CI captures.',
        );
      });
    });

    group('heap_growing (slope > 512KB/s sustained >= 10s)', () {
      test('sustained 600KB/s over 10s fires heap_growing', () {
        for (var i = 0; i < 25; i++) {
          detector.processHeapSample(
            HeapSample(
              heapUsage: i * 300000,
              heapCapacity: 100 * 1024 * 1024,
              externalUsage: 0,
              timestamp: now,
            ),
          );
          now = now.add(const Duration(milliseconds: 500));
        }
        expect(detector.issues, hasStableId('heap_growing'));
      });

      test('flat heap usage does NOT fire heap_growing', () {
        for (var i = 0; i < 25; i++) {
          detector.processHeapSample(
            HeapSample(
              heapUsage: 5 * 1024 * 1024,
              heapCapacity: 100 * 1024 * 1024,
              externalUsage: 0,
              timestamp: now,
            ),
          );
          now = now.add(const Duration(milliseconds: 500));
        }
        expect(detector.issues, lacksStableId('heap_growing'));
      });

      test('emission stamps extraTraceArgs.observedSlopeBytesPerSec', () {
        // Drive the same 600 KB/s sustained scenario as the fire test
        // above so the stamp value is predictable. Least-squares
        // regression over 25 samples at 500 ms spacing with heap usage
        // i * 300_000 yields slope = 600_000 bytes/sec exactly (linear
        // input). `slope.toStringAsFixed(0)` => '600000'.
        for (var i = 0; i < 25; i++) {
          detector.processHeapSample(
            HeapSample(
              heapUsage: i * 300000,
              heapCapacity: 100 * 1024 * 1024,
              externalUsage: 0,
              timestamp: now,
            ),
          );
          now = now.add(const Duration(milliseconds: 500));
        }
        final issue = detector.issues.firstWhere(
          (i) => i.stableId == 'heap_growing',
        );
        expect(
          issue.extraTraceArgs,
          isNotNull,
          reason:
              'v0.19.18 stamps observedSlopeBytesPerSec; '
              'extraTraceArgs map MUST be populated.',
        );
        expect(
          issue.extraTraceArgs!['observedSlopeBytesPerSec'],
          equals('600000'),
          reason:
              'Stringified slope (bytes/sec) for the schema\'s '
              'observed-axis cross-check. Format must match the '
              'wire-format contract (string or num) consumed at '
              'profile_capture_schema.dart L1198-1209.',
        );
      });
    });

    group('heap_near_capacity (RSS >= 80% of memoryBudgetBytes + '
        'correlated heap_growing)', () {
      const mb = 1024 * 1024;

      /// 25 samples 500 ms apart, heap growing 800 KB/s, heap ratio 0.85.
      void growth(MemoryPressureDetector d, {required int? rssBytes}) {
        for (var i = 0; i < 25; i++) {
          final heap = (10 * mb) + i * 400000;
          d.processHeapSample(
            HeapSample(
              heapUsage: heap,
              heapCapacity: (heap / 0.85).round(),
              externalUsage: 0,
              timestamp: now,
              rssBytes: rssBytes,
            ),
          );
          now = now.add(const Duration(milliseconds: 500));
        }
      }

      MemoryPressureDetector withBudget() => MemoryPressureDetector(
        clock: () => now,
        warmupDurationMs: 0,
        memoryBudgetBytes: 100 * mb,
      )..vmConnected = true;

      test('budget unset: sustained growth at heap ratio 0.85 does NOT '
          'fire', () {
        growth(detector, rssBytes: 95 * mb);
        expect(detector.issues, hasStableId('heap_growing'));
        expect(detector.issues, lacksStableId('heap_near_capacity'));
      });

      test('RSS 85 MB of a 100 MB budget with sustained growth fires both '
          'stableIds', () {
        final d = withBudget();
        growth(d, rssBytes: 85 * mb);
        expect(d.issues, hasStableId('heap_growing'));
        expect(d.issues, hasStableId('heap_near_capacity'));
        final issue = d.issues.firstWhere(
          (i) => i.stableId == 'heap_near_capacity',
        );
        expect(issue.severity, IssueSeverity.critical);
        expect(issue.confidence, IssueConfidence.likely);
        expect(issue.dedupIdentityMicros, isNotNull);
      });

      test('RSS 70 MB of a 100 MB budget does NOT fire even with growth', () {
        final d = withBudget();
        growth(d, rssBytes: 70 * mb);
        expect(d.issues, hasStableId('heap_growing'));
        expect(d.issues, lacksStableId('heap_near_capacity'));
      });

      test('null rssBytes never counts toward the budget', () {
        final d = withBudget();
        growth(d, rssBytes: null);
        expect(d.issues, hasStableId('heap_growing'));
        expect(d.issues, lacksStableId('heap_near_capacity'));
      });
    });

    group('native_memory_growing (RSS-heap gap > 1MB/s sustained 10s)', () {
      test('native memory growing at 2MB/s over 10s fires', () {
        for (var i = 0; i < 25; i++) {
          detector.processHeapSample(
            HeapSample(
              heapUsage: 5 * 1024 * 1024,
              heapCapacity: 50 * 1024 * 1024,
              externalUsage: 0,
              timestamp: now,
              rssBytes: (10 * 1024 * 1024) + i * 1024 * 1024,
            ),
          );
          now = now.add(const Duration(milliseconds: 500));
        }
        expect(detector.issues, hasStableId('native_memory_growing'));
      });

      test(
        'null rssBytes (web platform) does NOT fire native_memory_growing',
        () {
          for (var i = 0; i < 25; i++) {
            detector.processHeapSample(
              HeapSample(
                heapUsage: 5 * 1024 * 1024,
                heapCapacity: 50 * 1024 * 1024,
                externalUsage: 0,
                timestamp: now,
              ),
            );
            now = now.add(const Duration(milliseconds: 500));
          }
          expect(detector.issues, lacksStableId('native_memory_growing'));
        },
      );
    });

    group('null-coalesce edge case from VmServiceClient', () {
      test(
        'heapUsage=0 (null coalesced) does not fire any heap-axis issue',
        () {
          for (var i = 0; i < 25; i++) {
            detector.processHeapSample(
              HeapSample(
                heapUsage: 0,
                heapCapacity: 50 * 1024 * 1024,
                externalUsage: 0,
                timestamp: now,
              ),
            );
            now = now.add(const Duration(milliseconds: 500));
          }
          expect(detector.issues, lacksStableId('heap_growing'));
          expect(detector.issues, lacksStableId('heap_near_capacity'));
        },
      );

      test(
        'heapCapacity=0 (null coalesced) does not fire heap_near_capacity',
        () {
          detector = MemoryPressureDetector(
            clock: () => now,
            warmupDurationMs: 0,
            memoryBudgetBytes: 100 * 1024 * 1024,
          );
          for (var i = 0; i < 25; i++) {
            detector.processHeapSample(
              HeapSample(
                heapUsage: (5 + i) * 1024 * 1024,
                heapCapacity: 0,
                externalUsage: 0,
                timestamp: now,
              ),
            );
            now = now.add(const Duration(milliseconds: 500));
          }
          expect(detector.issues, lacksStableId('heap_near_capacity'));
        },
      );
    });

    group('negative control', () {
      test('disabled detector ignores GC cycles and heap samples', () {
        detector.isEnabled = false;
        for (var i = 0; i < 10; i++) {
          now = now.add(const Duration(seconds: 1));
          detector.recordGcCycle();
        }
        for (var i = 0; i < 25; i++) {
          detector.processHeapSample(
            HeapSample(
              heapUsage: i * 1024 * 1024,
              heapCapacity: 100 * 1024 * 1024,
              externalUsage: 0,
              timestamp: now,
              rssBytes: (10 + i) * 1024 * 1024,
            ),
          );
          now = now.add(const Duration(milliseconds: 500));
        }
        expect(detector.issues, isEmpty);
      });
    });

    group('producer-side dedup identity (heap_growing)', () {
      test('heap_growing issue carries dedupIdentityMicros derived from '
          '_sustainedGrowthStart (stable across polls during one episode)', () {
        // Drive sustained 600 KB/s growth across 25 samples (12.5 s wall).
        // First slope-cross sets `_sustainedGrowthStart` once; subsequent
        // polls during the same sustained window must emit issues sharing
        // that timestamp as dedup identity.
        final identitiesObserved = <int>{};
        for (var i = 0; i < 25; i++) {
          detector.processHeapSample(
            HeapSample(
              heapUsage: i * 300000,
              heapCapacity: 100 * 1024 * 1024,
              externalUsage: 0,
              timestamp: now,
            ),
          );
          final issue = detector.issues
              .where((it) => it.stableId == 'heap_growing')
              .cast<PerformanceIssue?>()
              .firstWhere((_) => true, orElse: () => null);
          if (issue != null) {
            expect(issue.dedupIdentityMicros, isNotNull);
            identitiesObserved.add(issue.dedupIdentityMicros!);
          }
          now = now.add(const Duration(milliseconds: 500));
        }

        expect(detector.issues, hasStableId('heap_growing'));
        // Across the entire sustained-growth episode, every emitted
        // heap_growing issue must share the same dedup identity → the
        // controller's composite-key dedup collapses N polls to one
        // trace record.
        expect(
          identitiesObserved,
          hasLength(1),
          reason:
              'Sustained-growth episode must emit ONE distinct dedup '
              'identity; multiple distinct identities indicate '
              '_sustainedGrowthStart reset mid-episode.',
        );
      });
    });

    group('vmConnected disconnect cleanup', () {
      test('vmConnected = false clears all identity-bearing state '
          '(heap samples, sustained-growth start, budget crossing, '
          'first-sample marker, GC window) so post-reconnect cannot '
          'carry stale dedupIdentityMicros from the prior session', () {
        // Establish sustained growth in session A.
        for (var i = 0; i < 25; i++) {
          detector.processHeapSample(
            HeapSample(
              heapUsage: i * 300000,
              heapCapacity: 100 * 1024 * 1024,
              externalUsage: 0,
              timestamp: now,
            ),
          );
          now = now.add(const Duration(milliseconds: 500));
        }
        expect(detector.issues, hasStableId('heap_growing'));
        final priorIdentity = detector.issues
            .firstWhere((i) => i.stableId == 'heap_growing')
            .dedupIdentityMicros;
        expect(priorIdentity, isNotNull);

        // Disconnect — every identity-bearing field must clear.
        detector.vmConnected = false;
        expect(
          detector.issues,
          isEmpty,
          reason:
              'Disconnect re-runs _evaluate; cleared state means '
              'no issue can survive',
        );
        // Heap-sample window cleared: heapSamples getter is empty.
        expect(detector.heapSamples, isEmpty);

        // Reconnect after a 10s simulated delay. Drive a fresh sustained-
        // growth episode in session B starting from a clean window.
        detector.vmConnected = true;
        now = now.add(const Duration(seconds: 10));
        for (var i = 0; i < 25; i++) {
          detector.processHeapSample(
            HeapSample(
              heapUsage: i * 300000,
              heapCapacity: 100 * 1024 * 1024,
              externalUsage: 0,
              timestamp: now,
            ),
          );
          now = now.add(const Duration(milliseconds: 500));
        }
        expect(detector.issues, hasStableId('heap_growing'));
        final newIdentity = detector.issues
            .firstWhere((i) => i.stableId == 'heap_growing')
            .dedupIdentityMicros;
        expect(newIdentity, isNotNull);
        expect(
          newIdentity,
          isNot(equals(priorIdentity)),
          reason:
              'Session B identity must derive from a fresh '
              '_sustainedGrowthStart, not survive from session A',
        );
      });
    });
  });
}
