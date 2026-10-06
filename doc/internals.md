# Sleuth internals and detector reference

This page holds the reference material the main [README](../README.md) leaves out: how Sleuth measures frames, the scan loop, the VM connection and poll pipeline, debug rebuild and paint counts, the full detector matrix, recurrence-trend thresholds, ranking, overlay state, startup metrics, and platform troubleshooting.

## Measurement window

Sleuth reports the frame's total duration, the build-to-raster span from Flutter's `FrameTiming`. It does not report vsync delivery cadence (`CADisplayLink` on iOS, `Choreographer.doFrame` on Android). The two metrics differ: `FrameTiming` reports how long the engine took to produce a frame, and a vsync-anchored metric reports when the OS displayed it. A frame produced in 3 ms still waits about 13 ms for the next vsync, so `FrameTiming` reports 3 ms where a vsync metric reports about 16 ms. Comparisons across frameworks that mix the two show large deltas where the behaviour is the same.

`FrameTimingDetector` and `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` on each emission. The value is `startup` when the issue was emitted within `DetectorThresholds.startupPhaseWindowSeconds` (default 5 s) of `Sleuth.dartEntryMonotonicUs`. The tag uses emission time, so a late callback can tag a startup-phase frame as `steady` when the emission lands past the window. The tag appears in capture-mode trace records and audit-gate replay, not in saved JSON snapshots. Use it to separate startup artefacts (route inflation, font loading, Material animations) from steady-state regressions.

## Scan loop

The structural scan runs on a self-rescheduling timer. Its callback scans in a post-frame callback, so a tick needs a frame to run. The interval starts at `treeScanInterval` (1 s). After three consecutive scans with no issues it doubles, up to 2 s and never below the base. Each tick times its unified walk plus aggregation. A tick over 4 ms stretches the next interval to `treeScanInterval × ceil(cost / 4 ms)`, capped at 5 s and never below the back-off interval; capture mode turns the stretch off. With `maxElementsPerScan > 0`, a walk over the cap skips the next tick once and schedules the following one at twice the interval. Walks are never cut short, and the previous issues stay visible. While the user scrolls, a tick retries after 250 ms, at most three times in a row, and a scroll with no start or update notification for 2 s counts as ended. Scroll notifications only re-measure highlight rects from the render objects they were measured from, and one early tick runs 300 ms after a scroll ends. `issuesNotifier` fires only when a rendered field of the ranked list changes. `scanTickNotifier` pulses once per tick for panels that re-read live state, such as rebuild counts and recurrence badges.

A scan keys rebuild and repaint evidence on the screen: the route name, the scaffold hash and the hot-reload generation. When the key changes, `RebuildDetector` and `RepaintDetector` drop what they hold and restart their VM window, and no detector receives that scan's debug counts, which span the change (a hot reload rebuilds every element once). A scan that cannot find a single visible page, such as two Scaffolds side by side during a transition, drops the held per-widget debug cards.

## VM connection

Sleuth connects to the app's own VM service from inside the app. Frame timing mode is the cross-platform path and gives accurate build and raster timing in profile builds. VM full mode adds the sub-phase breakdown (build, layout, paint and raster) but depends on VM service connectivity, which varies by platform. Sleuth falls back to frame timing mode when the VM is unavailable. On cold start, a background reconnect ladder (seven attempts, from 500 ms up to 30 s apart) upgrades Sleuth to full mode once the VM web server binds, with no manual action. On Android it also covers the cold-start port bind race.

`flutter run` starts DDS (Dart Development Service) by default, and DDS claims the device's VM service as its only client. That blocks Sleuth's in-process self-connect, so Sleuth stays in frame timing mode for the session. `flutter run --profile --no-dds` lets Sleuth connect on the first run, with no relaunch. Hot reload and hot restart still work; you lose the features only DDS provides (smoother multi-client DevTools, log history).

When you need DDS, DevTools and Sleuth at once, launch the installed binary directly so no DDS attaches.

**Android:**
```bash
flutter run --profile -d <id>          # build + install once, then quit (q)
adb -s <id> shell am start -n com.example.example/.MainActivity
adb -s <id> logcat -d | grep "Dart VM service"
adb -s <id> forward tcp:<port> tcp:<port>   # for sleuth_mcp / external tooling
```

**iOS simulator:**
```bash
flutter run --profile -d <id>          # build + install once, then quit (q)
xcrun simctl launch booted com.example.example
# capture the URI: xcrun simctl spawn booted log stream | grep "Dart VM service"
```

On either path, `ext.sleuth.diagnose` (shown by the `sleuth_mcp` `diagnose` tool) reports `vmConnected: true`, and so does `Sleuth.diagnoseCaptureState()` in the app. On emulators and simulators (software rendering, weak CPU) VM polling can lower FPS, so measure frame rates on a real device.

## VM poll pipeline

With a VM connection, `VmServiceClient` polls every 500 ms on the UI isolate. One poll has five steps.

1. **Window.** The first poll of a session, and the first after a reconnect, reads the whole timeline buffer, which still holds the engine startup events. Later polls first read the VM's timeline clock (`getVMTimelineMicros`, the clock that event `ts` values use) and request `getVMTimeline(timeOriginMicros: max(0, newest − 500 ms), timeExtentMicros: clock − origin + 1 s)`. Here `newest` is the largest `ts` accepted so far, and 500 ms is `VmServiceClient.fetchOverlapMicros`, one poll interval. The overlap covers events a thread appends with a `ts` older than another thread's newest event. A begin/end pair that straddles a fetch is not read again: the begin waits in the parser's pending-begin map until its end arrives, up to `TimelineParser.maxReconstructedPhaseUs` (2 s) apart.
2. **RPC.** The await of `getVMTimeline`. Most of it is the VM serializing the window and the transport, while the UI isolate runs frames. The tail end is different: package:vm_service pushes the raw string to `onReceive`, then decodes the JSON and builds the `Timeline` on the UI isolate before the future completes. The client stamps the arrival of the response that matches its request id. It searches only the first and last 64 characters of each raw message, so an id nested in a payload cannot match. The time from that stamp to the completed await is the decode.
3. **Parse.** One pass. Each thread has a cursor: `lastTs` plus the signatures of the events at exactly `lastTs`. An event below its thread's cursor is dropped after three map lookups, and the `(ph, name, id)` signature string is built only for ties at `lastTs`. The pass returns the batch's largest accepted `ts`, which advances `newest` and anchors the sweep that evicts pending begins and idle cursors older than 30 s.
4. **Dispatch.** `onTimelineData` passes the batch to the VM detectors and re-aggregates issues. A quiet timeline still dispatches an empty batch once per second. The verdict matches the batch's phase events to the frames whose windows overlap it: UI-thread events against build windows, raster events against raster windows. It is correlated for the worst janky frame that matched at least two events, when at least half of the batch's events matched some frame. Otherwise, for a batch with phase data, the batch-level full verdict applies to the latest frame if that frame is janky and does not already hold a full or correlated verdict. A batch without phase data, such as the idle heartbeat, never replaces a verdict. After a verdict the controller requests that frame's CPU samples (`getCpuSamples`) once per frame, and the answer is attached to whatever verdict the frame holds when it arrives.
5. **Tail.** The heap sample (`getMemoryUsage`).

The VM timeline is never cleared. The VM bounds the ring buffer, so keeping it costs no app memory, and events written between two polls are not lost to a fetch-then-clear gap; the ring buffer still bounds retention under load. DevTools keeps its timeline, and capture export (`fetchRawTimelineEventsJson`, a separate full read) sees scenario markers in both modes. The clock reading bounds `newest`: thread cursors past `clock + 1 s` are rewound to the newest cursor within it, so one event stamped on another clock cannot hold the window shut. If the clock read fails or returns a value behind `newest`, the poll reads the whole buffer and drops every event before the window origin on the client side (`PollTimings.windowFallback`, `pollWindowFallbacks`). After three such fallbacks in a row, the next poll forgets `newest` and reads the whole buffer with no floor.

Every poll records a `PollTimings` (`Sleuth.lastPollTimings`) with these values: `rpcMicros`; `decodeMicros`, the part of `rpcMicros` after the raw response arrived, or null when the response was not matched; `parseMicros`; `dispatchMicros`; `tailMicros`, the clock read plus the heap sample; the raw event count; the raw response length, matched to the request id through `VmService.onSend` and `onReceive`, or null when not matched; and the events dropped as duplicates. The dispatch splits into detectors (`processTimelineData` and `evaluateNow`), correlate (frame matching and the verdict), aggregate (`_aggregateIssues`), and other (capture bookkeeping, export buffers, the CPU-samples request). The tail reports the `getMemoryUsage` await and how much of it overlapped an in-flight `getCpuSamples` or `getAllocationProfile` request. `ext.sleuth.diagnose` serves the same values plus 32-poll maxima of the RPC, decode, parse, and dispatch segments.

Decode, parse and dispatch run synchronously on the UI isolate and delay any frame work queued behind them; `PollTimings.uiBlockingMicros` is their sum. RPC and tail are wall time across awaits and include VM-side work. Outside the decode, they cost the app only the time the VM spends on the isolate's thread (see below), not the length of the await.

The detectors' own work is small. An 1,800-event batch replayed from a device capture (230 phase events, 74 janky frames) dispatches in about 0.13 ms on an M1 Pro (`test/benchmark/dispatch_overhead_test.dart`). Isolate RPCs cost more: the VM serves them on the target isolate's thread and interrupts whatever Dart code runs there. `getCpuSamples` builds the profile on that thread and returns about 3.3 MB for a 60 ms window, mostly the function table, which is decoded on the same isolate. On an M1 Pro one request costs about 20 ms in the code it interrupts plus 95 ms before the next response. Requests are therefore spaced by `VmServiceClient.cpuSamplesMinInterval` (10 s) and never overlap. A request that timed out on the client still counts as in flight until the VM answers or 30 s pass (`VmServiceClient.cpuSamplesInFlightStaleAfter`).

Measured on the iPhone 12 (iOS 17.5, Flutter 3.47.6, profile, 500 ms polls). Each cell is the median / max per poll over a walk of the idle home screen, the tabbed shell, the FPS stress screen and a five-minute idle hold:

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

"Before" is the build that only added these timings; "after" adds the incremental fetch window, the spaced CPU-sample requests and the parse changes of v0.37.0. The capture-mode stall was the whole-buffer re-read. The FPS stress dispatch and tail were the `getCpuSamples` request made on every poll. The live FPS stress RPC grew because the old fetch-then-clear sequence, stretched past a second by that request, dropped most of that screen's events without notice. The incremental window now returns all of them, about 9.6k per 500 ms on that screen, so the remaining cost there is event volume, not Sleuth's processing. The 714 ms tail spike at idle was an allocation-profile request that overlapped the poll. In capture mode the five-minute idle hold stayed at 6 to 8 ms of RPC with no growth, and on the final build the FPS stress screen's verdict mode read `correlated`. Decode was measured in a separate short run on the same build: 1.0 ms per poll on the idle home screen (144 events, 18 KB), 5 to 10 ms in the first polls after launch while the startup burst drains, and 21 to 29 ms per poll on the FPS stress screen (9k to 10k events, 1.5 to 1.7 MB). With parse and dispatch, that is about 1.5 ms of UI-isolate time per 500 ms at idle and about 32 ms per 500 ms on the stress screen. A helper isolate for decode and parse was considered and not built. At idle it would save about a millisecond per poll, and on the stress screen the cost comes from the event volume of the Embedder stream (raster events at 20 fps), not from where the decode runs. Live mode still records the full Embedder stream.

## Debug rebuild and paint counts

With `SleuthConfig.enableDebugCallbacks` in a debug build, Sleuth installs `debugOnRebuildDirtyWidget` and `debugOnProfilePaint` and drains per-widget counts on every scan. These hooks conflict with DevTools "Track Widget Rebuilds". Sleuth checks each hook separately: when one is already set, it leaves that hook alone and prints a debug message.

- Per-widget counts keep only widgets the app creates, as the framework's creation tracking decides (`DebugInstrumentationConfig.userWidgetsOnly`, default true). Widgets from other packages count. Every paint the hook sees feeds the aggregate count, its animation-owned share and the repaint-boundary detector. Per-widget repaint cards read a separate origin record instead. Inside the hook, `debugNeedsPaint` still holds the render object's own flag from before it paints, so each marked paint is a candidate. A marked node with a marked parent clears that parent, and the deepest marked node in each layer is the layer's likely origin. `flushPaint` repaints the deepest dirty boundaries first, so a boundary already repainted in the same frame counts as a marked child of its parent. A repaint boundary that `flushPaint` repaints without a hook call of its own is credited when none of its children was marked. Each origin maps to the nearest widget the app creates and counts once per instance per frame. The card uses the busiest instance's rate and reports how many instances repainted (`DebugSnapshot.paintOrigins`). Sleuth does not credit slivers, viewports, framework control painters, Material's ink splashes, or origins under a `Scrollable` that is scrolling. The cards are `likely`, because an ancestor that marked itself looks the same as one its child marked. The CustomPainter detector's `frequent_repaint_painter` card reads the same origin rate and holds it across scans the same way.
- A rebuild counts for the widget that started it with a `setState`, a changed dependency or a listenable builder. The widgets its build updates are credited to it in `DebugSnapshot.forcedRebuildsByRoot` and named in its card's detail instead of raising cards of their own.
- Sleuth's own overlay is left out. `OverlayOwnership` treats an element as the overlay's when the walk up from it reaches the overlay before the app, and caches that answer per element. The widget Sleuth wraps around the app is skipped too.
- While a screen reader is on, paints of the framework's semantics-only widgets (`Semantics`, `MergeSemantics`, `ExcludeSemantics`, `BlockSemantics`, `IndexedSemantics`, `_GestureSemantics`) are not counted.
- A paint is animation-owned when an owner from `animationOwnerNames` appears in its ancestor chain, within 16 ancestors, or within 4 levels below the painted element (`isAnimationOwnedPaint`). The owners that animate by rebuilding (`AnimatedBuilder`, `ValueListenableBuilder`, `TweenAnimationBuilder`, `AnimatedContainer`, `AnimatedPadding`, `AnimatedAlign`, `AnimatedPositioned`, `AnimatedPositionedDirectional`, `AnimatedFractionallySizedBox`) own paints only in frames where they rebuilt, so an idle one next to a repainting widget does not hide it. A type past the 200-type cap gets no per-widget entry but still counts toward the animation-owned aggregate.

`RateHysteresis` holds per-type rates across scans. A type enters when one scan window reaches its threshold. It leaves when its rate over the last two windows falls below 0.75 times the threshold, or at once on a scan where it did not occur. Critical works the same way around the critical boundary, and highlights use the same held set.

`RebuildDetector` and `RepaintDetector` keep each source's issues until that source updates. Per-widget issues refresh with each scan's snapshot, and the VM share refreshes with each VM window. Every VM window is evaluated, also while per-widget cards are shown. Per-widget cards win; otherwise the VM share shows while connected, and `excessive_repaint_debug`, the debug aggregate, shows only without a VM connection. The `rebuild_activity` and `excessive_repaint` cards stay until the share is under 0.8 times the threshold for two windows, and stay critical until it is under 0.8 times the critical boundary for two windows. Emissions keep their measured severity, and capture mode shows each window as measured. A VM disconnect removes the VM card. When one widget has both a rebuild and a repaint card, the correlator keeps the more severe one.

## Frame budget

The jank budget comes from three inputs: `fpsTarget`, the display's reported refresh rate (`View.display.refreshRate`, read by the overlay), and the measured vsync cadence. `FrameTimingDetector` keeps the last 120 `vsyncStart` deltas, ignoring gaps longer than two `fpsTarget` frames. After 30 samples it estimates the cadence as `1e6 / p10(deltas)`. It uses the 10th percentile rather than the median because fast frames reveal the vsync period while slow frames are what is being measured; a median would fold steady jank into the cadence and loosen the budget. The estimate snaps to 30, 60, 90, 120 or 144 Hz when it is within 8 % of one.

The effective rate is the measured cadence clamped to `[fpsTarget, display rate]`. The display rate is only a cap, because iOS reports `UIScreen.maximumFramesPerSecond` (120 on ProMotion) even while the app renders at 60. `fpsTarget` is the floor, so a janky app cannot loosen its own budget. With no measurement the budget is `1e6 / fpsTarget` µs. `FrameStats.frameBudgetUs` carries the budget per frame, and jank compares microseconds: at 60 Hz the budget is 16667 µs, so a 16.8 ms frame is jank and a 33 ms frame is not severe. When the budget tightens below the `fpsTarget` budget, the `raster_dominance` per-frame floor and the default `heavy_compute` threshold become half of it; at the `fpsTarget` budget they stay at 8000 µs and 8 ms. With `autoFrameBudget: false`, and always in capture mode, the budget is the fixed `fpsTarget` budget.

## FPS troubleshooting

If the overlay shows unexpected FPS, check these causes:

1. `SleuthConfig.fpsTarget` caps the overlay. A ProMotion 120 Hz device with the default `fpsTarget: 60` shows `60` while it renders 120 frames per second. `actualFpsRaw` in the exported snapshot holds the uncapped value. The jank budget is not capped this way; see the frame budget section above.
2. The overlay shows a dash instead of a number while the rolling window holds fewer than 3 samples (about 50 ms at 60 Hz), so it never shows a red `0 FPS` at launch or after navigation.
3. Debug builds run about 10 times slower than profile builds. Check FPS numbers with `flutter run --profile`.
4. Raster-cache metrics read 0 on Impeller. Sleuth detects this and suppresses the cache-family warnings; FPS is unaffected.
5. The rolling window is anchored on the engine's `rasterFinish` timestamps, not `DateTime.now()`, so batched `addTimingsCallback` delivery does not distort the count.

## Detector matrix

### Runtime detectors (always available)

| Detector | Signal source | Can prove | Confidence | Known limitations |
|----------|-------------|-----------|------------|-------------------|
| Frame Timing | FrameTiming API | Frame exceeded budget, thread attribution (UI-bound, raster-bound, pipeline stall), judged on the frames since the current route was first scanned | Confirmed | Cannot attribute to a specific widget. Frames up to one scan tick after navigation count toward the previous route |
| Network Monitor | HttpOverrides | Slow, excessive, oversized, error-spiking, or high-frequency same-path HTTP requests | Confirmed; Likely for high-frequency same-path | Sees only `dart:io` `HttpClient` traffic, including `package:http`'s default `IOClient` and Dio's default adapter. `cronet_http`, `cupertino_http`, and platform-SDK networking are invisible. `large_response` skips `image/`, `video/`, `audio/`, and `font/` responses |
| Tracked Resource | `Sleuth.trackResource(name, ref)` with `WeakReference` and Finalizer | Concurrent retention (more than 5 live instances of one name) and long-lived retention (one instance alive more than 300 s) | Confirmed | Opt-in: app code must call `Sleuth.trackResource`. Registration from another isolate does nothing |

### VM-only detectors (require a VM connection)

| Detector | Signal source | Can prove | Confidence | Known limitations |
|----------|-------------|-----------|------------|-------------------|
| Shader Jank | VM timeline begin/end pairs | Impeller Vulkan pipeline build or Skia shader compile of 100 ms or more | Likely | Silent on Impeller Metal, which precompiles pipelines |
| Heavy Compute | VM timeline BUILD scopes | Build pass over 8 ms (half the frame budget when the measured rate is above `fpsTarget`); one issue per VM batch, the longest | Confirmed | Needs a VM connection |
| Platform Channel | VM timeline | High call frequency (count-only trigger; per-call max and p95 duration recorded); the card stays 10 s after a burst | Confirmed | Needs `debugProfilePlatformChannels`: opt in with `SleuthConfig(profilePlatformChannels: true)`, which sets it after the VM connects. The framework then prints a stats table every second |
| Memory Pressure | VM GC events, heap polling, process RSS | Elevated GC frequency (over 180/min, scavenge and old-gen split stamped), steady heap growth (linear regression), RSS at 80 % or more of an opt-in `memoryBudgetBytes` while the heap grows | Likely | The budget rule is off unless `DetectorThresholds.memoryBudgetBytes` is set, and it needs RSS, which web does not report |
| Stream Resource | `getAllocationProfile` class-instance diff over a 4-sample window | Retained async resources (dart:async, dart:io, web_socket_channel, rxdart subjects) while `heap_growing` fires | Likely | Gated on `MemoryPressureDetector.isHeapGrowingActive` |

### Hybrid detectors (VM and tree scan, degrade without a VM)

| Detector | Signal source | Can prove | Confidence | Known limitations |
|----------|-------------|-----------|------------|-------------------|
| Rebuild | VM BUILD scope durations and the tree; debug per-widget counts | Share of UI-thread time spent rebuilding per ~1 s window; per-widget rebuild rate in debug builds | Confirmed for the time share and debug counts; Possible for the structural density report | Without a VM it reports StatefulWidget density only. Debug counts cover only widgets the app creates |
| GPU Pressure | FrameTiming raster vs UI per frame, VM raster timing, render tree | Raster thread dominance | Likely from frames (3 raster-dominant frames in 1 s, every tier); Confirmed from the VM ratio; render nodes Likely when either leg fires, else Possible | The frame leg needs Frame Timing enabled and ignores the startup window. Impeller raster durations can include present back-pressure, so frame evidence stays Likely. BackdropFilter severity depends on sigma; ColorFiltered is detected by widget type |
| Repaint | VM PAINT scope durations; debug per-widget paint counts | Share of UI-thread time spent painting per ~1 s window, with animation-owned paints excluded from the debug paths | Confirmed for the time share and per-widget debug counts; Likely for the debug aggregate | Without a VM it reports only from debug callbacks. Debug counts cover only widgets the app creates |

### Structural detectors (tree scan only)

| Detector | Signal source | Can prove | Confidence | Known limitations |
|----------|-------------|-----------|------------|-------------------|
| setState Scope | Element tree | A StatefulWidget owns a large subtree and is seen rebuilding | Possible to Confirmed | Emits only with child-identity churn or debug-callback rebuild counts; a static wide page never emits. Builder-style owners (FutureBuilder, StreamBuilder, Form, Focus, ...) are skipped. Const subtrees are discounted when churn evidence is present |
| Layout Bottleneck | Render tree | IntrinsicHeight or IntrinsicWidth present; Wrap with too many children | Possible to Likely | Present does not mean slow: a single intrinsic is Possible, nesting is Likely. Intrinsics built by ToggleButtons, MenuBar, linear landscape BottomNavigationBar labels, AlertDialog and SimpleDialog, popup menus, CupertinoContextMenu, and Scaffold footer buttons are suppressed |
| ListView | Element tree | Non-lazy list with many children; shrinkWrap list inside a Column or Row | Possible | May be intentional for small lists. Catches ListView, GridView and SliverList built from a children list; `non_lazy_shrinkwrap` also catches builders with more than 20 children |
| Image Memory | Element tree and decoded `ui.Image` | Image decoded above the physical pixels its box needs | Likely | Counts an image at 1.5 times or more on the smaller axis and emits at 1 MiB or more of total waste. Undecoded images, ResizeImage, `BoxFit.none`, `centerSlice`, `repeat`, and BoxDecoration images are not measured. A widget that later grows may need the larger decode |
| CustomPainter | Element tree | shouldRepaint always returns true | Possible to Likely | May be needed for animated painters. Framework painters are skipped: toggle and scrollbar painters by type, Material shape borders, TabBar, progress indicators and others by name plus owner within a measured hop budget. The paint rate excludes animation-owned paints |
| Keep Alive | Element tree | Many keep-alive pages | Possible | A trade-off between memory and rebuild cost. Counts toward the innermost PageView or TabBarView only; list keep-alives are ignored |
| Font Loading | Element tree | More custom font families than the limit (3); runtime-loaded fonts (fontFamilyFallback heuristic) | Possible | The font may already be loaded. Runtime detection is a heuristic, so an intentional fallback chain can trigger it. Platform system and icon fonts are ignored; google_fonts variants count once |
| RepaintBoundary | Element and render tree | Expensive GPU widget without a RepaintBoundary ancestor; too many boundaries in a scrollable | Possible to Likely | Rises to Likely with debug paint-rate evidence, never Confirmed, because paint rates are per type, not per instance. ColorFiltered is detected by widget type. Framework painters and Material's own ClipPath are skipped; boundaries a default sliver delegate adds are never counted |
| Startup | `Sleuth.init()` and FrameTiming | TTFF over budget, dominant phase attribution | Confirmed | One-shot; requires `Sleuth.init()` before `runApp()`. The wall-clock measurement has about 5 to 50 ms of inherent skew |

## Recurrence badge

Each issue card shows a `Seen X/Y · {label}` badge once Sleuth has observed the issue across at least two scan cycles. It shows how sticky the issue is and whether it is getting better or worse.

- X is the number of scan cycles in which the issue fired (`presentCount`).
- Y is the number of scan cycles in the ring buffer, which holds 60 and evicts the oldest.

The label summarises the trend over the most recent window, 10 entries by default:

| Label | Color | When it appears |
|-------|-------|-----------------|
| worsening | red | Average severity in the second half of the window exceeds the first half by more than `0.3`. |
| persistent | amber | The trend is `stable` and `X / Y ≥ 0.9`, so the issue fires in almost every cycle. |
| stable | neutral | The issue is present consistently and its severity is not trending. |
| improving | green | Average severity in the second half of the window is lower than the first half by more than `0.3`. |
| flaky | neutral | The issue toggles between present and absent 3 or more times in the window (`intermittent` internally). |

Two labels differ from the JSON export:

- `flaky` is the display label for the `intermittent` enum value; JSON exports use `intermittent`.
- The UI derives `persistent` from a `stable` trend plus the 90 % presence ratio. The JSON export reports the underlying enum (`stable`) and a separate `totalOccurrences / totalObserved` pair, so you can recompute it downstream.

The badge and trend show persistence; severity always comes from the detector. See [`RecurrenceTrend`](../lib/src/models/recurrence_trend.dart) for the thresholds.

## Ranking and causal graph

[`IssueRanker`](../lib/src/ranking/issue_ranker.dart) scores each issue as `tier × 100 + frameImpact × 8 + recurrence × 2`. The tier combines severity and confidence:

| Severity | Confirmed | Likely | Possible |
|----------|-----------|--------|----------|
| critical | 6 | 5 | 3 |
| warning | 4 | 2 | 1 |
| ok | 0 | 0 | 0 |

The resulting order is confirmed critical, likely critical, confirmed warning, possible critical, likely warning, possible warning, ok. The largest bonus (frameImpact 3, recurrence 5) adds 34 points, less than the 100-point gap between tiers, so bonuses never move an issue across tiers.

[`CausalGraphRule`](../lib/src/analyzer/causal_graph.dart) holds 41 cause-to-effect rules. Before it looks for roots, it drops any edge whose cause is `possible` and whose effect is `likely` or `confirmed`, so a structural guess never claims an observed effect. `activeEdges` in the export applies the same filter.

In the overlay, an effect with exactly one cause collapses under that cause only when the cause is present and at least as severe as the effect. An effect with two or more causes always stays in the main list with a "Caused by" section.

## Route sessions

Sleuth detects route changes from the element tree, with no `NavigatorObserver`. Each route gets its own `RouteSession` with per-route FPS, jank ratio, issue snapshots and a composite health score from 0 to 100.

```dart
final history = Sleuth.routeHistory; // List<RouteSession>?
final score = Sleuth.routeHealthScore('/settings'); // int?

SleuthConfig(
  routeIgnorePatterns: {'/dialog*', '/splash'}, // skip ephemeral routes
  routeHistoryCapacity: 50,                      // max sessions retained (FIFO)
)
```

Bottom-navigation apps that use `IndexedStack`, `StatefulShellRoute.indexedStack` or `CupertinoTabScaffold` share one `ModalRoute` across all tabs but give each tab its own `Scaffold`. Sleuth keys sessions on `(routeName, scaffoldHashKey)`, so each tab gets its own `RouteSession` instead of all tabs sharing one route name. `tabVisitIndex` (starting at 1) tells repeat visits to the same tab apart. `TabBar`, `TabBarView` and `PageView` swipes within one route stay inside the outer session. `PerformanceIssue.routeName` stays raw for group-by-route filtering; use `issue.routeDisplayName` for labels that people read (for example `"/home (tab-2)"` on the second visit). Both the JSON and the markdown exports include route health data.

## Overlay state and back handling

The controller owns an `OverlayUiState`: dashboard open, trigger anchor, card geometry and window state, hidden keys, severity filter, and theme mode. None of it resets when the dashboard closes or on hot reload, and the dashboard-open flag is never saved. The trigger's anchor is the nearest horizontal edge plus the vertical position as a fraction of the safe-area height. It is resolved on every layout inside `MediaQuery.viewPaddingOf` plus a 16 px margin and above `viewInsetsOf`; rotation keeps the edge and the fraction.

With `SleuthConfig.stateStore` set, `initialize()` reads the store once with a 2 s timeout, applies it, and only then lets the trigger paint. A field changed before the read finishes keeps its value, and hidden keys are merged. Later changes are written after a trailing 500 ms debounce, with one write in flight at a time; a change during a write queues one more write with the latest state. A write still running after 5 s is given up. A pending change is written when the app goes to the background (`paused` or `hidden`) and on dispose. A read that times out, throws, or returns state from a newer `schemaVersion` turns writes off for the session, so the stored value is left as it is. Contents no release can read (not a JSON object, or no valid `schemaVersion`) keep the defaults and are replaced by the next change. The JSON carries `schemaVersion: 1`; unknown keys are ignored, a malformed field takes its default, and at most 200 hidden keys are kept.

The card list is `applyOverlayFilters`. The severity filter runs before `computeVisibleIssues`, so an effect whose only cause is filtered out shows as its own card. Hiding runs after it, so a hidden root takes its collapsed effects along. The list key is `stableId` (or `title`) plus `|widgetName` when the issue names a widget. A critical card's hide key adds `!critical`: a key taken from a critical card hides the issue at any severity, while a key taken from a warning or ok card does not hide it once it turns critical. A severity change clears every expansion together with the freeze snapshot. Hiding is overlay-only: aggregation, `latestIssues`, `suppressedCount`, `ext.sleuth.*`, snapshots, route sessions and recurrence never read the overlay state.

The overlay sits above the app's `MaterialApp` with no `Navigator` or `Router` of its own, so back handling goes through `WidgetsBindingObserver.didPopRoute`. `SleuthOverlay` registers its observer before the app's `WidgetsApp`, and `handlePopRoute` asks observers in registration order, stopping at the first `true`. While the dashboard is open, back unfocuses a focused text field, else closes the open full-screen page or the Hidden list, else closes the dashboard. With the dashboard closed it returns `false`. An observer the app registers before `runApp` is asked first. For Android predictive back, the overlay claims `handleStartBackGesture` while a layer is open and closes the innermost layer on commit. It requests `SystemNavigator.setFrameworkHandlesBack(true)` after each layer change (post-frame), because `WidgetsApp` resets the flag on its own navigation notifications. While a layer is open, it also checks the app's navigators after each frame and requests the flag again when one of them changes whether it can pop or how many overlay entries it holds. Flutter 3.32 gives a predictive swipe to the first observer that claims it; later versions offer it to every observer, so an app route that can pop may pop together with the overlay layer.

## Startup tracing

Sleuth measures cold-start performance with `Sleuth.init()` and `Sleuth.markInteractive()`. Call `Sleuth.init()` as the first line of `main()`:

```dart
void main() {
  Sleuth.init();          // Dart-entry clock starts here
  runApp(Sleuth.track(child: const MyApp()));
}
```

Sleuth reports four metrics over three windows:

| Metric | Window | Source |
|--------|--------|--------|
| `ttffMs` | Dart entry to first frame raster-finish | `FrameTiming` callback |
| `engineTtffMs` | Engine C++ entry to first frame rasterized (matches `flutter run --trace-startup`) | VM timeline |
| `preDartOverheadMs` | Engine C++ entry to Dart entry (native pre-Dart phase) | VM timeline |
| `frameworkInitMs` | `WidgetsFlutterBinding.ensureInitialized()` duration | `Timeline.now` delta |

`ttffMs` isolates the work Dart controls, with default thresholds of 1500 ms (warning) and 3000 ms (critical). `preDartOverheadMs` is outside Dart's control: typically 400 to 1200 ms on iOS, 300 to 900 ms on Android, and often over 1500 ms on Android Go.

Use `ttffMs` to catch Dart regressions, such as heavy work in `main()`, the first `build()` or the initial route. Use `engineTtffMs` for product dashboards. Compare `preDartOverheadMs` with `ttffMs` to split the cost between the engine and your code.

The in-app Startup metrics page shows the full method and a per-phase breakdown.

## iOS builds from `flutter build ios` lose source locations

Sleuth reads `file.dart:42` locations from Flutter's widget-creation tracking. Flutter compiles that tracking into debug and profile builds when the build asks for it, and never into release builds. `flutter run --profile` and `flutter build apk --profile` ask for it by default, so their issues show locations.

`flutter build ios` and `flutter build ipa` have no tracking option and write `TRACK_WIDGET_CREATION=false` into `ios/Flutter/Generated.xcconfig`. Xcode reads that file when it compiles the Dart code. A profile build from these commands has no locations, and so does an Xcode or `fastlane gym` archive that runs after them. Everything else in Sleuth works the same.

To keep locations in an iOS profile build, set the value to `true` after the Flutter step and before Xcode compiles:

```bash
flutter build ios --profile --config-only
sed -i '' 's/TRACK_WIDGET_CREATION=false/TRACK_WIDGET_CREATION=true/' ios/Flutter/Generated.xcconfig
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Profile -destination generic/platform=iOS build
```

In a Fastfile, make the same replacement before `gym`:

```ruby
xcconfig = File.expand_path('../ios/Flutter/Generated.xcconfig', __dir__)
text = File.read(xcconfig)
File.write(xcconfig, text.sub('TRACK_WIDGET_CREATION=false', 'TRACK_WIDGET_CREATION=true'))
gym(scheme: 'Runner', configuration: 'Profile')
```
