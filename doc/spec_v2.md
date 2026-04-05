## Framework Expansion

- Detector-level "How to verify in DevTools" hints via `verificationHint`
- UI badges for `Confirmed`, `Likely`, `Possible` ✅
- A clearer distinction in the UI between observed runtime facts and heuristic guidance ✅ (left border accent by ObservationSource — green/purple/gray)

## Core Foundation Positioning

Until advanced frame correlation lands, use this positioning:

- "VM-powered runtime diagnostics for Flutter apps, combining frame timing, VM timeline signals, and widget-tree heuristics to surface bottlenecks and actionable fixes."

After advanced frame correlation lands:

- "VM-powered runtime diagnostics with precise per-frame phase attribution and heuristic widget-level explanations."

## Framework Expansion Roadmap

These items are intentionally sequenced after the core foundation layer so the profiler framework can expand on top of accurate semantics and stable instrumentation architecture.

Recommended post-v1 priority:

1. `FrameTiming` upgrades
2. Debug-only widget attribution hooks
3. Issue ranking by impact
4. Route tagging and interaction context
5. Rolling capture and JSON export
6. Source-location enrichment after API verification ✅
7. Heavy inspection mode refinements

### 1. FrameTiming upgrades (implemented)

Uses `totalSpan` (vsyncStart → rasterFinish) as the primary jank indicator instead of `max(ui, raster)`, adds build-to-raster gap for pipeline stall detection, and migrates all `totalDuration` consumers to `effectiveTotalDuration`.

**effectiveTotalDuration** (`lib/src/models/frame_stats.dart`): `totalSpan ?? totalDuration`. Nullable `totalSpan` preserves backward compatibility — 26+ test FrameStats creation sites fall back to `max(ui, raster)` without modification. `isJank`, `isSevereJank`, `averageFps`, capture buffer eviction, worst-frame selection, chart bar height, and export summary all use `effectiveTotalDuration`.

**Pipeline stall detection**: New `PipelinePhase.pipelineStall` and `PipelinePhase.schedulerDelay` enum values. In basic mode, three-tier classification: (1) pipeline stall when gap > 25% of budget and both threads under budget, (2) scheduler delay when vsync overhead > 25% of budget, (3) UI/raster by whichever thread is slower. In full mode, a stall fallback fires when no VM-derived phase exceeds the budget but the gap is material. The 25% threshold is conservative and may need retuning if Flutter changes `FrameTiming` semantics.

**Build-to-raster gap** (`FrameTimingDetector._onTimings`): Computed from `FramePhase.rasterStart - FramePhase.buildFinish` raw timestamps. Passed as `Duration.zero` floor. `buildToRasterGapTime` on `FrameVerdict` is nullable — only populated when `totalSpan` is present (real frames from `FrameTiming`), preserving the distinction between "not measured" and "measured zero gap".

**Cross-cutting migration**: 8 production `totalDuration` sites across 5 files migrated to `effectiveTotalDuration`: `frame_chart.dart` (bar height + color thresholds + budget line), `frame_timing_detector.dart` (2 worst-frame selections), `capture_buffer.dart` (3 eviction comparisons), `sleuth_controller.dart` (worstFrameTimeUs).

**Chart consistency** (`lib/src/ui/frame_chart.dart`): Budget line and color thresholds now derive from per-frame `frameBudgetMs` instead of hardcoded 16ms/33ms. 120fps mode (8ms budget) correctly shows yellow at 8ms and red at 16ms.

**Bug fix**: Removed erroneous `* 1024 * 1024` on `pictureCacheBytes` in `frame_timing_detector.dart`. `FrameTiming.pictureCacheBytes` already returns bytes; the multiplication inflated the value by ~1M.

### 2. Debug-only widget attribution hooks (implemented)

Upgrades per-widget paint attribution in `DebugInstrumentationCoordinator` via `renderObject.debugCreator`, then wires debug snapshots into 3 previously-unintegrated detectors so they can upgrade confidence with real evidence.

**Per-widget paint attribution** (`lib/src/debug/debug_instrumentation_coordinator.dart`): `_handleProfilePaint` now extracts widget type via `renderObject.debugCreator` → `DebugCreator.element.widget.runtimeType`. Both `debugCreator` and `debugOnProfilePaint` are debug-only (assert-guarded), so they're always in sync. A `_paintCounts` map alongside `_paintCount` tracks per-type counts, capped by `_maxTrackedTypes` to prevent unbounded memory. O(1) per callback — one type check, one map lookup, one increment.

**DebugSnapshot** (`lib/src/debug/debug_snapshot.dart`): Added `paintCounts` field (default `const {}` — backward-compatible with ~15+ existing creation sites), `paintsPerSecondForType()`, and `totalPaintsFromTypes`. All rate methods use microsecond-precision elapsed division with zero-elapsed guard.

**RepaintDetector** (`lib/src/detectors/repaint_detector.dart`): Three-tier evaluation priority: debug per-widget > VM aggregate > debug aggregate. Per-widget issues get `confirmed` confidence (exact attribution). Critical: all staging fields cleared up front to prevent stale data from lower-priority sources leaking into next evaluation. Fall-through logic: if per-widget path yields no issues (activity spread across many types, none above threshold), falls to VM aggregate, then debug aggregate.

**ShallowRebuildRiskDetector** (`lib/src/detectors/shallow_rebuild_risk_detector.dart`): `updateDebugSnapshot()` stores latest snapshot. When debug confirms rebuilds of flagged widget, upgrades confidence from `possible` to `likely` with `debugCallbackAndStructural` source. Default `observationSource` is path-appropriate: `vmTimeline` in VM-backed path, `structural` in fallback.

**AnimatedBuilderDetector** (`lib/src/detectors/animated_builder_detector.dart`): When `AnimatedBuilder` rebuild rate > 30/sec, adds debug evidence text to detail and sets `observationSource` to `debugCallbackAndStructural`. Confidence stays `likely` (not `confirmed`) because runtime type can't distinguish childless vs child-using instances.

**CustomPainterDetector** (`lib/src/detectors/custom_painter_detector.dart`): When `CustomPaint` paint rate > 10/sec, upgrades confidence from `possible` to `likely` with `debugCallbackAndStructural` source. Not `confirmed` because paint activity can't be pinned to a specific painter instance.

**Controller wiring** (`lib/src/controller/sleuth_controller.dart`): Debug snapshot distribution block expanded to include `_shallowRebuildRisk`, `_animatedBuilder`, and `_customPainter`.

### 3. Issue ranking by impact (implemented)

Implemented in `lib/src/ranking/issue_ranker.dart`. Issues are sorted by a weighted composite score:

```
score = (severity * 100) + (frameImpact * 8) + (confidence * 5) + (recurrence * 2)
```

Severity weight 100 creates non-overlapping tiers (critical: 300-349, warning: 200-249, ok: 100-149), guaranteeing strict severity ordering. Within each tier, frame impact (category aligned with current jank phase), confidence, and scan-cycle recurrence determine the order. Both jank signals are derived from `FrameTimingDetector` state for consistent freshness. Recurrence is updated only from the scan path to prevent VM-backed issues from inflating faster than structural ones. Sort uses explicit index tiebreaker since Dart's `List.sort()` is not guaranteed stable.

### 4. Route tagging and interaction context (implemented)

Route tagging was implemented as part of the controller's `_aggregateIssues()` method, stamping `routeName` via `ModalRoute.of(_lastScanContext)?.settings.name`.

Interaction context tracking adds an `InteractionContext` enum (`idle`, `scrolling`, `navigating`) to `PerformanceIssue`. The controller tracks the current interaction state via a simple state machine: `ScrollStartNotification` → scrolling, `ScrollEndNotification` + 300ms debounce → idle, `_findVisiblePageContext()` returns null → navigating. State transitions trigger immediate re-aggregation so stamps update without waiting for the next scan cycle. The `NotificationListener` is scoped to the app child only (not the overlay stack) to prevent dashboard scrolling from contaminating interaction state. The navigating → idle transition is best-effort with up to ~1s latency (resolved on next scan cycle). The `IssueCard` shows "During: scrolling" or "During: route transition" for non-idle contexts.

### 5. Rolling capture and JSON export (implemented)

Implemented across models, controller, UI, and public API. JSON serialization uses `dart:convert` only (no codegen). Duration fields serialize as microseconds with `Us` suffix. Enums serialize as `.name` strings. DateTime as ISO 8601.

**JankCaptureBuffer** (`lib/src/models/capture_buffer.dart`): Bounded "worst N" buffer (default capacity 50, configurable via `SleuthConfig.captureBufferCapacity`). When full, evicts the mildest entry by `totalDuration`. New entries milder than all existing ones are rejected. Not a FIFO ring buffer — retains the worst frames across the session.

**CaptureEntry**: Bundles `FrameStats` + `FrameVerdict` + separately-stamped `relatedIssues` + `capturedAt`. The `relatedIssues` list is populated from `issuesNotifier.value` (post-aggregation, with route/context tags), NOT from `verdict.relatedIssues` (which are unstamped). `toJson()` strips `verdict.relatedIssues` to avoid conflicting issue lists in the export; the entry-level `relatedIssues` is canonical.

**Capture paths** (in `sleuth_controller.dart`): Two mutually exclusive paths feed the buffer. `_onTimelineData` (full VM mode) uses local variables to bridge the jank decision past `_aggregateIssues()` for stamped issues. `_onFrameStats` (basic/FRAME mode) captures inside the existing jank guard using the most recently stamped `issuesNotifier.value`. A `_lastCapturedFrameNumber` guard prevents duplicate captures.

**SessionSnapshot** (`lib/src/models/session_snapshot.dart`): Top-level export container with `capturedFrames`, `currentIssues`, `frameStatsSummary` (totalFrames, jankFrames, averageFps, worstFrameTimeUs), plus metadata (packageVersion, isVmConnected, isDebugMode, exportedAt). `toJsonString()` produces pretty-printed JSON with 2-space indent.

**Public API**: `Sleuth.exportSnapshot()` and `Sleuth.exportSnapshotJson()` static methods. Return `null` before `wrap()`, after overlay disposal, and in release mode. A static `_controller` reference is set in `wrap()` and cleared in `notifyControllerDisposed()` (called by `SleuthOverlay.dispose()`) with an identity check to handle repeated `wrap()` calls. `currentIssues` in the snapshot is wrapped with `List.unmodifiable()` for defensive immutability.

**Dashboard UI** (`lib/src/ui/dashboard_sheet.dart`): Export button (`Icons.ios_share`) in the header copies the JSON snapshot to the clipboard. A self-managed "Snapshot copied to clipboard" banner appears for 2 seconds (no `ScaffoldMessenger` dependency since the dashboard is not inside a `Scaffold`).

### 6. Source-location enrichment ✅

Goal:

- Improve developer guidance by pointing closer to source ownership.

Constraint:

- only commit to this after verifying the actual supported Flutter API surface and workflow requirements such as widget creation tracking.

**API verification result:** File:line source locations are fundamentally unavailable at runtime in Flutter — `_Location` is private/internal, `dart:mirrors` is unavailable. The achievable enrichment is structured ancestor chain attribution via `element.visitAncestorElements()`.

**Implementation:** Added `ancestorChain: String?` field to `PerformanceIssue`. Populated from 4 per-widget structural detectors (listview, nested_scroll, setstate_scope, shallow_rebuild_risk) and 2 debug callback detectors (rebuild, repaint) via `DebugSnapshot.ancestorChains`. Displayed as "Widget: Outer > Middle > Inner" metadata line in expanded IssueCard. Aggregate detectors not enriched (chains already in detail text). Expanded `_frameworkNames` filter set. 578 tests.

### 7. Heavy inspection mode refinements (partially implemented → enrichment complete)

The core heavy inspection mode architecture is implemented: two-tier config model, selective install, save/restore of 6 Flutter debug globals, UI warning banners, fidelity annotations, and `ObservationSource` tagging across all detectors. See "Advanced Profiling: Debug Instrumentation Strategy" section above for full details.

**Timeline enrichment consumption** ✅ (implemented 2026-03-28):
- `PhaseEvent` extended with `dirtyCount`, `dirtyList`, `scopeContext`, `hasEnrichment`
- `TimelineParser` extracts `args` from scope events using correct phase-specific keys (`"build scope dirty count"` for build, `"dirty count"` for layout/paint); `_parseIntArg` handles String→int conversion; `_parseDirtyList` strips `[...]` brackets
- `HeavyComputeDetector`: enriched build events show dirty widget names in title/detail; falls back to raw durations when no phaseEvents exist
- `RebuildDetector`: dirty widget names from enriched timeline staged atomically with 1s VM window, used for attribution in VM path
- `RepaintDetector`: dirty RenderObject count from enriched timeline staged atomically, appended to VM path detail
- All enrichment degrades gracefully — null args produce identical behavior to pre-enrichment

Remaining refinements:

- more detailed attribution views in the dashboard ✅ (category badges, left border accent by observation source, issues summary bar — 564 tests)
- additional expert controls once real user needs justify them

### 8. Deferred debug instrumentation work

The following items were identified during the debug instrumentation milestone but require capabilities beyond what the current callback APIs provide. They are deferred to a future milestone:

| Item | Status | Notes |
|------|--------|-------|
| Per-widget paint attribution | **Done** (expansion #2) | Implemented via `renderObject.debugCreator` → `DebugCreator.element.widget.runtimeType` in `DebugInstrumentationCoordinator._handleProfilePaint`. Per-type paint counts in `DebugSnapshot.paintCounts`. |
| CustomPainterDetector paint-frequency correlation | **Done** (expansion #2) | `CustomPainterDetector` consumes per-type paint counts from debug snapshot. Upgrades confidence to `likely` with `debugCallbackAndStructural` source when `CustomPaint` paint rate > 10/sec. |
| Rebuild/repaint widget highlights | **Done** (expansion #8) | Tree walk during `scanTree()` correlates debug snapshot / enriched VM names with live Elements to produce `WidgetHighlight` rects via `getGlobalRect(element.renderObject)`. Capped at 3 highlights per type. Repaint walk is conditional — zero overhead when no hot types. |
| `_collectHighlights()` + `detectorNamesForCategory` gaps for Rebuild/Repaint | **Done** (expansion #8) | `_collectHighlights()` now includes `_rebuild.highlights` and `_repaint.highlights`. `detectorNamesForCategory` maps build→Rebuild and paint→Repaint. |

## v2 Roadmap: Closing the DevTools Gap

### Goal

Narrow the gap between Sleuth and DevTools in four areas where DevTools has clear superiority, while staying true to the package's core value: **developers fast know what affects their app's performance, with zero setup.**

Mini flame chart is explicitly out of scope — it adds visualization complexity that competes with DevTools rather than complementing it. Sleuth answers "what's wrong?" not "show me the raw timeline."

### Scope

| Feature | New Detector? | VM Required? | Release Safe? | Priority |
|---------|:---:|:---:|:---:|:---:|
| Network monitoring | Yes (21st) | No | Yes | #1 — **Done** |
| Heap trend monitoring | No (enhances MemoryPressure) | Yes | No | #2 — **Done** |
| Jank CPU attribution | No (enhances FrameVerdict) | Yes | No | #3 — **Done** |
| Source location enrichment | No (enhances ancestorChain) | No | No (debug only) | #4 — **Done** |

### Design Principle

Each feature must produce **issues with actionable fix hints** that fit the existing detector framework. No raw data dumps, no "explore this yourself" UX. The developer glances at the overlay, sees "Slow API: GET /users — 3.2s" or "Heap Growing: +12MB in 30s", and knows what to fix.

---

### v2.1: Network Monitoring — **Done**

**Problem:**

Slow, excessive, or large HTTP requests are a top cause of perceived jank and memory pressure, but Sleuth has no visibility into network activity. This is the only DevTools gap that can be closed with zero VM dependency and full release-mode safety.

**Approach:**

Install a chaining `HttpOverrides.global` in `SleuthController.initialize()` that wraps every `dart:io HttpClient` with a monitoring proxy. The proxy records request timing, response status, and payload size without modifying behavior.

**Design decisions:**

1. **Chaining, not replacing.** Read `HttpOverrides.current` before installing. The sleuth override delegates `createHttpClient()` to the previous override (or `super`), then wraps the returned client. This preserves certificate pinning, proxy configuration, and other custom overrides the app may have installed.

2. **Opt-out, not opt-in.** Network monitoring is enabled by default (`SleuthConfig.enableNetworkMonitoring: true`) for zero-config alignment. Users can disable it or add URL exclusion patterns.

3. **No body capture.** Only record timing, status, URL, method, response size. Never capture request/response bodies — avoids memory pressure from large payloads and eliminates security concerns about logging sensitive data.

4. **Release mode guard.** `HttpOverrides.global` works in all build modes, but Sleuth is `kReleaseMode`-guarded in `wrap()`. Network monitoring follows the same guard — active only in debug/profile mode.

5. **Bounded record storage.** Request records stored in a ring buffer (default 200 entries). Old records evicted FIFO. No unbounded growth.

6. **Issue lifecycle: buffer-derived.** On each new record, `_issues` is cleared and re-evaluated from the current ring buffer contents. Slow/large issues are derived from records currently in the buffer. Frequency is computed by counting records in the last 5s window. Issues naturally disappear as records age out of the buffer. This matches the existing detector pattern where `_issues.clear()` precedes re-evaluation.

7. **Override restoration on dispose.** When `SleuthController.dispose()` is called, restore `HttpOverrides.global` to the previous override captured during install. Only restore if the current override is still the sleuth's instance — another package may have overwritten it since install. Store the previous override reference for identity comparison.

8. **Delegate pattern for HttpClient wrapping.** `_MonitoringHttpClient` delegates all `HttpClient` methods to the real client. Only `openUrl()` is intercepted to wrap the returned `HttpClientRequest` with timing instrumentation. Response body size is measured via stream byte counting (a `StreamTransformer` that counts bytes as they pass through), not body buffering — this preserves streaming behavior and adds negligible overhead.

9. **Frequency timer lifecycle.** A 5-second periodic timer drives frequency evaluation. Created in the detector's constructor (or on first record), cancelled in `dispose()`. Follows the same lifecycle pattern as the existing scan timer in `SleuthController`.

**New detector:**

`NetworkMonitorDetector` — lifecycle: `runtime` (always available, no VM or tree scan needed).

`DetectorType.networkMonitor` added to enum. `IssueCategory.network` added to enum.

Issue types:

| Issue | Condition | Severity | Confidence | stableId |
|-------|-----------|----------|------------|----------|
| Slow Request | Response time > `slowRequestThresholdMs` (default 2000ms) | warning (>2s), critical (>5s) | confirmed | `slow_request` |
| Request Frequency Spike | > `requestFrequencyLimit` (default 30) in 5s window | warning | confirmed | `request_frequency` |
| Large Response | Response body > `largeResponseThresholdBytes` (default 1MB) | warning | confirmed | `large_response` |

All issues are `confirmed` confidence — timing, count, and byte size are directly measured.

**stableId design note:** `slow_request` is per-issue-type, not per-URL — multiple slow requests to different endpoints consolidate into one issue card. This matches existing patterns (`heavy_compute`, `rebuild_activity`). The detail text lists the specific URLs. A per-URL stableId (e.g., `slow_request_/users`) could give richer UI but would create unbounded stableIds if the app hits many endpoints. Per-type is the safer default; per-URL can be reconsidered if users request it.

Fix hints:
- Slow Request: "Consider pagination, caching, or moving this request to app startup. If the endpoint is slow, add a loading indicator to mask latency."
- Request Frequency: "Batch or debounce repeated requests. Consider caching responses or using a single stream subscription instead of polling."
- Large Response: "Request only needed fields (sparse fieldsets / GraphQL). Paginate large collections. Compress responses (gzip)."

**Data flow:**

```
HttpClient.open() / .get() / .post() / ...
              ↓
   SleuthHttpOverrides (chaining proxy)
              ↓
   _MonitoringHttpClient (wraps real client)
              ↓ (on response complete)
   RequestRecord { url, method, status, durationMs, responseBytes, startedAt }
              ↓
   NetworkMonitorDetector.processRecord(record)
              ↓
   _evaluate() → issues
```

The detector evaluates on each incoming record (for slow/large) and on a 5-second timer (for frequency). This avoids polling overhead while still catching burst patterns.

**Configuration:**

New fields on `SleuthConfig`:

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `enableNetworkMonitoring` | `bool` | `true` | Master switch |
| `slowRequestThresholdMs` | `int` | `2000` | Slow request detection threshold |
| `requestFrequencyLimit` | `int` | `30` | Max requests per 5s window |
| `largeResponseThresholdBytes` | `int` | `1048576` (1MB) | Large response threshold |
| `networkExcludePatterns` | `List<String>?` | `null` | URL substring patterns to ignore (e.g. `['/analytics', 'crashlytics']`) |

**Files:**

| File | Action |
|------|--------|
| `lib/src/network/http_monitor.dart` | **Create** — `SleuthHttpOverrides`, chaining logic, `_MonitoringHttpClient` proxy |
| `lib/src/network/request_record.dart` | **Create** — lightweight record with `toJson()` |
| `lib/src/detectors/network_monitor_detector.dart` | **Create** — processes records, produces issues, frequency windowing |
| `lib/src/models/base_detector.dart` | **Edit** — add `DetectorType.networkMonitor` |
| `lib/src/models/performance_issue.dart` | **Edit** — add `IssueCategory.network` |
| `lib/src/controller/sleuth_controller.dart` | **Edit** — instantiate detector, install HttpOverrides in `initialize()`, wire record callbacks |
| `lib/sleuth.dart` | **Edit** — export new public types |
| `lib/src/models/session_snapshot.dart` | **Edit** — include recent request records in export |
| `test/detectors/network_monitor_detector_test.dart` | **Create** |
| `test/network/http_monitor_test.dart` | **Create** |
| `example/lib/demos/network_stress_demo.dart` | **Create** — 15th demo screen |

**Performance constraints:**

- Ring buffer of 200 `RequestRecord` entries: ~16KB. Negligible.
- Per-request proxy overhead: <1ms (two `DateTime.now()` calls + counter increment + buffer write).
- Frequency evaluation timer: 5s interval. One pass over buffer to count recent entries.
- `HttpOverrides` installation: O(1), one-time in `initialize()`.

**Degradation:**

None needed — this detector has no VM dependency. Only degradation path is `enableNetworkMonitoring: false`.

**Edge cases:**

- **User sets `HttpOverrides.global` after `wrap()`:** Sleuth override is lost. Document: call `Sleuth.track()` after any custom `HttpOverrides.global` setup, or set custom overrides before `wrap()` so chaining captures them.
- **Non-HttpClient HTTP libraries** (e.g. `cupertino_http`, `cronet_http`): Not intercepted. Document as known limitation. Dio with default `IOHttpClientAdapter` works (uses `HttpClient` internally).
- **WebSocket traffic:** Not monitored. Out of scope for v2.
- **HTTPS certificate validation:** Chaining preserves the previous override's `createHttpClient` including any custom `SecurityContext`. No interference with cert pinning.

**Acceptance criteria:**

- HTTP requests via `dart:io HttpClient`, `package:http`, and `Dio` (default adapter) are automatically monitored.
- Slow requests (>2s), frequency spikes (>30/5s), and large responses (>1MB) produce issues with actionable fix hints.
- Existing `HttpOverrides` preserved via chaining (verified by test).
- No request/response bodies captured.
- URL exclusion patterns filter analytics/crashlytics traffic.
- Detector disabled via `enableNetworkMonitoring: false` produces zero overhead.
- New demo screen exercises all 3 issue types.

**Testing:**

- Unit tests for `NetworkMonitorDetector`: slow request, frequency spike, large response, below-threshold (no issues), mixed scenarios
- Unit tests for `HttpMonitor`: override chaining (existing override preserved and called), null previous override, double-install idempotency
- URL exclusion pattern matching
- Ring buffer bounds (201st record evicts first)
- Request record `toJson()` serialization
- Benchmark: per-record processing overhead < 100µs

**Implementation notes (v0.2.0):**

All files listed above were created/edited. 37 new tests (25 detector, 8 http_monitor, 4 request_record). 15th example demo screen with 4 trigger buttons (slow, burst, large, all-3). Total test count: 667.

Deviations from spec:

1. **`_MonitoringResponse` extends `Stream<List<int>>`** instead of implementing all stream methods manually. By extending `Stream`, all convenience methods (`toList()`, `drain()`, `forEach()`, `fold()`, etc.) inherit the base `Stream` implementation which calls our `listen()` override. This eliminated ~130 lines of manual delegation and fixed a critical bypass bug where convenience methods would call `_inner.listen()` directly, skipping byte counting and record emission.

2. **Stream error handling in `listen()`:** The `onError` handler emits a partial record (bytes received so far) before forwarding the error. A `recorded` boolean guard prevents double-emission when both `onError` and `onDone` fire. Spec design decision #8 mentioned `StreamTransformer` for byte counting; the actual implementation uses direct `listen()` wrapping which is simpler and avoids an extra stream layer.

3. **Frequency timer auto-cancels when buffer empties.** Spec decision #9 said timer is cancelled in `dispose()`. The implementation also cancels the timer in `_evaluate()` when `_records.isEmpty` — no point ticking on stale state. Timer restarts on next `processRecord()`.

4. **`_networkMonitor` is nullable, not `late final`.** `SleuthController` uses `NetworkMonitorDetector?` to handle the case where `exportSnapshot()` is called before `initialize()`. All access sites use null-safe operators.

5. **`open()` scheme inference:** `_MonitoringHttpClient.open()` infers `https` for port 443, `http` for all others. This only affects the recorded URL string, not the actual connection. `HttpClient.open()` has no scheme parameter, so this is best-effort.

---

### v2.2: Heap Trend Monitoring — **Done**

**Problem:**

`MemoryPressureDetector` monitors GC frequency but has no direct visibility into heap usage trends. A steadily growing heap (common with image caches, large lists, or undisposed resources) goes undetected until GC pressure becomes critical.

**Approach:**

Add `getMemoryUsage(isolateId)` polling to `VmServiceClient` (piggyback on existing 500ms timeline poll). Feed heap metrics to an enhanced `MemoryPressureDetector` that tracks trend direction over a rolling window.

**Design decisions:**

1. **Enhance existing detector, don't create a new one.** Heap trends and GC pressure are two facets of the same memory concern. The `MemoryPressureDetector` already has the correct lifecycle (`vmOnly`) and VM wiring.

2. **Polling frequency.** `getMemoryUsage()` is near-zero cost (returns 3 integers). Call alongside existing `getVMTimeline()` poll (every 500ms). Store a rolling window of 60 samples (30 seconds of history).

3. **Trend detection algorithm.** Simple linear regression over the rolling window. If slope exceeds a configurable threshold (default +500KB/sec sustained for 10+ seconds), flag as growing. This avoids false positives from normal allocation/GC sawtooth patterns where allocations spike then get collected. To prevent false positives from one-time loads (e.g., a 15-second progressive image decode that plateaus), require the slope to remain positive across the *most recent* 10 seconds of samples, not just any 10s window. Slope is re-evaluated on each new sample — if slope drops below the threshold at any point, the sustained growth counter resets. This means a step function (sharp rise then flat) triggers during the rise but self-clears within 10 seconds of the plateau.

4. **No heap snapshots.** `requestHeapSnapshot()` pauses the isolate and generates 20-30MB of data. Antithetical to the zero-overhead goal. Leave heap snapshot browsing to DevTools.

5. **No allocation profiling.** `getAllocationProfile()` returns per-class allocation stats but is noisier and higher cost than heap trend. Deferred unless user demand justifies it.

6. **`externalUsage` captured but not alerted on.** `HeapSample` includes `externalUsage` (native memory from image codecs, platform channels, etc.) for completeness in the session export, but no issues are derived from it in v2. Native memory growth can be significant (images decoded at full resolution allocate in native heap, not Dart heap). Consider adding an external memory threshold issue in a future iteration once real-world usage patterns are observed.

**New issue types (added to MemoryPressureDetector):**

| Issue | Condition | Severity | Confidence | stableId |
|-------|-----------|----------|------------|----------|
| Heap Growing | Positive slope > 500KB/sec for 10+ consecutive seconds | warning | likely | `heap_growing` |
| Heap Near Capacity | heapUsage > 80% of heapCapacity | critical | confirmed | `heap_near_capacity` |

**Heap Growing** is `likely` (not confirmed) because steady growth could be intentional (progressive data loading). **Heap Near Capacity** is `confirmed` because it is a directly observed metric crossing a threshold.

Fix hints:
- Heap Growing: "Memory is growing steadily. Check for undisposed controllers, uncancelled streams, growing caches, or images decoded at full resolution. Use DevTools Memory view for per-object investigation."
- Heap Near Capacity: "App is using N% of available heap. Consider releasing image caches, disposing unused controllers, or paginating large data sets. GC may become frequent and cause jank."

**Data model:**

```dart
class HeapSample {
  final int heapUsage;      // bytes currently used
  final int heapCapacity;   // bytes available
  final int externalUsage;  // external (native) memory
  final DateTime timestamp;
}
```

**Data flow:**

```
VmServiceClient poll (every 500ms)
   ├─ getVMTimeline() → ParsedTimelineData  (existing)
   └─ getMemoryUsage() → MemoryUsage        (new)
              ↓
   onHeapUsage callback → HeapSample
              ↓
   MemoryPressureDetector.processHeapSample(sample)
              ↓
   Rolling window (60 samples = 30s)
              ↓
   _evaluateHeapTrend() → issues
```

**Files:**

| File | Action |
|------|--------|
| `lib/src/models/heap_sample.dart` | **Create** — data class with `toJson()` |
| `lib/src/vm/vm_service_client.dart` | **Edit** — add `getMemoryUsage()` call in poll loop, new `onHeapUsage` callback |
| `lib/src/detectors/memory_pressure_detector.dart` | **Edit** — add heap sample processing, rolling window, trend detection, new issue types |
| `lib/src/models/session_snapshot.dart` | **Edit** — include latest heap stats in export |
| `test/detectors/memory_pressure_detector_test.dart` | **Edit** — add heap trend tests |
| `test/vm/vm_service_client_test.dart` | **Edit** — verify heap polling |

**Performance constraints:**

- `HeapSample`: 3 ints + 1 DateTime = ~40 bytes. 60 samples = ~2.4KB. Negligible.
- `getMemoryUsage()` RPC: <1ms per call. At 500ms interval, <0.2% overhead.
- Linear regression on 60 points: <50µs. Run only when window is full and on each new sample.

**Degradation:**

- No VM connection: heap trend unavailable. Detector retains GC-frequency-only behavior (existing).
- VM disconnects mid-session: rolling window cleared, trend detection resets. No stale issues.
- VM reconnects: window rebuilds from scratch. No pre-fill from historical data.

**Acceptance criteria:**

- `getMemoryUsage()` polled alongside timeline in `VmServiceClient`.
- Steady heap growth > 500KB/sec for 10+ seconds produces a warning issue.
- Heap at > 80% capacity produces a critical issue.
- Normal allocation/GC sawtooth does NOT produce false positives.
- No new issues when VM is unavailable (existing behavior preserved).
- Heap stats included in session export JSON.

**Testing:**

- Synthetic heap sample sequences: flat (no issue), linear growth (issue), declining (no issue), sawtooth with GC (no issue), step function (transient spike, no issue after plateau)
- Threshold edge cases: exactly 500KB/sec slope, oscillating around threshold
- Capacity threshold: 79% (no issue), 80% (issue), 95% (critical)
- Rolling window bounds: verify oldest sample evicted when 61st arrives
- VM disconnect: verify window cleared and no stale issues carry over
- Integration with existing GC issues: both heap trend and GC frequency issues can coexist

**Implementation notes (v2.2):**

All files listed above were created/edited except `test/vm/vm_service_client_test.dart` (VmServiceClient has no test file — VM service is integration-only). Added `test/models/heap_sample_test.dart` (3 tests) and updated `test/models/serialization_test.dart` (2 new tests for heapSamples in SessionSnapshot). 31 detector tests (rewrite of existing + 20 new). Total test count: 689.

Deviations from spec:

1. **Callback named `onHeapSample`, not `onHeapUsage`.** Spec data flow diagram shows `onHeapUsage` callback. Implementation uses `onHeapSample` to match the `HeapSample` type name, consistent with the `onTimelineData`/`ParsedTimelineData` naming pattern.

2. **`updateHeapStats()` fully replaced by `processHeapSample()`.** Spec didn't explicitly call for removing the old method. Since `updateHeapStats()` was never wired from production code and its percentage-based growth logic is superseded by rolling-window regression, it was removed entirely. No dead code retained.

3. **`_initialized` guard in `exportSnapshot()`.** `_memoryPressure` is `late final` (initialized during `initialize()`). Accessing `heapSamples` before `initialize()` would throw `LateInitializationError`. Added `_initialized &&` guard, matching the nullable pattern used by `_networkMonitor`.

4. **`SentinelException` inner catch in `_pollTimeline()`.** Spec design decision #4 mentions handling `SentinelException` for stale isolate IDs. Implementation adds a second catch-all inside the memory poll try block to prevent non-Sentinel errors (e.g., transient `RPCError`) from escaping to the outer catch and triggering a full reconnect when the timeline poll succeeded.

5. **Shared `_evaluate()` with split elapsed guard.** Spec mentioned both `processTimelineData()` and `processHeapSample()` calling a shared evaluation. Implementation splits the `elapsed > 0` guard: only `_evaluateGcPressure()` is guarded (needs it for division by zero in GC/min calc). Heap evaluations (`_evaluateHeapTrend()`, `_evaluateHeapCapacity()`) work immediately with no elapsed guard, allowing heap capacity to alert on the very first sample.

---

### v2.3: Jank CPU Attribution — **Done**

**Problem:**

When Sleuth reports a jank frame ("32ms — build phase dominant"), the developer doesn't know *which code* was expensive. DevTools answers this with a full flame chart, but Sleuth can answer it more directly and actionably: "Top functions: `MyWidget.build` (40%), `jsonDecode` (25%)."

**Approach:**

When a jank frame is detected and VM is connected, query `getCpuSamples()` for that frame's time window and aggregate the top-N functions by exclusive ticks. Include the result in `FrameVerdict`.

**Design decisions:**

1. **On-demand, not continuous.** Only query CPU samples when a jank frame is detected. During smooth rendering at 60fps, zero CPU profiling queries. This keeps overhead strictly zero during normal operation.

2. **Exclusive ticks, not inclusive.** Report functions where time was *actually spent* (exclusive/self), not functions that *contain* expensive children (inclusive/total). Exclusive ticks give the developer the leaf-level "what to optimize" answer.

3. **Top 5 cap.** Only surface the top 5 functions by exclusive ticks. More becomes noise for in-app triage. The full sample data is available in the JSON export for deeper analysis.

4. **Display format.** `ClassName.methodName` when class is available, bare `functionName` otherwise. Library URI omitted from display for brevity but included in JSON export.

5. **Sampling limitation disclosure.** CPU profiling is statistical (~1kHz sampling). Include in fix hint: "Based on statistical sampling — functions running <1ms may not appear. Use DevTools CPU profiler for complete call tree."

6. **Async query with timeout.** `getCpuSamples()` is an async RPC. Call it with a 500ms timeout to avoid blocking verdict generation. If it times out, produce the verdict without CPU attribution.

7. **Two-phase verdict emission.** Emit the `FrameVerdict` immediately without `topFunctions` (same latency as today). Query CPU samples in parallel. When samples return (or timeout), update the verdict's `topFunctions` field and re-notify `verdictNotifier`. The notifier may fire twice for one jank frame — the UI handles this naturally since it always renders the latest value. This ensures the verdict is never delayed by the CPU sample query, while still enriching it when data arrives.

**New model:**

```dart
class CpuAttribution {
  final String functionName;  // "MyWidget.build" or "jsonDecode"
  final String className;     // "MyWidget" or "" for top-level functions
  final String libraryUri;    // "package:my_app/widgets/my_widget.dart"
  final double percentage;    // 0.0-100.0 (exclusive tick share)
}
```

**Data flow:**

```
Jank frame detected (FrameStats.isJank)
              ↓
RenderPipelineAnalyzer builds verdict
              ↓
If VM connected: getCpuSamples(buildStartUs, rasterFinishUs - buildStartUs)
              ↓
CpuSampleAggregator.aggregate(samples, topN: 5)
              ↓
FrameVerdict.topFunctions = List<CpuAttribution>
              ↓
Verdict detail: "Top functions: MyWidget.build (40%), jsonDecode (25%)"
```

**Integration points:**

- `FrameVerdict` gains `topFunctions: List<CpuAttribution>?` field (null when unavailable).
- `VmServiceClient` gains `getCpuSamples(int timeOriginUs, int timeExtentUs)` method. **Clock domain note:** `FrameTiming` uses `dart:ui` monotonic timestamps and `getCpuSamples` uses the VM's monotonic clock (`Dart_TimelineGetMicros`). Both should use the same underlying clock, but verify during implementation that timestamps are comparable. If not, apply an offset calibration using `Timeline.now` at frame capture time.
- `RenderPipelineAnalyzer` or `SleuthController` queries CPU samples during jank verdict generation. Preferred location: controller (keeps analyzer pure/testable with injected data).
- Verdict detail string appends function attribution when available.
- `IssueCard` shows top functions in expanded verdict view.
- Session export includes `topFunctions` in captured frame entries.

**Filtering:**

Raw CPU samples include Dart framework internals (`ComponentElement.performRebuild`, `RenderObject.layout`, etc.), GC samples, and native stubs. Filter rules:
- Exclude samples with `vmTag` indicating GC, compiler, or native code.
- Exclude functions from `dart:*` and `package:flutter/src/*` (framework internals) unless they dominate >50% of samples (in which case they ARE the bottleneck).
- Group remaining by `owner.name + '.' + function.name`.
- User code (from `package:<app_name>/`) sorts before third-party packages.

**Files:**

| File | Action |
|------|--------|
| `lib/src/models/cpu_attribution.dart` | **Create** — data class with `toJson()` |
| `lib/src/vm/cpu_sample_aggregator.dart` | **Create** — aggregation logic: dedup, sort, top-N, percentage |
| `lib/src/vm/vm_service_client.dart` | **Edit** — add `getCpuSamples()` method with timeout |
| `lib/src/models/frame_verdict.dart` | **Edit** — add `topFunctions` field, include in `toJson()` |
| `lib/src/controller/sleuth_controller.dart` | **Edit** — query CPU samples on jank, inject into verdict |
| `lib/src/models/session_snapshot.dart` | **Edit** — include `topFunctions` in captured frame export |
| `lib/src/ui/issue_card.dart` | **Edit** — display top functions in expanded verdict |
| `test/vm/cpu_sample_aggregator_test.dart` | **Create** |
| `test/models/frame_verdict_test.dart` | **Edit** — add topFunctions serialization tests |

**Performance constraints:**

- `getCpuSamples()` called ONLY on jank frames. Typical app: <5 jank frames/minute. Overhead: negligible.
- Serialization of ~1000 samples (1-second window at 1kHz): ~1-5ms. Acceptable — the frame already exceeded 16ms.
- Aggregation of 1000 samples into top-5: <1ms (single pass with counter map).
- `CpuAttribution` list: max 5 entries. Fixed memory.
- 500ms timeout prevents slow RPC from blocking verdict delivery.

**Degradation:**

- No VM connection: `topFunctions` is null. Verdict shows phase timing only (existing behavior).
- `getCpuSamples()` returns empty (known in some debug configs — dart-lang/sdk#42591): `topFunctions` is null. No error surfaced.
- Timeout exceeded: `topFunctions` is null. Verdict delivered on time without attribution.
- Debug mode: call stacks may include interpreter frames not representative of real cost. Fix hint notes this: "Run in profile mode for representative CPU attribution."
- Profile mode: meaningful call stacks with inlined functions properly attributed.

**Acceptance criteria:**

- Jank frames in full/correlated mode include top-5 function names when CPU samples available.
- Functions sorted by exclusive tick percentage.
- Verdict detail string includes attribution (e.g. "Top functions: MyWidget.build (40%), jsonDecode (25%)").
- Framework internals filtered unless they dominate samples.
- Empty/unavailable samples produce null topFunctions (graceful, no error).
- CPU attribution appears in JSON session export.
- 500ms timeout prevents blocking.

**Testing:**

- Synthetic `CpuSamples` aggregation: top-N sorting, percentage calculation, deduplication
- Framework function filtering: verify `dart:core`, `package:flutter` filtered when <50%
- Empty samples: null topFunctions, no error
- Timeout: mock slow RPC → null topFunctions, verdict still produced
- Serialization: `CpuAttribution.toJson()` round-trip
- Integration: jank frame + mock getCpuSamples → verify verdict includes attribution
- Benchmark: aggregation of 1000 samples < 5ms

**Implementation notes (deviations from spec):**

1. **`getCpuSamples()` on VmServiceClient, not controller.** The spec suggested the controller could call the VM service directly. Instead, `getCpuSamples()` is a public method on `VmServiceClient`, following the existing pattern where the controller accesses VM features through the client (same as `onHeapSample` callback and `_resolveMainIsolateId`). This keeps VM error handling (SentinelException, reconnection) encapsulated.

2. **`CpuSampleAggregator` is a pure const class.** Takes `CpuSamples` (vm_service type) and returns `List<CpuAttribution>`. No async, no state, no VM dependency. Easily testable with synthetic `CpuSamples` data.

3. **`JankCaptureBuffer.updateVerdict()` added.** Since `CaptureEntry` is immutable (`const` constructor), updating the verdict for async CPU attribution requires replacing the entire entry. The method searches by `frameNumber` and creates a new `CaptureEntry`.

4. **Dashboard display uses Column widget.** Replaced bare `Text(verdict.reason)` with a `Column` containing the reason text + a blue "Top: ..." line showing CPU attribution. The top functions line only appears when `topFunctions` is non-null and non-empty.

5. **No IssueCard changes.** The spec mentioned "IssueCard shows top functions in expanded verdict view" but `IssueCard` displays `PerformanceIssue` objects, not `FrameVerdict`. CPU attribution is displayed in the dashboard's verdict section instead.

6. **`FrameVerdict.withTopFunctions()` instead of full `copyWith`.** Focused copy method since only `topFunctions` changes in the two-phase flow. Avoids a 16-parameter copyWith.

7. **vmTag blocklist filtering.** Excludes samples with vmTag in `{GC, CompileOptimized, CompileUnoptimized, Native, Idle, VM}`. Samples with null or empty vmTag are kept.

---

### v2.4: Source Location Enrichment — **Done**

**Problem:**

Issue cards show ancestor chains like "Widget: MyApp > HomePage > ExpensiveList" but no file:line reference. The developer must search the codebase to find the widget.

**Correction to expansion #6:**

The original expansion #6 concluded "File:line source locations are fundamentally unavailable at runtime." This was incorrect. `WidgetInspectorService.getCreationLocation(Object?)` is a public static method returning `Map<String, Object>?` with keys `file` (String), `line` (int), `column` (int), and optionally `name` (String). It works when `isWidgetCreationTracked()` returns true, which is the default in debug mode with `--track-widget-creation` (the default for `flutter run`).

This is the same API that DevTools uses for its widget inspector "jump to source" feature.

**API verification requirement:** Verify `getCreationLocation` method signature and accessibility against the package's minimum Flutter SDK (`>=3.24.0`) before implementing. The method may be static or instance-scoped (accessed via `WidgetInspectorService.instance`). If the method is unavailable or has a different signature in `3.24.0`, adjust the implementation or bump the minimum SDK constraint. Do not add runtime capability checks — resolve via declared SDK range, matching the pattern from the debug instrumentation milestone.

**Approach:**

During tree scans, when building ancestor chains for structural issues, call `WidgetInspectorService.getCreationLocation(element.widget)` on the leaf (most specific) widget to enrich the chain with file:line. Cache lookups by widget runtime type to avoid repeated calls.

**Design decisions:**

1. **Debug-only enrichment.** `isWidgetCreationTracked()` returns false in profile mode and when `--no-track-widget-creation` is passed. Source locations are only available in debug mode. This is acceptable — debug mode is when developers actively investigate specific widgets.

2. **Enrich existing `ancestorChain`, don't add a new field.** Change format from:
   - `"MyApp > HomePage > ExpensiveList"`
   to:
   - `"MyApp > HomePage > ExpensiveList (lib/screens/home.dart:47)"`

   The file:line refers to the leaf widget in the chain — the one closest to the issue.

3. **Cache per widget type.** Source location doesn't change across rebuilds for the same widget class. Cache by `widget.runtimeType.toString()` to avoid repeated `getCreationLocation()` calls. Cache bounded by `maxTrackedTypes` (default 200). **Known limitation:** The same widget class instantiated from multiple source files (e.g., `Container` used in `home.dart:47` and `settings.dart:23`) stores only the first-encountered location. This is accurate for user-defined widgets (typically defined once) but approximate for framework widgets. Acceptable for v2 — user widgets are the primary target.

4. **Abbreviated paths.** Strip everything before `lib/` in file paths for brevity. `"/Users/dev/myapp/lib/screens/home.dart"` → `"lib/screens/home.dart"`. If `lib/` not found, show the last 2 path segments.

5. **Null-safe.** `getCreationLocation()` returns null when tracking is unavailable or for framework-internal widgets. Ancestor chain is unchanged when file:line is unavailable.

**Files:**

| File | Action |
|------|--------|
| `lib/src/utils/source_location_cache.dart` | **Create** — bounded LRU cache of `typeName → "file:line"` |
| `lib/src/utils/widget_location.dart` | **Edit** — add `getSourceLocation(Element)` helper that calls `WidgetInspectorService.getCreationLocation`, caches, and abbreviates path |
| Structural detectors that populate `ancestorChain` (listview, nested_scroll, setstate_scope, shallow_rebuild_risk) | **Edit** — append file:line to chain when available |
| Debug callback detectors (rebuild, repaint) that populate `ancestorChain` via `DebugSnapshot.ancestorChains` | **Edit** — enrich chains in `DebugInstrumentationCoordinator` during chain capture |
| `test/utils/source_location_cache_test.dart` | **Create** |
| `test/utils/widget_location_test.dart` | **Edit** — add source location tests |

**Performance constraints:**

- `getCreationLocation()`: ~1-5µs per call (creates a small Map). Cached after first lookup per type.
- Cache: max 200 entries × ~80 bytes each = ~16KB. Negligible.
- Only called during tree scan (1x/sec), not per frame. Max calls per scan: bounded by tree depth × issue count, practically <20.

**Degradation:**

- Profile mode: `isWidgetCreationTracked()` returns false → no file:line, ancestor chain format unchanged.
- `getCreationLocation()` returns null for a widget: ancestor chain format unchanged for that widget.
- `--no-track-widget-creation` flag: all lookups return null, zero overhead beyond the initial check.

**Acceptance criteria:**

- In debug mode, ancestor chains on structural and debug-backed issues include file:line for the leaf widget.
- File paths abbreviated to `lib/...` form.
- Lookups cached per widget type, bounded by `maxTrackedTypes`.
- No behavior change in profile mode.
- Source locations included in JSON session export `ancestorChain` field.

**Testing:**

- Source location cache: bounded at capacity, LRU eviction, cache hit returns same value
- Path abbreviation: full path → `lib/` prefix, no `lib/` in path → last 2 segments, edge cases (root path, empty path)
- Null handling: `getCreationLocation` returns null → chain unchanged
- Integration with existing ancestor chain tests: verify chain format with and without file:line

**Implementation notes (deviations from spec):**

1. **API path:** `WidgetInspectorService.getCreationLocation(Object?)` does not exist as a public method. Both `_getCreationLocation` and `_Location` are private to `widget_inspector.dart`. Used `InspectorSerializationDelegate.additionalNodeProperties(DiagnosticsNode)` instead — a public method on a public class that includes `creationLocation` in its output map. Same underlying data, different access path.

2. **No detector edits needed:** Instead of editing 4 structural detectors + DebugInstrumentationCoordinator individually, modified `buildAncestorChain()` directly to append file:line. All 14+ consumers get enrichment automatically with zero individual edits.

3. **No LRU eviction:** Cache uses simple bounded map (insert until full, then skip new types). True LRU is unnecessary — source locations are stable per widget type and 200 entries covers virtually all user-defined types.

4. **Module-level cache:** `sourceLocationCache` is a module-level `SourceLocationCache` instance in `widget_location.dart`. Simpler than threading a cache instance through all detector constructors. `clear()` method available for test isolation.

5. **24 new tests** (10 cache unit + 7 path abbreviation + 7 widget location integration), 757 total pass.

6. **Expanded framework widget filter:** Added 17 framework widgets to `_frameworkNames` in `widget_location.dart`: transition/animation widgets (8: `SlideTransition`, `FadeTransition`, `ScaleTransition`, `RotationTransition`, `SizeTransition`, `FractionalTranslation`, `PositionedTransition`, `DecoratedBoxTransition`), builder plumbing (3: `Builder`, `ListenableBuilder`, `NotificationListener`), pointer infrastructure (2: `IgnorePointer`, `AbsorbPointer`), and render infrastructure (4: `RepaintBoundary`, `Offstage`, `TickerMode`, `KeyedSubtree`). These produced long chains that pushed the file:line suffix off-screen in issue cards.

7. **Issue card deduplication:** Added `!issue.detail.contains(issue.ancestorChain!)` guard to the "Widget:" line in `issue_card.dart`. When the detail text already contains the ancestor chain (common for structural detectors), the redundant "Widget:" line is suppressed.

---

### v2 Config Changes Summary

New fields on `SleuthConfig`:

| Field | Type | Default | Feature |
|-------|------|---------|---------|
| `enableNetworkMonitoring` | `bool` | `true` | v2.1 |
| `slowRequestThresholdMs` | `int` | `2000` | v2.1 |
| `requestFrequencyLimit` | `int` | `30` | v2.1 |
| `largeResponseThresholdBytes` | `int` | `1048576` | v2.1 |
| `networkExcludePatterns` | `List<String>?` | `null` | v2.1 |

No new config for v2.2–v2.4:
- Heap trend uses existing VM polling infrastructure.
- CPU attribution is automatic on jank frames when VM connected.
- Source location is automatic in debug mode.

### v2 Breaking Changes

Target version: **0.3.0** (enum additions are breaking for exhaustive switches; semver for 0.x packages treats minor bumps as breaking).

- `DetectorType` enum gains `networkMonitor` — exhaustive switch breakage.
- `IssueCategory` enum gains `network` — exhaustive switch breakage.
- `FrameVerdict` gains `topFunctions` field — non-breaking (nullable, has default).

### v2 Detector Count

After v2: **21 detectors** (1 runtime + 1 network + 5 vmOnly + 3 hybrid + 11 structural).

### v2 Updated Positioning

After implementation, the "What DevTools Still Does Better" README section narrows to:

- **Heap snapshots & object graph**: DevTools can browse every object in the heap, inspect retention paths, and track individual allocations. Sleuth monitors heap trends and GC pressure but cannot drill into specific objects.
- **Full flame chart & call tree**: DevTools provides zoomable, interactive per-frame timelines with complete call tree visualization. Sleuth shows phase breakdowns with top-5 function attribution per jank frame.

The following are **no longer DevTools-only advantages**:
- ~~Network inspection~~ → Sleuth monitors HTTP timing, frequency, and response size automatically.
- ~~Memory inspection~~ → Sleuth tracks heap usage trends and capacity thresholds.
- ~~CPU profiling~~ → Sleuth attributes jank frames to top functions by CPU sample analysis.
- ~~Widget-exact attribution~~ → Sleuth provides source file:line in debug mode via `getCreationLocation`.

### v2 Implementation Order

**Planned order** (optimized for value delivery and dependency graph):

1. **v2.1 Network Monitoring** — highest value, no VM dependency, most user-visible improvement
2. **v2.4 Source Location** — quick win, low effort, immediate developer value in debug mode
3. **v2.2 Heap Trend** — enhances existing detector, moderate effort, strong signal
4. **v2.3 Jank CPU Attribution** — highest complexity, requires careful VM integration and filtering

**Actual order:** v2.1 → v2.2 → v2.3 → v2.4. Source location (v2.4) was implemented last instead of second. The features are fully independent, so the order change had no impact on implementation quality. The shift was pragmatic — v2.2 and v2.3 both touch `VmServiceClient` and the controller verdict pipeline, so implementing them back-to-back avoided context-switching between VM-based and non-VM work.

Each feature ships with: tests, example demo update, CHANGELOG entry, README update, and detector matrix update.

---

