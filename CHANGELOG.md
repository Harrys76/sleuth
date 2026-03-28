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
