import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' as vm;

/// Sanity-checks that the on-disk GC event fixture parses as a real
/// `vm_service.Event` of kind `GC`. Tests that exercise GC detection via
/// hand-rolled `recordGcCycle()` calls cannot catch a divergence between
/// the synthetic test stub and the actual `EventStreams.kGC` payload — if
/// the upstream package ever changes its event shape (added required
/// field, renamed `kind` enum, restructured `isolate` ref), this fixture
/// is the early-warning canary that surfaces the drift before production
/// silently falls behind.
void main() {
  test('committed GC event fixture parses as vm_service Event of kind GC', () {
    final file = File('test/detectors/_fixtures/gc_event_real.json');
    expect(file.existsSync(), isTrue,
        reason: 'fixture path is referenced from doc/validation_ledger.md '
            'and the GC event regression note in CHANGELOG.md');

    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final event = vm.Event.parse(json);

    expect(event, isNotNull, reason: 'Event.parse should not return null');
    expect(event!.kind, vm.EventKind.kGC,
        reason: 'kGC stream events always carry kind=GC');
    expect(event.timestamp, isNotNull,
        reason: '_onGcEvent depends on event.timestamp for sliding-window '
            'cutoff math; absence would corrupt rate calculation');
    expect(event.isolate, isNotNull,
        reason: 'isolate ref is part of every kGC event in the published '
            'vm_service contract — its absence indicates malformed JSON');
  });
}
