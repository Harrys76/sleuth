// Hermetic reproducer for `TrackedResourceDetector`.
//
// Drives the detector through its public `track` / `untrack` /
// `simulateFinalizerForTest` / `evaluateNowForTest` surface with an
// injected clock — no dependency on real GC or Finalizer timing.
// The simulate-finalizer seam is identity-keyed so it cannot mask
// hash-collision regressions in the production path. Production
// wiring of `Finalizer.attach` is integration-tested by the example
// demo screen at `example/lib/demos/tracked_resource_demo.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/tracked_resource_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

class _Holder {
  _Holder(this.id);
  final int id;
}

void main() {
  group('TrackedResourceDetector reproducer', () {
    late DateTime fakeNow;
    late TrackedResourceDetector detector;

    setUp(() {
      fakeNow = DateTime.utc(2026, 6, 1, 12, 0, 0);
      detector = TrackedResourceDetector(
        maxConcurrent: 5,
        longLivedSeconds: 300,
        maxDistinctNames: 1000,
        sweepIntervalSeconds: 10,
        clock: () => fakeNow,
      );
    });

    tearDown(() => detector.dispose());

    test('6 instances same name fires concurrent.warning', () {
      // Root holders locally so GC cannot reclaim them mid-test.
      final keep = <_Holder>[];
      for (var i = 0; i < 6; i++) {
        final h = _Holder(i);
        keep.add(h);
        detector.track('chat_socket', h);
      }
      detector.evaluateNowForTest();
      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.stableId, equals('tracked_resource_concurrent:chat_socket'));
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.extraTraceArgs!['resourceName'], 'chat_socket');
      expect(issue.extraTraceArgs!['liveInstanceCount'], '6');
    });

    test('5 instances same name does NOT fire concurrent (boundary)', () {
      for (var i = 0; i < 5; i++) {
        detector.track('chat_socket', _Holder(i));
      }
      detector.evaluateNowForTest();
      expect(
          detector.issues.where((i) =>
              i.stableId?.startsWith('tracked_resource_concurrent') ?? false),
          isEmpty);
    });

    test('long-lived fires after threshold elapsed', () {
      detector.track('chat_socket', _Holder(1));
      // Advance clock past 300s threshold.
      fakeNow = fakeNow.add(const Duration(seconds: 301));
      detector.evaluateNowForTest();
      final longLived = detector.issues.where(
          (i) => i.stableId == 'tracked_resource_long_lived:chat_socket');
      expect(longLived, hasLength(1));
      final issue = longLived.first;
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.extraTraceArgs!['resourceName'], 'chat_socket');
      final age = int.parse(issue.extraTraceArgs!['oldestInstanceAgeSeconds']!);
      expect(age, greaterThanOrEqualTo(301));
    });

    test('long-lived does NOT fire below threshold (boundary)', () {
      detector.track('chat_socket', _Holder(1));
      fakeNow = fakeNow.add(const Duration(seconds: 299));
      detector.evaluateNowForTest();
      expect(
          detector.issues.where((i) =>
              i.stableId?.startsWith('tracked_resource_long_lived') ?? false),
          isEmpty);
    });

    test('untrack reduces count below threshold; emission clears', () {
      final holders = List.generate(6, _Holder.new);
      for (final h in holders) {
        detector.track('chat_socket', h);
      }
      detector.evaluateNowForTest();
      expect(detector.issues, hasLength(1));
      // Untrack 2 → 4 live → below threshold.
      detector.untrack('chat_socket', holders[0]);
      detector.untrack('chat_socket', holders[1]);
      detector.evaluateNowForTest();
      expect(detector.issues, isEmpty);
    });

    test('LRU evicts least-recently-emitted bucket past maxDistinctNames', () {
      final smallDetector = TrackedResourceDetector(
        maxConcurrent: 5,
        longLivedSeconds: 300,
        maxDistinctNames: 3,
        sweepIntervalSeconds: 10,
        clock: () => fakeNow,
      );
      addTearDown(smallDetector.dispose);
      for (var i = 0; i < 5; i++) {
        smallDetector.track('name-$i', _Holder(i));
      }
      // Map cap = 3; expected evictions = 2.
      expect(smallDetector.evictedNamesCount, equals(2));
      final live = smallDetector.snapshotLiveCounts();
      expect(live.length, lessThanOrEqualTo(3));
    });

    test('primitive target rejected; counter increments', () {
      // ignore: invalid_use_of_visible_for_testing_member
      // Wrap in zoneError-tolerant runner so the debug `assert` does
      // not abort the test process. The release-equivalent silent-drop
      // path is what we assert on.
      final released = TrackedResourceDetector(
        maxConcurrent: 5,
        longLivedSeconds: 300,
        maxDistinctNames: 1000,
        sweepIntervalSeconds: 10,
        clock: () => fakeNow,
      );
      addTearDown(released.dispose);
      // Skip the assert by using a scope that catches it. Production
      // primitive-rejection runs in non-assert (release) mode where
      // the silent-drop branch is the only path. Confirm via try/catch.
      try {
        released.track('foo', 42);
      } on AssertionError {
        // Expected in debug; counter still increments below.
      }
      // The detector's runtime check increments dropped count even
      // when the assertion fires (in a release build the assert is
      // stripped and the check still runs).
      expect(released.droppedTargetsCount, greaterThanOrEqualTo(1));
    });

    test('bucket flap: cross/drop/re-cross yields distinct dedup identity', () {
      final h1 = List.generate(6, _Holder.new);
      for (final h in h1) {
        detector.track('chat_socket', h);
      }
      detector.evaluateNowForTest();
      final firstIdentity = detector.issues.first.dedupIdentityMicros;
      expect(firstIdentity, isNotNull);

      // Drop below threshold by untracking enough.
      detector.untrack('chat_socket', h1[0]);
      detector.untrack('chat_socket', h1[1]);
      detector.evaluateNowForTest();
      expect(detector.issues, isEmpty);

      // Advance clock + re-cross.
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      final h2 = List.generate(2, (i) => _Holder(100 + i));
      for (final h in h2) {
        detector.track('chat_socket', h);
      }
      detector.evaluateNowForTest();
      expect(detector.issues, hasLength(1));
      final secondIdentity = detector.issues.first.dedupIdentityMicros;
      expect(secondIdentity, isNotNull);
      expect(secondIdentity, isNot(equals(firstIdentity)));
    });

    test('untrack with mismatched identity is silent no-op', () {
      final h = _Holder(1);
      detector.track('chat_socket', h);
      // Different object same name.
      detector.untrack('chat_socket', _Holder(2));
      detector.evaluateNowForTest();
      // Original instance still live.
      final live = detector.snapshotLiveCounts();
      expect(live['chat_socket'], equals(1));
    });

    test('untrack with unknown name is silent no-op', () {
      final h = _Holder(1);
      detector.track('chat_socket', h);
      detector.untrack('not_a_known_name', h);
      detector.evaluateNowForTest();
      expect(detector.snapshotLiveCounts()['chat_socket'], equals(1));
    });

    test('simulateFinalizerForTest seam decrements bucket', () {
      final h = _Holder(1);
      detector.track('chat_socket', h);
      // Simulate GC reclaim via seam — same path Finalizer would use.
      detector.simulateFinalizerForTest('chat_socket', h);
      detector.evaluateNowForTest();
      expect(detector.snapshotLiveCounts(), isEmpty);
    });
  });
}
