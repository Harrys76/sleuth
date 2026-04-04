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

