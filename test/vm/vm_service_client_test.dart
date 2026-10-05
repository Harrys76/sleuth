import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:sleuth/src/analyzer/frame_event_correlator.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/heap_sample.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';

void main() {
  group('idle heartbeat', () {
    Timeline emptyTimeline() =>
        Timeline(traceEvents: [], timeOriginMicros: 0, timeExtentMicros: 0);

    test('an empty batch is dispatched once per heartbeat', () async {
      final batches = <ParsedTimelineData>[];
      final mock = _MockVmService()..timelineResult = emptyTimeline();
      final client = VmServiceClient(
        onTimelineData: batches.add,
        idleHeartbeat: const Duration(hours: 1),
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();
      await client.pollTimelineSync();
      await client.pollTimelineSync();

      // First poll always dispatches; the next two fall inside the window.
      expect(batches, hasLength(1));
      expect(batches.single.hasData, isFalse);
      client.dispose();
    });

    test('a zero heartbeat dispatches every empty batch', () async {
      final batches = <ParsedTimelineData>[];
      final mock = _MockVmService()..timelineResult = emptyTimeline();
      final client = VmServiceClient(
        onTimelineData: batches.add,
        idleHeartbeat: Duration.zero,
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();
      await client.pollTimelineSync();

      expect(batches, hasLength(2));
      expect(batches.every((b) => !b.hasData), isTrue);
      client.dispose();
    });
  });

  group('candidateWebSocketUris', () {
    test('loopback literal becomes localhost only', () {
      final uris = VmServiceClient.candidateWebSocketUris(
        Uri.parse('ws://127.0.0.1:51475/abc=/ws'),
      );
      expect(uris.map((u) => u.toString()), ['ws://localhost:51475/abc=/ws']);
    });

    test('localhost stays a single candidate', () {
      final uris = VmServiceClient.candidateWebSocketUris(
        Uri.parse('ws://localhost:1234/ws'),
      );
      expect(uris, hasLength(1));
      expect(uris.single.host, 'localhost');
    });

    test('an interface address tries loopback first, then itself', () {
      final uris = VmServiceClient.candidateWebSocketUris(
        Uri.parse('ws://192.168.1.5:51475/Oflj8eqwiDI=/ws'),
      );
      expect(uris.map((u) => u.toString()), [
        'ws://localhost:51475/Oflj8eqwiDI=/ws',
        'ws://192.168.1.5:51475/Oflj8eqwiDI=/ws',
      ]);
    });

    test('port and auth path survive the host swap', () {
      final uri = VmServiceClient.candidateWebSocketUris(
        Uri.parse('ws://10.0.2.2:9999/tok=/ws'),
      ).first;
      expect(uri.port, 9999);
      expect(uri.path, '/tok=/ws');
    });
  });

  // =========================================================================
  // 1. Constructor & default state
  // =========================================================================
  group('VmServiceClient constructor', () {
    test('starts not connected and not disposed', () {
      final client = VmServiceClient();
      expect(client.isConnected, isFalse);
      expect(client.isDisposed, isFalse);
      client.dispose();
    });

    test('accepts all optional callbacks', () {
      final client = VmServiceClient(
        onTimelineData: (_) {},
        onGcEvent: (_) {},
        onHeapSample: (_) {},
        onExtensionEvent: (_) {},
        onConnectionChanged: (_) {},
      );
      expect(client.isConnected, isFalse);
      client.dispose();
    });
  });

  // =========================================================================
  // 2. Dispose behavior
  // =========================================================================
  group('VmServiceClient dispose', () {
    test('sets isDisposed to true', () {
      final client = VmServiceClient();
      client.dispose();
      expect(client.isDisposed, isTrue);
    });

    test('sets isConnected to false', () {
      final client = VmServiceClient();
      client.setServiceForTest(_MockVmService(), isolateId: 'isolate-1');
      expect(client.isConnected, isTrue);
      client.dispose();
      expect(client.isConnected, isFalse);
    });

    test('double dispose does not throw', () {
      final client = VmServiceClient();
      client.dispose();
      expect(() => client.dispose(), returnsNormally);
    });
  });

  // =========================================================================
  // 3. getCpuSamples
  // =========================================================================
  group('getCpuSamples', () {
    test('returns null when service is null', () async {
      final client = VmServiceClient();
      final result = await client.getCpuSamples(
        timeOriginUs: 0,
        timeExtentUs: 1000,
      );
      expect(result, isNull);
      client.dispose();
    });

    test('returns null when isolateId is null', () async {
      final client = VmServiceClient();
      client.setServiceForTest(_MockVmService());
      final result = await client.getCpuSamples(
        timeOriginUs: 0,
        timeExtentUs: 1000,
      );
      expect(result, isNull);
      client.dispose();
    });

    test('returns CpuSamples on success', () async {
      final mock = _MockVmService();
      mock.cpuSamplesResult = CpuSamples(
        sampleCount: 3,
        samplePeriod: 100,
        maxStackDepth: 128,
        timeOriginMicros: 0,
        timeExtentMicros: 1000,
        pid: 1,
        functions: [],
        samples: [],
      );

      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      final result = await client.getCpuSamples(
        timeOriginUs: 0,
        timeExtentUs: 1000,
      );
      expect(result, isNotNull);
      expect(result!.sampleCount, 3);
      client.dispose();
    });

    test('returns null on SentinelException', () async {
      final mock = _MockVmService();
      mock.cpuSamplesThrows = SentinelException.parse(
        'isolate-1',
        <String, dynamic>{
          'type': 'Sentinel',
          'kind': 'Collected',
          'valueAsString': 'test',
        },
      );

      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      final result = await client.getCpuSamples(
        timeOriginUs: 0,
        timeExtentUs: 1000,
      );
      expect(result, isNull);
      client.dispose();
    });

    test('returns null on generic error', () async {
      final mock = _MockVmService();
      mock.cpuSamplesThrows = Exception('connection lost');

      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      final result = await client.getCpuSamples(
        timeOriginUs: 0,
        timeExtentUs: 1000,
      );
      expect(result, isNull);
      client.dispose();
    });

    test('returns null on timeout (500ms)', () async {
      final mock = _MockVmService();
      mock.cpuSamplesDelay = const Duration(seconds: 2);
      mock.cpuSamplesResult = CpuSamples(
        sampleCount: 0,
        samplePeriod: 100,
        maxStackDepth: 128,
        timeOriginMicros: 0,
        timeExtentMicros: 1000,
        pid: 1,
        functions: [],
        samples: [],
      );

      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      final result = await client.getCpuSamples(
        timeOriginUs: 0,
        timeExtentUs: 1000,
      );
      expect(result, isNull);
      client.dispose();
    });
  });

  group('getCpuSamples rate limit', () {
    test('a second request while one is in flight is not issued', () async {
      final mock = _MockVmService()
        ..cpuSamplesDelay = const Duration(milliseconds: 100);
      final client = VmServiceClient(cpuSamplesMinInterval: Duration.zero);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      final first = client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1);
      final second = await client.getCpuSamples(
        timeOriginUs: 0,
        timeExtentUs: 1,
      );
      expect(second, isNull);
      expect(await first, isNotNull);
      expect(mock.getCpuSamplesCallCount, 1);

      // Once the first answered, the next request goes out.
      expect(
        await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1),
        isNotNull,
      );
      expect(mock.getCpuSamplesCallCount, 2);
      client.dispose();
    });

    test('a timed-out request blocks the next one until the VM '
        'answers', () async {
      final mock = _MockVmService()
        ..cpuSamplesDelay = const Duration(milliseconds: 800);
      final client = VmServiceClient(cpuSamplesMinInterval: Duration.zero);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      expect(
        await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1),
        isNull,
      );
      expect(
        await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1),
        isNull,
      );
      expect(mock.getCpuSamplesCallCount, 1);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      mock.cpuSamplesDelay = null;
      expect(
        await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1),
        isNotNull,
      );
      expect(mock.getCpuSamplesCallCount, 2);
      client.dispose();
    });

    test('requests are spaced by the minimum interval', () async {
      final mock = _MockVmService();
      final client = VmServiceClient(
        cpuSamplesMinInterval: const Duration(milliseconds: 200),
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      expect(
        await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1),
        isNotNull,
      );
      expect(
        await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1),
        isNull,
      );
      expect(mock.getCpuSamplesCallCount, 1);

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1),
        isNotNull,
      );
      expect(mock.getCpuSamplesCallCount, 2);
      client.dispose();
    });

    test('an unanswered request older than the stale limit no longer '
        'blocks the next one', () async {
      final mock = _MockVmService()..cpuSamplesNeverCompletes = true;
      var nowUs = 0;
      final client = VmServiceClient(cpuSamplesMinInterval: Duration.zero)
        ..rpcClockForTest = () => nowUs;
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      expect(
        await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1),
        isNull,
      );
      expect(mock.getCpuSamplesCallCount, 1);

      nowUs = VmServiceClient.cpuSamplesInFlightStaleAfter.inMicroseconds;
      expect(
        await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1),
        isNull,
      );
      expect(mock.getCpuSamplesCallCount, 1);

      nowUs += 1;
      expect(
        await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1),
        isNull,
      );
      expect(mock.getCpuSamplesCallCount, 2);
      client.dispose();
    });

    test('the stale limit is 30 s', () {
      expect(
        VmServiceClient.cpuSamplesInFlightStaleAfter,
        const Duration(seconds: 30),
      );
    });

    test('the default interval is 10 s', () {
      expect(
        VmServiceClient().cpuSamplesMinInterval,
        const Duration(seconds: 10),
      );
    });
  });

  // =========================================================================
  // 3b. getAllocationProfile
  // =========================================================================
  group('getAllocationProfile', () {
    test('returns null when service is null', () async {
      final client = VmServiceClient();
      final result = await client.getAllocationProfile();
      expect(result, isNull);
      client.dispose();
    });

    test('returns null when isolateId is null', () async {
      final client = VmServiceClient();
      client.setServiceForTest(_MockVmService());
      final result = await client.getAllocationProfile();
      expect(result, isNull);
      client.dispose();
    });

    test('returns AllocationProfile on success', () async {
      final mock = _MockVmService();
      mock.allocationProfileResult = AllocationProfile(
        members: [
          ClassHeapStats(
            classRef: ClassRef(
              id: 'class-1',
              name: 'MyWidget',
              library: LibraryRef(
                id: 'lib-1',
                name: 'my_app',
                uri: 'package:my_app/widgets/my_widget.dart',
              ),
            ),
            bytesCurrent: 50000,
            instancesCurrent: 100,
          ),
        ],
      );

      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      final result = await client.getAllocationProfile(reset: true);
      expect(result, isNotNull);
      expect(result!.members, hasLength(1));
      expect(mock.getAllocationProfileCalled, isTrue);
      client.dispose();
    });

    test('returns null on SentinelException', () async {
      final mock = _MockVmService();
      mock.allocationProfileThrows = SentinelException.parse(
        'isolate-1',
        <String, dynamic>{
          'type': 'Sentinel',
          'kind': 'Collected',
          'valueAsString': 'test',
        },
      );

      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      final result = await client.getAllocationProfile();
      expect(result, isNull);
      client.dispose();
    });

    test('returns null on timeout (500ms)', () async {
      final mock = _MockVmService();
      mock.allocationProfileDelay = const Duration(seconds: 2);
      mock.allocationProfileResult = AllocationProfile(members: []);

      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      final result = await client.getAllocationProfile();
      expect(result, isNull);
      client.dispose();
    });
  });

  // =========================================================================
  // 4. Timeline polling
  // =========================================================================
  group('Timeline polling', () {
    test('poll invokes onTimelineData callback', () async {
      final receivedData = <ParsedTimelineData>[];
      final mock = _MockVmService();
      mock.timelineResult = Timeline(
        traceEvents: [
          TimelineEvent.parse({
            'name': 'VSYNC',
            'cat': 'Embedder',
            'ph': 'X',
            'dur': 1000,
            'ts': 100000,
            'pid': 1,
            'tid': 1,
          })!,
        ],
        timeOriginMicros: 100000,
        timeExtentMicros: 1000,
      );

      final client = VmServiceClient(onTimelineData: receivedData.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      // Timeline data should be parsed and forwarded
      // (may be empty if the mock event isn't recognized by TimelineParser)
      expect(mock.getVMTimelineCalled, isTrue);
      expect(mock.clearVMTimelineCalled, isFalse);
      client.dispose();
    });

    test('poll never clears the timeline buffer', () async {
      final mock = _MockVmService();
      mock.timelineResult = Timeline(
        traceEvents: [],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );

      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();
      await client.pollTimelineSync();
      expect(mock.clearVMTimelineCalled, isFalse);
      client.dispose();
    });

    test('poll does nothing when disposed', () async {
      final mock = _MockVmService();
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      client.dispose();

      await client.pollTimelineSync();
      expect(mock.getVMTimelineCalled, isFalse);
    });

    test(
      'pollTimelineSync barrier waits for in-flight poll then forces fresh',
      () async {
        // Capture-flow `Sleuth.flushTimelineNow` MUST guarantee a fresh
        // VM-poll observation before returning, even when a periodic
        // poll is already in flight. Without barrier semantics, the
        // periodic poll's snapshot may pre-date the BUILD the capture
        // flow wants to observe, and the issue trace event lands outside
        // the scenario span.
        //
        // Verifies: two concurrent pollTimelineSync calls produce TWO
        // getVMTimeline invocations on the mock — the second waits for
        // the first to complete, then runs fresh. (Previous v0.18.1
        // behaviour short-circuited the second call; v0.18.2 changes
        // this to barrier semantics for capture-flow correctness.)
        final mock = _MockVmService();
        mock.timelineResult = Timeline(
          traceEvents: [],
          timeOriginMicros: 0,
          timeExtentMicros: 0,
        );
        mock.getVMTimelineDelay = const Duration(milliseconds: 50);
        final client = VmServiceClient();
        client.setServiceForTest(mock, isolateId: 'isolate-1');

        final first = client.pollTimelineSync();
        // Second call lands while first is awaiting getVMTimeline.
        final second = client.pollTimelineSync();
        await Future.wait([first, second]);

        expect(
          mock.getVMTimelineCallCount,
          2,
          reason:
              'Barrier must run a fresh poll after the in-flight one '
              'completes — capture flow needs guaranteed-fresh observation '
              'before markScenarioEnd fires.',
        );
        client.dispose();
      },
    );

    test('cross-batch BUILD reconstruction on the default polling '
        'path', () async {
      // iOS profile mode emits BUILD as `ph: 'B'` / `ph: 'E'` pairs
      // instead of `ph: 'X'` complete-form. When a poll boundary falls
      // between the B and the E, the parser needs `_pendingBuildBegins`
      // to carry the unmatched B from batch N into batch N+1 so dur can
      // be reconstructed.
      final received = <ParsedTimelineData>[];
      final mock = _MockVmService();
      // Batch 1: BUILD begin only (no matching end in this batch).
      mock.timelineResult = Timeline(
        traceEvents: [
          TimelineEvent.parse({
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'B',
            'ts': 100000,
            'pid': 1,
            'tid': 1,
          })!,
        ],
        timeOriginMicros: 100000,
        timeExtentMicros: 1000,
      );
      final client = VmServiceClient(onTimelineData: received.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();
      expect(
        mock.clearVMTimelineCalled,
        isFalse,
        reason: 'The poll loop never clears the VM buffer.',
      );
      expect(
        received.expand((p) => p.buildScopeDurations),
        isEmpty,
        reason: 'Batch 1 has B without E; no dur reconstructed yet.',
      );

      // Batch 2: matching BUILD end. The B from batch 1 must still be
      // in `_pendingBuildBegins` for reconstruction to work.
      mock.clearVMTimelineCalled = false;
      mock.timelineResult = Timeline(
        traceEvents: [
          TimelineEvent.parse({
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'E',
            'ts': 105000,
            'pid': 1,
            'tid': 1,
          })!,
        ],
        timeOriginMicros: 105000,
        timeExtentMicros: 1000,
      );

      await client.pollTimelineSync();
      final allBuildDurs = received
          .expand((p) => p.buildScopeDurations)
          .toList();
      expect(
        allBuildDurs,
        equals([5000]),
        reason:
            'Cross-batch reconstruction must emit dur = E.ts - B.ts '
            '(5000 us) on the default polling path. Wiping '
            '_pendingBuildBegins between polls would silently drop '
            'this BUILD.',
      );
      client.dispose();
    });

    test('capture-mode buffer re-read does not inflate counters across '
        'polls (E2E watermark dedup)', () async {
      // Capture mode (`retainTimeline=true`) skips `clearVMTimeline()`
      // so the VM keeps returning the FULL retained buffer on every
      // poll. Without per-tid `lastProcessedTsByTid` watermark threaded
      // through the parser, every prior event is re-processed:
      //   - `buildEventCount` triples
      //   - `buildScopeDurations` accumulates duplicates
      //   - `gcEvents` / `platformChannelEvents` inflate
      // RebuildDetector reads `data.buildEventCount` raw (no producer
      // dedup), so this end-to-end test pins that 3 polls of the same
      // buffer yield each event ONCE per real occurrence — not 3×.
      final received = <ParsedTimelineData>[];
      final mock = _MockVmService();
      mock.timelineResult = Timeline(
        traceEvents: [
          TimelineEvent.parse({
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'X',
            'dur': 1000,
            'ts': 100000,
            'pid': 1,
            'tid': 1,
          })!,
          TimelineEvent.parse({
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'X',
            'dur': 1500,
            'ts': 200000,
            'pid': 1,
            'tid': 1,
          })!,
        ],
        timeOriginMicros: 100000,
        timeExtentMicros: 100000,
      );
      final client = VmServiceClient(
        retainTimeline: true,
        onTimelineData: received.add,
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      // Three polls of the SAME buffer (simulates capture-mode re-read).
      await client.pollTimelineSync();
      await client.pollTimelineSync();
      await client.pollTimelineSync();

      expect(
        mock.clearVMTimelineCalled,
        isFalse,
        reason: 'The poll loop never clears the VM buffer.',
      );
      // Aggregate across all onTimelineData callbacks.
      final allDurs = received.expand((p) => p.buildScopeDurations).toList();
      final totalBuildCount = received.fold<int>(
        0,
        (sum, p) => sum + p.buildEventCount,
      );
      expect(
        allDurs,
        equals([1000, 1500]),
        reason:
            '2 real BUILDs across 3 polls must yield 2 dur entries '
            '(not 6). Watermark dedup must skip re-observed events.',
      );
      expect(
        totalBuildCount,
        2,
        reason:
            'buildEventCount must equal real BUILDs (2), not 3× '
            '(6). RebuildDetector consumes this raw and would '
            'false-positive without the watermark.',
      );
      client.dispose();
    });

    test('cursor sweep evicts tids idle past the 30s ceiling so '
        'long-lived sessions with churning tids do not leak', () async {
      final mock = _MockVmService();
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      // Poll 1: tid=1 event at ts=1000. Cursor: tid=1 → lastTs=1000.
      mock.timelineResult = Timeline(
        traceEvents: [_build(1000, tid: 1)],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );
      await client.pollTimelineSync();
      expect(client.cursorsForTest.keys, [1]);

      // Poll 2: tid=2 event at ts=31_000_001 (>30s past ts=1000).
      // Anchor=31_000_001 → cursor cutoff = 1_000_001 → tid=1 cursor
      // (lastTs=1000) is evicted in both modes.
      mock.timelineResult = Timeline(
        traceEvents: [_build(1000, tid: 1), _build(31000001, tid: 2)],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );
      await client.pollTimelineSync();
      expect(client.cursorsForTest.keys, [2]);
      client.dispose();
    });

    test('capture mode: a retained buffer re-read after a 30 s gap does '
        'not replay events of an evicted tid', () async {
      // The fetch window starts 500 ms before the newest event seen, so
      // an evicted tid's old events are never read again.
      final received = <ParsedTimelineData>[];
      final mock = _MockVmService();
      final client = VmServiceClient(
        retainTimeline: true,
        onTimelineData: received.add,
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      // Poll 1: tid=1 BUILD at ts=1000.
      mock.timelineResult = Timeline(
        traceEvents: [_build(1000, tid: 1)],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );
      await client.pollTimelineSync();

      // Poll 2: retained buffer + a tid=2 event 31 s later. tid=1's
      // cursor is evicted by this poll's sweep.
      mock.timelineResult = Timeline(
        traceEvents: [_build(1000, tid: 1), _build(31000001, tid: 2, dur: 200)],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );
      await client.pollTimelineSync();
      expect(client.cursorsForTest.containsKey(1), isFalse);

      // Poll 3: same retained buffer once more.
      await client.pollTimelineSync();

      final allDurs = received.expand((p) => p.buildScopeDurations).toList()
        ..sort();
      expect(allDurs, equals([100, 200]));
      expect(received.fold<int>(0, (sum, p) => sum + p.buildEventCount), 2);
      expect(mock.timelineWindows.last.$1, 31000001 - 500000);
      expect(mock.clearVMTimelineCalled, isFalse);
      client.dispose();
    });

    test(
      'in-flight poll dropped if dispose runs during getVMTimeline await',
      () async {
        // Pin the generation-fence: an in-flight poll resuming after
        // dispose must not fire onTimelineData with stale data.
        final received = <ParsedTimelineData>[];
        final mock = _MockVmService();
        mock.timelineResult = Timeline(
          traceEvents: [
            TimelineEvent.parse({
              'name': 'Build',
              'cat': 'flutter',
              'ph': 'X',
              'dur': 1000,
              'ts': 100000,
              'pid': 1,
              'tid': 1,
            })!,
          ],
          timeOriginMicros: 100000,
          timeExtentMicros: 1000,
        );
        mock.getVMTimelineDelay = const Duration(milliseconds: 80);

        final client = VmServiceClient(onTimelineData: received.add);
        client.setServiceForTest(mock, isolateId: 'isolate-1');

        final pollFuture = client.pollTimelineSync();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        client.dispose();
        await pollFuture;

        expect(
          received,
          isEmpty,
          reason:
              'Stale poll resuming after dispose must not fire '
              'onTimelineData.',
        );
      },
    );
  });

  group('Poll timings', () {
    TimelineEvent build(int ts, {int tid = 1}) => TimelineEvent.parse({
      'name': 'Build',
      'cat': 'flutter',
      'ph': 'X',
      'dur': 100,
      'ts': ts,
      'pid': 1,
      'tid': tid,
    })!;

    test('null before the first poll', () {
      final client = VmServiceClient();
      client.setServiceForTest(_MockVmService(), isolateId: 'isolate-1');
      expect(client.lastPollTimings, isNull);
      expect(client.maxPollRpcMicros, isNull);
      expect(client.maxPollDecodeMicros, isNull);
      expect(client.maxPollParseMicros, isNull);
      expect(client.maxPollDispatchMicros, isNull);
      expect(client.pollDuplicatesDropped, isNull);
      client.dispose();
    });

    test('one poll records every segment, the event count, and the raw '
        'response length', () async {
      final mock = _MockVmService()
        ..responsePadding = 5000
        ..timelineResult = Timeline(
          traceEvents: [build(100000), build(200000)],
          timeOriginMicros: 0,
          timeExtentMicros: 0,
        );
      final client = VmServiceClient(onTimelineData: (_) {});
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      final t = client.lastPollTimings!;
      expect(t.rpcMicros, greaterThanOrEqualTo(0));
      expect(t.parseMicros, greaterThanOrEqualTo(0));
      expect(t.dispatchMicros, greaterThanOrEqualTo(0));
      expect(t.tailMicros, greaterThanOrEqualTo(0));
      expect(t.eventCount, 2);
      expect(t.duplicatesDropped, 0);
      expect(t.responseChars, greaterThan(5000));
      expect(client.maxPollRpcMicros, t.rpcMicros);
      expect(client.pollDuplicatesDropped, 0);
      client.dispose();
    });

    test('the dispatch split comes from the callback owner and the rest '
        'is other', () async {
      final mock = _MockVmService()
        ..timelineResult = Timeline(
          traceEvents: [build(100000)],
          timeOriginMicros: 0,
          timeExtentMicros: 0,
        );
      final client = VmServiceClient(
        onTimelineData: (_) {
          final w = Stopwatch()..start();
          while (w.elapsedMicroseconds < 3000) {}
        },
        readDispatchSegments: () =>
            (detectors: 100, correlate: 200, aggregate: 300),
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      final t = client.lastPollTimings!;
      expect(t.dispatchMicros, greaterThanOrEqualTo(3000));
      expect(t.dispatchDetectorsMicros, 100);
      expect(t.dispatchCorrelateMicros, 200);
      expect(t.dispatchAggregateMicros, 300);
      expect(t.dispatchOtherMicros, t.dispatchMicros - 600);
      client.dispose();
    });

    test('without a split reader the whole dispatch is other', () async {
      final mock = _MockVmService()
        ..timelineResult = Timeline(
          traceEvents: [build(100000)],
          timeOriginMicros: 0,
          timeExtentMicros: 0,
        );
      final client = VmServiceClient(onTimelineData: (_) {});
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      final t = client.lastPollTimings!;
      expect(t.dispatchDetectorsMicros, 0);
      expect(t.dispatchOtherMicros, t.dispatchMicros);
      client.dispose();
    });

    test('the tail reports the memory await and the in-flight CPU '
        'samples request it overlapped', () async {
      final mock = _MockVmService()
        ..memoryUsageDelay = const Duration(milliseconds: 40)
        ..cpuSamplesDelay = const Duration(milliseconds: 300);
      final client = VmServiceClient(onHeapSample: (_) {});
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      final cpu = client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1);
      await client.pollTimelineSync();

      final t = client.lastPollTimings!;
      expect(t.tailMemoryMicros, greaterThanOrEqualTo(35000));
      expect(t.tailMemoryMicros, lessThanOrEqualTo(t.tailMicros));
      expect(t.tailCpuSamplesMicros, greaterThanOrEqualTo(35000));
      expect(t.tailCpuSamplesMicros, lessThanOrEqualTo(t.tailMicros));
      expect(t.tailAllocationProfileMicros, 0);
      await cpu;

      // A later poll that no request overlapped reports zero.
      mock.memoryUsageDelay = null;
      await client.pollTimelineSync();
      expect(client.lastPollTimings!.tailCpuSamplesMicros, 0);
      client.dispose();
    });

    test('a response with another id is not attributed', () async {
      final mock = _MockVmService()..responseIdOverride = 'other';
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      expect(client.lastPollTimings!.responseChars, -1);
      expect(client.lastPollTimings!.decodeMicros, -1);
      expect(client.maxPollDecodeMicros, -1);
      client.dispose();
    });

    test('decode runs from the raw response to the completed await and '
        'lies inside the RPC', () async {
      final mock = _MockVmService()
        ..getVMTimelineDelay = const Duration(milliseconds: 20)
        ..decodeDelay = const Duration(milliseconds: 3);
      final client = VmServiceClient(onTimelineData: (_) {});
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      final t = client.lastPollTimings!;
      expect(t.decodeMicros, greaterThanOrEqualTo(3000));
      expect(t.decodeMicros, lessThanOrEqualTo(t.rpcMicros));
      // The VM-side wait before the response arrived is not decode.
      expect(t.rpcMicros - t.decodeMicros, greaterThanOrEqualTo(15000));
      expect(
        t.uiBlockingMicros,
        t.decodeMicros + t.parseMicros + t.dispatchMicros,
      );
      client.dispose();
    });

    test('decode without a measured delay is non-negative', () async {
      final mock = _MockVmService();
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      final t = client.lastPollTimings!;
      expect(t.decodeMicros, greaterThanOrEqualTo(0));
      expect(t.decodeMicros, lessThanOrEqualTo(t.rpcMicros));
      client.dispose();
    });

    test('the decode maximum spans the window, skipping unmatched '
        'polls', () async {
      final mock = _MockVmService()
        ..decodeDelay = const Duration(milliseconds: 6);
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();
      final slow = client.lastPollTimings!.decodeMicros;
      expect(slow, greaterThanOrEqualTo(6000));

      mock
        ..decodeDelay = null
        ..responseIdOverride = 'other';
      await client.pollTimelineSync();
      expect(client.lastPollTimings!.decodeMicros, -1);
      mock.responseIdOverride = null;
      await client.pollTimelineSync();
      expect(client.lastPollTimings!.decodeMicros, lessThan(slow));

      expect(client.maxPollDecodeMicros, slow);
      client.dispose();
    });

    test('a failed RPC still records timings with no events', () async {
      final mock = _MockVmService()..getVMTimelineThrows = Exception('busy');
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      final t = client.lastPollTimings!;
      expect(t.rpcMicros, greaterThanOrEqualTo(0));
      expect(t.eventCount, 0);
      expect(t.parseMicros, 0);
      expect(t.dispatchMicros, 0);
      expect(t.responseChars, -1);
      expect(t.decodeMicros, -1);
      client.dispose();
    });

    test('re-read events count as duplicates, summed over polls', () async {
      final mock = _MockVmService()
        ..timelineResult = Timeline(
          traceEvents: [build(100000), build(200000)],
          timeOriginMicros: 0,
          timeExtentMicros: 0,
        );
      final client = VmServiceClient(retainTimeline: true);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();
      await client.pollTimelineSync();
      await client.pollTimelineSync();

      expect(client.lastPollTimings!.duplicatesDropped, 2);
      expect(client.pollDuplicatesDropped, 4);
      client.dispose();
    });

    test('a lost connection resets every poll reading to null until the '
        'next session polls', () async {
      final mock = _MockVmService()
        ..timelineResult = Timeline(
          traceEvents: [build(100000)],
          timeOriginMicros: 0,
          timeExtentMicros: 0,
        );
      final client = VmServiceClient(onTimelineData: (_) {});
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      await client.pollTimelineSync();
      expect(client.lastPollTimings, isNotNull);
      expect(client.pollDuplicatesDropped, 0);
      expect(client.pollWindowFallbacks, 0);

      // Three failures report the connection lost; the reconnect ladder
      // cleans the session up.
      mock.getVMTimelineThrows = Exception('gone');
      await client.pollTimelineSync();
      await client.pollTimelineSync();
      await client.pollTimelineSync();
      expect(client.isConnected, isFalse);

      expect(client.lastPollTimings, isNull);
      expect(client.maxPollRpcMicros, isNull);
      expect(client.maxPollDecodeMicros, isNull);
      expect(client.maxPollParseMicros, isNull);
      expect(client.maxPollDispatchMicros, isNull);
      expect(client.pollDuplicatesDropped, isNull);
      expect(client.pollWindowFallbacks, isNull);

      final fresh = _MockVmService()
        ..timelineResult = Timeline(
          traceEvents: [build(100000)],
          timeOriginMicros: 0,
          timeExtentMicros: 0,
        );
      client.setServiceForTest(fresh, isolateId: 'isolate-1');
      await client.pollTimelineSync();

      expect(client.lastPollTimings, isNotNull);
      expect(client.lastPollTimings!.eventCount, 1);
      expect(client.maxPollRpcMicros, isNotNull);
      expect(client.pollDuplicatesDropped, 0);
      expect(client.pollWindowFallbacks, 0);
      client.dispose();
    });

    group('response id matching', () {
      const id = '42';
      final padding = 'x' * (2 * 1024 * 1024);

      test('an id only in the middle of a large message does not '
          'match', () {
        final message =
            '{"jsonrpc":"2.0","result":{"traceEvents":[$padding'
            '{"id":"$id"}$padding]},"id":"7"}';
        expect(VmServiceClient.responseCarriesId(message, id), isFalse);
      });

      test('a message ending with the id matches', () {
        final message =
            '{"jsonrpc":"2.0","result":{"traceEvents":[$padding]},'
            '"id":"$id"}';
        expect(VmServiceClient.responseCarriesId(message, id), isTrue);
      });

      test('a message starting with the id matches', () {
        final message =
            '{"id":"$id","jsonrpc":"2.0","result":{"traceEvents":'
            '[$padding]}}';
        expect(VmServiceClient.responseCarriesId(message, id), isTrue);
      });

      test('a short message is searched whole', () {
        expect(
          VmServiceClient.responseCarriesId('{"result":{},"id":"$id"}', id),
          isTrue,
        );
        expect(
          VmServiceClient.responseCarriesId('{"result":{},"id":"4"}', id),
          isFalse,
        );
      });
    });

    test('the rolling maxima reset with the session', () async {
      final mock = _MockVmService();
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      await client.pollTimelineSync();
      expect(client.maxPollRpcMicros, isNotNull);

      client.dispose();

      expect(client.maxPollRpcMicros, isNull);
      expect(client.maxPollDecodeMicros, isNull);
      expect(client.maxPollParseMicros, isNull);
      expect(client.maxPollDispatchMicros, isNull);
    });
  });

  group('Incremental fetch', () {
    TimelineEvent ev(
      String name,
      String ph,
      int ts, {
      int tid = 1,
      int? dur,
      String cat = 'flutter',
    }) => TimelineEvent.parse({
      'name': name,
      'cat': cat,
      'ph': ph,
      'ts': ts,
      'dur': ?dur,
      'pid': 1,
      'tid': tid,
    })!;

    Timeline buffer(List<TimelineEvent> events) =>
        Timeline(traceEvents: events, timeOriginMicros: 0, timeExtentMicros: 0);

    test('first poll reads the whole buffer, later polls a window from '
        '500 ms before the newest event to the clock plus 1 s', () async {
      final mock = _MockVmService()
        ..nowMicros = 9000000
        ..timelineResult = buffer([_build(5000000), _build(7000000)]);
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();
      await client.pollTimelineSync();

      expect(mock.timelineWindows, [
        (null, null),
        (6500000, 9000000 - 6500000 + 1000000),
      ]);
      expect(mock.getVMTimelineMicrosCallCount, 1);
      expect(mock.clearVMTimelineCalled, isFalse);
      expect(client.lastPollTimings!.windowFallback, isFalse);
      expect(client.pollWindowFallbacks, 0);
      client.dispose();
    });

    test('origin is clamped at zero', () async {
      final mock = _MockVmService()
        ..nowMicros = 3000000
        ..timelineResult = buffer([_build(300000)]);
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();
      await client.pollTimelineSync();

      expect(mock.timelineWindows.last, (0, 3000000 + 1000000));
      client.dispose();
    });

    test('an empty first poll keeps the next poll a full fetch', () async {
      final mock = _MockVmService();
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();
      mock.timelineResult = buffer([_build(5000000)]);
      await client.pollTimelineSync();

      expect(mock.timelineWindows, [(null, null), (null, null)]);
      client.dispose();
    });

    test('a clock reading behind the newest event falls back to a full '
        'read and drops events before the window', () async {
      final received = <ParsedTimelineData>[];
      final mock = _MockVmService()
        ..timelineResult = buffer([_build(5000000, tid: 2), _build(9000000)]);
      final client = VmServiceClient(onTimelineData: received.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      await client.pollTimelineSync();

      // tid 3 has no cursor; its event at 1 s is older than the window
      // (9 s − 0.5 s) and must not be replayed by the full read.
      mock
        ..nowMicros = 100
        ..timelineResult = buffer([
          _build(1000000, tid: 3),
          _build(5000000, tid: 2),
          _build(9000000),
          _build(9500000, dur: 300),
        ]);
      await client.pollTimelineSync();

      expect(mock.timelineWindows.last, (null, null));
      expect(client.lastPollTimings!.windowFallback, isTrue);
      expect(client.pollWindowFallbacks, 1);
      expect(received.last.buildScopeDurations, [300]);
      expect(received.last.duplicatesDropped, 3);
      client.dispose();
    });

    test('a failing clock read falls back to a full read', () async {
      final mock = _MockVmService()..timelineResult = buffer([_build(5000)]);
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      await client.pollTimelineSync();

      mock.nowMicros = null;
      await client.pollTimelineSync();

      expect(mock.timelineWindows.last, (null, null));
      expect(client.lastPollTimings!.windowFallback, isTrue);
      expect(client.isConnected, isTrue);
      client.dispose();
    });

    test('after a lost connection the next session starts with a full '
        'fetch again', () async {
      final mock = _MockVmService()..timelineResult = buffer([_build(5000)]);
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      await client.pollTimelineSync();
      await client.pollTimelineSync();
      expect(mock.timelineWindows.last.$1, isNotNull);

      // Three failures report the connection lost; the reconnect ladder
      // cleans the session up.
      mock.getVMTimelineThrows = Exception('gone');
      await client.pollTimelineSync();
      await client.pollTimelineSync();
      await client.pollTimelineSync();
      expect(client.isConnected, isFalse);

      final fresh = _MockVmService()..timelineResult = buffer([_build(5000)]);
      client.setServiceForTest(fresh, isolateId: 'isolate-1');
      await client.pollTimelineSync();

      expect(fresh.timelineWindows, [(null, null)]);
      client.dispose();
    });

    test('a growing buffer read through overlapping windows yields the '
        'same batches as non-overlapping reads', () async {
      // 6 s of 60 Hz frames: BUILD X, LAYOUT B/E pairs on the UI thread,
      // raster X on the raster thread. Polls every 500 ms. The full run
      // serves the whole buffer, so each poll reads the client's window
      // (500 ms before the newest event); the 100 ms run re-serves only
      // the last 100 ms before the previous poll; the non-overlapping run
      // hands each poll only the events written since the previous one.
      final all = <TimelineEvent>[];
      final frames = <FrameStats>[];
      for (var i = 0; i < 360; i++) {
        final start = 1000000 + i * 16667;
        all
          ..add(ev('BUILD', 'X', start, dur: 3000))
          ..add(ev('LAYOUT', 'B', start + 3100))
          ..add(ev('LAYOUT', 'E', start + 4100))
          ..add(
            ev('GPURasterizer::Draw', 'X', start + 6000, tid: 2, dur: 4000),
          );
        frames.add(
          FrameStats(
            frameNumber: i,
            uiDuration: const Duration(milliseconds: 5),
            rasterDuration: const Duration(milliseconds: 4),
            timestamp: DateTime(2026),
            vsyncStartUs: start - 500,
            buildStartUs: start,
            buildFinishUs: start + 5000,
            rasterStartUs: start + 5900,
            rasterFinishUs: start + 10500,
          ),
        );
      }
      final pollTimes = [for (var t = 1500000; t <= 7500000; t += 500000) t];

      // [servedOverlapUs] null serves the whole buffer.
      Future<List<ParsedTimelineData>> run({int? servedOverlapUs}) async {
        final received = <ParsedTimelineData>[];
        final mock = _MockVmService();
        final client = VmServiceClient(
          onTimelineData: received.add,
          idleHeartbeat: const Duration(hours: 1),
        );
        client.setServiceForTest(mock, isolateId: 'isolate-1');
        var previous = 0;
        int? newest;
        for (final now in pollTimes) {
          final written = [
            for (final e in all)
              if ((e.json!['ts'] as int) <= now) e,
          ];
          final from = servedOverlapUs == null
              ? null
              : previous - servedOverlapUs;
          mock
            ..nowMicros = now
            ..timelineResult = buffer([
              for (final e in written)
                if (from == null || (e.json!['ts'] as int) > from) e,
            ]);
          previous = now;
          await client.pollTimelineSync();
          if (newest != null) {
            expect(mock.timelineWindows.last.$1, newest - 500000);
          }
          newest = written.fold<int>(
            newest ?? 0,
            (m, e) => math.max(m, e.json!['ts'] as int),
          );
        }
        client.dispose();
        return received;
      }

      final overlapped = await run();
      final short = await run(servedOverlapUs: 100000);
      final plain = await run(servedOverlapUs: 0);

      List<int> builds(List<ParsedTimelineData> r) =>
          r.expand((p) => p.buildScopeDurations).toList();
      List<int> layouts(List<ParsedTimelineData> r) =>
          r.expand((p) => p.flushLayoutDurations).toList();
      List<int> rasters(List<ParsedTimelineData> r) =>
          r.expand((p) => p.rasterDurations).toList();
      List<(TimelinePhase, int, int)> phases(List<ParsedTimelineData> r) => [
        for (final p in r)
          for (final e in p.phaseEvents) (e.phase, e.timestampUs, e.durationUs),
      ];

      expect(builds(overlapped), hasLength(360));
      for (final run in [overlapped, short]) {
        expect(builds(run), builds(plain));
        expect(layouts(run), layouts(plain));
        expect(rasters(run), rasters(plain));
        expect(phases(run), phases(plain));
        expect(
          run.fold<int>(0, (s, p) => s + p.buildEventCount),
          plain.fold<int>(0, (s, p) => s + p.buildEventCount),
        );
        expect(
          run.fold<int>(0, (s, p) => s + p.duplicatesDropped),
          greaterThan(0),
        );
      }
      expect(plain.fold<int>(0, (s, p) => s + p.duplicatesDropped), 0);

      Map<int, (int, int, int, int)> correlated(List<ParsedTimelineData> r) {
        final correlator = FrameEventCorrelator();
        final totals = <int, (int, int, int, int)>{};
        for (final batch in r) {
          final result = correlator.correlate(
            recentFrames: frames,
            phaseEvents: batch.phaseEvents,
          );
          for (final entry in result.entries) {
            final d = entry.value;
            final prev = totals[entry.key] ?? (0, 0, 0, 0);
            totals[entry.key] = (
              prev.$1 + d.matchedEventCount,
              prev.$2 + d.buildScopeUs,
              prev.$3 + d.flushLayoutUs,
              prev.$4 + d.rasterUs,
            );
          }
        }
        return totals;
      }

      final a = correlated(overlapped);
      final b = correlated(plain);
      expect(a, b);
      expect(correlated(short), b);
      expect(a.values.fold<int>(0, (s, v) => s + v.$1), 360 * 3);
    });

    test('a begin before the window origin pairs with its end after it '
        'exactly once', () async {
      final received = <ParsedTimelineData>[];
      final mock = _MockVmService()..nowMicros = 6000000;
      final client = VmServiceClient(onTimelineData: received.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      // Poll 1 sees the begin on tid 1 and a later event on tid 2, so
      // the next window starts at 5 s, after the begin.
      mock.timelineResult = buffer([
        ev('BUILD', 'B', 4000000),
        _build(5500000, tid: 2),
      ]);
      await client.pollTimelineSync();

      final withEnd = buffer([
        ev('BUILD', 'B', 4000000),
        _build(5500000, tid: 2),
        ev('BUILD', 'E', 5100000),
      ]);
      mock.timelineResult = withEnd;
      await client.pollTimelineSync();
      await client.pollTimelineSync();

      expect(mock.timelineWindows[1].$1, 5000000);
      expect(received.expand((p) => p.buildScopeDurations).toList(), [
        100,
        1100000,
      ]);
      client.dispose();
    });

    test('an X event at exactly the window origin counts once', () async {
      final received = <ParsedTimelineData>[];
      final mock = _MockVmService()..nowMicros = 5000000;
      final client = VmServiceClient(onTimelineData: received.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      mock.timelineResult = buffer([_build(3000000, tid: 2)]);
      await client.pollTimelineSync();
      // Written late, stamped exactly at the next origin (3 s − 0.5 s).
      mock.timelineResult = buffer([
        _build(2500000, dur: 700),
        _build(3000000, tid: 2),
      ]);
      await client.pollTimelineSync();
      await client.pollTimelineSync();

      expect(mock.timelineWindows[1].$1, 2500000);
      expect(received.expand((p) => p.buildScopeDurations).toList(), [
        100,
        700,
      ]);
      client.dispose();
    });

    test('a begin whose end arrives 1.5 s later pairs through the pending '
        'map once the begin is outside the window', () async {
      final received = <ParsedTimelineData>[];
      final mock = _MockVmService();
      final client = VmServiceClient(onTimelineData: received.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      // Poll 1: the begin. Poll 2: unrelated work on tid 2 moves the
      // window origin to 1.3 s, past the begin. Poll 3: the end, 1.5 s
      // after the begin (beyond the overlap, inside the phase cap).
      final events = [ev('BUILD', 'B', 1000000)];
      mock
        ..nowMicros = 1100000
        ..timelineResult = buffer(List.of(events));
      await client.pollTimelineSync();
      events.add(_build(1800000, tid: 2));
      mock
        ..nowMicros = 1900000
        ..timelineResult = buffer(List.of(events));
      await client.pollTimelineSync();
      events.add(ev('BUILD', 'E', 2500000));
      mock
        ..nowMicros = 2600000
        ..timelineResult = buffer(List.of(events));
      await client.pollTimelineSync();

      expect(mock.timelineWindows[2].$1, 1300000);
      expect(
        2500000 - 1000000,
        allOf(
          greaterThan(VmServiceClient.fetchOverlapMicros),
          lessThanOrEqualTo(TimelineParser.maxReconstructedPhaseUs),
        ),
      );
      expect(received.map((p) => p.buildScopeDurations).toList(), [
        <int>[],
        [100],
        [1500000],
      ]);
      client.dispose();
    });

    test('cursor signatures stay bounded by the events sharing the latest '
        'ts', () async {
      final mock = _MockVmService();
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      final events = <TimelineEvent>[];
      for (var poll = 0; poll < 10; poll++) {
        final base = 1000000 + poll * 500000;
        for (var i = 0; i < 20; i++) {
          events.add(_build(base + i * 1000));
        }
        // Three distinct instants share the poll's newest ts.
        for (final name in ['a', 'b', 'c']) {
          events.add(ev(name, 'i', base + 30000));
        }
        mock
          ..nowMicros = base + 40000
          ..timelineResult = buffer(List.of(events));
        await client.pollTimelineSync();
        final cursor = client.cursorsForTest[1]!;
        expect(cursor.lastTs, base + 30000);
        expect(cursor.seenSignatures, hasLength(3));
      }
      client.dispose();
    });

    test('the SentinelException branch drops its isolate id when the '
        'session moved on', () async {
      final mock = _MockVmService()
        ..memoryUsageThrows = SentinelException.parse('isolate-1', {
          'type': 'Sentinel',
          'kind': 'Collected',
          'valueAsString': 'test',
        })
        ..getVMDelay = const Duration(milliseconds: 50)
        ..vmResult = VM(
          name: 'test',
          architectureBits: 64,
          hostCPU: 'x86',
          operatingSystem: 'macos',
          targetCPU: 'x86',
          version: '1.0',
          pid: 1,
          startTime: 0,
          isolates: [
            IsolateRef(
              id: 'isolate-2',
              number: '2',
              name: 'main',
              isSystemIsolate: false,
            ),
          ],
          isolateGroups: [],
          systemIsolates: [],
          systemIsolateGroups: [],
        );
      final client = VmServiceClient(onHeapSample: (_) {});
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      final poll = client.pollTimelineSync();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      client.dispose();
      await poll;

      expect(client.mainIsolateIdForTest, isNull);
    });

    test(
      'the SentinelException branch re-resolves within one session',
      () async {
        final mock = _MockVmService()
          ..memoryUsageThrows = SentinelException.parse('isolate-1', {
            'type': 'Sentinel',
            'kind': 'Collected',
            'valueAsString': 'test',
          })
          ..vmResult = VM(
            name: 'test',
            architectureBits: 64,
            hostCPU: 'x86',
            operatingSystem: 'macos',
            targetCPU: 'x86',
            version: '1.0',
            pid: 1,
            startTime: 0,
            isolates: [
              IsolateRef(
                id: 'isolate-2',
                number: '2',
                name: 'main',
                isSystemIsolate: false,
              ),
            ],
            isolateGroups: [],
            systemIsolates: [],
            systemIsolateGroups: [],
          );
        final client = VmServiceClient(onHeapSample: (_) {});
        client.setServiceForTest(mock, isolateId: 'isolate-1');

        await client.pollTimelineSync();

        expect(client.mainIsolateIdForTest, 'isolate-2');
        client.dispose();
      },
    );

    test('a pending begin older than 30 s is evicted using the batch max '
        'ts', () async {
      final received = <ParsedTimelineData>[];
      final mock = _MockVmService();
      final client = VmServiceClient(onTimelineData: received.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      mock.timelineResult = buffer([ev('BUILD', 'B', 1000, tid: 5)]);
      await client.pollTimelineSync();
      mock.timelineResult = buffer([_build(31000001)]);
      await client.pollTimelineSync();
      // A stray end on tid 5 finds no begin left to pair with.
      mock.timelineResult = buffer([
        _build(31000001),
        ev('BUILD', 'E', 31000500, tid: 5),
      ]);
      await client.pollTimelineSync();

      expect(received.expand((p) => p.buildScopeDurations).toList(), [100]);
      client.dispose();
    });
  });

  // =========================================================================
  // 5. Heap polling (piggybacked on timeline)
  // =========================================================================
  group('Heap polling piggybacked on timeline', () {
    test('invokes onHeapSample when isolateId and callback present', () async {
      final receivedSamples = <HeapSample>[];
      final mock = _MockVmService();
      mock.timelineResult = Timeline(
        traceEvents: [],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );
      mock.memoryUsageResult = MemoryUsage(
        heapUsage: 50000000,
        heapCapacity: 100000000,
        externalUsage: 5000000,
      );

      final client = VmServiceClient(onHeapSample: receivedSamples.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      expect(receivedSamples, hasLength(1));
      expect(receivedSamples.first.heapUsage, 50000000);
      expect(receivedSamples.first.heapCapacity, 100000000);
      expect(receivedSamples.first.externalUsage, 5000000);
      client.dispose();
    });

    test('skips heap poll when onHeapSample is null', () async {
      final mock = _MockVmService();
      mock.timelineResult = Timeline(
        traceEvents: [],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );

      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      // getMemoryUsage should NOT be called
      expect(mock.getMemoryUsageCalled, isFalse);
      client.dispose();
    });

    test('handles null heap values gracefully', () async {
      final receivedSamples = <HeapSample>[];
      final mock = _MockVmService();
      mock.timelineResult = Timeline(
        traceEvents: [],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );
      mock.memoryUsageResult = MemoryUsage();

      final client = VmServiceClient(onHeapSample: receivedSamples.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      expect(receivedSamples, hasLength(1));
      expect(receivedSamples.first.heapUsage, 0);
      expect(receivedSamples.first.heapCapacity, 0);
      expect(receivedSamples.first.externalUsage, 0);
      client.dispose();
    });

    test('SentinelException on getMemoryUsage re-resolves isolate', () async {
      final receivedSamples = <HeapSample>[];
      final mock = _MockVmService();
      mock.timelineResult = Timeline(
        traceEvents: [],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );
      mock.memoryUsageThrows = SentinelException.parse(
        'isolate-1',
        <String, dynamic>{
          'type': 'Sentinel',
          'kind': 'Collected',
          'valueAsString': 'test',
        },
      );
      // getVM for isolate re-resolve
      mock.vmResult = VM(
        name: 'test',
        architectureBits: 64,
        hostCPU: 'x86',
        operatingSystem: 'macos',
        targetCPU: 'x86',
        version: '1.0',
        pid: 1,
        startTime: 0,
        isolates: [
          IsolateRef(
            id: 'isolate-2',
            number: '2',
            name: 'main',
            isSystemIsolate: false,
          ),
        ],
        isolateGroups: [],
        systemIsolates: [],
        systemIsolateGroups: [],
      );

      final client = VmServiceClient(onHeapSample: receivedSamples.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      // No sample emitted (SentinelException path re-resolves isolate)
      expect(receivedSamples, isEmpty);
      // getVM called to re-resolve isolate
      expect(mock.getVMCalled, isTrue);
      client.dispose();
    });

    test('generic error on getMemoryUsage does not crash', () async {
      final receivedSamples = <HeapSample>[];
      final mock = _MockVmService();
      mock.timelineResult = Timeline(
        traceEvents: [],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );
      mock.memoryUsageThrows = Exception('memory poll failed');

      final client = VmServiceClient(onHeapSample: receivedSamples.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      // No sample emitted, but no crash
      expect(receivedSamples, isEmpty);
      client.dispose();
    });
  });

  // =========================================================================
  // 6. Connection state
  // =========================================================================
  group('Connection state via setServiceForTest', () {
    test('setServiceForTest sets connected state', () {
      final client = VmServiceClient();
      expect(client.isConnected, isFalse);

      client.setServiceForTest(_MockVmService(), isolateId: 'isolate-1');
      expect(client.isConnected, isTrue);
      client.dispose();
    });

    test('reconnect returns false when disposed', () async {
      final client = VmServiceClient();
      client.dispose();
      final result = await client.reconnect();
      expect(result, isFalse);
    });
  });

  // =========================================================================
  // 7. Poll error handling
  // =========================================================================
  group('Poll error handling', () {
    test('poll error fires onConnectionChanged(false)', () async {
      final connectionChanges = <bool>[];
      final mock = _MockVmService();
      mock.getVMTimelineThrows = Exception('connection lost');

      final client = VmServiceClient(
        onConnectionChanged: connectionChanges.add,
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      expect(client.isConnected, isTrue);

      // One or two failed polls are a blip, not a lost connection.
      await client.pollTimelineSync();
      await client.pollTimelineSync();
      expect(client.isConnected, isTrue);
      expect(connectionChanges, isEmpty);

      await client.pollTimelineSync();

      expect(client.isConnected, isFalse);
      expect(connectionChanges, [false]);
      client.dispose();
    });

    test('a successful poll resets the failure run', () async {
      final connectionChanges = <bool>[];
      final mock = _MockVmService();
      final client = VmServiceClient(
        onConnectionChanged: connectionChanges.add,
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      mock.getVMTimelineThrows = Exception('busy');
      await client.pollTimelineSync();
      await client.pollTimelineSync();
      mock.getVMTimelineThrows = null;
      await client.pollTimelineSync();
      mock.getVMTimelineThrows = Exception('busy');
      await client.pollTimelineSync();
      await client.pollTimelineSync();

      expect(client.isConnected, isTrue);
      expect(connectionChanges, isEmpty);
      client.dispose();
    });

    test('socket closure disconnects without waiting for polls', () async {
      final connectionChanges = <bool>[];
      final mock = _MockVmService();
      final client = VmServiceClient(
        onConnectionChanged: connectionChanges.add,
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      expect(client.isConnected, isTrue);

      mock.onDoneCompleter.complete();
      await Future<void>.delayed(Duration.zero);

      expect(client.isConnected, isFalse);
      expect(connectionChanges, [false]);
      client.dispose();
    });

    test('poll error when disposed does not fire callback', () async {
      final connectionChanges = <bool>[];
      final mock = _MockVmService();
      mock.getVMTimelineThrows = Exception('connection lost');

      final client = VmServiceClient(
        onConnectionChanged: connectionChanges.add,
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      client.dispose();

      await client.pollTimelineSync();

      expect(connectionChanges, isEmpty);
    });

    test('consecutive poll errors fire callback only once', () async {
      final connectionChanges = <bool>[];
      final mock = _MockVmService();
      mock.getVMTimelineThrows = Exception('connection lost');

      final client = VmServiceClient(
        onConnectionChanged: connectionChanges.add,
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      // Three failed polls: onConnectionChanged(false) → reconnect(),
      // which calls _cleanup() and sets _service = null.
      await client.pollTimelineSync();
      await client.pollTimelineSync();
      await client.pollTimelineSync();

      // Further polls: _service is null (cleaned up by reconnect) → early
      // return.
      await client.pollTimelineSync();
      await client.pollTimelineSync();

      // Only one callback fired
      expect(connectionChanges, [false]);
      client.dispose();
    });
  });

  group('A timestamp ahead of the timeline clock', () {
    Timeline buffer(List<TimelineEvent> events) =>
        Timeline(traceEvents: events, timeOriginMicros: 0, timeExtentMicros: 0);

    // Polls every 500 ms over a buffer that already holds [future]; each
    // poll appends one UI-thread build (777 µs) and one raster-thread
    // build. Returns the poll (1-based, after the first) whose batch first
    // carries a UI build, or -1.
    Future<(int, VmServiceClient)> pollsUntilDelivered(
      TimelineEvent future, {
      required int maxPolls,
    }) async {
      final received = <ParsedTimelineData>[];
      final served = <TimelineEvent>[
        _build(9000000),
        _build(9500000, tid: 2),
        future,
      ];
      final mock = _MockVmService()
        ..nowMicros = 10000000
        ..timelineResult = buffer(served);
      final client = VmServiceClient(
        onTimelineData: received.add,
        idleHeartbeat: const Duration(hours: 1),
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      await client.pollTimelineSync();
      final before = received.length;

      for (var poll = 1; poll <= maxPolls; poll++) {
        final now = 10000000 + poll * 500000;
        served
          ..add(_build(now - 100000, dur: 777))
          ..add(_build(now - 50000, tid: 2, dur: 888));
        mock
          ..nowMicros = now
          ..timelineResult = buffer(served);
        await client.pollTimelineSync();
        final delivered = received
            .skip(before)
            .any((p) => p.buildScopeDurations.contains(777));
        if (delivered) return (poll, client);
      }
      return (-1, client);
    }

    test('one event 60 s ahead on another thread does not hold later '
        'events back', () async {
      final (poll, client) = await pollsUntilDelivered(
        _build(70000000, tid: 9),
        maxPolls: 3,
      );
      expect(poll, isNot(-1));
      client.dispose();
    });

    test('one event 60 s ahead on the UI thread: the thread\'s cursor is '
        'rewound once another thread agrees with the clock', () async {
      final (poll, client) = await pollsUntilDelivered(
        _build(70000000),
        maxPolls: 4,
      );
      expect(poll, isNot(-1));
      expect(client.cursorsForTest[1]!.lastTs, lessThan(70000000));
      client.dispose();
    });

    test('three window fallbacks in a row forget the newest event and the '
        'next poll reads the whole buffer', () async {
      final mock = _MockVmService()..timelineResult = buffer([_build(5000)]);
      final client = VmServiceClient(idleHeartbeat: const Duration(hours: 1));
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      await client.pollTimelineSync();

      // The clock read fails: every poll falls back.
      mock.nowMicros = null;
      for (var i = 0; i < 3; i++) {
        await client.pollTimelineSync();
      }
      expect(client.pollWindowFallbacks, 3);
      final clockReads = mock.getVMTimelineMicrosCallCount;

      // Fourth poll: a full read with no clock read, counted as a
      // fallback.
      mock.timelineResult = buffer([_build(5000), _build(8000000)]);
      await client.pollTimelineSync();
      expect(mock.getVMTimelineMicrosCallCount, clockReads);
      expect(mock.timelineWindows.last, (null, null));
      expect(client.lastPollTimings!.windowFallback, isTrue);
      expect(client.pollWindowFallbacks, 4);

      // The clock is back: windowed fetches resume.
      mock.nowMicros = 9000000;
      await client.pollTimelineSync();
      expect(mock.timelineWindows.last.$1, isNotNull);
      expect(client.lastPollTimings!.windowFallback, isFalse);
      client.dispose();
    });

    test('a clock behind every thread leaves the cursors in place', () {
      final cursors = <int, TimelineCursor>{};
      TimelineParser.parse([
        _build(5000000),
        _build(6000000, tid: 2),
      ], cursorsByTid: cursors);

      expect(
        TimelineParser.clampOutlierCursors(cursors, ceilingUs: 1000),
        isNull,
      );
      expect(cursors[1]!.lastTs, 5000000);
      expect(cursors[2]!.lastTs, 6000000);
    });

    test('an outlier cursor is rewound to the newest agreeing one', () {
      final cursors = <int, TimelineCursor>{};
      TimelineParser.parse([
        _build(5000000),
        _build(6000000, tid: 2),
        _build(90000000, tid: 3),
      ], cursorsByTid: cursors);

      expect(
        TimelineParser.clampOutlierCursors(cursors, ceilingUs: 7000000),
        6000000,
      );
      expect(cursors[1]!.lastTs, 5000000);
      expect(cursors[3]!.lastTs, 6000000);
      // A later event on the rewound thread is accepted.
      final next = TimelineParser.parse([
        _build(6500000, tid: 3, dur: 42),
      ], cursorsByTid: cursors);
      expect(next.buildScopeDurations, [42]);
    });
  });

  group('A poll that outlives its session', () {
    test('its failure leaves the new session\'s counter and connection '
        'alone', () async {
      final old = _MockVmService()
        ..getVMTimelineDelay = const Duration(milliseconds: 20)
        ..getVMTimelineThrows = Exception('old socket');
      final client = VmServiceClient(idleHeartbeat: const Duration(hours: 1));
      client.setServiceForTest(old, isolateId: 'isolate-1');

      final stale = client.pollTimelineSync();
      client.endSessionForTest();
      final fresh = _MockVmService()
        ..timelineResult = Timeline(
          traceEvents: [_build(5000)],
          timeOriginMicros: 0,
          timeExtentMicros: 0,
        );
      client.setServiceForTest(fresh, isolateId: 'isolate-2');
      await stale;

      expect(client.consecutivePollFailuresForTest, 0);
      expect(client.isConnected, isTrue);

      // Two failures of the new session are still below the limit.
      fresh.getVMTimelineThrows = Exception('blip');
      await client.pollTimelineSync();
      await client.pollTimelineSync();
      expect(client.consecutivePollFailuresForTest, 2);
      expect(client.isConnected, isTrue);
      client.dispose();
    });

    test('a stale-isolate answer does not overwrite the new session\'s '
        'isolate id', () async {
      final old = _MockVmService()
        ..cpuSamplesDelay = const Duration(milliseconds: 20)
        ..cpuSamplesThrows = SentinelException.parse(
          'isolate-1',
          <String, dynamic>{
            'type': 'Sentinel',
            'kind': 'Collected',
            'valueAsString': 'test',
          },
        );
      final client = VmServiceClient();
      client.setServiceForTest(old, isolateId: 'isolate-1');

      final pending = client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1000);
      client.endSessionForTest();
      client.setServiceForTest(_MockVmService(), isolateId: 'isolate-2');
      await pending;

      expect(client.mainIsolateIdForTest, 'isolate-2');
      client.dispose();
    });

    test('a new session extracts startup events again', () async {
      final startups = <StartupTimelineEvents>[];
      Timeline startupBuffer() => Timeline(
        traceEvents: [
          TimelineEvent.parse({
            'name': 'FlutterEngineMainEnter',
            'cat': 'Embedder',
            'ph': 'i',
            'ts': 1000,
            'pid': 1,
            'tid': 1,
          })!,
        ],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );
      final client = VmServiceClient(onStartupTimelineEvents: startups.add);
      client.setServiceForTest(
        _MockVmService()..timelineResult = startupBuffer(),
        isolateId: 'isolate-1',
      );
      await client.pollTimelineSync();
      expect(startups, hasLength(1));

      client.endSessionForTest();
      client.setServiceForTest(
        _MockVmService()..timelineResult = startupBuffer(),
        isolateId: 'isolate-1',
      );
      await client.pollTimelineSync();
      expect(startups, hasLength(2));
      client.dispose();
    });
  });
}

TimelineEvent _build(int ts, {int tid = 1, int dur = 100}) =>
    TimelineEvent.parse({
      'name': 'Build',
      'cat': 'flutter',
      'ph': 'X',
      'dur': dur,
      'ts': ts,
      'pid': 1,
      'tid': tid,
    })!;

// ---------------------------------------------------------------------------
// Mock VmService
// ---------------------------------------------------------------------------

/// Minimal mock of [VmService] for testing VmServiceClient.
///
/// Tracks which methods were called and returns configurable results.
class _MockVmService implements VmService {
  final Completer<void> onDoneCompleter = Completer<void>();

  @override
  Future<void> get onDone => onDoneCompleter.future;

  bool getVMTimelineCalled = false;
  bool clearVMTimelineCalled = false;
  bool getMemoryUsageCalled = false;
  bool getVMCalled = false;
  Duration? getVMDelay;
  int getVMTimelineCallCount = 0;
  Duration? getVMTimelineDelay;

  Timeline? timelineResult;
  Object? getVMTimelineThrows;
  MemoryUsage? memoryUsageResult;
  Object? memoryUsageThrows;
  Duration? memoryUsageDelay;
  CpuSamples? cpuSamplesResult;
  Object? cpuSamplesThrows;
  Duration? cpuSamplesDelay;

  /// When true, `getCpuSamples` never answers.
  bool cpuSamplesNeverCompletes = false;
  int getCpuSamplesCallCount = 0;
  AllocationProfile? allocationProfileResult;
  Object? allocationProfileThrows;
  Duration? allocationProfileDelay;
  bool getAllocationProfileCalled = false;
  VM? vmResult;

  /// Raw wire traffic, mirroring package:vm_service's sync broadcast
  /// `onSend` / `onReceive` streams.
  final StreamController<String> sendController =
      StreamController<String>.broadcast(sync: true);
  final StreamController<String> receiveController =
      StreamController<String>.broadcast(sync: true);
  int _nextRequestId = 0;

  /// When set, the simulated timeline response carries this id instead
  /// of the request's own.
  String? responseIdOverride;

  /// Raw size of the simulated timeline response body.
  int responsePadding = 0;

  /// Synchronous work after the raw response is emitted on `onReceive`
  /// and before the future completes, standing in for the JSON decode
  /// and `Timeline` construction package:vm_service runs there.
  Duration? decodeDelay;

  @override
  Stream<String> get onSend => sendController.stream;

  @override
  Stream<String> get onReceive => receiveController.stream;

  /// Value served by `getVMTimelineMicros`; null makes the RPC throw.
  int? nowMicros = 1 << 40;
  int getVMTimelineMicrosCallCount = 0;

  /// `(timeOriginMicros, timeExtentMicros)` of every `getVMTimeline` call.
  final List<(int?, int?)> timelineWindows = [];

  @override
  Future<Timestamp> getVMTimelineMicros() async {
    getVMTimelineMicrosCallCount++;
    final now = nowMicros;
    if (now == null) throw Exception('clock unavailable');
    return Timestamp(timestamp: now);
  }

  @override
  Future<Timeline> getVMTimeline({
    int? timeOriginMicros,
    int? timeExtentMicros,
  }) {
    getVMTimelineCalled = true;
    getVMTimelineCallCount++;
    timelineWindows.add((timeOriginMicros, timeExtentMicros));
    final id = '${_nextRequestId++}';
    sendController.add(
      '{"jsonrpc":"2.0","id":"$id","method":"getVMTimeline","params":{}}',
    );
    return _completeTimeline(id);
  }

  Future<Timeline> _completeTimeline(String id) async {
    if (getVMTimelineDelay != null) {
      await Future<void>.delayed(getVMTimelineDelay!);
    }
    if (getVMTimelineThrows != null) throw getVMTimelineThrows!;
    receiveController.add(
      '{"jsonrpc":"2.0","result":{"type":"Timeline","traceEvents":['
      '${'x' * responsePadding}]},"id":"${responseIdOverride ?? id}"}',
    );
    final decode = decodeDelay;
    if (decode != null) {
      final w = Stopwatch()..start();
      while (w.elapsed < decode) {}
    }
    final window = timelineWindows.last;
    final result =
        timelineResult ??
        Timeline(traceEvents: [], timeOriginMicros: 0, timeExtentMicros: 0);
    final origin = window.$1;
    if (origin == null) return result;
    // Windowed read, as the VM serves it: events whose `ts` lies inside
    // [origin, origin + extent].
    final end = origin + window.$2!;
    return Timeline(
      traceEvents: [
        for (final e in result.traceEvents ?? const <TimelineEvent>[])
          if (e.json?['ts'] case final int ts when ts >= origin && ts <= end) e,
      ],
      timeOriginMicros: origin,
      timeExtentMicros: window.$2,
    );
  }

  @override
  Future<Success> clearVMTimeline() async {
    clearVMTimelineCalled = true;
    return Success();
  }

  @override
  Future<MemoryUsage> getMemoryUsage(String isolateId) async {
    getMemoryUsageCalled = true;
    if (memoryUsageDelay != null) {
      await Future<void>.delayed(memoryUsageDelay!);
    }
    if (memoryUsageThrows != null) throw memoryUsageThrows!;
    return memoryUsageResult ?? MemoryUsage();
  }

  @override
  Future<CpuSamples> getCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  ) async {
    getCpuSamplesCallCount++;
    if (cpuSamplesNeverCompletes) return Completer<CpuSamples>().future;
    if (cpuSamplesDelay != null) {
      await Future<void>.delayed(cpuSamplesDelay!);
    }
    if (cpuSamplesThrows != null) throw cpuSamplesThrows!;
    return cpuSamplesResult ??
        CpuSamples(
          sampleCount: 0,
          samplePeriod: 100,
          maxStackDepth: 128,
          timeOriginMicros: 0,
          timeExtentMicros: 0,
          pid: 1,
          functions: [],
          samples: [],
        );
  }

  @override
  Future<AllocationProfile> getAllocationProfile(
    String isolateId, {
    bool? reset,
    bool? gc,
  }) async {
    getAllocationProfileCalled = true;
    if (allocationProfileDelay != null) {
      await Future<void>.delayed(allocationProfileDelay!);
    }
    if (allocationProfileThrows != null) throw allocationProfileThrows!;
    return allocationProfileResult ?? AllocationProfile(members: []);
  }

  @override
  Future<VM> getVM() async {
    getVMCalled = true;
    if (getVMDelay != null) await Future<void>.delayed(getVMDelay!);
    return vmResult ??
        VM(
          name: 'test',
          architectureBits: 64,
          hostCPU: 'x86',
          operatingSystem: 'macos',
          targetCPU: 'x86',
          version: '1.0',
          pid: 1,
          startTime: 0,
          isolates: [],
          isolateGroups: [],
          systemIsolates: [],
          systemIsolateGroups: [],
        );
  }

  @override
  Future<Success> setVMTimelineFlags(List<String> recordedStreams) async =>
      Success();

  @override
  Future<Success> streamListen(String streamId) async => Success();

  @override
  Future<Success> streamCancel(String streamId) async => Success();

  // -- Streams --

  @override
  Stream<Event> get onGCEvent => const Stream.empty();

  @override
  Stream<Event> get onExtensionEvent => const Stream.empty();

  @override
  Stream<Event> get onTimelineEvent => const Stream.empty();

  @override
  Stream<Event> get onVMEvent => const Stream.empty();

  @override
  Stream<Event> get onIsolateEvent => const Stream.empty();

  @override
  Stream<Event> get onDebugEvent => const Stream.empty();

  @override
  Stream<Event> get onStdoutEvent => const Stream.empty();

  @override
  Stream<Event> get onStderrEvent => const Stream.empty();

  @override
  Stream<Event> get onLoggingEvent => const Stream.empty();

  @override
  Stream<Event> get onServiceEvent => const Stream.empty();

  @override
  Stream<Event> get onHeapSnapshotEvent => const Stream.empty();

  @override
  Stream<Event> get onProfilerEvent => const Stream.empty();

  // -- Other required methods (no-op stubs) --

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    // Catch-all for any VmService methods not explicitly overridden.
    // This allows the mock to compile against any version of vm_service
    // without needing stubs for every method.
    return null;
  }
}
