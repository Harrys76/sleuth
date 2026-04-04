## v0.4.0 Post-Implementation Notes

v0.4.0 implements v3.1 (7 detection accuracy fixes) and v3.9 (FrameEventCorrelator binary search optimization). 849 tests passing (up from 828), 0 analysis issues. No breaking API changes.

### Implementation Summary

| Item | Status | New Tests | Spec Deviations |
|------|:------:|:---------:|:---------------:|
| v3.1.1 AnimatedBuilder threshold + corroboration | Done | 4 | 1 |
| v3.1.2 CustomPainter secondary heuristic | Done | 2 | 1 |
| v3.1.3 MemoryPressure warmup exclusion | Done | 4 | 0 |
| v3.1.4 NestedScroll cross-axis suppression | Done | 4 | 1 |
| v3.1.5 Opacity threshold `< 0.01` | Done | 3 | 0 |
| v3.1.6 GpuPressure structural issue preservation | Done | 2 | 0 |
| v3.1.7 PlatformChannel duration tracking | Done | 4 | 0 |
| v3.9 FrameEventCorrelator binary search | Done | 1 | 2 |
| **Total** | **8/8** | **24** | **5** |

### Spec Deviations

All deviations are simplifications that produce better or equivalent results with less complexity.

#### 1. v3.1.1 — Corroboration source changed

**Spec:** Require corroboration from RepaintDetector (paint rate > 30/sec on same widget type).
**Actual:** Uses DebugSnapshot `rebuildsPerSecond('AnimatedBuilder')` instead. RepaintDetector tracks types at a coarser level and isn't directly accessible from AnimatedBuilderDetector (hub architecture prevents inter-detector access). DebugSnapshot is already piped to the detector via `updateDebugSnapshot()` and provides widget-type-specific rebuild rates.
**Impact:** Better — uses existing data flow, no architectural coupling. Same confidence outcome.

#### 2. v3.1.2 — Self-comparison kept, secondary heuristic added

**Spec:** Replace self-comparison test with a second instance or reflection-based check.
**Actual:** Kept self-comparison (correctly catches `=> true` pattern). Added a secondary heuristic: when no always-true painters are found but DebugSnapshot shows CustomPaint paint rate > 30/sec, emit a `frequent_repaint_painter` warning at `possible` confidence. Uses `IssueSeverity.warning` (not `info` — enum doesn't include `info`).
**Impact:** Simpler and more robust. The self-comparison correctly flags the `=> true` pattern without requiring reflection or second-instance creation (both fragile). The secondary heuristic catches the remaining class of problematic painters via runtime evidence.

#### 3. v3.1.4 — Cross-axis always suppressed

**Spec:** Cross-axis nesting should flag when `NeverScrollableScrollPhysics` is NOT applied (both axes live-scrollable → gesture conflict).
**Actual:** Cross-axis nesting is always suppressed. The spec's acceptance criteria ("Horizontal ListView inside vertical ScrollView → no issue") uses default physics (AlwaysScrollableScrollPhysics), which would be flagged under the spec's rule. The acceptance criteria contradicts the rule.
**Impact:** The simpler rule matches the acceptance criteria exactly and avoids false positives on the most common cross-axis pattern. Gesture conflicts in cross-axis nesting are rare and better caught by user testing than static analysis.

#### 4. v3.9 — Separate UI/raster sorted lists instead of single tuple list

**Spec:** Build a sorted list of `(buildStartUs, rasterFinishUs, frameIndex)` tuples and binary search on `buildStartUs`.
**Actual:** Two separate sorted lists: `uiSorted` (by `buildStartUs`) and `rasterSorted` (by `rasterStartUs`). UI-thread events search `uiSorted`, raster-thread events search `rasterSorted`.
**Impact:** Better — a single sorted list by `buildStartUs` cannot efficiently search raster windows (which may be in different order). Separate lists give O(log F) for both thread types with correct matching.

#### 5. v3.9 — Cross-frame event splitting not implemented

**Spec:** If an event's duration spans two frame boundaries, assign proportionally by time overlap.
**Actual:** Not implemented — events are assigned to the first matching frame (same as original linear scan). This maintains exact behavioral equivalence with the original implementation.
**Impact:** Low — cross-frame events are rare in practice (events are typically much shorter than frame windows). Implementing proportional splitting would change the output and is better done as a separate follow-up with its own tests.

### WatchdogConfig Additions

Two new optional fields with sensible defaults:

| Field | Default | Used By |
|-------|---------|---------|
| `memoryWarmupDurationMs` | `5000` | `MemoryPressureDetector` — suppresses heap trend alerts during first N ms |
| `platformChannelDurationThresholdMs` | `8` | `PlatformChannelDetector` — cumulative duration threshold per window |

### Test Helper Changes

`platformChannelData()` in `test/helpers/timeline_test_helpers.dart` gained two optional params: `durUs` (per-event duration, default 100) and `methodName` (event name, default `'PlatformChannel'`). Existing test callsites unchanged (use defaults).

---

## v3.3 Post-Implementation Notes

v3.3 implements Issue-to-Verdict Linking — three UI additions that connect the Live tab's jank verdicts to the Issues tab. 863 tests passing (up from 849), 0 analysis issues. No model or controller changes needed.

### Implementation Summary

| Item | Status | New Tests | Spec Deviations |
|------|:------:|:---------:|:---------------:|
| Jank banner on Live tab | Done | 7 | 0 |
| "JANK" badge on issue cards | Done | 4 | 0 |
| Issue flash on banner tap | Done | 3 | 0 |
| **Total** | **3/3** | **14** | **0** |

### Design Decisions

#### 1. Jank detection from verdict

Verdicts are only created for jank frames (controller guards: `latest.isJank` at lines 838, 765, 793 of `watchdog_controller.dart`). Any non-null verdict with `relatedIssues.isNotEmpty` is a jank-with-issues verdict. No separate "isJank" field needed on `FrameVerdict`.

#### 2. Issue matching by intersection

The verdict's `relatedIssues` are populated from `_getAllIssues()` (pre-stamp). The `issuesNotifier` holds the stamped/ranked version. Matching uses `stableId ?? title` — the same key already used for expansion persistence and highlight selection. An intersection with `issuesNotifier.value` handles staleness when issues are removed between verdict creation and UI render.

#### 3. Flash vs badge — two separate concerns

- **"JANK" badge** (`jankCorrelated` param): persistent indicator on issue cards in the current verdict's `relatedIssues`. Driven by `verdictNotifier` via `ValueListenableBuilder`.
- **Flash** (`jankFlash` param): temporary 2-second amber tint when the user taps the banner. Driven by `_jankFlashIds` state + `Future.delayed` with `mounted` guard. Same pattern as `_exportFeedbackVisible`.

#### 4. Card background precedence

`jankFlash` (amber `0xFF5F2D1E`) > `highlighted` (blue `0xFF1E3A5F`, widget-locate) > normal (gray `0xFF374151`). Flash is transient and meant to draw attention, so it takes priority.

### Files Changed

| File | Change |
|------|--------|
| `lib/src/ui/issue_card.dart` | Added `jankCorrelated` and `jankFlash` params (default `false`); three-way card color; "JANK" badge in collapsed header row |
| `lib/src/ui/dashboard_sheet.dart` | Added `_jankFlashIds` state, `_matchingIssueKeys()` helper, `_onJankBannerTap()` handler; jank banner in Live tab; `ValueListenableBuilder<FrameVerdict?>` wrapping Issues tab list |
| `test/ui/jank_verdict_linking_test.dart` | New file — 14 widget tests across 4 groups (banner visibility, tap behavior, badge rendering, edge cases) |

No changes to: models, controller, detectors, barrel file, config.

---

## v3.8 Post-Implementation Notes

v3.8 implements Overlay UX Improvements — six targeted UI enhancements that improve the diagnostic workflow. 877 tests passing (up from 863), 0 analysis issues. No model, detector, or controller changes needed.

### Implementation Summary

| Item | Status | New Tests | Spec Deviations |
|------|:------:|:---------:|:---------------:|
| 3.8.1 Widget name before ancestor chain | Done | 3 | 0 |
| 3.8.2 Highlight not-found feedback | Done | 2 | 1 (see below) |
| 3.8.3 Interaction context filter | Done | 3 | 0 |
| 3.8.4 "About this detection" section | Done | 2 | 0 |
| 3.8.5 Effort indicators on fix hints | Done | 3 | 0 |
| 3.8.6 Color legend in Guide tab | Done | 1 | 0 |
| **Total** | **6/6** | **14** | **1** |

### Design Decisions

#### 1. Banner instead of SnackBar for highlight not-found (3.8.2)

Spec called for a SnackBar, but `DashboardSheet` is hosted inside a `Material` widget, not a `Scaffold`. `ScaffoldMessenger` requires `Scaffold` ancestry to display SnackBars. Instead, used the same temporary-banner pattern as `_exportFeedbackVisible` and `_jankFlashIds`: amber-tinted `Container` with `Future.delayed(3s)` + `mounted` guard for auto-clear. This is the only spec deviation.

#### 2. UI-layer effort inference (3.8.5)

Spec said "effort is determined per-detector, not computed." Adding an `effortLevel` field to `PerformanceIssue` would require touching all 21 detector files — disproportionate for a UX improvement. Instead, `_fixEffort()` infers effort from `fixHint` keyword patterns at the UI layer:

- **Quick:** `const constructor`, `cacheWidth`, `ListView.builder`, `RepaintBoundary`, `Visibility`, `child parameter`, etc.
- **Involved:** `Isolate.run`, `compute()`, `cache-sksl`, `sparse fieldsets`, `GraphQL`, `growing steadily`, etc.
- **Medium:** Default for everything else.

This is explicitly a bridge solution. v3.2 (Context-Aware Fix Hints) already plans to rewrite all fix hints and will add an explicit `fixEffort` field to the model at that time.

#### 3. Interaction filter semantics (3.8.3)

The "Idle" filter includes issues with `null` `interactionContext`, because most structural and hybrid detectors don't set an interaction context — they fire during normal idle operation. Treating `null` as "Idle" ensures the filter is useful rather than showing an empty list when "Idle" is selected.

Scrolling deprioritization applies a 0.7× multiplier to the recurrence component only (not the full score). A scrolling-context issue with max recurrence 5 gets `(5*0.7).round() = 4` instead of 5, costing ~2 rank points. Subtle enough to distinguish without burying legitimate scroll jank.

#### 4. Text.rich for testability (3.8.4)

The "About this detection" content uses `Text.rich(TextSpan(...))` instead of `RichText(text: TextSpan(...))`. `RichText` creates a `RichText` widget that `find.textContaining()` cannot locate — it only searches `Text` widgets. `Text.rich` creates a `Text` widget with a `TextSpan` tree, making all label/value pairs findable in widget tests.

#### 5. Color legend scope (3.8.6)

The legend covers all visual indicators in the overlay: severity colors, confidence badges (CONFIRMED/LIKELY/POSSIBLE), source accent bars (VM timeline/debug callback/structural), category badges (all 8 categories with matching colors from `issue_card.dart`), and effort badges (QUICK/MEDIUM/INVOLVED). The `_buildGuideTab` method lost its `const` qualifier to accommodate the dynamic legend content.

### Files Changed

| File | Change | Items |
|------|--------|-------|
| `lib/src/ui/issue_card.dart` | Widget name reorder, "About this detection" collapsible, effort badge in fix hint box | 3.8.1, 3.8.4, 3.8.5 |
| `lib/src/ui/dashboard_sheet.dart` | Highlight not-found banner, interaction filter chips + logic, color legend section | 3.8.2, 3.8.3, 3.8.6 |
| `lib/src/ranking/issue_ranker.dart` | 0.7× recurrence multiplier for scrolling-context issues | 3.8.3 |
| `test/ui/overlay_ux_improvements_test.dart` | New file — 14 widget tests across 6 groups | All |
| `test/ui/issue_card_attribution_test.dart` | Updated 3 assertions for "Ancestors:" label change | 3.8.1 |

No changes to: models, controller, detectors, barrel file, config.

### Spec vs. Implementation Corrections

The original spec (v3.8 section above) has minor inaccuracies relative to the implementation:

| Spec | Actual |
|------|--------|
| 3.8.2: "Show a SnackBar" | Temporary banner (no Scaffold ancestor) |
| Files: `issue_card.dart` — items 3.8.1, **3.8.2**, 3.8.4, 3.8.5 | 3.8.2 is in `dashboard_sheet.dart` (highlight checkbox is in the dashboard, not the card) |
| Testing: "10 widget tests" | 14 widget tests (expanded coverage) |

---

## v3.2 Post-Implementation Notes

v3.2 implements Context-Aware Fix Hints — centralizing all fix hint generation into a `FixHintBuilder` utility with explicit effort classification. 974 tests passing (up from 877), 0 analysis issues.

### Implementation Summary

| Item | Status | New Tests | Spec Deviations |
|------|:------:|:---------:|:---------------:|
| `FixEffort` enum + `fixEffort` field on `PerformanceIssue` | Done | 13 | 1 (see below) |
| `FixHintBuilder` utility (28 static methods) | Done | 86 | 0 |
| All 21 detectors migrated to builder calls | Done | 0 (existing 358 pass) | 0 |
| UI `_fixEffort()` updated to prefer model field | Done | 1 | 0 |
| Barrel file export | Done | 0 | 0 |
| **Total** | **5/5** | **97** (+ 2 file updates) | **1** |

### Design Decisions

#### 1. FixEffort as a model field (spec deviation)

The spec said "no model changes needed — `fixHint` remains a String." In practice, the effort classification needs to live on the model for two reasons: (a) the UI's keyword-inference approach from v3.8.5 was always a bridge solution, and (b) consumers of `SessionSnapshot` JSON need effort data without re-parsing hint text. Added `FixEffort?` as a nullable field on `PerformanceIssue` — backward compatible, no existing constructor calls break, JSON without the field deserializes to null.

#### 2. Record return type `(String, FixEffort)`

Each `FixHintBuilder` method returns a Dart 3 positional record. This keeps the hint text and effort classification atomic — detectors destructure with `final (hint, effort) = FixHintBuilder.xxx(...)` and pass both to the `PerformanceIssue` constructor in one step. No risk of mismatched effort/hint pairs.

#### 3. UI keyword fallback preserved

The `_fixEffort()` function in `issue_card.dart` now checks `issue.fixEffort` first (model field from builder). If null (legacy issue deserialized from pre-v0.5.0 JSON), it falls back to the existing keyword-scanning logic from v3.8.5. This ensures backward compatibility for exported snapshots.

#### 4. Context-aware vs. generic fallback

Every builder method that accepts optional context (`widgetName`, `ancestorChain`, `interactionContext`) produces a generic fallback when context is null. The two private helpers `_locationSuffix()` and `_contextPrefix()` standardize the format: " in WidgetName (AncestorChain)" suffix or "In WidgetName (AncestorChain): " prefix. No regression from current behavior when context is unavailable.

#### 5. Effort classification is human-authored, not computed

Each of the 28 builder methods hardcodes its `FixEffort` value based on the actual developer work required. This matches the spec's "human-written per detector" design. The classification is:

- **quick** (12 methods): single-parameter additions, widget swaps, mixin removal
- **medium** (11 methods): widget extraction, boundary additions, profiling-guided changes
- **involved** (5 methods): isolate migration, caching layers, API redesign, shader pipeline

### Files Changed

| File | Change |
|------|--------|
| `lib/src/models/performance_issue.dart` | `FixEffort` enum + nullable `fixEffort` field, toJson/fromJson/copyWith/toString |
| `lib/src/utils/fix_hint_builder.dart` | **New** — 28 static methods + 2 private helpers |
| `lib/src/detectors/*.dart` (21 files) | Import builder, replace hardcoded fixHint strings, set `fixEffort:` from builder |
| `lib/src/ui/issue_card.dart` | `_fixEffort()` checks model field first, keyword fallback for legacy |
| `lib/widget_watchdog.dart` | Export `fix_hint_builder.dart` |
| `test/utils/fix_hint_builder_test.dart` | **New** — 86 tests across 28 groups |
| `test/models/performance_issue_test.dart` | 9 tests in new `fixEffort` group |
| `test/models/serialization_test.dart` | 4 assertions added across existing tests + 1 new test |
| `test/ui/overlay_ux_improvements_test.dart` | 1 test: explicit fixEffort takes precedence over keyword inference |

No changes to: controller, ranking, debug, vm, analyzer, network.

### Spec vs. Implementation Corrections

| Spec | Actual |
|------|--------|
| "No model changes needed" | Added `FixEffort` enum + `fixEffort` field to `PerformanceIssue` (nullable, backward compatible) |
| "~21 tests (one per detector)" | 97 new tests: 86 builder tests + 13 model/serialization tests + 1 UI test |
| Files: "Modified: `performance_issue.dart` (no model changes)" | Model changes required for explicit effort classification |

---

## v3.4 Post-Implementation Notes

v3.4 implements Native Memory Tracking — adding process-level RSS monitoring alongside existing Dart heap polling to detect native memory growth (GPU textures, decoded images, platform channel buffers). 996 tests passing (up from 974), 0 analysis issues.

### Implementation Summary

| Item | Status | New Tests | Spec Deviations |
|------|:------:|:---------:|:---------------:|
| `rssBytes` field + `nativeBytes` getter on `HeapSample` | Done | 8 | 1 (see below) |
| `_readRssBytes()` platform guard in `VmServiceClient` | Done | 0 (runtime-only) | 0 |
| `_evaluateNativeGrowth()` in `MemoryPressureDetector` | Done | 11 | 0 |
| `nativeMemoryGrowth()` in `FixHintBuilder` | Done | 3 | 0 |
| **Total** | **4/4** | **22** | **1** |

### Design Decisions

#### 1. `nativeBytes` as a computed getter, not a stored field (spec deviation)

The spec said "add `rssBytes: int?`, `nativeBytes: int?`" as two stored fields. In practice, `nativeBytes` is always `rssBytes - heapUsage`, so storing it would create a consistency risk (stale value if either input changes). Implemented as a getter instead: `int? get nativeBytes => rssBytes != null ? (rssBytes! - heapUsage).clamp(0, rssBytes!) : null`. The clamp to `[0, rssBytes]` handles the edge case where RSS lags behind a heap expansion (would produce a confusing negative value). `toJson()` still serializes both `rssBytes` and `nativeBytes` for export consumers.

#### 2. try/catch platform guard over `kIsWeb`

The spec said "platform guard" and suggested try/catch. Implemented `_readRssBytes()` as a top-level function with try/catch. This is more robust than a `kIsWeb` check because `ProcessInfo.currentRss` can also fail on Fuchsia or unusual embeddings. Zero cost on success (< 50μs syscall).

#### 3. No session_snapshot.dart changes needed

The spec listed `session_snapshot.dart` as a changed file. In practice, no changes were needed — the existing `heapSamples!.map((s) => s.toJson()).toList()` at line 60 automatically picks up the new `rssBytes` and `nativeBytes` fields from the updated `HeapSample.toJson()`. Conditional serialization (`if (rssBytes != null)`) ensures backward compatibility.

#### 4. Linear regression reuse

`_computeNativeSlopeBytesPerSec()` duplicates the least-squares regression logic from `_computeSlopeBytesPerSec()` with only the Y-axis value changed (`nativeBytes` vs `heapUsage`). Could be refactored to accept a `double Function(HeapSample)` extractor, but for 2 usages the duplication is clearer and avoids premature abstraction.

#### 5. Reuses existing thresholds and constants

Native growth detection reuses `_sustainedGrowthDurationSec = 10` and `warmupDurationMs` from the heap trend evaluator. Only the slope threshold differs: 1MB/sec for native (vs 500KB/sec for heap). No new `WatchdogConfig` knob added — can be added later if users request configurability.

### Files Changed

| File | Change |
|------|--------|
| `lib/src/models/heap_sample.dart` | `rssBytes: int?` field, `nativeBytes` computed getter, conditional `toJson` |
| `lib/src/vm/vm_service_client.dart` | `dart:io` import, `_readRssBytes()` helper, `rssBytes:` in HeapSample constructor |
| `lib/src/detectors/memory_pressure_detector.dart` | `_nativeGrowthThresholdBytesPerSec` constant, `_sustainedNativeGrowthStart` tracker, `_evaluateNativeGrowth()`, `_computeNativeSlopeBytesPerSec()`, wired into `_evaluate()`, reset/dispose cleanup |
| `lib/src/utils/fix_hint_builder.dart` | `nativeMemoryGrowth()` static method (involved effort) |
| `test/models/heap_sample_test.dart` | 8 new tests: rssBytes serialization, nativeBytes computation, clamping, null handling |
| `test/detectors/memory_pressure_detector_test.dart` | `_sample` helper updated, 11 new tests in Native Memory Growth group |
| `test/utils/fix_hint_builder_test.dart` | 3 new tests: effort level, DevTools keyword, cacheWidth keyword |

No changes to: session_snapshot.dart, watchdog_controller.dart, barrel file, UI files, WatchdogConfig.

### Spec vs. Implementation Corrections

| Spec | Actual |
|------|--------|
| "`nativeBytes: int?` stored field on HeapSample" | Computed getter `int? get nativeBytes` (clamped to [0, rssBytes]) — avoids stale value risk |
| "Files changed: `session_snapshot.dart`" | No changes needed — existing `s.toJson()` call picks up new fields automatically |
| "8 tests" | 22 new tests: 8 model + 11 detector + 3 FixHintBuilder |

## v3.10 Post-Implementation Notes

v3.10 implements Inter-Detector Correlation — a post-processing step that merges, suppresses, or escalates issues based on cross-detector evidence. 1062 tests passing (up from 1045), 0 analysis issues.

### Implementation Summary

| Item | Status | New Tests | Spec Deviations |
|------|:------:|:---------:|:---------------:|
| `DetectorCorrelator` class + `CorrelationRule` interface | Done | 3 (passthrough) | 0 |
| Rule 4: SuppressAnimatedBuilderRule | Done | 3 | 1 (see below) |
| Rule 1: MergeRebuildSetStateRule | Done | 4 | 0 |
| Rule 2: EscalateGpuCustomPainterRule | Done | 2 | 0 |
| Rule 3: EscalateMemoryImageRule | Done | 1 | 0 |
| Rule 5: DeduplicateRebuildRepaintRule | Done | 2 | 0 |
| Rule ordering tests | Done | 2 | 0 |
| Controller integration | Done | 0 (pipeline) | 0 |
| **Total** | **8/8** | **17** | **1** |

### Design Decisions

#### 1. Rule ordering: suppress → merge → escalate → deduplicate

Order is critical because rules interact. Suppress runs first to remove false positives before other rules see them. Merge runs second to consume `rebuild_debug_$TYPE` issues — if dedup ran first it could remove that same rebuild (if a matching repaint existed), and then merge would find nothing to merge with. Escalate is order-independent (disjoint stableIds). Dedup runs last to handle remaining rebuild/repaint overlaps. Test #17 validates the ordering property.

#### 2. AnimatedBuilder suppress condition (spec deviation)

The spec said "AnimatedBuilder flagged but RepaintDetector has no elevated paint rate for that widget type." Research revealed this is fragile — RepaintDetector's per-widget path only fires when individual types cross the threshold (30 paints/sec). Broadened to: suppress when `confidence == possible` AND no `IssueCategory.paint` issues exist at all. This is more robust: if any paint pressure exists (from any source), AnimatedBuilder is retained as a potential contributor.

#### 3. Merge preserves stableId for recurrence tracking

The controller tracks issue recurrence via `stableId` (`_recurrenceCounts` map). Merged issues keep the `setstate_scope` stableId rather than creating a new `correlated_wide_setstate` ID. This preserves recurrence history and IssueCard expansion state (which uses `ValueKey(stableId)`).

#### 4. Escalate only upgrades `possible` → `likely`, never touches higher

If a detector already promoted confidence to `likely` (via debug callbacks) or `confirmed` (via VM timeline), the detector's own evidence is stronger than cross-detector co-occurrence. The correlator never overrides that signal.

#### 5. No new PerformanceIssue fields needed

All correlation uses existing fields (`stableId`, `widgetName`, `category`, `confidence`) and `copyWith`. No model changes, no serialization changes, no barrel file changes.

### Files Changed

| File | Change |
|------|--------|
| `lib/src/analyzer/detector_correlator.dart` | NEW — `DetectorCorrelator`, `CorrelationRule` abstract class, 5 rule implementations |
| `lib/src/controller/watchdog_controller.dart` | Import, `_detectorCorrelator` field, 2-line change in `_aggregateIssues()` |
| `test/analyzer/detector_correlator_test.dart` | NEW — 17 tests: 3 passthrough, 3 suppress, 4 merge, 2 GPU escalate, 1 memory escalate, 2 dedup, 2 ordering |

### Spec vs. Implementation Corrections

| Spec | Actual |
|------|--------|
| "12 tests" | 17 tests: 3 passthrough + 3 suppress + 4 merge + 2 escalate GPU + 1 escalate memory + 2 dedup + 2 ordering |
| Rule 4: "RepaintDetector has no elevated paint rate for widget type" | Broadened to: no `IssueCategory.paint` issues exist at all (more robust) |
| "New: `lib/src/analyzer/detector_correlator.dart`" | Confirmed — single file with class + 5 rules |

---

## v3.7 Post-Implementation Notes

v3.7 implements CPU Attribution Call Chains — extending CPU profiling from flat function names to full call chains with inclusive percentages. 1045 tests passing (up from 1032), 0 analysis issues.

### Implementation Summary

| Item | Status | New Tests | Spec Deviations |
|------|:------:|:---------:|:---------------:|
| `callChain` + `inclusivePercentage` on `CpuAttribution` | Done | 5 | 0 |
| Inclusive tick counting in `CpuSampleAggregator` | Done | 1 (inclusive invariant) | 1 (see below) |
| Call chain extraction in `CpuSampleAggregator` | Done | 7 | 0 |
| Dashboard UI chain rendering | Done | 0 (visual) | 1 (see below) |
| **Total** | **4/4** | **13** | **2** |

### Design Decisions

#### 1. Inclusive denominator differs from exclusive denominator

Exclusive percentage uses `totalFiltered` (after framework filter) as denominator for backward compatibility. Inclusive percentage uses `totalUsableSamples` (all samples after vmTag filtering) because inclusive measures "how often was this function on any stack" — framework filtering the denominator would inflate percentages artificially. A floor clamp ensures inclusive >= exclusive despite the different denominators.

#### 2. UI shows top 3 functions (spec deviation — reduction from 5)

The spec's dashboard section said to render call chains in the existing verdict detail area. With chains, each function needs its own line (chains are too long for comma-joining). Reduced from 5 to 3 displayed functions to fit the compact overlay. All 5 are still in the data (toJson, session export, capture buffer).

#### 3. Most-common-chain frequency selection

When a function appears at stack[0] across multiple samples, different stacks may show different call paths. Rather than using the first sample's chain or merging all paths, we frequency-count full chains and pick the most common. This gives the most representative call path without the complexity of a merged tree view.

#### 4. No controller or FrameVerdict changes needed

The controller calls `_cpuAggregator.aggregate()` and passes the result through `verdict.withTopFunctions()`. The new `callChain` and `inclusivePercentage` fields ride along in the CpuAttribution objects automatically. Zero coupling — no changes to `watchdog_controller.dart`, `frame_verdict.dart`, `session_snapshot.dart`, or `capture_buffer.dart`.

### Files Changed

| File | Change |
|------|--------|
| `lib/src/models/cpu_attribution.dart` | `callChain: List<String>?`, `inclusivePercentage: double?` fields, `chainDisplay` getter, toJson/fromJson/toString |
| `lib/src/vm/cpu_sample_aggregator.dart` | Inclusive tick counting (Step 1b), `_extractCallChain()`, `_truncateChain()`, `_maxChainDepth` constant, updated Step 4 |
| `lib/src/ui/dashboard_sheet.dart` | Per-function line rendering with chain display, take(3), inclusive percentage parenthetical |
| `test/vm/cpu_sample_aggregator_test.dart` | 8 new tests: basic chain, single entry, framework-only, truncation, inclusive invariant, most-common-wins, null chain, first-user-root |
| `test/models/serialization_test.dart` | 5 new tests: toJson with/without new fields, fromJson with/without, chainDisplay |

### Spec vs. Implementation Corrections

| Spec | Actual |
|------|--------|
| "8 tests" | 13 new tests: 8 aggregator + 5 serialization |
| UI "render call chains in verdict detail" | Top 3 (not 5) functions, each on own line with chain + inclusive % |
| No mention of denominator difference | Inclusive uses totalUsableSamples, exclusive uses totalFiltered, with floor clamp |

---

## v3.5 Post-Implementation Notes

v3.5 implements Allocation-Rate Detection — on-demand per-class allocation profiling that enriches existing `heap_growing` issues with the top allocating classes. 1034 tests passing (up from 1014), 0 analysis issues.

### Implementation Summary

| Item | Status | New Tests | Spec Deviations |
|------|:------:|:---------:|:---------------:|
| `AllocationEntry` model | Done | 5 | 0 |
| `topAllocators` field on `PerformanceIssue` | Done | 4 | 0 |
| `getAllocationProfile()` on `VmServiceClient` | Done | 5 | 0 |
| `enrichHeapGrowingIssue()` on `MemoryPressureDetector` | Done | 4 | 1 (see below) |
| `_enrichWithAllocationProfile()` + `_extractTopAllocators()` on `WatchdogController` | Done | 0 (integration) | 1 (see below) |
| `heapAllocationHotspot()` on `FixHintBuilder` | Removed (dead code) | 0 | 1 (see below) |
| Barrel export | Done | 0 | 0 |
| **Total** | **7/7** | **18** | **3** |

### Design Decisions

#### 1. `_lastTopAllocators` cache field (spec deviation — critical addition)

The spec's two-phase enrichment design overlooked that `_evaluate()` in MemoryPressureDetector calls `_issues.clear()` every 500ms (on each `processHeapSample` call), destroying any `topAllocators` set via enrichment. Added `_lastTopAllocators` cache field to the detector: `enrichHeapGrowingIssue()` stores data in the cache AND applies to the current issue; `_evaluateHeapTrend()` re-attaches cached data when rebuilding the `heap_growing` issue. Cache cleared when growth stops (slope drops below threshold). This was caught during plan review before implementation.

#### 2. Edge-triggered enrichment with 10s cooldown (spec deviation — addition)

The spec said "call getAllocationProfile when heap growth is detected" but didn't address oscillation. When the regression slope hovers near the 512KB/s threshold, `heap_growing` can appear and disappear on alternating samples. Each absent→present transition would trigger a new `getAllocationProfile` call. Added `_lastAllocationEnrichmentTime` with 10s cooldown to prevent repeated queries. Also caught during plan review.

#### 3. `heapAllocationHotspot()` removed (spec deviation — deletion)

The spec included a `heapAllocationHotspot()` method in FixHintBuilder. During post-implementation review, it was identified as dead code: enrichment adds `topAllocators` data to the existing `heap_growing` issue which already has its fixHint from `heapGrowing()`. No production code path calls `heapAllocationHotspot()`. Removed the method and its 2 tests rather than keeping dead code.

#### 4. `bytesCurrent`/`instancesCurrent` used instead of accumulated fields

After `getAllocationProfile(reset: true)`, the "current" values represent allocations since the last reset. The two-call delta approach (reset → 300ms delay → reset) gives meaningful per-interval allocations without needing to manually diff two snapshots.

### Files Changed

| File | Change |
|------|--------|
| `lib/src/models/allocation_entry.dart` | **New.** AllocationEntry model: className, libraryUri, instancesDelta, bytesDelta, percentage, displayBytes, toJson/fromJson |
| `lib/src/models/performance_issue.dart` | `topAllocators: List<AllocationEntry>?` field, toJson/fromJson/copyWith/toString |
| `lib/src/vm/vm_service_client.dart` | `getAllocationProfile({bool reset})` method (500ms timeout, SentinelException handling) |
| `lib/src/detectors/memory_pressure_detector.dart` | `_lastTopAllocators` cache, `enrichHeapGrowingIssue()`, enrichment in `_evaluateHeapTrend()`, cleanup in reset/dispose |
| `lib/src/controller/watchdog_controller.dart` | `_onHeapSample` edge trigger, `_enrichWithAllocationProfile()`, `_extractTopAllocators()`, `_isFrameworkClass()`, `_frameworkClassPrefixes`, `_AllocStat`, `_lastAllocationEnrichmentTime` cooldown |
| `lib/src/utils/fix_hint_builder.dart` | No changes (specced `heapAllocationHotspot()` removed as dead code) |
| `lib/widget_watchdog.dart` | `export 'src/models/allocation_entry.dart'` |
| `test/models/allocation_entry_test.dart` | **New.** 5 tests: toJson, fromJson, roundtrip, displayBytes, toString |
| `test/models/serialization_test.dart` | 4 new tests: topAllocators toJson, fromJson, null default, copyWith |
| `test/utils/fix_hint_builder_test.dart` | 2 new tests: effort level, hint keywords |
| `test/vm/vm_service_client_test.dart` | Mock support + 5 new tests: null service, null isolate, success, sentinel, timeout |
| `test/detectors/memory_pressure_detector_test.dart` | 4 new tests: enrich existing, no-op, survives rebuild, cleared on stop |

### Spec vs. Implementation Corrections

| Spec | Actual |
|------|--------|
| No mention of `_evaluate()` clearing enrichment | Added `_lastTopAllocators` cache to preserve enrichment across `_issues.clear()` rebuilds |
| No cooldown on enrichment trigger | Added 10s cooldown via `_lastAllocationEnrichmentTime` to prevent oscillation-driven repeated queries |
| "10 tests" | 18 new tests: 5 model + 4 serialization + 5 VmServiceClient + 4 detector enrichment |
| `heapAllocationHotspot()` in spec | Removed — dead code with no production caller (existing `heapGrowing()` hint suffices for the enriched issue) |

---

## v3.6 Post-Implementation Notes

v3.6 implements Raster Cache Trend Analysis — detecting cache thrashing, unbounded cache growth, and Impeller renderer suppression within the existing FrameTimingDetector. 1014 tests passing (up from 996), 0 analysis issues.

### Implementation Summary

| Item | Status | New Tests | Spec Deviations |
|------|:------:|:---------:|:---------------:|
| `pictureCacheCount` + `layerCacheBytes` fields on `FrameStats` | Done | 4 | 1 (see below) |
| `_evaluateCacheTrends()` in `FrameTimingDetector` | Done | 10 | 2 (see below) |
| `rasterCacheThrashing()` + `rasterCacheGrowing()` in `FixHintBuilder` | Done | 4 | 0 |
| **Total** | **3/3** | **18** | **3** |

### Design Decisions

#### 1. Added `totalCacheBytes` computed getter (spec deviation — addition)

The spec said to add `pictureCacheCount` to FrameStats. Implementation also added `layerCacheBytes` (the other missing metric from `FrameTiming`) and a `totalCacheBytes` getter (`pictureCacheBytes + layerCacheBytes`) to simplify growth detection math. All four `FrameTiming` cache properties are now captured: `layerCacheCount`, `layerCacheBytes`, `pictureCacheCount`, `pictureCacheBytes`.

#### 2. `_evaluateJank()` changed from `_issues.clear()` to selective `removeWhere` (spec deviation)

The spec assumed cache issues would be managed separately. In practice, `_evaluateJank()` previously called `_issues.clear()` which would wipe cache issues on every evaluation cycle. Changed to `_issues.removeWhere((i) => i.stableId == 'sustained_jank' || i.stableId == 'jank_detected')` so each method owns its own stableIds and cache/jank issues coexist correctly.

#### 3. Thrashing uses 15 frames, not 10 (spec body vs acceptance criteria)

The spec body said "10+ consecutive frames" but the acceptance criteria said "15 consecutive frames". Used 15 as the acceptance criteria is authoritative, and 15 frames (~250ms at 60fps) provides better noise immunity for brief layout transitions.

#### 4. Impeller detection resets immediately on non-zero frame

When Impeller suppression is active (30+ all-zero frames), a single non-zero frame immediately clears the `_impellerDetected` flag. This is conservative — false positives from brief metric availability are preferable to silently missing real cache issues on Skia.

#### 5. No Impeller note issue emitted

The spec mentioned "add a note: Raster cache metrics unavailable (Impeller renderer)." Implementation suppresses analysis silently rather than emitting an informational issue. Rationale: an informational issue about unavailable metrics would clutter the issue list without being actionable by the developer. The suppression prevents false positives, which is the primary goal.

### Files Changed

| File | Change |
|------|--------|
| `lib/src/models/frame_stats.dart` | `pictureCacheCount`, `layerCacheBytes` fields, `totalCacheBytes` getter, toJson/fromJson |
| `lib/src/detectors/frame_timing_detector.dart` | Captures all 4 cache metrics, 4 tracking constants, 4 state fields, `_evaluateCacheTrends()`, `_evaluateJank()` selective clear, dispose cleanup |
| `lib/src/utils/fix_hint_builder.dart` | `rasterCacheThrashing()` and `rasterCacheGrowing()` static methods |
| `test/models/serialization_test.dart` | 4 new tests: toJson, fromJson, totalCacheBytes, backward compat defaults |
| `test/detectors/frame_timing_detector_test.dart` | `makeFrame()` helper extended with cache params, 10 new tests in Raster Cache Trends group |
| `test/utils/fix_hint_builder_test.dart` | 4 new tests: effort levels, keyword checks |

No changes to: performance_issue.dart (IssueCategory.raster already existed), watchdog_controller.dart, barrel file, session_snapshot.dart, UI files.

### Spec vs. Implementation Corrections

| Spec | Actual |
|------|--------|
| "add `pictureCacheCount` field" | Added `pictureCacheCount` + `layerCacheBytes` + `totalCacheBytes` getter — captured all 4 FrameTiming cache properties |
| "10+ consecutive frames" for thrashing | 15 consecutive frames (acceptance criteria is authoritative over body text) |
| "`_issues.clear()` in `_evaluateJank()`" | Changed to selective `removeWhere` — allows jank and cache issues to coexist |
| "6 tests" | 18 new tests: 4 serialization + 10 detector + 4 FixHintBuilder |
| "Impeller note shown when metrics unavailable" | Silent suppression — no informational issue emitted (avoids clutter) |

---

## v0.5.0 Review Fixes Post-Implementation Notes

Comprehensive code review of all v3 implementation changes (v3.1–v3.10, ~57 files, ~7000 lines) identified 3 critical, 17 medium, and 26 low issues plus 10 test gaps. This pass addresses 47 of those findings. 1072 tests passing (up from 1062), 0 analysis issues. No breaking API changes.

### Phase 1: Non-UI Fixes (17 items)

| Fix | File | Change |
|-----|------|--------|
| M1: Post-dispose async safety | `watchdog_controller.dart` | `_disposed` flag guards all `.then()` callbacks in `_enrichVerdictWithCpuAttribution` and `_enrichWithAllocationProfile` |
| M2: Stale packageVersion | `watchdog_controller.dart` | `'0.2.0'` → `'0.5.0'` in config |
| M3: Duplicate stableId | `nested_scroll_detector.dart` | Generic nested-scroll stableId changed from `'nested_scroll'` → `'nested_scroll_same_axis'` to distinguish from SCSV-specific `'nested_scroll'` |
| M4: isFrameworkOwned false negatives | `animated_builder_detector.dart` | Removed `name.startsWith('_')` check — private widgets are not necessarily framework-owned |
| M5: KeepAlive string check | `keep_alive_detector.dart` | Match both `'KeepAlive'` and `'_KeepAlive'` variants |
| M6: Platform channel flickering | `platform_channel_detector.dart` | 3-cycle cooldown with `_lastEmittedIssue` — issues persist for 3 empty evaluations after last detection |
| M7: Shader issues lost between polls | `shader_jank_detector.dart` | `_emptyPollsSinceLastShader` counter — only clear after 3 consecutive empty polls |
| M8: CPU denominator mismatch | `cpu_sample_aggregator.dart` | Inclusive percentage now uses `totalFiltered` (same as exclusive) instead of `totalUsableSamples` |
| M9: Call chain extraction optimization | `cpu_sample_aggregator.dart` | Sort+topN before extracting chains using `(CpuAttribution, int)` record tuples — O(topN) chain extraction instead of O(N) |
| L1: Memory dispose cleanup | `memory_pressure_detector.dart` | Reset `_gcEventCount` and `_trackingStart` in `dispose()` |
| L2: Repaint dispose cleanup | `repaint_detector.dart` | Clear `_pendingDebugSnapshot` in `dispose()` |
| L3: Frame timing dispose cleanup | `frame_timing_detector.dart` | Clear `_lastTimelineData` in `dispose()` |
| L4: GPU pressure variable naming | `gpu_pressure_detector.dart` | Renamed `depth`→`nodeCount`, `countDepth`→`countNodes` for clarity |
| L5: Font loading doc comment | `font_loading_detector.dart` | Documented DefaultTextStyle/Theme limitation |
| L6: Network timer on disable | `network_monitor_detector.dart` | Cancel `_frequencyTimer` in `set isEnabled` when disabling |
| L7: CustomPainter doc comment | `custom_painter_detector.dart` | Documented self-comparison limitation |
| L10+L11+L15+L16+L24 | Various models/analyzers | Assertion on inclusivePercentage, `_truncateChain` guard, bytesDelta clamp, toJson doc comment, rule comment renumbering |

### Phase 2: UI Performance Fixes (4 items)

| Fix | File | Change |
|-----|------|--------|
| C1: IntrinsicHeight removal | `issue_card.dart` | Replaced `IntrinsicHeight` + `Row` + `Container(width:3)` + `Expanded` with `Container(decoration: BoxDecoration(border: Border(left: BorderSide(color, width: 3))))` — eliminates two-pass layout cost in ListView |
| C2+C3: VLB flattening + jank key caching | `dashboard_sheet.dart` | Replaced triple-nested `ValueListenableBuilder` with `_cachedJankKeys`/`_cachedJankMatchCount` computed via listeners on both `verdictNotifier` and `issuesNotifier`. Initial state computed in `initState()` |
| M10: Cancellable timers | `dashboard_sheet.dart` | Replaced 3 `Future.delayed` calls with `Timer` fields (`_exportFeedbackTimer`, `_jankFlashTimer`, `_highlightNotFoundTimer`), all cancelled in `dispose()` |
| M12: Checkbox touch target | `issue_card.dart` | Removed `SizedBox(20x20)`, `MaterialTapTargetSize.shrinkWrap`, and `VisualDensity.compact` — checkbox now uses Material default 48×48 touch target |

### Phase 3: UI Polish (7 items)

| Fix | File | Change |
|-----|------|--------|
| M11: Filter chip overflow | `dashboard_sheet.dart` | Wrapped filter chips in `SingleChildScrollView(scrollDirection: Axis.horizontal)` |
| M13: Reset aboutExpanded on collapse | `issue_card.dart` | `if (!_expanded) _aboutExpanded = false;` in `_toggle()` |
| M15: Prune _expandedIssueIds | `dashboard_sheet.dart` | `retainWhere` on current issue keys before rendering |
| M15b: Prune _selectedIssueId | `dashboard_sheet.dart` | Clear stale selection when issue no longer in list |
| M16: Dynamic collapsed height | `dashboard_sheet.dart` | `_maxCollapsedHeight.clamp(0.0, screenHeight * 0.65)` prevents overflow on small screens |
| U1: Filter chip counts | `dashboard_sheet.dart` | Added `(N)` suffix: `'All (5)'`, `'Idle (3)'`, etc. |
| U2: Empty filter state | `dashboard_sheet.dart` | Shows "No issues match the selected filter" when filtering produces empty list |
| U3: Export error handling | `dashboard_sheet.dart` | `async` + `try/catch` on `Clipboard.setData` |

### Phase 4: Test Gaps (10 new tests)

| Test | File | Covers |
|------|------|--------|
| T1 | `detector_correlator_test.dart` | EscalateMemoryImageRule does NOT escalate confirmed uncached_images |
| T2 | `frame_event_correlator_test.dart` | Empty `recentFrames` returns empty map |
| T3 | `frame_timing_detector_test.dart` | Layer cache growth triggers `raster_cache_growing` (35 frames with monotonic `layerCacheBytes`) |
| T4 | `platform_channel_detector_test.dart` | Simultaneous frequency + duration threshold produces single critical issue |
| T5 | `memory_pressure_detector_test.dart` | Exact 80% heap capacity boundary (strict `>`, no issue at boundary) |
| T6 | `memory_pressure_detector_test.dart` | Zero `heapCapacity` does not crash (division-by-zero guard) |
| T7 | `cpu_sample_aggregator_test.dart` | Exact 50% framework filter boundary (strict `>`, excluded at boundary) |
| T8 | `cpu_sample_aggregator_test.dart` | Negative function index gracefully skipped |
| T9 | `detector_correlator_test.dart` | Duplicate stableIds produce deterministic output |
| T10 | `issue_card_attribution_test.dart` | Empty `fixHint` string does not crash when card expanded |

### Remaining Low-Priority Items (not implemented)

These are polish items deferred to a future pass. None affect correctness or performance.

| ID | Description | Rationale for deferral |
|----|-------------|----------------------|
| M14 | Semantic labels on severity icons, JANK badge, confidence badge | Accessibility improvement — no functional impact |
| L17 | Extract `_WatchdogColors` class for ~50 hardcoded `Color(0xFF...)` values | Maintainability — no runtime impact |
| L19 | CPU chain display order (percentage before chain name) | UX preference — no functional impact |
| L20 | Extract `_GuideTabContent` to const StatelessWidget | Minor build optimization — Guide tab is rarely visible |
| L22 | Animate jank flash with `AnimatedContainer` | Visual polish — current instant flash works correctly |

### Files Changed Summary

| File | Changes |
|------|---------|
| `controller/watchdog_controller.dart` | `_disposed` flag + async guards, version `0.5.0` |
| `detectors/nested_scroll_detector.dart` | stableId `nested_scroll_same_axis` |
| `detectors/animated_builder_detector.dart` | Removed `name.startsWith('_')` + unused variable |
| `detectors/keep_alive_detector.dart` | Both KeepAlive variants + doc comment |
| `detectors/platform_channel_detector.dart` | 3-cycle cooldown mechanism |
| `detectors/shader_jank_detector.dart` | 3-poll delayed clear |
| `detectors/memory_pressure_detector.dart` | dispose cleanup |
| `detectors/repaint_detector.dart` | dispose cleanup |
| `detectors/frame_timing_detector.dart` | dispose cleanup |
| `detectors/gpu_pressure_detector.dart` | `depth`→`nodeCount` rename |
| `detectors/font_loading_detector.dart` | Limitation doc comment |
| `detectors/network_monitor_detector.dart` | Timer cancel on disable |
| `detectors/custom_painter_detector.dart` | Limitation doc comment |
| `vm/cpu_sample_aggregator.dart` | Denominator fix, chain optimization, truncate guard |
| `models/cpu_attribution.dart` | Assertion + doc comment |
| `models/allocation_entry.dart` | Negative bytesDelta clamp |
| `analyzer/detector_correlator.dart` | Rule comment renumbering |
| `ui/issue_card.dart` | IntrinsicHeight removal, aboutExpanded reset, checkbox touch target |
| `ui/dashboard_sheet.dart` | VLB flattening, timers, filter chips, dynamic height, pruning, empty state, export error handling |
| `test/` (10 files) | 10 new tests, updated assertions for stableId/version/border/filter changes |

---

## Confidence Audit + Highlight Fix Post-Implementation Notes

Three targeted fixes arising from manual testing of the example app overlay. 1072 tests passing, 0 analysis issues.

### Fixes

#### 1. Eager highlight collection on first checkbox tap

**File:** `controller/watchdog_controller.dart`
**Problem:** First checkbox tap on Issues tab always showed "Widget not currently visible" banner, even when the widget was in the tree. Highlights were only collected during the scan loop when `highlightEnabledNotifier` was already true — but on the first tap, highlighting was just enabled, so the previous scan cycle hadn't gathered them.
**Fix:** `selectHighlightForIssue()` now calls `_collectHighlights()` eagerly if `highlightsNotifier.value` is empty. This is safe because `_collectHighlights()` just gathers already-computed highlights from each detector's last `scanTree()` — no tree walking.

#### 2. Confidence audit — 2 structural detectors upgraded to `confirmed`

Full audit of all 21 detectors against the confidence definition: `confirmed` = directly observed with framework-guaranteed performance impact.

**Test:** A detector should use `confirmed` only when (a) it reads a provable widget/render property AND (b) the framework guarantees performance waste unconditionally.

| Detector | Before | After | Justification |
|----------|--------|-------|---------------|
| `opacity_detector` | `possible` | `confirmed` | `Opacity(0.0)` — widget IS invisible, IS doing layout + hit-test + saveLayer. Framework guarantee, zero false positive risk. |
| `layout_bottleneck_detector` | `possible` | `confirmed` | `IntrinsicHeight`/`IntrinsicWidth` — always triggers two-pass layout (O(N^2)). Framework guarantee, no condition needed. |

**7 detectors correctly remain `possible`** — they read properties but performance impact depends on runtime conditions:

| Detector | Why `possible` is correct |
|----------|------------------------|
| `listview_detector` | Eager build confirmed, but impact depends on child complexity (unknown) |
| `image_memory_detector` | Missing ResizeImage confirmed, but waste depends on image dimensions (unknown) |
| `keep_alive_detector` | KeepAlive count confirmed, but may be intentional and low-cost |
| `nested_scroll_detector` | Same-axis nesting confirmed, but may use custom physics |
| `global_key_detector` | GlobalKey presence confirmed, but cost only during reparenting |
| `font_loading_detector` | Can't confirm font is actually missing/loading |
| `custom_painter_detector` | Self-comparison is a heuristic (only catches `=> true`) |

**3 detectors correctly use tiered confidence** (`possible` → `likely` with runtime evidence):
`animated_builder_detector`, `setstate_scope_detector`, `shallow_rebuild_risk_detector`

**10 runtime/VM detectors already correct** — all use `confirmed` or well-calibrated tiered confidence.

### Ranking Impact

The confidence upgrade gives these detectors +10 ranking points (from `possible`×5=5 to `confirmed`×5=15). This prevents provably-wasteful issues from ranking below less-certain issues at the same severity tier.

### Files Changed

| File | Change |
|------|--------|
| `controller/watchdog_controller.dart` | Eager `_collectHighlights()` in `selectHighlightForIssue()` |
| `detectors/opacity_detector.dart` | `possible` → `confirmed` |
| `detectors/layout_bottleneck_detector.dart` | `possible` → `confirmed` |
| `test/detectors/layout_bottleneck_detector_test.dart` | Updated confidence assertion |

## Combined Demo Screens Post-Implementation Notes

**Date:** 2026-03-30
**Scope:** Added 2 combined multi-detector demo screens to the example app to demonstrate realistic multi-issue scenarios and the correlation pipeline in action.

### Motivation

The existing 15 demo screens each target a single detector in isolation. Real-world apps trigger multiple detectors simultaneously, and the correlation pipeline (suppress, merge, escalate, deduplicate) is invisible when only one issue appears at a time. Combined screens let developers see how Watchdog handles overlapping issues.

### Combined Demo 1: Social Feed

Simulates a social media feed with 4+ simultaneous anti-patterns:

| Anti-pattern | Detector | Confidence |
|---|---|---|
| `Opacity(0.0)` hidden "loading more" banner | Opacity | confirmed |
| 8× `IntrinsicHeight` on user header rows | LayoutBottleneck | confirmed |
| 16 network images without `cacheWidth` (avatars + posts) | ImageMemory | possible → likely* |
| Top-level `setState` rebuilds all 8 cards | Rebuild + SetStateScope | merged by Rule 2 |

*Escalated to `likely` by correlation Rule 4 (EscalateMemoryImage) when VM detects heap growth from full-resolution image decodes.

**Correlation rules exercised:**
- Rule 2 (MergeRebuildSetState): Rebuild evidence merged into setState scope issue
- Rule 4 (EscalateMemoryImage): Uncached images escalated when heap growth co-occurs

### Combined Demo 2: Analytics Dashboard

Simulates a data dashboard with 5 simultaneous anti-patterns:

| Anti-pattern | Detector | Confidence |
|---|---|---|
| `AnimatedBuilder` without `child` parameter | AnimatedBuilder | possible (may be suppressed*) |
| `CustomPainter` with `shouldRepaint → true` | CustomPainter | possible → likely** |
| 12 `GlobalKey` instances on metric tiles | GlobalKey | possible |
| 4 custom font families (Lobster, Pacifico, DancingScript, IndieFlower) | FontLoading | possible |
| `SingleChildScrollView` + `Column` (12 items, non-lazy) | ListView | confirmed |

*Suppressed by correlation Rule 1 (SuppressAnimatedBuilder) when no paint-category issues exist.
**Escalated by correlation Rule 3 (EscalateGpuCustomPainter) when raster dominance co-occurs.

**Correlation rules exercised:**
- Rule 1 (SuppressAnimatedBuilder): May suppress AnimatedBuilder if no paint pressure detected
- Rule 3 (EscalateGpuCustomPainter): May escalate CustomPainter when GPU raster pressure co-occurs

### Demo Home Registration

Both screens added to the `DemoHome` route list after the existing 15 demos, with distinctive icons and colors:
- Social Feed: `Icons.dynamic_feed`, deepPurple
- Analytics Dashboard: `Icons.dashboard`, teal

### Verification

- `fvm flutter analyze` — 0 issues
- `fvm flutter test` — all 1072 tests pass (no new tests needed — these are example app screens, not library code)

### Files Changed

| File | Change |
|------|--------|
| `example/lib/main.dart` | Added `CombinedSocialFeedDemo`, `CombinedAnalyticsDashboardDemo`, `_DashboardChartPainter`, and 2 route entries |

---

## v0.6.0 Floating Issues Card Post-Implementation Notes

Replaced the 1,241-line `DashboardSheet` bottom sheet with a ~630-line `FloatingIssuesCard` draggable floating card. Developers can now interact with their app while viewing diagnostics. 1,060 tests passing, 0 analysis issues.

### What changed

| File | Action | Details |
|------|--------|---------|
| `lib/src/ui/floating_issues_card.dart` | **Created** | Draggable floating card replacing DashboardSheet. Stack-based self-positioning, GestureDetector drag on header, ConstrainedBox(300px, 55%). Preserves: export, highlight, jank correlation, warning banners. Removed: TabController, AnimationController, drag-to-expand, filter chips, FPS chart, jank flash/banner. |
| `lib/src/ui/guide_page.dart` | **Created** | Full-screen StatelessWidget with color legend, guide steps. Shown via `_showGuide` state toggle (not Navigator — card is outside app's Navigator context). |
| `lib/src/ui/trigger_button.dart` | **Modified** | Added `frameStatsNotifier` parameter. Shows color-coded FPS number below the circle button (green ≥50, amber ≥30, red <30). Height 56→78. |
| `lib/src/ui/watchdog_overlay.dart` | **Modified** | Swapped DashboardSheet→FloatingIssuesCard, removed bottom-sheet Positioned wrapper, passed frameStatsNotifier to TriggerButton. |
| `lib/src/ui/dashboard_sheet.dart` | **Deleted** | Was 1,241 lines, replaced by floating_issues_card.dart. |
| `lib/src/ui/frame_chart.dart` | **Deleted** | FPS chart removed — FPS is now a number on TriggerButton. |
| `lib/src/controller/watchdog_controller.dart` | **Modified** | Updated overlay self-skip from `'DashboardSheet'` to `'FloatingIssuesCard'`. |
| `test/ui/guide_page_test.dart` | **Created** | 2 tests: legend content, back button. |
| `test/ui/dashboard_summary_test.dart` | **Adapted** | Removed tab navigation, deleted tab-specific test. 5 tests remain. |
| `test/ui/jank_verdict_linking_test.dart` | **Adapted** | Deleted jank banner tests (no banner), kept JANK badge + flash tests. 4 tests remain. |
| `test/ui/overlay_ux_improvements_test.dart` | **Adapted** | Deleted filter chip tests, moved legend test to guide_page_test. Kept highlight, effort, about-section, ranker tests. |
| `test/ui/dashboard_export_test.dart` | **Updated** | Import → floating_issues_card.dart. |
| `test/ui/dashboard_dbg_badge_test.dart` | **Updated** | Import → floating_issues_card.dart. |
| `test/ui/instrumentation_warning_test.dart` | **Updated** | Import → floating_issues_card.dart. |

### Design decisions

- **Stack-based positioning** (not Transform.translate): card uses `Positioned` within the overlay's Stack so the card is self-contained and hit-testing works correctly.
- **`_showGuide` toggle** (not Navigator.push): the overlay lives outside the app's Navigator context, so GuidePage is shown by swapping it into the same Stack.
- **Compact header icons**: Custom `_headerIconButton` (GestureDetector + Padding(8) + Icon(16) = 32px each) instead of IconButton (30px+ minimum) to fit in 300px card width while staying close to recommended touch target sizes.
- **Single Flexible text for summary bar**: Combined confirmed/heuristic counts into one `Flexible(Text(...join(' · ')))` to prevent overflow with the Ahem test font.

### Post-review fixes

Code review after initial implementation identified 6 issues (2 critical, 3 medium, 3 low). All fixed:

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| C1 | Critical | Doc comment claimed `Transform.translate`, actual code uses `Positioned` | Updated doc to match implementation |
| C2 | Critical | `jankFlash` IssueCard doc referenced deleted Live tab | Updated doc; kept parameter as IssueCard capability |
| M1 | Medium | FPS color thresholds duplicated in floating_issues_card.dart and trigger_button.dart | Extracted shared `fpsColor()` helper in floating_issues_card.dart, trigger_button imports it |
| M2 | Medium | State mutated during build (clamping `_cardOffset` + pruning stale expanded/selected IDs) | Clamping uses local `clamped` variable; pruning moved to `_pruneStaleState` listener on issuesNotifier |
| M3 | Medium | Sentinel offset `Offset(-1, -1)` was fragile | Changed to `Offset?` with null-coalescing `??=` initialization |
| L1 | Low | Header icon touch targets were 24px (below 44px minimum) | Bumped padding 4→8px for 32px targets |
| L2 | Low | Test group names still said "DashboardSheet" | Renamed to "FloatingIssuesCard" |
| L3 | Low | No `RepaintBoundary` between header and issues list | Added `RepaintBoundary` wrapping issues list to isolate from header/FPS repaints |

### Net result

~800 lines added, ~1,340 lines removed. Net: -540 lines. Simpler widget tree, better UX, lower performance cost (no TabBarView keep-alive, no AnimationController, no CustomPaint chart).

## v0.6.0 Enhancements Post-Implementation Notes

Two batches of improvements after the initial floating card implementation: GuidePage redesign with animations and expanded content, and resizable card with corner grip handle. 70 UI tests passing, 0 analysis issues.

### What changed

| File | Action | Details |
|------|--------|---------|
| `lib/src/ui/guide_page.dart` | **Rewritten** | StatelessWidget → StatefulWidget with `SingleTickerProviderStateMixin`. Added staggered entrance animations (fade+slide per section, 120ms offset). 4 expandable sections: Quick Start, Understanding the Card, Color Legend, Tips & Tricks. Color Legend expanded with 6 subsections: Severity (with detail descriptions), Confidence Badges, Source Accent, Category Badges (all 8 with chip+description), Effort Badges, Special Indicators (JANK badge, card state swatches). |
| `lib/src/ui/floating_issues_card.dart` | **Enhanced** | Added resizable width+height via corner drag handle. `_cardWidth` state (default 300, min 220, max screen width). `_cardHeight` nullable state (default 55% screen, min 250px static, max screen-topPadding-20). Double-tap header toggles maximize. `_CornerGripPainter` (const, `shouldRepaint => false`) draws 6 diagonal grip dots inside card's 16px corner radius. `effectiveWidth` local computed from `_cardWidth.clamp()` — no state mutation during build. Summary bar: `Spacer` + `Flexible` → single `Expanded` with `textAlign: TextAlign.right` for flush-right "confirmed · heuristic" label. |
| `test/ui/card_resize_test.dart` | **Created** | 9 tests: handle presence, CustomPaint child, drag-right width increase, drag-left width decrease, min-width clamp (220px), drag-down height increase, min-height clamp (250px), double-tap maximize, double-tap restore. Uses `startGesture` + `moveBy` (two-step: exceed pan slop, then apply delta). |
| `test/ui/guide_page_test.dart` | **Updated** | Added assertions for category descriptions, effort badge descriptions, and Special Indicators section (JANK, Highlighted, Jank flash). |

### Design decisions

- **`effectiveWidth` computed local** (not mutating `_cardWidth` in build): The card width needs clamping to screen bounds which may change on rotation. Rather than mutating state during `build()`, a local `effectiveWidth` is computed from `_cardWidth.clamp(min, max)` each frame. The stored `_cardWidth` is only mutated in `setState` callbacks (resize drag, double-tap).
- **Nullable `_cardHeight`**: Default card height (55% screen) is computed from `MediaQuery` each build. `_cardHeight` is null until the user first drags the resize handle, at which point it captures the user's preference. This avoids storing a stale pixel value that breaks on rotation. Static minimum of 250px (`_minCardHeight`) — decoupled from default so the card can be shrunk below 55% but not to unusable dimensions.
- **Corner grip inside card radius**: The 32×32 `Positioned` handle sits at `right: 0, bottom: 0` inside the inner Stack (not overflowing). `_CornerGripPainter` draws dots inset 6px from edges to stay within the 16px corner radius. No separate container/background — just dot circles on the card's existing Material surface.
- **Pan slop in tests**: `tester.drag()` loses unpredictable amounts to pan gesture slop. Tests use `tester.startGesture()` + two `moveBy()` calls (first exceeds 36px slop threshold, second delivers exact delta). Width/height assertions use `greaterThan`/`lessThan` for direction, `closeTo` only where exact values are known (clamp floors, maximize).
- **Double-tap timer drain**: `GestureDetector.onDoubleTap` uses a 40ms countdown timer internally. Tests pump 300ms after the second tap to drain it, preventing "Timer still pending" failures.

### Post-review fixes

Code review after enhancement implementation identified 3 issues. All fixed:

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| R1 | Medium | State mutation during `build()` — `_cardWidth = _cardWidth.clamp(...)` | Changed to computed local `effectiveWidth`; `_cardWidth` only mutated in setState callbacks |
| R2 | Medium | GuidePage resize description said "right edge" — stale after corner-handle refactor | Updated to "bottom-right corner to resize width and height" |
| R3 | Low | `_CornerGripPainter()` allocated new object each rebuild | Added `const` constructor, call site uses `const _CornerGripPainter()` |
| R4 | Low | Min card height (400px) was higher than default (55% = 330px on small screens), forcing cards to be taller than intended | Changed to static 250px `_minCardHeight` constant — allows shrinking below default without being unusable |
| R5 | Low | Summary bar "confirmed · heuristic" label not flush-right — `Spacer` + `Flexible` split remaining space 50/50 | Replaced with single `Expanded` + `textAlign: TextAlign.right` |

### Test count

70 UI tests across 9 files (was 61 across 8). Full suite: ~1,070 tests.

## v0.6.1 FPS Counter Fixes Post-Implementation Notes

Fixed three FPS counter bugs: wrong values at startup, no target cap in UI, and millisecond truncation in `averageFps`. Uses throughput-based FPS: `1,000,000 / avg_frame_duration_μs`, capped at 120 internally and at `fpsTarget` (default 60) in UI.

### What changed

| File | Action | Details |
|------|--------|---------|
| `lib/src/controller/watchdog_controller.dart` | **Modified** | Moved `_frameTiming.start()` before `await client.connect()` so FPS counter captures frames during slow VM connection (1.5–10.5s). `exportSnapshot()` reads live detector buffer (`_frameTiming.frameBuffer`) when initialized, falls back to `frameStatsNotifier.value` pre-init. |
| `lib/src/models/frame_stats.dart` | **Modified** | `averageFps` changed from milliseconds to microseconds for precision. Formula: `(1,000,000 / (totalUs / length)).clamp(0, 120)`. Eliminates truncation artifacts (6.5ms → 6ms was inflating FPS by ~8%). Empty buffer → 0, zero total → 0. |
| `lib/src/ui/floating_issues_card.dart` | **Modified** | `fpsColor` made target-aware with `{int target = 60}` parameter. Thresholds: green ≥ 83% of target, amber ≥ 50%, red below. Display FPS capped at `fpsTarget`. |
| `lib/src/ui/trigger_button.dart` | **Modified** | Added `fpsTarget` parameter (default 60). Display FPS capped at `widget.fpsTarget`. Passes target to `fpsColor`. |
| `lib/src/ui/watchdog_overlay.dart` | **Modified** | Wires `fpsTarget: widget.controller.config.fpsTarget` to `TriggerButton`. |
| `test/models/frame_stats_buffer_fps_test.dart` | **Created** | 9 tests: empty buffer, single frame clamped to 120, 60Hz budget (~62.5 FPS), janky frames (~30 FPS), severe jank (10 FPS), mixed fast+janky (~45.5 FPS), zero durations, clamp to 120, raster bottleneck, sub-millisecond precision. |
| `example/lib/main.dart` | **Modified** | Added FPS Stress Test demo screen with `AnimationController` + sorting 50k items + triple `BackdropFilter` blur to produce ~20 FPS. |

### Design decisions

- **Throughput model (not vsync-interval)**: `1,000,000 / avgFrameTimeUs` answers "can my engine keep up with the display?" On idle screens, fast frames (~6ms) yield high throughput capped to 60 (healthy). On janky screens, slow frames (~30ms) yield low throughput (problem). Matches what Flutter's performance overlay communicates.
- **No throttle on notifier updates**: Throttling (e.g., 500ms) was tried and removed — it made the FPS counter feel sluggish. Direct notifier updates give live feedback. The feedback loop (rebuild → frame → callback → rebuild) is the FPS counter's own overhead and is acceptable.
- **Debug mode quirks accepted**: In debug mode, idle screens show ~10 FPS due to debug overhead + tree scan timer producing frames via `addPostFrameCallback`. This is expected — always use profile mode for reliable FPS readings. Added doc comment to `averageFps` noting this.
- **120 internal cap, fpsTarget UI cap**: `averageFps` clamps at 120 (max refresh rate Flutter supports). UI further clamps at `fpsTarget` so an idle screen in profile mode shows 60 (the target), not 120+.
- **`exportSnapshot` reads live buffer**: Uses `_frameTiming.frameBuffer` when `_initialized` is true, avoiding any potential staleness if notifier update strategy changes in the future.

### What was NOT changed

- `effectiveTotalDuration`, `isJank`, `isSevereJank` — still use processing time (correct for jank detection)
- `_evaluateJank()` — unaffected
- Export JSON schema — unchanged
- `frameBudgetMs` derivation — still `1000 ~/ fpsTarget`

### Expected behavior

| Screen state | Frame time | Raw throughput | Displayed (target=60) | Color |
|---|---|---|---|---|
| Idle (profile mode) | ~6ms | ~167 → clamp 120 | **60** | Green |
| Light jank | ~20ms | ~50 | **50** | Amber |
| Heavy jank | ~33ms | ~30 | **30** | Red |
| Severe jank | ~100ms | ~10 | **10** | Red |
| Idle (debug mode) | ~100ms | ~10 | **10** | Red (expected) |

### Test count

9 new unit tests in `frame_stats_buffer_fps_test.dart`. Full suite: ~1,079 tests.

---

