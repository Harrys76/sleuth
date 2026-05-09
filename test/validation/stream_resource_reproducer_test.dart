// Hermetic reproducer for `StreamResourceDetector`.
//
// Drives synthetic `AllocationProfile` responses through the detector
// via the `allocationProfileFetcherForTest` injection seam. Exercises
// the gating contract end-to-end:
//   1. Warmup window suppresses emission for [streamResourceWarmupSeconds].
//   2. Sample-rate gate enforces ≥[streamResourceSampleSeconds] between
//      polls.
//   3. Sliding K=4 window with ≥3 of 3 ascending transitions per class.
//   4. ≥2 watchlist classes growing AND netDelta > minDelta AND
//      heap_growing co-fire all required.
//   5. Cooldown holds dedupIdentityMicros stable for 3 cycles.
//
// Tier limitation: this reproducer mocks the AllocationProfile shape;
// real-VM dynamics (GC cadence interplay, true class-name format
// across SDK versions, library-URI population) are NOT exercised. A
// tier raise to runtimeVerified requires on-device class-instance
// capture infrastructure that does not exist yet — the current schema
// brackets a single observed-axis numeric magnitude (ms / bytes/sec /
// count) and does not yet model the multi-class delta axis this
// detector operates on.

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/stream_resource_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';
import 'package:vm_service/vm_service.dart';

AllocationProfile profileWith(
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
  group('StreamResourceDetector reproducer', () {
    late DateTime now;
    late List<AllocationProfile> profileQueue;
    late bool heapGrowing;
    late StreamResourceDetector detector;

    setUp(() {
      now = DateTime(2026, 5, 9, 12, 0, 0);
      profileQueue = [];
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
          if (profileQueue.isEmpty) return null;
          return profileQueue.removeAt(0);
        },
      );
    });

    Future<void> tickAndSettle() async {
      detector.processTimelineData(ParsedTimelineData());
      await Future<void>.delayed(Duration.zero);
    }

    void advance(Duration d) => now = now.add(d);

    test(
        'deliberate-leak harness fires stream_resource_growth.warning '
        'on co-fire', () async {
      // Drive 4 monotone-ascending samples for two watchlist classes.
      // Models a route that subscribes on every navigation and never
      // cancels: each tick adds 25 StreamSubscription + 15
      // _BroadcastSubscription, well above minDelta=50.
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      for (var i = 0; i < 4; i++) {
        profileQueue.add(profileWith({
          'StreamSubscription': 100 + i * 25,
          '_BroadcastSubscription': 50 + i * 15,
          'WebSocketChannel': 5,
        }));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.stableId, 'stream_resource_growth');
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.confidence, IssueConfidence.likely);
      expect(issue.category, IssueCategory.memory);
      expect(issue.observationSource, ObservationSource.vmTimeline);

      final args = issue.extraTraceArgs!;
      expect(args.keys.toSet(), {
        'topGrowthClass',
        'topGrowthDelta',
        'watchlistClassesGrowing',
        'samplesInWindow',
      });
      expect(args['samplesInWindow'], '4');
      expect(args['topGrowthClass'], 'StreamSubscription');
      expect(int.parse(args['topGrowthDelta']!), 75);
    });

    test('same growth pattern with heap_growing inactive does NOT emit',
        () async {
      heapGrowing = false;
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      for (var i = 0; i < 4; i++) {
        profileQueue.add(profileWith({
          'StreamSubscription': 100 + i * 25,
          '_BroadcastSubscription': 50 + i * 15,
        }));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      expect(detector.issues, isEmpty,
          reason: 'heap_growing co-fire gate suppresses emission');
    });

    test('flat (no growth) profile does NOT emit', () async {
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      for (var i = 0; i < 4; i++) {
        profileQueue.add(profileWith({
          'StreamSubscription': 100,
          '_BroadcastSubscription': 50,
        }));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      expect(detector.issues, isEmpty);
    });

    test('rxdart Subject family included only with rxdart library URI',
        () async {
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      for (var i = 0; i < 4; i++) {
        profileQueue.add(profileWith(
          {
            'StreamSubscription': 100 + i * 5,
            'PublishSubject': 100 + i * 25,
            'BehaviorSubject': 50 + i * 15,
          },
          libraryUriByClass: {
            'PublishSubject':
                'package:rxdart/src/subjects/publish_subject.dart',
            'BehaviorSubject':
                'package:rxdart/src/subjects/behavior_subject.dart',
          },
        ));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      expect(detector.issues, hasLength(1));
      final args = detector.issues.first.extraTraceArgs!;
      expect(args['topGrowthClass'], 'PublishSubject');
      expect(args['watchlistClassesGrowing'], contains('PublishSubject'));
      expect(args['watchlistClassesGrowing'], contains('BehaviorSubject'));
    });

    test('cooldown collapses successive overage to one dedup identity',
        () async {
      await tickAndSettle();
      advance(const Duration(seconds: 25));
      for (var i = 0; i < 4; i++) {
        profileQueue.add(profileWith({
          'StreamSubscription': 100 + i * 25,
          '_BroadcastSubscription': 50 + i * 15,
        }));
        await tickAndSettle();
        advance(const Duration(seconds: 10));
      }
      final firstId = detector.issues.first.dedupIdentityMicros;
      // Wall-clock cooldown is 30s. Re-emit within window preserves
      // dedup identity so the controller composite-key dedup
      // collapses successive fires to one trace record.
      profileQueue.add(profileWith({
        'StreamSubscription': 200,
        '_BroadcastSubscription': 100,
      }));
      advance(const Duration(seconds: 10));
      await tickAndSettle();
      expect(detector.issues.first.dedupIdentityMicros, firstId);
    });
  });
}
