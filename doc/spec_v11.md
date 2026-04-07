## v11 Detector Audit: Gaps, False Positives & Milestones

**Status: 6/6 milestones shipped** ✅ (v0.10.2)

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

## Verification

- `fvm flutter test` — 1,561 tests passing ✅
- `fvm flutter analyze` — 0 issues ✅
- Two adversarial reviews completed with all findings resolved
