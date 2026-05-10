import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/tracked_resource_detector.dart';
import 'package:sleuth/src/utils/issue_explanation_builder.dart';

class _Service {
  _Service(this.id);
  final int id;
}

void main() {
  group('TrackedResourceDetector unit', () {
    late DateTime fakeNow;
    late TrackedResourceDetector detector;

    setUp(() {
      fakeNow = DateTime.utc(2026, 6, 1);
      detector = TrackedResourceDetector(
        maxConcurrent: 5,
        longLivedSeconds: 300,
        maxDistinctNames: 1000,
        sweepIntervalSeconds: 10,
        clock: () => fakeNow,
      );
    });

    tearDown(() => detector.dispose());

    test('multi-name interleaved tracking; buckets independent', () {
      // Root holders locally so GC cannot reclaim them mid-test —
      // WeakReference + temporaries would otherwise let the bucket
      // empty before `evaluateNowForTest` runs.
      final keep = <_Service>[];
      for (var i = 0; i < 6; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('chat_socket', s);
      }
      for (var i = 0; i < 3; i++) {
        final s = _Service(100 + i);
        keep.add(s);
        detector.track('analytics', s);
      }
      detector.evaluateNowForTest();
      // chat_socket fires (>5); analytics does not (<=5).
      final chats = detector.issues
          .where((i) => i.extraTraceArgs!['resourceName'] == 'chat_socket');
      final analytics = detector.issues
          .where((i) => i.extraTraceArgs!['resourceName'] == 'analytics');
      expect(chats, hasLength(1));
      expect(analytics, isEmpty);
    });

    test('co-fire: same bucket above concurrent AND long-lived thresholds', () {
      final keep = <_Service>[];
      for (var i = 0; i < 6; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('chat_socket', s);
      }
      fakeNow = fakeNow.add(const Duration(seconds: 301));
      detector.evaluateNowForTest();
      final ids = detector.issues.map((i) => i.stableId).toSet();
      expect(ids, contains('tracked_resource_concurrent:chat_socket'));
      expect(ids, contains('tracked_resource_long_lived:chat_socket'));
    });

    test('dispose clears state + cancels sweep', () {
      detector.track('chat_socket', _Service(1));
      expect(detector.snapshotLiveCounts(), isNotEmpty);
      detector.dispose();
      expect(detector.snapshotLiveCounts(), isEmpty);
      expect(detector.issues, isEmpty);
    });

    test('vmConnected toggle inert (pure-Dart detector)', () {
      detector.track('chat_socket', _Service(1));
      detector.vmConnected = false;
      detector.vmConnected = true;
      // Tracking state should be unaffected by VM toggles.
      expect(detector.snapshotLiveCounts()['chat_socket'], equals(1));
    });

    test('isEnabled = false clears issues + stops accepting new tracks', () {
      detector.track('chat_socket', _Service(1));
      detector.isEnabled = false;
      detector.track('chat_socket', _Service(2));
      detector.evaluateNowForTest();
      expect(detector.issues, isEmpty);
      // Re-enable: previous state cleared so new tracks start fresh.
      detector.isEnabled = true;
      detector.track('chat_socket', _Service(3));
      detector.evaluateNowForTest();
      expect(detector.snapshotLiveCounts()['chat_socket'], equals(1));
    });

    test('WeakReference smoke: common Flutter types accept track', () {
      // Custom class.
      detector.track('service', _Service(1));
      // Closure (a Function — accepted by WeakReference).
      void handler() {}
      detector.track('callback', handler);
      // Iterable instance.
      detector.track('list', <int>[1, 2, 3]);
      // Map instance.
      detector.track('map', <String, int>{'a': 1});
      detector.evaluateNowForTest();
      expect(detector.droppedTargetsCount, equals(0));
      expect(detector.snapshotLiveCounts().keys, hasLength(4));
    });

    test('untrack matches by identity (not equality)', () {
      final a = _Service(1);
      final b = _Service(1); // Equal but distinct identity.
      detector.track('service', a);
      detector.track('service', b);
      expect(detector.snapshotLiveCounts()['service'], equals(2));
      detector.untrack('service', a);
      expect(detector.snapshotLiveCounts()['service'], equals(1));
    });

    test('repeated track of same identity is deduped', () {
      final a = _Service(1);
      detector.track('service', a);
      detector.track('service', a);
      detector.track('service', a);
      expect(detector.snapshotLiveCounts()['service'], equals(1));
    });

    test('encyclopedia carries entries for both stableId constants', () {
      final keys = IssueExplanationBuilder.allExplanations.keys.toSet();
      expect(keys, contains(TrackedResourceDetector.concurrentStableId));
      expect(keys, contains(TrackedResourceDetector.longLivedStableId));
    });

    test('large-N tracking counts every distinct identity', () {
      // Identity-keyed dedup must not collapse on hash collision —
      // Dart's identityHashCode is allocation-collision-allowed by
      // contract. At 5000 distinct objects under one name the counter
      // must report 5000 even if some hash codes happen to overlap.
      const n = 5000;
      final keep = <_Service>[];
      for (var i = 0; i < n; i++) {
        final s = _Service(i);
        keep.add(s); // Root the object so the GC cannot reclaim it.
        detector.track('stress', s);
      }
      detector.evaluateNowForTest();
      expect(detector.snapshotLiveCounts()['stress'], equals(n),
          reason: 'identity-keyed dedup must count every distinct object');
    });

    test(
        'simulateFinalizerForTest releases only the matching ref under same name',
        () {
      final a = _Service(1);
      final b = _Service(2);
      detector.track('chat_socket', a);
      detector.track('chat_socket', b);
      expect(detector.snapshotLiveCounts()['chat_socket'], equals(2));
      // Simulate GC of `a` only. `b` must remain live in the bucket.
      detector.simulateFinalizerForTest('chat_socket', a);
      detector.evaluateNowForTest();
      expect(detector.snapshotLiveCounts()['chat_socket'], equals(1));
    });
  });
}
