// native_memory_growing against recorded heap samples. The Galaxy A07
// fixtures are profile builds on Flutter 3.47.6 (Android 16, Impeller
// Vulkan); the iPhone fixture is the 420-sample idle run of the heap floor
// recordings (iPhone 12, iOS 17.5).
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/memory_pressure_detector.dart';

import '../helpers/heap_sample_fixture.dart';

/// Feeds the fixture's samples with the detector clock at each sample's
/// time and reports whether `native_memory_growing` was ever emitted.
bool firesNative(String path) {
  final samples = loadHeapSamples(path);
  var now = samples.first.timestamp;
  final detector = MemoryPressureDetector(clock: () => now);
  var fired = false;
  for (final sample in samples) {
    now = sample.timestamp;
    detector.processHeapSample(sample);
    fired |= detector.issues.any((i) => i.stableId == 'native_memory_growing');
  }
  detector.dispose();
  return fired;
}

void main() {
  test('Galaxy A07: RSS growing with the GPU demo open is native growth', () {
    // RSS rose about 57 MB in 25 s while the Dart heap stayed under 33 MB.
    expect(
      firesNative('test/detectors/_fixtures/native/android_gpu_ramp.json'),
      isTrue,
    );
  });

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
