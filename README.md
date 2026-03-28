# widget_watchdog

A runtime performance diagnostics package for Flutter mobile apps. Combines frame timing, optional VM timeline analysis, and widget-tree heuristics to surface bottlenecks and actionable fixes — directly inside your app.

## How It Works

Widget Watchdog runs three layers of analysis:

1. **Frame timing** (FrameTiming API) — per-frame build and raster duration, vsync overhead, cache stats. Works on every platform in debug and profile mode. This is the primary signal.
2. **VM timeline** (vm_service) — when connected, provides sub-phase breakdowns (buildScope, flushLayout, flushPaint, raster). Best-effort; availability depends on platform and runtime environment.
3. **Widget tree scan** (post-frame walk, 1x/sec) — finds structural anti-patterns like non-lazy lists, uncached images, excessive GlobalKeys, and more.
4. **Network monitoring** (HttpOverrides) — transparent HTTP interception that detects slow requests, frequency spikes, and oversized responses without modifying app networking code.

## Quick Start

```dart
import 'package:widget_watchdog/widget_watchdog.dart';

void main() => runApp(WidgetWatchdog.wrap(child: MyApp()));
```

The overlay appears in debug and profile mode. Completely disabled in release builds.

## Running

```bash
# Profile mode (recommended — accurate timing data)
flutter run --profile

# Debug mode (works, but timing is less representative)
flutter run
```

## Platform Support

| Platform | Frame Timing | VM Full Mode | Notes |
|----------|:---:|:---:|-------|
| Android device | Yes | Best-effort | VM service may not connect via adb forwarding |
| Android emulator | Yes | Best-effort | Same adb limitation applies |
| iOS device | Yes | Good | Profile mode recommended |
| Desktop | Yes | Good | Strongest VM connectivity |

**Frame timing mode** is the universal cross-platform path and provides accurate build/raster timing in profile builds.

**VM full mode** adds sub-phase breakdown (build vs layout vs paint vs raster) but depends on VM service connectivity, which varies by platform. The package falls back gracefully to frame timing mode when VM is unavailable.

## Configuration

```dart
WidgetWatchdog.wrap(
  child: MyApp(),
  config: WatchdogConfig(
    fpsTarget: 60,
    rebuildThreshold: 10,
    maxListChildren: 20,
    maxGlobalKeys: 10,
    platformChannelLimit: 20,
    treeScanIntervalMs: 1000,
    captureBufferCapacity: 50,        // max jank frames retained for export
    enableDebugCallbacks: false,       // opt-in: per-widget rebuild/repaint hooks (conflicts with DevTools)
    enableDeepDebugInstrumentation: false, // opt-in: heavy per-widget timeline events
    maxTrackedTypes: 200,              // cap on tracked widget types in debug callbacks
    enableNetworkMonitoring: true,     // HTTP interception via HttpOverrides
    slowRequestThresholdMs: 2000,      // flag requests slower than this
    requestFrequencyLimit: 30,         // max requests per 5s window
    largeResponseThresholdBytes: 1048576, // flag responses larger than 1MB
    networkExcludePatterns: ['analytics.example.com'], // exclude URLs from monitoring
    enabledDetectors: {
      DetectorType.frameTiming,
      DetectorType.rebuild,
      DetectorType.imageMemory,
      // ... add only the detectors you need
    },
  ),
);
```

**Debug callbacks note:** `enableDebugCallbacks` installs `debugOnRebuildDirtyWidget` and `debugOnProfilePaint` hooks. These conflict with DevTools "Track Widget Rebuilds" — only one can be active at a time. Default `false` to avoid surprising DevTools users.

## Session Export

Export captured jank data and current issues as JSON for sharing or comparison:

```dart
// Get a SessionSnapshot object
final snapshot = WidgetWatchdog.exportSnapshot();

// Or get formatted JSON directly
final json = WidgetWatchdog.exportSnapshotJson();
```

The dashboard also includes an export button that copies the JSON snapshot to the clipboard.

Returns `null` in release mode, before `wrap()` is called, or after overlay disposal.

## Confidence Levels

Issues include a confidence level reflecting evidence quality:

| Level | Meaning | Example |
|-------|---------|---------|
| **Confirmed** | Directly observed runtime condition | Jank frame measured at 32ms |
| **Likely** | Runtime signal + structural evidence | Raster-dominant frame + deep opacity subtree |
| **Possible** | Structural heuristic only | Non-lazy list with 50 children found |

## Detector Matrix

### Runtime Detectors (always available)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Frame Timing | FrameTiming API | Frame exceeded budget | Confirmed | Cannot attribute to specific widget |
| Network Monitor | HttpOverrides | Slow, excessive, or oversized HTTP requests | Confirmed | Only intercepts dart:io HttpClient (not package:http directly) |

### VM-Only Detectors (require VM connection)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Shader Jank | VM Timeline | Shader compilation occurred | Confirmed | Requires VM connection |
| Heavy Compute | VM Timeline | Long UI-thread event | Confirmed | Requires VM connection |
| Platform Channel | VM Timeline | High call frequency | Confirmed | Requires VM connection |
| Memory Pressure | VM GC events | GC frequency elevated | Likely | Heap growth requires VM stats |
| Repaint | VM Timeline | High paint frequency | Confirmed | Requires VM connection |

### Hybrid Detectors (VM + tree scan, degrade without VM)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Rebuild | VM build count + tree | High rebuild activity | Confirmed for count, Possible for widget attribution | Degrades to structural density report without VM |
| GPU Pressure | VM raster timing + render tree | Raster thread dominance | Confirmed for ratio, Likely when nodes coexist | Degrades to structural node detection without VM |
| Shallow Rebuild Risk | VM build count + tree depth | Shallow StatefulWidgets exist during high build activity | Possible | Degrades to structural risk report without VM |

### Structural Detectors (tree scan only)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| setState Scope | Element tree | StatefulWidget owns large subtree | Possible–Likely | Needs rebuild evidence to confirm |
| Layout Bottleneck | Render tree | IntrinsicHeight/Width present | Possible | Present does not mean slow |
| ListView | Element tree | Non-lazy list with many children | Possible | May be intentional for small lists |
| Image Memory | Element tree | Image without cacheWidth/Height | Possible | Small images may not matter |
| GlobalKey | Element tree | Many GlobalKeys in scrollable | Possible | May be necessary for state preservation |
| Nested Scroll | Element tree | Scroll-inside-scroll pattern | Possible | May be intentional with NeverScrollableScrollPhysics |
| CustomPainter | Element tree | shouldRepaint always true | Possible | May be needed for animated painters |
| Keep Alive | Element tree | Many keep-alive pages | Possible | Trade-off between memory and rebuild cost |
| AnimatedBuilder | Element tree | No child param on large subtree | Possible | Only matters if subtree is large |
| Opacity | Element tree | Opacity(0.0) widget present | Possible | Widget still participates in hit testing and semantics |
| Font Loading | Element tree | Non-system font in use | Possible | Font may already be loaded |

## What This Does Better Than DevTools

- **Always on**: no separate tool window, no connection setup — performance data is visible as you use your app
- **Structural analysis**: finds anti-patterns (non-lazy lists, uncached images, excessive GlobalKeys) that DevTools does not flag
- **Network monitoring**: in-app detection of slow requests, request floods, and oversized responses with actionable fix hints
- **Actionable fix hints**: every issue includes what to change, not just what went wrong
- **Zero setup**: one line of code, no browser tab, no port forwarding

## What DevTools Still Does Better

- **Exact timeline analysis**: DevTools provides precise per-frame timeline with full event detail
- **Memory inspection**: DevTools has heap snapshots, allocation tracking, and real leak detection
- **CPU profiling**: DevTools can profile Dart code execution with call stacks
- **Network inspection**: DevTools monitors individual HTTP request/response bodies and WebSocket traffic (Watchdog only tracks timing, size, and frequency — not payloads)
- **Widget-exact attribution**: DevTools can trace rebuilds to specific widgets via the inspector

Widget Watchdog is best used for **fast in-app triage** — catch the problem, understand the category, then use DevTools when you need deeper investigation.

## Unsupported Claims

To set clear expectations:

- This package is **not a replacement** for full DevTools timeline analysis
- It **cannot attribute exact offending widgets** in profile mode (only structural heuristics)
- **VM full mode availability** depends on runtime environment and is not guaranteed on all platforms
- **Memory pressure detection** monitors GC frequency and heap trends, not individual object leaks

## Example App

The `example/` directory includes 15 demo screens, each triggering a specific detector:

```bash
cd example
flutter run
```

Demos cover: high-level setState, non-lazy ListView, IntrinsicHeight abuse, always-repaint CustomPainter, uncached images, GlobalKey overuse, nested scroll, heavy compute, KeepAlive overuse, Opacity zero, AnimatedBuilder without child, shallow rebuild risk, font loading stress, repaint stress, and network stress.

Each demo includes `BAD:` and `FIX:` annotations explaining the anti-pattern and its fix.

## Dependencies

- `vm_service: ^14.0.0` — optional VM timeline data when connected

## License

MIT
