import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:sleuth/src/models/heap_sample.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';

void main() {
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

      final client = VmServiceClient(
        onTimelineData: receivedData.add,
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();

      // Timeline data should be parsed and forwarded
      // (may be empty if the mock event isn't recognized by TimelineParser)
      expect(mock.getVMTimelineCalled, isTrue);
      expect(mock.clearVMTimelineCalled, isTrue);
      client.dispose();
    });

    test('poll clears timeline buffer after reading', () async {
      final mock = _MockVmService();
      mock.timelineResult = Timeline(
        traceEvents: [],
        timeOriginMicros: 0,
        timeExtentMicros: 0,
      );

      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      await client.pollTimelineSync();
      expect(mock.clearVMTimelineCalled, isTrue);
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

    test('pollTimelineSync barrier waits for in-flight poll then forces fresh',
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

      expect(mock.getVMTimelineCallCount, 2,
          reason: 'Barrier must run a fresh poll after the in-flight one '
              'completes — capture flow needs guaranteed-fresh observation '
              'before markScenarioEnd fires.');
      client.dispose();
    });

    test(
        'cross-batch BUILD reconstruction survives clearVMTimeline on '
        'default !retainTimeline polling path', () async {
      // iOS profile mode emits BUILD as `ph: 'B'` / `ph: 'E'` pairs
      // instead of `ph: 'X'` complete-form. When a poll boundary falls
      // between the B and the E, the parser needs `_pendingBuildBegins`
      // to carry the unmatched B from batch N into batch N+1 so dur can
      // be reconstructed. The matching E is emitted by Flutter AFTER
      // `clearVMTimeline()` and lands in the next batch's fresh buffer
      // — clearing `_pendingBuildBegins` on every poll would drop every
      // poll-boundary BUILD silently.
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
      expect(mock.clearVMTimelineCalled, isTrue,
          reason: 'Default !retainTimeline path must clear VM buffer.');
      expect(received.expand((p) => p.buildScopeDurations), isEmpty,
          reason: 'Batch 1 has B without E; no dur reconstructed yet.');

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
      final allBuildDurs =
          received.expand((p) => p.buildScopeDurations).toList();
      expect(allBuildDurs, equals([5000]),
          reason: 'Cross-batch reconstruction must emit dur = E.ts - B.ts '
              '(5000 us) on the default polling path. Wiping '
              '_pendingBuildBegins on clearVMTimeline would silently '
              'drop this BUILD.');
      client.dispose();
    });

    test(
        'capture-mode buffer re-read does not inflate counters across '
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

      expect(mock.clearVMTimelineCalled, isFalse,
          reason: 'retainTimeline=true must skip clearVMTimeline.');
      // Aggregate across all onTimelineData callbacks.
      final allDurs = received.expand((p) => p.buildScopeDurations).toList();
      final totalBuildCount =
          received.fold<int>(0, (sum, p) => sum + p.buildEventCount);
      expect(allDurs, equals([1000, 1500]),
          reason: '2 real BUILDs across 3 polls must yield 2 dur entries '
              '(not 6). Watermark dedup must skip re-observed events.');
      expect(totalBuildCount, 2,
          reason: 'buildEventCount must equal real BUILDs (2), not 3× '
              '(6). RebuildDetector consumes this raw and would '
              'false-positive without the watermark.');
      client.dispose();
    });

    test(
        'cursor sweep evicts tids idle past the 30s ceiling so '
        'long-lived sessions with churning tids do not leak', () async {
      // Behavioural check: an evicted cursor lets a low-ts event on
      // that tid pass through (otherwise the watermark would skip it
      // as ts < lastTs).
      final received = <ParsedTimelineData>[];
      final mock = _MockVmService();
      final client = VmServiceClient(onTimelineData: received.add);
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      // Poll 1: tid=1 event at ts=1000. Cursor: tid=1 → lastTs=1000.
      mock.timelineResult = Timeline(
        traceEvents: [
          TimelineEvent.parse({
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'X',
            'dur': 100,
            'ts': 1000,
            'pid': 1,
            'tid': 1,
          })!,
        ],
        timeOriginMicros: 1000,
        timeExtentMicros: 100,
      );
      await client.pollTimelineSync();

      // Poll 2: tid=2 event at ts=31_000_001 (>30s past ts=1000).
      // Anchor=31_000_001 → cursor cutoff = 1_000_001 → tid=1 cursor
      // (lastTs=1000) is evicted.
      mock.timelineResult = Timeline(
        traceEvents: [
          TimelineEvent.parse({
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'X',
            'dur': 100,
            'ts': 31000001,
            'pid': 1,
            'tid': 2,
          })!,
        ],
        timeOriginMicros: 31000001,
        timeExtentMicros: 100,
      );
      await client.pollTimelineSync();

      // Poll 3: tid=1 event at ts=500 (LESS than the prior cursor's
      // lastTs=1000). If the cursor was correctly evicted, this event
      // passes through. If retained, the watermark skips it.
      mock.timelineResult = Timeline(
        traceEvents: [
          TimelineEvent.parse({
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'X',
            'dur': 50,
            'ts': 500,
            'pid': 1,
            'tid': 1,
          })!,
        ],
        timeOriginMicros: 500,
        timeExtentMicros: 100,
      );
      await client.pollTimelineSync();

      final allDurs = received.expand((p) => p.buildScopeDurations).toList();
      expect(allDurs, contains(50),
          reason: 'tid=1 cursor must be evicted by poll 2 sweep so the '
              'tid=1 ts=500 event in poll 3 is not skipped as stale.');
      client.dispose();
    });

    test(
        'capture mode (retainTimeline=true) does NOT evict cursors — '
        'retained-buffer re-reads across 30s+ cross-tid gaps stay '
        'deduped (no replay of old events)', () async {
      // The cursor map is the dedup mechanism in capture mode because
      // the VM buffer is intentionally re-read across polls. Evicting
      // a cursor for a tid idle past the cursor TTL would let the next
      // poll's re-read of that tid's old events pass through the
      // parser, inflating buildEventCount and other accumulators.
      final received = <ParsedTimelineData>[];
      final mock = _MockVmService();
      final client = VmServiceClient(
        retainTimeline: true,
        onTimelineData: received.add,
      );
      client.setServiceForTest(mock, isolateId: 'isolate-1');

      // Poll 1: tid=1 BUILD at ts=1000.
      mock.timelineResult = Timeline(
        traceEvents: [
          TimelineEvent.parse({
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'X',
            'dur': 100,
            'ts': 1000,
            'pid': 1,
            'tid': 1,
          })!,
        ],
        timeOriginMicros: 1000,
        timeExtentMicros: 100,
      );
      await client.pollTimelineSync();
      expect(mock.clearVMTimelineCalled, isFalse,
          reason: 'retainTimeline=true must not clear the VM buffer.');

      // Poll 2: full retained buffer + new tid=2 event 31s later.
      // anchorTs=31_000_001; cursorCutoff would be 1_000_001 if the
      // sweep ran — would evict tid=1 cursor (lastTs=1000). Capture
      // mode must NOT evict.
      mock.timelineResult = Timeline(
        traceEvents: [
          TimelineEvent.parse({
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'X',
            'dur': 100,
            'ts': 1000,
            'pid': 1,
            'tid': 1,
          })!,
          TimelineEvent.parse({
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'X',
            'dur': 200,
            'ts': 31000001,
            'pid': 1,
            'tid': 2,
          })!,
        ],
        timeOriginMicros: 1000,
        timeExtentMicros: 31000000,
      );
      await client.pollTimelineSync();

      // Poll 3: same retained buffer once more. tid=1's cursor must
      // still be present so the re-read of tid=1 ts=1000 stays deduped.
      // Without the gate, the sweep evicted tid=1 in poll 2 and this
      // poll re-emits tid=1's BUILD.
      await client.pollTimelineSync();

      final allDurs = received.expand((p) => p.buildScopeDurations).toList()
        ..sort();
      final totalBuildCount =
          received.fold<int>(0, (sum, p) => sum + p.buildEventCount);
      expect(allDurs, equals([100, 200]),
          reason: 'Each BUILD must appear exactly once across 3 polls of '
              'retained buffer. Cursor eviction in capture mode would '
              'replay tid=1 ts=1000 → [100, 100, 200] or similar.');
      expect(totalBuildCount, 2,
          reason: 'buildEventCount must equal real BUILDs (2). '
              'Replay would inflate to 3+.');
      client.dispose();
    });

    test('in-flight poll dropped if dispose runs during getVMTimeline await',
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

      expect(received, isEmpty,
          reason: 'Stale poll resuming after dispose must not fire '
              'onTimelineData.');
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

      final client = VmServiceClient(
        onHeapSample: receivedSamples.add,
      );
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

      final client = VmServiceClient(
        onHeapSample: receivedSamples.add,
      );
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

      final client = VmServiceClient(
        onHeapSample: receivedSamples.add,
      );
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

      final client = VmServiceClient(
        onHeapSample: receivedSamples.add,
      );
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

      await client.pollTimelineSync();

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

      // First poll: triggers error → onConnectionChanged(false) → reconnect()
      // reconnect() calls _cleanup() which sets _service = null
      await client.pollTimelineSync();

      // Second poll: _service is null (cleaned up by reconnect) → early return
      await client.pollTimelineSync();

      // Only one callback fired
      expect(connectionChanges, [false]);
      client.dispose();
    });
  });
}

// ---------------------------------------------------------------------------
// Mock VmService
// ---------------------------------------------------------------------------

/// Minimal mock of [VmService] for testing VmServiceClient.
///
/// Tracks which methods were called and returns configurable results.
class _MockVmService implements VmService {
  bool getVMTimelineCalled = false;
  bool clearVMTimelineCalled = false;
  bool getMemoryUsageCalled = false;
  bool getVMCalled = false;
  int getVMTimelineCallCount = 0;
  Duration? getVMTimelineDelay;

  Timeline? timelineResult;
  Object? getVMTimelineThrows;
  MemoryUsage? memoryUsageResult;
  Object? memoryUsageThrows;
  CpuSamples? cpuSamplesResult;
  Object? cpuSamplesThrows;
  Duration? cpuSamplesDelay;
  AllocationProfile? allocationProfileResult;
  Object? allocationProfileThrows;
  Duration? allocationProfileDelay;
  bool getAllocationProfileCalled = false;
  VM? vmResult;

  @override
  Future<Timeline> getVMTimeline({
    int? timeOriginMicros,
    int? timeExtentMicros,
  }) async {
    getVMTimelineCalled = true;
    getVMTimelineCallCount++;
    if (getVMTimelineDelay != null) {
      await Future<void>.delayed(getVMTimelineDelay!);
    }
    if (getVMTimelineThrows != null) throw getVMTimelineThrows!;
    return timelineResult ??
        Timeline(traceEvents: [], timeOriginMicros: 0, timeExtentMicros: 0);
  }

  @override
  Future<Success> clearVMTimeline() async {
    clearVMTimelineCalled = true;
    return Success();
  }

  @override
  Future<MemoryUsage> getMemoryUsage(String isolateId) async {
    getMemoryUsageCalled = true;
    if (memoryUsageThrows != null) throw memoryUsageThrows!;
    return memoryUsageResult ?? MemoryUsage();
  }

  @override
  Future<CpuSamples> getCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  ) async {
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
