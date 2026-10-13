import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' as vm;

/// Checks the captured GC event fixture against the shape the client,
/// the controller and the memory detector read: `kind`, the isolate ref
/// and its group, `gcType`, and the cumulative `time` of both heap
/// spaces. The events are raw `EventStreams.kGC` payloads recorded on a
/// device (see the fixture's `provenance`), so a change in the VM's
/// event shape fails here before production falls behind.
void main() {
  final fixture =
      jsonDecode(
            File(
              'test/detectors/_fixtures/gc_events_ios_profile.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final events = [
    for (final e in fixture['events'] as List)
      vm.Event.parse(e as Map<String, dynamic>)!,
  ];
  final pair = [
    for (final e in fixture['duplicatePair'] as List)
      vm.Event.parse(e as Map<String, dynamic>)!,
  ];

  test('the fixture records where it was captured', () {
    final provenance = fixture['provenance'] as Map<String, dynamic>;
    expect(provenance['device'], isNotEmpty);
    expect(provenance['vmVersion'], isNotEmpty);
    expect(provenance['appIsolateId'], startsWith('isolates/'));
  });

  test('every event is a GC event with an isolate ref and its group', () {
    expect(events, isNotEmpty);
    for (final event in [...events, ...pair]) {
      expect(event.kind, vm.EventKind.kGC);
      expect(event.timestamp, isNotNull);
      expect(event.isolate?.id, startsWith('isolates/'));
      expect(event.isolate?.isolateGroupId, startsWith('isolateGroups/'));
    }
  });

  test('gcType values are the VM names the detector classifies', () {
    const known = {
      'Scavenge',
      'Evacuate',
      'StartCMark',
      'MarkSweep',
      'MarkCompact',
    };
    final types = {for (final e in events) e.json?['gcType']};
    expect(known, containsAll(types));
    // A concurrent old-generation cycle starts with StartCMark; the
    // legacy 'StartConcurrentMark' spelling never appears.
    expect(types, contains('StartCMark'));
    expect(types, isNot(contains('StartConcurrentMark')));
  });

  test('both heap spaces carry a numeric cumulative time', () {
    for (final event in [...events, ...pair]) {
      for (final space in ['new', 'old']) {
        final heap = event.json?[space] as Map<String, dynamic>;
        expect(heap['time'], isA<num>(), reason: '$space.time');
      }
    }
  });

  test('a collection posted for two isolates carries identical stats', () {
    final [a, b] = pair;
    expect(a.isolate?.id, isNot(b.isolate?.id));
    expect(a.isolate?.isolateGroupId, b.isolate?.isolateGroupId);
    expect(a.timestamp, b.timestamp);
    for (final key in ['gcType', 'reason']) {
      expect(a.json?[key], b.json?[key], reason: key);
    }
    for (final space in ['new', 'old']) {
      final heapA = a.json?[space] as Map<String, dynamic>;
      final heapB = b.json?[space] as Map<String, dynamic>;
      expect(heapA['time'], heapB['time'], reason: '$space.time');
      expect(heapA['collections'], heapB['collections']);
    }
  });
}
