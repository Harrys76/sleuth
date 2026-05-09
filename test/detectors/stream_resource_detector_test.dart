import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/stream_resource_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:vm_service/vm_service.dart';

import '../helpers/timeline_test_helpers.dart';

/// Builds a fake [AllocationProfile] with the given (className → instance
/// count) pairs. Optional [libraryUriByClass] supplies library URIs so the
/// rxdart-suffix gate can be exercised.
AllocationProfile _profile(
  Map<String, int> instances, {
  Map<String, String>? libraryUriByClass,
}) {
  final members = instances.entries.map((e) {
    final libUri = libraryUriByClass?[e.key] ?? _defaultLibraryUri(e.key);
    return ClassHeapStats(
      classRef: ClassRef(
        id: 'class/${e.key}',
        name: e.key,
        library: LibraryRef(id: 'lib/$libUri', name: e.key, uri: libUri),
      ),
      instancesCurrent: e.value,
    );
  }).toList();
  return AllocationProfile(members: members);
}

String _defaultLibraryUri(String className) {
  if (className.endsWith('_WebSocketImpl')) return 'dart:io';
  if (className.endsWith('WebSocketChannel')) {
    return 'package:web_socket_channel/web_socket_channel.dart';
  }
  return 'dart:async';
}

void main() {
  group('StreamResourceDetector', () {
    late DateTime now;
    late List<AllocationProfile> profileQueue;
    late int profilesFetched;
    late bool heapGrowing;
    late StreamResourceDetector detector;

    setUp(() {
      now = DateTime(2026, 5, 9, 12, 0, 0);
      profileQueue = [];
      profilesFetched = 0;
      heapGrowing = true;
      detector = StreamResourceDetector(
        vmClient: null,
        heapGrowingStateProvider: () => heapGrowing,
        clock: () => now,
        sampleSeconds: 10,
        minDelta: 50,
        warmupSeconds: 20,
        windowSize: 4,
        allocationProfileFetcherForTest: () async {
          profilesFetched++;
          if (profileQueue.isEmpty) return null;
          return profileQueue.removeAt(0);
        },
      );
    });

    void advance(Duration d) {
      now = now.add(d);
    }

    Future<void> tickAndSettle() async {
      detector.processTimelineData(emptyTimelineData());
      // Allow the unawaited poll future to resolve.
      await Future<void>.delayed(Duration.zero);
    }

    /// Drives a 4-sample monotonically increasing window for two
    /// watchlist classes plus enough total delta to clear the
    /// minDelta threshold.
    Future<void> driveGrowthWindow({
      int? warmupSkipMicros,
    }) async {
      // Warmup: first tick stamps `_activatedAtMicros` but is suppressed.
      await tickAndSettle();
      advance(Duration(seconds: warmupSkipMicros ?? 25));
      // Now drive 4 samples at 10 s cadence.
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile({
          'StreamSubscription': 100 + i * 30,
          '_BroadcastSubscription': 50 + i * 10,
        }));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
    }

    test('warmup suppresses emission before window elapsed', () async {
      // Initial tick activates the detector; subsequent tick within
      // warmup must not emit.
      await tickAndSettle();
      advance(const Duration(seconds: 5));
      profileQueue.add(_profile({
        'StreamSubscription': 200,
        '_BroadcastSubscription': 100,
      }));
      await tickAndSettle();
      expect(detector.issues, isEmpty);
      expect(profilesFetched, 0,
          reason: 'No profile fetched while in warmup window');
    });

    test('sample-rate gate skips poll within sampleSeconds', () async {
      // First post-warmup tick fetches a profile.
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      profileQueue.add(_profile({'StreamSubscription': 100}));
      await tickAndSettle();
      final after1 = profilesFetched;
      // Same timestamp re-tick must not fetch.
      await tickAndSettle();
      expect(profilesFetched, after1);
      // Advance only 5 s — still under sampleSeconds=10.
      advance(const Duration(seconds: 5));
      await tickAndSettle();
      expect(profilesFetched, after1);
    });

    test('does not emit with single growing class', () async {
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile({'StreamSubscription': 100 + i * 30}));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      expect(detector.issues, isEmpty,
          reason: 'Single growing class fails the ≥2 watchlist gate');
    });

    test('does not emit when heap_growing inactive', () async {
      heapGrowing = false;
      await driveGrowthWindow();
      expect(detector.issues, isEmpty);
    });

    test('does not emit when sum of deltas below minDelta', () async {
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile({
          'StreamSubscription': 100 + i * 5,
          '_BroadcastSubscription': 50 + i * 5,
        }));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      // Total net delta = (115-100) + (65-50) = 15 + 15 = 30 < 50.
      expect(detector.issues, isEmpty);
    });

    test('emits warning with confidence likely on co-fire', () async {
      await driveGrowthWindow();
      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.stableId, 'stream_resource_growth');
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.category, IssueCategory.memory);
    });

    test('emission stamps all four extraTraceArgs keys', () async {
      await driveGrowthWindow();
      final args = detector.issues.first.extraTraceArgs!;
      expect(args.keys.toSet(), {
        'topGrowthClass',
        'topGrowthDelta',
        'watchlistClassesGrowing',
        'samplesInWindow'
      });
      expect(args['samplesInWindow'], '4');
      // Delta is non-negative integer-as-string.
      expect(int.parse(args['topGrowthDelta']!), greaterThan(0));
      // topGrowthClass is one of the watchlist suffixes.
      expect(
        ['StreamSubscription', '_BroadcastSubscription'],
        contains(args['topGrowthClass']),
      );
    });

    test('cooldown re-emits with stable dedupIdentityMicros within window',
        () async {
      await driveGrowthWindow();
      final firstId = detector.issues.first.dedupIdentityMicros;
      // Wall-clock cooldown is 30s by default. Initial emission lands
      // at T0+55 with cooldown expiry T0+85. Re-emit at T0+75 falls
      // inside the cooldown window and preserves dedup identity.
      profileQueue.add(_profile({
        'StreamSubscription': 1000,
        '_BroadcastSubscription': 1000,
      }));
      advance(const Duration(seconds: 10));
      await tickAndSettle();
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.dedupIdentityMicros, firstId);
    });

    test('cooldown re-emit refreshes detectedAt while preserving dedup id',
        () async {
      await driveGrowthWindow();
      final firstIssue = detector.issues.first;
      final firstDetectedAt = firstIssue.detectedAt;
      final firstId = firstIssue.dedupIdentityMicros;
      profileQueue.add(_profile({
        'StreamSubscription': 1000,
        '_BroadcastSubscription': 1000,
      }));
      advance(const Duration(seconds: 10));
      await tickAndSettle();
      final reemittedIssue = detector.issues.first;
      expect(reemittedIssue.dedupIdentityMicros, firstId,
          reason: 'dedup identity stable across cooldown re-emit');
      expect(reemittedIssue.detectedAt!.isAfter(firstDetectedAt!), isTrue,
          reason: 'detectedAt refreshed so UI does not show a stale stamp');
    });

    test('strict ≥3 of 3 ascending — non-monotone window does not emit',
        () async {
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      // Ascending values: [100, 110, 105, 115] for class A — only 2 of 3
      // ascending transitions (100→110 ascend, 110→105 descend, 105→115
      // ascend). Should NOT qualify.
      final aSeries = [100, 110, 105, 115];
      final bSeries = [50, 60, 70, 80];
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile({
          'StreamSubscription': aSeries[i],
          '_BroadcastSubscription': bSeries[i],
        }));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      // Only B qualifies → < 2 growing → no emission.
      expect(detector.issues, isEmpty);
    });

    test('VmService null fetcher returns increments backoff after 3 nulls',
        () async {
      // Profile queue empty → fetcher returns null.
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      // 3 null returns trigger backoff.
      for (var i = 0; i < 3; i++) {
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      // Next eligible tick should be skipped due to backoff (60 s).
      final beforeBackoffSkip = profilesFetched;
      profileQueue.add(_profile({
        'StreamSubscription': 100,
        '_BroadcastSubscription': 50,
      }));
      advance(const Duration(seconds: 10));
      await tickAndSettle();
      expect(profilesFetched, beforeBackoffSkip,
          reason: 'Backoff window suppresses poll');
      // Advance past backoff.
      advance(const Duration(seconds: 60));
      await tickAndSettle();
      expect(profilesFetched, greaterThan(beforeBackoffSkip));
    });

    test('_HttpClientStreamSubscription (dart:io HTTP) does NOT match',
        () async {
      // dart:io's _HttpClientStreamSubscription ends with
      // 'StreamSubscription' but is HTTP-internal and self-cancels on
      // response completion. The dart:io library gate excludes it
      // from the watchlist so network-heavy apps do not trip the gate.
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile(
          {
            '_HttpClientStreamSubscription': 100 + i * 30,
            'StreamSubscription': 50 + i * 15,
          },
          libraryUriByClass: {
            '_HttpClientStreamSubscription': 'dart:io',
            'StreamSubscription': 'dart:async',
          },
        ));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      // Only StreamSubscription qualifies (HTTP subscription excluded)
      // → single growing class fails ≥2 gate.
      expect(detector.issues, isEmpty);
    });

    test('cooldown is wall-clock-bounded — expires after cooldownSeconds',
        () async {
      await driveGrowthWindow();
      expect(detector.issues, hasLength(1));
      // Advance well beyond cooldown (default 30s).
      advance(const Duration(seconds: 60));
      // Tick with empty profile queue — fetcher returns null, but
      // wall-clock cooldown expiry runs in processTimelineData itself.
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty,
          reason: 'Wall-clock cooldown lapsed; retained issue should clear');
    });

    test('rxdart suffix matched only when library URI contains rxdart',
        () async {
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      // Watchlist core class growing slowly; rxdart class growing fast
      // with rxdart library URI.
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile(
          {
            'StreamSubscription': 100 + i,
            'PublishSubject': 100 + i * 30,
          },
          libraryUriByClass: {
            'PublishSubject':
                'package:rxdart/src/subjects/publish_subject.dart',
          },
        ));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      // Both qualify (both ascending), netDelta well over 50.
      expect(detector.issues, hasLength(1));
      final args = detector.issues.first.extraTraceArgs!;
      expect(args['watchlistClassesGrowing'], contains('PublishSubject'));
    });

    test(
        'rxdart suffix excluded when same class name comes from non-rxdart library',
        () async {
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile(
          {
            'StreamSubscription': 100 + i,
            'PublishSubject': 100 + i * 30,
          },
          libraryUriByClass: {
            'PublishSubject': 'package:my_app/publish_subject.dart',
          },
        ));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      // Only StreamSubscription qualifies (and barely) — single growing
      // class fails ≥2 gate.
      expect(detector.issues, isEmpty);
    });

    test('resetCaptureState clears window and re-engages warmup', () async {
      await driveGrowthWindow();
      expect(detector.issues, hasLength(1));
      detector.resetCaptureState();
      expect(detector.issues, isEmpty);
      // Immediate post-reset tick stamps fresh activation but is in
      // warmup again — no emission even with full ascending window.
      profileQueue.add(_profile({
        'StreamSubscription': 1000,
        '_BroadcastSubscription': 1000,
      }));
      await tickAndSettle();
      advance(const Duration(seconds: 5));
      await tickAndSettle();
      expect(detector.issues, isEmpty);
    });

    test('disabled detector does not poll or emit', () async {
      detector.isEnabled = false;
      profileQueue.add(_profile({
        'StreamSubscription': 100,
        '_BroadcastSubscription': 100,
      }));
      advance(const Duration(seconds: 60));
      await tickAndSettle();
      expect(profilesFetched, 0);
      expect(detector.issues, isEmpty);
    });

    test('disappearing class ages out and does NOT re-fire after cooldown',
        () async {
      // Drive emission with [StreamSubscription, _BroadcastSubscription]
      // both growing.
      await driveGrowthWindow();
      expect(detector.issues, hasLength(1));

      // User fixes the leak: the leaking class is GC'd and no longer
      // appears in subsequent profiles. Send only an unrelated class.
      // The window should append 0 for the absent suffix on each poll
      // until the ascending evidence ages out.
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile({
          'WebSocketChannel': 1,
        }, libraryUriByClass: {
          'WebSocketChannel':
              'package:web_socket_channel/web_socket_channel.dart',
        }));
        advance(const Duration(seconds: 10));
        await tickAndSettle();
      }

      // Advance well past cooldown (default 30s).
      advance(const Duration(seconds: 60));
      profileQueue.add(_profile({
        'WebSocketChannel': 1,
      }, libraryUriByClass: {
        'WebSocketChannel':
            'package:web_socket_channel/web_socket_channel.dart',
      }));
      await tickAndSettle();
      expect(detector.issues, isEmpty,
          reason: 'Stale ascending window must age out via 0-fill samples '
              'so a fixed leak does not re-fire after cooldown lapses.');
    });

    test(
        'per-poll aggregation across multiple classes-per-suffix produces '
        'stable windowing', () async {
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      // Two distinct classes, both ending in 'StreamSubscription', both
      // from dart:async. Per-poll aggregation should sum their counts
      // into ONE sample per poll, not append two samples.
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile(
          {
            'MyAStreamSubscription': 100 + i * 10,
            'MyBStreamSubscription': 50 + i * 5,
            // Add a second growing suffix so the ≥2-classes gate fires.
            '_BroadcastSubscription': 30 + i * 10,
          },
          libraryUriByClass: {
            'MyAStreamSubscription': 'dart:async',
            'MyBStreamSubscription': 'dart:async',
            '_BroadcastSubscription': 'dart:async',
          },
        ));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      expect(detector.issues, hasLength(1));
      final args = detector.issues.first.extraTraceArgs!;
      // topGrowthDelta for StreamSubscription should be the SUM delta:
      // last (130 + 65) - first (100 + 50) = 195 - 150 = 45.
      // _BroadcastSubscription delta = (60 - 30) = 30.
      // StreamSubscription beats _BroadcastSubscription on delta.
      expect(args['topGrowthClass'], 'StreamSubscription');
      expect(args['topGrowthDelta'], '45');
      expect(args['samplesInWindow'], '4');
    });

    test(
        'longest-suffix match — _SyncBroadcastStreamController matches '
        '_SyncBroadcastStreamController, not StreamController', () async {
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile(
          {
            '_SyncBroadcastStreamController': 100 + i * 25,
            '_BroadcastSubscription': 50 + i * 15,
          },
          libraryUriByClass: {
            '_SyncBroadcastStreamController': 'dart:async',
            '_BroadcastSubscription': 'dart:async',
          },
        ));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      expect(detector.issues, hasLength(1));
      final args = detector.issues.first.extraTraceArgs!;
      final growingSet = args['watchlistClassesGrowing']!.split(',').toSet();
      expect(growingSet, contains('_SyncBroadcastStreamController'),
          reason:
              'Longest-match must select the specific suffix, not the generic StreamController bucket.');
      expect(growingSet, isNot(contains('StreamController')),
          reason:
              'Generic StreamController bucket must NOT capture _SyncBroadcastStreamController.');
    });

    test(
        'after cooldown lapse + gate failure, second emission gets a fresh '
        'dedupIdentityMicros', () async {
      // Drive emission. Cooldown active.
      await driveGrowthWindow();
      expect(detector.issues, hasLength(1));
      final firstId = detector.issues.first.dedupIdentityMicros;

      // Advance past cooldown (default 30s) plus enough for the
      // window to slide.
      advance(const Duration(seconds: 60));

      // Drive a non-growing poll so the lapse-clear runs and the
      // fresh-eval gate fails (window has stale 0-fill from absent
      // classes by now).
      profileQueue.add(_profile({
        'WebSocketChannel': 1,
      }, libraryUriByClass: {
        'WebSocketChannel':
            'package:web_socket_channel/web_socket_channel.dart',
      }));
      await tickAndSettle();
      expect(detector.issues, isEmpty,
          reason:
              'Lapse + gate-failure must clear all retained emission state.');

      // Drive a fresh growing window. Emission must land with a NEW
      // dedupIdentityMicros (not a stale value from prior emission).
      for (var i = 0; i < 4; i++) {
        profileQueue.add(_profile({
          'StreamSubscription': 2000 + i * 30,
          '_BroadcastSubscription': 1000 + i * 15,
        }));
        advance(const Duration(seconds: 10));
        await tickAndSettle();
      }
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.dedupIdentityMicros, isNot(firstId),
          reason: 'Fresh emission must have a new dedupIdentityMicros, '
              'not be suppressed or labelled with the original cooldown identity.');
    });

    test('vmConnected=false clears retained state', () async {
      await driveGrowthWindow();
      expect(detector.issues, hasLength(1));
      detector.vmConnected = false;
      expect(detector.issues, isEmpty);
    });
  });
}
