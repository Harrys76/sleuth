# Sleuth — Internals & Detector Reference

Deep reference moved out of the main [README](../README.md) to keep the
landing page focused. This file covers the measurement methodology, the
full detector matrix, recurrence-trend thresholds, startup metrics, and
platform-specific troubleshooting.

## Measurement Window

Sleuth reports the frame total duration (build-to-raster span) from Flutter's `FrameTiming` — not vsync delivery cadence (`CADisplayLink` on iOS, `Choreographer.doFrame` on Android). The two are different metrics: `FrameTiming` reports how long the engine took to produce a frame; vsync-anchored metrics report when the OS displayed it. A frame produced in 3 ms still waits ~13 ms for the next vsync — `FrameTiming` reports 3 ms, vsync metrics report ~16 ms. Cross-framework comparison numbers that mix the two read as large performance deltas where the underlying behaviour is identical.

`FrameTimingDetector` and `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` on each emission based on whether the issue emitted within `DetectorThresholds.startupPhaseWindowSeconds` (default 5 s) of `Sleuth.dartEntryMonotonicUs`. This is **emission-time semantics** — late callback delivery can tag a startup-phase frame as `'steady'` if the emission lands past the window boundary. The tag is observable in capture-mode trace records and audit-gate replay; it is not serialized into saved JSON snapshots. Operators use it to filter startup-phase artefacts (route inflation, font loading, Material animations) from steady-state regressions.

## FPS troubleshooting

**If the overlay shows unexpected FPS:**

1. **`SleuthConfig.fpsTarget` caps the overlay.** A ProMotion 120 Hz device running with the default `fpsTarget: 60` shows `60` in the overlay even while rendering 120 frames/second. Check `actualFpsRaw` in the exported snapshot for the uncapped value.
2. **Warm-up placeholder.** The overlay shows `—` while the rolling window is below 3 samples (≈ 50 ms @ 60 Hz) to avoid flashing a red `0 FPS` at app launch or after navigation.
3. **Debug mode overhead.** Debug builds run ~10× slower than profile mode. Always verify FPS numbers with `flutter run --profile`.
4. **Impeller zeros.** Raster-cache metrics read 0 on Impeller — Sleuth detects this and suppresses cache-family warnings; FPS semantics are unaffected.
5. **Batched callbacks.** The rolling window is anchored on engine `rasterFinish` timestamps, not `DateTime.now()`, so batched `addTimingsCallback` delivery does not distort the count.

`enableDebugCallbacks` installs `debugOnRebuildDirtyWidget` and `debugOnProfilePaint` — these conflict with DevTools "Track Widget Rebuilds", so only one can be active at a time. The package detects the conflict and yields to DevTools if it's already attached.

## Detector Matrix

### Runtime Detectors (always available)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Frame Timing | FrameTiming API | Frame exceeded budget, thread attribution (UI-bound/raster-bound/pipeline stall) | Confirmed | Cannot attribute to specific widget |
| Network Monitor | HttpOverrides | Slow, excessive, oversized, error-spiking, or high-frequency same-path HTTP requests | Confirmed | Only intercepts dart:io HttpClient (not package:http directly) |
| Tracked Resource | `Sleuth.trackResource(name, ref)` + `WeakReference` + Finalizer | Concurrent retention (`> 5` live instances same name) and long-lived retention (single instance alive `> 300 s`) | Confirmed | Opt-in: user code must call `Sleuth.trackResource`. Cross-isolate registration is a no-op |

### VM-Only Detectors (require VM connection)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Shader Jank | VM Timeline | Shader compilation occurred | Confirmed | Requires VM connection. No-op on Impeller (shaders pre-compiled) |
| Heavy Compute | VM Timeline | Long UI-thread event | Confirmed | Requires VM connection |
| Platform Channel | VM Timeline | High call frequency | Confirmed | Requires VM connection and `debugProfilePlatformChannels` |
| Memory Pressure | VM GC events + heap polling | GC frequency elevated, heap growing steadily (linear regression), heap near capacity (>80%) | Likely / Confirmed | Requires VM connection |
| Stream Resource | `getAllocationProfile` class-instance diff (K=4 window) | Retained async resources (dart:async / dart:io / web_socket_channel / rxdart subjects) when `heap_growing` co-fires | Likely | Requires VM connection. Gated on `MemoryPressureDetector.isHeapGrowingActive` |

### Hybrid Detectors (VM + tree scan, degrade without VM)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Rebuild | VM build count + tree | High rebuild activity | Confirmed for count, Possible for widget attribution | Degrades to structural density report without VM |
| GPU Pressure | VM raster timing + render tree | Raster thread dominance | Confirmed for ratio, Likely when nodes coexist | Degrades to structural node detection without VM. Sigma-aware severity for BackdropFilter; ColorFiltered detection via widget type |
| Repaint | VM paint events + per-widget attribution | High paint frequency, animation-owned suppression | Confirmed for rate, Possible for widget attribution | Degrades to structural-only without VM |

### Structural Detectors (tree scan only)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| setState Scope | Element tree | StatefulWidget owns large subtree | Possible–Likely | Needs rebuild evidence to confirm. Const subtree discounting when rebuild evidence present |
| Layout Bottleneck | Render tree | IntrinsicHeight/Width present, Wrap with excessive children | Possible | Present does not mean slow. Framework-internal intrinsics (DropdownButton, AlertDialog) suppressed |
| ListView | Element tree | Non-lazy list with many children | Possible | May be intentional for small lists. Catches ListView/GridView/SliverList non-builder constructors |
| Image Memory | Element tree | Image without cacheWidth/Height | Possible | Images ≤50px suppressed — negligible memory savings |
| CustomPainter | Element tree | shouldRepaint always true | Possible | May be needed for animated painters |
| Keep Alive | Element tree | Many keep-alive pages | Possible | Trade-off between memory and rebuild cost |
| Font Loading | Element tree | Non-system font in use, runtime-loaded fonts (fontFamilyFallback heuristic) | Possible | Font may already be loaded. Runtime detection is heuristic — intentional fallback chains may trigger |
| RepaintBoundary | Element + render tree | Expensive GPU widget without RepaintBoundary ancestor, excessive boundaries in scrollables | Possible–Confirmed | Escalates with debug paint rate evidence. ColorFiltered detected via widget type |
| Startup | `Sleuth.init()` + FrameTiming | TTFF exceeded budget, dominant phase attribution | Confirmed | One-shot; requires `Sleuth.init()` before `runApp()`. Wall-clock measurement has ~5-50ms inherent skew |

## Recurrence Badge

Each issue card shows a `Seen X/Y · {label}` badge once Sleuth has observed the issue across at least two scan cycles. It tells you how sticky the issue is and whether it is getting better or worse.

- **X** — scan cycles where the issue fired (`presentCount`).
- **Y** — total scan cycles in the ring buffer (capacity `60`, oldest evicted).

The label summarises the trend over the most recent window (default `10` entries):

| Label | Color | When it appears |
|-------|-------|-----------------|
| **worsening** | red | Average severity in the second half of the window exceeds the first half by more than `0.3`. |
| **persistent** | amber | Trend is `stable` **and** `X / Y ≥ 0.9` — the issue fires in almost every cycle. |
| **stable** | neutral | Issue is consistently present but severity is not trending. |
| **improving** | green | Average severity in the second half of the window falls below the first half by more than `0.3`. |
| **flaky** | neutral | Issue toggles present/absent `≥ 3` times in the window (`intermittent` internally). |

Two vocabulary notes:
- **`flaky`** is the display label for the `intermittent` enum value — JSON exports still use `intermittent`.
- **`persistent`** is synthesised in the UI from a `stable` trend plus the `≥ 90%` presence ratio. The JSON export reports the underlying enum (`stable`) and a separate `totalOccurrences / totalObserved` pair, so you can recompute it downstream.

Severity for warnings auto-escalates to critical after 30 consecutive scan cycles — a `Seen 30/30 · persistent` warning will flip red on the next cycle. See [`RecurrenceTrend`](../lib/src/models/recurrence_trend.dart) for the underlying thresholds.

## Startup Tracing

Sleuth measures cold-start performance via `Sleuth.init()` + `Sleuth.markInteractive()`. Call `Sleuth.init()` as the first line of `main()`:

```dart
void main() {
  Sleuth.init();          // Dart-entry clock starts here
  runApp(Sleuth.track(child: const MyApp()));
}
```

Four metrics, three windows:

| Metric | Window | Source |
|--------|--------|--------|
| `ttffMs` | Dart entry → first frame raster-finish | `FrameTiming` callback |
| `engineTtffMs` | Engine C++ entry → first frame rasterized (matches `flutter run --trace-startup`) | VM timeline |
| `preDartOverheadMs` | Engine C++ entry → Dart entry (native pre-Dart phase) | VM timeline |
| `frameworkInitMs` | `WidgetsFlutterBinding.ensureInitialized()` duration | `Timeline.now` delta |

`ttffMs` isolates Dart-controlled work (default thresholds 1500 ms warning / 3000 ms critical). `preDartOverheadMs` is outside Dart's control (typically 400–1200 ms iOS, 300–900 ms Android, often >1500 ms on Android Go).

**Use `ttffMs`** to catch Dart regressions — heavy work in `main()` / first `build()` / initial route. **Use `engineTtffMs`** for product dashboards. **Split the bill** with `preDartOverheadMs` vs `ttffMs`.

In-app Startup Metrics page has full methodology + per-phase breakdown.

## iOS profile builds via Fastlane lose source locations

**Symptom:** profile-mode IPA archived via `fastlane gym` shows issues without `file.dart:42` ancestor chains. Local `flutter run --profile` works fine.

**Cause:** `gym` re-runs `flutter assemble` via `xcode_backend.sh` during archive, which reads `ios/Flutter/Generated.xcconfig`. A stale `TRACK_WIDGET_CREATION=false` lingering from a prior release build strips Sleuth's widget-creation locations from the archived binary.

**Fix:** patch the xcconfig before `gym` in your Fastfile. Belt-and-suspenders — `flutter build ios --profile` sets the flag correctly, but archive runs against cached values can drift.

```ruby
if target_platform == :ios && (mode == "profile" || mode == "debug")
  xcconfig = File.expand_path('../ios/Flutter/Generated.xcconfig', __dir__)
  if File.exist?(xcconfig)
    text = File.read(xcconfig)
    if text.include?('TRACK_WIDGET_CREATION=false')
      File.write(xcconfig, text.sub('TRACK_WIDGET_CREATION=false', 'TRACK_WIDGET_CREATION=true'))
    end
  end

  gym(
    scheme: flavor == "PROD" ? "Runner" : "dev",
    configuration: flavor == "PROD" ? "Profile" : "Profile-dev",
    export_method: @export_method,
    silent: true,
    suppress_xcode_output: true,
  )
end
```
