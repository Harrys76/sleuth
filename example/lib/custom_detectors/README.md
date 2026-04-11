# Custom Detector Cookbook

Three reference custom detectors covering the shapes you're most likely
to need. Each file is a complete, runnable detector with explanatory
comments. Pick the simplest shape that fits your use case — escalate
only when you actually need the extra machinery.

| File | Shape | Use when... |
|------|-------|-------------|
| [`01_simple_structural_detector.dart`](01_simple_structural_detector.dart) | `SimpleStructuralDetector` | You only need to inspect widgets and emit one issue per match. Includes a framework-tooltip filter to skip standard Material tooltips (Back, Close, etc.) |
| [`02_runtime_callback_detector.dart`](02_runtime_callback_detector.dart) | `BaseDetector` with `DetectorLifecycle.runtime` | You need to observe app events (frames, routes, lifecycle) without walking the tree |
| [`03_hybrid_vm_structural_detector.dart`](03_hybrid_vm_structural_detector.dart) | `BaseDetector` with `DetectorLifecycle.hybrid` | You're combining VM timeline data with tree scanning |

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

Set the `key` parameter when constructing the detector (all three
cookbook detectors already do this), then list the key in
`disabledCustomDetectorKeys`:

```dart
SleuthConfig(
  customDetectors: [TooltipUsageDetector()],
  disabledCustomDetectorKeys: {'tooltip_usage'},
)
```

The gate applies once at controller initialisation. Runtime flips of
`detector.isEnabled = true` after init still win — the disabled set is
only consulted during `_initializeDetectors()`.

## Which shape should I pick?

Start at the top of this decision tree and stop at the first "yes":

1. **"I only need to look at widgets in the build tree."**
   → `SimpleStructuralDetector`. File 01.
2. **"I need to observe something Flutter tells me about (frames,
   routes, lifecycle) but I don't need the tree."**
   → `BaseDetector` with `DetectorLifecycle.runtime`. File 02.
3. **"I need VM timeline data (raster, GC, build times)."**
   → `BaseDetector` with `DetectorLifecycle.hybrid` (if you also walk
   the tree) or `DetectorLifecycle.vmOnly` (if you don't). File 03.

## Reading more

- [`BaseDetector`](../../../lib/src/models/base_detector.dart) — full
  lifecycle contract (`prepareScan` / `checkElement` / `afterElement` /
  `finalizeScan` plus `processTimelineData` and `vmConnected`).
- [`SimpleStructuralDetector`](../../../lib/src/models/simple_structural_detector.dart)
  — the helper used by file 01.
- [`lib/src/detectors/`](../../../lib/src/detectors/) — the 23 built-in
  detectors, each a production-quality reference implementation.
