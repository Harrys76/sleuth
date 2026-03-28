# Widget Watchdog Implementation Spec

## Objective

Build `widget_watchdog` into an honest in-app DevTools alternative with:

- a mobile-first Flutter performance workflow for Android and iOS apps
- strong default detectors that are actually trustworthy
- clear separation between measured runtime signals and heuristic guidance
- public messaging that matches what the code can prove
- a stable path for later advanced work on frame-correlated VM analysis

## Roadmap Structure

This document is organized in three layers:

- `Core Foundation`: the minimum work required to make the profiler framework technically honest, maintainable, and publishable
- `Advanced Profiling`: stronger attribution and deeper runtime analysis built on top of that foundation
- `Framework Expansion`: higher-value workflow and UX features that make the package more useful in day-to-day performance work

This is not a "small v1" plan. It is a staged profiler-framework roadmap where the core layer exists to make the advanced layers trustworthy.

## Product Positioning

For v1, the package should be positioned as:

- VM-powered runtime diagnostics for Flutter mobile apps
- frame timing plus optional VM timeline plus widget-tree heuristics
- faster, more actionable in-app triage than DevTools for common issues

It should not claim:

- exact per-frame diagnosis
- exact offending widget detection
- leak tracking unless leak tracking is truly implemented

## Platform Capability Disclosure

This needs to be explicit in the README and package docs.

- Frame timing mode is the universal baseline and should be the primary story.
- Full VM mode is best-effort and platform-dependent.
- Android and iOS are the primary target platforms.
- Desktop is a secondary environment that may still be useful for development and validating full VM analysis behavior.
- Physical iOS devices are a good candidate for full VM analysis.
- Android full VM analysis may work on real devices depending on VM service connectivity, but should not be presented as universally reliable.
- Android emulator/device workflows should expect fallback behavior more often than desktop.

Acceptance criteria:

- The README states that frame timing mode is the primary cross-platform path.
- The README states that Android and iOS are the primary target platforms.
- The README explains that full VM mode is best-effort.
- No user-facing copy implies full VM mode is equally reliable on all platforms.

## Operational Guarantees

The profiler framework should define explicit expectations for:

- target-platform validation
- fallback and degradation behavior
- package self-overhead

### Mobile-first validation matrix

Required primary validation targets:

- Android real device
- Android emulator
- iOS real device

Secondary validation target:

- desktop, only as a secondary environment for development convenience and full-mode behavior validation

Required runtime modes:

- debug
- profile

For each target/mode combination, validation should record:

- whether the app boots with the package enabled
- whether the overlay works
- whether the `FrameTiming` path works
- whether VM full mode connects
- which detector groups are active:
  - frame/runtime
  - VM-backed
  - structural
  - debug instrumentation
- what UI warning/state is shown
- whether confidence or verdict behavior is degraded

Acceptance criteria:

- Release readiness is evaluated against a written validation matrix, not ad hoc spot checks. ✅
  Implemented as `doc/validation_matrix.md` with per-platform/mode grids, expected behavior
  reference, degradation verification checklist, detector coverage checklist, and sign-off template.
- Mobile targets are treated as the primary compatibility contract. ✅
  Android (device + emulator) and iOS grids are primary; desktop grid is secondary.

### Degradation contract

The product should define consistent fallback behavior when VM full mode is unavailable or partial.

Required rules:

- `FrameTiming` mode remains available whenever possible and is the baseline runtime path.
- VM-backed detectors must be disabled or downgraded when VM service connectivity is unavailable.
- The UI must explicitly state when the package is operating without full VM analysis.
- Confidence and verdict wording must degrade automatically when only partial signals are available.
- The package should prefer "limited analysis" over silent failure.

Acceptance criteria:

- Each detector group has a defined fallback behavior.
- Users can tell from the UI when the package is running in reduced-capability mode.
- No detector silently presents VM-strength claims when only fallback signals are available.

### Self-overhead constraints

The profiler framework must define constraints on its own overhead.

Required constraints:

- no extra tree walks when the overlay is off unless explicitly required by an enabled detector
- highlight collection remains conditional
- callback aggregation is bounded and allocation-light
- no unbounded buffers for events, issues, or histories
- debug instrumentation overhead must be measurable and documented

Future requirement:

- add a small benchmark or measurement workflow to validate package overhead over time ✅ Implemented as `test/benchmark/` suite: per-detector scan overhead (15 detectors × 1000 elements), full scan at 100/500/1000/3000 elements, linearity regression test, timeline processing benchmarks, memory/buffer bounds. All tests assert CI-friendly overhead budgets. 592→606+ tests.

Acceptance criteria:

- The package has explicit self-overhead rules in the spec.
- Instrumentation and analysis paths are bounded by design.
- Overhead-sensitive features are documented with their tradeoffs.

## Definition Of Confidence

- `Confirmed`: directly observed runtime condition or directly observable widget state.
- `Likely`: real runtime signal plus a plausible structural cause.
- `Possible`: structural or indirect heuristic only.

Confidence should describe evidence quality, not marketing certainty.

Confidence-to-copy rules:

- `Confirmed` may use wording like `observed`, `measured`, or `detected`.
- `Likely` may use wording like `likely caused by` or `likely related to`.
- `Possible` should use wording like `may be related to`, `possible`, or `heuristic`.
- Copy must not be stronger than the confidence level assigned to the issue.

## Core Foundation Roadmap

1. README truthfulness and platform disclosure
2. Memory leak story fix
3. Configuration truthfulness
4. Deduplicate detector and highlight logic
5. Detector confidence cleanup and detector renames/repurposing
6. Interleaved tests with each fix
7. Optional `verificationHint` support
8. Advanced frame correlation later

## Milestone 1: README Truthfulness And Capability Disclosure

- Rewrite the README intro and feature copy in `README.md`.
- Remove or weaken "exact phase breakdown" wording until frame correlation exists.
- Remove `leak_tracker` claims unless the code actually uses it.
- Document the package as "VM-powered runtime diagnostics with heuristic explanations".
- Add a detector matrix table with:
  - `Detector`
  - `Signal Source`
  - `Can Prove`
  - `Confidence`
  - `Known False Positives`
- Add a short section:
  - "What this does better than DevTools"
  - "What DevTools still does better"
- Add an explicit unsupported-claims section covering at least:
  - not a replacement for full DevTools timeline analysis
  - not guaranteed to attribute the exact offending widget in profile mode
  - VM full mode availability depends on runtime environment
- Add platform capability notes for full VM mode vs frame timing mode.

Acceptance criteria:

- No public copy claims exactness that the implementation cannot prove.
- Every detector listed in README has an evidence description matching the code.
- Platform limitations are explained clearly.

## Milestone 2: Memory Story Fix

Short-term publish-safe path:

- Rename `MemoryLeakDetector` to `MemoryPressureDetector`.
- Rename `DetectorType.memoryLeak` to `DetectorType.memoryPressure`, or add a deprecation path if backward compatibility is required.
- Remove `leak_tracker` from public claims and from `pubspec.yaml` if unused.
- Present only:
  - GC pressure
  - heap growth, if truly wired
  - image memory heuristics
- Update all docs and issue text accordingly.

Required code fixes:

- Stop calling `processTimelineData(ParsedTimelineData())` on GC events as a fake signal path.
- Either wire real heap stats from VM service into the detector or remove heap growth claims until that plumbing exists.

Files:

- `lib/src/detectors/memory_leak_detector.dart`
- `lib/src/controller/watchdog_controller.dart`
- `lib/src/vm/vm_service_client.dart`
- `README.md`
- `pubspec.yaml`

Public API note:

- Renaming `DetectorType.memoryLeak` is a breaking API change for users who pass custom `enabledDetectors`.
- The implementation must choose one of:
  - a documented breaking change with changelog/release-note coverage
  - a temporary compatibility/deprecation path
- File names and exported type names should be kept consistent with the final terminology.

Acceptance criteria:

- Publish version uses honest memory pressure terminology unless real leak tracking is implemented.
- No README line suggests leak-tracker-backed leak detection unless code actually uses it.
- The GC event path is no longer a fake no-op signal.

Testing:

- Add or update tests alongside the rename and behavior change.

## Milestone 3: Configuration Truthfulness

Files:

- `lib/src/models/frame_stats.dart`
- `lib/src/controller/watchdog_controller.dart`
- `lib/src/detectors/frame_timing_detector.dart`

Goal:

- Make public configuration actually affect behavior.

Recommended path:

- Make `fpsTarget`, `warningThresholdMs`, and `criticalThresholdMs` drive jank detection.
- Derive defaults from frame budget:
  - `frameBudgetMs = 1000 / fpsTarget`
  - warning threshold defaults to `frameBudgetMs`
  - critical threshold defaults to `frameBudgetMs * 2`
- Move `isJank` and `isSevereJank` policy out of `FrameStats` if needed, so `FrameStats` stays raw measurement rather than policy.

Fallback path:

- If a config field is not going to be honored, remove it from the public API.

Acceptance criteria:

- Every public config field changes behavior in a real way.
- No detector relies on hidden hardcoded thresholds that contradict config.

Testing:

- Add tests proving threshold changes alter behavior.

## Milestone 4: Deduplicate Detector And Highlight Logic

Problem:

- `_collectHighlights` in `lib/src/controller/watchdog_controller.dart` duplicates detection logic from the detectors.
- That creates drift risk: changing detector rules requires touching two places.

Goal:

- Make detectors the single source of truth for detection conditions.
- Highlight generation should consume detector results, not re-implement detection logic.

Possible implementation paths:

- Extend detector outputs to optionally include highlight metadata.
- Add a lightweight issue-to-highlight mapping layer.
- Introduce a small shared abstraction used by both issue generation and highlight generation.

Performance constraint:

- Deduplication must preserve the current behavior where highlight collection only happens when the overlay/highlights are enabled.
- No new always-on highlight-related tree work should run when the overlay is off.

Acceptance criteria:

- Detection rules for a given issue live in one place.
- Updating a detector does not require reimplementing the same condition in `_collectHighlights`.
- Highlight-related work remains conditional and does not become part of the always-on detector path unless explicitly needed.

Testing:

- Add tests proving highlight behavior stays aligned with detector outputs.

## Milestone 4.5: Detector Registry

Problem:

- Detector metadata and behavior are currently spread across detector classes, controller logic, UI assumptions, and documentation.

Goal:

- Introduce a single source of truth for detector metadata and operational behavior.

Each detector should declare in one place:

- detector id/type
- display name
- category
- lifecycle classification
- default enabled state
- confidence basis
- fallback behavior
- whether it can produce highlights

Lifecycle classification should be explicit, for example:

- runtime
- treeScan
- vmDependent
- debugInstrumentation

Benefits:

- makes the degradation contract mechanically enforceable
- supports a clearer "which detectors are active" UI
- reduces metadata drift across controller, UI, and docs
- complements Milestone 4 deduplication work

Acceptance criteria:

- Detector metadata is no longer duplicated across multiple framework layers without a single source of truth.
- Lifecycle classification is declared per detector and consumed by controller/UI logic.
- Fallback behavior is defined per detector in a structured way.

Testing:

- Add tests covering detector registration metadata and lifecycle/fallback behavior where practical.

## Milestone 5: Detector Confidence Cleanup And Renaming

### RebuildDetector

File: `lib/src/detectors/rebuild_detector.dart`

- Keep VM-derived high rebuild activity as a real signal.
- Remove "Top rebuilding widget" unless there is direct rebuild instrumentation.
- If keeping extra widget context, label it explicitly as heuristic or screen context rather than rebuild attribution.
- Recommended replacement wording:
  - "High rebuild activity: N builds/sec"
  - "Most common StatefulWidget on screen: X" as context only, not direct rebuild attribution
- Confidence should be:
  - `Confirmed` for elevated rebuild count only
  - `Likely` or `Possible` for any suspected cause text

### MediaQueryRebuildDetector

File: `lib/src/detectors/media_query_rebuild_detector.dart`

Current issue:

- The detector does not observe `MediaQuery.of()` usage.
- The name makes a causal claim the code cannot support.

Short-term path:

- Rename it to something honest, such as `ShallowRebuildRiskDetector`.
- Or disable it by default until it has a better basis.

Do not keep the current name with only a confidence downgrade.

### GpuPressureDetector

File: `lib/src/detectors/gpu_pressure_detector.dart`

- Split the message into:
  - observed runtime signal: raster slower than UI
  - heuristic cause: expensive render nodes found in tree
- Confidence rules:
  - `Confirmed` only for raster dominance itself
  - `Likely` if raster dominance plus suspicious nodes coexist
  - `Possible` for suspicious nodes without raster pressure

### OpacityDetector

File: `lib/src/detectors/opacity_detector.dart`

Current issue:

- `Opacity(opacity: 0.0)` is not a valid paint-cost warning as currently described.

Required change:

- Remove the GPU-waste framing.
- Either:
  - repurpose it into a correctness/accessibility hint
  - or disable/remove it from performance defaults

If repurposed, it should focus on:

- invisible widgets still participating in hit testing
- invisible widgets still occupying layout
- invisible widgets still participating in semantics

### General detector rules

- Observed fact first
- Suspected cause second
- Fix hints should match what the detector can truly infer

Acceptance criteria:

- No detector marked `Confirmed` is making a causal claim it cannot support.
- Detector names match the data they actually observe.
- The `Opacity` detector no longer claims `opacity: 0.0` wastes GPU work.

Testing:

- Each detector fix ships with its corresponding test changes.

## Milestone 5.5: FRAME Mode Verdict Path Cleanup

Problem:

- `analyzeBasicMode()` in `lib/src/analyzer/render_pipeline_analyzer.dart` is currently unused.
- `lib/src/controller/watchdog_controller.dart` builds a manual fallback FRAME mode verdict instead of using the analyzer path.

Required decision:

- Either wire `analyzeBasicMode()` into FRAME mode verdict generation
- Or remove `analyzeBasicMode()` and keep the controller-owned fallback path as the single implementation

Acceptance criteria:

- There is only one authoritative implementation for FRAME mode verdict generation.
- No dead analysis path remains in the codebase.

Testing:

- Add tests for the chosen FRAME mode verdict path.

## Milestone 6: Interleaved Test Expansion

Testing should not be a final cleanup phase. It should happen with each milestone.

Current gap:

- Most detectors have zero tests.

Policy:

- Every detector touched in Milestone 5 must gain or update tests in the same change.
- Every config behavior change in Milestone 3 must have tests.
- Every memory rename/behavior change in Milestone 2 must have tests.

Priority areas:

- `rebuild_detector.dart`
- `media_query_rebuild_detector.dart`
- `gpu_pressure_detector.dart`
- `memory_leak_detector.dart`
- highlight behavior in `watchdog_controller.dart`

Acceptance criteria:

- Tests verify diagnosis quality and wording, not only that an issue exists.
- Negative tests exist for the false positives being fixed.

## Milestone 7: Minimal Schema Improvement

The original schema expansion was too heavy for v1.

Only consider adding:

- `verificationHint`
- `routeName`
- `interactionContext`

to `PerformanceIssue` if it materially improves the UI and docs.

Do not add a large set of new fields unless there is a clear need from actual detectors and UI.

Acceptance criteria:

- Any new field added to `PerformanceIssue` is used by multiple detectors and the UI.
- No schema changes are made "for future flexibility" alone.
- If `routeName` and `interactionContext` are added, they should support later ranking/export work without requiring a breaking schema migration.

### Completed: `routeName` and `stableId`

**`routeName`** (`String?`) — Added. Stamped automatically by `_aggregateIssues()` via `ModalRoute.of(_lastScanContext)`. Used by all 20 detectors (auto-stamped) and displayed in expanded `IssueCard`. `_lastScanContext` is the last visible-page context from `_findVisiblePageContext()`, not the overlay context. Cleared during route transitions to avoid stale stamps. For VM-only issues, routeName reflects the last scanned page (best-effort).

**`stableId`** (`String?`) — Added. A stable identifier per issue type (e.g. `'gc_pressure'`, `'sustained_jank'`, `'non_lazy_list'`) that does not change when dynamic values in the title update. All 20 detectors (27 constructors) provide a stableId. Used by the dashboard UI to preserve expansion and checkbox state across scan cycles. **`verificationHint`** and **`interactionContext`** — Deferred. `fixHint` + `detail` already cover verification guidance. `interactionContext` requires an interaction tracking subsystem that does not exist.

### Dashboard UI State Persistence

Issue cards in the dashboard must preserve expansion and checkbox state despite frequent list rebuilds from the scan timer, frame callbacks, and parent widget rebuilds.

**Design decisions:**

1. **`IssueCard` is a `StatefulWidget`** — Internal `_expanded` state survives parent rebuilds. The parent passes `initiallyExpanded` (read once in `initState`); after creation the card owns its expansion. This decouples expansion from the parent rebuild cycle.

2. **`ValueKey(stableId)` on each card** — Flutter matches cards by key, not list position. When the ListView rebuilds, the same `_IssueCardState` is reused for each stableId. Internal `_expanded` survives.

3. **`_expandedIssueIds` set in parent** — Backup for when a card is destroyed (issue disappears from list) and later recreated. Updated via `onExpandedChanged` callback without calling `setState` on the parent (avoids triggering another rebuild cycle).

4. **No `_issuesEqual` guard needed** — `_aggregateIssues()` fires on every scan timer tick and timeline callback, always updating `issuesNotifier`. This ensures live counters in titles (e.g. "45 GC/min" → "52 GC/min") reach the UI immediately. Expansion state survives these rebuilds because `IssueCard` is a `StatefulWidget` with `ValueKey(stableId)` — Flutter reuses the same `_IssueCardState` across list rebuilds, so internal `_expanded` is never reset. An earlier `_issuesEqual` guard was removed because it suppressed title updates.

5. **`_selectedIssueId` tracks checkbox by stableId** — Previously matched by category, which checked multiple issues at once. Now tracks the specific issue's stableId.

## Advanced Profiling: Frame Correlation ✅

**Implemented.** Per-frame event correlation matches VM timeline events to specific
frames using monotonic timestamp overlap, solving the batch attribution error where
500ms of events were attributed to a single frame.

Key components:
- `PhaseEvent` model with absolute timestamps from VM timeline
- `FrameEventCorrelator` matches events to frames via build/raster time windows
- `analyzeCorrelatedMode()` produces per-frame verdicts with confidence wording
- Three-tier degradation: Correlated → Legacy full → Basic
- Fallback to legacy `analyzeFullMode()` when correlation fails or is untrustworthy

Implementation outline:

- Capture raw per-frame timing boundaries from `FrameTiming`.
- Retain raw VM timeline events with timestamps, not only aggregated batch totals.
- Correlate timeline events to frame windows by timestamp overlap.
- Only use stronger wording when correlation coverage is good enough.

Files:

- `lib/src/detectors/frame_timing_detector.dart`
- `lib/src/vm/timeline_parser.dart`
- `lib/src/vm/vm_service_client.dart`
- `lib/src/controller/watchdog_controller.dart`
- `lib/src/analyzer/render_pipeline_analyzer.dart`

Acceptance criteria:

- A verdict is attached to a specific frame by correlated timestamps, not just recent batch timing.
- The analyzer can downgrade confidence when event coverage is incomplete.
- The README may then say "precise per-frame phase attribution in full mode".

Testing:

- Add synthetic frame/timeline correlation tests with exact expected attribution.

## Advanced Profiling: Debug Instrumentation Strategy (implemented)

Goal:

- Make debug mode genuinely useful for attribution without pretending it reflects real runtime cost.
- Use lightweight debug callbacks by default in debug mode.
- Put heavier profiling flags behind an explicit opt-in toggle.

### Debug callback installation — opt-in (revised)

**Original plan**: Enable lightweight hooks (`debugOnRebuildDirtyWidget`, `debugOnProfilePaint`) automatically when `kDebugMode` is true.

**Revised design**: Callbacks are **opt-in** via `WatchdogConfig.enableDebugCallbacks` (default `false`).

**Reason**: Flutter's `WidgetInspectorService` asserts debug callback globals are `null` before installing its own handlers (verified at `widget_inspector.dart:1114`). Auto-enabling would prevent DevTools "Track Widget Rebuilds" / "Track Repaint Widgets" from working. The service extension handler's try-catch prevents app crashes, but DevTools features fail silently.

**Installation policy**: Each callback slot is checked independently. If one is already occupied (e.g. by DevTools), it is skipped with a log warning; the other can still be installed.

**Paint attribution scope**: `debugOnProfilePaint` provides a `RenderObject`. Per-widget paint attribution is extracted via `renderObject.debugCreator` → `DebugCreator.element.widget.runtimeType`, the same technique DevTools uses. The `DebugSnapshot.paintCounts` map provides per-type paint counts alongside the aggregate `totalPaintCount`.

Expected behavior:

- Keep `FrameTiming` as the baseline runtime signal.
- Use `debugOnRebuildDirtyWidget` to improve per-widget-type rebuild attribution and explanation quality.
- Use `debugOnProfilePaint` for aggregate repaint activity detection only.
- Label debug-derived evidence clearly in the UI via `ObservationSource` enum on `PerformanceIssue`.

UI wording requirement:

- Distinguish observation sources: `structural scan`, `VM timeline`, `debug callback`, `debug callback + structural`.

SDK verification requirement:

- Verify callback availability and signature against the package's minimum supported Flutter SDK (`>=3.24.0`) before committing to this milestone.
- Current official API docs show:
  - `RebuildDirtyWidgetCallback = void Function(Element e, bool builtOnce)`
  - `ProfilePaintCallback = void Function(RenderObject renderObject)`
- If either callback is not available or stable in Flutter `3.24.0`, bump the minimum Flutter SDK constraint.
- Do not add runtime capability checks for these globals. This should be resolved through the declared Flutter SDK range.

### Heavy profiling flags

Expose a clearly labeled opt-in toggle for heavier debug instrumentation, for example:

- `Deep Debug Instrumentation`
- `Inspection Mode`

This toggle should only be available in debug mode.

Recommended initial flag order:

1. `debugProfileBuildsEnabledUserWidgets`
2. `debugProfileLayoutsEnabled`
3. `debugProfilePaintsEnabled`

Optional later enrichments:

- `debugEnhanceBuildTimelineArguments`
- `debugEnhanceLayoutTimelineArguments`
- `debugEnhancePaintTimelineArguments`

### Rules for heavy instrumentation

- Heavy flags are off by default.
- Enabling them must show a clear warning in the UI.
- When heavy flags are enabled:
  - attribution claims may become stronger
  - timing claims must become weaker

Required warning text concept:

- Widget/layout/paint instrumentation is enabled.
- Counts and traces are useful for attribution.
- Timings are not representative of real performance because instrumentation adds overhead.

### Detector behavior under heavy instrumentation

- Rebuild-related detectors may use instrumented widget rebuild counts.
- Paint-related detectors may use instrumented paint callbacks/events.
- The package must not present instrumented timings as profile-equivalent performance measurements.

### Performance constraints for debug callbacks

- `debugOnRebuildDirtyWidget` can fire for every dirty widget rebuild in debug mode.
- `debugOnProfilePaint` can fire for every painted `RenderObject`.
- Aggregation must be allocation-light and O(1) per callback:
  - increment counters in existing maps keyed by widget/render-object type
  - avoid per-callback object allocation where possible
  - avoid storing full element/render-object histories unless explicitly sampled
- Callback handlers must not trigger additional tree walks.
- Any rolling history built from these callbacks should use bounded ring buffers.

### Config model

Use a two-tier config model:

- simple top-level switches for the common path
- a structured expert `advanced` block for profiler-framework users

Recommended shape:

- top-level:
  - `enableDebugCallbacks` (opt-in, default false — see revised installation policy above)
  - `enableDeepDebugInstrumentation`
  - `maxTrackedTypes`
- expert refinement under an `advanced` block, expressed as profiler intent rather than raw Flutter globals

Examples of expert controls:

- rebuild attribution
- paint attribution
- widget build profiling
- layout profiling
- paint profiling
- timeline enrichment

Design rules:

- The primary API should not read like a direct passthrough of Flutter debug globals.
- Advanced controls are for power users and should be documented with overhead and fidelity tradeoffs.
- The top-level switches are the authoritative controls.
- Advanced sub-flags only refine behavior when their parent switch is enabled.

Parent-switch precedence:

- If `enableDebugCallbacks` is `false`, attribution-related advanced flags are ignored.
- If `enableDeepDebugInstrumentation` is `false`, deep instrumentation advanced flags are ignored.
- Contradictory config states must resolve in favor of the parent top-level switch.

Acceptance criteria:

- When lightweight callbacks are enabled, debug mode becomes more useful through per-widget attribution without additional user effort.
- Heavy instrumentation is explicit, opt-in, and clearly explained.
- UI distinguishes attribution quality from timing fidelity.
- Debug callback aggregation is implemented efficiently enough to avoid making debug mode noticeably worse through avoidable package overhead.
- The config model supports both simple adoption and expert refinement without exposing raw framework internals as the primary API.
- Parent top-level switches always take precedence over advanced sub-flags.

### Implementation summary

**Config model** (`lib/src/debug/debug_instrumentation_config.dart`): New `DebugInstrumentationConfig` class with 6 sub-flags (`rebuildAttribution`, `paintAttribution`, `widgetBuildProfiling`, `layoutProfiling`, `paintProfiling`, `timelineEnrichment`). Exposed as `WatchdogConfig.advanced`. Barrel-exported from `lib/widget_watchdog.dart`.

**Selective install** (`lib/src/debug/debug_instrumentation_coordinator.dart`): Added `installRebuild` and `installPaint` constructor params. `install()` checks these before attempting slot installation, allowing partial install (e.g. paint-only when rebuild attribution sub-flag is off).

**Two independent parent switches** (`lib/src/controller/watchdog_controller.dart`): `enableDebugCallbacks` and `enableDeepDebugInstrumentation` are evaluated in separate `if` blocks inside `_installDebugInstrumentation()`, fixing a pre-existing bug where deep instrumentation was nested inside the callbacks check and silently did nothing without callbacks enabled. Both `initialize()` and `initializeDetectorsForTest()` call the shared `_installDebugInstrumentation()` method, closing a test-path discrepancy where the test path silently skipped heavy flags.

**Heavy flag save/restore**: `_installHeavyFlags()` saves and overrides 6 Flutter debug globals (`debugProfileBuildsEnabledUserWidgets`, `debugProfileLayoutsEnabled`, `debugProfilePaintsEnabled`, `debugEnhanceBuildTimelineArguments`, `debugEnhanceLayoutTimelineArguments`, `debugEnhancePaintTimelineArguments`). `_restoreHeavyFlags()` restores originals on dispose. All wrapped in assert blocks.

**Resolved state getter**: `isDeepInstrumentationActive` checks actual `_prev*` fields (not raw config), so `enableDeepDebugInstrumentation=true` with all sub-flags off correctly returns `false`.

**UI surface** (`lib/src/ui/dashboard_sheet.dart`, `lib/src/ui/issue_card.dart`): Purple instrumentation warning banner when `isDeepInstrumentationActive`. Fidelity annotation on `IssueCard` ("Attribution: high fidelity" + "Timing: overhead present") when deep instrumentation is active and the issue's `observationSource` is `debugCallback` or `debugCallbackAndStructural`.

**ObservationSource tagging**: All 12 structural and VM-timeline detectors now set `observationSource` on every `PerformanceIssue` constructor (8 structural, 4 vmTimeline). The 4 debug-callback-aware detectors (RepaintDetector, ShallowRebuildRiskDetector, AnimatedBuilderDetector, CustomPainterDetector) already set source dynamically from expansion #2.

**Tests**: 42 new tests/assertions across 4 new test files (`debug_instrumentation_config_test.dart`, `instrumentation_warning_test.dart`) and updates to existing test files (coordinator, wiring, 12 detector test files). Total suite: 480 tests, 0 analysis issues.

Testing:

- Add debug-only tests for instrumentation-enabled detector behavior where practical.
- Add unit tests for toggle/config behavior and warning-state propagation.
- Add dedicated chaining/restore tests for debug globals:
  - user callback installed -> coordinator installed -> both fire
  - coordinator disposed -> user callback still works
- Add restore-order tests for nested installs to guard against lifecycle corruption in tests/hot reload scenarios.

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

**Cross-cutting migration**: 8 production `totalDuration` sites across 5 files migrated to `effectiveTotalDuration`: `frame_chart.dart` (bar height + color thresholds + budget line), `frame_timing_detector.dart` (2 worst-frame selections), `capture_buffer.dart` (3 eviction comparisons), `watchdog_controller.dart` (worstFrameTimeUs).

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

**Controller wiring** (`lib/src/controller/watchdog_controller.dart`): Debug snapshot distribution block expanded to include `_shallowRebuildRisk`, `_animatedBuilder`, and `_customPainter`.

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

**JankCaptureBuffer** (`lib/src/models/capture_buffer.dart`): Bounded "worst N" buffer (default capacity 50, configurable via `WatchdogConfig.captureBufferCapacity`). When full, evicts the mildest entry by `totalDuration`. New entries milder than all existing ones are rejected. Not a FIFO ring buffer — retains the worst frames across the session.

**CaptureEntry**: Bundles `FrameStats` + `FrameVerdict` + separately-stamped `relatedIssues` + `capturedAt`. The `relatedIssues` list is populated from `issuesNotifier.value` (post-aggregation, with route/context tags), NOT from `verdict.relatedIssues` (which are unstamped). `toJson()` strips `verdict.relatedIssues` to avoid conflicting issue lists in the export; the entry-level `relatedIssues` is canonical.

**Capture paths** (in `watchdog_controller.dart`): Two mutually exclusive paths feed the buffer. `_onTimelineData` (full VM mode) uses local variables to bridge the jank decision past `_aggregateIssues()` for stamped issues. `_onFrameStats` (basic/FRAME mode) captures inside the existing jank guard using the most recently stamped `issuesNotifier.value`. A `_lastCapturedFrameNumber` guard prevents duplicate captures.

**SessionSnapshot** (`lib/src/models/session_snapshot.dart`): Top-level export container with `capturedFrames`, `currentIssues`, `frameStatsSummary` (totalFrames, jankFrames, averageFps, worstFrameTimeUs), plus metadata (packageVersion, isVmConnected, isDebugMode, exportedAt). `toJsonString()` produces pretty-printed JSON with 2-space indent.

**Public API**: `WidgetWatchdog.exportSnapshot()` and `WidgetWatchdog.exportSnapshotJson()` static methods. Return `null` before `wrap()`, after overlay disposal, and in release mode. A static `_controller` reference is set in `wrap()` and cleared in `notifyControllerDisposed()` (called by `WatchdogOverlay.dispose()`) with an identity check to handle repeated `wrap()` calls. `currentIssues` in the snapshot is wrapped with `List.unmodifiable()` for defensive immutability.

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

Narrow the gap between Widget Watchdog and DevTools in four areas where DevTools has clear superiority, while staying true to the package's core value: **developers fast know what affects their app's performance, with zero setup.**

Mini flame chart is explicitly out of scope — it adds visualization complexity that competes with DevTools rather than complementing it. Widget Watchdog answers "what's wrong?" not "show me the raw timeline."

### Scope

| Feature | New Detector? | VM Required? | Release Safe? | Priority |
|---------|:---:|:---:|:---:|:---:|
| Network monitoring | Yes (21st) | No | Yes | #1 — **Done** |
| Heap trend monitoring | No (enhances MemoryPressure) | Yes | No | #2 — **Done** |
| Jank CPU attribution | No (enhances FrameVerdict) | Yes | No | #3 — **Done** |
| Source location enrichment | No (enhances ancestorChain) | No | No (debug only) | #4 |

### Design Principle

Each feature must produce **issues with actionable fix hints** that fit the existing detector framework. No raw data dumps, no "explore this yourself" UX. The developer glances at the overlay, sees "Slow API: GET /users — 3.2s" or "Heap Growing: +12MB in 30s", and knows what to fix.

---

### v2.1: Network Monitoring — **Done**

**Problem:**

Slow, excessive, or large HTTP requests are a top cause of perceived jank and memory pressure, but Widget Watchdog has no visibility into network activity. This is the only DevTools gap that can be closed with zero VM dependency and full release-mode safety.

**Approach:**

Install a chaining `HttpOverrides.global` in `WatchdogController.initialize()` that wraps every `dart:io HttpClient` with a monitoring proxy. The proxy records request timing, response status, and payload size without modifying behavior.

**Design decisions:**

1. **Chaining, not replacing.** Read `HttpOverrides.current` before installing. The watchdog override delegates `createHttpClient()` to the previous override (or `super`), then wraps the returned client. This preserves certificate pinning, proxy configuration, and other custom overrides the app may have installed.

2. **Opt-out, not opt-in.** Network monitoring is enabled by default (`WatchdogConfig.enableNetworkMonitoring: true`) for zero-config alignment. Users can disable it or add URL exclusion patterns.

3. **No body capture.** Only record timing, status, URL, method, response size. Never capture request/response bodies — avoids memory pressure from large payloads and eliminates security concerns about logging sensitive data.

4. **Release mode guard.** `HttpOverrides.global` works in all build modes, but Widget Watchdog is `kReleaseMode`-guarded in `wrap()`. Network monitoring follows the same guard — active only in debug/profile mode.

5. **Bounded record storage.** Request records stored in a ring buffer (default 200 entries). Old records evicted FIFO. No unbounded growth.

6. **Issue lifecycle: buffer-derived.** On each new record, `_issues` is cleared and re-evaluated from the current ring buffer contents. Slow/large issues are derived from records currently in the buffer. Frequency is computed by counting records in the last 5s window. Issues naturally disappear as records age out of the buffer. This matches the existing detector pattern where `_issues.clear()` precedes re-evaluation.

7. **Override restoration on dispose.** When `WatchdogController.dispose()` is called, restore `HttpOverrides.global` to the previous override captured during install. Only restore if the current override is still the watchdog's instance — another package may have overwritten it since install. Store the previous override reference for identity comparison.

8. **Delegate pattern for HttpClient wrapping.** `_MonitoringHttpClient` delegates all `HttpClient` methods to the real client. Only `openUrl()` is intercepted to wrap the returned `HttpClientRequest` with timing instrumentation. Response body size is measured via stream byte counting (a `StreamTransformer` that counts bytes as they pass through), not body buffering — this preserves streaming behavior and adds negligible overhead.

9. **Frequency timer lifecycle.** A 5-second periodic timer drives frequency evaluation. Created in the detector's constructor (or on first record), cancelled in `dispose()`. Follows the same lifecycle pattern as the existing scan timer in `WatchdogController`.

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
   WatchdogHttpOverrides (chaining proxy)
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

New fields on `WatchdogConfig`:

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
| `lib/src/network/http_monitor.dart` | **Create** — `WatchdogHttpOverrides`, chaining logic, `_MonitoringHttpClient` proxy |
| `lib/src/network/request_record.dart` | **Create** — lightweight record with `toJson()` |
| `lib/src/detectors/network_monitor_detector.dart` | **Create** — processes records, produces issues, frequency windowing |
| `lib/src/models/base_detector.dart` | **Edit** — add `DetectorType.networkMonitor` |
| `lib/src/models/performance_issue.dart` | **Edit** — add `IssueCategory.network` |
| `lib/src/controller/watchdog_controller.dart` | **Edit** — instantiate detector, install HttpOverrides in `initialize()`, wire record callbacks |
| `lib/widget_watchdog.dart` | **Edit** — export new public types |
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

- **User sets `HttpOverrides.global` after `wrap()`:** Watchdog override is lost. Document: call `WidgetWatchdog.wrap()` after any custom `HttpOverrides.global` setup, or set custom overrides before `wrap()` so chaining captures them.
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

4. **`_networkMonitor` is nullable, not `late final`.** `WatchdogController` uses `NetworkMonitorDetector?` to handle the case where `exportSnapshot()` is called before `initialize()`. All access sites use null-safe operators.

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

When Widget Watchdog reports a jank frame ("32ms — build phase dominant"), the developer doesn't know *which code* was expensive. DevTools answers this with a full flame chart, but Widget Watchdog can answer it more directly and actionably: "Top functions: `MyWidget.build` (40%), `jsonDecode` (25%)."

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
- `RenderPipelineAnalyzer` or `WatchdogController` queries CPU samples during jank verdict generation. Preferred location: controller (keeps analyzer pure/testable with injected data).
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
| `lib/src/controller/watchdog_controller.dart` | **Edit** — query CPU samples on jank, inject into verdict |
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

### v2.4: Source Location Enrichment

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

---

### v2 Config Changes Summary

New fields on `WatchdogConfig`:

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

- **Heap snapshots & object graph**: DevTools can browse every object in the heap, inspect retention paths, and track individual allocations. Widget Watchdog monitors heap trends and GC pressure but cannot drill into specific objects.
- **Full flame chart & call tree**: DevTools provides zoomable, interactive per-frame timelines with complete call tree visualization. Widget Watchdog shows phase breakdowns with top-5 function attribution per jank frame.

The following are **no longer DevTools-only advantages**:
- ~~Network inspection~~ → Watchdog monitors HTTP timing, frequency, and response size automatically.
- ~~Memory inspection~~ → Watchdog tracks heap usage trends and capacity thresholds.
- ~~CPU profiling~~ → Watchdog attributes jank frames to top functions by CPU sample analysis.
- ~~Widget-exact attribution~~ → Watchdog provides source file:line in debug mode via `getCreationLocation`.

### v2 Implementation Order

1. **v2.1 Network Monitoring** — highest value, no VM dependency, most user-visible improvement
2. **v2.4 Source Location** — quick win, low effort, immediate developer value in debug mode
3. **v2.2 Heap Trend** — enhances existing detector, moderate effort, strong signal
4. **v2.3 Jank CPU Attribution** — highest complexity, requires careful VM integration and filtering

Each feature ships with: tests, example demo update, CHANGELOG entry, README update, and detector matrix update.
