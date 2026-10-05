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

## VM poll pipeline

With a VM connection, `VmServiceClient` polls every 500 ms on the UI isolate. One poll:

1. **Window.** The first poll of a session (and the first after a reconnect) reads the whole timeline buffer, which still holds the engine startup events. Later polls first read the VM's timeline clock (`getVMTimelineMicros`, the clock event `ts` values use) and request `getVMTimeline(timeOriginMicros: max(0, newest − 500 ms), timeExtentMicros: clock − origin + 1 s)`, where `newest` is the largest `ts` accepted so far and 500 ms is `VmServiceClient.fetchOverlapMicros`, one poll interval. The overlap covers events a thread appends with a `ts` older than another thread's newest event. A begin/end pair that straddles a fetch is not re-read: the begin waits in the parser's pending-begin map until its end arrives, up to `TimelineParser.maxReconstructedPhaseUs` (2 s) apart.
2. **RPC.** The await of `getVMTimeline`. Most of it is the VM serializing the window and the transport, during which the UI isolate runs frames. The tail end is not: package:vm_service pushes the raw string to `onReceive`, then decodes the JSON and builds the `Timeline` on the UI isolate before the future completes. The client stamps the arrival of the response matched to its request id, searched for in the first and last 64 characters of each raw message only, so ids nested in a payload cannot match; the time from that stamp to the completed await is the decode.
3. **Parse.** One pass. Each thread has a cursor (`lastTs` plus the signatures of the events at exactly `lastTs`); an event below its thread's cursor is dropped after three map lookups, and the `(ph, name, id)` signature string is built only for ties at `lastTs`. The pass returns the batch's largest accepted `ts`, which advances `newest` and anchors the sweep that evicts pending begins and idle cursors older than 30 s.
4. **Dispatch.** `onTimelineData` fans the batch out to the VM detectors and re-aggregates issues; a quiet timeline still dispatches an empty batch once per second. The verdict matches the batch's phase events to the frames whose windows overlap it (UI-thread events against build windows, raster events against raster windows) and is correlated for the worst jank frame that matched at least two events, provided at least half of the batch's events matched some frame; otherwise it falls back to the batch-level full verdict. On a jank verdict the controller asks for the frame's CPU samples (`getCpuSamples`) at the end of the dispatch.
5. **Tail.** The heap sample (`getMemoryUsage`).

The VM timeline is never cleared: the ring buffer is bounded by the VM, so retaining it costs no app memory, events written between two polls are not lost to the fetch-then-clear gap (the VM ring buffer still bounds retention under load), DevTools keeps its timeline, and capture export (`fetchRawTimelineEventsJson`, a separate full read) sees scenario markers in both modes. If the clock read fails or returns a value behind `newest`, the poll reads the whole buffer and drops every event before the window origin client side (`PollTimings.windowFallback`, `pollWindowFallbacks`).

Every poll records a `PollTimings` (`Sleuth.lastPollTimings`): `rpcMicros`, `decodeMicros` (the part of `rpcMicros` after the raw response arrived; null when unmatched), `parseMicros`, `dispatchMicros`, `tailMicros` (the clock read plus the heap sample), the raw event count, the raw response length (matched to the request id through `VmService.onSend` / `onReceive`; null when unmatched), and the events dropped as duplicates. The dispatch is split into detectors (`processTimelineData` + `evaluateNow`), correlate (frame matching and the verdict), aggregate (`_aggregateIssues`), and other (capture bookkeeping, export buffers, the CPU-samples request); the tail reports the `getMemoryUsage` await and how much of it overlapped an in-flight `getCpuSamples` or `getAllocationProfile` request. `ext.sleuth.diagnose` serves the same values plus 32-poll maxima of the RPC, decode, parse, and dispatch segments.

Decode, parse and dispatch run synchronously on the UI isolate and delay any frame work queued behind them; `PollTimings.uiBlockingMicros` is their sum. RPC and tail are wall time across awaits and include VM-side work; outside the decode they cost the app only what the VM spends on the isolate's thread (see below), not the length of the await.

The detectors' own work is small: an 1,800-event batch replayed from a device capture (230 phase events, 74 janky frames) dispatches in about 0.13 ms on an M1 Pro (`test/benchmark/dispatch_overhead_test.dart`). Isolate RPCs are not: the VM serves them on the target isolate's thread, interrupting whatever Dart code runs there. `getCpuSamples` builds the profile there and returns about 3.3 MB for a 60 ms window (the function table), decoded on the same isolate; on an M1 Pro one request costs about 20 ms in the code it interrupts plus 95 ms before the next response. Requests are therefore spaced by `VmServiceClient.cpuSamplesMinInterval` (10 s) and never overlap, and a request that timed out client side still counts as in flight until the VM answers or 30 s pass (`VmServiceClient.cpuSamplesInFlightStaleAfter`).

Measured on the iPhone 12 (iOS 17.5, Flutter 3.47.6, profile, 500 ms polls; median / max per poll over a walk of the idle home screen, the tabbed shell, the FPS stress screen and a five-minute idle hold):

| mode, screen | RPC ms | parse ms | dispatch ms | tail ms | events | response |
|---|---|---|---|---|---|---|
| capture, idle home, before | 117 / 128 | 7.6 / 9.4 | 0.1 / 0.2 | 0.5 | 23.8k | 3.7 MB |
| capture, idle home, after | 6.6 / 7.5 | 0.3 / 0.6 | 0.0 / 0.4 | 2.8 | 278 | 38 KB |
| capture, FPS stress, before | 154 / 154 | 15 / 21 | 282 / 311 | 616 / 747 | 28.7k | 4.7 MB |
| capture, FPS stress, after | 13.7 / 41 | 1.1 / 5.0 | 0.2 / 0.2 | 26.5 / 32 | 3.7k | 530 KB |
| live, idle home, before | 6.6 / 10.1 | 1.5 / 2.4 | 0.3 / 0.6 | 3.7 / 714 | 170 | 23 KB |
| live, idle home, after | 6.4 / 8.6 | 0.3 / 0.5 | 0.2 / 0.3 | 2.5 / 3.0 | 271 | 37 KB |
| live, FPS stress, before | 33 / 39 | 1.5 / 3.3 | 211 / 238 | 808 / 847 | 1.8k | 293 KB |
| live, FPS stress, after | 67 / 70 | 2.6 / 2.6 | 0.2 / 0.2 | 27 / 30 | 9.6k | 1.6 MB |

"Before" is the build with timings only; "after" is this release. The capture-mode stall was the whole-buffer re-read. The FPS stress dispatch and tail were the per-poll `getCpuSamples` request. The live FPS stress RPC grew because the old fetch-then-clear sequence, stretched to over a second by that request, silently dropped most of that screen's events; the incremental window now returns all of them (about 9.6k per 500 ms on that screen), so the remaining cost there is event volume, not Sleuth's processing. The 714 ms tail spike at idle was an allocation-profile request overlapping the poll. In capture mode the five-minute idle hold stayed at 6–8 ms RPC with no growth, and on the final build the FPS stress screen's verdict mode read `correlated`. Decode was measured in a separate short run on the same build: 1.0 ms per poll on the idle home screen (144 events, 18 KB), 5–10 ms in the first polls after launch while the startup burst drains, and 21–29 ms per poll on the FPS stress screen (9–10k events, 1.5–1.7 MB). With parse and dispatch that is about 1.5 ms of UI-isolate time per 500 ms at idle and about 32 ms per 500 ms on the stress screen. A helper isolate for decode and parse was considered and not built: at idle it would save about a millisecond per poll, and on the stress screen the lever is the event volume of the Embedder stream (raster events at 20 fps), not where the decode runs; narrowing that stream in live mode is the follow-up.

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
| Rebuild | VM BUILD scope durations + tree; debug per-widget counts | Share of UI-thread time spent rebuilding (per ~1 s window) | Confirmed for the time share, Possible for widget attribution | Degrades to structural density report without VM |
| GPU Pressure | FrameTiming raster vs UI per frame + VM raster timing + render tree | Raster thread dominance | Likely from frames (3 raster-dominant frames in 1 s, every tier); Confirmed when the VM ratio also fires; nodes Likely when either coexists | Frame leg needs Frame Timing enabled and ignores the startup window. Impeller raster durations can include present back-pressure, so frame evidence stays Likely. Sigma-aware severity for BackdropFilter; ColorFiltered detection via widget type |
| Repaint | VM PAINT scope durations + per-widget debug paint counts | Share of UI-thread time spent painting (per ~1 s window), animation-owned suppression | Confirmed for the time share, Possible for widget attribution | Degrades to structural-only without VM |

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

## Overlay state and back handling

The controller owns an `OverlayUiState` (dashboard open, trigger anchor, card geometry and window state, hidden keys, severity filter), so none of it resets when the dashboard closes or on hot reload. The trigger's anchor is the nearest horizontal edge plus the vertical position as a fraction of the safe-area height, resolved on every layout inside `MediaQuery.viewPaddingOf` (plus a 16 px margin) and above `viewInsetsOf`; rotation keeps the edge and the fraction. With `SleuthConfig.stateStore` set, `initialize()` reads the store once (2 s timeout, defaults on any error), applies it, and only then lets the trigger paint; a field changed before the read finishes keeps its value (hidden keys are merged). Later changes are written after a trailing 500 ms debounce, one write in flight at a time (a change during a write queues one more write with the latest state), and a pending change is written on dispose. A read that times out turns writes off for the session. The JSON carries `schemaVersion: 1`; unknown keys are ignored, a malformed field takes its default, and at most 200 hidden keys are kept.

The card list is `applyOverlayFilters`: the severity filter runs before `computeVisibleIssues` (an effect whose only cause is filtered out surfaces as its own card), hiding runs after it (a hidden root takes its collapsed effects along). The hide key is `stableId` (or `title`) plus `|widgetName` when the issue names a widget. A severity change clears every expansion together with the freeze snapshot. Hiding is overlay-only: aggregation, `latestIssues`, `suppressedCount`, `ext.sleuth.*`, snapshots, route sessions and recurrence never read the overlay state.

The overlay sits above the app's `MaterialApp`, with no `Navigator` or `Router` of its own, so back handling goes through `WidgetsBindingObserver.didPopRoute`. `SleuthOverlay` registers its observer before the app's `WidgetsApp` and `handlePopRoute` asks observers in registration order, stopping at the first `true`. While the dashboard is open, back unfocuses a focused text field, else closes the open full-screen page or the Hidden list, else closes the dashboard; with the dashboard closed it returns `false`. An observer an app registers before `runApp` is asked first. For Android predictive back the overlay claims `handleStartBackGesture` while a layer is open and closes the innermost layer on commit; it also requests `SystemNavigator.setFrameworkHandlesBack(true)` after each layer change (post-frame), because `WidgetsApp` resets the flag on its own navigation notifications. Flutter 3.32 gives a predictive swipe to the first observer that claims it; later versions offer it to every observer, so an app route that can pop may pop together with the overlay layer.

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
