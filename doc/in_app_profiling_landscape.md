# In-App Profiling Landscape Research

Comprehensive survey of Flutter/Dart packages and approaches that implement
in-app profiling capabilities similar to DevTools.  Conducted March 2026.

---

## 1. In-App Network Inspectors

### 1.1 Alice (flutter_alice / alice)

- **pub.dev**: https://pub.dev/packages/alice and https://pub.dev/packages/flutter_alice
- **Source**: https://github.com/oromico/flutter-alice

**Approach**: Alice is a multi-client HTTP inspector.  It does **not** use
`HttpOverrides.global` or `vm_service`.  Instead it relies on explicit
integration hooks per HTTP library:

| HTTP Client       | Integration mechanism                                              |
|--------------------|--------------------------------------------------------------------|
| **Dio**            | `dio.interceptors.add(alice.getDioInterceptor())` — standard Dio Interceptor |
| **http** package   | Manual call: `alice.onHttpResponse(response)` after each call      |
| **Chopper**        | Chopper interceptor adapter                                        |
| **dart:io HttpClient** | Manual: `alice.onHttpClientRequest(req)` / `alice.onHttpClientResponse(res, req)` |

**UI**: Ships its own overlay UI with a navigator key.  Shows request/response
bodies, headers, timing, status codes, errors.  Notification badge, shake-to-open,
search, and export to file.

**Limitations**:
- Requires manual wiring for each HTTP client.
- Does not auto-intercept — you must plumb every client.
- UI requires a navigator key injected into the app's MaterialApp.

**Profile mode**: Yes — the interceptor pattern is pure Dart and works in any
build mode.  No dependency on debug-only APIs.

---

### 1.2 Chuck Interceptor (chuck_interceptor)

- **pub.dev**: https://pub.dev/packages/chuck_interceptor
- **Source**: https://github.com/SunnatilloShavkatov/chuck_interceptor

**Approach**: Same architecture as Alice — explicit interceptor per client
(Dio, http, dart:io HttpClient).  Catches and stores requests/responses in
memory, shown via built-in overlay UI.

**Features**: Notification badge, shake-to-open, stats summary, export, search.

**Profile mode**: Yes.  Pure Dart interceptor pattern.

---

### 1.3 Chucker Flutter (chucker_flutter)

- **pub.dev**: https://pub.dev/packages/chucker_flutter
- **Source**: https://github.com/syedmurtaza108/chucker-flutter

**Approach**: Works as a Dio/http `Interceptor`.  Stores network data on
local storage (not just in memory), which survives hot-restarts.  Shows
in-app notifications with status code and URL; tapping opens a detail screen.

**Key difference from Alice/Chuck**: Persists call data to local storage
rather than only holding it in memory.  This is useful for post-mortem
inspection but adds a storage dependency.

**Profile mode**: Yes.

---

### 1.4 Flutter Stetho (flutter_stetho) - DISCONTINUED

- **pub.dev**: https://pub.dev/packages/flutter_stetho
- **Source**: https://github.com/brianegan/flutter_stetho

**Approach**: Fundamentally different — wraps dart:io HttpClient at the
platform level and pipes data to Facebook's Stetho library (Android only).
You inspect traffic in `chrome://inspect`, not in-app.

**How it works**: `Stetho.initialize()` in `main()` hooks the native Android
Stetho bridge.  All HttpClient traffic is forwarded to Chrome DevTools'
Network tab via the Stetho protocol.

**Limitations**:
- Android only.
- Discontinued; not compatible with Flutter 2.x+.
- Not an in-app inspector — requires Chrome.
- No iOS / web / desktop support.

**Profile mode**: Was intended for debug only.

---

### 1.5 Talker + talker_dio_logger

- **pub.dev**: https://pub.dev/packages/talker_flutter / https://pub.dev/packages/talker_dio_logger
- **Source**: https://github.com/Frezyx/talker

**Approach**: Unified logging framework with built-in Dio interceptor.
`talker_dio_logger_plus` adds Chucker-style request cards with tabbed
detail views and cURL export with token masking.

**Profile mode**: Yes.  Pure Dart.

---

### 1.6 HttpOverrides.global approach (Joker pattern)

- **pub.dev**: https://pub.dev/packages/joker
- **Source**: https://github.com/juanvegu/joker_dart

**Approach**: Sets `HttpOverrides.global` before any networking code runs.
This intercepts **all** `HttpClient` creation at the dart:io level, meaning
any package that ultimately uses dart:io (including `http`, `dio` when on
native) is captured transparently — no per-client wiring needed.

**Relevance to widget_watchdog**: This is the only approach that provides
truly automatic interception without requiring the app developer to modify
their HTTP client setup.  However:
- Only works on native platforms (not web).
- Must be set before any HttpClient is created.
- Overrides are global — can conflict with other packages that also set
  `HttpOverrides.global`.

---

### Network Inspector Summary

| Package            | Interception method        | Auto-capture? | In-app UI? | Profile mode? | Maintained? |
|--------------------|----------------------------|---------------|------------|---------------|-------------|
| Alice              | Per-client interceptors    | No            | Yes        | Yes           | Yes         |
| Chuck Interceptor  | Per-client interceptors    | No            | Yes        | Yes           | Yes         |
| Chucker Flutter    | Per-client interceptors    | No            | Yes        | Yes           | Yes         |
| Flutter Stetho     | Native Stetho bridge       | Partial       | No (Chrome)| No            | Discontinued|
| Talker             | Dio interceptor + logger   | No            | Yes        | Yes           | Yes         |
| HttpOverrides      | HttpOverrides.global       | Yes           | No (DIY)   | Yes           | N/A (pattern)|

**Key insight**: No maintained package uses `vm_service` for network
inspection.  The proven approaches are either per-client interceptors
(Alice/Chuck/Chucker/Talker) or `HttpOverrides.global` (Joker pattern).
The interceptor approach is universally adopted because it works across
all build modes and platforms without debug-only API dependencies.

---

## 2. In-App Memory Profiling

### 2.1 leak_tracker (Official Dart Team)

- **pub.dev**: https://pub.dev/packages/leak_tracker
- **Source**: https://github.com/dart-lang/leak_tracker

**Approach**: Instrumentation-based leak detection.  The framework calls
`LeakTracking.dispatchObjectCreated()` at object creation and
`dispatchObjectDisposed()` at disposal.  The leak tracker then uses
`WeakReference` to check if objects are actually garbage-collected after
disposal.

**API surface**:
- `LeakTracking.start()` — enables tracking
- `FlutterMemoryAllocations.instance.addListener()` — hooks into Flutter's
  allocation events
- `collectLeaks()` — programmatic retrieval of leak data
- Default: checks every 1 second, outputs to console, sends to DevTools

**vm_service usage**: Uses `getAllocationProfile(isolateId, gc: true)` to
force a garbage collection cycle, then checks WeakReferences.  Also uses
`streamListen("GC")` to listen for GC completion events.

**Profile mode**: Available, but with a caveat: `FlutterMemoryAllocations`
must be explicitly enabled in profile mode to track Flutter Framework objects.
In debug mode this is automatic.

**Limitations**:
- Primarily designed for unit tests (`leak_tracker_flutter_testing`).
- Runtime leak detection works but is documented as secondary use case.
- Requires vm_service connection for `forceGC` via `getAllocationProfile`.
- If vm_service is unavailable, GC cannot be forced and leak detection
  becomes probabilistic (waits for natural GC).

---

### 2.2 WeakReference + Finalizer pattern (manual approach)

**Approach**: Attach a `Finalizer` callback to disposable objects.  If
the finalizer is never called after disposal, the object leaked.

```
// Conceptual pattern
final _leak = Finalizer<String>((label) {
  // Object was collected — remove from watch list
});

void trackDisposable(Object obj, String label) {
  _leak.attach(obj, label, detach: obj);
  _watchList.add(label);
}
```

**Relevance**: This is what `leak_tracker` does internally, but you can
implement a lighter version without the full leak_tracker dependency.

**Limitations**:
- `Finalizer` callbacks run asynchronously and are not guaranteed to run
  promptly (or at all before process exit).
- No ability to force GC without vm_service.
- Cannot detect why an object leaked (no retaining path info without
  vm_service's `getRetainingPath`).

---

### 2.3 ProcessInfo.currentRss (dart:io)

**Approach**: `ProcessInfo.currentRss` returns the current Resident Set Size
in bytes.  Several packages use this for in-app memory display:

- `flutter_performance_monitor_plus` uses `ProcessInfo.currentRss` for its
  memory overlay
- `flutter_perf_monitor` uses the same approach

**Limitations**:
- RSS is process-level, not Dart-heap-specific.  Includes native memory,
  shared memory, and may double-count shared pages.
- Returns 0 on web.
- Cannot distinguish Dart heap from native allocations.
- Useful as a trend indicator, not for precise leak detection.

**Profile mode**: Yes.  `dart:io` is available in all build modes.

---

### 2.4 vm_service getMemoryUsage / getAllocationProfile

**Approach**: Connect to VM service via `dart:developer.Service.getInfo()`
and call:

- `getMemoryUsage(isolateId)` — returns heap used, heap capacity, external usage
- `getAllocationProfile(isolateId, gc: true)` — forces GC and returns per-class
  allocation counts

**This is what widget_watchdog already uses** (via VmServiceClient) for GC
event listening.  The existing `onGcEvent` callback receives GC events.

**Profile mode**: Works in profile mode.  vm_service connection depends on
platform (see Section 6 below).

---

### Memory Profiling Summary

| Approach                     | Granularity      | Force GC? | Profile mode? | Requires vm_service? |
|------------------------------|------------------|-----------|---------------|----------------------|
| leak_tracker                 | Per-object leaks | Yes       | Yes*          | Yes (for forceGC)    |
| WeakReference + Finalizer    | Per-object leaks | No        | Yes           | No                   |
| ProcessInfo.currentRss       | Process-level    | N/A       | Yes           | No                   |
| vm_service getMemoryUsage    | Isolate heap     | No        | Yes           | Yes                  |
| vm_service getAllocationProfile | Per-class alloc | Yes       | Yes           | Yes                  |

*leak_tracker in profile mode requires explicit FlutterMemoryAllocations enable.

---

## 3. In-App CPU/Performance Profiling

### 3.1 vm_service getCpuSamples

**API**: `VmService.getCpuSamples(isolateId, timeOriginMicros, timeExtentMicros)`

**How it works**: The Dart VM continuously collects CPU samples (snapshots of
the call stack at regular intervals).  `getCpuSamples` retrieves samples from
a specified time window.  The VM uses a ring buffer that overwrites old samples
when full.

**Parameters**:
- `timeOriginMicros` — start of time range (same clock as `Timeline.now`)
- `timeExtentMicros` — duration of time range

**Return value**: `CpuSamples` object containing stack frames, sample counts,
and timing data.  Can be used to build flame charts or identify hot functions.

**Alternative**: `getPerfettoCpuSamples` returns the same data in Perfetto's
proto format.

**Profile mode**: Yes — this is the recommended mode.  CPU profiles in debug
mode are not representative due to debug overhead.

**Limitations**:
- Ring buffer means old samples get overwritten.  No "start/stop" control
  without `clearCpuSamples`.
- Sample buffer size is fixed by the VM.  `--profile-startup` flag changes
  behavior to discard instead of overwrite.
- Requires vm_service connection.
- Heavy serialization cost: the VM serializes the entire sample buffer to JSON.
- **No known published package** wraps getCpuSamples for in-app use.  This is
  exclusively consumed by DevTools.

---

### 3.2 SchedulerBinding.addTimingsCallback + FrameTiming

**API**: `SchedulerBinding.instance.addTimingsCallback(callback)`

**How it works**: The Flutter engine reports `FrameTiming` objects containing:
- `buildDuration` — time spent in the build phase
- `rasterDuration` — time spent in the raster phase
- `totalSpan` — end-to-end frame time
- `vsyncOverhead`, `buildStartTime`, `rasterStartTime`, etc.

Data is batched and delivered:
- ~every 100ms in debug/profile mode
- ~every 1 second in release mode

**Profile mode**: Yes.  This is the recommended mode.  Overhead is ~0.01% CPU
per second (measured on iPhone 6s).  In release mode with no listeners, overhead
drops to approximately zero.

**Packages using this**:
- `statsfl` — simple FPS chart overlay using addTimingsCallback
- `flutter_performance_monitor_plus` — full overlay with FPS, jank, build/raster times
- `flutter_perf_monitor` — real-time FPS + memory overlay
- **widget_watchdog** already uses this via `FrameTimingDetector`

**Key insight**: This is the universal, proven, cross-platform approach for
frame-level performance monitoring.  Every in-app performance package uses it.

---

### 3.3 dart:developer Timeline (custom tracing)

**API**: `Timeline.startSync('label')` / `Timeline.finishSync()`

**How it works**: Injects custom events into the VM timeline stream.  These
appear alongside framework events (build, layout, paint) in DevTools and
in `getVMTimeline()` output.

**Relevance**: widget_watchdog already consumes timeline events via
`getVMTimeline()`.  Custom tracing allows apps to mark expensive operations
for correlation with frame data.

**Profile mode**: Yes.  Timeline events are recorded in profile mode.

---

### CPU/Performance Summary

| Approach                    | What it measures       | Requires vm_service? | Profile mode? | Any package wraps it? |
|-----------------------------|------------------------|----------------------|---------------|-----------------------|
| getCpuSamples               | Stack-sampled CPU time | Yes                  | Yes           | No (DevTools only)    |
| addTimingsCallback          | Frame build/raster     | No                   | Yes           | Many (statsfl, etc.)  |
| Timeline.startSync          | Custom trace sections  | No (to emit)         | Yes           | N/A (manual)          |
| getVMTimeline               | All timeline events    | Yes                  | Yes           | widget_watchdog       |

**Key insight**: No published package has attempted in-app `getCpuSamples`
consumption.  The serialization cost and the difficulty of building a
meaningful in-app flame chart likely explain why this remains DevTools-only.
Frame timing via `addTimingsCallback` is the universally adopted alternative.

---

## 4. Widget Rebuild Tracking

### 4.1 debugProfileBuildsEnabled / debugProfileBuildsEnabledUserWidgets

**Approach**: Setting these flags to `true` in `main()` causes the Flutter
framework to emit `Timeline` events for every widget build.  These events
include the widget type name and are consumable via `getVMTimeline()`.

- `debugProfileBuildsEnabled` — emits events for ALL widgets (framework + user)
- `debugProfileBuildsEnabledUserWidgets` — emits events for user widgets only

**How DevTools uses this**: DevTools enables these flags, then reads timeline
events to count rebuilds per widget type per frame.  The "Rebuild Stats" feature
(Flutter 3.24+) aggregates these counts in real time.

**Profile mode**: These are debug-only flags (`dart:ui` debug properties).
They do NOT work in profile or release mode.  This is a hard limitation.

---

### 4.2 performance_profiler package

- **pub.dev**: https://pub.dev/packages/performance_profiler

**Approach**: Provides a `TrackedWidget` wrapper that monitors rebuild frequency
per screen/component.  Uses a `ProfilerNavigatorObserver` for screen-level tracking.

**Components**:
- `PerformanceAnalyzer` — state management for metrics
- `TrackedWidget` — wrapper widget that counts its own rebuilds
- `ProfilerOverlay` — display overlay
- `ProfilerNavigatorObserver` — navigation integration

**How it counts rebuilds**: The `TrackedWidget` increments a counter in its
`build()` method.  This is a wrapper-based approach — you must wrap widgets
you want to monitor.

**Profile mode**: Yes — this is pure Dart and works in all build modes.

**Limitations**:
- Requires manual wrapping of widgets (not automatic).
- Cannot detect rebuilds of widgets you haven't wrapped.
- Adds overhead proportional to the number of tracked widgets.

---

### 4.3 flutter_performance_monitor_plus

- **pub.dev**: https://pub.dev/packages/flutter_performance_monitor_plus

**Approach**: Tracks "rebuilds/sec" as one of its overlay metrics alongside
FPS, memory, and CPU.

**Rebuild counting method**: Likely uses `SchedulerBinding` frame callbacks
combined with element tree walking, or timeline events when
`debugProfileBuildsEnabled` is on.

**Profile mode**: Claims to work in debug/profile mode.

---

### 4.4 What widget_watchdog already does

widget_watchdog's `RebuildDetector` and `ShallowRebuildRiskDetector` consume
timeline events containing widget build data.  This works when:
1. VM service is connected
2. `debugProfileBuildsEnabled` is true (debug mode only)

This is the same approach DevTools uses, but consumed in-app.

---

### Widget Rebuild Summary

| Approach                         | Automatic? | Granularity    | Profile mode? | Accuracy  |
|----------------------------------|------------|----------------|---------------|-----------|
| debugProfileBuildsEnabled        | Yes        | Per-widget type| No (debug)    | Exact     |
| TrackedWidget wrapper            | No         | Per-wrapped    | Yes           | Exact     |
| Element tree walking / heuristic | Yes        | Structural     | Yes           | Heuristic |

**Key insight**: There is no way to get per-widget rebuild counts in profile
mode without wrapping widgets.  `debugProfileBuildsEnabled` is debug-only.
The wrapper approach (performance_profiler) works in profile mode but requires
developer effort.  widget_watchdog's structural/heuristic detectors are the
right fallback for profile mode.

---

## 5. Timeline Analysis

### 5.1 vm_service getVMTimeline

**API**: `VmService.getVMTimeline(timeOriginMicros?, timeExtentMicros?)`

**How it works**: Returns all recorded timeline events as a list of
`TimelineEvent` objects in Chrome trace-event format.  Events include:
- Framework events (build, layout, paint, composite)
- Dart events (custom Timeline.startSync)
- Embedder events (raster, VSync)
- GC events

**widget_watchdog already uses this** via `VmServiceClient._pollTimeline()`
every 500ms.  The `TimelineParser` processes these events.

**Timeline streams**: Controlled via `setVMTimelineFlags(['Dart', 'Embedder', 'GC'])`.

**Limitations**:
- Events are unordered — no guaranteed chronological order.
- Buffer management: must call `clearVMTimeline()` to avoid reprocessing.
- Polling approach means events between polls are batched.
- On Android, getVMTimeline may fail if VM service connection fails.

---

### 5.2 Integration test timeline tracing

**API**: `IntegrationTestWidgetsFlutterBinding.traceTimeline(action, streams:)`

**How it works**: Runs an action and captures a `vm.Timeline` for it.  Used in
integration tests to record and later analyze frame data.  Output can be saved
to JSON for loading in `chrome://tracing`.

**Relevance**: This is a testing-time approach, not a runtime in-app approach.
But it demonstrates that timeline event consumption from within a Dart process
is feasible and officially supported.

---

### 5.3 dart:developer Timeline (emit side)

Apps can emit custom timeline events that are then capturable via getVMTimeline:

```dart
import 'dart:developer' as dev;

dev.Timeline.startSync('expensiveOperation');
doExpensiveWork();
dev.Timeline.finishSync();
```

These events appear in the same stream as framework events and can be correlated.

---

### Timeline Analysis Summary

| Approach                     | Direction  | Runtime? | Profile mode? | Package support?       |
|------------------------------|------------|----------|---------------|------------------------|
| getVMTimeline                | Consume    | Yes      | Yes           | widget_watchdog        |
| Integration test tracing     | Consume    | Test     | Yes           | integration_test       |
| Timeline.startSync/finishSync| Emit       | Yes      | Yes           | dart:developer (stdlib)|
| setVMTimelineFlags           | Configure  | Yes      | Yes           | vm_service             |

**Key insight**: widget_watchdog is one of the only packages that consumes
timeline events at runtime for in-app analysis.  Most packages either emit
events (for DevTools to consume) or consume them only during integration tests.
This is a genuine differentiator.

---

## 6. Cross-Cutting: VM Service Self-Connection

This is the foundation that enables advanced profiling (timeline, CPU samples,
memory allocation profiles) from within the app itself.

### How it works

1. `dart:developer.Service.getInfo()` returns the VM service URI
2. Convert HTTP URI to WebSocket URI
3. Connect via `vmServiceConnectUri(wsUri)`
4. Use the connected `VmService` instance to call RPCs

### Platform reliability

| Platform           | Reliability | Notes                                       |
|--------------------|-------------|---------------------------------------------|
| macOS desktop      | High        | Reliable for development                    |
| Linux desktop      | High        | Reliable for development                    |
| iOS real device    | Good        | Works well; local network permission needed |
| iOS simulator      | Good        | Works well                                  |
| Android emulator   | Medium      | URI may use adb-forwarded port              |
| Android real device| Low-Medium  | Connection refused common; URI unreachable  |
| Web                | None        | vm_service not available                    |
| Release mode       | None        | VM service disabled entirely                |

### Known issues

- `Service.getInfo()` may return null URI; may need
  `Service.controlWebServer(enable: true)` and retry
- Android real devices: the reported URI often uses `127.0.0.1` which is
  the host machine's loopback, not the device's
- Connection timeout needed (widget_watchdog uses 3 seconds)
- DDS (Dart Development Service) may intercept the connection in some
  configurations

**widget_watchdog's approach** (fallback to BASIC mode on connection failure)
is the correct pattern — this matches what the landscape shows.

---

## 7. Relevant Composite Packages

### 7.1 flutter_performance_monitor_plus

- **pub.dev**: https://pub.dev/packages/flutter_performance_monitor_plus

Most feature-complete in-app profiler overlay found.  Combines:
- FPS via addTimingsCallback
- Build/raster time display
- Rebuilds/sec counter
- Memory via ProcessInfo.currentRss
- CPU% (best-effort, may be null on some platforms)
- Network request logging (HTTP capture)
- Hot reload/restart counters
- Draggable bubble UI

**Profile mode**: debug and profile.

**What it does NOT do**:
- No vm_service connection
- No timeline event consumption
- No leak detection
- No CPU sampling (getCpuSamples)
- No per-widget rebuild attribution

---

### 7.2 ispect

- **Source**: https://github.com/yelmuratoff/ispect

Logging and inspection tool combining Talker-style logs with in-app inspector UI.
HTTP inspection, logging, and developer tools in one package.

---

## 8. What This Means for widget_watchdog

### Proven feasible by the landscape

1. **Frame timing overlay** (addTimingsCallback) — universally adopted, works
   in profile mode, near-zero overhead.  widget_watchdog already has this.

2. **Network interception** — per-client interceptors (Alice pattern) are the
   standard.  HttpOverrides.global is the only auto-capture approach but has
   conflict risks.

3. **Process-level memory display** (ProcessInfo.currentRss) — simple, works
   everywhere except web.  Good enough for trend monitoring.

4. **VM service self-connection** — feasible on iOS and desktop, unreliable on
   Android.  widget_watchdog already handles this correctly with fallback.

5. **Timeline event consumption at runtime** — widget_watchdog is ahead of the
   curve here.  No other published package does this.

6. **Leak detection via WeakReference + Finalizer** — proven by leak_tracker,
   can work without vm_service (but cannot force GC).

### Not yet proven feasible in-app

1. **getCpuSamples consumption** — no package does this.  The serialization
   cost and UI complexity of flame charts likely make this impractical for
   in-app use.  Heuristic detection from timeline events is the better path.

2. **Per-widget rebuild counting in profile mode** — impossible without wrapping
   widgets.  debugProfileBuildsEnabled is debug-only.  Structural heuristics
   are the correct profile-mode approach.

3. **Retaining path analysis** — vm_service's `getRetainingPath` can identify
   why an object is retained, but no package uses this at runtime.  Very
   expensive.

### widget_watchdog's unique position

widget_watchdog is the only package that:
- Consumes VM timeline events at runtime for in-app analysis
- Combines frame timing + timeline + structural heuristics
- Has graceful degradation from full VM mode to basic mode
- Targets profile mode as a first-class use case

The closest competitor is `flutter_performance_monitor_plus`, which has a
richer overlay UI but shallower analysis (no timeline, no per-detector
attribution, no structural heuristics).
