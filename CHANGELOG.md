## 0.32.0

MCP support shipped — seven `ext.sleuth.*` VM service extensions in the
main package plus a standalone `sleuth_mcp` sidecar package
(`packages/sleuth_mcp/` v0.1.0) bridging them to MCP stdio JSON-RPC
clients (Claude Code, Cursor, Zed). Debug/profile only; `kReleaseMode`
is a no-op. Full plan: [`doc/spec_mcp.md`](doc/spec_mcp.md).

- Seven extensions: `snapshot`, `issues`, `routeHealth`, `explain`,
  `encyclopedia`, `causalGraph`, `diagnose`. Every response stamps
  `connectionMode` (`correlated` / `full` / `basic` / `warmup` /
  `disconnected`), `schemaVersion: 1`, and a per-controller-construction
  `sessionUuid` so consumers can distinguish "no issues observed" from
  "we couldn't talk to the VM" or "warmup not elapsed".
- `ConnectionMode` returns `warmup` until `frameTimingWarmupDuration`
  elapses, regardless of VM-connection state.
- `ServiceExtensionRegistry` is a process-wide singleton with per-name
  binding tracking — `dart:developer.registerExtension` is called at
  most once per name per isolate, surviving hot-restart and serial test
  setUp/tearDown. `unboundNames` is surfaced via `ext.sleuth.diagnose`
  so an MCP sidecar can warn when the live surface is degraded.
- New public surface: `CausalGraphRule.rulesJson`,
  `SleuthController.sessionUuid`, `SleuthController.initializedAt`,
  `ConnectionMode`, `ServiceExtensionRegistry` (opt-in barrel export).
- `envelopeError` strips reserved keys (`connectionMode`,
  `schemaVersion`, `sessionUuid`, `error`, `stack`) from caller-supplied
  `extra` so trust fields cannot be overwritten.
- Sanitiser: identity-based cycle detection, 256-depth cap, `Iterable`
  branch, `__keyCollision` / `__cycle` / `__truncated` /
  `__nonSerializable` envelopes; non-encodable leaves wrap as typed
  envelopes instead of crashing.
- Sleuth reserves the `ext.sleuth.*` extension namespace.

### sleuth_mcp v0.1.0 (new sidecar package)

Companion Dart CLI at `packages/sleuth_mcp/`. Two binaries: `sleuth_mcp`
(long-running MCP stdio JSON-RPC server) and `sleuth_check` (one-shot
CI gate). Discovery is `--uri` only — sleuth targets ios + android, so
the app process and sidecar do not share a filesystem; the user copies
the VM service URI from `flutter run`'s output. Eight MCP tools each
with `inputSchema`: `connect`, `get_snapshot`, `get_issues`,
`get_route_health`, `explain_issue`, `compare_snapshots`,
`check_budgets`, `diagnose`. Two MCP resources cached by `sessionUuid`:
`sleuth://encyclopedia`, `sleuth://causal-graph`. Hot-restart of the
target app surfaces inline as a `session_changed` error envelope from
the next tool call — no idle polling.

## 0.30.1

pub.dev README polish — no detector or distribution change.

- `doc/logo.png` now ships in the published archive (`.pubignore` whitelist) so the README hero image renders on pub.dev instead of falling back to the alt text.
- Tests-passing badge refreshed to the current count (3,001).

## 0.30.0

`TrackedResourceDetector.tracked_resource_long_lived.warning` raised to runtimeVerified via `additionalBrackets[0]`. Distribution: 15/20 effective runtimeVerified family-severity pairs across 12 unique stableIds.

- Long-lived bracket: threshold 300 (matches default `longLivedSeconds`), unit `seconds`, atTolerance 0.5 (at-band [300, 450]), aboveCeilingMultiplier 3.0 (ceiling 900). `observedAxisArgKey: 'oldestInstanceAgeSeconds'`, `requireUniqueDetectedAtMicros: true`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures with real-time waits past the 300 s production threshold.
- Detector behaviour change: `_evaluateLongLived` overwrites `longLivedFirstCrossMicros = nowMicros` each sweep (was `??=` first-cross-only). A long-lived overshoot now produces an emission per sweep with monotonically-increasing age — captures get a real ascending-age series (`observedAxisReduction: 'max'` picks the leg-end value), and a lingering leak re-flags every sweep with the current elapsed retention. UI cards unchanged (same stableId, age refreshes).
- `captureTraceStableId: longLivedStableId` re-added to `_evaluateLongLived` so parametric `tracked_resource_long_lived:<name>` emissions route through the bare family for the bracket validator's byte-exact filter.
- New public API: `lastObservedAgeSecondsFor(name)` / `peakObservedAgeSecondsFor(name)` per-name age observables. `_sweep()` records each pass; `untrackAll(name)` drops entries; `resetCaptureState()` clears them.
- Capture screen long-lived legs: register 1 ref + real-time wait (250 / 380 / 600 s for below / at / above) at the production threshold. `dispose()` clears per-name override defensively via `Sleuth.setResourceThreshold(_kResourceName)` (both null = remove).

## 0.29.1

`IssueEncyclopediaPage` "Learn more" navigation now resolves to the correct entry for parametric stableIds (`tracked_resource_concurrent:<name>`, `excessive_keep_alive:<i>`, `excessive_global_keys:<i>`) and dynamic-suffix stableIds (`repaint_debug_<typeName>`, `rebuild_debug_<typeName>`). Previously the page used byte-exact `scrollToStableId` against `IssueExplanationBuilder.allExplanations` (bare-family keys), so parametric/dynamic variants never expanded or scrolled the target entry.

- New public `IssueExplanationBuilder.canonicalId(String)` — strips parametric `:<param>` and dynamic widget-type suffixes, mapping a `PerformanceIssue.stableId` to the encyclopedia key.
- `IssueEncyclopediaPage._scrollTargetKey` getter resolves `widget.scrollToStableId` through `canonicalId`; `initState` `containsKey` check, `_scrollToTarget`, and per-row `isScrollTarget` comparison all use the normalized key.

## 0.29.0

`TrackedResourceDetector.tracked_resource_concurrent.warning` raised to runtimeVerified via `perStableIdTier`. Distribution: 14/20 effective runtimeVerified family-severity pairs across 11 unique stableIds.

- Bracket: threshold 6 (smallest count > default `maxConcurrent` 5 that triggers emission), unit `instances`, atTolerance 0.5 (at-band [6, 9]), aboveCeilingMultiplier 3.0 (ceiling 18). `observedAxisArgKey: 'liveInstanceCount'`, `requireUniqueDetectedAtMicros: true`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures.
- New `PerformanceIssue.captureTraceStableId` optional field. When set, `CaptureHelper.composeIssueEvent` uses it (instead of `stableId`) to compose the `sleuth.issue.<id>.<severity>` trace-event name. Parametric stableId detectors (`tracked_resource_concurrent:<name>`) route the trace event through the bare family so the bracket validator's byte-exact filter matches every member. UI cards still key on the parametric `stableId`; equality + hashCode unchanged.
- Detector capture plumbing: `flushConcurrentEvaluation()` (synchronous sweep, bypasses the 10 s sweep-timer); `untrackAll(name)` (drop bucket + detach Finalizers — leg isolation for capture screens); `resetCaptureState()` (clears per-name observables + every bucket's `concurrentFirstCrossMicros` / `longLivedFirstCrossMicros`, propagated from `SleuthController.resetCaptureState`); per-name getters `lastObservedLiveCountFor(name)` / `peakObservedLiveCountFor(name)` plus aggregate `lastObservedLiveCount` / `peakObservedLiveCount` for back-compat. Capture screens MUST use the per-name getter — the aggregate would track an unrelated bucket if another `Sleuth.trackResource(...)` registration is active.
- `tracked_resource_long_lived` family stays reproducerOnly — 300 s threshold exceeds an on-device scenario window. `_evaluateLongLived` does NOT set `captureTraceStableId`, so its emissions never land as bare-family `sleuth.issue.tracked_resource_long_lived.warning` events in capture mode (which would be unclaimed evidence: no bracket, no `coveredThresholds` entry).
- New `example/lib/demos/tracked_resource_capture_screen.dart`. Per-leg flow: `untrackAll` + clear strong-refs → `suspendNonEssentialTimelineStreams` → `markScenarioBegin` → synchronous allocate + register → `flushConcurrentEvaluation` → 3 × 32 ms frame yields → `flushTimelineNow` → read `peakObservedLiveCountFor(name)` → `markScenarioEnd` → 600 ms drain → `exportCaptureJson`.

## 0.28.0

New `Sleuth.setResourceThreshold(name, {int? maxConcurrent, int? longLivedSeconds})` per-name threshold override for `TrackedResourceDetector`. `trackResource` / `untrackResource` API unchanged.

- **Merge semantics**: omitted or invalid axis preserves the prior value for that axis. Explicit both-null clears the override. Subsequent calls update one axis without losing the other.
- Override is bucket-independent — survives empty-bucket sweep eviction, LRU bucket drops, and `isEnabled = false` toggle. `dispose()` clears.
- Per-axis validation: invalid values (`<= 0`) drop that axis (counted via `droppedOverridesCount`). Cap at 1000 distinct names — new-name overflow silently drops; updates to existing names always succeed. Runtime guard (release-safe).
- Issue `extraTraceArgs` always stamps `effectiveMaxConcurrent` / `effectiveLongLivedSeconds` + `thresholdSource` (`'override'` or `'global'`).
- Pre-init calls (before `Sleuth.init`) drop with a once-per-session debug warning.
- Cross-isolate / `kReleaseMode` no-op (matches `trackResource` shape).

## 0.27.0

New `TrackedResourceDetector` (runtime, opt-in) + public `Sleuth.trackResource` / `Sleuth.untrackResource` API. 19 → 20 detectors.

- `Sleuth.trackResource(name, resource)` registers; tracker keeps `WeakReference` + Finalizer token + first-seen timestamp per registration. Token is the registration identity (allocation-unique, collision-resistant); shared `Finalizer` dispatches release on GC reclaim. `Sleuth.untrackResource(name, resource)` is the optional explicit decrement.
- Two emission paths, both `confirmed`:
  - `tracked_resource_concurrent.warning` — live count under one name > `trackedResourceMaxConcurrent` (default 5).
  - `tracked_resource_long_lived.warning` — single instance alive past `trackedResourceLongLivedSeconds` (default 300 s).
- LRU cap (`trackedResourceMaxDistinctNames`, default 1000) bounds the in-memory bucket map; eviction detaches per-ref Finalizer entries so VM-side state stays bounded. Periodic sweep (`trackedResourceSweepIntervalSeconds`, default 10 s) drives evaluation.
- Pure Dart — no VM service dependency. Cross-isolate registration is a no-op (one controller per isolate).
- Primitive / record targets silently dropped via `droppedTargetsCount`.
- New `CausalGraphRule` edges `tracked_resource_concurrent → heap_growing` and `tracked_resource_long_lived → heap_growing`.
- Tier `reproducerOnly`.

## 0.26.0

`stream_resource_growth.warning` raised to runtimeVerified; `gc_pressure` default 30 → 60/min.

- `StreamResourceDetector`: `stream_resource_growth.warning` → runtimeVerified via `perStableIdTier`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures bracket threshold 50 (unit `instances`) on `topGrowthDelta` axis; atTolerance 0.6, aboveCeilingMultiplier 3.0.
- BREAKING-ISH: magnitude gate switched from summed `netDelta` to dominant-class `top.delta` so the firing axis matches the bracketed axis. Multi-class growth (≥2 watchlist classes ascending) stays as a structural precondition. A balanced 25+25 multi-class workload no longer fires; a single 60-instance leak with any other grower still does.
- `MemoryPressureDetector.gcRateThresholdPerMin` default 30 → 60. Dart's `EventStreams.kGC` emits per young-gen scavenge; ~30/min is steady-state for a moderately allocating UI. Pre-v0.26.0 sensitivity available via `SleuthConfig(gcRateThresholdPerMin: 30)`.
- `StreamResourceCaptureScreen`: 1024 KB/sec byte pressure (256 KB × 4 Hz, 1024-entry rotating cap) reliably re-arms heap_growing inside scenario. Heap-growing readiness wait moved INSIDE scenario span (`markScenarioBegin → resetCaptureState` wipes the prior latch). Direct `flushStreamResourceEvaluation()` dropped — emissions route through `pollStreamResourceAllocationProfileNowWithCapture`. JSON post-process aligns `expectedMagnitude.observed` to detector-stamped `topGrowthDelta`.
- `'instances'` added to `ProfileCaptureSchema.approvedUnits`.

## 0.25.0 (BREAKING)

Multi-parent causal UI + removal of deprecated `rootCauseId` singular field.

**BREAKING** — `PerformanceIssue.rootCauseId` (deprecated since v0.24.2) and `effectiveRootCauseIds` getter removed. JSON `rootCauseId` key no longer read or emitted. Migration:
- `PerformanceIssue(rootCauseId: 'x')` → `rootCauseIds: ['x']` (also covers `copyWith`).
- `issue.rootCauseId` getter → `issue.rootCauseIds?.firstOrNull`.
- v0.24.x-or-earlier snapshots carrying only the singular key must re-export through v0.24.2 (singular → plural coercion) before importing on v0.25.0+. Debug builds emit a warning when fromJson sees the legacy key without the plural.

UI:
- `IssueCard.parentIssues` + `_causedBySection` widget (mirrors `_downstreamSection`; cap at 5 + "and N more"; "(+N suppressed)" annotation when resolved parents < `rootCauseIds.length`).
- `computeVisibleIssues`: ≥2 parents always visible (multi-parent badge); 1 parent collapses under visible parent or surfaces as orphan; 0 parents visible.
- `FloatingIssuesCard`: resolves `parentIssues` via `stableIdToIssue` map; counts unresolved parents.
- `AiContextBuilder` reads `rootCauseIds` directly.

Contract:
- `rootCauseIds` documented invariant: null or non-empty. `fromJson` coerces empty/all-non-string lists to null.
- `_resortRootCauseIdsByCurrentSeverity` keeps `rootCauseIds[0]` highest-severity post-escalation so the "Caused by" badge and AI-prompt cap-at-5 truncation stay accurate.

Tests: +9 (5 `_causedBySection` render + 4 fromJson normalization). Visibility-filter triad updated. ~10 sites migrated singular→plural; singular-only regression tests removed (now compile errors).

## 0.24.2

Multi-parent causal-graph annotation (metadata layer). `CausalGraphRule.apply` now claims every reaching root for each downstream effect, removing the v0.24.1 export-vs-UI asymmetry at the data model layer. Top-level UI rendering of multi-parent badges is deferred to v0.25.0+ — the visibility filter still collapses each downstream under any visible reaching root.

- `PerformanceIssue.rootCauseIds: List<String>?` (plural) joins the schema; singular `rootCauseId` is `@Deprecated` and removed in v0.25.0. Constructor accepts both for back-compat. `fromJson` reads `rootCauseIds` if present, falls back to a singleton-list coercion of `rootCauseId` for v0.24.1-and-earlier snapshots. `toJson` derives singular from `rootCauseIds.first` (post-v0.24.2 canonical) so v0.24.1 readers see the highest-severity root after re-export — eliminates singular/plural drift.
- `CausalGraphRule.apply()`: `downstreamOwners` is now `Map<int, Set<int>>` (multi-parent) instead of `Map<int, int>` (single-owner). BFS from each root accumulates every reach. Each downstream issue carries every reaching root, sorted severity desc then stableId asc. Confidence suppression skips the root's `downstreamIds` listing for a `possible` downstream when any reaching root is `confirmed` or `likely`. Intermediate nodes in multi-hop chains are not surfaced as parents — only originating roots are (matches BFS-from-roots model; surfacing intermediates ships in v0.25.0+).
- `FloatingIssuesCard`: precomputed `stableIdToIssue` map (O(1) downstream lookup, drops itemBuilder cost from O(n²) to O(n)). `computeVisibleIssues` filter extended for multi-parent semantics: a downstream is hidden from top-level when any reaching root is visible; surfaces standalone only when every parent is suppressed.
- `AiContextBuilder`: prompt section uses singular "Root cause issue" / plural "Root cause issues" label depending on `rootCauseIds.length`; caps the joined list at 5 with `(+N more)` suffix.
- Tests: +5 (multi-parent 3×3 fan-in pin, rule-ordering invariant under input-shuffle, multi-parent confidence suppression, full-pipeline integration via correlator, multi-parent visibility-filter triad). ~70 existing assertions migrated from `.rootCauseId` → `.rootCauseIds`.

## 0.24.1

Cross-detector polish for `stream_resource_growth`.

- `CausalGraphRule`: 3 new edges so retained-stream emissions surface as causes of co-firing memory issues. `stream_resource_growth → heap_growing`, `stream_resource_growth → heap_near_capacity`, `stream_resource_growth → gc_pressure`. Mirrors the `uncached_images` and `excessive_keep_alive:*` patterns.
- Edge enumeration is asymmetric across consumers: `CausalGraphRule.activeEdges` (Markdown export, session summaries) returns every distinct cause→effect pair, so a 3-cause × 3-effect memory co-fire surfaces all 9 edges. `CausalGraphRule.apply` (UI annotation) remains single-owner — each downstream gets one `rootCauseId` chosen by severity-then-index, and losing roots render as standalone cards. Multi-parent UI rendering is deferred to a future cut.
- Schema regression guard: `ProfileCaptureSchema.parseFile` round-trip test for the 4 detector-side `extraTraceArgs` keys (`topGrowthClass`, `topGrowthDelta`, `watchlistClassesGrowing`, `samplesInWindow`) so a future schema tightening with a key allowlist cannot silently disable the detector's trace args.
- Tests: +6 (4 `activeEdges` edge tests + 1 negative control, 1 `apply()` single-owner pin for the 3-cause memory fan-in, 1 schema round-trip).

## 0.24.0

New `StreamResourceDetector` (vmOnly) flags likely retained async resources via `getAllocationProfile` class-instance diff, gated on a recent `MemoryPressureDetector.heap_growing` emission. 18 → 19 detectors.

- `StreamResourceDetector`: polls allocation profile at most once per `streamResourceSampleSeconds` (default 10s); tracks `instancesCurrent` for a hardcoded watchlist of dart:async / dart:io / web_socket_channel suffixes (`StreamSubscription`, `_BroadcastSubscription`, `_ControllerSubscription`, `StreamController`, `_SyncBroadcastStreamController`, `_AsyncBroadcastStreamController`, `_WebSocketImpl`, `WebSocketChannel`) plus rxdart `PublishSubject` / `BehaviorSubject` / `ReplaySubject` when `classRef.library.uri` contains rxdart. Emits `stream_resource_growth.warning` only when (a) `MemoryPressureDetector.isHeapGrowingActive` returns true within the recency window (default 30s), (b) ≥2 watchlist classes show ≥3 of 3 ascending transitions across a K=4 sample window, (c) sum of per-class net deltas exceeds `streamResourceMinDelta` (default 50). Confidence `likely`. Tier `reproducerOnly`.
- Suffix-match (`endsWith`) shields against private-class renames across Flutter SDK versions. 20s warmup window suppresses cold-start subscription accumulation; window/warmup re-engage on `pause()` / `resume()` / `resetCaptureState()`. Re-entrancy guard (`_pollInFlight`) + 3-failure backoff (60s default). 3-cycle cooldown holds `dedupIdentityMicros` stable so the controller dedup composite key collapses successive fires to one trace record.
- `MemoryPressureDetector`: new public `bool isHeapGrowingActive([int? windowMicros])` getter backed by `_lastHeapGrowingEmittedAtMicros` stamp. Decoupled from `_issues.any(...)` retention so a long-resolved heap_growing cannot latch downstream gating. Cleared on `vmConnected=false` / `reset()` / `dispose()`.
- `Sleuth.streamResourceDetector` static accessor (kReleaseMode-guarded). `StreamResourceDetector` exported from the public barrel.
- 5 new `DetectorThresholds` fields: `streamResourceSampleSeconds`, `streamResourceMinDelta`, `streamResourceWarmupSeconds`, `streamResourceHeapGrowingRecencyMicros`, `streamResourcePollFailureBackoffSeconds`.
- New `FixHintBuilder.streamResourceGrowth` cross-references `heap_growing` / `native_memory_growing` as alternative memory-pressure causes.
- IssueEncyclopediaPage entry for `stream_resource_growth` in `issue_explanation_builder.dart`.
- Library-URI gate on core watchlist: `endsWith` matches only fire when `classRef.library.uri` is `dart:async`, `package:web_socket_channel`, or (for WebSocket only) `dart:io`. dart:io's `_HttpClientStreamSubscription` is explicitly excluded — it self-cancels on response completion and would otherwise produce false positives on every network-heavy app.
- Cooldown semantics: wall-clock deadline (`cooldownSeconds`, default 30 s) — survives VmService disconnect mid-cooldown without leaving a stale issue pinned to `_issues` until the next non-null poll arrives. Re-emit during cooldown refreshes `detectedAt` (so UI does not show a stale stamp) while preserving `dedupIdentityMicros` for controller composite-key dedup.
- Reset-generation guard: in-flight `_pollAllocationProfile` snapshots `_resetGeneration` at start; if `_clearRetainedState` runs between the `await` and the result handler, the result is discarded. Without this, leg-N-1 sample data could write into leg-N's freshly-cleared `_perClassWindow` and break capture-mode scenario isolation.
- `windowSize` constructor assertion: `assert(windowSize >= 2)` rules out the empty-list `RangeError` path in `_evaluateWindow` if a future caller passes 0 or 1.
- `_ingestProfile` per-poll aggregation: sums `instancesCurrent` across every class that maps to the same suffix bucket and appends exactly one sample per suffix per poll. For suffixes previously seen but absent from the current poll (the leak was fixed and GC reclaimed every instance), appends `0` so a stale ascending window ages out instead of re-firing every cooldown cycle. All-zero windows are dropped to bound map growth.
- `_matchWatchlist` longest-suffix-match: a class named `_SyncBroadcastStreamController` matches the specific suffix instead of being shadowed by the generic `StreamController` bucket. First-match would also collapse multiple distinct controller flavors into one window, corrupting the ascending-transitions check.
- `_dropEmissionState` helper consolidates clears across cooldown lapse + transient gate failure + window underflow paths, eliminating drift between code paths that previously cleared a subset of emission fields.
- `@visibleForTesting` annotation on `allocationProfileFetcherForTest` constructor parameter so production callers cannot inject a custom fetcher.
- Tests: +17 unit (warmup, sample-rate gate, single-class-no-emit, heap_growing-off-no-emit, sub-threshold-no-emit, co-fire emission, extraTraceArgs key set, cooldown stable identity within window, cooldown detectedAt refresh, wall-clock cooldown expiry, non-monotone-no-emit, null-fetcher backoff, rxdart library-URI gate × 2, `_HttpClientStreamSubscription` exclusion, resetCaptureState, disabled, vmConnected-false). +5 reproducer (deliberate-leak harness, heap_growing-off, flat-no-emit, rxdart, cooldown).

## 0.23.0

`GpuPressureDetector.raster_dominance` idle false-positive fixed; `HeavyComputeDetector` issues persist past one VM batch.

- `GpuPressureDetector`: ratio numerator uses MAX-of-frame raster gated by `maxFrameRasterFloorUs` (default 8000us). New ctor param tunable for 120Hz / Impeller / low-power-mode.
- `RenderPipelineAnalyzer`: raster admitted as `suspectedPhase` only when one frame crosses 8000us.
- `HeavyComputeDetector`: emissions persist `emissionPersistence` (default 10s) via monotonic `Stopwatch` — survives VM poll cadence + system clock jumps. Retained state clears on `isEnabled=false` / `vmConnected=false`.
- `PerformanceIssue.sourceRoute`: detectors that retain issues stamp the route at emission. Aggregator prefers `sourceRoute` over live route, so post-emission navigation cannot reattribute. Wired through `HeavyComputeDetector` + `PlatformChannelDetector` via `sourceRouteProvider`.
- CSV Import demo row choices `[50K, 200K, 500K]` + post-parse sort. 500K cap avoids OOM / iOS watchdog.
- Tests: +5 gpu_pressure (idle-suppression, floor-triad, spike+idle, 12ms critical); +7 persistence (heavy_compute Stopwatch TTL × 3, lifecycle clear × 2, route-during-TTL × 2; platform_channel route-during-cooldown × 2).
- Doc cleanup: 21 historical spec files + `HANDOFF.md` removed; example/README aligned with 18-detector + 500K demo cap; README logo path switched to relative (`doc/logo.png`) for pub.dev rendering against private repo. Added Fastlane `TRACK_WIDGET_CREATION` patch tip for iOS profile archives. README accuracy fixes: Repaint detector moved from VM-Only to Hybrid section (matches `DetectorLifecycle.hybrid`); `heavyComputeGapMs` config example corrected to 8 (was drift-stamped 200). Pubspec description sharpened — leads with in-app overlay differentiator, drops abstract layer names.
- `doc/validation_ledger.md` Non-Detector Components: dropped stale v0.16.7 promise; framework live, 0 components registered; tier raises deferred to next non-detector formula change (4 candidates listed: `IssueRanker`, `RouteSession.healthScore`, `RecurrenceTrend`, FPS formulas).
- Reference-device matrix slimmed to **iPhone 12 / iOS 17.5 only** (`approvedDevicePairs`). iPhone 13 mini + Pixel 7 removed — never used by real captures (only synthetic fixtures, swapped). Anchor fixture re-pinned (SHA-256 updated). Android coverage gap explicitly documented in `doc/reference_devices.md`. 5 device-mismatch tests skipped pending second approved device pair. `doc/validation_matrix.md` + `doc/capture_procedure.md` + `example/lib/custom_detectors/README.md` swept for stale 23-detector / iPhone 13 mini / Pixel 7 references.

2,883 tests; `fvm flutter analyze` clean.

## 0.22.0

`sustained_jank.critical` runtimeVerified raise withdrawn. Bracket axis (sliding 240-frame-window severeCount) cannot composably bracket against operator-claimed K — ambient severe frames accumulate in the same window. Future raise needs detector-level baseline subtraction (`RebuildDetector.setBaseline(int)` pattern).

- Removed: 3 `sustained_jank` capture JSONs, `frame_timing_sustained_jank_capture_screen.dart`, example-app tile, retainedOrphans manifest entries.
- Reproducer-tier coverage of `sustained_jank` retained in `test/validation/frame_timing_reproducer_test.dart`.
- Distribution unchanged (12 family-severity pairs across 9 stableIds).
- README distribution paragraph + frame_timing_detector source comment refreshed to current state.

## 0.21.0

`RepaintDetector.excessive_repaint.warning` raised to runtimeVerified via `perStableIdTier` on three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures. Base tier stays `reproducerOnly`; `excessive_repaint_debug` and parametric `repaint_debug_<typeName>` are not over-claimed.

- Capture-mode plumbing: `lastObservedPaintCount` + `peakObservedPaintCount` getters, `flushPaintEvaluation()` (refreshes only `lastObservedPaintCount`; never updates peak so the exported magnitude always matches an emitted `observedPaintCount` arg), `resetCaptureState()` (per-leg accumulator clear, also called from `SleuthController.resetCaptureState` for cross-detector parity). VM emission stamps `extraTraceArgs.observedPaintCount` + `dedupIdentityMicros`.
- Bracket: `threshold: 30 paints`, `bracketAtTolerance: 0.50` (at-band [30, 45]), `aboveCeilingMultiplier: 2.0` (above-band ceiling 60 sits strictly under the `> 60` critical-tier fire boundary). Capture screen mounts 32 distinct `CustomPaint` widget classes so the per-widget debug gate stays sub-threshold and emission flows through the VM aggregate path.
- `Sleuth.repaintDetector` static getter (capture-screen access). `Sleuth.lastCaptureExportFailure` surfaces the most-recent `exportCaptureJson` null-return reason in-app.
- 12 effective runtimeVerified family-severity pairs across 9 unique stableIds. Base distribution unchanged (16/18 reproducerOnly, 2/18 runtimeVerified).

2,870 tests passing; `fvm flutter analyze` clean.

## 0.20.2

Example-app polish. No detector logic, public API, or schema change.

- `example/lib/main.dart` tile subtitles trimmed to ≤40 chars so 360 dp phones render single-line without ellipsis. Combined-chat tile keeps `SetState` (drops `Image`) to advertise actual detector coverage.
- `example/lib/demos/heavy_compute_demo.dart` description drops the hard "300 ms" claim → "complete in under a few hundred ms on modern devices" so CPU-throttled devices don't break the promise.
- `example/lib/demos/network_stress_demo.dart` search builds URL via `Uri.parse(...).replace(queryParameters: {'q': query})` — RFC 3986 percent-encoding for special chars (`+`, `&`, `=`, `#`, unicode).

2,862 unit + integration tests passing; `fvm flutter analyze` clean.

## 0.20.1

`FrameTimingDetector` and `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` on each emission. README + dartdoc gain a "Measurement window" note: Sleuth reports frame total duration from `FrameTiming` (build-to-raster span), not vsync delivery cadence.

- New `DetectorThresholds.startupPhaseWindowSeconds` (default 5). Classification reads `Timeline.now` at emission time — emission-time semantics, not event-time. A startup-phase frame whose callback delivery is delayed past the window boundary tags `'steady'`. Differs from `ShaderJankDetector.shaderWarmupContext` (per-event timestamp); the two tags are related but not aligned at the boundary.
- Buffer-aggregated emissions (`sustained_jank` 60-frame, `rebuild_activity` 1-second, raster-cache 30+ frames) tag from emission-time `Timeline.now`. A buffer straddling the boundary tags `'steady'` once `Timeline.now` exceeds the threshold.
- Null `Sleuth.dartEntryMonotonicUs` (init not called) or negative delta omits the key rather than fabricating a value.
- `rebuild_activity` runtimeVerified bracket axis (`observedRebuildRate`) co-exists with the new key. Audit-gate `validateBracket` reads named keys directly; multi-key emissions remain extractable.
- The tag is observable in capture-mode trace records and audit-gate replay; not serialized into saved JSON snapshots.
- Both detectors expose `appStartMonotonicUsForTest` constructor parameter for deterministic tests.

2,862 unit + integration tests passing; `fvm flutter analyze` clean. No detector logic, public API, or schema-version change.

## 0.20.0

**BREAKING**: 5 low-value detectors removed. Distribution: 23 → 18 detectors.

### Removed

- `DetectorType.animatedBuilder` — subset of `rebuild_detector` (AnimatedBuilder misuse manifests as rebuild storms; covered upstream).
- `DetectorType.opacity` — symptom-of-symptom (`Opacity` → `saveLayer` → jank already caught by `frame_timing.jank_detected`).
- `DetectorType.shallowRebuildRisk` — predictive heuristic; real signal caught by `rebuild_detector` from VM-timeline evidence.
- `DetectorType.nestedScroll` — Flutter's own `Vertical viewport was given unbounded height` diagnostic is more authoritative.
- `DetectorType.globalKey` — correctness lint, not perf; framework throws on duplicate `GlobalKey`.

Orphaned config fields removed: `SleuthConfig.maxGlobalKeys`, `DetectorThresholds.shallowRebuildMaxDepth`, `DetectorThresholds.animatedBuilderMinSubtreeSize`.

### Migration

Drop the 5 removed `DetectorType` references from `enabledDetectors`. `rebuild_detector` + `frame_timing` still surface AnimatedBuilder, opacity-jank, and rebuild-storm patterns from runtime evidence.

```dart
// BEFORE (v0.19.x):
SleuthConfig(enabledDetectors: {
  DetectorType.opacity, DetectorType.rebuild, DetectorType.frameTiming,
});

// AFTER (v0.20.0):
SleuthConfig(enabledDetectors: {
  DetectorType.rebuild, DetectorType.frameTiming,
});
```

v0.19 snapshots remain readable in v0.20 — serialization is `stableId`-keyed; encyclopedia + causal-graph rules retain removed-stableId entries for replay context. Users pinned at `^0.19.x` will not auto-upgrade.

### Distribution

16/18 reproducerOnly base + 2/18 runtimeVerified base. 11 effective runtimeVerified family-severity pairs across 8 unique stableIds (unchanged — none of the 5 removed carried raises).

2,851 unit + integration tests passing; `fvm flutter analyze` clean. Benchmark thresholds in `test/benchmark/` are machine-load-sensitive and may flake on slower hardware.


---

Releases prior to v0.20.0 are archived in [`CHANGELOG.archive.md`](https://github.com/Harrys76/sleuth/blob/main/CHANGELOG.archive.md).
