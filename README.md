<p align="center">
  <img src="doc/logo.png" width="128" alt="Sleuth logo">
</p>

# Sleuth

[![Pub Version](https://img.shields.io/pub/v/sleuth)](https://pub.dev/packages/sleuth)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-blue?logo=flutter)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Tests](https://img.shields.io/badge/tests-3%2C001_passing-brightgreen)]()
[![Analysis](https://img.shields.io/badge/analysis-0_issues-brightgreen)]()

In-app performance diagnostics overlay for Flutter. Surfaces jank, memory leaks, slow networks, GPU pressure, and widget anti-patterns — directly inside your app, with a fix hint on every issue.

## How It Works

Sleuth runs four layers of analysis:

1. **Frame timing** (FrameTiming API) — per-frame build and raster duration, vsync overhead, cache stats. Works on every platform in debug and profile mode. This is the primary signal.
2. **VM timeline** (vm_service) — when connected, provides sub-phase breakdowns (buildScope, flushLayout, flushPaint, raster). Best-effort; availability depends on platform and runtime environment.
3. **Widget tree scan** (post-frame walk, 1x/sec) — finds structural anti-patterns like non-lazy lists, uncached images, missing RepaintBoundary, and more.
4. **Network monitoring** (HttpOverrides) — transparent HTTP interception that detects slow requests, frequency spikes, oversized responses, and HTTP error bursts without modifying app networking code.

## Quick Start

```dart
import 'package:sleuth/sleuth.dart';

void main() => runApp(Sleuth.track(child: MyApp()));
```

The overlay appears in debug and profile mode. Completely disabled in release builds.

## Running

```bash
# Profile mode (recommended — accurate timing data)
flutter run --profile

# Debug mode (works, but timing is less representative)
flutter run
```

## Debug vs Profile Mode

Both modes run the full overlay, all 20 detectors, and the AI chat. The difference is **what data each mode can access** and **how accurate the timing is**.

| Capability | Debug | Profile | Release |
|------------|:-----:|:-------:|:-------:|
| Overlay & all detectors | Yes | Yes | Disabled |
| Frame timing accuracy | Inflated by debug overhead | Production-accurate | — |
| VM timeline (build/layout/paint durations) | Yes | Yes | — |
| Source location in issues (`file.dart:42`) | Yes | No | — |
| Per-widget rebuild/paint attribution | Yes (opt-in) | Via VM timeline only | — |
| Deep timeline enrichment (dirty lists) | Yes (opt-in) | No | — |
| AI Chat & Issue Encyclopedia | Yes | Yes | — |

### When to use which

- **Profile mode** for performance investigation — timing is real, no debug overhead inflating numbers. This is what you should trust.
- **Debug mode** for root-cause drilling — source locations pinpoint the exact file:line, and opt-in debug callbacks give per-widget rebuild/paint counts. Verify timing fixes in profile mode afterward.

### Debug-only opt-in features

These add overhead and are off by default. Enable them when you need deeper attribution:

```dart
SleuthConfig(
  enableDebugCallbacks: true,        // per-widget rebuild & paint counts
  enableDeepDebugInstrumentation: true, // timeline dirty lists & per-widget build/layout/paint events
)
```

## FPS Semantics

Sleuth exposes two frame-rate metrics:

- **Actual FPS** — frames actually presented in the last 1 second, counted from `FrameTiming.rasterFinish` timestamps in a rolling window. This is what the device drew.
- **Throughput FPS** — latency-derived capacity estimate from average frame duration (`1e6 / avg(frame_duration_us)`). This is what the engine could produce given current per-frame cost.

The overlay shows **Throughput FPS** as the primary numeral (color-coded vs `fpsTarget`). Idle screens read smooth because Flutter only repaints on change — Actual FPS would collapse to a few frames/sec on a static screen even though rendering is healthy. Tap the info icon to reveal both metrics side-by-side (ACTUAL + TPUT). Session exports (`SessionSnapshot` schema v5) carry both metrics plus `actualFpsRaw` — the device rate capped at 240 Hz, useful on ProMotion 120 Hz hardware where the overlay clamps to `fpsTarget`.

**If the overlay shows unexpected FPS:**

1. **`SleuthConfig.fpsTarget` caps the overlay.** A ProMotion 120 Hz device running with the default `fpsTarget: 60` shows `60` in the overlay even while rendering 120 frames/second. Check `actualFpsRaw` in the exported snapshot for the uncapped value.
2. **Warm-up placeholder.** The overlay shows `—` while the rolling window is below 3 samples (≈ 50 ms @ 60 Hz) to avoid flashing a red `0 FPS` at app launch or after navigation.
3. **Debug mode overhead.** Debug builds run ~10× slower than profile mode. Always verify FPS numbers with `fvm flutter run --profile`.
4. **Impeller zeros.** Raster-cache metrics read 0 on Impeller — Sleuth detects this and suppresses cache-family warnings; FPS semantics are unaffected.
5. **Batched callbacks.** The rolling window is anchored on engine `rasterFinish` timestamps, not `DateTime.now()`, so batched `addTimingsCallback` delivery does not distort the count.

`enableDebugCallbacks` installs `debugOnRebuildDirtyWidget` and `debugOnProfilePaint` — these conflict with DevTools "Track Widget Rebuilds", so only one can be active at a time. The package detects the conflict and yields to DevTools if it's already attached.

## Measurement Window

Sleuth reports the frame total duration (build-to-raster span) from Flutter's `FrameTiming` — not vsync delivery cadence (`CADisplayLink` on iOS, `Choreographer.doFrame` on Android). The two are different metrics: `FrameTiming` reports how long the engine took to produce a frame; vsync-anchored metrics report when the OS displayed it. A frame produced in 3 ms still waits ~13 ms for the next vsync — `FrameTiming` reports 3 ms, vsync metrics report ~16 ms. Cross-framework comparison numbers that mix the two read as large performance deltas where the underlying behaviour is identical.

`FrameTimingDetector` and `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` on each emission based on whether the issue emitted within `DetectorThresholds.startupPhaseWindowSeconds` (default 5 s) of `Sleuth.dartEntryMonotonicUs`. This is **emission-time semantics** — late callback delivery can tag a startup-phase frame as `'steady'` if the emission lands past the window boundary. The tag is observable in capture-mode trace records and audit-gate replay; it is not serialized into saved JSON snapshots. Operators use it to filter startup-phase artefacts (route inflation, font loading, Material animations) from steady-state regressions.

## Platform Support

| Platform | Frame Timing | VM Full Mode | Notes |
|----------|:---:|:---:|-------|
| Android device | Yes | Best-effort | Background reconnect ladder retries on cold-start port bind race |
| Android emulator | Yes | Best-effort | Same adb limitation applies |
| iOS device | Yes | Good | Profile mode recommended |
| Desktop | Yes | Good | Strongest VM connectivity |

**Frame timing mode** is the universal cross-platform path and provides accurate build/raster timing in profile builds.

**VM full mode** adds sub-phase breakdown (build vs layout vs paint vs raster) but depends on VM service connectivity, which varies by platform. The package falls back gracefully to frame timing mode when VM is unavailable. On cold start, a background reconnect ladder (500 ms → 30 s, 7 attempts) automatically upgrades to full mode once the VM web server binds — no manual action needed.

## Configuration

### Quick start

First-time integration? Drop in a preset instead of reading 25 field docs:

```dart
// Safe defaults, structural + runtime detectors only.
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig.minimal(),
);

// Or optimise for low overhead in CI / profile runs.
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig.performance(),
);
```

### Full configuration

```dart
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig(
    fpsTarget: 60,
    rebuildThreshold: 10,
    maxListChildren: 20,
    platformChannelLimit: 20,
    treeScanInterval: Duration(seconds: 1),
    captureBufferCapacity: 50,        // max jank frames retained for export
    enableDebugCallbacks: false,       // opt-in: per-widget rebuild/repaint hooks (conflicts with DevTools)
    enableDeepDebugInstrumentation: false, // opt-in: heavy per-widget timeline events
    maxTrackedTypes: 200,              // cap on tracked widget types in debug callbacks
    enableNetworkMonitoring: true,     // HTTP interception via HttpOverrides
    slowRequestThresholdMs: 1000,         // warn on requests slower than this (default 1000 ms)
    criticalSlowRequestThresholdMs: 3000, // escalate to critical at this duration (must be > slow; default 3000 ms)
    requestFrequencyLimit: 30,         // max requests per 5s window
    largeResponseThresholdBytes: 1048576, // flag responses larger than 1MB
    adaptiveScanEnabled: true,         // back off scan interval when app is healthy (default true)
    networkExcludePatterns: ['analytics.example.com'], // exclude URLs from monitoring
    enabledDetectors: {
      DetectorType.frameTiming,
      DetectorType.rebuild,
      DetectorType.imageMemory,
      // ... add only the detectors you need
    },
    suppressedIssues: {'non_lazy_list', 'font_*'}, // hide known issues by stableId (exact or wildcard)
    thresholds: DetectorThresholds(
      shaderJankMs: 50,              // shader compilation warning threshold
      heavyComputeGapMs: 8,          // heavy compute warning gap (critical at 2× = 16ms)
      gpuPressureRatio: 1.5,         // raster/UI time ratio for GPU pressure
    ),
    customDetectors: [MyCustomDetector()], // plug in domain-specific detectors
    disabledCustomDetectorKeys: {'my_heavy_detector'}, // gate custom detectors by key
    triggerButtonAlignment: Alignment.bottomRight, // initial trigger button corner
    triggerButtonOffset: Offset(16, 16),           // pixel offset from corner
    showDebugModeBanner: true,         // dismissible debug-mode warning banner
    routeIgnorePatterns: {'/dialog*'}, // routes to exclude from tracking (exact or trailing *)
    routeHistoryCapacity: 20,          // max route sessions retained (FIFO)
  ),
);
```

**Debug callbacks note:** `enableDebugCallbacks` installs `debugOnRebuildDirtyWidget` and `debugOnProfilePaint` hooks. These conflict with DevTools "Track Widget Rebuilds" — only one can be active at a time. Default `false` to avoid surprising DevTools users.

**Overlay theming:** The overlay auto-detects light/dark backgrounds. A built-in toggle in the overlay header lets you switch themes at runtime. You can also override programmatically:

```dart
// Static config at initialization
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig(
    theme: SleuthThemeData.light().copyWith(
      cardBackground: Color(0xFFF5F5F5),
      spacingMd: 10, // adjust overlay density (default 8)
    ),
  ),
);

// Runtime toggle (from anywhere in your app)
Sleuth.updateTheme(const SleuthThemeData.light()); // force light
Sleuth.updateTheme(null);                          // revert to auto-detect
```

## AI Chat

Tap "Ask AI" on any issue card to open a contextual AI chat. The package builds a rich system prompt from issue metrics, encyclopedia knowledge, and the causal graph — your AI provider just needs to stream a response.

```dart
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig(
    aiChat: AiChatAdapter.anthropic(apiKey: myKey),
    // Or: AiChatAdapter.openAi(apiKey: myKey)
    // Or: AiChatAdapter.google(apiKey: myKey)
  ),
);
```

Custom backend:

```dart
config: SleuthConfig(
  aiChat: AiChatAdapter(
    sendMessage: (request) async* {
      // request.systemPrompt — rich issue context built by the package
      // request.history — full conversation so far
      yield* myBackend.stream(request);
    },
  ),
),
```

Built-in adapters automatically exclude their provider URLs from network monitoring. When no adapter is configured, the "Ask AI" link is hidden.

## Custom Detectors

Plug in domain-specific detectors alongside the built-in 20. Three shapes are supported:

**Structural** — inspect widgets during the tree walk using `SimpleStructuralDetector`:

```dart
class TooltipUsageDetector extends SimpleStructuralDetector {
  TooltipUsageDetector()
      : super(
          name: 'Tooltip Usage',
          description: 'Flags Tooltip widgets in the tree',
          key: 'tooltip_usage',
        );

  @override
  void inspect(Element element) {
    if (element.widget is Tooltip) {
      report(
        element: element,
        title: 'Tooltip detected',
        detail: 'Consider Semantics instead for accessibility.',
        category: IssueCategory.build,
      );
    }
  }
}
```

**Runtime** — observe app events (frame timings, route transitions) by extending `BaseDetector` directly with `DetectorLifecycle.runtime`.

**Hybrid** — combine VM timeline data with tree inspection using `DetectorLifecycle.hybrid`.

See the three-file cookbook in `example/lib/custom_detectors/` for complete examples of all three shapes.

Register custom detectors and optionally gate them by key:

```dart
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig(
    customDetectors: [TooltipUsageDetector(), SlowFrameDetector()],
    disabledCustomDetectorKeys: {'slow_frame_detector'}, // disable by key
  ),
);
```

## Session Export

Export captured jank data and current issues for sharing or comparison:

```dart
// JSON snapshot (full data — frame stats, issues, causal edges, heat map)
final snapshot = Sleuth.exportSnapshot();
final json = Sleuth.exportSnapshotJson();

// Markdown summary (human-readable — paste into Slack or a PR description)
final markdown = Sleuth.exportSummary(topN: 5);
```

The dashboard includes an export button that copies the JSON snapshot to the clipboard, and a "Copy conversation" button on the AI chat page that serializes the full thread.

Exports include recurrence trends (per-issue worsening/improving/stable/intermittent), widget heat map (top offending widgets by cumulative ranking score), and per-route health data (FPS, jank ratio, issue counts, health scores).

Returns `null` in release mode, before `track()` is called, or after overlay disposal.

## Route Scoping

Sleuth passively detects route changes via the element tree — no `NavigatorObserver` needed. Each route gets its own `RouteSession` with per-route FPS, jank ratio, issue snapshots, and a composite health score (0–100).

```dart
// Access route history programmatically
final history = Sleuth.routeHistory; // List<RouteSession>?
final score = Sleuth.routeHealthScore('/settings'); // int?
```

Route health data is included in both JSON and markdown exports. Configure route tracking:

```dart
SleuthConfig(
  routeIgnorePatterns: {'/dialog*', '/splash'}, // skip ephemeral routes
  routeHistoryCapacity: 50,                      // max sessions retained (FIFO)
)
```

**Per-tab sessions for tab shells.** Bottom-nav apps using `IndexedStack`, `StatefulShellRoute.indexedStack`, or `CupertinoTabScaffold` share one `ModalRoute` across all tabs but give each tab its own `Scaffold`. Sleuth keys sessions on `(routeName, scaffoldHashKey)`, so every tab produces a distinct `RouteSession` instead of conflating tabs under a single route name. Repeat visits to the same tab are disambiguated via `tabVisitIndex` (1-indexed ordinal). Inline `TabBar` / `TabBarView` / `PageView` swipes within a single route stay inside the outer session. `PerformanceIssue.routeName` is preserved raw for group-by-route filtering — use `issue.routeDisplayName` for human-facing labels (e.g. `"/home (tab-2)"` on the second visit).

## Confidence Levels

Issues include a confidence level reflecting evidence quality:

| Level | Meaning | Example |
|-------|---------|---------|
| **Confirmed** | Directly observed runtime condition | Jank frame measured at 32ms |
| **Likely** | Runtime signal + structural evidence | Raster-dominant frame + deep opacity subtree |
| **Possible** | Structural heuristic only | Non-lazy list with 50 children found |

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

Severity for warnings auto-escalates to critical after 30 consecutive scan cycles — a `Seen 30/30 · persistent` warning will flip red on the next cycle. See [`RecurrenceTrend`](lib/src/models/recurrence_trend.dart) for the underlying thresholds.

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

## Validation Ledger

Each detector carries a `DetectorMetadata` record declaring the strongest evidence backing its current thresholds and heuristics, ordered across four tiers: `unvalidated` → `reproducerOnly` → `runtimeVerified` → `externallyCited`. As of v0.30.0, **18/20 detectors ship at `reproducerOnly` base and 2/20 at `runtimeVerified` base**, with **15 effective `runtimeVerified` family-severity pairs across 12 unique stableIds** (`slow_request {warning + critical}`, `large_response.warning`, `request_frequency.warning`, `heap_growing.warning`, `platform_channel_traffic.warning`, `jank_detected.warning`, `rebuild_activity {warning + critical}`, `heavy_compute {warning + critical}`, `excessive_repaint.warning`, `stream_resource_growth.warning`, `tracked_resource_concurrent.warning`, `tracked_resource_long_lived.warning`). Zero detectors at `unvalidated`. The CI audit gate at `test/validation/detector_metadata_audit_test.dart` enforces the contract on every test run.

The per-detector ledger lives at [`doc/validation_ledger.md`](https://github.com/Harrys76/sleuth/blob/main/doc/validation_ledger.md) — it names each detector's current tier, links to its reproducer when one exists, and explains what would raise it. Tier raises land the supporting reproducer or capture evidence in the same PR.

## MCP Roadmap

Sleuth v0.32.0 ships seven `ext.sleuth.*` VM service extensions plus the
`sleuth_mcp` v0.1.0 sidecar package that bridges them to MCP stdio
JSON-RPC clients (Claude Code, Cursor, Zed). The schema audit lands in
M3 (v0.33.0). Full plan:
[`doc/spec_mcp.md`](https://github.com/Harrys76/sleuth/blob/main/doc/spec_mcp.md).

| Milestone | Status |
|-----------|--------|
| M1 — `ext.sleuth.*` VM service extensions in the main `sleuth` package | Landed in v0.32.0 |
| M2 — `sleuth_mcp` sidecar package (MCP stdio JSON-RPC) | Landed in v0.32.0 + sleuth_mcp v0.1.0 |
| M3 — versioned MCP schema doc + audit test | Planned |

MCP clients use the same live-app signals as the in-app overlay. During
warmup or degraded VM connectivity, responses report `connectionMode`
honestly (`correlated` / `full` / `basic` / `warmup` / `disconnected`)
instead of returning empty data. Sleuth reserves the `ext.sleuth.*`
extension namespace — other packages should choose a distinct prefix to
avoid duplicate-name collisions with
`dart:developer.registerExtension`.

The in-app overlay remains the primary UX. The sidecar is an opt-in
consumer for AI assistant integration only — most developers will not
need to install or invoke it.

## What This Does Better Than DevTools

- **Always on**: no separate tool window, no connection setup — one-line install, visible while you use the app
- **20 detectors**: structural anti-patterns DevTools does not flag (non-lazy lists, uncached images, missing RepaintBoundary, intrinsic-height layout cost, retained stream subscriptions)
- **Inline Rebuild Stats**: live rebuild counter with top-3 widget breakdown and full-list drilldown when `enableDeepDebugInstrumentation: true`
- **Confidence explanations**: every issue explains *why* its confidence is confirmed/likely/possible — what evidence was used, what would upgrade it
- **Causal issue graph**: 44 rules link root causes to downstream effects — see why an issue matters, not just that it exists
- **Fix verification**: baseline → fix → compare. Cooldown-based resolution with hot-reload grace period
- **Historical trending**: per-issue recurrence tracks worsening/improving/stable/intermittent patterns across scan cycles
- **Per-route health scores**: passive route detection (no NavigatorObserver) with per-route FPS, jank ratio, issue aggregation, composite health score
- **Network monitoring**: slow requests, request floods, oversized responses, HTTP error spikes, high-frequency same-path bursts (≥3 GET/HEAD/OPTIONS to one endpoint within 500 ms), network-to-frame correlation
- **Heap trend monitoring**: sustained memory growth + near-capacity detection without heap snapshots
- **CPU attribution on jank frames**: top-5 functions by CPU time per jank frame — no manual profiling session
- **Issue Encyclopedia**: in-app deep-dives for all 47 issue types, searchable + cross-referenced
- **Contextual AI Chat**: per-issue AI assistant with streaming responses + starter questions — bring your own provider

## What DevTools Still Does Better

- **Heap snapshots & object graph**: DevTools can browse every object in the heap, inspect retention paths, and track individual allocations. Sleuth monitors heap trends and GC pressure but cannot drill into specific objects.
- **Full flame chart & call tree**: DevTools provides zoomable, interactive per-frame timelines with complete call tree visualization. Sleuth shows phase breakdowns with top-5 function attribution per jank frame.

Sleuth is best used for **fast in-app triage** — catch the problem, understand the category, then use DevTools when you need deeper investigation.

## Unsupported Claims

To set clear expectations:

- This package is **not a replacement** for DevTools heap snapshots or interactive flame charts — it covers breadth (20 detectors, encyclopedia, AI chat) but not the depth of object-level introspection or zoomable timelines
- **Widget attribution varies by mode** — debug mode provides exact per-widget rebuild/paint counts and source file:line locations. Profile mode provides per-widget-type attribution via VM timeline dirty lists (when VM is connected), falling back to structural heuristics when unavailable. See [Debug vs Profile Mode](#debug-vs-profile-mode) for the full matrix
- **VM full mode availability** depends on runtime environment and is not guaranteed on all platforms
- **Memory pressure detection** monitors GC frequency, heap growth trends (linear regression), and capacity thresholds. When growth is detected, enriches the issue with per-class allocation deltas — but does not track individual object leaks or retention paths
- **CPU attribution** is statistical (~1 kHz sampling) — functions running <1 ms may not appear; use DevTools CPU profiler for complete call trees

## Tips & Troubleshooting

### iOS profile builds via Fastlane lose source locations

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

## Example App

20 demo screens + 7 capture-helper screens with Before/After toggle + live metrics. See [`example/README.md`](example/README.md) for the full screen list and demo categorization.

```bash
cd example && flutter run --profile
```

## License

MIT
