<p align="center">
  <img src="doc/logo.png" width="128" alt="Sleuth logo">
</p>

# Sleuth

[![Pub Version](https://img.shields.io/pub/v/sleuth)](https://pub.dev/packages/sleuth)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-blue?logo=flutter)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Tests](https://img.shields.io/badge/tests-2%2C051_%2B_9_passing-brightgreen)]()
[![Analysis](https://img.shields.io/badge/analysis-0_issues-brightgreen)]()

Runtime performance diagnostics for Flutter mobile apps. Combines frame timing, optional VM timeline analysis, and widget-tree heuristics to surface bottlenecks and actionable fixes — directly inside your app.

## How It Works

Sleuth runs four layers of analysis:

1. **Frame timing** (FrameTiming API) — per-frame build and raster duration, vsync overhead, cache stats. Works on every platform in debug and profile mode. This is the primary signal.
2. **VM timeline** (vm_service) — when connected, provides sub-phase breakdowns (buildScope, flushLayout, flushPaint, raster). Best-effort; availability depends on platform and runtime environment.
3. **Widget tree scan** (post-frame walk, 1x/sec) — finds structural anti-patterns like non-lazy lists, uncached images, excessive GlobalKeys, and more.
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

Both modes run the full overlay, all 23 detectors, and the AI chat. The difference is **what data each mode can access** and **how accurate the timing is**.

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

`enableDebugCallbacks` installs `debugOnRebuildDirtyWidget` and `debugOnProfilePaint` — these conflict with DevTools "Track Widget Rebuilds", so only one can be active at a time. The package detects the conflict and yields to DevTools if it's already attached.

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
    maxGlobalKeys: 10,
    platformChannelLimit: 20,
    treeScanInterval: Duration(seconds: 1),
    captureBufferCapacity: 50,        // max jank frames retained for export
    enableDebugCallbacks: false,       // opt-in: per-widget rebuild/repaint hooks (conflicts with DevTools)
    enableDeepDebugInstrumentation: false, // opt-in: heavy per-widget timeline events
    maxTrackedTypes: 200,              // cap on tracked widget types in debug callbacks
    enableNetworkMonitoring: true,     // HTTP interception via HttpOverrides
    slowRequestThresholdMs: 2000,      // flag requests slower than this
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
    suppressedIssues: {'opacity_zero', 'font_*'}, // hide known issues by stableId (exact or wildcard)
    thresholds: DetectorThresholds(
      shaderJankMs: 50,              // shader compilation warning threshold
      heavyComputeGapMs: 200,        // heavy compute gap threshold
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

Plug in domain-specific detectors alongside the built-in 23. Three shapes are supported:

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

### What `ttffMs` measures (and what it excludes)

`StartupMetrics.ttffMs` is a wall-clock duration from the `Sleuth.init()` call to the first `FrameTiming` raster-finish. It **deliberately excludes** the native pre-Dart phase, which differs by platform:

- **iOS cold start** — `dyld`, Objective-C `+load`, `UIApplicationMain`, `AppDelegate` init, `FlutterEngine` creation, Dart VM bootstrap, AOT snapshot load, core-library init. Typically **400–1200 ms** on iPhone 12-class hardware.
- **Android cold start** — Zygote fork, `Application.onCreate()`, ContentProvider auto-init (Firebase, WorkManager, etc.), `FlutterActivity.onCreate()`, `FlutterEngine` creation, Dart VM bootstrap, AOT snapshot load, core-library init. Typically **300–900 ms** on mid-range devices; often exceeds **1500 ms** on budget / Android Go hardware, where Zygote preload is less effective and AOT snapshot load is disk-bound.

That portion is outside Dart's control — it depends on device class, OS version, how many pods/gradle plugins you ship, and how many ContentProviders auto-initialize. `ttffMs` isolates the part your Dart code can actually move.

The default detector thresholds (`1500 ms` warning, `3000 ms` critical) apply to `ttffMs` and are calibrated for this narrower window. They are the same on both platforms because `ttffMs` is measuring Dart code, which runs on the same VM across iOS and Android.

### `ttffMs` vs `flutter run --trace-startup`

`flutter run --trace-startup` writes `build/start_up_info.json` with `timeToFirstFrameRasterizedMicros`, which measures from **engine C++ entry** to first frame rasterized. That's a wider window than `ttffMs` — it includes the native pre-Dart phase. **Expect `--trace-startup` to report a larger number than `ttffMs` by the pre-Dart overhead.** Both numbers are correct; they just answer different questions.

Sleuth exposes the `--trace-startup`-equivalent value as `StartupMetrics.engineTtffMs`, and the native-phase gap as `StartupMetrics.preDartOverheadMs`. Both are populated retroactively by scraping `FlutterEngineMainEnter` and `Rasterized first useful frame` events from the Dart VM timeline ring buffer. They require:

- A VM connection (debug or profile mode — release has no VM service).
- The VM to poll the timeline before the ring buffer evicts those early events (usually fine, but possible to lose on high-traffic startups — in which case the fields are `null`).

When present, both numbers render in the in-app Startup Metrics page and in the `slow_startup_ttff` issue detail under "Engine startup phases". Read them programmatically via `Sleuth.exportSummary()`.

| Metric | Window | Matches `--trace-startup`? | Source |
|--------|--------|----------------------------|--------|
| `ttffMs` | Dart entry → first frame raster-finish | No (narrower, excludes native phase) | `FrameTiming` callback |
| `engineTtffMs` | Engine C++ entry → first frame rasterized | **Yes** | VM timeline |
| `preDartOverheadMs` | Engine C++ entry → Dart entry | — | VM timeline |
| `frameworkInitMs` | `WidgetsFlutterBinding.ensureInitialized()` duration | — | Direct `Timeline.now` delta |

### When to use which

- **Track Dart-land regressions** (heavy synchronous work in `main()` / first `build()` / initial route) → use `ttffMs`. It moves when your code moves.
- **Track full cold-start time** for product dashboards → use `engineTtffMs`, or `flutter run --trace-startup` as the ground-truth reference.
- **Split the bill between native and Dart** → `preDartOverheadMs` (native, outside Dart's control) vs `ttffMs` (Dart, yours to optimize).

The in-app Startup Metrics page also includes a full "Measurement Methodology" section that enumerates both capture layers (direct `FrameTiming` + VM timeline extraction) if you need the exact capture mechanics.

## Detector Matrix

### Runtime Detectors (always available)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Frame Timing | FrameTiming API | Frame exceeded budget, thread attribution (UI-bound/raster-bound/pipeline stall) | Confirmed | Cannot attribute to specific widget |
| Network Monitor | HttpOverrides | Slow, excessive, oversized, error-spiking, or high-frequency same-path HTTP requests | Confirmed | Only intercepts dart:io HttpClient (not package:http directly) |

### VM-Only Detectors (require VM connection)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Shader Jank | VM Timeline | Shader compilation occurred | Confirmed | Requires VM connection. No-op on Impeller (shaders pre-compiled) |
| Heavy Compute | VM Timeline | Long UI-thread event | Confirmed | Requires VM connection |
| Platform Channel | VM Timeline | High call frequency | Confirmed | Requires VM connection and `debugProfilePlatformChannels` |
| Memory Pressure | VM GC events + heap polling | GC frequency elevated, heap growing steadily (linear regression), heap near capacity (>80%) | Likely / Confirmed | Requires VM connection |
| Repaint | VM Timeline | High paint frequency | Confirmed | Requires VM connection |

### Hybrid Detectors (VM + tree scan, degrade without VM)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| Rebuild | VM build count + tree | High rebuild activity | Confirmed for count, Possible for widget attribution | Degrades to structural density report without VM |
| GPU Pressure | VM raster timing + render tree | Raster thread dominance | Confirmed for ratio, Likely when nodes coexist | Degrades to structural node detection without VM. Sigma-aware severity for BackdropFilter; ColorFiltered detection via widget type |
| Shallow Rebuild Risk | VM build count + tree depth | Shallow StatefulWidgets exist during high build activity | Possible | Degrades to structural risk report without VM |

### Structural Detectors (tree scan only)

| Detector | Signal Source | Can Prove | Confidence | Known Limitations |
|----------|-------------|-----------|------------|-------------------|
| setState Scope | Element tree | StatefulWidget owns large subtree | Possible–Likely | Needs rebuild evidence to confirm. Const subtree discounting when rebuild evidence present |
| Layout Bottleneck | Render tree | IntrinsicHeight/Width present, Wrap with excessive children | Possible | Present does not mean slow. Framework-internal intrinsics (DropdownButton, AlertDialog) suppressed |
| ListView | Element tree | Non-lazy list with many children | Possible | May be intentional for small lists. Catches ListView/GridView/SliverList non-builder constructors |
| Image Memory | Element tree | Image without cacheWidth/Height | Possible | Images ≤50px suppressed — negligible memory savings |
| GlobalKey | Element tree | Many GlobalKeys in scrollable, cross-scan key recreation | Possible–Likely | May be necessary for state preservation |
| Nested Scroll | Element tree | Scroll-inside-scroll pattern | Possible | NeverScrollableScrollPhysics and NestedScrollView automatically suppressed |
| CustomPainter | Element tree | shouldRepaint always true | Possible | May be needed for animated painters |
| Keep Alive | Element tree | Many keep-alive pages | Possible | Trade-off between memory and rebuild cost |
| AnimatedBuilder | Element tree | No child param on large subtree | Possible | Only matters if subtree is large. Also detects TweenAnimationBuilder without child |
| Opacity | Element tree | Opacity(0.0), AnimatedOpacity(0.0), or FadeTransition(0.0) settled | Possible | Widget still participates in hit testing and semantics. FadeTransition deduped with AnimatedOpacity |
| Font Loading | Element tree | Non-system font in use, runtime-loaded fonts (fontFamilyFallback heuristic) | Possible | Font may already be loaded. Runtime detection is heuristic — intentional fallback chains may trigger |
| RepaintBoundary | Element + render tree | Expensive GPU widget without RepaintBoundary ancestor, excessive boundaries in scrollables | Possible–Confirmed | Escalates with debug paint rate evidence. ColorFiltered detected via widget type |
| Startup | `Sleuth.init()` + FrameTiming | TTFF exceeded budget, dominant phase attribution | Confirmed | One-shot; requires `Sleuth.init()` before `runApp()`. Wall-clock measurement has ~5-50ms inherent skew |

## What This Does Better Than DevTools

- **Always on**: no separate tool window, no connection setup — performance data is visible as you use your app
- **23 detectors**: structural anti-patterns (non-lazy lists, uncached images, excessive GlobalKeys, missing RepaintBoundary) that DevTools does not flag
- **Confidence explanations**: every issue explains *why* its confidence is confirmed/likely/possible — what evidence was used and what would upgrade it
- **Severity auto-escalation**: persistent warnings automatically escalate to critical after 30 scan cycles; structural findings upgrade to likely when corroborated by frame jank or rebuild evidence
- **Causal issue graph**: 44 rules linking root causes to downstream effects — see why an issue matters, not just that it exists
- **Fix verification**: capture baseline → fix → compare. Cooldown-based resolution with hot-reload grace period
- **Historical trending**: per-issue recurrence time-series tracks worsening/improving/stable/intermittent patterns across scan cycles
- **Widget heat map**: "top offenders" ranking aggregates issues by widget, filtering framework internals
- **Per-route health scores**: passive route detection (no NavigatorObserver) with per-route FPS, jank ratio, issue aggregation, and composite health score — see which screens are degraded
- **Network monitoring**: in-app detection of slow requests, request floods, oversized responses, HTTP error spikes, high-frequency same-path bursts (≥3 GET/HEAD/OPTIONS to one endpoint within 500 ms, query strings ignored), and network-to-frame correlation
- **Heap trend monitoring**: detects sustained memory growth and near-capacity conditions without heap snapshots
- **CPU attribution on jank frames**: surfaces top-5 functions by CPU time on every jank frame — no manual profiling session needed
- **Source-location enrichment**: ancestor chains include file:line in debug mode, linking issues directly to source code
- **Actionable fix hints**: every issue includes what to change, not just what went wrong — with code snippets and debugging commands
- **Issue Encyclopedia**: in-app educational deep-dives for all 47 issue types — searchable, with cross-references between related issues, accessible from any issue card
- **Contextual AI Chat**: per-issue AI assistant with streaming responses, starter questions, and expandable issue context — bring your team's AI provider
- **Customizable**: suppress known issues, tune detector thresholds, plug in custom detectors, theme the overlay (60+ color tokens, 6 spacing tokens, 9 typography tokens, 7 border radius tokens)
- **Zero setup**: one line of code, no browser tab, no port forwarding

## What DevTools Still Does Better

- **Heap snapshots & object graph**: DevTools can browse every object in the heap, inspect retention paths, and track individual allocations. Sleuth monitors heap trends and GC pressure but cannot drill into specific objects.
- **Full flame chart & call tree**: DevTools provides zoomable, interactive per-frame timelines with complete call tree visualization. Sleuth shows phase breakdowns with top-5 function attribution per jank frame.

Sleuth is best used for **fast in-app triage** — catch the problem, understand the category, then use DevTools when you need deeper investigation.

## Unsupported Claims

To set clear expectations:

- This package is **not a replacement** for DevTools heap snapshots or interactive flame charts — it covers breadth (23 detectors, encyclopedia, AI chat) but not the depth of object-level introspection or zoomable timelines
- **Widget attribution varies by mode** — debug mode provides exact per-widget rebuild/paint counts and source file:line locations. Profile mode provides per-widget-type attribution via VM timeline dirty lists (when VM is connected), falling back to structural heuristics when unavailable. See [Debug vs Profile Mode](#debug-vs-profile-mode) for the full matrix
- **VM full mode availability** depends on runtime environment and is not guaranteed on all platforms
- **Memory pressure detection** monitors GC frequency, heap growth trends (linear regression), and capacity thresholds. When growth is detected, enriches the issue with per-class allocation deltas — but does not track individual object leaks or retention paths
- **CPU attribution** is statistical (~1 kHz sampling) — functions running <1 ms may not appear; use DevTools CPU profiler for complete call trees

## Example App

The `example/` directory includes 26 demo screens organized into 8 categories (Build, Paint, GPU & Rendering, Layout, Memory, Network & I/O, Keys & Identity, Custom Detectors, Combined). Every demo is wrapped in the shared `DemoScaffold`, which provides a **Before/After toggle** and a **live metrics bar** so you can flip between the anti-pattern and its fix in-place and watch Sleuth's detection appear and disappear:

```bash
cd example
flutter run
```

**Every demo ships a working "Fixed Pattern" body** — not a description — so the segmented toggle shows a real comparison:

- Top-level `setState` → `ValueNotifier` + `ValueListenableBuilder`
- `ListView(children: List.generate(...))` → `ListView.builder` with `itemExtent`
- `IntrinsicHeight` row → `CrossAxisAlignment.stretch`
- `Image.network` without caching → `cacheWidth` / `cacheHeight`
- `GlobalKey()` in `build()` → `final` field
- `Opacity(opacity: 0.0)` → `Visibility(visible: false)`
- `AnimatedBuilder` without `child` → extracted `child`
- `Fibonacci` on main thread → `Isolate.run()`
- 40 concurrent HTTP gets → in-memory cache + pagination

**Demos with live metric chips:** high-level setState (bad/fixed rebuilds), non-lazy list (widgets built), heavy compute (ms per call), FPS stress test (live FPS via `addTimingsCallback`), repaint stress (paints/sec), network stress (request count), memory pressure (retained MB).

**Combined multi-detector demos** stack 4–5 anti-patterns in one realistic screen and show every corresponding fix applied together:

- **E-Commerce Product Page** — hero carousel, rotating price `AnimatedBuilder`, `IntrinsicHeight` size row, 200-review list, 4 `GlobalKey`s, hidden `Opacity(0.0)` loading banner
- **Chat App** — tabbed conversations with `AutomaticKeepAliveClientMixin`, uncached avatars, 40ms platform-channel typing poll, top-level `setState` on message arrival
- **Social Feed** — cards with uncached post images, `IntrinsicHeight` header row, `Opacity(0.0)` "load more" banner, top-level `setState` on Like
- **Analytics Dashboard** — `CustomPainter.shouldRepaint` always-true, non-extracted `AnimatedBuilder`, refresh that rebuilds every tile

Each demo description follows the `❌ BAD / ✅ FIX / ▶ action` format with an explicit reproduction step telling you what to tap to trigger the detection.

## Dependencies

- `vm_service: ^14.0.0` — optional VM timeline data when connected

## License

MIT
