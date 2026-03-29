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
