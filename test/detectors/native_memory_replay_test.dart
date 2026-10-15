// native_memory_growing against recorded heap samples. The Galaxy A07
// fixtures are profile builds on Flutter 3.47.6 (Android 16, Impeller
// Vulkan), the staircases also on an iPhone 12 (iOS 17.5); the idle iPhone
// fixture is the 420-sample run of the heap floor recordings. Each
// fixture's provenance block says how it was recorded.
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/memory_pressure_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/heap_sample_fixture.dart';

const _dir = 'test/detectors/_fixtures/native';

/// Feeds the fixture's samples with the detector clock at each sample's
/// time and returns every `native_memory_growing` issue it emitted, with
/// the seconds since the first sample.
List<(double, PerformanceIssue)> nativeIssues(String path) {
  final samples = loadHeapSamples(path);
  final start = samples.first.timestamp;
  var now = start;
  final detector = MemoryPressureDetector(clock: () => now);
  final seen = <(double, PerformanceIssue)>[];
  for (final sample in samples) {
    now = sample.timestamp;
    detector.processHeapSample(sample);
    for (final issue in detector.issues) {
      if (issue.stableId == 'native_memory_growing') {
        seen.add((now.difference(start).inMilliseconds / 1000, issue));
      }
    }
  }
  detector.dispose();
  return seen;
}

bool firesNative(String path) => nativeIssues(path).isNotEmpty;

/// The MB/s figure in a `native_memory_growing` title.
double titleRate(PerformanceIssue issue) => double.parse(
  RegExp(r'\+([0-9.]+) MB/s').firstMatch(issue.title)!.group(1)!,
);

void main() {
  test('Galaxy A07: RSS jumping once when the GPU demo opens is not native '
      'growth', () {
    // RSS goes from about 300 to 350 MB in one sample, then stays flat.
    expect(firesNative('$_dir/android_gpu_ramp.json'), isFalse);
  });

  test('Galaxy A07: RSS jumping once when the FPS stress demo opens is not '
      'native growth', () {
    expect(firesNative('$_dir/galaxy_fps_jump.json'), isFalse);
  });

  for (final (device, file) in [
    ('Galaxy A07', 'galaxy_staircase.json'),
    ('iPhone 12', 'iphone_staircase.json'),
  ]) {
    test('$device: a staircase of 10 MB native allocations is native '
        'growth', () {
      // Fourteen taps 2.5 s apart start about 55 s into the samples.
      final seen = nativeIssues('$_dir/$file');
      expect(seen, isNotEmpty);
      final (at, issue) = seen.first;
      expect(at, inInclusiveRange(55, 95));
      expect(titleRate(issue), inInclusiveRange(1, 6));
    });
  }

  test('Galaxy A07: freeing 64 MB of Dart objects is not native growth', () {
    // The VM returned the pages, so RSS fell with the heap.
    expect(
      firesNative('test/detectors/_fixtures/native/android_heap_drop.json'),
      isFalse,
    );
  });

  test('iPhone 12: an idle app is not native growth', () {
    expect(
      firesNative('test/detectors/_fixtures/heap_floor/idle.json'),
      isFalse,
    );
  });
}
