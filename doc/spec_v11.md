## v11 Detector Audit: Gaps, False Positives & Hot-Path Performance

**Status: 19/19 milestones + Pillar 2a (3 milestones) + Pillar 2b (4 milestones) shipped** ✅ (v0.10.5 / v0.10.6)

Origin: Adversarial audit (2026-04-07) of 5 detectors (ListviewDetector, NestedScrollDetector, LayoutBottleneckDetector, SetStateScopeDetector, RepaintBoundaryDetector). Found 6 gaps and false positives across detection coverage, accuracy, and enrichment. All milestones implemented, adversarial-reviewed twice (8 fix-round findings resolved), 1,561 tests passing, 0 analysis issues.

**Detectors audited:**
- **ListviewDetector** — detection gap: non-lazy ListView/GridView/SliverList invisible
- **NestedScrollDetector** — false positives: NeverScrollableScrollPhysics and NestedScrollView
- **LayoutBottleneckDetector** — false positive: framework IntrinsicWidth; gap: Wrap detection
- **SetStateScopeDetector** — accuracy: const subtree inflating rebuild scope
- **RepaintBoundaryDetector** — gap: excessive RepaintBoundary overuse

---

### v11.1: Detect SliverChildListDelegate-based Non-Lazy Patterns

**Effort:** Medium | **Theme:** Accuracy | **Impact:** P0 — `ListView(children: [...])` is the most common non-lazy anti-pattern and was invisible

**Problem:** ListviewDetector only caught `SingleChildScrollView + Column/Row`. Three major non-lazy patterns were undetected: `ListView(children: [...])`, `GridView(children: [...])`, and `CustomScrollView > SliverList(delegate: SliverChildListDelegate([...]))`. All build every child eagerly via `SliverChildListDelegate`.

**Fix:** Added detection in `checkElement()` for:
1. `ListView`/`GridView` — check `childrenDelegate` property for `SliverChildListDelegate`, count via `delegate.children.length`
2. `SliverList`/`SliverGrid` — check `delegate` property, same counting logic
3. Depth counter (`_insideBoxScrollView`) to skip SliverList/SliverGrid that are internal children of already-detected ListView/GridView

Added `FixHintBuilder.nonLazySliver()` for SliverList/SliverGrid-specific fix hints with `$widgetName.builder()` recommendation.

**Files modified:**
- `lib/src/detectors/listview_detector.dart` — added ListView/GridView delegate check, SliverList/SliverGrid detection, depth counter for dedup
- `lib/src/utils/fix_hint_builder.dart` — added `nonLazySliver()` method
- `test/detectors/listview_detector_test.dart` — ~10 new tests

**Tests:** ListView(children: 55) flagged, GridView(children: 55) flagged, GridView.count(children: 55) flagged, CustomScrollView > SliverList with SliverChildListDelegate flagged, builder variants not flagged, severity thresholds verified.

---

### v11.2: Suppress NeverScrollableScrollPhysics and NestedScrollView False Positives

**Effort:** Medium | **Theme:** Accuracy | **Impact:** P1 — NeverScrollableScrollPhysics false positive commonly encountered in forms and detail pages

**Problem:** NestedScrollDetector flagged `ListView(physics: NeverScrollableScrollPhysics())` inside scrollables (safe pattern for embedded lists) and inner scrollables inside `NestedScrollView` (framework's coordination solution). Both are false positives.

**Fix:**
1. Added `_hasNeverScrollablePhysics()` — walks `ScrollPhysics.parent` chain to find `NeverScrollableScrollPhysics` at any depth. Suppresses nesting warning when found.
2. Added `_insideNestedScrollView` depth counter — incremented on `checkElement(NestedScrollView)`, decremented on `afterElement`. When >0, all nesting warnings suppressed.

**Files modified:**
- `lib/src/detectors/nested_scroll_detector.dart` — added physics chain check, NestedScrollView depth counter
- `test/detectors/nested_scroll_detector_test.dart` — ~7 new tests

**Tests:** NeverScrollableScrollPhysics suppresses ListView/GridView/SCSV nesting; ClampingScrollPhysics(parent: NeverScrollable) suppresses (chain walk); BouncingScrollPhysics(parent: Clamping) still flags; ListView inside NestedScrollView body suppressed; nesting detection resumes after leaving NestedScrollView subtree.

---

### v11.3: Suppress Framework-Internal IntrinsicWidth

**Effort:** Low | **Theme:** Accuracy | **Impact:** P1 — DropdownButton is extremely common and creates false-positive noise

**Problem:** LayoutBottleneckDetector flagged `IntrinsicWidth` inside `DropdownButton`, `AlertDialog`, and other framework widgets that use intrinsics internally. Developers cannot control this usage, so flagging it is noise.

**Fix:** Added `_isInsideFrameworkWidget()` — walks up element tree (max 10 levels via `visitAncestorElements`) checking for known framework widgets (`DropdownButton`, `DropdownButtonFormField`, `PopupMenuButton`, `AlertDialog`, `SimpleDialog`, `ExpansionTile`). Handles generic types (e.g., `DropdownButton<String>`) by stripping the type parameter. Intrinsics inside these widgets are suppressed.

**Critical fix during adversarial review:** The `_intrinsicDepth++` must happen *before* the `_isInsideFrameworkWidget()` early return to keep push/pop balanced with `afterElement`'s unconditional decrement. The ancestor lookup depth was also bumped from 5 to 10 to handle Flutter version variations in widget tree depth.

**Files modified:**
- `lib/src/detectors/layout_bottleneck_detector.dart` — added `_isInsideFrameworkWidget()`, `_frameworkIntrinsicParents` set, depth-balanced increment
- `test/detectors/layout_bottleneck_detector_test.dart` — 3 new tests

**Tests:** IntrinsicWidth inside DropdownButton not flagged, standalone IntrinsicWidth still flagged, IntrinsicHeight inside AlertDialog not flagged.

---

### v11.4: Detect Wrap with Excessive Children

**Effort:** Low | **Theme:** Detection Gap | **Impact:** P2 — real but less common pattern than intrinsic misuse

**Problem:** `Wrap` with many children (>30) has non-virtualized layout — all children are measured every frame regardless of visibility. Not detected.

**Fix:** In `checkElement()`, when `widget is Wrap`, count direct children via `element.visitChildren()`. If count exceeds `_wrapChildThreshold` (30), record finding. In `finalizeScan()`, emit issues with stableId `wrap_layout_bottleneck`. Critical severity at >60 children (2x threshold).

**Text accuracy fix during adversarial review:** Changed detail text from "O(n²) layout" to "non-virtualized layout" — Wrap is O(n) per-pass, not O(n²). Confidence changed from `confirmed` to `possible` since cost depends on child complexity.

**Files modified:**
- `lib/src/detectors/layout_bottleneck_detector.dart` — added Wrap detection, `_wrapFindings` accumulator, `_wrapChildThreshold`
- `lib/src/utils/fix_hint_builder.dart` — added `wrapBottleneck()` method
- `test/detectors/layout_bottleneck_detector_test.dart` — 4 new tests

**Tests:** Wrap with 35 children flagged (possible confidence), Wrap with 30 not flagged, Wrap alongside IntrinsicHeight both reported, critical severity at 65 children.

---

### v11.5: Const Subtree Discounting for setState Scope

**Effort:** High | **Theme:** Enrichment | **Impact:** P2 — improves accuracy; current behavior directionally correct but overstates severity

**Problem:** SetStateScopeDetector counted all elements equally. A StatefulWidget owning 500 elements where 450 are `const` reports "owns 500 elements" without distinguishing the mutable fraction. This overstates rebuild cost.

**Fix:** Added element-widget identity tracking across scans:
1. `_elementWidgetSnapshots` maps `identityHashCode(element)` → `identityHashCode(element.widget)` from previous scan
2. Const widgets keep the same widget instance across rebuilds, so matching identity = stable
3. `_stableCountStack` parallels `_subtreeSizeStack` — counts stable elements per subtree
4. In `finalizeScan()`, when rebuild evidence exists, uses `mutableSubtreeSize = maxSubtreeSize - maxStableCount` for ratio calculation
5. Without rebuild evidence, uses raw subtree size (conservative — no discount applied without proof of rebuild)
6. Detail string shows breakdown: `"(X mutable of Y total, Z const)"`

**Critical test fix during adversarial review:** Split the const-discount test into two: one at low threshold (0.01) verifying the detail string contains 'mutable', and one at moderate threshold (0.3) verifying const discount actually suppresses an issue that would fire with raw size. Used `GlobalKey<State>` + `triggerRebuild()` pattern to externally trigger setState on the test widget.

**Files modified:**
- `lib/src/detectors/setstate_scope_detector.dart` — added `_elementWidgetSnapshots`, `_stableCountStack`, `_maxStableCount`, mutable ratio calculation
- `test/detectors/setstate_scope_detector_test.dart` — added `RebuildableConstHeavyWidget` (1 mutable + 29 const children), 3 new tests

**Tests:** First scan uses raw size (no baseline), detail includes const count when rebuild evidence present, const discount suppresses issue at moderate threshold, second scan without rebuild uses raw size.

---

### v11.6: Detect Excessive RepaintBoundary in Scrollables

**Effort:** Medium | **Theme:** Detection Gap | **Impact:** P2 — real but less commonly encountered than missing boundaries

**Problem:** Too many `RepaintBoundary` widgets in a scrollable (e.g., wrapping every list item) increases GPU memory by creating excessive compositing layers. No detection existed for this anti-pattern.

**Fix:** Added `_scrollableBoundaryStack` — per-scrollable RepaintBoundary counter:
1. On `BoxScrollView` entry: check `_delegateAddsRepaintBoundaries()` (reads `childrenDelegate.addRepaintBoundaries`). If true (framework manages boundaries), push -1 sentinel to skip counting. If false, push 0.
2. On `CustomScrollView` entry: push 0 (no delegate property).
3. On `RepaintBoundary`: increment top of stack if >= 0.
4. On scrollable exit (`afterElement`): pop and check against `_excessiveBoundaryThreshold` (20).

**Key design decision during adversarial review:** Distinguishing framework-added vs user-added RepaintBoundary at the individual element level is unreliable (both sit in same render/element tree structure, nesting depth varies by Flutter version). The correct approach is checking the scrollable widget's delegate configuration — if `addRepaintBoundaries: true` (default), skip counting entirely for that scrollable via -1 sentinel.

**Files modified:**
- `lib/src/detectors/repaint_boundary_detector.dart` — added `_scrollableBoundaryStack`, `_excessiveFindings`, `_delegateAddsRepaintBoundaries()`, sentinel pattern
- `lib/src/utils/fix_hint_builder.dart` — added `excessiveRepaintBoundary()` method
- `test/detectors/repaint_boundary_detector_test.dart` — 5 new tests

**Tests:** ListView with 25 explicit boundaries (addRepaintBoundaries: false) flagged, 5 boundaries not flagged, GridView with 25 flagged, nested scrollables tracked independently, framework-added boundaries (addRepaintBoundaries: true, default) NOT counted.

---

## Adversarial Review Findings (Post-Implementation)

8 findings identified and fixed in the review round:

| # | Type | Detector | Finding | Resolution |
|---|------|----------|---------|------------|
| 1 | Bug | LayoutBottleneck | `_intrinsicDepth` increment/decrement imbalanced when framework widget suppresses recording | Moved `_intrinsicDepth++` before `_isInsideFrameworkWidget()` early return |
| 2 | Bug | RepaintBoundary | Excessive-boundary counter counted framework-added RepaintBoundary children (false positive for default ListView.builder) | Reworked to delegate-based `addRepaintBoundaries` check with -1 sentinel |
| 3 | Text | LayoutBottleneck | Wrap detail said "O(n²)" — Wrap is O(n) per-pass, not O(n²) | Changed to "non-virtualized layout" |
| 4 | Convention | LayoutBottleneck | Wrap confidence was `confirmed` — should be `possible` (structural-only) | Changed to `IssueConfidence.possible` |
| 5 | Text | Listview | SliverList/SliverGrid fix hint hardcoded "SliverList.builder" for both | Added `nonLazySliver()` with `$widgetName.builder()` |
| 6 | Test | SetStateScope | Const-discount test was vacuous (never verified the code path) | Split into 2 tests: detail string verification + suppression verification |
| 7 | Test | NestedScroll | No test for NestedScrollView depth counter restoration after leaving subtree | Added sibling-after-NSV test asserting exactly 1 issue |
| 8 | Fragility | LayoutBottleneck | `_maxAncestorLookup` of 5 too shallow for some Flutter version widget depths | Bumped to 10 |

---

## Verification (v11.1–v11.6)

- `fvm flutter test` — 1,561 tests passing ✅
- `fvm flutter analyze` — 0 issues ✅
- Two adversarial reviews completed with all findings resolved

---

# v11 Detector Audit — Part 2 (v11.7–v11.12)

6 detectors, 6 milestones. Second audit pass covering remaining detector gaps.

## P1 — Accuracy & Detection Gaps

### v11.7: FadeTransition opacity detection (OpacityDetector) ✅

**Problem**: `AnimatedOpacity` internally builds `FadeTransition` → both produce `RenderAnimatedOpacity`. Previous code would double-count.

**Solution**:
- Added `_insideAnimatedOpacity` depth counter
- Split AnimatedOpacity/FadeTransition into separate branches in `checkElement`
- FadeTransition only checked when `_insideAnimatedOpacity == 0` (not inside AnimatedOpacity)
- Extracted shared `_checkSettledAtZero()` helper for both paths
- Added `afterElement` to decrement counter

**Files**: `opacity_detector.dart`, `opacity_detector_test.dart`
**Tests**: 4 new tests (FadeTransition at zero, at non-zero, dedup with AnimatedOpacity, mixed counts)

### v11.8: ColorFiltered GPU detection (GpuPressureDetector + RepaintBoundaryDetector) ✅

**Problem**: `ColorFiltered` creates `_ColorFilterRenderObject` (private class) — can't use `is` check on render object. Not detected as expensive GPU node.

**Solution**:
- GpuPressureDetector: Added `element.widget is ColorFiltered` check (widget-level, not render-object-level)
- RepaintBoundaryDetector: Added `'ColorFiltered'` to `_expensiveTypeNames` and `widget is ColorFiltered` check

**Files**: `gpu_pressure_detector.dart`, `repaint_boundary_detector.dart`, both test files
**Tests**: 3 new tests (deep subtree flagged, shallow subtree not flagged, issue detail)

### v11.9: Small image suppression (ImageMemoryDetector) ✅

**Problem**: Images displayed at ≤50px (icons, avatars) have negligible memory savings from `cacheWidth`/`cacheHeight` (~10KB for 50×50 RGBA). Flagging them is noise.

**Solution**:
- Added `_smallImageThreshold = 50.0` constant
- Added `_isSmallImage(Element)` — checks render object size via `RenderBox.hasSize`
- Skips zero-size render objects (unloaded images or unconstrained widgets)
- Applied to both Image and DecoratedBox paths

**Key insight**: `Element.renderObject` for Image's StatefulElement walks down to `RenderSemanticsAnnotations` (not `RenderImage`). In tests, root tight constraints (800×600) override SizedBox — tests use `Center` wrapper to convert to loose constraints.

**Files**: `image_memory_detector.dart`, `image_memory_detector_test.dart`
**Tests**: 5 new tests (24×24, 50×50 boundary, 51×51, 300×300, DecoratedBox)

## P2 — Enrichment & Severity

### v11.10: TweenAnimationBuilder child detection (AnimatedBuilderDetector) ✅

**Problem**: `TweenAnimationBuilder` without `child` has the same performance issue as `AnimatedBuilder` without `child` — entire builder subtree rebuilds per tick. Not detected.

**Key challenge**: `TweenAnimationBuilder extends ImplicitlyAnimatedWidget`, which `isFrameworkWidget()` classifies as framework-owned → false negatives inside Scaffold/Navigator.

**Solution**:
- Added TweenAnimationBuilder check in `afterElement` (separate from AnimatedBuilder)
- Skipped `isFrameworkOwned` for TweenAnimationBuilder — always user-placed, never framework-created
- Extracted `_recordNoChild()` helper to share logic
- Track `_widgetNames` for per-type title and debug evidence lookup
- Dynamic dominant widget name in title and FixHintBuilder

**Files**: `animated_builder_detector.dart`, `animated_builder_detector_test.dart`
**Tests**: 4 new tests (flagged without child, passes with child, not blocked by framework ancestor, small subtree ignored)

### v11.11: Runtime font loading detection (FontLoadingDetector) ✅

**Problem**: `google_fonts` (and similar packages) load fonts at runtime via HTTP, causing text flicker (FOUT/FOIT). Not detected separately from generic custom font counting.

**Detection signal**: `fontFamilyFallback` — google_fonts sets this on TextStyles. Bundled fonts never need it.

**Solution**:
- Added `_runtimeLoadedFamilies` set
- Extracted `_checkStyle()` helper for Text and RichText
- Checks `fontFamilyFallback` non-empty as runtime loading indicator
- New `runtime_font_loading` issue (confidence: likely, severity: warning/critical based on count)
- New `FixHintBuilder.runtimeFontLoading()` method

**Files**: `font_loading_detector.dart`, `fix_hint_builder.dart`, `font_loading_detector_test.dart`
**Tests**: 7 new tests (flagged, not flagged without fallback, system font ignored, multiple families, severity, RichText, dispose)

### v11.12: BackdropFilter sigma-aware severity (GpuPressureDetector) ✅

**Problem**: All BackdropFilters treated equally. Low-sigma blurs (σ ≤ 2.0) are cheap; high-sigma blurs (σ > 10.0) are extremely expensive. Flat severity wastes developer attention.

**Key challenge**: `_GaussianBlurImageFilter` is private — fields `sigmaX`/`sigmaY` only accessible via `toString()` returning `'ImageFilter.blur(sigmaX, sigmaY, TileMode.clamp)'`.

**Solution**:
- Added `_extractMaxBlurSigma(ui.ImageFilter?)` — regex extracts sigma from `toString()`
- `_lowSigmaThreshold = 2.0` — suppress cheap blurs entirely
- `_highSigmaThreshold = 10.0` — critical severity for expensive blurs
- Sigma included in expensive node detail and highlight detail (`σ=X.X`)

**Files**: `gpu_pressure_detector.dart`, `gpu_pressure_detector_test.dart`
**Tests**: 6 new tests (low sigma suppressed, boundary, medium flagged, critical highlight, warning highlight, detail includes sigma)

---

## Adversarial Review Findings (v11.7–v11.12)

3 bugs found and fixed, 3 test gaps filled:

| # | Type | Detector | Finding | Resolution |
|---|------|----------|---------|------------|
| 1 | Bug | Opacity | `_insideAnimatedOpacity` not reset in `dispose()` — stale counter after dispose/reuse | Added `_insideAnimatedOpacity = 0` to `dispose()` |
| 2 | Bug | FontLoading | `runtime_font_loading` confidence too high (`likely`) — `fontFamilyFallback` is a heuristic that can produce false positives | Downgraded to `IssueConfidence.possible` |
| 3 | Bug | GpuPressure | BackdropFilter sigma extracted twice (once for early return, once for detail enrichment) | Refactored to extract once into `backdropSigma` variable reused in both paths |
| 4 | Test | GpuPressure | No test for sigma at exact boundary (σ=3.0) | Added boundary test verifying sigma 3.0 is flagged (above `_lowSigmaThreshold` 2.0) |
| 5 | Test | GpuPressure | No test for non-blur ImageFilter (e.g. `ImageFilter.dilate`) | Added test with `_BackdropFilterNonBlur` widget verifying non-blur filters still flagged |
| 6 | Test | FontLoading | No test for `runtime_font_loading` and `multiple_custom_fonts` coexistence | Added coexistence test verifying both issues emitted simultaneously |

---

## Verification (v11.7–v11.12)

- `fvm flutter test` — 1,594 tests passing ✅
- `fvm flutter analyze` — 0 issues ✅

---

# v11 Detector Audit — Part 3 (v11.13–v11.18)

6 milestones. Third audit pass covering runtime detector enrichment: duplicate detection,
cross-scan identity tracking, subtree cost metrics, and thread attribution.

## P1 — Accuracy & False Positive Reduction

### v11.13: Builder widget suppression (FrameTimingDetector) ✅

**Problem**: Builder widgets (`StreamBuilder`, `FutureBuilder`, `ValueListenableBuilder`) are
designed to rebuild frequently. Default jank thresholds flag normal reactive rebuilds as issues.

**Solution**:
- Added 3x threshold multiplier for builder-pattern widgets during jank evaluation
- Builder widgets identified by type name matching against known builder set
- Reduces false positive jank warnings during normal reactive data flow

**Files**: `frame_timing_detector.dart`, `frame_timing_detector_test.dart`
**Tests**: Builder suppression applied, non-builder widgets not suppressed

### v11.14: Warmup frame suppression (FrameTimingDetector) ✅

**Problem**: App startup triggers expensive initialization (loading assets, building initial widget
tree, shader warmup). These frames are always slow and produce spurious jank issues.

**Solution**:
- Added `warmupFrameCount` parameter (default 180 ≈ 3s at 60fps)
- Frames within warmup window are excluded from jank evaluation
- Configurable via `SleuthConfig.frameTimingWarmupFrameCount`
- Test controllers pass `frameTimingWarmupFrameCount: 0` to avoid warmup interference

**Files**: `frame_timing_detector.dart`, `sleuth_controller.dart`, `frame_verdict_fallback_test.dart`, `issue_ranking_integration_test.dart`
**Tests**: Warmup frames suppressed, post-warmup jank detected, configurable via SleuthConfig

## P2 — Detection Gaps

### v11.15: Duplicate request detection (NetworkMonitorDetector) ✅

**Problem**: Multiple identical HTTP requests within a short window (e.g., 3+ GETs to the same
endpoint within 500ms) indicate missing caching, redundant widget fetches, or rebuild-triggered
API calls. Not detected.

**Solution**:
- Added `_evaluateDuplicates()` method called from `_evaluate()`
- Groups recent records by `method + _normalizeUrl(url)` (strips query params)
- Sliding window cluster detection: sorts by `startedAt`, finds max cluster within 500ms window
- Constants: `_duplicateWindowMs=500`, `_duplicateThreshold=3`, `_criticalDuplicateThreshold=10`
- Indexed stableIds: `duplicate_request:0`, `duplicate_request:1` for per-endpoint tracking
- `FixHintBuilder.duplicateRequest()` for caching/dedup hints

**Key challenge**: Sliding window `maxCluster` must use `if (clusterSize > maxCluster)` guard —
direct assignment overwrites previous larger cluster values when the window slides.

**Files**: `network_monitor_detector.dart`, `fix_hint_builder.dart`, `network_monitor_detector_test.dart`
**Tests**: 11 tests — 3+ duplicates flagged, 2 not flagged, different endpoints not flagged,
different methods not flagged, critical at 10+, boundary 500ms/501ms, maxCluster regression

### v11.16: GlobalKey recreation detection (GlobalKeyDetector) ✅

**Problem**: GlobalKeys recreated in `build()` (instead of stored in `State`) cause framework to
unmount and remount subtrees every frame. Expensive and invisible to other detectors.

**Solution**:
- Added `_prevKeyIds` / `_currentKeyIds` sets tracking `identityHashCode(key)` per scan
- `checkElement` collects identity hashes for all GlobalKey-bearing widgets
- `finalizeScan` calls `_evaluateKeyRecreation()`:
  - Computes `newKeys = current - prev`, `goneKeys = prev - current`
  - `churnCount = min(newKeys.length, goneKeys.length)` — symmetric churn = recreation
  - Asymmetric changes (navigation: many new, few gone) filtered out
- Configurable `recreationThreshold` (default 5)
- `FixHintBuilder.globalKeyRecreation()` — store keys in State fields
- Confidence: `likely` (cross-scan identity is strong signal but not direct observation)

**Files**: `global_key_detector.dart`, `fix_hint_builder.dart`, `global_key_detector_test.dart`
**Tests**: 8 tests — first scan no issue, recreation flagged, stable keys not flagged,
navigation filtered, below threshold not flagged, critical at 3x, dispose resets, fixHint content

## P3 — Enrichment

### v11.17: KeepAlive subtree cost enrichment (KeepAliveDetector) ✅

**Problem**: `KeepAliveDetector` reports page count but not subtree cost. 5 keep-alive pages with
10 elements each is very different from 5 pages with 500 elements each.

**Solution**:
- Added `totalElements` field to `_ScrollableAccumulator`
- `checkElement` increments `totalElements` for all active accumulators on every element
- `afterElement` includes `totalElements` in scrollable data record
- `finalizeScan` computes `avgSubtreeSize = totalElements ~/ count` and includes in detail

**Files**: `keep_alive_detector.dart`, `keep_alive_detector_test.dart`
**Tests**: 2 new tests — subtree size reported in detail, heavy pages produce higher counts

### v11.18: Thread-attributed jank classification (FrameTimingDetector) ✅

**Problem**: Jank frames reported without distinguishing UI-thread vs raster-thread bottleneck.
Developers can't tell if the fix is in build/layout code or in painting/compositing.

**Solution**:
- Added `_classifyJankBottleneck()` returning `_JankBottleneck(label, summary)`
- Classification logic:
  - **Pipeline stall**: `buildToRasterGap > budget/4` AND both threads individually under budget
  - **UI-bound**: `uiDuration > rasterDuration`
  - **Raster-bound**: otherwise
  - **Mixed**: fallback when no clear signal
- Title includes bottleneck label; detail includes thread timing summary

**Files**: `frame_timing_detector.dart`, `frame_timing_detector_test.dart`
**Tests**: 6 tests — UI-bound, raster-bound, pipeline stall, mixed, detail counts, no attribution without jank

---

## Adversarial Review Findings (v11.13–v11.18)

5 findings identified and fixed:

| # | Type | Detector | Finding | Resolution |
|---|------|----------|---------|------------|
| 1 | Bug | NetworkMonitor | `maxCluster` direct assignment overwrote previous larger cluster when window slides | Added `if (clusterSize > maxCluster)` guard |
| 2 | Convention | NetworkMonitor | `duplicate_request` stableId shared across endpoint groups — breaks per-issue tracking | Changed to `duplicate_request:$dupIndex` indexed stableId |
| 3 | Test | NetworkMonitor | No test for cluster at exact 500ms boundary | Added boundary test (500ms → clustered, 501ms → split) |
| 4 | Test | NetworkMonitor | No test for maxCluster regression (larger cluster followed by smaller) | Added regression test verifying max is preserved |
| 5 | Test | NetworkMonitor | Existing "3 simultaneous issues" test broke due to new duplicate detection on same-URL records | Fixed by using different URLs per record |

---

## Verification (v11.13–v11.18)

- `fvm flutter test` — 1,631 tests passing ✅
- `fvm flutter analyze` — 0 issues ✅
- Adversarial review completed, all findings resolved

---

# Part 4: Sliver Anti-Pattern Detection (v11.19)

## P1 — Detection Gap

### v11.19: Sliver anti-pattern detection (ListviewDetector) ✅

**Problem**: Three common CustomScrollView misuse patterns are invisible to all 22 detectors:
SliverToBoxAdapter wrapping large Column/Row subtrees, SliverFillRemaining(hasScrollBody: false)
with scrollable children, and SliverToBoxAdapter wrapping shrinkWrap scrollables. Adjacent to
ListviewDetector's existing non-lazy list checks.

**Solution**:
- **Check A — SliverToBoxAdapter + large Column/Row**: `_insideSliverToBoxAdapter` depth counter
  incremented in `checkElement`, decremented in `afterElement`. `_checkSliverToBoxAdapterChild()`
  recursive wrapper traversal (same pattern as `_checkForNonLazyList`) finds Column/Row through
  Padding/SizedBox/Center wrappers. Warning at >50 children (shared `childThreshold`), critical
  at >150 (3x). StableId: `sliver_to_box_adapter_large`.
- **Check B — SliverFillRemaining(hasScrollBody: false) + scrollable child**:
  `_insideSliverFillNoScroll` depth counter — only increments when `hasScrollBody == false`.
  Scrollable findings (ListView, GridView, CustomScrollView, SingleChildScrollView) recorded in
  `_sliverFillFindings` deferred list, emitted in `finalizeScan()`. Always warning severity.
  StableId: `sliver_fill_remaining_scrollable`.
- **Check C — SliverToBoxAdapter + shrinkWrap scrollable**: Fires when inside SliverToBoxAdapter
  AND widget is ListView/GridView with `shrinkWrap == true`. Dedup: `!isNonLazy` guard skips
  if same widget already fired the non-lazy check. Always warning severity.
  StableId: `sliver_to_box_adapter_shrinkwrap`.
- 3 new `FixHintBuilder` methods: `sliverToBoxAdapterLarge()`, `sliverFillRemainingScrollable()`,
  `sliverToBoxAdapterShrinkWrap()`.
- Updated detector description to `'Detects non-lazy lists and sliver anti-patterns'`.

**Files**: `listview_detector.dart`, `fix_hint_builder.dart`, `listview_detector_test.dart`
**Tests**: 18 new tests — Check A (6: flag/threshold/Row/single-widget/wrapper/critical),
Check B (6: ListView/GridView/SingleChildScrollView/CustomScrollView flagged, hasScrollBody:true
not flagged, non-scrollable not flagged), Check C (4: ListView/GridView flagged, shrinkWrap:false
not flagged, non-lazy dedup), dispose (1), existing regression confirmed (1)

---

## Adversarial Review Findings (v11.19)

2 findings identified and fixed:

| # | Type | Detector | Finding | Resolution |
|---|------|----------|---------|------------|
| 1 | Bug | ListviewDetector | Check B: `SingleChildScrollView` inside `SliverFillRemaining(hasScrollBody: false)` caught by earlier `SingleChildScrollView` branch — Check B finding never recorded (false negative) | Added Check B recording inside the `SingleChildScrollView` branch when `_insideSliverFillNoScroll > 0`. Removed dead `widget is SingleChildScrollView` from later branch. |
| 2 | Test | ListviewDetector | No test coverage for Check B with `SingleChildScrollView` or `CustomScrollView` descendants | Added 2 tests covering both scrollable types inside `SliverFillRemaining(hasScrollBody: false)` |

---

## Verification (v11.19)

- `fvm flutter test` — 1,648 tests passing ✅
- `fvm flutter analyze` — 0 issues ✅
- Adversarial review completed, all findings resolved

---

## Pillar 2a: Hot-Path Performance Optimization (v0.10.5)

**Status: 3/3 milestones shipped** ✅

Origin: Profile-guided audit of Sleuth's own runtime overhead. Investigation revealed
`runtimeType.toString()` string allocation is the dominant per-element cost during the
unified tree walk — not virtual dispatch overhead, not issue deduplication (already O(n)),
and not element-type batching (negligible after toString fix).

---

### Pillar 2a M1: Widget Type Name Cache (P0)

**Effort:** Medium | **Theme:** Performance | **Impact:** P0 — eliminates ~40-60% of tree walk allocation pressure

**Problem:** `widget.runtimeType.toString()` called per-element in 3 detectors' `checkElement()` unconditionally (RebuildDetector, KeepAliveDetector, RepaintDetector) plus `buildAncestorChain()` in widget_location.dart. On a 5K-element tree with ~50 unique widget types, creates 15,000+ duplicate string allocations per scan.

**Solution:** Shared `TypeNameCache` — a `Map<Type, String>` module-level singleton (follows existing `sourceLocationCache` pattern). Cleared once per scan by `SleuthController` before the unified tree walk. Detectors call `typeNameCache.lookup(widget)` instead of `widget.runtimeType.toString()`. Lazily computes each type's string once, turning O(elements x detectors) allocations into O(unique_types).

**Key design decision:** Module-level singleton rather than passing as parameter to `checkElement()`. Avoids changing the `BaseDetector` API, which would break custom detectors.

**Files changed:** `lib/src/utils/type_name_cache.dart` (new), `sleuth_controller.dart`, 11 detectors (`rebuild_detector`, `keep_alive_detector`, `repaint_detector`, `global_key_detector`, `setstate_scope_detector`, `nested_scroll_detector`, `repaint_boundary_detector`, `listview_detector`, `layout_bottleneck_detector`, `shallow_rebuild_risk_detector`), `widget_location.dart`.

**Tests:** 6 new (cache correctness, identity caching, clear behavior, lazy population, generic types).

---

### Pillar 2a M2: Highlight Generation Dirty-Check (P1)

**Effort:** Low | **Theme:** Performance | **Impact:** P1 — eliminates unnecessary overlay repaint every scan cycle

**Problem:** `_collectHighlights()` unconditionally increments `_highlightGeneration` and rebuilds the highlight list every scan. Triggers `CustomPainter.shouldRepaint()` even when no highlights exist (common case: no issues detected, overlay enabled).

**Solution:** Zero-highlights fast path: if no detector has highlights AND previous list was empty, skip the list spread, generation increment, and notifier update entirely. Includes defensive `selectedHighlightNotifier` null-clear for belt-and-suspenders safety.

**Key challenge:** Highlights include `Rect` values that change on scroll. The dirty-check only applies to the zero→zero case. When highlights exist, full collection always runs to propagate rect updates.

**Files changed:** `lib/src/controller/sleuth_controller.dart`.

**Tests:** 3 new (generation stable on zero→zero, increments on appear, increments on disappear).

---

### Pillar 2a M3: Timeline Parser Case-Matching (P2)

**Effort:** Low | **Theme:** Performance | **Impact:** P2 — minor allocation reduction off the tree-walk hot path

**Problem:** `TimelineParser.parse()` calls `.toLowerCase()` on every event's `name` and `cat` fields, creating 2 string allocations per event. For a 500-event batch, that's 1,000 allocations.

**Solution:** Direct multi-case matching for all known Flutter timeline event name variants across v2.x and v3+ (e.g., `BUILD`/`build`/`Build`, `LAYOUT (root)`/`layout (root)`, `GPURasterizer::Draw`/`gpurasterizer::draw`). Eliminates both `toLowerCase()` calls.

**Key constraint:** Must cover all known case variants explicitly. Flutter event naming is stable and well-documented across versions, but the approach is inherently more fragile than toLowerCase for unknown future variants.

**Files changed:** `lib/src/vm/timeline_parser.dart`.

**Tests:** All 28 existing timeline parser tests pass (cover all case variants).

---

### Skipped Optimizations (with justification)

| Optimization | Why skipped |
|---|---|
| Issue deduplication hash-set | Already O(n) via `Map` in `DetectorCorrelator` |
| Tree walk short-circuiting | Breaks accumulator detectors (RebuildDetector, SetStateScopeDetector) |
| Element-type batching | <1% gain after M1 eliminates toString cost |
| Ranker allocation | Already uses Dart 3 records, short-circuits for ≤1 issue |
| `copyWith` in `_aggregateIssues` | ~50 copies per scan, negligible |

---

## Adversarial Review Findings (Pillar 2a)

1 defensive fix applied, 4 false alarms dismissed with code path traces:

| # | Type | Component | Finding | Resolution |
|---|------|-----------|---------|------------|
| 1 | Fragility | M2: `_collectHighlights` | `selectedHighlightNotifier` could theoretically persist stale during zero→zero fast path | Added defensive null-clear. Traced all paths — scenario can't happen in practice (non-empty→empty always triggers full collection first). |
| 2 | False alarm | M2: `pendingIssueSelection` | Claimed pending selection lost when dirty-check skips | Verified: pending fulfillment code is outside `_collectHighlights()`, always executes. |
| 3 | False alarm | M1: Custom detector cache | Claimed cache stale for custom detector `scanTree()` | Custom detectors run in same scan cycle — cache entries valid. Reuse is beneficial. |
| 4 | False alarm | M3: Missing event names | Claimed old code matched `buildscope`/`flushlayout` | Verified: old `_isBuild` was `name == 'build'`, does NOT match `'buildscope'`. |
| 5 | Convention | M3: Timeline fragility | Multi-case matching less future-proof than toLowerCase | Accepted: known variants well-covered, naming stable across Flutter versions. |

---

## Verification (Pillar 2a)

- `fvm flutter test` — 1,657 tests passing ✅
- `fvm flutter analyze` — 0 issues ✅
- Adversarial review completed, all findings resolved

---

## Pillar 2b: Performance — Resource Management

**Status: 4/4 milestones shipped + adversarial review complete** (v0.10.6)

Reduces Sleuth's own CPU, memory, and GC pressure when the app is healthy. Follows Pillar 2a (hot-path performance, v0.10.5) which targeted tree walk allocations. Pillar 2b targets idle overhead — the cost Sleuth pays when it's running but the app has no issues.

**Area 10 (Encyclopedia precomputation) was skipped** — `IssueExplanationBuilder._explanations` is already a `static const Map` with O(1) lookup and zero runtime allocations. <1% overhead.

---

### M7: Debug Callback TypeNameCache (smallest scope, shipped first)

**Problem:** `_handleRebuildDirtyWidget` and `_handleProfilePaint` in `DebugInstrumentationCoordinator` call `element.widget.runtimeType.toString()` per rebuild/paint callback. At 1,000 rebuilds/sec, that's 1,000 string allocations/sec. The global `TypeNameCache` (Pillar 2a M1) is cleared every scan cycle, so it can't be reused for continuous-callback paths.

**Solution:** Private `Map<Type, String> _typeNames` inside coordinator. Never cleared between snapshots (persists for maximum hit rate, bounded by unique widget types ~50–200). Only cleared in `dispose()`.

**Files modified:**
- `lib/src/debug/debug_instrumentation_coordinator.dart` — `_typeNames` map, `_typeName()` helper, 2 call site replacements, `dispose()` clear
- `test/debug/debug_instrumentation_coordinator_test.dart` — 2 tests: cache avoids repeated allocations, cache persists across snapshot windows

---

### M4: Adaptive Scan Frequency (highest CPU impact)

**Problem:** Fixed `Timer.periodic(1000ms)` in `startTreeScanning()` fires every second regardless of app health. On a 3,000-element app, each scan costs ~80ms. When the app is healthy (0 issues), this is wasted CPU.

**Solution:** Replaced `Timer.periodic` with self-rescheduling `Timer`. Backs off to `min(treeScanIntervalMs * 2, 2000ms)` after 3 consecutive clean (zero-issue) scan cycles. Returns to normal interval immediately when issues appear. `FrameTiming` callbacks and VM timeline processing remain event-driven and unaffected.

**Config:** `SleuthConfig.adaptiveScanEnabled` (default `true`). Set `false` for fixed interval.

**Design decisions:**
- Only the tree walk timer is adaptive. Frame timing and VM timeline are event-driven — zero added latency.
- `RebuildDetector._hotTypes` normalizes to per-second rates via `DebugSnapshot.elapsed`, so longer intervals preserve accuracy.
- 3-consecutive threshold prevents thrashing on issue flicker.
- Max 2000ms cap bounds worst-case detection latency.

**Files modified:**
- `lib/src/controller/sleuth_controller.dart` — `_consecutiveCleanScans`, `_currentScanIntervalMs`, `_scheduleNextScan()`, `SleuthConfig.adaptiveScanEnabled`
- `test/controller/adaptive_scan_test.dart` (new) — 7 tests: back-off, return-to-normal, flicker debounce, opt-out, small/large interval caps, dispose safety

---

### M5: Issue Allocation Reduction

**Problem:** `_getAllIssues()` creates a new list via `[for (d in _detectors) ...d.issues]` and is called 4+ times during timeline data arrival. Each call allocates a fresh list even when no detector has produced new issues.

**Solution:** Generation-counter cache. `_issueGeneration` increments when detectors produce fresh issues (after structural scans, timeline evaluateNow, and frame stats updates). `_getAllIssues()` returns the cached list when `_cachedIssueGeneration == _issueGeneration`.

**Stamp-skip optimization (Part A) was rejected:** Detectors recreate fresh unstamped issues each `finalizeScan()`, so `copyWith` is always needed for route/interaction/debugMode stamping.

**Files modified:**
- `lib/src/controller/sleuth_controller.dart` — `_issueGeneration`, `_cachedIssueGeneration`, `_cachedAllIssues`, generation increments in 3 code paths
- `test/controller/issue_allocation_test.dart` (new) — 4 tests: cache reuse, fresh list after scan, generation independence, cache + adaptive tracking interaction

---

### M6: Detector Lazy Initialization

**Problem:** All 22 detectors instantiated eagerly in `_initializeDetectors()` regardless of `config.enabledDetectors`. Each detector allocates internal buffers. A user enabling only 5 detectors still pays construction cost for all 22.

**Solution:** Factory-map pattern. `Map<DetectorType, BaseDetector Function()>` with 19 entries for non-typed detectors. Only detectors present in `enabledDetectors` are constructed. 3 typed detectors (`_frameTiming`, `_memoryPressure`, `_networkMonitor`) always constructed — they have special access patterns beyond the `BaseDetector` interface. Custom detectors always present.

**Runtime toggling:** `enableDetector(DetectorType)` constructs from factory map and adds to `_detectors`. `disableDetector(DetectorType)` removes from list. Both defer list mutations if called during an active scan iteration (see adversarial review finding #2/#3).

**Design decision:** Typed detectors kept as `late final` (not nullable) to avoid ~20 null-check sites across the codebase. Their `isEnabled` flag gates detection logic.

**Files modified:**
- `lib/src/controller/sleuth_controller.dart` — factory map, `enableDetector()`, `disableDetector()`, typed detector `isEnabled` flag-flipping
- `test/controller/lazy_detector_test.dart` (new) — 8 tests: partial init, default 22, runtime enable/disable, typed flag toggle, custom detectors, idempotent enable, partial scan correctness

---

## Adversarial Review Findings (Pillar 2b)

Scope: All Pillar 2b changes in `sleuth_controller.dart` and `debug_instrumentation_coordinator.dart`.

| # | Type | Component | Finding | Resolution |
|---|------|-----------|---------|------------|
| 1 | Bug | `_scheduleNextScan` | Timer leak: dispose during mid-flight callback creates infinite orphan timer chain | Added `if (_disposed) return;` guard at 3 points in `_scheduleNextScan` |
| 2 | Fragility | `disableDetector` | `removeWhere` could throw ConcurrentModificationError if called from notifier listener during scan | Added `_isIteratingDetectors` flag; mutations deferred to `_pendingDetectorMutations`, drained after iteration |
| 3 | Fragility | `enableDetector` | `add` same concurrent modification risk as #2 | Same deferred-mutation pattern |
| 4 | Fragility | `startTreeScanning` | Rapid start/stop creates parallel timer chains via stale post-frame callbacks | Added `_scanTimerGeneration` counter; stale callbacks bail on generation mismatch |
| 5 | Convention | `_issueGeneration` | Int overflow after millions of cycles | Safe: 64-bit int at 3 increments/sec = ~97 billion years |
| 6 | Convention | `_typeNames` | Not cleared in `snapshot()` | Correct by design: type names don't change at runtime, cleared in `dispose()` |
| 7 | Convention | `_detectorFactories` | Stale config if SleuthConfig replaced | Not possible: `config` is `final` on controller, set once in constructor |

---

## Verification (Pillar 2b)

- `fvm flutter test` — 1,678 tests passing ✅
- `fvm flutter analyze` — 0 issues ✅
- All 4 milestones + 3 adversarial review fixes shipped
- All roadmaps complete: v7 (10/10), v8 (5/5), v9 (17/17), v10 (12/12), v11 (19/19), Pillar 2a (3/3), Pillar 2b (4/4)
