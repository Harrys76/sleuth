import 'dart:async';

import 'package:vm_service/vm_service.dart';

/// A [VmService] for tests that run `VmServiceClient`'s real session
/// start (`startSessionForTest`).
///
/// Records every call in [calls] in order, the isolate id passed to each
/// isolate-scoped RPC in [isolateRpcCalls], and every stream id passed to
/// `streamListen` in [streamListenCalls]. GC, Extension and Timer events
/// are pushed through [gcController], [extensionController] and
/// [timerController]; [streamListenErrors] makes `streamListen` fail for
/// a stream id, as an older VM does for `Timer`. `getVM` and
/// `getAllocationProfile` can be held open; `getVM` can be made to
/// throw.
class FakeVmService implements VmService {
  FakeVmService({List<IsolateRef>? isolates})
    : isolates = isolates ?? [isolateRef('isolates/1')];

  /// Isolates `getVM` reports.
  List<IsolateRef> isolates;

  /// Method names in call order.
  final List<String> calls = [];

  /// Stream ids passed to `streamListen`.
  final List<String> streamListenCalls = [];

  /// `(method, isolateId)` for `getMemoryUsage`, `getCpuSamples` and
  /// `getAllocationProfile`.
  final List<(String, String)> isolateRpcCalls = [];

  int getVMCallCount = 0;

  /// While set, `getVM` waits for this to complete.
  Completer<void>? getVMGate;

  /// Thrown by every `getVM` call while set.
  Object? getVMThrows;

  /// Thrown by the isolate-scoped RPCs while set.
  Object? isolateRpcThrows;

  /// While set, `getAllocationProfile` waits for this to complete.
  Completer<void>? allocationProfileGate;

  /// `reset` values passed to `getAllocationProfile`, in call order.
  final List<bool?> allocationProfileResets = [];

  final StreamController<Event> gcController =
      StreamController<Event>.broadcast(sync: true);
  final StreamController<Event> extensionController =
      StreamController<Event>.broadcast(sync: true);
  final StreamController<Event> timerController =
      StreamController<Event>.broadcast(sync: true);
  final StreamController<Event> debugController =
      StreamController<Event>.broadcast(sync: true);
  final StreamController<Event> isolateController =
      StreamController<Event>.broadcast(sync: true);

  /// Errors `streamListen` throws, by stream id.
  final Map<String, Object> streamListenErrors = {};
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get onDone => _done.future;

  @override
  Stream<String> get onSend => const Stream.empty();

  @override
  Stream<String> get onReceive => const Stream.empty();

  @override
  Future<Success> setVMTimelineFlags(List<String> recordedStreams) async {
    calls.add('setVMTimelineFlags');
    return Success();
  }

  @override
  Future<Success> streamListen(String streamId) async {
    calls.add('streamListen:$streamId');
    streamListenCalls.add(streamId);
    final error = streamListenErrors[streamId];
    if (error != null) throw error;
    return Success();
  }

  @override
  Future<Success> streamCancel(String streamId) async => Success();

  @override
  Future<VM> getVM() async {
    calls.add('getVM');
    getVMCallCount++;
    final gate = getVMGate;
    if (gate != null) await gate.future;
    final error = getVMThrows;
    if (error != null) throw error;
    return VM(
      name: 'fake',
      architectureBits: 64,
      hostCPU: 'arm64',
      operatingSystem: 'ios',
      targetCPU: 'arm64',
      version: '1.0',
      pid: 1,
      startTime: 0,
      isolates: isolates,
      isolateGroups: [],
      systemIsolates: [],
      systemIsolateGroups: [],
    );
  }

  @override
  Future<MemoryUsage> getMemoryUsage(String isolateId) async {
    isolateRpcCalls.add(('getMemoryUsage', isolateId));
    final error = isolateRpcThrows;
    if (error != null) throw error;
    return MemoryUsage(heapUsage: 1, heapCapacity: 2, externalUsage: 0);
  }

  @override
  Future<CpuSamples> getCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  ) async {
    isolateRpcCalls.add(('getCpuSamples', isolateId));
    final error = isolateRpcThrows;
    if (error != null) throw error;
    return CpuSamples(
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
    isolateRpcCalls.add(('getAllocationProfile', isolateId));
    allocationProfileResets.add(reset);
    final gate = allocationProfileGate;
    if (gate != null) await gate.future;
    final error = isolateRpcThrows;
    if (error != null) throw error;
    return AllocationProfile(members: []);
  }

  @override
  Future<Timeline> getVMTimeline({
    int? timeOriginMicros,
    int? timeExtentMicros,
  }) async =>
      Timeline(traceEvents: [], timeOriginMicros: 0, timeExtentMicros: 0);

  @override
  Future<Timestamp> getVMTimelineMicros() async =>
      Timestamp(timestamp: 1 << 40);

  @override
  Stream<Event> get onGCEvent => gcController.stream;

  @override
  Stream<Event> get onExtensionEvent => extensionController.stream;

  @override
  Stream<Event> get onTimelineEvent => const Stream.empty();

  @override
  Stream<Event> get onDebugEvent => debugController.stream;

  @override
  Stream<Event> get onIsolateEvent => isolateController.stream;

  @override
  Stream<Event> onEvent(String streamId) => switch (streamId) {
    'GC' => gcController.stream,
    'Extension' => extensionController.stream,
    'Timer' => timerController.stream,
    'Debug' => debugController.stream,
    'Isolate' => isolateController.stream,
    _ => const Stream.empty(),
  };

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A non-system isolate reference with [id], in the VM's
/// `isolates/<number>` form.
IsolateRef isolateRef(String id, {String group = 'isolateGroups/1'}) {
  final number = id.split('/').last;
  return IsolateRef(
    id: id,
    number: number,
    name: 'isolate-$number',
    isSystemIsolate: false,
    isolateGroupId: group,
  );
}

/// A kGC event posted for [isolateId]. Omit [isolateId] for an event
/// without an isolate ref. [newUsed] and [oldUsed] are the bytes left in
/// each space after the collection.
Event gcEvent({
  String? isolateId,
  String gcType = 'Scavenge',
  double? newTime,
  double? oldTime,
  String group = 'isolateGroups/1',
  String? reason,
  int? newUsed,
  int? oldUsed,
  int timestampMs = 0,
}) {
  return Event.parse({
    'type': 'Event',
    'kind': 'GC',
    'timestamp': timestampMs,
    'gcType': gcType,
    'reason': ?reason,
    if (isolateId != null)
      'isolate': {
        'type': '@Isolate',
        'id': isolateId,
        'number': isolateId.split('/').last,
        'name': 'main',
        'isSystemIsolate': false,
        'isolateGroupId': group,
      },
    if (newTime != null || newUsed != null)
      'new': {'type': 'HeapSpace', 'time': ?newTime, 'used': ?newUsed},
    if (oldTime != null || oldUsed != null)
      'old': {'type': 'HeapSpace', 'time': ?oldTime, 'used': ?oldUsed},
  })!;
}

/// A `TimerSignificantlyOverdue` event, as the VM posts on its `Timer`
/// stream, for [isolateId] (omit for an event without an isolate ref).
Event timerOverdueEvent({
  String? isolateId,
  int overdueMs = 150,
  String? details,
  int timestampMs = 0,
}) {
  return Event.parse({
    'type': 'Event',
    'kind': 'TimerSignificantlyOverdue',
    'timestamp': timestampMs,
    'details':
        details ??
        'A timer should have fired $overdueMs ms ago, but just fired now.',
    if (isolateId != null)
      'isolate': {
        'type': '@Isolate',
        'id': isolateId,
        'number': isolateId.split('/').last,
        'name': 'main',
        'isSystemIsolate': false,
        'isolateGroupId': 'isolateGroups/1',
      },
  })!;
}

/// A `Debug` or `Isolate` stream event of [kind] (`PauseBreakpoint`,
/// `Resume`, `IsolateReload`, ...) for [isolateId] at [timestampMs].
Event isolateStateEvent({
  required String kind,
  String? isolateId,
  int timestampMs = 0,
}) {
  return Event.parse({
    'type': 'Event',
    'kind': kind,
    'timestamp': timestampMs,
    if (isolateId != null)
      'isolate': {
        'type': '@Isolate',
        'id': isolateId,
        'number': isolateId.split('/').last,
        'name': 'main',
        'isSystemIsolate': false,
        'isolateGroupId': 'isolateGroups/1',
      },
  })!;
}
