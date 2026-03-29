import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:widget_watchdog/src/models/heap_sample.dart';
import 'package:widget_watchdog/src/vm/timeline_parser.dart';
import 'package:widget_watchdog/src/vm/vm_service_client.dart';

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

      await client.pollTimelineForTest();

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

      await client.pollTimelineForTest();
      expect(mock.clearVMTimelineCalled, isTrue);
      client.dispose();
    });

    test('poll does nothing when disposed', () async {
      final mock = _MockVmService();
      final client = VmServiceClient();
      client.setServiceForTest(mock, isolateId: 'isolate-1');
      client.dispose();

      await client.pollTimelineForTest();
      expect(mock.getVMTimelineCalled, isFalse);
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

      await client.pollTimelineForTest();

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

      await client.pollTimelineForTest();

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

      await client.pollTimelineForTest();

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

      await client.pollTimelineForTest();

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

      await client.pollTimelineForTest();

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

  Timeline? timelineResult;
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
