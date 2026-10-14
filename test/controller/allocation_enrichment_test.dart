import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart' show Sleuth;
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/heap_sample.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';
import 'package:vm_service/vm_service.dart';

import '../helpers/fake_vm_service.dart';

/// One profile with one app class, so enrichment has an allocator to
/// report.
AllocationProfile _profile() => AllocationProfile(
  members: [
    ClassHeapStats(
      classRef: ClassRef(
        id: 'classes/1',
        name: 'LeakyCache',
        library: LibraryRef(id: 'libraries/1', uri: 'package:app/cache.dart'),
      ),
      bytesCurrent: 4 * 1024 * 1024,
      instancesCurrent: 1000,
      accumulatedSize: 0,
      instancesAccumulated: 0,
    ),
  ],
);

/// Records each `getAllocationProfile` call. Answers with [answer], or
/// waits for [gate] while it is set.
class _ProfileClient extends VmServiceClient {
  final List<({bool reset, Duration timeout})> calls = [];
  Completer<AllocationProfile?>? gate;
  AllocationProfile? answer = _profile();

  @override
  bool get isConnected => true;

  @override
  bool get isOwnIsolateVerified => true;

  @override
  Future<AllocationProfile?> getAllocationProfile({
    bool reset = false,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    calls.add((reset: reset, timeout: timeout));
    final pending = gate;
    if (pending != null) return pending.future;
    return answer;
  }

  @override
  void dispose() {}
}

final _start = DateTime(2026, 10, 14, 9);

/// Heap samples 500 ms apart growing 4 MB/s, numbered from [from].
/// From an empty window, `heap_growing` appears on sample 23 (10 s after
/// the slope first crossed the threshold on sample 3).
void _growHeap(SleuthController controller, {int from = 0, int count = 30}) {
  for (var i = from; i < from + count; i++) {
    controller.feedHeapSampleForTest(
      HeapSample(
        heapUsage: (50 << 20) + i * (2 << 20),
        heapCapacity: 1 << 30,
        externalUsage: 0,
        timestamp: _start.add(Duration(milliseconds: 500 * i)),
      ),
    );
  }
}

/// Idle full collections for the floor leg. The controller's detector
/// ignores the first 30 s after construction, so event times start 35 s
/// ahead of the wall clock; freshness only bounds how old points are.
final int _floorBaseMs = DateTime.now().millisecondsSinceEpoch + 35000;

void _floorPoint(SleuthController controller, double sec, double mb) {
  controller.feedGcEventForTest(
    gcEvent(
      gcType: 'MarkSweep',
      reason: 'idle',
      newUsed: 0,
      oldUsed: (mb * 1000000).round(),
      timestampMs: _floorBaseMs + (sec * 1000).round(),
    ),
  );
}

PerformanceIssue? _heapGrowing(SleuthController controller) => controller
    .memoryPressureDetector!
    .issues
    .where((i) => i.stableId == 'heap_growing')
    .firstOrNull;

void main() {
  late SleuthController controller;
  late _ProfileClient client;
  late bool disposed;

  setUp(() {
    controller = SleuthController(
      config: const SleuthConfig(memoryWarmupDurationMs: 0),
    );
    controller.initializeDetectorsForTest();
    controller.simulateVmStateChangeForTest(true);
    client = _ProfileClient();
    controller.setVmClientForTest(client);
    disposed = false;
  });

  tearDown(() {
    final pending = client.gate;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    if (!disposed) controller.dispose();
  });

  group('allocation enrichment', () {
    test('the first heap_growing makes one read, without a reset, and '
        'reports the current allocators', () async {
      _growHeap(controller, count: 23);
      expect(client.calls, isEmpty, reason: 'no heap_growing yet');

      _growHeap(controller, from: 23, count: 7);
      await Future<void>.delayed(Duration.zero);

      expect(client.calls, hasLength(1));
      expect(client.calls.single.reset, isFalse);
      expect(
        client.calls.single.timeout,
        SleuthController.allocationEnrichmentTimeout,
      );
      final allocators = _heapGrowing(controller)!.topAllocators!;
      expect(allocators.single.className, 'LeakyCache');
      expect(allocators.single.instancesDelta, 1000);
      expect(allocators.single.bytesDelta, 4 * 1024 * 1024);
    });

    test('GC events during the episode start no further read', () async {
      _growHeap(controller);
      for (final type in ['Scavenge', 'StartCMark', 'MarkSweep']) {
        controller.feedGcEventForTest(gcEvent(gcType: type));
      }
      _growHeap(controller, from: 30, count: 10);
      await Future<void>.delayed(Duration.zero);

      expect(client.calls, hasLength(1));
    });

    test('GC events before heap_growing start no read', () async {
      _growHeap(controller, count: 23);
      for (var i = 0; i < 5; i++) {
        controller.feedGcEventForTest(gcEvent(gcType: 'MarkSweep'));
      }
      await Future<void>.delayed(Duration.zero);

      expect(client.calls, isEmpty);
    });

    test('a second episode inside the 10 s cooldown reads nothing; one '
        'after it reads once', () async {
      _growHeap(controller);
      controller.resetCaptureState();
      _growHeap(controller);
      expect(client.calls, hasLength(1));

      controller
        ..resetCaptureState()
        ..lastAllocationEnrichmentTimeForTest = DateTime.now().subtract(
          const Duration(seconds: 11),
        );
      _growHeap(controller);
      expect(client.calls, hasLength(2));
    });

    test('a failed read leaves the issue without allocators', () async {
      client.answer = null;
      _growHeap(controller);
      await Future<void>.delayed(Duration.zero);

      expect(client.calls, hasLength(1));
      expect(_heapGrowing(controller), isNotNull);
      expect(_heapGrowing(controller)!.topAllocators, isNull);
    });

    test('a result that lands after a new scenario began is dropped', () async {
      final pending = client.gate = Completer<AllocationProfile?>();
      _growHeap(controller);
      expect(client.calls, hasLength(1));

      controller.resetCaptureState();
      _growHeap(controller);
      pending.complete(_profile());
      await Future<void>.delayed(Duration.zero);

      expect(_heapGrowing(controller), isNotNull);
      expect(_heapGrowing(controller)!.topAllocators, isNull);
    });

    test('a result that lands after dispose writes nothing', () async {
      final pending = client.gate = Completer<AllocationProfile?>();
      _growHeap(controller);
      final detector = controller.memoryPressureDetector!;
      controller.dispose();
      disposed = true;

      pending.complete(_profile());
      await Future<void>.delayed(Duration.zero);
      final issue = detector.issues
          .where((i) => i.stableId == 'heap_growing')
          .firstOrNull;
      expect(issue?.topAllocators, isNull);
    });
    group('floor leg and episodes', () {
      test('a GC event that completes a growing floor verdict starts one '
          'read', () async {
        _floorPoint(controller, 0, 10);
        _floorPoint(controller, 10, 17);
        expect(client.calls, isEmpty);
        _floorPoint(controller, 20, 24);
        await Future<void>.delayed(Duration.zero);

        expect(
          _heapGrowing(controller)!.extraTraceArgs!['heapGrowingLeg'],
          'floor',
        );
        expect(client.calls, hasLength(1));
      });

      test(
        'a new episode inside the cooldown gets one deferred read',
        () async {
          _floorPoint(controller, 0, 10);
          _floorPoint(controller, 10, 17);
          _floorPoint(controller, 20, 24);
          expect(client.calls, hasLength(1));
          _floorPoint(controller, 30, 24);
          expect(_heapGrowing(controller), isNull);

          // The next episode comes from the sample leg 9.9 s after the read.
          controller.lastAllocationEnrichmentTimeForTest = DateTime.now()
              .subtract(const Duration(milliseconds: 9900));
          controller.resetCaptureState();
          _growHeap(controller);
          expect(_heapGrowing(controller), isNotNull);
          expect(client.calls, hasLength(1));

          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(client.calls, hasLength(2));
        },
      );

      test(
        'a deferred read is dropped when the capture state resets',
        () async {
          controller.lastAllocationEnrichmentTimeForTest = DateTime.now()
              .subtract(const Duration(milliseconds: 9900));
          _growHeap(controller);
          expect(client.calls, isEmpty);
          controller.resetCaptureState();

          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(client.calls, isEmpty);
        },
      );

      test(
        'a reply that lands after its episode ended labels nothing',
        () async {
          final pending = client.gate = Completer<AllocationProfile?>();
          _floorPoint(controller, 0, 10);
          _floorPoint(controller, 10, 17);
          _floorPoint(controller, 20, 24);
          _floorPoint(controller, 30, 24);
          pending.complete(_profile());
          await Future<void>.delayed(Duration.zero);

          controller.lastAllocationEnrichmentTimeForTest = DateTime.now();
          controller.resetCaptureState();
          _growHeap(controller);
          expect(_heapGrowing(controller)!.topAllocators, isNull);
        },
      );

      test('leg switches are ignored outside capture mode', () {
        _floorPoint(controller, 0, 10);
        _floorPoint(controller, 10, 17);
        _floorPoint(controller, 20, 24);
        controller.setHeapGrowingLegsForCapture(floor: false);
        expect(
          _heapGrowing(controller)!.extraTraceArgs!['heapGrowingLeg'],
          'floor',
        );
      });
    });

    group('allocation-profile hold', () {
      late VmServiceClient realClient;
      late FakeVmService service;

      setUp(() async {
        service = FakeVmService();
        realClient = VmServiceClient(
          ownIsolateIdResolver: () => 'isolates/1',
          onHeapSample: (_) {},
        );
        expect(await realClient.startSessionForTest(service), isTrue);
        controller.setVmClientForTest(realClient);
      });

      tearDown(() => realClient.dispose());

      int profileRequests() => service.isolateRpcCalls
          .where((c) => c.$1 == 'getAllocationProfile')
          .length;

      test('a held controller sends no enrichment read; after release the '
          'next episode reads', () async {
        expect(await controller.holdAllocationProfileReads(), isTrue);
        _growHeap(controller);
        await Future<void>.delayed(Duration.zero);
        expect(_heapGrowing(controller), isNotNull);
        expect(profileRequests(), 0);

        controller
          ..releaseAllocationProfileReads()
          ..resetCaptureState()
          ..lastAllocationEnrichmentTimeForTest = null;
        _growHeap(controller);
        await Future<void>.delayed(Duration.zero);
        expect(profileRequests(), 1);
        expect(service.allocationProfileResets.single, isFalse);
      });

      test('the hold waits for a read already in flight', () async {
        final gate = service.allocationProfileGate = Completer<void>();
        _growHeap(controller);
        await Future<void>.delayed(Duration.zero);
        expect(profileRequests(), 1);

        var drained = false;
        final hold = controller
            .holdAllocationProfileReads(timeout: const Duration(seconds: 2))
            .then((value) => drained = value);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(drained, isFalse);

        gate.complete();
        await hold;
        expect(drained, isTrue);
        controller.releaseAllocationProfileReads();
      });
    });

    test(
      'Sleuth.holdAllocationProfileReads is false before Sleuth starts',
      () async {
        expect(await Sleuth.holdAllocationProfileReads(), isFalse);
        Sleuth.releaseAllocationProfileReads();
      },
    );
  });
}
