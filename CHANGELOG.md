## 0.37.0

- Scan-root detection works on Flutter 3.47: `IndexedStack` no longer wraps
  inactive children in `Visibility`, so the visible-page walk now descends only
  into the selected child via the element's onstage visitor. Bottom-navigation
  apps on 3.47 previously had every scan aborted.
- Floors: Dart `^3.8.0`, Flutter `>=3.32.0` (previously declared `>=3.24.0`,
  but 3.27+ APIs were already required).
- `vm_service` constraint widened to `>=14.0.0 <16.0.0` so apps on Flutter
  3.32.x can resolve sleuth beside `flutter_test`.
- Overlay keyboard-inset detection reads the hosting `View` instead of the
  first platform view.
- Profile captures may be recorded on Flutter 3.41 or 3.47
  (`ProfileCaptureSchema.approvedFlutterMajorMinors`); the three legs of a
  bracket must still share one exact `flutterVersion`.
  `approvedFlutterMajorMinor` stays `3.41` as the baseline member.
- Encyclopedia, fix-hint, detector-description, guide, and README text now
  match detector behavior (thresholds, Impeller-era shader and repaint
  guidance, profile-mode axis wording, mode table).
- Encyclopedia entries for detectors removed in 0.20.0 are labelled legacy.
- `non_lazy_listview` / `non_lazy_gridview` / `non_lazy_sliver_list` /
  `non_lazy_sliver_grid` resolve to the `non_lazy_list` encyclopedia entry
  (Learn more, AI context, `ext.sleuth.explain`).
- Explanation placeholders (`{routeName}`, `{count}`, `{widgetName}`) are
  substituted in the AI prompt and in `ext.sleuth.explain` /
  `ext.sleuth.encyclopedia` payloads.

### Behavior changes

- The VM client dispatches an empty timeline batch once per second while the
  timeline is quiet (`VmServiceClient.idleHeartbeat`), so window-based
  detectors keep evaluating on a static screen; a platform-channel burst no
  longer waits for the next unrelated event before it is judged.
- A structural scan tick schedules a frame when none is pending. On a quiet
  screen the post-frame scan used to wait for the next incidental repaint,
  which left results ten seconds or more behind a tab switch.

- The VM connection is reported lost after three consecutive failed polls
  (1.5 s) or as soon as the socket closes, instead of on the first failed
  RPC. A VM under allocation pressure can fail one timeline poll; treating
  that as a disconnect cleared every detector's VM state and left the memory
  detector blind for tens of seconds after each blip.

- Timeline begin/end reconstruction discards a pair longer than 2 s and
  evicts a pending begin older than that when the next begin arrives. Under
  heavy jank the VM drops events; a lost begin let a later end pair with a
  stale one and report the gap between two frames as a multi-second
  `heavy_compute` or raster scope.
- `expensive_gpu_nodes` no longer counts the `ClipPath` a transparency
  `Material` builds for its own shape (buttons, chips); user `ClipPath`s
  still count. One render object is now reported once: wrapper elements
  above it (a `Material`, a `Builder`) used to add a finding each, so a
  single clip showed as three nodes with subtrees one apart.

- The VM connection tries loopback before the address the service reports.
  A wirelessly launched iOS app binds its service to the wildcard address and
  reports the Wi-Fi address; connecting to that from inside the app was
  blocked by local-network privacy, so Sleuth stayed in Basic mode.

- Ranking uses an evidence tier (severity × confidence): confirmed critical >
  likely critical > confirmed warning > possible critical > likely warning >
  possible warning > ok. A structural-only guess ranks below a warning observed
  at runtime. Frame impact and recurrence order issues within a tier.
  `rankingBreakdown` keeps its four keys; `confidence` now carries the tier
  offset from the severity base and can be negative.
- Duration escalation removed: a warning no longer turns critical after 30 scan
  cycles. Severity is the detector's. Persistence shows in the `Seen N` badge
  and trend.
- Causal guard: a `possible` root claims only `possible` effects; it no longer
  claims `likely` or `confirmed` ones.
- A single-parent effect collapses under its parent only when the parent is at
  least as severe. Multi-parent effects stay visible as before.
- Removed edges: `uncached_images` → `heap_growing` / `heap_near_capacity` /
  `gc_pressure`; `excessive_keep_alive:*` → `gc_pressure`; `slow_request` →
  `heavy_compute`; `request_frequency` and `high_frequency_same_path:*` →
  `rebuild_activity` / `rebuild_debug_*`; `multiple_custom_fonts` →
  `sustained_jank` / `jank_detected`; `missing_repaint_boundary` →
  `raster_dominance`.
- Added edges: `uncached_images` → `native_memory_growing` (decoded bitmaps
  live in native memory); `large_response` → `heavy_compute`;
  `excessive_repaint` → `raster_dominance`; `non_lazy_shrinkwrap` →
  `jank_detected`. 41 causal rules.
- `compare_snapshots` between a 0.36 and a 0.37 snapshot can show severity
  differences caused by the escalation removal, not by app changes.
- Frame budget follows the measured frame rate. The vsync cadence (10th
  percentile of recent frame intervals) clamped to `[fpsTarget, display
  refresh rate]` sets the budget, so 90/120 Hz devices that render at 90/120
  get tighter jank thresholds; a ProMotion device rendering at 60 keeps 16.67
  ms. Opt out with `SleuthConfig(autoFrameBudget: false)`; capture mode always
  uses the fixed `fpsTarget` budget.
- Jank compares microseconds: `FrameStats.frameBudgetUs` (JSON
  `frameBudgetUs`; derived from `frameBudgetMs` when absent). At 60 Hz the
  budget is 16667 µs, so a 16.8 ms frame is jank and a 33 ms frame is no
  longer severe (severe starts above 33.334 ms).
- `DetectorThresholds.heavyComputeGapMs` defaults to null (auto): 8 ms at the
  `fpsTarget` budget, half the resolved budget when it tightens. An explicit
  value never scales. The `raster_dominance` per-frame floor scales the same
  way.
- `ext.sleuth.diagnose` adds `effectiveFrameRateHz`, `frameBudgetUs`, and
  `frameRateSource` (`fixed` / `display` / `measured`).
- `heavy_compute` and `platform_channel_traffic` keep the interaction context
  they fired in, so an issue raised during navigation still reads
  `navigating` afterwards. Ranking weights recurrence for `navigating` issues
  at 0.7, like scrolling and app-lifecycle. Nothing is suppressed while
  navigating.
- `layout_bottleneck`: intrinsics built by ToggleButtons, MenuBar, linear
  landscape BottomNavigationBar labels, AlertDialog, SimpleDialog, popup
  menus, CupertinoContextMenu, and Scaffold footer buttons are suppressed
  (matched by owner type within a measured ancestor-hop budget) and do not
  count toward nesting. A single intrinsic is warning/`possible`; nesting
  is critical/`likely`.
- Font detectors ignore Material's platform families (`CupertinoSystemText`,
  `CupertinoSystemDisplay`, `.AppleSystemUIFont`, `Segoe UI`) and the SDK
  icon fonts. A `packages/<pkg>/` family and its bare name, or google_fonts
  `<Family>_<variant>` names, count as one family. `runtime_font_loading` is
  always warning.
- `setstate_scope` requires observed rebuilds: child-identity churn across
  scans, or a debug-callback snapshot naming the owner (timeline-sourced
  counts do not count). A wide but static page no longer emits. Critical
  means the ratio exceeds 1.5× `dirtyRatioThreshold`. Builder-style owners
  (FutureBuilder, StreamBuilder, ValueListenableBuilder, Form, Focus, ...)
  never emit.
- `excessive_keep_alive:<i>`: a keep-alive counts toward the innermost
  PageView/TabBarView only. ListView, GridView, CustomScrollView,
  NestedScrollView, and SingleChildScrollView act as barriers and take no
  index, so a TabBarView emits once (previously twice, with its internal
  PageView) and kept-alive list items inside a page are not counted. Indices
  can shift for trees that contained a TabBarView.
- `stateful_density` has its own threshold, `RebuildDetector.statefulDensityThreshold`
  (default 10), instead of following the rebuild-rate threshold.
- List detectors: issue text says list-style children allocate every child
  widget on each parent rebuild instead of claiming every item is built at
  once; highlights go critical at the same > 3× threshold as the issue;
  `sliver_to_box_adapter_shrinkwrap` fires only when the child count is
  unbounded or above 20.
- `CustomPainterDetector` and `RepaintBoundaryDetector` skip framework
  painters: toggle and scrollbar painters by type (`ToggleablePainter`,
  `ScrollbarPainter`), and Material shape borders (Card, buttons, FAB),
  input borders, TabBar indicator and divider, progress and activity
  indicators, overscroll glow and stretch, AnimatedIcon, the dropdown menu,
  Placeholder, and GridPaper by painter class name plus the owning widget
  within a measured ancestor-hop budget. A user painter with the same class
  name outside that owner is still reported. `RepaintBoundaryDetector` also
  skips the `ClipPath` a transparency `Material` builds for itself.
- `excessive_repaint_boundary` no longer counts the boundaries a default
  `SliverList` / `SliverGrid` adds per child inside a `CustomScrollView`.
  Boundary frames are keyed by the element that pushed them; any
  `BoxScrollView` subclass is supported. User boundaries under a
  `SliverToBoxAdapter` or an `addRepaintBoundaries: false` delegate still
  count toward the enclosing scroll view.
- `uncached_images` measures instead of pattern-matching: each `Image` is
  paired with its decoded picture, and an image counts when its decode is at
  least 1.5× the physical pixels its box needs on the smaller axis (box ×
  device pixel ratio). The issue emits when counted images waste ≥ 1 MiB
  in total, critical at ≥ 16 MiB, as `likely`; the title shows the worst
  ratio and the wasted megabytes, the detail lists the top five. Skipped:
  images not yet decoded, `ResizeImage` providers (`cacheWidth` /
  `cacheHeight`), `BoxFit.none`, `centerSlice`, and `repeat`.
  `BoxDecoration` images are no longer reported (their decode is not
  reachable). The 50 dp small-image skip and the `> 5 images → critical`
  rule are removed. Encyclopedia name: Oversized Images.
- New `non_lazy_shrinkwrap` (ListView detector): a `ListView` / `GridView`
  with `shrinkWrap: true` inside a `Column` / `Row`, an unbounded main axis
  (not under `Expanded` or a sized box), and more than 20 children (or an
  unbounded builder) is a `possible` warning, critical above 100. It replaces `non_lazy_listview` for the same list; inside a
  `SliverToBoxAdapter`, `sliver_to_box_adapter_shrinkwrap` still wins.
  Escalates to `likely` with jank like the other list ids.
- `detectorHitRates` counts `non_lazy_sliver_list` and
  `non_lazy_sliver_grid` toward the ListView detector (previously `custom`).
- `missing_repaint_boundary` caps at `likely`: per-type paint rates cannot
  attribute to the specific unprotected widget.
- `frequent_repaint_painter` and the `always_repaint_painter` upgrade use the
  CustomPaint paint rate minus animation-owned paints.
- `shader_compilation` reads engine begin/end pairs: Impeller Vulkan pipeline
  builds (`PipelineVK::Create`, `CreateComputePipeline`) and Skia shader
  compiles (`devtoolsTag: shaders`). Issues are `likely` (a build stalls only
  frames that need that pipeline). Impeller Metal emits no build events and
  stays silent. The `--cache-sksl` / `--bundle-sksl-path` advice is removed.
- Platform-channel profiling is opt-in: `SleuthConfig(profilePlatformChannels:
  true)` sets `debugProfilePlatformChannels` once the VM connects and restores
  it on dispose. While on, the framework prints a "Platform Channel Stats"
  table to the console every second that channels are active.
- `platform_channel_traffic` emits on call count only. Per-call durations
  (async `b`/`e` pairs matched by `id`) are reported as `maxCallDurationUs`,
  `p95CallDurationUs`, and `callsOverThreshold`;
  `platformChannelDurationThresholdMs` (default 8) now marks slow calls and no
  longer triggers. `cumulativeDurationUs` is no longer stamped. Exported
  channel summaries carry measured durations.
- `large_response` skips `image/`, `video/`, `audio/`, and `font/` responses.
  `RequestRecord.contentType` (MIME type, serialized when present) is new.
  Network monitoring observes `dart:io` `HttpClient` traffic only;
  `cronet_http`, `cupertino_http`, and platform-SDK networking are invisible.
- `issuesNotifier` fires only when something rendered changes (ids, order,
  severity, confidence, category, text, widget/route attribution,
  interaction context, causal links); timestamps, ranking scores and trace
  arguments no longer trigger it. Export, fix verification and
  `ext.sleuth.issues` / `ext.sleuth.explain` read the latest aggregation.
  A per-tick scan pulse keeps the rebuild-stats panel and the `Seen X/Y`
  badge live.
- Scrolling re-measures highlight rects from their render objects instead of
  rescanning the tree, so scrolling no longer consumes detector state.
  `WidgetHighlight.renderObject` is new (optional). `refreshHighlights()`
  requests an early scan tick; scroll end runs one early tick 300 ms later.
- Scan cadence: a tick costing more than 4 ms stretches the next interval to
  `treeScanInterval × ceil(cost / 4 ms)`, capped at 5 s (not in capture
  mode). The clean-scan back-off no longer shortens intervals above 2 s.
  `SleuthConfig.maxElementsPerScan` (default 0, unlimited) skips one tick
  after a walk over the cap; a walk is never cut short.
- Periodic ticks defer by 250 ms while scrolling, at most three times in a
  row; a scroll with no activity for 2 s counts as ended.
- Route names come from `ModalRoute.settingsOf`, so the scan root no longer
  rebuilds on route pushes, pops and animation status changes.
- Long sessions stay bounded: `RouteSession.issueSnapshots` and
  `rebuildCountsByType` keep at most 256 keys (`RouteSession.maxTrackedEntries`,
  oldest-inserted evicted), unnamed-route ordinals are dropped with their last
  session, and recurrence trends go stale 120 cycles after their last
  presence even when it has left the 60-entry window. The type-name cache
  persists across scans and clears on hot reload.
- `raster_dominance` fires without a VM. Each frame's `FrameTiming` raster
  time is compared with its UI time: 3 frames within one second whose raster
  time exceeds the per-frame floor and `gpuPressureRatio` × UI time raise it
  as `likely` (new `ObservationSource.frameTiming`), critical when those
  frames also exceeded the frame budget. Frames in the startup window
  (`startupPhaseWindowSeconds`) are ignored on both legs: cold-start
  pipeline compilation no longer raises a VM-timeline `raster_dominance`. The VM leg is unchanged and
  still emits `confirmed`; a scan emits at most one `raster_dominance`. A VM
  disconnect keeps frame-sourced issues. Needs Frame Timing enabled.
- `expensive_gpu_nodes` is `likely` when raster-dominant frames were seen
  from either source; its text no longer asks for a VM connection.
- `BaseDetector.processFrame(FrameStats)` (default no-op) receives every
  presented frame on every tier. A detector that throws there is reported
  once and skipped until the next scan.
- `gc_pressure` defaults to more than 180 GC/min (`SleuthConfig.gcRateThresholdPerMin`,
  previously 60): an idle app with Sleuth attached runs 60–140 scavenges per
  minute from its own VM-service polling. Emissions stamp `scavengeCount` and
  `oldGenCount`, read from each GC event's raw `gcType`.
- `heap_near_capacity` measures process RSS against the new opt-in
  `DetectorThresholds.memoryBudgetBytes` (default null: the issue is off). It
  fires when RSS is at or above `memoryCapacityPercent` (default 0.80, now a
  fraction of the budget) of the budget for 4 of the last 5 memory polls while
  `heap_growing` is emitted; critical, `likely`, one identity per episode. The
  Dart heap usage/capacity rule is removed: Dart grows capacity with usage, so
  the ratio sat at 85–97 % on idle screens. Older capture files still carry
  `heap_near_capacity` / `gc_pressure` records from the previous rules; no
  audit reads them.
- Jank is judged per route. `FrameTimingDetector.markRouteEpoch()`, called
  when the scan loop sees a new route, drops `sustained_jank` /
  `jank_detected` at once; later evaluations read only frames since then, and
  emissions carry `sourceRoute`. Frames up to one scan tick after navigation
  still count toward the previous route, and frames before the first scan
  (startup) no longer count. The frame buffer, FPS and verdicts are unchanged.
- `platform_channel_traffic` stays visible for 10 s after it fires
  (`PlatformChannelDetector.emissionPersistence`). After the 3-window cooldown
  the issue is kept unchanged, so a burst still records one trace event.
- Example: the GPU Pressure demo animates six blurred circles (pause switch)
  to raise `raster_dominance`; new Tabbed Shell demo (`IndexedStack`, one
  structural pattern per tab).
- `rebuild_activity` and `excessive_repaint` measure cost, not count: the
  share of UI-thread wall time spent inside BUILD / PAINT scopes per ~1 s VM
  window, divided by the window's measured length. Warning above 10 %,
  critical above 30 % for both (`excessive_repaint` critical moves from 2×
  to 3× the warning threshold). A 60 fps animation of a small subtree no longer raises
  `rebuild_activity`. Titles read `build phase 18.2% of UI time`; emissions
  stamp `observedBuildPercent` / `observedPaintPercent` (one decimal)
  instead of `observedRebuildRate` / `observedPaintCount`.
- New `DetectorThresholds.buildTimePercentThreshold` and
  `paintTimePercentThreshold` (default 10). `SleuthConfig.rebuildThreshold`
  and `RepaintDetector.paintFrequencyThreshold` keep gating the per-widget
  debug paths (`rebuild_debug_*`, `repaint_debug_*`,
  `excessive_repaint_debug`) only.
- Removed: `RebuildDetector.setBaseline`, `baselineRebuildRate`,
  `lastObservedRebuildRate`, `peakObservedRebuildRate`;
  `RepaintDetector.lastObservedPaintCount`, `peakObservedPaintCount`.
  Replaced by `lastObservedBuildPercent` / `peakObservedBuildPercent` and
  `lastObservedPaintPercent` / `peakObservedPaintPercent` (double).
  `FixHintBuilder.rebuildActivity` takes `buildPercent` and
  `excessiveRepaintVm` takes `paintPercent`.
- The `rebuild_activity` (warning, critical) and `excessive_repaint`
  (warning) capture triads are re-recorded on the iPhone 12 / iOS 17.5 /
  Flutter 3.47.6 on the time-share axis (`percent`, atTolerance 0.5,
  ceiling 2.7×, observed-axis tolerance 0.25; the critical bracket keeps
  `minInBandSamples: 2`).
- Example: the RebuildActivity and Repaint capture screens vary build or
  paint cost per frame with a calibration pre-pass, and legs can be driven
  through `ext.sleuthDemo.captureLeg` / `captureResult` / `vmAxes`.
  The repaint leg records 6 s (was 4 s) with the above leg aimed at 2.0×
  the threshold; `vmAxes` refuses `reset=true` while a leg runs, and a
  throwing scenario end in a leg's cleanup is logged instead of replacing
  the leg's result.
- The VM poll loop fetches incrementally and never clears the VM timeline.
  The first poll of a session reads the whole buffer (startup events);
  later polls read a window from 500 ms (one poll interval,
  `VmServiceClient.fetchOverlapMicros`) before the newest event seen to
  the VM's timeline clock plus 1 s, and per-thread cursors drop the
  overlap. Begin/end pairs split across fetches pair through the
  pending-begin maps.
  Capture mode no longer re-reads the retained ring buffer on every poll
  (the source of two UI-isolate stalls per poll), live mode no longer
  loses events written between the fetch and the clear, and DevTools
  keeps its timeline. A clock read that fails or runs behind the newest
  event falls back to a full read with a client-side floor.
- Timeline parsing compares `ts` before reading any other field and builds
  the `(ph, name, id)` dedup signature only for events at a cursor's
  latest timestamp; `ParsedTimelineData` gains `maxTimestampUs` (used by
  the stale-begin sweep instead of a second walk) and `duplicatesDropped`.
- Poll cost is measured: `Sleuth.lastPollTimings` (`PollTimings`: RPC
  including decode, parse, dispatch, tail RPCs, event count, raw response
  length, duplicates dropped) and `ext.sleuth.diagnose` keys
  `lastPollRpcMicros`, `lastPollParseMicros`, `lastPollDispatchMicros`,
  `lastPollTailMicros`, `lastPollEventCount`, `lastPollResponseChars`,
  `maxPollRpcMicros`, `maxPollParseMicros`, `maxPollDispatchMicros`
  (32-poll maxima), `pollDuplicatesDropped`, and `pollWindowFallbacks`.
  Dispatch and tail are split further: `lastPollDispatch{Detectors,
  Correlate,Aggregate,Other}Micros` (sum to the dispatch),
  `lastPollTailMemoryMicros` (the `getMemoryUsage` await), and
  `lastPollTail{CpuSamples,AllocationProfile}Micros` (tail time during
  which such a request was in flight). Measured on the iPhone 12: <numbers>
- `getCpuSamples` (jank-frame CPU attribution) is issued at most once per
  10 s (`VmServiceClient.cpuSamplesMinInterval`) and never while an
  earlier request, including one that timed out, is unanswered. The VM
  builds the profile on the UI isolate's own thread and the response
  (about 3.3 MB for a 60 ms window, mostly the function table) is decoded
  there; issued on every poll with a jank verdict, it stalled the UI
  isolate by about 20 ms + 95 ms per poll on an M1 Pro.
- Debug instrumentation: the paint callback caches each element's ancestor
  chain and ancestor-owner verdict (recomputed when the parent, the depth,
  or the hot-reload epoch changes), and `SourceLocationCache` keys on the
  widget `Type`. 1,000 paints of a repainting widget cost about 2 % of the
  uncached path.
- Correlated verdicts are no longer suppressed when a poll batch spans
  several frames. The trust check compared one frame's matched events
  against the whole batch, so with three or more frames no frame reached
  half and the verdict fell back to `full`. `CorrelatedFrameData` now
  carries `batchMatchedEventCount` and `batchCoverageRatio` (events that
  matched any frame); a frame is trusted when it matched at least one
  event and the batch coverage is at least 0.5. `coverageRatio` is
  removed, and `FrameVerdict.correlationCoverage` reports the batch
  coverage.

### Testing

- Wall-clock benchmarks carry the `benchmark` tag and run serially:
  `flutter test --exclude-tags benchmark` for the default suite,
  `flutter test --tags benchmark --concurrency=1` for benchmarks. Budgets
  are about 5× the measured serial means, doubled on CI.
- The audit forwards each detector's canonical `observedAxisReduction` to
  bracket validation, so the `jank_detected` bracket is checked with
  `last` as declared.

`kSleuthPackageVersion` → 0.37.0. Sidecar sleuth_mcp 0.8.0 pins 0.37.0.

## 0.36.0

Companion package: `sleuth_mcp` is now available — an MCP stdio sidecar that
exposes the `ext.sleuth.*` VM service extensions to AI clients (Claude Code,
Cursor, Zed), so an assistant can query a running app's live performance data in
conversation. Opt-in and versioned independently (see
[`packages/sleuth_mcp/CHANGELOG.md`](packages/sleuth_mcp/CHANGELOG.md), current
0.7.2). The in-app overlay remains sleuth's primary UX.

This release also brings the MCP integration surface and snapshot controls
(consolidates 0.32.0–0.35.0; per-version detail in `CHANGELOG.archive.md`):

- Seven `ext.sleuth.*` extensions — `snapshot`, `issues`, `routeHealth`,
  `explain`, `encyclopedia`, `causalGraph`, `diagnose`. Debug/profile only
  (`kReleaseMode` no-op). Every response stamps `connectionMode`,
  `schemaVersion: 1`, and a per-session `sessionUuid`.
- Wire-shape lock — `doc/mcp_schema.{json,md}` codify the envelope and every
  handler's data shape (nested `recurrenceTrends` / `sessionSummary` /
  `routeSessions` included), audit-enforced.
- Snapshot projection + pagination — `sections` / `maxIssueCount` /
  `maxRouteCount` keep long sessions under the MCP client token cap;
  backward-compatible (no args = full payload).
- `SleuthConfig.showOverlay` (default `true`): set `false` to hide the in-app
  overlay (trigger button + dashboard) while detectors and `ext.sleuth.*` keep
  running — for MCP-only sessions where the AI client is the consumer.

`kSleuthPackageVersion` → 0.36.0; envelope `schemaVersion` stays `1`. Sidecar
`sleuth_mcp` (current 0.7.2) pins 0.36.0.

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
