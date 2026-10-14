import 'dart:convert';
import 'dart:io';

import 'package:sleuth/src/models/heap_sample.dart';

/// The `heapSamples` of a recorded fixture, in timestamp order.
/// `HeapSample` has no `fromJson`; this keeps the fields the memory
/// detector reads.
List<HeapSample> loadHeapSamples(String path) {
  final json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final samples = [
    for (final s in (json['heapSamples'] as List).cast<Map<String, dynamic>>())
      HeapSample(
        heapUsage: s['heapUsage'] as int,
        heapCapacity: s['heapCapacity'] as int,
        externalUsage: s['externalUsage'] as int? ?? 0,
        timestamp: DateTime.parse(s['timestamp'] as String),
        rssBytes: s['rssBytes'] as int?,
      ),
  ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return samples;
}
