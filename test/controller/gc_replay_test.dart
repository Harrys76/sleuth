import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';
import 'package:vm_service/vm_service.dart' as vm;

import '../helpers/fake_vm_service.dart';

/// Replays a captured GC event stream (an iPhone 12 profile run with
/// `Isolate.run` helpers alive, see the fixture's `provenance`) through
/// the client's real GC listener and the controller's `_onGcEvent`.
void main() {
  final fixture =
      jsonDecode(
            File(
              'test/detectors/_fixtures/gc_dump_multi_isolate_ios_profile.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final appIsolateId =
      (fixture['provenance'] as Map<String, dynamic>)['appIsolateId'] as String;
  final events = [
    for (final e in fixture['events'] as List)
      vm.Event.parse(e as Map<String, dynamic>)!,
  ];
  final own = [
    for (final e in events)
      if (e.isolate?.id == appIsolateId) e,
  ];
  final isolates = {
    for (final e in events) e.isolate!.id!,
  }.map(isolateRef).toList();

  double cumulative(vm.Event e) =>
      ((e.json!['new'] as Map)['time'] as num).toDouble() +
      ((e.json!['old'] as Map)['time'] as num).toDouble();

  test('the fixture holds copies of the same collections on helper '
      'isolates', () {
    expect(own.length, lessThan(events.length));
    expect(own, isNotEmpty);
  });

  test('a verified client passes exactly the app isolate\'s events, in '
      'order', () async {
    final delivered = <vm.Event>[];
    final service = FakeVmService(isolates: isolates);
    final client = VmServiceClient(
      ownIsolateIdResolver: () => appIsolateId,
      onGcEvent: delivered.add,
    );
    addTearDown(client.dispose);
    await client.startSessionForTest(service);
    expect(client.isOwnIsolateVerified, isTrue);

    events.forEach(service.gcController.add);

    expect(delivered.map((e) => e.timestamp), own.map((e) => e.timestamp));
    expect(delivered.every((e) => e.isolate?.id == appIsolateId), isTrue);
  });

  test('through the controller, the detector counts each collection once '
      'and sums the measured pauses', () async {
    final controller = SleuthController(
      config: const SleuthConfig(gcRateThresholdPerMin: 30),
    );
    addTearDown(controller.dispose);
    controller.initializeDetectorsForTest();
    final memory = controller.memoryPressureDetector!;
    final service = FakeVmService(isolates: isolates);
    final client = VmServiceClient(
      ownIsolateIdResolver: () => appIsolateId,
      onGcEvent: controller.feedGcEventForTest,
    );
    addTearDown(client.dispose);
    await client.startSessionForTest(service);
    controller.setVmClientForTest(client);

    // The first collection only sets the pause baseline. `reset` clears
    // its window record and keeps the baseline.
    service.gcController.add(own.first);
    memory.reset();
    for (final e in events.skip(events.indexOf(own.first) + 1)) {
      service.gcController.add(e);
    }

    final counted = own.skip(1).toList();
    int ofType(String type) =>
        counted.where((e) => e.json!['gcType'] == type).length;
    final stats = memory.gcWindowStats;
    expect(stats.events, counted.length);
    expect(stats.young, ofType('Scavenge') + ofType('Evacuate'));
    expect(stats.old, ofType('MarkSweep') + ofType('MarkCompact'));
    expect(stats.markStarts, ofType('StartCMark'));
    expect(stats.pauseAvailable, isTrue);
    expect(
      stats.pauseMs,
      closeTo((cumulative(own.last) - cumulative(own.first)) * 1000, 1e-6),
    );

    final args = memory.issues
        .singleWhere((i) => i.stableId == 'gc_pressure')
        .extraTraceArgs!;
    expect(args['observedGcEvents'], '${counted.length}');
    expect(args.containsKey('gcPauseMs'), isTrue);
  });

  test('an at-leg dump publishes the floor leg through the client and '
      'controller, within 1 % of the operator rate', () async {
    final dump =
        jsonDecode(
              File(
                'test/detectors/_fixtures/heap_floor/at1.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final replay = dump['replay'] as Map<String, dynamic>;
    final own =
        (dump['provenance'] as Map<String, dynamic>)['appIsolateId'] as String;
    // The controller's detector reads the wall clock and ignores its first
    // 30 s, so the dump is shifted to start 35 s from now.
    final beginMs =
        (replay['tapMs'] as int) +
        ((replay['scenarioBeginSec'] as num) * 1000).round();
    final shift = DateTime.now().millisecondsSinceEpoch + 35000 - beginMs;
    final shifted = [
      for (final e in (dump['events'] as List).cast<Map<String, dynamic>>())
        if ((e['timestamp'] as int) >= beginMs)
          vm.Event.parse({...e, 'timestamp': (e['timestamp'] as int) + shift})!,
    ];

    final controller = SleuthController(
      config: const SleuthConfig(memoryWarmupDurationMs: 0),
    );
    addTearDown(controller.dispose);
    controller.initializeDetectorsForTest();
    final service = FakeVmService(isolates: [isolateRef(own)]);
    final client = VmServiceClient(
      ownIsolateIdResolver: () => own,
      onGcEvent: controller.feedGcEventForTest,
    );
    addTearDown(client.dispose);
    await client.startSessionForTest(service);
    controller.setVmClientForTest(client);

    String? firstSlope;
    for (final e in shifted) {
      service.gcController.add(e);
      final issue = controller.memoryPressureDetector!.issues
          .where((i) => i.stableId == 'heap_growing')
          .firstOrNull;
      if (issue != null) {
        expect(issue.extraTraceArgs!['heapGrowingLeg'], 'floor');
        firstSlope = issue.extraTraceArgs!['observedFloorSlopeBytesPerSec'];
        break;
      }
    }
    final operator = replay['operatorBytesPerSec'] as int;
    expect(firstSlope, isNotNull);
    expect(double.parse(firstSlope!), closeTo(operator, operator * 0.01));
  });
}
