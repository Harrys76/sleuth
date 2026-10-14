import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:example/demos/heap_growing_capture_check.dart';

/// A wrapped capture with the scenario span and the given in-span
/// `heap_growing` record args.
String _capture(String scenario, List<Map<String, String>> records) =>
    jsonEncode({
      'traceEvents': [
        {
          'name': 'sleuth.scenario.begin',
          'ph': 'i',
          'ts': 1000,
          'args': {'name': scenario},
        },
        for (final (i, args) in records.indexed)
          {
            'name': 'sleuth.issue.heap_growing.warning',
            'ph': 'i',
            'ts': 2000 + i,
            'args': args,
          },
        {
          'name': 'sleuth.scenario.end',
          'ph': 'i',
          'ts': 9000,
          'args': {'name': scenario},
        },
      ],
      'sleuthMetadata': <String, Object?>{},
    });

String? _check(
  HeapGrowingCaptureLeg leg,
  String role,
  List<Map<String, String>> records,
) => checkHeapGrowingCapture(
  _capture('${leg.scenarioPrefix}$role', records),
  leg: leg,
  role: role,
  bandMin: 512000,
  bandMax: 768000,
);

void main() {
  const floor = HeapGrowingCaptureLeg.floor;
  const sample = HeapGrowingCaptureLeg.sample;

  test('a floor run with in-band floor records passes', () {
    expect(
      _check(floor, 'at', [
        {'observedFloorSlopeBytesPerSec': '574000'},
      ]),
      isNull,
    );
  });

  test('a floor run without a record fails', () {
    expect(_check(floor, 'at', []), contains('did not fire'));
  });

  test('a floor run holding a sample-leg record fails', () {
    expect(
      _check(floor, 'at', [
        {'observedFloorSlopeBytesPerSec': '574000'},
        {'observedSlopeBytesPerSec': '611000'},
      ]),
      contains('other leg'),
    );
  });

  test('a sample run with an out-of-band record fails', () {
    expect(
      _check(sample, 'at', [
        {'observedSlopeBytesPerSec': '900000'},
      ]),
      contains('outside'),
    );
  });

  test('a below run with any record fails', () {
    expect(
      _check(sample, 'below', [
        {'observedSlopeBytesPerSec': '516000'},
      ]),
      contains('below the threshold'),
    );
    expect(_check(sample, 'below', []), isNull);
  });

  test('the scenario name and file name carry the leg', () {
    expect(floor.scenarioPrefix, 'memory_pressure_heap_growing_floor_');
    expect('${floor.fileStem}at.json', 'heap_growing_floor_at.json');
    expect(sample.scenarioPrefix, 'memory_pressure_heap_growing_');
    expect(
      heapGrowingCaptureSlope(
        _capture('${floor.scenarioPrefix}above', [
          {'observedFloorSlopeBytesPerSec': '784000'},
          {'observedFloorSlopeBytesPerSec': '790000'},
        ]),
        leg: floor,
        role: 'above',
      ),
      790000,
    );
  });
}
