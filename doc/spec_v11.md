## v11 Detector Audit: Gaps, False Positives & Hot-Path Performance

**Status: 19/19 milestones + Pillar 2a (3 milestones) + Pillar 2b (4 milestones) + Pillar 3a (5 milestones) + Pillar 3b (4 milestones) + Pillar 4 (10 milestones) + Pillar 5 Part 1 (7 milestones) + Pillar 5 Part 2 (7 milestones) + Pillar 6 Part 1 (7 milestones) + Pillar 6 Part 2 (8 milestones) + v0.12.2 hardening (3 fixes) shipped** ✅ (v0.10.5 / v0.10.6 / v0.10.7 / v0.10.8 / v0.10.9 / v0.11.0 / v0.11.1 / v0.12.0 / v0.12.1 / v0.12.2)

Origin: Adversarial audit (2026-04-07) of 5 detectors (ListviewDetector, NestedScrollDetector, LayoutBottleneckDetector, SetStateScopeDetector, RepaintBoundaryDetector). Found 6 gaps and false positives across detection coverage, accuracy, and enrichment. All milestones implemented, adversarial-reviewed twice (8 fix-round findings resolved), 1,869 tests passing, 0 analysis issues.

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

---

## Pillar 3a: Enrichment — Analysis & Tracking (v0.10.7)

**Status: 5/5 milestones shipped** ✅

Enrichment features that deepen diagnostic intelligence beyond per-frame detection:
causal chain expansion, historical trending, interaction context enrichment, widget
heat map aggregation, and fix verification.

---

### Pillar 3a.1: Expanded Causal Chain Rules

**Effort:** Low | **Theme:** Enrichment | **Impact:** P1 — connects more root causes to downstream effects

Added 15 new `CausalRule` entries (8 logical patterns) to `causal_graph.dart`:

- `setstate_scope` → `rebuild_debug_*` (high setState scope causes widget rebuilds)
- `uncached_images` → `gc_pressure` (uncached images stress GC)
- `excessive_keep_alive:*` → `gc_pressure` (too many keep-alive pages stress GC)
- `animated_builder_no_child` → `excessive_repaint` / `excessive_repaint_debug`
- `layout_bottleneck` → `sustained_jank` / `jank_detected`
- `runtime_font_loading` / `multiple_custom_fonts` → `sustained_jank` / `jank_detected`
- `platform_channel_traffic` → `heavy_compute`
- `duplicate_request:*` → `rebuild_activity` / `rebuild_debug_*`

Total rule count: 37 → 52. 14 new tests.

**Files modified:**
- `lib/src/analyzer/causal_graph.dart` — 15 new rules, updated count comment
- `test/analyzer/causal_graph_test.dart` — 14 new tests

---

### Pillar 3a.2: Historical Trending Time-Series

**Effort:** Medium | **Theme:** Enrichment | **Impact:** P1 — enables trend-based insights (worsening/improving/intermittent)

New `RecurrenceTrend` model: ring-buffered (capacity 60) per-issue presence/absence tracker.

- `RecurrenceEntry(scanCycle, present, severity)` — individual data points
- `TrendDirection` enum: worsening, improving, stable, intermittent
- `computeTrend(window)` — compares severity average of first half vs second half; ≥3 transitions = intermittent
- `isStale(currentScanCycle)` — evicts after 120 absent cycles
- `toJson()` — summary-only (trend + counts, not raw ring buffer)
- `SleuthController._recurrenceTrends` replaces flat `_recurrenceCounts`
- `_updateRecurrence()` rewritten: records presence/absence per cycle, evicts stale entries
- `_buildRankingContext()` derives recurrence counts from trends (filtered to present-only, clamped 0–5)
- `recurrenceCountsForTest` backward-compatible: only returns entries where last entry is present

**Files modified:**
- `lib/src/models/recurrence_trend.dart` (new) — RecurrenceTrend, RecurrenceEntry, TrendDirection
- `lib/src/controller/sleuth_controller.dart` — replaced _recurrenceCounts, rewrote _updateRecurrence
- `test/models/recurrence_trend_test.dart` (new) — 19 tests

---

### Pillar 3a.3: Interaction Context Enrichment

**Effort:** Medium | **Theme:** Enrichment | **Impact:** P1 — keyboard/typing and app lifecycle awareness for issue stamping

- Added `typing` and `appLifecycle` to `InteractionContext` enum with priority ordering
- `onKeyboardVisibilityChanged(visible)`: detects keyboard via `WidgetsBindingObserver.didChangeMetrics()`, viewInsets.bottom delta. Debounced hide→idle transition (300ms)
- `onAppLifecycleChanged(AppLifecycleState)`: sets `appLifecycle` on paused/inactive, returns to idle on resumed
- Priority guards: typing does not downgrade from navigating; scrolling does not downgrade from typing
- `appLifecycle` deprioritized in ranking alongside `scrolling` (transient context)
- Overlay: `_SleuthOverlayState` implements `WidgetsBindingObserver` with `didChangeMetrics()`, `didChangeAppLifecycleState()`, `reassemble()`

**Files modified:**
- `lib/src/models/performance_issue.dart` — added `typing`, `appLifecycle` to enum
- `lib/src/controller/sleuth_controller.dart` — keyboard/lifecycle handlers, priority guards
- `lib/src/ui/sleuth_overlay.dart` — WidgetsBindingObserver mixin, metric/lifecycle forwarding
- `lib/src/ranking/issue_ranker.dart` — appLifecycle transient deprioritization
- `test/controller/interaction_context_test.dart` — 8 new tests

---

### Pillar 3a.4: Widget Heat Map Aggregation

**Effort:** Medium | **Theme:** Enrichment | **Impact:** P1 — surfaces "top offending" widgets by cumulative impact

New `WidgetHeatMapEntry` model and `buildWidgetHeatMap()` function.

- Aggregates issues by `widgetName`, computing issueCount, totalRankingScore, detectorStableIds, worstSeverity
- Filters ~50 framework widget names (`_frameworkPrefixes`): layout primitives, scrollables, scaffold/chrome, builders, buttons, painting/clipping, sizing constraints, text
- Sorted by totalRankingScore descending, capped at `maxEntries` (default 10)
- Round-trip JSON serialization (toJson/fromJson)
- Included in `SessionSnapshot` export as `widgetHeatMap`

**Files modified:**
- `lib/src/models/widget_heat_map_entry.dart` (new) — model, builder, framework filter
- `lib/src/models/session_snapshot.dart` — added widgetHeatMap field + serialization
- `lib/src/controller/sleuth_controller.dart` — exportSnapshot includes heat map
- `lib/sleuth.dart` — export widget_heat_map_entry.dart
- `test/models/widget_heat_map_test.dart` (new) — 9 tests

---

### Pillar 3a.5: Fix Verification

**Effort:** Medium | **Theme:** Enrichment | **Impact:** P1 — enables objective before/after comparison for performance fixes

- `FixBaseline`: captures per-issue snapshots (severity, rankingScore), tracks consecutiveAbsentCycles per stableId
- `FixVerificationResult`: comparison result with per-issue `IssueVerificationEntry` categorized as resolved/improved/unchanged/worsened/newIssue
- Resolution requires 5 consecutive absent cycles (cooldown)
- Severity comparison: lower severity or score delta < -10 = improved; higher or > +10 = worsened
- 3-cycle hot-reload grace period: `notifyReassemble()` resets grace counter and clears absence counters
- Public API: `Sleuth.captureBaseline()`, `Sleuth.compareToBaseline()`, `Sleuth.hasBaseline`, `Sleuth.clearBaseline()`

**Files modified:**
- `lib/src/models/fix_verification_result.dart` (new) — FixBaseline, FixVerificationResult, BaselineIssueSnapshot, captureFixBaseline()
- `lib/src/controller/sleuth_controller.dart` — baseline state, grace period, notifyReassemble
- `lib/src/ui/sleuth_overlay.dart` — reassemble() forwarding
- `lib/sleuth.dart` — exports + static API methods
- `test/models/fix_verification_test.dart` (new) — 12 tests

---

## Adversarial Review Findings (Pillar 3a)

| # | Type | Component | Finding | Resolution |
|---|------|-----------|---------|------------|
| 1 | Bug | `widget_heat_map_entry.dart` | `_frameworkPrefixes` missing ListView, GridView, Scaffold, AppBar, buttons, etc. | Added 18 framework widgets across scrollable, scaffold/chrome, and button categories |
| 2 | Bug | `sleuth_controller.dart` | `notifyReassemble()` sets grace period but doesn't reset absence counters — false resolution after hot reload | Added `_fixBaseline!.consecutiveAbsentCycles.clear()` in `notifyReassemble()` |

---

## Verification (Pillar 3a)

- `fvm flutter test` — 1,741 tests passing ✅
- `fvm flutter analyze` — 0 issues ✅
- All 5 milestones + 2 adversarial review fixes shipped
- All roadmaps complete: v7 (10/10), v8 (5/5), v9 (17/17), v10 (12/12), v11 (19/19), Pillar 2a (3/3), Pillar 2b (4/4)

---

## Pillar 3b: Enrichment — Output & Presentation (v0.10.8)

**Status: 4/4 milestones shipped** ✅

Pillar 3b completes the enrichment pillar by improving how Sleuth communicates diagnostics — richer exports, confidence explanations, severity escalation, and precise source locations.

### 3b.6 — Confidence Explanation

Added `confidenceReason` field (`String?`) to `PerformanceIssue`. Each of the 22 detectors sets the reason at issue-creation time using tier templates:
- **Confirmed**: "Measured directly from {source}"
- **Likely**: "{evidence1} + {evidence2}"
- **Possible**: "Structural scan only — {upgrade hint}"

The 3 existing correlator escalation rules and 2 new rules (see 3b.7) append `[Correlated] Upgraded from possible: ...` when upgrading confidence. IssueCard displays the reason as a `Tooltip` on the confidence badge.

**Files:** `performance_issue.dart`, all 22 detectors, `detector_correlator.dart`, `issue_card.dart`

### 3b.7 — Severity Auto-Escalation

**Part A — Duration-based escalation:** In `_aggregateIssues()`, after correlation and before ranking, warning-severity issues with `RecurrenceTrend.presentCount >= 30` (cumulative) are escalated to critical. Append `[Auto-escalated: persisted for N scan cycles]` to confidenceReason.

**Part B — Structural + runtime correlation (2 new rules):**
- `EscalateStructuralWithJankRule`: non_lazy_list, layout_bottleneck, nested_scroll (+ variants) upgrade possible→likely when sustained_jank/jank_detected co-occurs
- `EscalateStructuralWithRebuildRule`: animated_builder_no_child, setstate_scope upgrade possible→likely when rebuild_activity/rebuild_debug_* co-occurs

**Files:** `sleuth_controller.dart`, `detector_correlator.dart`

### 3b.8 — Code Location Precision

Enhanced `buildAncestorChain()` to append source location for each non-framework ancestor (not just leaf). Format: `"HomeScreen (lib/screens/home.dart:42) > Column > MyWidget (lib/widgets/my.dart:15)"`. Profile mode degrades gracefully (no locations appended).

Added `lookupStructured()` to `SourceLocationCache` returning `({String location, String? packageName})?`. Added `extractPackageName()` static method parsing `/packages/{name}/lib/` from paths. Added `packageName` field to `PerformanceIssue`.

**Files:** `source_location_cache.dart`, `widget_location.dart`, `performance_issue.dart`

### 3b.9 — Session Summary Export

Added `sessionSummary` field (`Map<String, dynamic>?`) to `SessionSnapshot`. Computed lazily at export time via `_buildSessionSummary()` with 5 fields:

1. **topIssues** — Top 5 by rankingScore (stableId, title, severity, confidence, confidenceReason, rankingScore, widgetName)
2. **causalEdges** — Active cause→effect pairs via `CausalGraphRule.activeEdges()`
3. **frameHistogram** — Duration bins: `<16ms`, `16-33ms`, `33-50ms`, `50-100ms`, `>100ms`
4. **detectorHitRates** — Issue count per detector via stableId prefix mapping
5. **memoryTrendSummary** — startBytes, endBytes, peakBytes, growthRatePerSec, sampleCount

Schema version bumped from 2 → 3. Backward compatible with v2 exports.

**Files:** `session_snapshot.dart`, `sleuth_controller.dart`, `causal_graph.dart`

### Adversarial Review Findings (Pillar 3b)

| # | Type | Component | Finding | Resolution |
|---|------|-----------|---------|------------|
| 1 | Bug | `sleuth_controller.dart` | `_detectorNameFromStableId()` missing entries for `shader_compilation`, `repaint_debug_`, `stateful_density` — fell through to 'custom' | Added 3 entries to prefix map |

---

### Full Branch Adversarial Review (Pillars 1-3)

Comprehensive adversarial review of all 78 changed files (8,880 insertions) across all 3 pillars. Covered 7 attack vectors: logic bugs & correctness, detection accuracy, performance & resource leaks, serialization & backward compatibility, correlator & escalation interactions, UI correctness, test coverage gaps.

| # | Severity | Component | Finding | Resolution |
|---|----------|-----------|---------|------------|
| 1 | HIGH | `sleuth_controller.dart` | Adaptive scan chain dies on first detector exception — `_isIteratingDetectors` stuck true, timer chain broken | Wrapped scan body in `try/finally` (always clears guard, drains mutations); wrapped callback in `try/catch` (always reschedules) |
| 2 | HIGH | `network_monitor_detector.dart` | `duplicate_request:$dupIndex` uses unstable loop index — stableIds jitter as records age in/out | Derived stableId from method+URL hash fingerprint |
| 3 | MEDIUM | `network_monitor_detector.dart` | POST/PUT/PATCH requests flagged as duplicates despite potentially different payloads | Limited duplicate detection to idempotent methods (GET/HEAD/OPTIONS) |
| 4 | MEDIUM | `global_key_detector.dart` | Cross-scan key recreation comparison not scoped to route — page transitions produce false `global_key_recreation` warnings | Track scan root identity via `identityHashCode(context)`; reset `_prevKeyIds` on route change |
| 5 | MEDIUM | `detector_correlator.dart` | `EscalateStructuralWithJankRule._structuralIds` missing 5 new sliver IDs added in Pillar 1 | Added `non_lazy_sliver_list`, `non_lazy_sliver_grid`, `sliver_to_box_adapter_large`, `sliver_fill_remaining_scrollable`, `sliver_to_box_adapter_shrinkwrap` |

---

## Verification (Pillars 1-3)

- `fvm flutter test` — 1,791 tests passing ✅
- `fvm flutter analyze` — 0 issues ✅
- All 4 milestones + 1 Pillar 3b adversarial fix + 5 full branch adversarial fixes shipped
- All roadmaps complete: v7 (10/10), v8 (5/5), v9 (17/17), v10 (12/12), v11 (19/19), Pillar 2a (3/3), Pillar 2b (4/4), Pillar 3a (5/5), Pillar 3b (4/4)

---

## Pillar 4 — Issue Documentation Quality (v0.10.9)

**Status: 10/10 milestones shipped** ✅

### Summary

Comprehensive encyclopedia content for all 46 issue types with cross-references, enriched explanations, and quality guardrail tests.

### Milestones

| Milestone | Title | Priority |
|-----------|-------|----------|
| v11.20 | Add 8 missing encyclopedia entries (38→46) | P0 |
| v11.21 | Fix stale count + missing test coverage | P0 |
| v11.22 | readingTheData for all 46 entries | P1 |
| v11.23 | Enrich build-phase entries (heavy_compute, setstate_scope, animated_builder_no_child) | P1 |
| v11.24 | Enrich memory/image entries (gc_pressure, heap_growing, uncached_images) | P1 |
| v11.25 | Enrich paint/layout entries (excessive_repaint, missing_repaint_boundary, layout_bottleneck, opacity_zero) | P1 |
| v11.26 | Enrich raster/network/scroll entries (shader_compilation, platform_channel_traffic, non_lazy_list, nested_scroll_same_axis) | P1 |
| v11.27 | Add relatedIssues field + bidirectional cross-references | P2 |
| v11.28 | Render relatedIssues in encyclopedia UI + AI context | P2 |
| v11.29 | Content quality guardrail tests | P2 |

### Adversarial Review Findings (Pillar 4)

| # | Severity | Component | Finding | Resolution |
|---|----------|-----------|---------|------------|
| 1 | CRITICAL | `issue_encyclopedia_page.dart` | Related issue chip tap used single `_scrollTargetKey` — always scrolled to initial target, not the tapped chip's entry | Replaced single GlobalKey with per-entry key map (`Map<String, GlobalKey> _entryKeys`) |
| 2 | LOW | `issue_explanation_builder.dart` | `repaint_debug` was only runtime entry without relatedIssues (null) | Added cross-references to `excessive_repaint`, `excessive_repaint_debug`, `missing_repaint_boundary` + reverse entries |
| 3 | LOW | `issue_explanation_builder.dart` | 5 entries had readingTheData without metric patterns matching guardrail regex | Enriched `raster_cache_growing`, `gc_pressure`, `heavy_compute`, `expensive_gpu_nodes`, `excessive_repaint_debug` with numeric thresholds |

### Files Changed

| File | Change |
|------|--------|
| `lib/src/utils/issue_explanation_builder.dart` | 8 new entries, readingTheData for all 46, relatedIssues field + data, 14 entries enriched |
| `lib/src/ui/issue_encyclopedia_page.dart` | relatedIssues UI chips with scroll-to, per-entry GlobalKey map, search integration |
| `lib/src/utils/ai_context_builder.dart` | relatedIssues in system prompt |
| `test/utils/issue_explanation_builder_test.dart` | Quality guardrails, content assertions, relatedIssues validation |
| `test/ui/issue_encyclopedia_page_test.dart` | relatedIssues rendering + chip interaction tests |

---

---

## Pillar 5 Part 1: Demo Infrastructure & Missing Detector Demos (v0.11.0)

**Status: 7/7 milestones shipped** ✅

### Milestones

| Milestone | Title | Priority |
|-----------|-------|----------|
| M1 | DemoScaffold shared layout (collapsible banner + Expanded body) | P0 |
| M2 | Shader Jank demo (BackdropFilter, ShaderMask, ColorFiltered, Impeller caveat) | P0 |
| M3 | Platform Channel Traffic demo (rapid fire, sustained load, single call, log area) | P0 |
| M4 | Memory Pressure demo (Dart heap, native Uint8List, GC churn, visual bar chart) | P0 |
| M5 | GPU Pressure demo (4 stacked GPU layers, >5 descendants, diagonal clip) | P0 |
| M6 | Missing RepaintBoundary demo (SingleChildScrollView, Opacity(0.7), animated CustomPaint) | P0 |
| M7 | Home screen categorization (8 categories, 23 demos) | P1 |

### Adversarial Review Findings (Pillar 5 Part 1 — Round 1)

| # | Severity | Component | Finding | Resolution |
|---|----------|-----------|---------|------------|
| 1 | HIGH | `memory_pressure_demo.dart` | `_dartMB` used `_dartObjects.length * 10`, overcounting GC Churn batches (~600KB) as 10MB | Introduced `_dartBatchKB` list tracking actual per-batch estimated KB |
| 2 | MEDIUM | `memory_pressure_demo.dart` | Hardcoded `Colors.grey.shade100` on visualization card breaks dark mode | Replaced with `Theme.of(context).colorScheme.surfaceContainerLow` |

### Adversarial Review Findings (Pillar 5 Part 1 — Round 2)

Second-round review targeted the demos' ability to actually trigger their detectors and
to avoid resource leaks. 7 findings across 3 severity levels; all fixed.

| # | Severity | Component | Finding | Resolution |
|---|----------|-----------|---------|------------|
| 1 | CRITICAL | `lib/src/detectors/memory_pressure_detector.dart` | `_evaluateGcPressure` used `_gcEventCount / (now - _trackingStart).inSeconds * 60`, so the denominator grew unbounded across a session. A GC burst after 60s of unrelated exploration would be diluted below the 30/min threshold even though the burst itself exceeded it. | Replaced lifetime-based rate with a 10-second sliding window (`Queue<({DateTime ts, int count})> _gcWindow`) with timestamp-based eviction. Removed `_trackingStart` and `_gcEventCount` fields. All 55 memory pressure detector tests still pass. |
| 2 | HIGH | `example/lib/demos/platform_channel_demo.dart` | `_triggerRapidFire` and `_triggerSingle` called `setState` after `await Future.wait(...)`/`await _channel.invokeMethod(...)` without `mounted` checks; navigating away mid-call crashed the app | Added `if (!mounted) return;` after each await. `_addLog` guards internally. |
| 3 | HIGH | `example/lib/demos/platform_channel_demo.dart` | Unconditionally set `debugProfilePlatformChannels = true` in `initState` and `= false` in `dispose`, silently clobbering any global setting the developer had enabled in `main.dart` | Snapshot prior value in `initState` (`_priorDebugProfilePlatformChannels`), restore in `dispose` |
| 4 | MEDIUM | `example/lib/demos/memory_pressure_demo.dart` | Stats label "Dart Heap" was misleading — it only tracked *retained* allocations, so GC Churn mode left the counter at 0 and users concluded the demo was broken | Renamed stat to "Retained (Dart)"; updated demo description to explain that churn allocations are intentionally transient |
| 5 | MEDIUM | `example/lib/demos/repaint_boundary_demo.dart` | Description claimed the detector flagged "Opacity(0.7) with 6+ descendants" — real check is non-trivial opacity values (0.0 < x < 1.0) without a `RepaintBoundary` ancestor within 5 levels, across 6 widget classes | Rewrote description to match detector logic and enumerate the 6 flagged widget classes (Opacity, ClipPath, BackdropFilter, ShaderMask, CustomPaint, ColorFiltered) |
| 6 | MEDIUM | `example/lib/demos/shader_jank_demo.dart` | `ShaderCompilation` timeline events only fire on the Skia backend. Impeller (default iOS 3.16+, Android 3.22+) pre-compiles shaders offline, so the demo silently produced zero detector hits on modern devices and no Dart API exists to detect the graphics backend at runtime | Added `_ImpellerWarningBanner` widget at the top of `_ShaderHeavyPage`'s ListView, using `colorScheme.errorContainer` to explain the Skia/Impeller difference and direct users to relaunch with `--no-enable-impeller` |

Self-attack on Round 2 fixes (second-order regressions checked):
- **Clock monotonicity in sliding window**: `DateTime.now()` is not guaranteed monotonic, but test clocks are injected via `_clock`; and in production the scan cadence (every few seconds) provides enough slack that NTP skew below 10s won't empty the window prematurely.
- **Queue growth bounds**: `_gcWindow` evicts on every `processTimelineData` call, so the queue cannot grow beyond the number of scan cycles in the 10s window.
- **Hot reload**: Hot reload recreates the detector fresh, so no stale state survives.
- **setState guards**: Guards are placed *after* each await but *before* any `_log.add`; no path bypasses them.
- **Banner UI on Skia**: The banner is always shown, including on Skia where detection does work — this is intentional (it still correctly describes what the user is observing).

### Files Changed

| File | Change |
|------|--------|
| `example/lib/demo_scaffold.dart` | New — DemoScaffold + _CollapsibleBanner widgets |
| `example/lib/demos/shader_jank_demo.dart` | New — ShaderJank demo with 4 GPU effects |
| `example/lib/demos/platform_channel_demo.dart` | New — PlatformChannel demo with 3 modes + log |
| `example/lib/demos/memory_pressure_demo.dart` | New — MemoryPressure demo with Dart/native/GC churn |
| `example/lib/demos/gpu_pressure_demo.dart` | New — GpuPressure demo with 4 stacked layers |
| `example/lib/demos/repaint_boundary_demo.dart` | New — RepaintBoundary demo with Opacity + CustomPaint |
| `example/lib/main.dart` | Rewritten — 8 categories, 23 demos, new imports |

---

---

## Pillar 5 Part 2: Demo Quality Enhancements & Combined Demos (v0.11.1)

**Status: 7/7 milestones shipped** ✅

Pillar 5 Part 2 transforms the example app from a gallery of isolated anti-patterns into
an interactive teaching tool. Every demo ships a **Before/After toggle** with a real
working fix, a **live metrics bar** showing quantitative impact, and a `▶` action line
telling the developer exactly what to tap to trigger detection. Two new combined demos
(E-Commerce Product Page, Chat App) stack 4–5 anti-patterns in one realistic screen and
show every corresponding fix applied together.

### Milestones

| Milestone | Title | Priority |
|-----------|-------|----------|
| M8 | Extend DemoScaffold with Before/After toggle (`fixedBody`, `onToggle`, `metricsBar`, `StatefulWidget` upgrade) | P0 |
| M9 | Fixed-pattern bodies for all 23 existing demos | P0 |
| M10 | Live metrics bar with `MetricsBar` + `MetricChip` widgets, wired into 7 demos | P1 |
| M11 | Reproduction instructions (`❌ BAD / ✅ FIX / ▶ action`) on every demo description | P1 |
| M12 | Combined E-Commerce Product Page demo (imageMemory, animatedBuilder, layoutBottleneck, listview, globalKey, opacity) | P1 |
| M13 | Combined Chat App demo (rebuild, keepAlive, platformChannel, imageMemory, setStateScope) | P1 |
| M14 | Home screen wiring for the two new combined demos (23 → 25 demos) | P2 |

### Demos with live metric chips

| Demo | Metric shown |
|------|--------------|
| `high_level_setstate_demo` | Bad rebuilds / Fixed rebuilds (dual counters, reset on toggle) |
| `non_lazy_list_demo` | Widgets built (incremented in `itemBuilder` callback) |
| `heavy_compute_demo` | Compute time per tap (ms) |
| `fps_stress_test_demo` | Live FPS via `SchedulerBinding.instance.addTimingsCallback` sliding window |
| `repaint_stress_demo` | Paints per second (1s sliding window via post-frame callback) |
| `network_stress_demo` | Total requests issued in the current session |
| `memory_pressure_demo` | Retained MB (Dart heap) |

### DemoScaffold upgrade

`DemoScaffold` was a `StatelessWidget` in Part 1. Part 2 converts it to a `StatefulWidget`
and adds three new parameters:

- `fixedBody: Widget?` — when non-null, a Material 3 `SegmentedButton` appears below the
  AppBar letting the user switch between `body` and `fixedBody`. The swap is a simple
  ternary in the build tree (`_isFixed ? widget.fixedBody! : widget.body`), so the hidden
  side is fully unmounted and any timers, animations, or controllers it owned stop
  automatically.
- `onToggle: ValueChanged<bool>?` — invoked synchronously AFTER the scaffold's internal
  `setState(() => _isFixed = ...)`, so demos can react to the transition (reset counters,
  gate FAB handlers, pause global callbacks). Critical for demos that share a FAB between
  bad and fixed paths — see the "FAB double-action" adversarial finding below.
- `metricsBar: Widget?` — displayed as a thin horizontal strip between the description
  banner and the body. Typically a `MetricsBar` containing several `MetricChip` children.

New helper widgets:

- `MetricsBar` — horizontal row of chips with consistent padding and spacing.
- `MetricChip` — small rounded pill labeled `"Label: value unit"`. Stateless — callers
  wrap it in `ValueListenableBuilder` to drive updates.

### Combined demos

**Combined E-Commerce Product Page** (`example/lib/demos/combined_ecommerce_demo.dart`,
683 lines). Stacks 6 anti-patterns in one product detail page:

- 6 hero images at full resolution (ImageMemory — exceeds the `count > 5` critical
  threshold)
- `AnimatedBuilder` rotating a price tag without an extracted `child` parameter
- Row of size-selector chips wrapped in `IntrinsicHeight` (LayoutBottleneck)
- 200-review `ListView(children: ...)` — non-lazy, fully realized (ListView)
- 4 `GlobalKey()` instances created fresh in `build()` on every frame (GlobalKey)
- Loading banner hidden via `Opacity(opacity: 0.0)` (Opacity)

The fixed body applies `cacheWidth: 520` on every image, extracts the `AnimatedBuilder`
child, removes `IntrinsicHeight`, wraps the review `ListView.builder` in a bounded-height
`SizedBox(height: 480)` so only the visible window is realized, stores `GlobalKey`s as
`final` State fields, and swaps the `Opacity(0.0)` banner for `Visibility(visible: false)`.

**Combined Chat App** (`example/lib/demos/combined_chat_demo.dart`, 577 lines). A tabbed
messaging interface stacking 5 interaction-driven anti-patterns:

- 5 `TabBarView` conversations all using `AutomaticKeepAliveClientMixin` — every tab is
  retained in memory (KeepAlive, above the `wantKeepAlive` threshold of 5)
- Uncached circular `Image.network` avatars on every message (ImageMemory)
- Simulated "typing" poll via `MethodChannel.invokeMethod` on a `Timer.periodic` with a
  40ms interval = 25 calls/sec (PlatformChannelTraffic, above the 20/sec threshold)
- Top-level `setState(() {})` on every message arrival — rebuilds the entire tab tree
  (SetStateScope + Rebuild)
- Standalone `TextField` input wired to the outer State (contributes to rebuild scope)

The fixed body debounces the typing poll, caps `wantKeepAlive` at 2 tabs, isolates the
message list behind a `ValueNotifier` that only the list subscribes to, caches avatars
with `cacheWidth: 80`, extracts the text input into its own `StatefulWidget`, and
restores `debugProfilePlatformChannels` to its pre-demo value on dispose so developers
who enabled it globally in `main.dart` aren't clobbered.

### Adversarial Review Findings (Pillar 5 Part 2)

Two rounds of review. The first pass focused on "does each fix actually eliminate the
detector it's supposed to demonstrate a fix for?" and turned up subtle bugs in the
E-Commerce demo that made its fixed body look correct while the detector was never
actually firing. The second pass focused on "do the new `StatefulWidget` demos leak
timers, controllers, or client handles on dispose or navigation?" and turned up the
`HttpClient` leak and unbounded-growth hazards.

| # | Severity | Component | Finding | Resolution |
|---|----------|-----------|---------|------------|
| 1 | CRITICAL | `combined_analytics_dashboard_demo.dart` | FAB `onPressed` called `_badRefreshCount++ + _fixedRefreshCount.value++` AND `setState(() {})` unconditionally. In the fixed path, the outer `State`'s top-level `setState` rebuilt the entire subtree — burying the `ValueListenableBuilder`'s isolated update and silently hiding the fix the demo was meant to demonstrate. | Added `_isFixed` field synced via `onToggle: _handleToggle`; FAB only calls `setState` when `!_isFixed`. Both counters still update together so toggling doesn't desync the visible value. |
| 2 | CRITICAL | `combined_social_feed_demo.dart` | Same FAB double-action pattern on the Like button. Fixed path still rebuilt every card on every like. | Same `_isFixed` gate pattern. |
| 3 | CRITICAL | `high_level_setstate_demo.dart` | Same FAB double-action — **most severe here** because `_FixedBody` and `_FixedGrid` are NOT `const`, so a top-level `setState` rebuilt every one of the 50 tiles. The entire "fix" was effectively dead. | Same `_isFixed` gate pattern. Inline comment explains why the gate is essential for this specific demo. |
| 4 | CRITICAL | `combined_ecommerce_demo.dart` | `ImageMemoryDetector` flags at `count > 5`, but the bad-path horizontal `ListView.builder` with 6 heroes only realized 2–4 items on phones due to the default 250px `cacheExtent`. The demo never actually placed > 5 `Image.network` widgets in the element tree simultaneously, so the critical-threshold detection silently never fired. | Converted both bad and fixed hero carousels from `ListView.builder(scrollDirection: Axis.horizontal)` to `SingleChildScrollView` + `Row`. All 6 heroes are now always in the tree. The fixed version still demonstrates `cacheWidth: 520` — the fix is "decode smaller", not "render fewer". |
| 5 | HIGH | `combined_ecommerce_demo.dart` | Fixed-path reviews used `ListView.builder(shrinkWrap: true, physics: NeverScrollableScrollPhysics)` inside a `SingleChildScrollView`. Under infinite main-axis constraints, `shrinkWrap` still realizes every one of the 200 items — the "pagination" fix wasn't paginating anything. | Wrapped the inner `ListView.builder` in `SizedBox(height: 480)` to give it a bounded viewport. Only ~8 items are realized at a time as the user scrolls the inner list. |
| 6 | HIGH | `network_stress_demo.dart` | `_triggerFrequencySpike` awaited `Future.wait([40 gets])` and then early-returned on `!mounted` before reaching `client.close()`. Navigating away mid-flight leaked the `HttpClient` until GC. | Moved `client.close(force: true)` into a `finally` block so cleanup runs on every exit path, including exceptions and mid-flight unmount. |
| 7 | MEDIUM | `network_stress_demo.dart` | `_log` grew unboundedly across toggles and taps; long demo sessions janked the `ListView.builder` rendering it. | Added `_maxLogLines = 200` constant; `_addLog` trims the front of the list with `removeRange` when the cap is exceeded. |
| 8 | MEDIUM | `combined_chat_demo.dart` | 40ms message-arrival timer did `[...notifier.value, msg]` on every tick. Over a long session, each tab would accumulate thousands of entries and thrash the ListView. | Added `_maxMessagesPerTab = 100` constant + `_appendCapped` helper that drops the oldest entry when the cap is hit. Used in both bad and fixed branches. |
| 9 | LOW | `combined_chat_demo.dart` | `_startBadTypingPoll` caught only `MissingPluginException` and `PlatformException`. Any other throw tore down the demo entirely — e.g. a native-side Swift exception wrapped in something unexpected. | Added a defensive `catch (_)` fallback after the typed catches, plus a `mounted` guard so the poll keeps running if the platform side returns something weird. |

**Second-order regression checks on the fixes:**

- The `_isFixed` gate is driven by `onToggle`, which `DemoScaffold._handleToggle` invokes
  synchronously after `setState(() => _isFixed = isFixed)`. There is no window where the
  FAB could fire between the toggle's state change and the outer demo's `_isFixed` update.
- The `try/finally` in `_triggerFrequencySpike` runs even on exceptions thrown during
  `await Future.wait(...)`, so `client.close(force: true)` is guaranteed. `force: true`
  is safe because the client is local to the method — no other code holds a reference.
- The 480px review viewport is large enough to show a realistic page of reviews on typical
  phones (~8 items at 60px each) but small enough to force the `ListView.builder` into its
  lazy-realization path. Verified by scrolling: items 9–200 are not in the element tree
  until brought into view.
- `_appendCapped` uses `List.sublist` + spread — correct but allocates. The 40ms timer
  allocates a new list every tick regardless of the cap, so this adds no additional
  overhead beyond what already exists.
- `MetricsBar` counters reset on toggle for the demos that track both paths — verified
  that the reset fires before the next frame so the post-toggle chip shows 0, not a
  stale lifetime-accumulated number.

**False positives (no fix needed):**

- `fps_stress_test_demo`: adversarial review flagged "phantom `_recentFrames` accumulation
  across toggles" — but the `TimingsCallback` is intentionally installed in both modes so
  the chip can show a real Before/After FPS comparison. The accumulator is bounded by the
  sliding window.
- `non_lazy_list_demo`: adversarial review flagged a "multiple `addPostFrameCallback`
  race" — but all post-frame callbacks in the demo capture the same closure variable, so
  they converge to the same final counter value regardless of interleaving.
- `font_loading_demo`: flagged `_badFonts` with 5 families as a bug — that IS the bad body;
  the `FontLoadingDetector` counts unique `Text.style.fontFamily` strings in the widget
  tree, not fonts declared in `pubspec.yaml`.
- `shallow_rebuild_risk_demo`: suspected FAB double-action — but its "fix" is intentionally
  a `const _StaticRowList` leaf that doesn't rebuild when top-level `setState` fires. The
  demo is correct as-is because the `const` constructor insulates the subtree.

### Files Changed

| File | Change |
|------|--------|
| `example/lib/demo_scaffold.dart` | Upgraded to `StatefulWidget`; added `fixedBody`, `onToggle`, `metricsBar` parameters; added `MetricsBar` + `MetricChip` helper widgets |
| `example/lib/demos/combined_chat_demo.dart` | **New** (577 lines) — tabbed chat with 5 anti-patterns, bounded message list, save/restore of `debugProfilePlatformChannels`, broad exception handling in typing poll |
| `example/lib/demos/combined_ecommerce_demo.dart` | **New** (683 lines) — product detail page with 6 anti-patterns, hero carousel via `Row`, bounded-height reviews list |
| `example/lib/demos/combined_analytics_dashboard_demo.dart` | Migrated to `DemoScaffold.fixedBody`; added `_isFixed` FAB gate |
| `example/lib/demos/combined_social_feed_demo.dart` | Migrated to `DemoScaffold.fixedBody`; added `_isFixed` FAB gate |
| `example/lib/demos/high_level_setstate_demo.dart` | Added `fixedBody` with `_FixedBody`/`_FixedGrid`; `_isFixed` FAB gate; dual rebuild counters in metrics bar |
| `example/lib/demos/network_stress_demo.dart` | `HttpClient` try/finally leak fix; `_log` capped at 200 lines; added `_triggerCached` and `_triggerPaginated` fixed-body actions |
| `example/lib/demos/heavy_compute_demo.dart` | `Isolate.run` fixed body; compute-time metric chip |
| `example/lib/demos/fps_stress_test_demo.dart` | Debounced/cached fixed body; live FPS metric chip via `addTimingsCallback` |
| `example/lib/demos/non_lazy_list_demo.dart` | `ListView.builder` fixed body; built-widgets metric chip |
| `example/lib/demos/repaint_stress_demo.dart` | `RepaintBoundary`-wrapped fixed body; paints/sec metric chip |
| `example/lib/demos/memory_pressure_demo.dart` | Bounded-pool fixed body |
| `example/lib/demos/intrinsic_height_demo.dart`, `opacity_zero_demo.dart`, `global_key_demo.dart`, `animated_builder_demo.dart`, `custom_painter_demo.dart`, `nested_scroll_demo.dart`, `font_loading_demo.dart`, `uncached_image_demo.dart`, `shallow_rebuild_risk_demo.dart`, `keepalive_demo.dart`, `shader_jank_demo.dart`, `platform_channel_demo.dart`, `gpu_pressure_demo.dart`, `repaint_boundary_demo.dart` | Migrated to `DemoScaffold.fixedBody` with real corrected implementations |
| `example/lib/main.dart` | Added `CombinedEcommerceDemo` and `CombinedChatDemo` route entries in the Combined category (23 → 25 demos) |

---

## Verification (Final)

- `fvm flutter test` — 1,825 tests passing ✅
- `fvm flutter analyze` — 0 issues ✅ (both `sleuth` package and `example` app)
- All roadmaps complete: v7 (10/10), v8 (5/5), v9 (17/17), v10 (12/12), v11 (19/19), Pillar 2a (3/3), Pillar 2b (4/4), Pillar 3a (5/5), Pillar 3b (4/4), Pillar 4 (10/10), Pillar 5 Part 1 (7/7 + 2 adversarial reviews), Pillar 5 Part 2 (7/7 + 3 adversarial review rounds + KeepAliveDetector bug fix), Pillar 6 Part 1 (7/7 + 1 adversarial review), Pillar 6 Part 2 (8/8 + 1 adversarial review round, 6 fixes)

---

## KeepAliveDetector False-Positive Bug Fix (Pillar 5 Part 2 follow-up)

**Symptom:** The new `combined_chat_demo.dart` fixed mode (only 2 of 6 tabs opting in
via `wantKeepAlive`) still reported "excessive keep-alive" — same as the bad mode. The
"fix" was indistinguishable from the broken pattern from Sleuth's perspective.

**Root cause (two layered bugs):**

1. `KeepAliveDetector` matched `KeepAlive` widgets by type-name string. But Flutter's
   `AutomaticKeepAlive.build()` ALWAYS wraps its child in `KeepAlive(keepAlive: ...)` —
   the `keepAlive` flag toggles between true and false depending on the
   `KeepAliveNotification` from descendants. Counting `KeepAlive` widgets by type alone
   counts every page in a `TabBarView`, regardless of whether it's actually being
   retained.

2. Falling back to `element.widget.keepAlive` is also wrong. `AutomaticKeepAlive` updates
   the child render object's parent data via
   `ParentDataElement.applyWidgetOutOfTurn()`, which mutates the **render object's
   parent data** but does NOT replace `element.widget`. So `widget.keepAlive` stays at
   the stale `false` from the very first build, even after the keep-alive flips to
   `true`. The framework itself reads the parent data, not the widget field.

**Fix:** Read `element.renderObject.parentData` and cast to `KeepAliveParentDataMixin`.
That's the authoritative signal — it's what the framework uses for retention decisions
in `RenderSliverWithKeepAliveMixin` and friends. Added `_isActiveKeepAlive(Element)`
helper in `lib/src/detectors/keep_alive_detector.dart`.

**Regression tests added** (`test/detectors/keep_alive_detector_test.dart`):

- `_OptOutKeepAlivePage`: a `TabBarView` of 6 pages where every page returns
  `wantKeepAlive: false`. Detector must NOT fire (zero active keep-alive clients).
- `_ConfigurableKeepAlivePage`: a `TabBarView` where pages have configurable
  `wantKeepAlive`. Mirrors the chat demo fixed pattern (2 of 6 opted in). Detector must
  NOT fire below the 5-page threshold.

Test count: 1,823 → 1,825.

---

## Adversarial Review Round 5 — Migrated Demo Polish

A dedicated review pass over the demos migrated to `DemoScaffold` in Pillar 5 Part 2 M9.
4 findings, 1 critical:

| # | Severity | Demo | Finding | Resolution |
|---|----------|------|---------|------------|
| 1 | CRITICAL | `non_lazy_list_demo.dart` | Both `_BadBody.build()` and `_FixedBody.build()` reset `builtCount.value = 0` at the start of build. After the first build's post-frame callback set the counter non-zero, the next build's reset called `notifyListeners` during the build phase, marking the ancestor `ValueListenableBuilder` in `MetricsBar` dirty mid-frame and risking the "setState or markNeedsBuild called during build" assertion. | Removed in-build reset; reset moved to `_handleToggle` (fires outside build phase). Kept the `var running = 0` + post-frame `builtCount.value = running` publish pattern. |
| 2 | TEXT | `combined_chat_demo.dart` | Description said "cacheWidth: 48" but code uses `64`; code comment said "48px for 24×24 avatars" but avatars display at 32×32. | Aligned text to 64 and 32×32 for high-DPI. |
| 3 | TEXT | `combined_ecommerce_demo.dart` | Description said "cacheWidth: 400" but code uses `520`. | Aligned to 520. |
| 4 | CONVENTION | `fps_stress_test_demo.dart` | Missing `▶ action` reproduction marker. | Added marker. |

**False positives cleared in Round 5** (audited and dismissed): GlobalKey threshold in
ecommerce (triggers recreation detector at threshold 5, not excessive at 20), counter
reset semantics in network_stress/heavy_compute/fps/analytics/memory_pressure (cumulative
per docstring intent), repaint microtask race, analytics FAB sync, chat TabController
sharing.

---

## Adversarial Review Round 6 — Demo ↔ Detector Alignment

A focused pass that asked, for every demo: **does it actually fire the detector it
claims to demonstrate, given today's tightened thresholds?** Detectors have been narrowed
across multiple pillars (Pillar 2a hot-path fixes, Pillar 2b lazy initialization, Pillar
3a/3b enrichment, the v11 detector audit Parts 1–3) and several demos had silently
drifted below their trigger threshold. They showed pretty UI but produced zero issue
cards — a worst-case "demo lies about Sleuth" failure mode.

5 demos were broken; 17 were audited and dismissed.

| # | Severity | Demo | Root cause | Resolution |
|---|----------|------|------------|------------|
| 1 | CRITICAL | `global_key_demo.dart` | 15 keys but `GlobalKeyDetector.threshold = 20` (fires on `> 20`). Description also mis-stated the threshold as 10. | Bumped `_itemCount` to 25; corrected description. Kept `ListView.builder` scope because the **excessive** branch only counts keys inside `ListView/GridView/PageView` (gated at `global_key_detector.dart:131`). |
| 2 | CRITICAL | `non_lazy_list_demo.dart` | 40 children but `ListviewDetector.childThreshold = 50` (fires on `> 50`). | Bumped `_itemCount` to 60. |
| 3 | CRITICAL | `animated_builder_demo.dart` | 6 progress bars built a ~14-widget subtree, well below `AnimatedBuilderDetector.minSubtreeSize = 50`. | Added `_barCount = 12`; enriched each row to `Row(SizedBox(label) + Expanded(LinearProgressIndicator) + SizedBox(percentage))`. Total subtree ≈ 135 widgets. `_StaticBarColumn` mirrors the structure for the fixed path. |
| 4 | CRITICAL | `combined_analytics_dashboard_demo.dart` | Two issues stacked: 25 tiles below `ListviewDetector.childThreshold = 50`, AND 25 GlobalKeys lived in a `SingleChildScrollView + Column` (wrong scope — the excessive branch only counts inside LV/GV/PV). The recreation branch also never fired because keys were stored as a stable `final List<GlobalKey> _tileKeys` field on the State. | Bumped `_tileCount` to 60. Removed the `_tileKeys` field. Moved key allocation INSIDE `_BadDashboard.build()` as `final tileKeys = List.generate(_tileCount, (_) => GlobalKey())`. Wrapped `_BadDashboard` in an outer `AnimatedBuilder(animation: _controller)` so every tick rebuilds the bad subtree without user interaction. Net effect: ListviewDetector fires (60 > 50) AND GlobalKey **recreation** fires (`churnCount = 60 ≥ recreationThreshold = 5`). Mirrors the same outer-AnimatedBuilder pattern already used in `combined_ecommerce_demo.dart`. |
| 5 | CRITICAL | `nested_scroll_demo.dart` | Original demo had ONE `SingleChildScrollView` with 30 children — no actual nesting AND below threshold. `NestedScrollDetector` requires `parentAxis != null && scrollAxis == parentAxis` (i.e. an inner scrollable on the same axis as an outer scrollable) AND `childCount > childThreshold = 50`. Without the outer wrapper, the demo trivially could not fire. | Bumped `_itemCount` to 60. Wrapped the inner SCSV in `SingleChildScrollView > Column > Padding(header) > SizedBox(height: 480) > SingleChildScrollView`. The bounded 480px viewport keeps the inner scrollable from crashing on unbounded height while preserving the same-axis nesting that the detector requires. |

### Key insight uncovered

`GlobalKeyDetector` has **two modes with different scoping**, and the behavioral
difference is what made the combined_analytics fix possible:

- **Excessive count branch** (`global_key_detector.dart:131`): gated by
  `_isInListLikeScrollable`. Counts only keys inside `ListView`, `GridView`, or
  `PageView` scrollables. This is why putting 25 keys in a `SingleChildScrollView +
  Column` did nothing — they're invisible to the excessive branch.
- **Recreation branch** (`global_key_detector.dart:113-116`): collects
  `identityHashCode(key)` **globally** in `checkElement`, NOT gated by the scrollable
  scope. So you can trigger recreation by allocating new `GlobalKey` instances inside
  *any* widget's `build()` — as long as that build actually runs repeatedly. The
  combined_analytics fix exploits this exactly: outer `AnimatedBuilder` forces the
  rebuild, inline `List.generate` churns the identity set, detector observes
  `churnCount = 60 ≥ recreationThreshold = 5` and fires per cycle.

This difference is deliberate (recreation is dangerous regardless of where the keys
live) but it isn't documented anywhere except in the code, so demos that wanted to
demonstrate the recreation pattern needed to be specifically structured around it.

### Demos audited and dismissed

`custom_painter_demo`, `font_loading_demo`, `gpu_pressure_demo`, `heavy_compute_demo`,
`high_level_setstate_demo`, `intrinsic_height_demo`, `network_stress_demo`,
`opacity_zero_demo`, `platform_channel_demo`, `repaint_boundary_demo`,
`repaint_stress_demo`, `shader_jank_demo`, `shallow_rebuild_risk_demo`,
`uncached_image_demo`, `combined_chat_demo`, `combined_ecommerce_demo`,
`combined_social_feed_demo`. Each was traced through its corresponding detector's
`checkElement` path with current thresholds and confirmed to still fire.

### Second-order regression checks

- **animated_builder**: counted the subtree manually — 1 outer Column + 1 Text + 1
  SizedBox + 12 × (Padding + Row + 5 children) = ~135 widgets. Comfortably above 50.
- **combined_analytics**: confirmed the outer `AnimatedBuilder` actually invokes its
  builder on every tick (not just on `_controller.status` changes); confirmed
  `_BadDashboard.build` allocates a fresh `List<GlobalKey>` each call; confirmed the
  identity hashes change every rebuild and the recreation detector accumulates them
  globally. The 60-element churn rate is well above the threshold even after framework
  filter exclusions.
- **nested_scroll**: confirmed the inner `SingleChildScrollView` is inside a bounded
  `SizedBox(480)` so it doesn't crash, and the outer `SingleChildScrollView` produces
  the same axis as the inner — `NestedScrollDetector._checkNestedScroll` walks the
  scrollable parent stack and the match path is exercised.
- **global_key**: confirmed `Card` is NOT in `GlobalKeyDetector`'s framework filter
  (`KeyedSubtree`, `RawGestureDetector`, `IgnorePointer`, `Padding`, `Semantics`,
  `Actions`, `Shortcuts`, `Focus`, `FocusScope`, `FocusTrapArea`, `Builder`, `Listener`,
  `MouseRegion`, `MergeSemantics`, `BlockSemantics`, `ExcludeSemantics` — all
  framework-internal). 25 user-supplied `Card(key: ...)` instances all count.
- **non_lazy_list**: 60 > 50, no edge cases.

### Verification (Round 6)

- `fvm flutter analyze` (sleuth) — 0 issues
- `fvm flutter analyze` (example) — 0 issues
- `fvm flutter test` — **1,825 tests passing**
- Manual trace through each fixed demo's detector path confirmed firing in profile mode

### Pillar 5 Part 2 round count

After Round 6, Pillar 5 Part 2 totals:

- Round 4 (initial post-implementation review): 9 findings resolved
- Round 5 (migrated demo polish): 4 findings resolved + KeepAliveDetector bug fix
- Round 6 (demo ↔ detector alignment): 5 findings resolved
- **Total: 18 findings + 1 detector bug fix across 3 rounds**

---

---

## Pillar 6 Part 1: Public API & Authoring Surface (v0.12.0)

**Status: 7/7 milestones shipped** ✅

### Summary

Reduces friction at every consumer-facing API surface in Sleuth. Adds preset
configuration constructors, threshold documentation, debug-mode validation,
`Duration`-typed intervals, a `SimpleStructuralDetector` helper base class,
key-based gating for custom detectors, and a three-file custom-detector
cookbook in the example app. **One breaking change**: `treeScanIntervalMs: int`
is replaced by `treeScanInterval: Duration`.

### Milestones

| Milestone | Title | Priority |
|-----------|-------|----------|
| M1 | `SleuthConfig.minimal()` and `.performance()` preset constructors | P0 |
| M2 | Inline doc comments on every `SleuthConfig` and `DetectorThresholds` threshold | P0 |
| M3 | Debug-mode `assert()` validation for invalid configs (14 `SleuthConfig` asserts + 10 `DetectorThresholds` asserts) | P0 |
| M4 | **Breaking**: `Duration treeScanInterval` replaces `int treeScanIntervalMs` | P0 |
| M5 | `SimpleStructuralDetector` helper base class (`inspect` + `report` API) | P0 |
| M6 | Custom detector enable/disable via `BaseDetector.key` + `SleuthConfig.disabledCustomDetectorKeys` | P1 |
| M7 | Custom detector cookbook (`example/lib/custom_detectors/` + smoke test) | P1 |

### Adversarial Review Findings (Pillar 6 Part 1)

One round of review against the full M1–M7 surface. 8 findings across 3 severity levels; all resolved before merge.

| # | Severity | Component | Finding | Resolution |
|---|----------|-----------|---------|------------|
| 1 | HIGH | `test/controller/adaptive_scan_test.dart` | M4 migration strays: three `SleuthConfig(treeScanIntervalMs: ...)` call sites left in the adaptive scan test suite would compile against the removed field and break the build | Migrated all three to `treeScanInterval: Duration(...)`; grep confirmed zero stragglers across `lib/`, `test/`, `example/`, `doc/`, and `README.md` |
| 2 | HIGH | `lib/src/controller/sleuth_controller.dart` | `SleuthConfig.performance()` originally included `DetectorType.shallowRebuildRisk` in the enabled set — but `ShallowRebuildRiskDetector.lifecycle == DetectorLifecycle.hybrid` (reads VM timeline data), so the "structural-only" preset was implicitly enabling a debug-callback-paying detector | Removed `shallowRebuildRisk` from the `.performance()` set; added doc comment explaining the intentional exclusion and naming `frameTiming` as the other runtime detector excluded by design |
| 3 | HIGH | `lib/src/controller/detector_thresholds.dart` | M3 added asserts to `SleuthConfig` but left `DetectorThresholds` with no validation. Negative `shaderJankMs`, zero `gpuPressureRatio`, or out-of-range `memoryCapacityPercent` would silently misbehave under const construction | Added 10 asserts covering every numeric field: non-negative millisecond thresholds, positive ratios, percentages in `[0.0, 1.0]`, positive sample-size minimums |
| 4 | HIGH | `example/lib/custom_detectors/03_hybrid_vm_structural_detector.dart` | `RasterHotSpotDetector.processTimelineData` originally *summed* `data.rasterDurations`. A batch typically contains ~10 frames, so summing tripped the `rasterBudgetMs` budget at ~10× the intended threshold and produced a flood of false positives on perfectly healthy apps | Changed to peak (max) via `fold<int>(0, (peak, current) => current > peak ? current : peak)`; added comment explaining the batch-vs-frame distinction for future copyists |
| 5 | HIGH | `test/models/simple_structural_detector_test.dart` | `SimpleStructuralDetector` inherited `BaseDetector.scanTree`'s exception safety (wraps walk in try/catch), but no test verified that a throwing `inspect()` still runs `finalizeScan` — the contract was unverified | Added `_ThrowingDetector` subclass and test asserting `scanTree` returns normally, `prepareCalled == true`, and `finalizeCalled == true` even when `inspect` always throws `StateError` |
| 6 | MEDIUM | `example/lib/custom_detectors/02_runtime_callback_detector.dart` | Dead `_unusedImportAnchor` helper referencing `Timer` and `kDebugMode` anchored two unused imports (`dart:async`, `package:flutter/foundation.dart`). `flutter analyze` flagged the unused imports when the anchor was removed | Removed the dead function AND the two imports in the same edit; final import set: `scheduler.dart`, `widgets.dart`, `sleuth.dart` |
| 7 | MEDIUM | `example/lib/custom_detectors/01_simple_structural_detector.dart` | `TooltipUsageDetector` used `identityHashCode(element.widget)` as its `stableId`. Flutter creates a fresh `Widget` instance on every rebuild, so the correlator received one new issue per rebuild and flooded the overlay | Keyed `stableId` on `tooltip.message` instead (user-authored, stable across rebuilds). Documented the tradeoff (two tooltips with the same message dedupe together) and pointed to source-location dedup as the production-grade approach |
| 8 | MEDIUM | `lib/src/controller/sleuth_controller.dart` validation | `SleuthConfig.treeScanInterval > Duration.zero` can't be asserted in the const constructor because `Duration` operators are not const-evaluable, so a zero-duration scan interval would hang the scan loop without warning | Added runtime `assert(() { ... }())` in the `SleuthController` constructor body throwing `ArgumentError` with a remediation hint. Noted the const-assertion limitation inline in `SleuthConfig` so future readers understand why the validation lives in the controller |

### Files Changed

| File | Change |
|------|--------|
| `lib/src/controller/sleuth_controller.dart` | `treeScanInterval: Duration` field, 14 `SleuthConfig` asserts, runtime `treeScanInterval > Duration.zero` validation, `.minimal()` + `.performance()` factories, `disabledCustomDetectorKeys` field, custom detector gating in `_initializeDetectors()`, per-field doc comments |
| `lib/src/controller/detector_thresholds.dart` | 10 asserts covering all numeric fields, per-field doc comments |
| `lib/src/models/base_detector.dart` | New public `String? key` field with doc contract (null = always enabled, non-null = gated by `disabledCustomDetectorKeys`) |
| `lib/src/models/simple_structural_detector.dart` | **New** — `SimpleStructuralDetector` helper base class: `inspect(Element)` + `report(...)` API, automatic per-scan reset, issue/highlight list management, `onPrepareScan` / `onDispose` lifecycle hooks |
| `lib/sleuth.dart` | Export `SimpleStructuralDetector` |
| `example/lib/custom_detectors/01_simple_structural_detector.dart` | **New** — `TooltipUsageDetector` (simplest shape: `SimpleStructuralDetector` subclass) |
| `example/lib/custom_detectors/02_runtime_callback_detector.dart` | **New** — `SlowFrameDetector` (runtime `BaseDetector` hooked to `SchedulerBinding.addTimingsCallback` with rolling window + subscription lifecycle) |
| `example/lib/custom_detectors/03_hybrid_vm_structural_detector.dart` | **New** — `RasterHotSpotDetector` (hybrid: correlates `ParsedTimelineData` peak raster with wide-`Stack` structural walk, graceful VM-disconnect confidence downgrade) |
| `example/lib/custom_detectors/README.md` | **New** — cookbook index describing when to use each shape |
| `example/lib/demos/custom_detector_cookbook_demo.dart` | **New** — demo screen wiring all three cookbook detectors into `Sleuth.track` |
| `example/test/cookbook_smoke_test.dart` | **New** — 5 smoke tests verifying the cookbook compiles against the public `package:sleuth/sleuth.dart` barrel and flags tooltips end-to-end |
| `test/controller/config_presets_test.dart` | **New** — `.minimal()` and `.performance()` field assertions, lifecycle verification for the performance preset's detector set |
| `test/controller/custom_detector_key_gating_test.dart` | **New** — key-gating semantics (null key always on, matching key disabled at init, non-matching key still on) |
| `test/models/simple_structural_detector_test.dart` | **New** — `inspect` invocation, `report` emission, enabled gating, dispose cleanup, throwing-inspect exception-safety test |
| `test/controller/adaptive_scan_test.dart` | Migrated 3 call sites from `treeScanIntervalMs: int` to `treeScanInterval: Duration` |
| `CHANGELOG.md` | `0.12.0` entry with **Breaking** section for M4 and Added entries for M1–M7 |
| `README.md` | Quick-start shows `SleuthConfig.minimal()` alongside full configuration; configuration snippet uses `Duration` |
| `pubspec.yaml` | Version bump `0.11.1 → 0.12.0` |

### Real-Device First-Launch VM Connection Fix

**Problem:** On cold start from Android Studio / terminal via USB/WiFi to a real device,
`Service.getInfo()` returned null URI because the VM web server hadn't bound its port yet.
Sleuth fell to BASIC/FRAME mode permanently — no VM timeline data, no correlated verdicts,
no memory profiling.

**VmServiceClient changes** (`lib/src/vm/vm_service_client.dart`):
- Replaced `Service.getInfo()` with `Service.controlWebServer(enable: true, silenceOutput: true)` to proactively force-bind the VM web server on cold start
- 3 s timeout using owned `Timer` + `Completer` (NOT `Future.timeout` — avoids timer leak in test environments)
- `_connectInFlight` concurrency guard — duplicate `connect()` calls join the existing future
- Prefer SDK's `info.serverWebSocketUri` over hand-rolled `_toWebSocketUri()` for URI conversion
- IPv4→localhost rewrite enables Dart's Happy Eyeballs dual-stack resolver
- `reconnect()` checks `_connectInFlight` before cleanup to avoid racing with in-flight connect

**SleuthController changes** (`lib/src/controller/sleuth_controller.dart`):
- **Background reconnect ladder**: `_scheduleBackgroundReconnect()` runs persistent exponential-backoff retry: 500 ms, 1 s, 2 s, 4 s, 8 s, 16 s, 30 s (7 attempts). Self-cancels on success/dispose/manual reconnect.
- **Manual reconnect**: Public `reconnect()` with `_reconnectInFlight` concurrency guard. Cancels background loop, delegates to client, re-arms background on failure.
- **Mid-session VM death recovery**: `_onVmConnectionChanged(false)` re-arms the background ladder when internal reconnect fails.
- **frameStatsNotifier throttle (Fix A)**: FrameTimingDetector fires at ~60 Hz; notifier emission now throttled to ~5 Hz (200 ms min). Prevents Sleuth's own overlay rebuilds from triggering false `rebuild_activity` on idle screens.

### Adversarial Review (Pillar 6 Part 1 + VM Connection)

**Scope:** M1–M7 + real-device VM connection changes. One review round, 4 findings:

1. **Unified walk exception isolation** (Critical): One custom detector throwing in `checkElement` killed the walk for all 16 detectors. **Fix:** Per-detector try/catch wrapping each `d.checkElement(element)` and `d.afterElement(element)` in the unified walk visitor.
2. **Post-dispose continuation guards** (Medium): `VmServiceClient._connectImpl` had no `_disposed` checks after 6 await points, risking leaked VmService + poll timer. **Fix:** Added `if (_disposed) return false;` (with `_cleanup()` where service already assigned) after every await.
3. **Diagnostic prints removal** (Low): 36 `[sleuth-diag]` temporary prints across 4 files removed before publish.
4. **frameStatsNotifier throttle test coverage** (Low): Throttle had zero test coverage. **Fix:** 2 new tests in `degradation_contract_test.dart` using injectable `clockOverrideForTest` (since `DateTime.now()` is not overridden by `fakeAsync`).

### Verification (Pillar 6 Part 1)

- `fvm flutter analyze` (sleuth) — 0 issues
- `fvm flutter analyze` (example) — 0 issues
- `fvm flutter test` — **1,869 tests passing** (1,825 → 1,869, +44 across M1–M7 + VM connection + throttle)
- `cd example && fvm flutter test` — **6 tests passing** (5 cookbook + 1 global key realization)
- Adversarial review: 4 findings, all resolved

---

## Pillar 6 Part 2: Overlay UI, Diagnostics Output & Export (v0.12.1)

**Status: 8/8 milestones shipped** ✅

Upgrades every consumer-facing surface a developer looks at during debugging — the trigger button, floating card, issue card, encyclopedia, and export path — so the information Sleuth already collects is visible, customizable, and shareable.

### Milestones (8/8 complete)

**M1: Trigger button alignment config** — `triggerButtonAlignment` (any of 4 corners) and `triggerButtonOffset` (pixel offset) on `SleuthConfig`. Wired through `SleuthOverlay` → `TriggerButton`. Debug-mode assert on non-corner alignments; release mode snaps silently.

**M2: Minimize/maximize/restore card controls** — Three-state window mode (`normal`, `minimized`, `maximized`) on `FloatingIssuesCard`. Minimized collapses to a 54 px header; maximized fills screen minus safe area. Pre-transition position/size stored and restored exactly. Compact header buttons with semantic labels.

**M3: Recurrence badge on IssueCard** — Surfaces `RecurrenceTrend` data as "Seen N/M · direction" badge. Direction labels: persistent (ratio ≥ 0.9 + stable), stable, flaky (intermittent), worsening, improving, new. Signal floor: `length < 2` suppresses badge to avoid flicker on new issues.

**M4: Context-aware encyclopedia entries** — `IssueExplanationBuilder.substitute()` replaces `{widgetName}`, `{count}`, `{routeName}`, `{severity}`, `{title}`, `{stableId}` placeholders with values from the triggering issue. Seven high-value templates enriched. Count extracted via regex from title with `'several'` fallback.

**M5: Inline confidence reasoning** — `confidenceReason` shown as italic caption text in expanded `IssueCard`, with confidence-level icon (check_circle_outline / help_outline / info_outline). Hidden when collapsed or null.

**M6: Dismissible debug-mode banner** — Warning banner on `FloatingIssuesCard` when `isDebugMode` is true. Dismiss button hides for current session. `SleuthConfig.showDebugModeBanner` config option to suppress entirely.

**M7: `Sleuth.exportSummary()` markdown export** — `SessionMarkdownExporter.render()` produces human-readable markdown with frame stats, top-N issues (clamped), causal chains, and version footer. Full GFM escaping (`\`, `*`, `` ` ``, `[`, `]`, `<`, `>`, `|`). Deterministic output for identical snapshots.

**M8: Copy conversation button on AiChatPage** — Serializes issue context + full chat thread to markdown and writes to clipboard. GFM escaping on all user-controlled text (issue titles, confidence reasons, message bodies). Snackbar confirmation with `ScaffoldMessenger.maybeOf` guard.

### Adversarial Review Findings (Pillar 6 Part 2)

**Scope:** M1–M8 implementations: `trigger_button.dart`, `floating_issues_card.dart`, `issue_card.dart`, `issue_encyclopedia_page.dart`, `issue_explanation_builder.dart`, `sleuth_controller.dart`, `session_markdown_exporter.dart`, `ai_chat_page.dart`, `sleuth.dart` barrel.

One review round, 6 findings:

1. **Tooltip crash in overlay** (High): `_confidenceBadge` used `Tooltip` widget which requires `OverlayPortal` → `_RenderTheaterMarker` ancestor. Sleuth's bare `Overlay` (no Navigator) lacks this. **Fix:** Replaced `Tooltip` with `Semantics(label: ...)`. Confidence reason shown inline when expanded (M5).

2. **Markdown escaping in copied conversation** (High): `_copyConversation` in `ai_chat_page.dart` passed raw issue titles and message text into markdown template — `*`, `` ` ``, `[`, `#`, etc. could corrupt GFM structure. **Fix:** Added `_escapeMd` static method escaping 9 GFM-significant characters, applied to all user-controlled text.

3. **Markdown escaping in session export** (Medium): `SessionMarkdownExporter._escape` only handled `*` and `` ` `` — missing `\`, `[`, `]`, `<`, `>`, `|`. **Fix:** Expanded to full 8-character set matching `_escapeMd`.

4. **Recurrence badge overflow** (Medium): On narrow cards, long badge text like "Seen 45/60 · persistent" could overflow horizontally. **Fix:** Added `maxLines: 1`, `overflow: TextOverflow.ellipsis` to `Text`, wrapped in `Align(alignment: Alignment.centerLeft)`.

5. **Semantic labels on interactive elements** (Low): AI chat back button, copy button, and floating card window controls (minimize, maximize, restore, dismiss banner) lacked `Semantics` wrappers. **Fix:** Added `Semantics(label: ..., button: true)` to all interactive elements.

6. **Cookbook TooltipUsageDetector false positives** (Bug fix): `TooltipUsageDetector` registered globally in `example/lib/main.dart` fired on standard Material framework tooltips (AppBar back button `Tooltip("Back")`) on every screen. **Fix:** Added `_frameworkMessages` static set (`Back`, `Close`, `Open navigation menu`, `Search`, `Show menu`, `More`, `Dismiss`) and early return in `inspect()`.

### Verification (Pillar 6 Part 2)

- `fvm flutter analyze` (sleuth) — 0 issues
- `fvm flutter analyze` (example) — 0 issues
- `fvm flutter test` — **1,915 tests passing** (1,869 → 1,915, +46 across M1–M8 + adversarial fixes)
- `cd example && fvm flutter test` — **7 tests passing** (6 → 7, +1 framework tooltip filter test)
- Adversarial review: 6 findings, all resolved

---

## v0.12.2: Post-Codex Adversarial Review Hardening

**Status: 3 fixes shipped** ✅ (v0.12.2)

Origin: Codex adversarial review (2026-04-10) of the full `feat/v11_implementations` branch diff (~25k lines across Pillars 1–6). Two Codex review passes produced 4 findings; meta-adversarial review validated 3 as real bugs, dismissed 1 (GC pressure fallback) as intentionally removed behavior. Post-implementation adversarial review confirmed all fixes and surfaced one additional improvement (static const hoisting).

### Fix 1: Timeline pipeline exception isolation

**Problem:** `SleuthController._onTimelineData` lacked the `try/finally` around `_isIteratingDetectors` that the structural walk path (`_runStructuralScans`) already had. A throwing custom detector in `processTimelineData` or `evaluateNow` would leave `_isIteratingDetectors = true` permanently, deadlocking all future detector enable/disable mutations via `_drainPendingDetectorMutations`.

**Fix:** Wrapped the entire detector iteration + verdict generation + aggregation block in `try { ... } finally { _isIteratingDetectors = false; _drainPendingDetectorMutations(); }`. Added per-detector `try/catch` around `d.processTimelineData(data)` and `d.evaluateNow()` calls, matching the structural walk's isolation pattern at lines 1766–1784.

**Files modified:**
- `lib/src/controller/sleuth_controller.dart` — `_onTimelineData` method restructured

### Fix 2: Encyclopedia placeholder leak

**Problem:** `IssueEncyclopediaPage._entryTile` only called `IssueExplanationBuilder.substitute()` for the scroll target entry when a `contextIssue` was provided. All other encyclopedia entries rendered raw `{widgetName}`, `{count}`, `{routeName}` placeholder tokens as literal text.

**Fix:** Apply `substitute()` to all entries. When no context issue is available, use a static sentinel `PerformanceIssue` (with null `widgetName`, null `routeName`, title `'several'`) that triggers the built-in fallbacks in `_substitutePlaceholders`: `'the widget'`, `'several'`, `'the current route'`.

**Files modified:**
- `lib/src/ui/issue_encyclopedia_page.dart` — static `_fallbackIssue` constant, `_entryTile` always calls `substitute()`
- `test/ui/issue_encyclopedia_page_test.dart` — test updated from `findsWidgets` to `findsNothing` for raw placeholders

### Fix 3: Cookbook slow-frame detector staleness

**Problem:** `SlowFrameDetector._recentSlowFrames` only stored slow frames. Fast frames never evicted entries, so a single slow frame could keep the detector reporting a stale issue through an arbitrarily long healthy period. The rolling window represented "recent slow frames" rather than "recent frames."

**Fix:** Added `_TimestampedFrame` wrapper pairing each slow frame's `Duration` with its `DateTime.now()` recording time. `finalizeScan()` now evicts entries older than `_maxAge` (10 seconds) before checking the window, so stale slow frames age out naturally.

**Files modified:**
- `example/lib/custom_detectors/02_runtime_callback_detector.dart` — `_TimestampedFrame` class, `_maxAge` constant, age eviction in `finalizeScan()`
- `example/test/cookbook_smoke_test.dart` — +2 tests (disable-clears-window, custom thresholds)

### Post-implementation adversarial review

**Finding:** `fallbackIssue` was allocated as a local variable inside `_entryTile()` — 46 unnecessary `PerformanceIssue` allocations per encyclopedia rebuild. **Fix:** Hoisted to `static const _fallbackIssue` on the State class.

### Verification (v0.12.2)

- `fvm flutter analyze` — 0 issues
- `fvm flutter test` — **1,915 tests passing**
- `cd example && fvm flutter test` — **9 tests passing** (7 → 9, +2 cookbook detector tests)
- Adversarial reviews: 2 Codex passes + 1 meta-review + 1 post-implementation review, 3 findings fixed + 1 improvement
