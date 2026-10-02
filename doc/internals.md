# Sleuth — Internals & Detector Reference

Deep reference moved out of the main [README](../README.md) to keep the
landing page focused. This file covers the measurement methodology, the
full detector matrix, recurrence-trend thresholds, startup metrics, and
platform-specific troubleshooting.

## Measurement Window

Sleuth reports the frame total duration (build-to-raster span) from Flutter's `FrameTiming` — not vsync delivery cadence (`CADisplayLink` on iOS, `Choreographer.doFrame` on Android). The two are different metrics: `FrameTiming` reports how long the engine took to produce a frame; vsync-anchored metrics report when the OS displayed it. A frame produced in 3 ms still waits ~13 ms for the next vsync — `FrameTiming` reports 3 ms, vsync metrics report ~16 ms. Cross-framework comparison numbers that mix the two read as large performance deltas where the underlying behaviour is identical.

`FrameTimingDetector` and `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` on each emission based on whether the issue emitted within `DetectorThresholds.startupPhaseWindowSeconds` (default 5 s) of `Sleuth.dartEntryMonotonicUs`. This is **emission-time semantics** — late callback delivery can tag a startup-phase frame as `'steady'` if the emission lands past the window boundary. The tag is observable in capture-mode trace records and audit-gate replay; it is not serialized into saved JSON snapshots. Operators use it to filter startup-phase artefacts (route inflation, font loading, Material animations) from steady-state regressions.

## Scan loop

The structural scan runs on a self-rescheduling timer whose callback scans in a post-frame callback, so a tick needs a frame to run. The interval starts at `treeScanInterval` (1 s). After three consecutive clean scans it doubles up to 2 s, never below the base. Each tick times its unified walk plus aggregation; a tick over 4 ms stretches the next interval to `treeScanInterval × ceil(cost / 4 ms)`, capped at 5 s and never below the back-off interval (capture mode disables the stretch). With `maxElementsPerScan > 0`, a walk over the cap skips the next tick once and schedules the following one at twice the interval; walks are never cut short and the previous issues stay visible. While the user is scrolling, a tick retries after 250 ms, at most three times in a row; a scroll with no start/update notification for 2 s is treated as ended. Scroll notifications only re-measure highlight rects from the render objects they were measured from; 300 ms after a scroll ends, one early tick runs. `issuesNotifier` fires only when a rendered field of the ranked list changes; `scanTickNotifier` pulses once per tick for panels that re-read live state (rebuild counts, recurrence badges).

## Frame budget

The jank budget is resolved from three inputs: `fpsTarget`, the display's reported refresh rate (`View.display.refreshRate`, read by the overlay), and the measured vsync cadence. `FrameTimingDetector` keeps the last 120 `vsyncStart` deltas (ignoring gaps longer than two `fpsTarget` frames) and, after 30 samples, estimates the cadence as `1e6 / p10(deltas)`. The 10th percentile, not the median: fast frames reveal the vsync period, while slow frames are what is being measured, and a median would fold steady jank into the cadence and loosen the budget. The estimate snaps to 30/60/90/120/144 Hz when within 8 %.

The effective rate is the measured cadence clamped to `[fpsTarget, display rate]`. The display rate is only a cap because iOS reports `UIScreen.maximumFramesPerSecond` (120 on ProMotion) even while the app renders at 60; `fpsTarget` is the floor so a janky app cannot loosen its own budget. With no measurement the budget is `1e6 / fpsTarget` µs. `FrameStats.frameBudgetUs` carries it per frame and jank compares microseconds (16667 µs at 60 Hz, so a 16.8 ms frame is jank and a 33 ms frame is not severe). When the budget tightens below the `fpsTarget` budget, the `raster_dominance` per-frame floor and the default `heavy_compute` threshold become half of it; at the `fpsTarget` budget they stay 8000 µs and 8 ms. `autoFrameBudget: false` and capture mode always use the fixed `fpsTarget` budget.

## FPS troubleshooting

**If the overlay shows unexpected FPS:**

1. **`SleuthConfig.fpsTarget` caps the overlay.** A ProMotion 120 Hz device running with the default `fpsTarget: 60` shows `60` in the overlay even while rendering 120 frames/second. Check `actualFpsRaw` in the exported snapshot for the uncapped value. The jank budget is not capped this way: see the frame budget section below.
2. **Warm-up placeholder.** The overlay shows `—` while the rolling window is below 3 samples (≈ 50 ms @ 60 Hz) to avoid flashing a red `0 FPS` at app launch or after navigation.
3. **Debug mode overhead.** Debug builds run ~10× slower than profile mode. Always verify FPS numbers with `flutter run --profile`.
4. **Impeller zeros.** Raster-cache metrics read 0 on Impeller — Sleuth detects this and suppresses cache-family warnings; FPS semantics are unaffected.
5. **Batched callbacks.** The rolling window is anchored on engine `rasterFinish` timestamps, not `DateTime.now()`, so batched `addTimingsCallback` delivery does not distort the count.

`enableDebugCallbacks` installs `debugOnRebuildDirtyWidget` and `debugOnProfilePaint` — these conflict with DevTools "Track Widget Rebuilds", so only one can be active at a time. The package detects the conflict and yields to DevTools if it's already attached.

## Detector Matrix

### Runtime Detectors (always available)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Frame Timing | FrameTiming API | Frame exceeded budget, thread attribution (UI-bound/raster-bound/pipeline stall), judged on the frames since the current route was first scanned | Confirmed | Cannot attribute to specific widget; frames up to one scan tick after navigation count toward the previous route |
| Network Monitor | HttpOverrides | Slow, excessive, oversized, error-spiking, or high-frequency same-path HTTP requests | Confirmed | Only `dart:io` `HttpClient` traffic is observed (including `package:http`'s default `IOClient` and Dio's default adapter); `cronet_http`, `cupertino_http`, and platform-SDK networking are invisible. `large_response` skips `image/`, `video/`, `audio/`, and `font/` responses |
| Tracked Resource | `Sleuth.trackResource(name, ref)` + `WeakReference` + Finalizer | Concurrent retention (`> 5` live instances same name) and long-lived retention (single instance alive `> 300 s`) | Confirmed | Opt-in: user code must call `Sleuth.trackResource`. Cross-isolate registration is a no-op |

### VM-Only Detectors (require VM connection)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Shader Jank | VM Timeline begin/end pairs | Impeller Vulkan pipeline build or Skia shader compile ≥ 100 ms | Likely | Requires VM connection. Silent on Impeller Metal (pipelines precompiled) |
| Heavy Compute | VM Timeline | Long UI-thread event | Confirmed | Requires VM connection |
| Platform Channel | VM Timeline | High call frequency (count-only trigger; per-call max/p95 duration observed); the card stays 10 s after a burst | Confirmed | Requires VM connection and `debugProfilePlatformChannels` (opt in with `SleuthConfig(profilePlatformChannels: true)`, set after the VM connects; the framework then prints a stats table every second) |
| Memory Pressure | VM GC events + heap polling + process RSS | GC frequency elevated (>180/min, scavenge / old-gen split stamped), heap growing steadily (linear regression), RSS at ≥80% of an opt-in `memoryBudgetBytes` while the heap grows | Likely | Requires VM connection; the budget rule is off unless `DetectorThresholds.memoryBudgetBytes` is set and needs RSS (unavailable on web) |
| Stream Resource | `getAllocationProfile` class-instance diff (K=4 window) | Retained async resources (dart:async / dart:io / web_socket_channel / rxdart subjects) when `heap_growing` co-fires | Likely | Requires VM connection. Gated on `MemoryPressureDetector.isHeapGrowingActive` |

### Hybrid Detectors (VM + tree scan, degrade without VM)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Rebuild | VM build count + tree | High rebuild activity | Confirmed for count, Possible for widget attribution | Degrades to structural density report without VM |
| GPU Pressure | FrameTiming raster vs UI per frame + VM raster timing + render tree | Raster thread dominance | Likely from frames (3 raster-dominant frames in 1 s, every tier); Confirmed when the VM ratio also fires; nodes Likely when either coexists | Frame leg needs Frame Timing enabled and ignores the startup window. Impeller raster durations can include present back-pressure, so frame evidence stays Likely. Sigma-aware severity for BackdropFilter; ColorFiltered detection via widget type |
| Repaint | VM paint events + per-widget attribution | High paint frequency, animation-owned suppression | Confirmed for rate, Possible for widget attribution | Degrades to structural-only without VM |

### Structural Detectors (tree scan only)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| setState Scope | Element tree | StatefulWidget owns large subtree and is observed rebuilding | Possible–Confirmed | Emits only with child-identity churn or debug-callback rebuild counts; a static wide page never emits. Builder-style owners (FutureBuilder, StreamBuilder, Form, Focus, ...) skipped. Const subtree discounting when churn evidence present |
| Layout Bottleneck | Render tree | IntrinsicHeight/Width present, Wrap with excessive children | Possible–Likely | Present does not mean slow: a single intrinsic is Possible, nesting is Likely. Intrinsics built by ToggleButtons, MenuBar, linear landscape BottomNavigationBar labels, AlertDialog/SimpleDialog, popup menus, CupertinoContextMenu, and Scaffold footer buttons are suppressed |
| ListView | Element tree | Non-lazy list with many children; shrinkWrap list inside a Column/Row | Possible | May be intentional for small lists. Catches ListView/GridView/SliverList non-builder constructors; `non_lazy_shrinkwrap` also catches builders (> 20 children) |
| Image Memory | Element tree + decoded `ui.Image` | Image decoded above the physical pixels its box needs | Likely | Counts an image at ≥ 1.5× on the smaller axis; emits at ≥ 1 MiB total waste. Undecoded images, ResizeImage, `BoxFit.none`, `centerSlice`, `repeat`, and BoxDecoration images are not measured. A widget that later grows may need the larger decode |
| CustomPainter | Element tree | shouldRepaint always true | Possible–Likely | May be needed for animated painters. Framework painters skipped (toggle/scrollbar by type; Material shape borders, TabBar, progress indicators, ... by name + owner within a measured hop budget); paint rate excludes animation-owned paints |
| Keep Alive | Element tree | Many keep-alive pages | Possible | Trade-off between memory and rebuild cost. Counts toward the innermost PageView/TabBarView only; list keep-alives ignored |
| Font Loading | Element tree | Non-system font in use, runtime-loaded fonts (fontFamilyFallback heuristic) | Possible | Font may already be loaded. Runtime detection is heuristic — intentional fallback chains may trigger. Platform system and icon fonts ignored; google_fonts variants count once |
| RepaintBoundary | Element + render tree | Expensive GPU widget without RepaintBoundary ancestor, excessive boundaries in scrollables | Possible–Likely | Escalates to Likely with debug paint rate evidence; never Confirmed because paint rates are per type, not per instance. ColorFiltered detected via widget type. Framework painters and Material's own ClipPath skipped; boundaries a default sliver delegate adds are never counted |
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

Persistence is shown by the `Seen N` badge and trend; severity always comes from the detector. See [`RecurrenceTrend`](../lib/src/models/recurrence_trend.dart) for the underlying thresholds.

## Ranking and Causal Graph

[`IssueRanker`](../lib/src/ranking/issue_ranker.dart) scores each issue as `tier × 100 + frameImpact × 8 + recurrence × 2`. The tier combines severity and confidence:

| Severity | Confirmed | Likely | Possible |
|----------|-----------|--------|----------|
| critical | 6 | 5 | 3 |
| warning | 4 | 2 | 1 |
| ok | 0 | 0 | 0 |

Order: confirmed critical > likely critical > confirmed warning > possible critical > likely warning > possible warning > ok. The largest bonus (frameImpact 3, recurrence 5) adds 34, below the 100-point tier gap, so bonuses never move an issue across tiers.

[`CausalGraphRule`](../lib/src/analyzer/causal_graph.dart) drops any edge whose cause is `possible` and whose effect is `likely` or `confirmed` before it looks for roots, so a structural guess never claims an observed effect. `activeEdges` in the export applies the same filter.

In the overlay, an effect with exactly one cause collapses under that cause only when the cause is present and at least as severe as the effect. An effect with two or more causes always stays in the main list with a "Caused by" section.

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
