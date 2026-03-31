## 0.9.0

### Changed

- **Unified structural tree walk** (v7.9): all 16 tree-scanning detectors now
  run in a single `O(N)` pass instead of 16 separate `O(N)` walks. Four new
  `BaseDetector` lifecycle methods (`prepareScan`, `checkElement`,
  `afterElement`, `finalizeScan`) replace per-detector `scanTree` for built-in
  detectors. Custom detectors continue using `scanTree` via legacy path.
  Zero test changes required — `scanTree` base class wrapper calls the 4 methods
  automatically.

## 0.8.2

### Improved

- **Ring buffer for frame history** (v7.7): `FrameStatsBuffer` replaced
  `List<FrameStats>` with a fixed-capacity ring buffer. Eliminates GC pressure
  from growing lists during long sessions. `O(1)` insert, bounded memory.
- **Correlator sort cache** (v7.8): `FrameEventCorrelator` caches sorted event
  lists across correlation rounds. Avoids re-sorting unchanged data on every
  frame. ~40% reduction in correlator CPU time under sustained load.
- **VM reconnect polling fix** (v7.10): `_pollTimeline()` error handler now
  cancels the poll timer directly before invoking callbacks, preventing a 500ms
  error loop if `onConnectionChanged` throws. Timer cancel is idempotent —
  no impact on `reconnect()` cleanup path.

## 0.8.1

### Improved

- **HeavyCompute two-tier severity** (v7.1): events 100–500ms report as
  `medium` severity, >500ms as `high`. Previously all heavy compute events
  were `high` regardless of duration.
- **NetworkMonitor threshold fix** (v7.2): frequency limit comparison changed
  from `>` to `>=` to match documented behavior. 30 requests in 5s now
  correctly triggers the detector at the configured limit.
- **Threshold tuning pass** (v7.3): 6 detector thresholds adjusted based on
  real-app profiling data. Reduces false positives for common patterns while
  maintaining sensitivity for genuine issues.
- **Correlator coverage expansion** (v7.4): `FrameEventCorrelator` now matches
  3 additional timeline event categories that were previously ignored, improving
  phase attribution accuracy.
- **Rebuild VM fallback** (v7.5): `RebuildDetector` degrades gracefully when VM
  build counts are unavailable, falling back to structural density analysis
  instead of reporting nothing.
- **MemoryPressure warmup guard** (v7.6): heap growth detection ignores the
  first 10s after connection to avoid false positives from app startup
  allocation patterns.

## 0.8.0

### Improved

- **Controller async safety** (v6.1): VM service calls wrapped with 10 s
  timeouts and disposed-state guards. `dispose()` cancels in-flight futures
  and timeline subscriptions. Prevents `setState after dispose` and hung
  controller on lost VM connections.
- **Enrichment error logging** (v6.14): enrichment chain failures now log
  structured messages via `debugPrint` instead of silently swallowing errors.
- **AnimatedOpacity detection** (v6.2): `OpacityDetector` now detects
  `AnimatedOpacity` widgets at opacity 0 in addition to static `Opacity`.
- **ShaderMask render detection** (v6.3): `GpuPressureDetector` includes
  `RenderShaderMask` in the expensive render-tree check.
- **Nested scroll highlights** (v6.4): `NestedScrollDetector` provides
  widget highlight overlays marking the inner and outer scroll regions.
- **ListView threshold tuning** (v6.19): non-lazy `ListView` child-count
  threshold adjusted for more accurate detection with fewer false positives.
- **TriggerButton adaptive position** (v6.20): initial button position adapts
  to screen size, placing it in the visible area on all device sizes.
- **Model equality** (v6.13): `PerformanceIssue` implements `==` and
  `hashCode` based on `stableId`, enabling correct deduplication and
  `Set`/`Map` usage.
- **Suppression precompilation** (v6.15): suppression patterns compiled to
  `RegExp` once at config time instead of per-issue per-scan.
- **UI tap targets** (v6.5): header icon buttons increased to minimum 44 px
  touch target.
- **UI drag safety** (v6.6): `onPanUpdate` clamps card position within
  screen bounds on every frame.
- **UI keyboard awareness** (v6.7): floating card repositions when the
  software keyboard opens to prevent occlusion.
- **UI listener dedup** (v6.8): `ValueListenableBuilder` listeners
  deduplicated to prevent redundant rebuilds.
- **UI text overflow protection** (v6.9): long text in issue cards and
  banners protected with `maxLines` and `TextOverflow.ellipsis`.
- **GuidePage back navigation** (v6.12): hardware/system back button returns
  from GuidePage to the floating card.
- **Spacing theme tokens** (v6.21): 6 spacing tokens (`spacingXxs` through
  `spacingXl`) on `WatchdogThemeData`. ~67 hardcoded spacing values replaced
  across 4 UI files. Consumers can customize overlay density via theme.
- **Benchmark robustness** (v6.22): timing budgets use `budgetMultiplier`
  that reads `CI` environment variable, preventing flaky tests on loaded
  runners.

### Changed

- **FloatingIssuesCard refactored** (v6.10): large build methods extracted
  into focused builder functions. Zero behavior change.
- **IssueCard refactored** (v6.11): build method extraction matching
  FloatingIssuesCard pattern. Zero behavior change.
- **Platform declarations** (v6.16): `pubspec.yaml` now declares `android`
  and `ios` platform support explicitly for pub.dev scoring.

### Added

- Controller lifecycle tests (v6.17): 20+ tests for dispose guards, timeout
  behavior, and error resilience.
- UI widget tests (v6.18): widget tests for FloatingIssuesCard, IssueCard,
  TriggerButton, and GuidePage interactions.
- 1,294 tests total, 0 analysis issues.

## 0.7.0

### Added

- **Issue suppression** (v4.1): `WatchdogConfig.suppressedIssues` filters issues
  by `stableId` pattern (exact match or trailing `*` wildcard). Applied
  post-correlate, pre-rank. `suppressedCountNotifier` for UI display.
  `SessionSnapshot.suppressedCount` for export.
- **Custom detector plugin API** (v4.2): `WatchdogConfig.customDetectors` accepts
  `List<BaseDetector>` for domain-specific detectors. Custom detectors integrate
  into all 7 controller lifecycle points (init, debug snapshot, structural scans,
  highlights, timeline data, issue aggregation, dispose). Always enabled
  regardless of `enabledDetectors`. Barrel file exports `BaseDetector`,
  `ParsedTimelineData`, `DebugSnapshot`.
- **Overlay theming** (v5.1): `WatchdogThemeData` with 60 color tokens extracted
  from 6 UI files. Dark defaults match original values exactly.
  `WatchdogThemeData.light()` for light-background apps. Auto-brightness
  detection via `MediaQuery.platformBrightness`. `copyWith()` for custom
  overrides. `WatchdogTheme` InheritedWidget with dark fallback.
- **Export enrichment** (v5.2): `SessionSnapshot` schema v2 with `PhaseEvent`
  toJson/fromJson + rolling buffer, `GcEventSummary` + `PlatformChannelSummary`
  serializable wrappers, `FpsPercentiles` (p50/p95/p99), `rankingScore` /
  `rankingBreakdown` on `PerformanceIssue`, `recentFrames` (last 60),
  `schemaVersion` field. All new fields nullable for backward compat.
- **Causal issue graph** (v5.3): 23 cause-effect rules build a directed graph,
  identifying root causes and annotating issues with `rootCauseId` /
  `downstreamIds`. Confidence suppression hides `possible` downstream when root
  is `confirmed` / `likely`. UI: FloatingIssuesCard filters downstream from main
  list, IssueCard shows `↳ N` badge + "Related effects" section. 1 new theme
  token (`effectsBadge`).
- **Configurable detector thresholds** (v5.4): `DetectorThresholds` nested config
  class on `WatchdogConfig` with 10 tunable parameters. All defaults match
  pre-change hardcoded values. Secondary severity thresholds scale with primary
  (`* 2`). Barrel exports `DetectorThresholds`.
- **Network-to-frame correlation** (v5.6): `NetworkMonitorDetector` gains active
  request tracking via `startRequest()` / `endRequest()`. `FrameVerdict` gains
  `pendingRequestCount` and `slowestPendingMs` fields. `WatchdogHttpOverrides`
  gains `onRequestStarted` / `onRequestEnded` callbacks. Controller enriches all
  3 verdict paths. 2 new causal graph rules. Zero overhead when network
  monitoring disabled.
- **RepaintBoundary coverage detector** (v5.8): 22nd detector
  (`DetectorType.repaintBoundary`, structural). Walks element tree for 5
  expensive GPU widget types (`Opacity`, `ClipPath`, `BackdropFilter`,
  `ShaderMask`, `CustomPaint`), checks render tree for `RenderRepaintBoundary`
  within 3 ancestor levels. Three-tier confidence: `possible` → `likely`
  (>10/sec) → `confirmed` (>30/sec). 3 new causal graph rules.

### Changed

- **Detector registry** (v5.5): replaced 21 individual detector fields in
  `WatchdogController` with unified `List<BaseDetector>` registry. 7 dispatch
  methods use lifecycle-filtered loops. Adding a new detector now requires 1 new
  file, 1 enum value, 1 line in the registry. ~-90 net lines in controller.
- **Example app modularized** (v4.5): extracted 18 demo screens from
  `example/lib/main.dart` (1,807 lines) into individual files under
  `example/lib/demos/`. `main.dart` reduced to 239 lines.
- **FloatingIssuesCard sub-widgets extracted** (v4.4): `_StatusRow`,
  `_CardFooter`, `_WarningBanners` extracted — state class reduced from 659 to
  433 lines. Zero behavior change.

## 0.6.1

### Fixed

- **FPS counter precision**: `averageFps` now uses microsecond-precision
  arithmetic instead of milliseconds, eliminating ~8% inflation from truncation
  artifacts (e.g., 6.5ms truncated to 6ms gave 167 FPS instead of 154).
- **FPS counter startup**: `_frameTiming.start()` moved before
  `await client.connect()` so the FPS counter captures frames during the
  potentially slow VM connection (1.5–10.5s), instead of showing 0.
- **FPS display capped at target**: UI now clamps displayed FPS at `fpsTarget`
  (default 60) so an idle screen in profile mode shows 60 instead of raw
  throughput values like 120+.
- **`fpsColor` target-aware**: color thresholds are now relative to `fpsTarget`
  (green >= 83%, amber >= 50%) instead of hardcoded to 50/30 FPS.
- **`exportSnapshot` reads live buffer**: uses `_frameTiming.frameBuffer`
  directly when initialized, avoiding potential staleness from the notifier.

### Added

- `TriggerButton.fpsTarget` parameter — wired from `WatchdogConfig.fpsTarget`.
- FPS throughput unit tests (9 tests in `frame_stats_buffer_fps_test.dart`).
- FPS Stress Test demo screen in example app.

## 0.6.0

### Changed

- **Replaced DashboardSheet with FloatingIssuesCard**: the bottom sheet
  (1,241 lines) is replaced by a draggable floating card (~830 lines). Removed
  `FrameChart`, tabs, and filter chips. FPS is now shown directly on the
  `TriggerButton`.
- **Guide redesigned**: the Guide tab is now a full-screen `GuidePage` with
  staggered entrance animations and 4 expandable sections (Quick Start,
  Understanding the Card, Color Legend, Tips & Tricks).
- **Resizable card**: width and height adjustable via corner grip handle.
  Double-tap header to maximize/restore.

### Added

- `FloatingIssuesCard` — draggable, resizable floating panel for issue display.
- `_CornerGripPainter` — 6-dot grip handle inside the card's corner radius.
- `GuidePage` — full-screen guide with staggered fade+slide animations.
- 9 card resize tests (`card_resize_test.dart`).

### Removed

- `DashboardSheet`, `FrameChart` widget, `TabBarView` with keep-alive, filter
  chips, `AnimationController` for chart.

## 0.5.0

### Added

- **Context-aware fix hints** (v3.2): centralized `FixHintBuilder` generates
  widget-specific, location-aware fix suggestions instead of generic textbook
  advice. Hints reference the detected widget name, ancestor chain, and
  interaction context when available. `FixEffort` enum (`quick`, `medium`,
  `involved`) classifies every hint by estimated developer effort.
  - New `FixHintBuilder` utility with 28 static methods (one per issue type).
  - `fixEffort` field on `PerformanceIssue` — nullable for backward compat.
  - UI effort badge now reads from model field; keyword fallback for legacy JSON.
- **Issue-to-verdict linking** (v3.3): jank verdicts in the Live tab now connect
  to related issues in the Issues tab.
  - Amber "Jank detected" banner on Live tab when a verdict has related issues.
  - "JANK" badge on issue cards correlated with the current jank verdict.
  - Tap the jank banner to flash correlated issue cards in the Issues tab.
- **Overlay UX improvements** (v3.8): six targeted UI enhancements for the
  diagnostic workflow.
  - Widget name shown before ancestor chain in expanded issue cards.
  - "Widget not currently visible" feedback when highlight target not found.
  - Interaction context filter chips on the Issues tab (All / Idle / Scrolling).
  - "About this detection" collapsible section with source, confidence, and
    verification guidance.
  - Effort indicators (QUICK / MEDIUM / INVOLVED) on fix hint boxes.
  - Color legend in the Guide tab explaining severity and source colors.

### Changed

- All 21 detectors now use `FixHintBuilder` instead of hardcoded fix hint
  strings. No detector logic changes — only hint generation centralized.
- `PerformanceIssue` model gains `fixEffort` field (nullable, backward
  compatible). JSON without the field deserializes to null.
- Barrel file exports `FixHintBuilder` for consumers who want to generate
  custom hints.

## 0.4.0

### Improved

- **AnimatedBuilder threshold raised** (v3.1.1): subtree size threshold increased
  from 5 to 20, reducing false positives on normal animations. Confidence defaults
  to `possible` and upgrades to `likely` only when DebugSnapshot confirms rebuild
  rate > 30/sec.
- **CustomPainter secondary heuristic** (v3.1.2): added `frequent_repaint_painter`
  detection — when no always-true painters are found but CustomPaint paint rate
  exceeds 30/sec, a warning is emitted to prompt `shouldRepaint` review.
- **MemoryPressure warmup exclusion** (v3.1.3): heap trend alerts are suppressed
  during the first 5 seconds after the initial heap sample, preventing false
  positives from normal app startup allocation. GC pressure and heap capacity
  alerts are unaffected. Configurable via `WatchdogConfig.memoryWarmupDurationMs`.
- **NestedScroll cross-axis suppression** (v3.1.4): horizontal ListView inside
  vertical ScrollView (and other cross-axis combinations) no longer produces
  false positives. Only same-axis nesting is flagged.
- **Opacity near-zero detection** (v3.1.5): threshold widened from exact `0.0`
  to `< 0.01`, catching visually invisible widgets that still pay layout and
  hit-testing costs. Detail text includes the actual opacity value.
- **GpuPressure structural issue preservation** (v3.1.6): when VM disconnects,
  structural issues (expensive render nodes) are preserved at `possible`
  confidence instead of being cleared entirely. Only the VM-backed raster
  dominance issue is removed.
- **PlatformChannel duration tracking** (v3.1.7): tracks cumulative per-call
  duration alongside frequency. Fires when either frequency exceeds threshold
  OR cumulative duration exceeds 8ms (configurable via
  `WatchdogConfig.platformChannelDurationThresholdMs`). Detail includes top
  method names.
- **FrameEventCorrelator binary search** (v3.9): O(E×F) linear scan replaced
  with O(E log F) binary search using pre-sorted frame lists. Behavioral
  equivalence maintained for all existing tests.

### Added

- `WatchdogConfig.memoryWarmupDurationMs` — warmup period for heap trend alerts
  (default 5000ms).
- `WatchdogConfig.platformChannelDurationThresholdMs` — cumulative duration
  threshold for platform channel detection (default 8ms).

## 0.3.0

### Added

- **Heap trend monitoring** (v2.2): `MemoryPressureDetector` now polls
  `getMemoryUsage()` alongside the existing VM timeline poll. Tracks a rolling
  window of 60 heap samples (30 seconds) and applies linear regression to detect
  sustained growth. Two new issue types:
  - *Heap Growing* — positive slope > 500 KB/sec for 10+ consecutive seconds
    (severity: warning, confidence: likely).
  - *Heap Near Capacity* — heap usage > 80% of heap capacity (severity:
    critical, confidence: confirmed).
  - `HeapSample` data class exported for session snapshot consumers.
- **Jank CPU attribution** (v2.3): when a jank frame is detected and VM is
  connected, `getCpuSamples()` is queried for that frame's time window.
  `CpuSampleAggregator` ranks functions by exclusive ticks and surfaces the
  top 5 in `FrameVerdict.topFunctions`. Two-phase verdict emission: the verdict
  is emitted immediately, then updated with CPU attribution when samples arrive
  (or after 500 ms timeout).
  - `CpuAttribution` data class exported for snapshot consumers.
  - Dashboard shows "Top: ClassName.method (N%)" on jank verdicts.
- **Source file:line in ancestor chains** (v2.4): `buildAncestorChain()` appends
  `(lib/path/file.dart:line)` to the leaf widget when `--track-widget-creation`
  is active (debug mode default). Uses `InspectorSerializationDelegate` to
  access creation location data. Results cached per widget runtime type
  (bounded at 200 entries). Zero behavior change in profile mode.
  - `SourceLocationCache` utility with `abbreviatePath()` for `lib/`-relative
    path display.

### Changed

- `MemoryPressureDetector` enhanced: `processHeapSample()` replaces the old
  `updateHeapStats()` method. Rolling window with linear regression replaces
  percentage-based growth detection.
- `FrameVerdict` gains `topFunctions: List<CpuAttribution>?` field and
  `withTopFunctions()` copy method for two-phase enrichment.
- Session export (`exportSnapshot()`) now includes `heapSamples` array and
  CPU attribution data when available.
- Barrel file exports `CpuAttribution`, `HeapSample`, and updated
  `FrameVerdict`.
- Ancestor chain framework filter expanded: 17 additional framework widgets
  (transitions, builders, pointer/render infrastructure) are now excluded
  from ancestor chains, producing shorter and more user-relevant paths.
- Issue card no longer shows redundant "Widget:" line when the detail text
  already contains the ancestor chain.
- README "What DevTools Still Does Better" narrowed from 5 items to 2
  (heap snapshots & full flame chart). Network inspection, memory trends,
  CPU profiling, and widget-exact attribution are no longer DevTools-only.

## 0.2.0

### Breaking Changes

- **`DetectorType.memoryLeak`** renamed to **`DetectorType.memoryPressure`**.
  If you pass a custom `enabledDetectors` set, update the enum value.
- **`DetectorType.mediaQueryRebuild`** renamed to **`DetectorType.shallowRebuildRisk`**.
  Same migration: update any custom `enabledDetectors` references.
- **`DetectorLifecycle.runtime`** added to the `DetectorLifecycle` enum.
  Exhaustive switches over `DetectorLifecycle` need a new case.

### Added

- **Per-frame event correlation**: VM timeline events matched to specific frames
  by monotonic timestamp overlap, replacing batch attribution.
- **Three-tier verdict degradation**: Correlated > Full > Basic mode. Falls back
  automatically based on VM connectivity and correlation quality.
- **FrameTiming upgrades**: `totalSpan` (vsyncStart to rasterFinish) as primary
  jank indicator, pipeline stall detection, scheduler delay detection,
  build-to-raster gap measurement.
- **Debug attribution hooks** (`enableDebugCallbacks` config): opt-in per-widget
  rebuild/repaint tracking via `debugOnRebuildDirtyWidget` and
  `debugOnProfilePaint`. Default false to avoid conflicting with DevTools.
- **Heavy debug instrumentation** (`enableDeepDebugInstrumentation` config):
  per-widget timeline events using 6 Flutter debug globals with save/restore
  lifecycle. UI shows purple warning banner when active.
- **Two-tier config model**: simple top-level switches + expert `advanced` block
  (`DebugInstrumentationConfig`) for fine-grained control over attribution and
  profiling sub-flags.
- **Issue ranking**: weighted composite score (severity, frame impact, confidence,
  recurrence) determines issue ordering in the dashboard.
- **Route tagging**: automatic `routeName` stamping on issues via
  `ModalRoute.of()`. Displayed in expanded issue cards.
- **Interaction context**: `idle`, `scrolling`, `navigating` states tracked and
  stamped on issues. Shows "During: scrolling" in issue cards.
- **Rolling jank capture buffer**: worst-N frame retention (default capacity 50,
  configurable via `captureBufferCapacity`). Evicts mildest frames when full.
- **JSON session export**: `WidgetWatchdog.exportSnapshot()` and
  `exportSnapshotJson()` static methods. Dashboard export button copies JSON to
  clipboard.
- **Source-location enrichment**: ancestor chain attribution on structural and
  debug-backed issues. Displayed as "Widget: Outer > Middle > Inner" in expanded
  issue cards.
- **Timeline enrichment**: dirty widget names and counts extracted from enriched
  VM timeline args (build scope, layout, paint phases).
- **Rebuild/repaint widget highlights**: visual overlay rects highlighting hot
  widgets during scan, correlated from debug snapshot and enriched VM names.
- **`stableId`** field on `PerformanceIssue` for UI state persistence across
  scan cycles.
- **`ancestorChain`** field on `PerformanceIssue` for source-location guidance.
- **`ObservationSource`** enum distinguishing VM timeline, debug callback,
  structural, and combined sources. UI shows left-border accent (green/purple/gray).
- **Confidence badges** in dashboard: Confirmed, Likely, Possible with
  color-coded chips.
- **20th detector**: Repaint detector added as hybrid (VM + debug callback).
- **Self-overhead benchmark suite** (29 tests): per-detector scan overhead, full
  scan scaling, timeline processing, buffer bounds, issue/highlight count limits.
- **Validation matrix** (`doc/validation_matrix.md`): structured release-readiness
  checklist with per-platform grids, degradation verification, and detector
  coverage checklist.
- **Degradation contract integration tests** (9 tests): VM disconnect/reconnect,
  verdict path switching, detector group isolation.
- **5 new example app demo screens**: Opacity Zero, AnimatedBuilder No Child,
  Shallow Rebuild Risk, Font Loading Stress, Repaint Stress.

### Changed

- `MemoryLeakDetector` renamed to `MemoryPressureDetector` — honest framing;
  this detector monitors GC frequency and heap growth, not individual object leaks.
- `MediaQueryRebuildDetector` renamed to `ShallowRebuildRiskDetector` — the
  detector finds shallow StatefulWidgets during high build activity, it does not
  observe actual `MediaQuery.of()` usage.
- `RebuildDetector` now labels widget names as screen context, not proven
  rebuild attribution. Title changed to "High Rebuild Activity".
- `GpuPressureDetector` confidence corrected: `confirmed` for observed raster
  dominance, `likely` when expensive render nodes also found (was reversed).
- `OpacityDetector` no longer claims GPU waste for `Opacity(0.0)`. Repurposed
  as a correctness hint (widget still participates in hit testing, layout, and
  semantics). Confidence downgraded to `possible`, category changed to `layout`.
- Removed dead `analyzeBasicMode()` from `RenderPipelineAnalyzer`.
- `fpsTarget` config now drives jank detection thresholds (was hardcoded to
  16ms/33ms regardless of target FPS).
- `IssueConfidence` doc comments updated to describe evidence tiers accurately.
- README, barrel file, and CHANGELOG updated to match actual package behavior.

### Fixed

- Erroneous `* 1024 * 1024` multiplier on `pictureCacheBytes` in
  `FrameTimingDetector` — `FrameTiming.pictureCacheBytes` already returns bytes.
- Chart budget line and color thresholds now use per-frame `frameBudgetMs`
  instead of hardcoded 16ms/33ms, correctly supporting 120fps mode.

## 0.1.0

- Initial release
- 19 performance detectors (VM-only, hybrid, structural)
- Dual-mode analysis (Full VM Timeline + Basic SchedulerBinding)
- In-app overlay with live FPS chart, issue dashboard, and guide
- Debug mode warning banner
- Configurable thresholds and detector selection
- Zero release overhead (kReleaseMode guard)
