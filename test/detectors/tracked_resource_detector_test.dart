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

    test('long-lived re-emits each sweep: monotone age + fresh dedup identity',
        () {
      // Single instance so only the long-lived path fires. Each sweep above
      // threshold must emit fresh `dedupIdentityMicros` + current age so
      // captures see an ascending-age series, not a frozen first-cross value.
      final keep = _Service(1);
      detector.track('socket', keep);

      fakeNow = fakeNow.add(const Duration(seconds: 310));
      detector.evaluateNowForTest();
      final first = detector.issues.firstWhere(
          (i) => i.stableId == 'tracked_resource_long_lived:socket');
      final firstAge =
          int.parse(first.extraTraceArgs!['oldestInstanceAgeSeconds']!);
      final firstDedup = first.dedupIdentityMicros!;

      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.evaluateNowForTest();
      final second = detector.issues.firstWhere(
          (i) => i.stableId == 'tracked_resource_long_lived:socket');
      final secondAge =
          int.parse(second.extraTraceArgs!['oldestInstanceAgeSeconds']!);
      final secondDedup = second.dedupIdentityMicros!;

      expect(secondAge, greaterThan(firstAge));
      expect(secondDedup, greaterThan(firstDedup));
      expect(first.captureTraceStableId,
          equals(TrackedResourceDetector.longLivedStableId));
      expect(second.captureTraceStableId,
          equals(TrackedResourceDetector.longLivedStableId));
      // Parametric stableId for UI keying; bare family for bracket match.
      expect(second.stableId, equals('tracked_resource_long_lived:socket'));
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

  group('TrackedResourceDetector per-name overrides', () {
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

    test('override beats global default', () {
      detector.registerNameOverride('http_pool', maxConcurrent: 10);
      final keep = <_Service>[];
      // 8 < override 10 → no fire.
      for (var i = 0; i < 8; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('http_pool', s);
      }
      detector.evaluateNowForTest();
      expect(detector.issues, isEmpty);
      // 11 > override 10 → fire.
      for (var i = 8; i < 11; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('http_pool', s);
      }
      detector.evaluateNowForTest();
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.stableId,
          equals('tracked_resource_concurrent:http_pool'));
    });

    test('override applies live to existing bucket', () {
      final keep = <_Service>[];
      for (var i = 0; i < 6; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('chat_socket', s);
      }
      detector.evaluateNowForTest();
      expect(detector.issues, hasLength(1));
      // Raise threshold above current live count → next sweep clears.
      detector.registerNameOverride('chat_socket', maxConcurrent: 10);
      detector.evaluateNowForTest();
      expect(detector.issues, isEmpty);
    });

    test('firstSeenMicros NOT reset by registerNameOverride', () {
      final h = _Service(1);
      detector.track('chat_socket', h);
      fakeNow = fakeNow.add(const Duration(seconds: 100));
      detector.registerNameOverride('chat_socket', longLivedSeconds: 200);
      fakeNow = fakeNow.add(const Duration(seconds: 250));
      detector.evaluateNowForTest();
      // Age >= 200 (override) → long-lived fires.
      final longLived = detector.issues.where(
          (i) => i.stableId == 'tracked_resource_long_lived:chat_socket');
      expect(longLived, hasLength(1));
      final age = int.parse(
          longLived.first.extraTraceArgs!['oldestInstanceAgeSeconds']!);
      expect(age, greaterThanOrEqualTo(350));
    });

    test('register-without-track does not create bucket', () {
      detector.registerNameOverride('foo', maxConcurrent: 10);
      expect(detector.snapshotLiveCounts().containsKey('foo'), isFalse);
      expect(detector.snapshotNameOverrides().containsKey('foo'), isTrue);
      // Run sweep — no bucket created/dropped.
      detector.evaluateNowForTest();
      expect(detector.snapshotLiveCounts().containsKey('foo'), isFalse);
      expect(
          detector.snapshotNameOverrides()['foo']!.maxConcurrent, equals(10));
      // Later track picks up override.
      final keep = <_Service>[];
      for (var i = 0; i < 11; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('foo', s);
      }
      detector.evaluateNowForTest();
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.extraTraceArgs!['effectiveMaxConcurrent'],
          equals('10'));
    });

    test('non-positive values silently drop + counter increments', () {
      detector.registerNameOverride('a', maxConcurrent: 0);
      detector.registerNameOverride('b', maxConcurrent: -5);
      detector.registerNameOverride('c', longLivedSeconds: 0);
      detector.registerNameOverride('d', longLivedSeconds: -1);
      expect(detector.droppedOverridesCount, equals(4));
      expect(detector.snapshotNameOverrides(), isEmpty);
    });

    test('extraTraceArgs stamps override + thresholdSource when active', () {
      detector.registerNameOverride('http_pool', maxConcurrent: 3);
      final keep = <_Service>[];
      for (var i = 0; i < 4; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('http_pool', s);
      }
      detector.evaluateNowForTest();
      final issue = detector.issues.first;
      expect(issue.extraTraceArgs!['effectiveMaxConcurrent'], equals('3'));
      expect(issue.extraTraceArgs!['thresholdSource'], equals('override'));
    });

    test('extraTraceArgs stamps global + thresholdSource when no override', () {
      final keep = <_Service>[];
      for (var i = 0; i < 6; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('chat_socket', s);
      }
      detector.evaluateNowForTest();
      final issue = detector.issues.first;
      expect(issue.extraTraceArgs!['effectiveMaxConcurrent'], equals('5'));
      expect(issue.extraTraceArgs!['thresholdSource'], equals('global'));
    });

    test('lower-threshold-mid-episode emits new dedupIdentityMicros', () {
      final keep = <_Service>[];
      for (var i = 0; i < 5; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('chat_socket', s);
      }
      // Raise to 10 → no fire (5 ≤ 10), marker cleared.
      detector.registerNameOverride('chat_socket', maxConcurrent: 10);
      detector.evaluateNowForTest();
      expect(detector.issues, isEmpty);
      // Lower to 3 → fires with fresh dedupIdentityMicros.
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      detector.registerNameOverride('chat_socket', maxConcurrent: 3);
      detector.evaluateNowForTest();
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.dedupIdentityMicros, isNotNull);
    });

    test('override survives isEnabled=false → true cycle', () {
      detector.registerNameOverride('chat_socket', maxConcurrent: 3);
      detector.isEnabled = false;
      detector.isEnabled = true;
      // Override still in map.
      expect(detector.snapshotNameOverrides()['chat_socket']!.maxConcurrent,
          equals(3));
      // Track 4 → fires at override 3 (not global 5).
      final keep = <_Service>[];
      for (var i = 0; i < 4; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('chat_socket', s);
      }
      detector.evaluateNowForTest();
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.extraTraceArgs!['effectiveMaxConcurrent'],
          equals('3'));
    });

    test('dispose() clears overrides', () {
      detector.registerNameOverride('foo', maxConcurrent: 3);
      detector.registerNameOverride('bar', longLivedSeconds: 100);
      expect(detector.snapshotNameOverrides(), hasLength(2));
      detector.dispose();
      expect(detector.snapshotNameOverrides(), isEmpty);
    });

    test('partial override: maxConcurrent only, longLivedSeconds falls back',
        () {
      detector.registerNameOverride('foo', maxConcurrent: 3);
      final h = _Service(1);
      detector.track('foo', h);
      // Add 3 more → liveCount 4 > override 3 → concurrent fires.
      final keep = <_Service>[h];
      for (var i = 0; i < 3; i++) {
        final s = _Service(i + 10);
        keep.add(s);
        detector.track('foo', s);
      }
      // Advance past global long-lived (300s) → long-lived fires using
      // global default since override only set maxConcurrent.
      fakeNow = fakeNow.add(const Duration(seconds: 301));
      detector.evaluateNowForTest();
      final concurrent = detector.issues
          .where((i) => i.stableId == 'tracked_resource_concurrent:foo');
      final longLived = detector.issues
          .where((i) => i.stableId == 'tracked_resource_long_lived:foo');
      expect(concurrent, hasLength(1));
      expect(concurrent.first.extraTraceArgs!['thresholdSource'],
          equals('override'));
      expect(longLived, hasLength(1));
      expect(longLived.first.extraTraceArgs!['effectiveLongLivedSeconds'],
          equals('300'));
      expect(
          longLived.first.extraTraceArgs!['thresholdSource'], equals('global'));
    });

    test('override cap silently drops past 1000 distinct names', () {
      for (var i = 0; i < 1000; i++) {
        detector.registerNameOverride('name-$i', maxConcurrent: 3);
      }
      expect(detector.snapshotNameOverrides(), hasLength(1000));
      // 1001st — silently dropped.
      detector.registerNameOverride('overflow', maxConcurrent: 3);
      expect(detector.snapshotNameOverrides(), hasLength(1000));
      expect(detector.snapshotNameOverrides().containsKey('overflow'), isFalse);
      expect(detector.droppedOverridesCount, equals(1));
      // Existing key update still works at cap.
      detector.registerNameOverride('name-0', maxConcurrent: 7);
      expect(
          detector.snapshotNameOverrides()['name-0']!.maxConcurrent, equals(7));
    });

    test('registerNameOverride while disabled lands; takes effect on re-enable',
        () {
      detector.isEnabled = false;
      detector.registerNameOverride('chat_socket', maxConcurrent: 3);
      expect(detector.snapshotNameOverrides()['chat_socket']!.maxConcurrent,
          equals(3));
      detector.isEnabled = true;
      // Track 4 → fires at override 3.
      final keep = <_Service>[];
      for (var i = 0; i < 4; i++) {
        final s = _Service(i);
        keep.add(s);
        detector.track('chat_socket', s);
      }
      detector.evaluateNowForTest();
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.extraTraceArgs!['effectiveMaxConcurrent'],
          equals('3'));
    });

    test(
        'per-axis acceptance: invalid maxConcurrent drops, valid '
        'longLivedSeconds lands', () {
      detector.registerNameOverride('foo',
          maxConcurrent: -1, longLivedSeconds: 600);
      final ov = detector.snapshotNameOverrides()['foo']!;
      expect(ov.maxConcurrent, isNull);
      expect(ov.longLivedSeconds, equals(600));
      expect(detector.droppedOverridesCount, equals(1));
    });

    test('per-axis acceptance: both invalid preserves prior override', () {
      detector.registerNameOverride('foo', maxConcurrent: 5);
      detector.registerNameOverride('foo',
          maxConcurrent: 0, longLivedSeconds: -1);
      // Both axes invalidated → preserve prior (no clear).
      expect(detector.snapshotNameOverrides()['foo']!.maxConcurrent, equals(5));
      expect(detector.droppedOverridesCount, equals(2));
    });

    test('single-axis typo preserves prior override (merge semantics)', () {
      detector.registerNameOverride('http_pool',
          maxConcurrent: 50, longLivedSeconds: 3600);
      // Typo: invalid maxConcurrent, longLivedSeconds omitted.
      detector.registerNameOverride('http_pool', maxConcurrent: -1);
      final ov = detector.snapshotNameOverrides()['http_pool']!;
      expect(ov.maxConcurrent, equals(50));
      expect(ov.longLivedSeconds, equals(3600));
      expect(detector.droppedOverridesCount, equals(1));
    });

    test('multi-call partial: long-then-max preserves both axes', () {
      detector.registerNameOverride('foo', longLivedSeconds: 600);
      detector.registerNameOverride('foo', maxConcurrent: 10);
      final ov = detector.snapshotNameOverrides()['foo']!;
      expect(ov.maxConcurrent, equals(10));
      expect(ov.longLivedSeconds, equals(600));
    });

    test('multi-call partial: max-then-long preserves both axes', () {
      detector.registerNameOverride('foo', maxConcurrent: 10);
      detector.registerNameOverride('foo', longLivedSeconds: 600);
      final ov = detector.snapshotNameOverrides()['foo']!;
      expect(ov.maxConcurrent, equals(10));
      expect(ov.longLivedSeconds, equals(600));
    });

    test('explicit both-null clears override (intentional)', () {
      detector.registerNameOverride('foo',
          maxConcurrent: 5, longLivedSeconds: 600);
      detector.registerNameOverride('foo'); // both args literally absent
      expect(detector.snapshotNameOverrides().containsKey('foo'), isFalse);
      expect(detector.droppedOverridesCount, equals(0));
    });

    test('LRU bucket eviction does NOT discard override', () {
      final smallDetector = TrackedResourceDetector(
        maxConcurrent: 5,
        longLivedSeconds: 300,
        maxDistinctNames: 2,
        sweepIntervalSeconds: 10,
        clock: () => fakeNow,
      );
      addTearDown(smallDetector.dispose);
      smallDetector.registerNameOverride('A', maxConcurrent: 3);
      smallDetector.track('A', _Service(0));
      smallDetector.track('B', _Service(1));
      smallDetector.track('C', _Service(2));
      // Bucket cap = 2 → at least one eviction.
      expect(smallDetector.evictedNamesCount, greaterThanOrEqualTo(1));
      // Override for 'A' still present.
      expect(
          smallDetector.snapshotNameOverrides()['A']!.maxConcurrent, equals(3));
      // Re-track 4 of 'A' → uses override (fires at 3, not global 5).
      final keep = <_Service>[];
      for (var i = 0; i < 4; i++) {
        final s = _Service(100 + i);
        keep.add(s);
        smallDetector.track('A', s);
      }
      smallDetector.evaluateNowForTest();
      final fires = smallDetector.issues
          .where((i) => i.stableId == 'tracked_resource_concurrent:A');
      expect(fires, hasLength(1));
      expect(
          fires.first.extraTraceArgs!['effectiveMaxConcurrent'], equals('3'));
    });
  });
}
