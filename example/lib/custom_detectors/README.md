# Custom detector cookbook

These three reference custom detectors cover the shapes you are most
likely to need. Each file is a complete, runnable detector with comments
that explain it. Pick the simplest shape that fits your use case, and
move to a larger one only when you need what it adds.

| File | Shape | Use when... |
|------|-------|-------------|
| [`01_simple_structural_detector.dart`](01_simple_structural_detector.dart) | `SimpleStructuralDetector` | You only need to inspect widgets and emit one issue per match. It includes a filter that skips the standard Material tooltips (Back, Close, etc.) |
| [`02_runtime_callback_detector.dart`](02_runtime_callback_detector.dart) | `BaseDetector` with `DetectorLifecycle.runtime` | You need to observe app events (frames, routes, lifecycle) without walking the tree |
| [`03_hybrid_vm_structural_detector.dart`](03_hybrid_vm_structural_detector.dart) | `BaseDetector` with `DetectorLifecycle.hybrid` | You are combining VM timeline data with tree scanning |

## Wiring a custom detector

Pass instances to `SleuthConfig.customDetectors`:

```dart
Sleuth.track(
  child: const MyApp(),
  config: SleuthConfig(
    customDetectors: [
      TooltipUsageDetector(),
      SlowFrameDetector(),
      RasterHotSpotDetector(),
    ],
  ),
);
```

## Disabling a custom detector

Set the `key` parameter when you construct the detector (all three
cookbook detectors already do this), then list the key in
`disabledCustomDetectorKeys`:

```dart
SleuthConfig(
  customDetectors: [TooltipUsageDetector()],
  disabledCustomDetectorKeys: {'tooltip_usage'},
)
```

The controller applies the set once, when it initialises its detectors
(`_initializeDetectors()`). Setting `detector.isEnabled = true` after
that still turns the detector on, because the set is not read again.

## Which shape should I pick?

Start at the top of this list and stop at the first "yes":

1. **"I only need to look at widgets in the build tree."**
   Use `SimpleStructuralDetector` (file 01).
2. **"I need to observe something Flutter tells me about (frames,
   routes, lifecycle) but I don't need the tree."**
   Use `BaseDetector` with `DetectorLifecycle.runtime` (file 02).
3. **"I need VM timeline data (raster, GC, build times)."**
   Use `BaseDetector` with `DetectorLifecycle.hybrid` if you also walk
   the tree, or `DetectorLifecycle.vmOnly` if you don't (file 03).

## Reading more

- [`BaseDetector`](../../../lib/src/models/base_detector.dart) has the
  full lifecycle contract: `prepareScan`, `checkElement`, `afterElement`
  and `finalizeScan`, plus `processTimelineData`, `processFrame` and the
  `vmConnected` setter.
- [`SimpleStructuralDetector`](../../../lib/src/models/simple_structural_detector.dart)
  is the helper that file 01 uses.
- [`lib/src/detectors/`](../../../lib/src/detectors/) holds the 20
  built-in detectors, each a production reference implementation.
