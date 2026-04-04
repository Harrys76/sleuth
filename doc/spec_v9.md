## v9 Roadmap: Accuracy, Self-Overhead & Correctness

Origin: Deep codebase audit (2026-04-03) across all 22 detectors, controller, VM/timeline/ranking systems, and UI overlay. 19 initial findings identified; 2 dropped after source-level verification (_ModalScope already filtered; HTTP cancelled stream implementation is correct). 17 verified findings remain across 3 tiers.

**Tiers:**
- **Tier 1 — Accuracy** (v9.1–v9.8): User-facing correctness — false positives, overclaims, and missed signals.
- **Tier 2 — Performance** (v9.9–v9.14): Tool self-overhead — allocations, redundant walks, and hot-path waste.
- **Tier 3 — Correctness** (v9.15–v9.17): Internal robustness — silent failures, safety guards, and documentation honesty.

---

### v9.1: Opacity Value Semantics — 3 Detectors

**Effort:** Medium | **Theme:** Accuracy | **Impact:** Eliminates false positives for opacity 1.0 (no-op) and 0.0 (short-circuit)

**Problem:** Three detectors flag Opacity widgets without checking the actual opacity value. In Flutter's rendering pipeline:
- **opacity == 1.0:** `RenderOpacity.paint()` skips `saveLayer` entirely — passes through to child. Zero GPU cost.
- **opacity == 0.0:** `RenderOpacity.paint()` short-circuits — doesn't paint the child at all. Zero GPU cost.
- **0 < opacity < 1:** Triggers `canvas.saveLayer()` — the expensive GPU path that allocates an offscreen buffer.

Only fractional opacity values are expensive. Flagging 1.0 or 0.0 is a false positive.

**Affected detectors:**

**1. GpuPressureDetector (gpu_pressure_detector.dart:94-118)**

```dart
if (typeName.contains('RenderOpacity') ||
    typeName.contains('RenderClipPath') ||
    typeName.contains('RenderBackdropFilter') ||
    typeName.contains('RenderShaderMask')) {
  int nodeCount = 0;
  void countNodes(Element child) {
    nodeCount++;
    if (nodeCount < 20) child.visitChildren(countNodes);
  }
  element.visitChildren(countNodes);
  if (nodeCount > 5) {
    _expensiveNodes.add('$typeName ($nodeCount descendants)');
```

Flags `RenderOpacity` based solely on subtree size (>5 descendants). Never checks the actual opacity value. An `Opacity(opacity: 1.0)` wrapping a 10-widget subtree triggers a false positive.

**Fix:** For `RenderOpacity`, check opacity value before flagging:

```dart
if (typeName.contains('RenderOpacity')) {
  if (ro is RenderOpacity) {
    final val = ro.opacity;
    if (val <= 0.0 || val >= 1.0) return; // no-op or short-circuit
  }
  // ... existing subtree size check
```

**Secondary fix:** The inner subtree walk (lines 100-105) is also addressed by v9.11.

**2. RepaintBoundaryDetector (repaint_boundary_detector.dart:73)**

```dart
if (widget is Opacity ||
    widget is ClipPath ||
    widget is BackdropFilter ||
    widget is ShaderMask ||
    widget is CustomPaint) {
```

Flags all `Opacity` widgets without checking opacity value. An `Opacity(opacity: 1.0)` triggers a spurious "missing RepaintBoundary" warning.

**Fix:** Filter non-expensive opacity before entering the RepaintBoundary ancestor check:

```dart
if (widget is Opacity) {
  if (widget.opacity <= 0.0 || widget.opacity >= 1.0) {
    // no-op or short-circuit — not GPU-expensive
  } else {
    // Check RepaintBoundary ancestor
    ...
  }
}
```

**3. OpacityDetector (opacity_detector.dart:53, 72-73)**

```dart
if (widget is Opacity && widget.opacity < 0.01) {  // line 53
```
```dart
final currentOpacity = ro.opacity.value;
if (currentOpacity < 0.01) {  // line 73 (AnimatedOpacity)
```

The threshold `< 0.01` catches mid-animation transient values. A fade-in animation passing through 0.005 on its way to 1.0 is flagged as "invisible but still active" — a false positive during transient animation frames.

**Fix:** Two changes:
1. Tighten threshold to `== 0.0` (exact zero) for static `Opacity` widgets.
2. For `AnimatedOpacity`, check `ro.opacity.status` — only flag when `AnimationStatus.completed` or `AnimationStatus.dismissed` (animation has settled), not during `forward`/`reverse`.

```dart
// Static Opacity: exact zero only
if (widget is Opacity && widget.opacity == 0.0) { ... }

// AnimatedOpacity: only when animation has settled
if (ro is RenderAnimatedOpacity) {
  final status = ro.opacity.status;
  if (ro.opacity.value == 0.0 &&
      (status == AnimationStatus.completed ||
       status == AnimationStatus.dismissed)) { ... }
}
```

**Files:** `lib/src/detectors/gpu_pressure_detector.dart`, `lib/src/detectors/repaint_boundary_detector.dart`, `lib/src/detectors/opacity_detector.dart`, corresponding tests.

**Risk:** Low. Strictly reduces false positives. All changes are additive guards before existing logic. Existing true positives (fractional opacity with deep subtrees) remain detected.

---

### v9.2: IssueRanker Paint Phase Thread Classification ✅ Shipped

**Effort:** Very Low | **Theme:** Accuracy | **Impact:** Corrects issue priority weighting for paint-related issues

**Problem:** `IssueRanker._frameImpactScore()` (issue_ranker.dart:122-132) classifies `PipelinePhase.paint` as raster-thread work:

```dart
final isUiThread =
    phase == PipelinePhase.build || phase == PipelinePhase.layout;
final isRasterThread =
    phase == PipelinePhase.paint || phase == PipelinePhase.raster;
```

This is incorrect. In Flutter's rendering pipeline, `flushPaint()` runs on the **UI thread** — it traverses the render tree and records painting commands into a `PictureRecorder`/`DisplayList`. Only `PipelinePhase.raster` (GPU submission of the recorded display list) runs on the raster thread.

**Consequence:** When jank is detected in the build/layout phase, paint-related issues get a low score (1 instead of 3) because the ranker thinks paint is on a different thread. Conversely, when jank occurs in the paint phase, build/layout issues get incorrectly downweighted.

**Fix — update both thread classification AND category matching:**

The thread assignment alone is not sufficient. The existing `matches` condition only checks `build`/`layout` categories for `isUiThread` and `paint`/`raster` categories for `isRasterThread`. Moving paint to `isUiThread` without updating the category matching means `IssueCategory.paint` issues still score 1 when `suspectedPhase == PipelinePhase.paint` (because the `isUiThread` branch only matches `build`/`layout` categories).

Replace the entire block:

```dart
// Before (broken — paint on wrong thread, categories don't match):
final isUiThread =
    phase == PipelinePhase.build || phase == PipelinePhase.layout;
final isRasterThread =
    phase == PipelinePhase.paint || phase == PipelinePhase.raster;
final matches = (isUiThread &&
        (category == IssueCategory.build ||
            category == IssueCategory.layout)) ||
    (isRasterThread &&
        (category == IssueCategory.paint ||
            category == IssueCategory.raster));

// After (correct — paint on UI thread, categories match their thread):
final isUiThread =
    phase == PipelinePhase.build ||
    phase == PipelinePhase.layout ||
    phase == PipelinePhase.paint;        // ← paint runs on UI thread
final isRasterThread =
    phase == PipelinePhase.raster;       // ← only raster is raster-thread
final matches = (isUiThread &&
        (category == IssueCategory.build ||
            category == IssueCategory.layout ||
            category == IssueCategory.paint)) ||  // ← paint is a UI-thread category
    (isRasterThread &&
        category == IssueCategory.raster);        // ← only raster on raster thread
```

**Why both changes are needed:** The thread assignment determines *which branch fires* for a given `suspectedPhase`. The category list in each branch determines *which issue categories score 3*. Both must agree — paint must be in the UI-thread group on both sides.

**Part 2 — Update `_buildRankingContext()` to emit paint/layout phases:**

The ranker fix alone is a production no-op because `_buildRankingContext()` (watchdog_controller.dart:1499-1525) collapses all UI-thread jank to `PipelinePhase.build`:

```dart
// Current (broken — only emits build or raster):
phase = latest.uiDuration > latest.rasterDuration
    ? PipelinePhase.build
    : PipelinePhase.raster;
```

When VM Timeline data is available, `RenderPipelineAnalyzer.analyzeFullMode()` and `analyzeCorrelatedMode()` correctly derive fine-grained phases (build/layout/paint/raster) from actual event durations. But `_buildRankingContext()` ignores this and re-derives a coarse binary signal. The result: even with a perfect ranker, paint-phase issues never get boosted because the ranking context never says `suspectedPhase=paint`.

**Fix:** Store the most recent verdict's phase directly in the controller as a dedicated field, rather than re-reading `verdictNotifier.value` and comparing against `frameBuffer.latest`. The problem with `verdict.frameNumber == latest.frameNumber` is that in correlated mode, `_onTimelineData()` selects `worstFrame` from the batch (watchdog_controller.dart:1100-1112) — which is not necessarily `frameBuffer.latest`. By the time `_buildRankingContext()` runs (called from `_aggregateIssues()` at line 1147), `frameBuffer.latest` may be a completely different frame, so the equality check silently discards valid correlated verdicts and falls back to the coarse build/raster heuristic.

```dart
// New controller field — set alongside verdictNotifier:
PipelinePhase? _lastVerdictPhase;
int? _lastVerdictFrameNumber;

// In _onTimelineData(), after emitting correlated verdict (line 1122):
verdictNotifier.value = verdict;
_lastVerdictPhase = verdict.suspectedPhase;
_lastVerdictFrameNumber = verdict.frameNumber;

// In _onTimelineData(), after emitting full-mode verdict (line 1140):
verdictNotifier.value = verdict;
_lastVerdictPhase = verdict.suspectedPhase;
_lastVerdictFrameNumber = verdict.frameNumber;

// In _onFrameStats(), after emitting basic-mode verdict (line 1207):
_lastVerdictPhase = verdict.suspectedPhase;
_lastVerdictFrameNumber = verdict.frameNumber;
```

```dart
// Updated _buildRankingContext():
PipelinePhase? phase;
if (jankActive && latestIsJank) {
  // Use the stored verdict phase if it was computed for a recent frame.
  // "Recent" = within the frame buffer window, not necessarily latest.
  // This handles correlated mode where the verdict frame (worstFrame)
  // differs from frameBuffer.latest.
  if (_lastVerdictPhase != null &&
      _lastVerdictPhase != PipelinePhase.unknown &&
      _lastVerdictFrameNumber != null &&
      (latest.frameNumber - _lastVerdictFrameNumber!) <= _frameTiming.frameBuffer.capacity) {
    phase = _lastVerdictPhase;
  } else {
    // Fallback: no VM verdict or verdict too old — coarse heuristic.
    phase = latest.uiDuration > latest.rasterDuration
        ? PipelinePhase.build
        : PipelinePhase.raster;
  }
}
```

**Why this is better than `verdict.frameNumber == latest.frameNumber`:**
1. **Correlated mode:** `worstFrame` is selected from `batchFrames` (line 1100-1112), not `frameBuffer.latest`. Strict equality would almost always miss.
2. **Full mode fallback:** Uses `latest` from the frame buffer at verdict time, which may have advanced by the time `_aggregateIssues()` calls `_buildRankingContext()`.
3. **Staleness protection:** The `capacity` window check (default 60 frames ≈ 1 second at 60fps) prevents a very old verdict from persisting indefinitely, while being generous enough to survive the timing gap between verdict emission and ranking context construction.

**Why NOT cache by frameNumber map:** A map of `{frameNumber → phase}` for recent frames would be more precise, but `_buildRankingContext()` only needs the *most recent* verdict's phase to boost the right category. Multiple frames in the buffer may have different bottlenecks, but the ranker applies a single phase boost — the most recent verdict is the best signal for "what is currently janking."

**Files:** `lib/src/ranking/issue_ranker.dart` (replace `_frameImpactScore` body), `lib/src/controller/watchdog_controller.dart` (update `_buildRankingContext` to read verdict phase), `test/ranking/issue_ranker_test.dart` (test: `suspectedPhase=paint` + `category=paint` → score 3, `suspectedPhase=paint` + `category=build` → score 3, `suspectedPhase=raster` + `category=paint` → score 1), `test/controller/` (controller-level test: paint-phase jank frame with VM timeline → paint-category issues ranked higher than build-category issues).

**Risk:** Low. Ranker fix is a direct mapping of Flutter's thread model. Controller fix reads an already-computed verdict — no new computation. The fallback preserves current behavior when VM is not connected.

---

### v9.3: Debug Coordinator — builtOnce Parameter Ignored ✅ Shipped

**Effort:** Very Low | **Theme:** Accuracy | **Impact:** Stops counting initial widget builds as rebuilds

**Problem:** `_handleRebuildDirtyWidget()` (debug_instrumentation_coordinator.dart:142-148) receives a `builtOnce` parameter from `debugOnRebuildDirtyWidget` but ignores it:

```dart
void _handleRebuildDirtyWidget(Element element, bool builtOnce) {
  final typeName = element.widget.runtimeType.toString();
  if (_rebuildCounts.length >= _maxTrackedTypes &&
      !_rebuildCounts.containsKey(typeName)) {
    return;
  }
  _rebuildCounts[typeName] = (_rebuildCounts[typeName] ?? 0) + 1;
```

Flutter's `debugOnRebuildDirtyWidget` calls this callback with `builtOnce = false` for initial builds and `builtOnce = true` for actual rebuilds. By ignoring this parameter, every widget's first build inflates `_rebuildCounts`, making initial page loads appear rebuild-heavy. Downstream, `SetStateScopeDetector` uses this data to upgrade confidence from `possible` to `likely`/`confirmed` — inflated counts lead to over-confident false positives on first navigation.

**Fix:**

```dart
void _handleRebuildDirtyWidget(Element element, bool builtOnce) {
  if (!builtOnce) return; // Skip initial builds — only count actual rebuilds
  // ... existing logic
```

**Files:** `lib/src/debug/debug_instrumentation_coordinator.dart` (1 line added), tests for coordinator rebuild counting.

**Risk:** Very low. Strictly reduces noise. Detectors that consume `_rebuildCounts` will see fewer counts, which may lower confidence ratings — but this is the correct behavior (counting only true rebuilds).

---

### v9.4: Layout Bottleneck — O(N²) Overclaim

**Effort:** Low | **Theme:** Accuracy | **Impact:** Stops overclaiming severity for non-nested IntrinsicHeight

**Problem:** `LayoutBottleneckDetector` (layout_bottleneck_detector.dart:61, 82-83) unconditionally claims "O(N²) layout passes" for every `IntrinsicHeight`/`IntrinsicWidth` widget:

```dart
detail: 'Causes O(N^2) layout passes',  // line 61 (highlight)
detail: 'Found ${_found.length} IntrinsicHeight/IntrinsicWidth '
    'widgets. These cause O(N²) layout passes.\n\n$locations',  // line 83
```

This is partially inaccurate. The detail text unconditionally claims "O(N²) layout passes" for all intrinsic widgets. However, per Flutter's [IntrinsicHeight API docs](https://api.flutter.dev/flutter/widgets/IntrinsicHeight-class.html): "In the worst case, this widget can result in a layout that is O(N²) in the depth of the tree." This applies even to a **single** non-nested `IntrinsicHeight` — the dry layout pass can trigger multi-pass layout in descendant render objects (e.g., `RenderFlex` with `Expanded` children), making the total O(N²) in subtree depth.

Nested intrinsics are **strictly worse** (exponential in nesting depth), but a single non-nested intrinsic is NOT always O(N) — it depends on the subtree structure. The current "O(N²)" message is the correct worst-case per Flutter's documented contract.

**Fix — two changes:**

1. **Track nesting with abort-safety:** During `checkElement`, maintain a depth counter for intrinsic widgets. **Critical:** Reset `_intrinsicDepth` in `prepareScan()` to prevent stale state after aborted tree walks. The controller catches `visitChildElements` exceptions, so one aborted walk could leave `_intrinsicDepth > 0` and incorrectly mark later non-nested intrinsic widgets as nested/critical. Follow the same abort-safety pattern used by `SetStateScopeDetector` (which resets all counters in `prepareScan()` and guards `finalizeScan()` with `_walkCompleted`).

```dart
int _intrinsicDepth = 0;

@override
void prepareScan(BuildContext context) {
  super.prepareScan(context);
  _intrinsicDepth = 0;  // Reset — prevents leak from aborted walks
  _found.clear();
}

@override
void checkElement(Element element) {
  final ro = element.renderObject;
  if (ro != null) {
    final typeName = ro.runtimeType.toString();
    if (typeName.contains('RenderIntrinsicHeight') ||
        typeName.contains('RenderIntrinsicWidth')) {
      final isNested = _intrinsicDepth > 0;
      _intrinsicDepth++;
      _found.add((name: element.widget.runtimeType.toString(), nested: isNested));
      // ... highlight with correct detail
    }
  }
}

@override
void afterElement(Element element) {
  // Decrement depth if this was an intrinsic widget
  final ro = element.renderObject;
  if (ro != null) {
    final typeName = ro.runtimeType.toString();
    if (typeName.contains('RenderIntrinsicHeight') ||
        typeName.contains('RenderIntrinsicWidth')) {
      _intrinsicDepth--;
    }
  }
}
```

**Abort-safety guarantee:** Even if the tree walk throws mid-traversal and `afterElement` is never called for some nodes, the next `prepareScan()` resets `_intrinsicDepth` to 0, so no stale depth leaks across scans. This mirrors `SetStateScopeDetector`'s `prepareScan()` pattern (setstate_scope_detector.dart:107-117) which resets `_walkCompleted`, `_totalElements`, and all tracking state unconditionally.

2. **Differentiate messaging — keep warning severity for all, escalate nested to critical:**
   - Nested: "O(N²+) layout — nested IntrinsicHeight/Width multiplies layout passes" (critical)
   - Non-nested: "Potentially O(N²) layout — IntrinsicHeight/Width triggers speculative layout passes" (warning, same as current)

**Important:** Do NOT downgrade non-nested intrinsic widgets. Per Flutter's documented worst-case contract, even a single `IntrinsicHeight` can be O(N²) in subtree depth. The non-nested case keeps the existing warning severity. Only nested cases are escalated to critical because nesting guarantees exponential pass multiplication.

**Files:** `lib/src/detectors/layout_bottleneck_detector.dart`, tests.

**Risk:** Low. Non-nested cases keep current severity (warning). Nested cases escalate to critical. No false downgrades — respects Flutter's documented worst-case complexity.

---

### v9.5: CustomPainter — foregroundPainter Not Checked ✅ Shipped

**Effort:** Very Low | **Theme:** Accuracy | **Impact:** Detects bad shouldRepaint on foreground painters

**Problem:** `CustomPainterDetector.checkElement()` (custom_painter_detector.dart:56) only checks `widget.painter`:

```dart
if (widget is CustomPaint && widget.painter != null) {
  final painter = widget.painter!;
  try {
    if (painter.shouldRepaint(painter)) {
```

`CustomPaint` has two painter slots: `painter` (background) and `foregroundPainter` (foreground). Both can have problematic `shouldRepaint` implementations. The detector completely ignores `foregroundPainter`.

**Fix:** Check both painters:

```dart
if (widget is CustomPaint) {
  if (widget.painter != null) {
    _checkPainter(element, widget.painter!, 'painter');
  }
  if (widget.foregroundPainter != null) {
    _checkPainter(element, widget.foregroundPainter!, 'foregroundPainter');
  }
}
```

Extract the existing painter check into a `_checkPainter(Element, CustomPainter, String label)` helper to avoid duplication.

**Files:** `lib/src/detectors/custom_painter_detector.dart`, tests.

**Risk:** None. Strictly additive — existing painter checks unchanged.

---

### v9.6: Per-Scrollable Count Accumulation

**Effort:** Medium | **Theme:** Accuracy | **Impact:** Stops inflated counts from unrelated scrollables

**Problem:** Two detectors accumulate counts globally across all scrollable widgets instead of per-scrollable:

**GlobalKeyDetector (global_key_detector.dart:78-83):**

```dart
final before = _globalKeyCount;
_countUserGlobalKeys(element, (n) => _globalKeyCount += n);
if (_globalKeyCount > before) {
  _scrollableLocations.add(buildAncestorChain(element));
  final ro = element.renderObject;
  if (ro != null) _parentRect = getGlobalRect(ro);  // overwrites — last wins
```

`_globalKeyCount` is a single scalar that accumulates across all `ListView`/`GridView`/`PageView` widgets. If page has 3 ListViews with 5, 3, 4 GlobalKeys respectively, the detector reports 12 GlobalKeys as if one scrollable has them all. Additionally, `_parentRect` is overwritten by each scrollable — only the last scrollable's rect is used for the highlight.

**KeepAliveDetector (keep_alive_detector.dart:60-75):** Same pattern — `_keepAliveCount` accumulates across all `PageView`/`TabBarView` widgets, and `_parentRect` is overwritten.

**Fix — both detectors:** Replace scalar accumulators with per-scrollable tracking:

```dart
// GlobalKeyDetector
final _scrollableData = <({int count, Rect? rect, String chain})>[];

@override
void checkElement(Element element) {
  final widget = element.widget;
  if (widget is ListView || widget is GridView || widget is PageView) {
    int count = 0;
    _countUserGlobalKeys(element, (n) => count += n);
    if (count > 0) {
      _scrollableData.add((
        count: count,
        rect: element.renderObject != null ? getGlobalRect(element.renderObject!) : null,
        chain: buildAncestorChain(element),
      ));
    }
  }
}
```

In `finalizeScan`, threshold **per-scrollable only** — emit one issue/highlight per scrollable that individually exceeds the threshold. Never sum counts across scrollables for threshold decisions; summing reintroduces the exact false positive this milestone fixes (e.g., three scrollables with 8, 8, 8 keys would incorrectly exceed threshold 20 even though no individual scrollable is problematic). Totals may appear in secondary detail text for context ("24 total across 3 scrollables"), but must never drive the flag/no-flag decision. Highlight rects are per-scrollable.

**Critical — per-scrollable stableIds:** Each emitted issue must have a **unique stableId** that includes scrollable identity. The current detectors use a single stableId (`'excessive_global_keys'` at global_key_detector.dart:109, `'excessive_keep_alive'` at keep_alive_detector.dart:101). If v9.6 emits multiple per-scrollable issues sharing the same stableId, three things break:

1. **`PerformanceIssue.==`** (performance_issue.dart:287-291) collapses same-stableId objects, so deduplication/set membership would treat distinct scrollable issues as identical.
2. **`ValueKey(issueKey)`** (floating_issues_card.dart:495) where `issueKey = issue.stableId ?? issue.title` — duplicate keys cause Flutter framework errors and broken list state.
3. **`_expandedIssueId`/`_selectedIssueId`** (floating_issues_card.dart:40,473) — expansion/highlight/suppression would attach to the wrong card or all cards simultaneously.

**Fix:** Derive per-scrollable stableIds using the scan-order index, NOT `String.hashCode`:

```dart
// In finalizeScan:
for (final (i, data) in _scrollableData.indexed) {
  if (data.count >= threshold) {
    _issues.add(PerformanceIssue(
      // ... same fields as current ...
      stableId: 'excessive_global_keys:$i',
      detail: '${data.count} user GlobalKeys in ${_scrollableTypeName(data)}...',
      // ...
    ));
  }
}
```

**Why NOT `data.chain.hashCode`:** Two problems make hash-based IDs unsuitable:
1. **Non-unique:** `buildAncestorChain()` (widget_location.dart:79-100) captures only ancestor widget type names, not sibling positions. Two sibling `ListView` widgets under the same `Column` produce identical chains (e.g., "MyPage > Column > ListView"), so `chain.hashCode` would collide — recreating the exact duplicate-key bug this fix is meant to prevent.
2. **Non-stable:** Dart's `String.hashCode` is not contractually stable across VM restarts (the Dart language spec makes no such guarantee), so suppressions keyed by hash could silently drift between app sessions.

**Why scan-order index works:** Detectors visit children in depth-first tree order (inherited from `visitChildElements`), so the index is deterministic within a scan. The ordering is stable across rescans as long as the widget tree structure doesn't change — which is the same stability guarantee the existing single-stableId approach provides. If the tree changes (scrollable added/removed), indices shift, but so would any structural identity. The index approach is strictly better than hash: unique within a scan, no cross-restart drift, and trivially simple.

Same pattern for KeepAliveDetector. Add a test: two ListViews both above threshold → two distinct issues with different stableIds, both rendering simultaneously in the issues list.

**Files:** `lib/src/detectors/global_key_detector.dart`, `lib/src/detectors/keep_alive_detector.dart`, tests.

**Risk:** Low. Changes internal data model. StableId format change means existing suppressions targeting the old bare `'excessive_global_keys'` string won't match per-scrollable IDs — but `_matchesSuppression()` (watchdog_controller.dart:1491-1496) already supports prefix matching, so users can suppress with `'excessive_global_keys'` as a prefix pattern to match all per-scrollable variants.

---

### v9.7: Image Detector — Messaging Improvement (No Behavioral Change) ✅ Shipped

**Effort:** Very Low | **Theme:** Accuracy | **Impact:** Improves issue detail text and fix hints for uncached images

**Problem:** `ImageMemoryDetector.checkElement()` (image_memory_detector.dart:69-72) correctly flags every `Image` widget that lacks `ResizeImage`. The detection predicate (`provider is ResizeImage`) is correct and should not change. However, the issue detail text (line 87: `'No cacheWidth/cacheHeight\n$sourceName'`) and the fix hint could be more actionable.

**Why no behavioral change:** Through adversarial review, all proposed suppression heuristics were found to be unsafe:
- **RenderBox.size:** Layout size ≠ decode size. A 4000×4000 `AssetImage` in a 32×32 box decodes at full resolution.
- **MemoryImage.bytes.length:** Encoded size ≠ decoded size. A highly compressible 4000×4000 PNG can be <16KB encoded but ~61MB decoded.
- **AssetImage filename heuristics:** (`contains('icon')`, `contains('logo')`) — no guaranteed relationship to dimensions. A `splash_logo.png` could be 4000×4000.
- **SVG extension check:** Flutter's `Image` widget can't decode SVGs — dead code.

The current `ResizeImage`-only suppression is the only safe predicate. All other providers are flagged because we cannot determine decoded dimensions without async resolution.

**Fix — improve messaging only:**

1. **Detail text:** Include the provider type to help the user understand what kind of image was flagged:
   - `'Uncached AssetImage: $sourceName\nAdd cacheWidth/cacheHeight or wrap in ResizeImage'`
   - `'Uncached NetworkImage: $sourceName\nAdd cacheWidth/cacheHeight or wrap in ResizeImage'`
   - `'Uncached MemoryImage\nAdd cacheWidth/cacheHeight or wrap in ResizeImage'`

2. **Fix hint:** Update `FixHintBuilder.uncachedImage()` to include a concrete code example showing how to add `cacheWidth`/`cacheHeight`.

**Files:** `lib/src/detectors/image_memory_detector.dart` (detail text), `lib/src/utils/fix_hint_builder.dart` (hint text), tests (verify provider type appears in detail).

**Risk:** None. No behavioral change — only improves the diagnostic text users see.

---

### v9.8: Timeline Parser — Event Name Validation

**Effort:** Low | **Theme:** Accuracy | **Impact:** Validates that current event name sets match actual Flutter engine output

**Problem:** `TimelineParser` (timeline_parser.dart:81-101) uses bare single-word names alongside specific names in its match sets:

```dart
static const _buildNames = { 'buildscope', 'build', 'build_scope' };
static const _layoutNames = { 'flushlayout', 'layout', 'flush_layout' };
static const _paintNames = { 'flushpaint', 'paint', 'flush_paint' };
static const _rasterNames = { 'gpurasterizer::draw', 'gpurasterizer', 'rasterizer::dodraw', 'raster' };
```

The bare names (`'build'`, `'paint'`, `'layout'`) are generic English words. The concern is that unrelated timeline events with these exact names could be misclassified. However, **these names cannot be removed without verification** — the parser lowercases all event names at line 160 (`name.toLowerCase()`), so an engine emitting `Build`, `Layout`, or `Paint` as event names would match via the bare lowercase entries. Removing them blindly would silently break phase duration tracking for those engines.

**Why NOT remove bare names speculatively:** The v8.4 experience demonstrated the value of evidence-first changes — the platform channel classifier was fundamentally wrong in ways that only real trace data revealed. The same discipline applies here. Removing `'build'` without proof that no engine emits it risks a silent regression.

**Fix — trace-first validation (same pattern as v8.4):**

1. **[PREREQUISITE] Capture real VM timeline traces** from the example app on Android device, Android emulator, iOS device, and desktop (macOS). Record all unique `name` values emitted during build/layout/paint phases. Identify which names match the current sets and which are extra or missing.

2. **Based on trace results, do one of:**
   - **If bare names appear in traces:** Keep them. Add a comment documenting which engine/platform emits them. Add positive test fixtures that replay these events.
   - **If bare names never appear:** Remove them. Add negative tests confirming that only prefixed forms match.
   - **If new names are discovered:** Add them to the sets with trace evidence.

3. **Either way, add regression tests:** Replay fixtures with `Build`, `build`, `buildscope`, `buildScope` etc. and assert correct phase classification. This locks in the current behavior so future changes are caught.

**Files:** `lib/src/vm/timeline_parser.dart` (0-3 lines changed depending on trace results), `test/vm/timeline_parser_test.dart` (new trace-replay tests).

**Risk:** None if trace capture is completed first. The prerequisite eliminates guesswork. If trace capture is impractical, the fallback is to keep all current names and only add regression tests — no removals without evidence.

---

### v9.9: runtimeType.toString() Allocation Reduction

**Effort:** Medium | **Theme:** Performance | **Impact:** Eliminates ~7 string allocations per scan in scan-root resolution

**Problem:** `WatchdogController` calls `widget.runtimeType.toString()` at 7 locations in the scan-root resolution path. Each call allocates a new String on the UI thread, per element visited:

| Line | Function | String Comparison |
|------|----------|-------------------|
| 714 | `_findVisiblePageContext` | `== 'FloatingIssuesCard'`, `== 'TriggerButton'`, `== 'HighlightOverlay'` |
| 722 | `_findVisiblePageContext` | `== 'Scaffold'`, `== 'CupertinoPageScaffold'` |
| 761 | `_findVisiblePageContext` | `startsWith('_')` |
| 785 | `_findActiveRouteScanRoot` | `== 'FloatingIssuesCard'`, `== 'TriggerButton'`, `== 'HighlightOverlay'`, `== 'Navigator'` |
| 809 | `collectEntries` | `== '_OverlayEntryWidget'`, `== 'OverlayEntry'` |
| 849 | `_isRouteOwnedEntry` | `startsWith('_ModalScope')` |
| 867 | `_containsNestedNavigator` | `== 'Navigator'` |
| 886 | `_captureRouteName` | `== '_ModalScopeStatus'` |

**Fix — two strategies:**

1. **Replace with `widget is Type` checks** where the type is importable (most Material/Cupertino types are public):

```dart
// Before (allocates String):
final name = widget.runtimeType.toString();
if (name == 'Scaffold' || name == 'CupertinoPageScaffold') { ... }

// After (zero allocation):
if (widget is Scaffold || widget is CupertinoPageScaffold) { ... }
```

Applicable to: `Scaffold`, `CupertinoPageScaffold`, `Navigator`, `Offstage`, `TickerMode` (already done for last two at lines 708/711).

2. **For private types** (`_OverlayEntryWidget`, `_ModalScope`, `_ModalScopeStatus`), `widget is Type` is not possible. Keep `runtimeType.toString()` but compute once per element and reuse:

```dart
// Before (3 separate toString() calls in one function):
if (el.widget.runtimeType.toString().startsWith('_ModalScope')) { ... }

// After (single toString(), multiple comparisons):
final name = el.widget.runtimeType.toString();
if (name.startsWith('_ModalScope')) { ... }
```

3. **For overlay widget exclusion** (lines 714-717, 785-789), replace string comparisons with `widget is` checks using the actual imported types (`FloatingIssuesCard`, `TriggerButton`, `HighlightOverlay` — all defined in the package).

**Files:** `lib/src/controller/watchdog_controller.dart` (~7 locations), no test changes needed (behavior unchanged).

**Risk:** None. Pure optimization — same behavior, fewer allocations. The `is` operator is a constant-time type check with zero allocation.

---

### v9.10: FrameStatsBuffer Hot-Path Allocations

**Effort:** Medium | **Theme:** Performance | **Impact:** Eliminates redundant List allocations per frame

**Problem:** Multiple hot-path allocations in the frame processing pipeline:

**1. `frames` getter (frame_stats.dart:160):**

```dart
List<FrameStats> get frames => _buffer.toList();
```

Every access creates a new `List<FrameStats>`. Called at least twice per frame evaluation (lines 172, 220 in frame_timing_detector.dart).

**2. `fpsPercentiles()` (frame_stats.dart:206-211):**

```dart
final fpsValues = _buffer.map((f) {
  final us = f.effectiveTotalDuration.inMicroseconds;
  if (us <= 0) return 120.0;
  return (1000000.0 / us).clamp(0.0, 120.0);
}).toList()
  ..sort();
```

Allocates a new List + closure per call.

**3. `_evaluateJank()` double frames access (frame_timing_detector.dart:172-176):**

```dart
final frames = _buffer.frames;   // allocation #1
// ...
final severeCount = frames.where((f) => f.isSevereJank).length;  // closure #1
final jankCount = frames.where((f) => f.isJank).length;           // closure #2
```

Two separate `.where()` iterations with closures instead of a single-pass count.

**4. `_evaluateCacheTrends()` second frames access (frame_timing_detector.dart:220-221):**

```dart
final frames = _buffer.frames;   // allocation #2 (same scan cycle)
```

**5. `FrameStatsBuffer.from()` per frame (watchdog_controller.dart:1202):**

```dart
frameStatsNotifier.value = FrameStatsBuffer.from(buffer);
```

Copies entire buffer (Queue.addAll) every frame callback.

**Fix — five changes:**

1. **Cache a `List` snapshot internally** (invalidated on add AND clear):

```dart
List<FrameStats>? _cachedFrames;
bool _percentilesDirty = true;

List<FrameStats> get frames =>
    _cachedFrames ??= List.unmodifiable(_buffer);

void add(FrameStats stats) {
  _buffer.add(stats);
  if (_buffer.length > _capacity) _buffer.removeFirst();
  _cachedFrames = null; // invalidate — next access rebuilds
  _percentilesDirty = true;
}

void clear() {
  _buffer.clear();
  _cachedFrames = null;       // invalidate cached frames
  _percentilesDirty = true;   // invalidate cached percentiles
}
```

**Critical:** `clear()` must invalidate both `_cachedFrames` and `_percentilesDirty`. The current `clear()` is called from `FrameTimingDetector.dispose()`, so without cache invalidation, post-clear calls to `frames`, `latest`, or `fpsPercentiles()` would return stale pre-clear data until the next `add()`. Add a regression test: call `add()` N times, verify `frames` has N entries, call `clear()`, verify `frames` is empty and `fpsPercentiles()` returns zero percentiles.

**Why NOT `UnmodifiableListView(_buffer)`:** `UnmodifiableListView.operator[]` delegates to `_source.elementAt(index)`, and `Queue.elementAt` is O(N). Consumers like `frames.last` and `frames[frames.length - 2]` in `_evaluateCacheTrends()` would become O(N) per indexed access. Caching a real `List` keeps indexed access O(1) while still avoiding copies on repeated access within the same frame cycle.

2. **Single-pass jank counting** in `_evaluateJank()`:

```dart
int severeCount = 0, jankCount = 0;
FrameStats? worst;
for (final f in _buffer.frames) {
  if (f.isSevereJank) severeCount++;
  if (f.isJank) jankCount++;
  if (worst == null || f.effectiveTotalDuration > worst.effectiveTotalDuration) {
    worst = f;
  }
}
```

Replaces 2× `.where().length` + 2× `.reduce()` with one loop.

3. **Cache frames locally** in `_evaluateJank` and pass to `_evaluateCacheTrends` to avoid double getter access.

4. **Listener-gated buffer copy** for notifier — only run `FrameStatsBuffer.from(buffer)` when `frameStatsNotifier` has active listeners. The copy itself must still create a **new instance** because `ValueNotifier` uses identity comparison (`FrameStatsBuffer` has no custom `==`), and `ValueListenableBuilder` in `trigger_button.dart:140` and `floating_issues_card.dart:540` only rebuilds when `.value` changes identity. Reusing the same instance would suppress all FPS/jank UI updates. The optimization is skipping the copy entirely when no UI is listening, not eliminating the copy.

5. **Lazy dirty-flag for `fpsPercentiles()`** — `fpsPercentiles()` is only called from `exportSnapshot()` (watchdog_controller.dart:525), not from any per-frame or per-scan hot path. Do NOT maintain a pre-sorted list incrementally on every `add()` — that would move O(N) insertion work onto the hot path to optimize a rarely-called export method. Instead, set a `_percentilesDirty = true` flag on `add()` and rebuild the cached sorted snapshot lazily on the next `fpsPercentiles()` call only when the flag is set.

**Files:** `lib/src/models/frame_stats.dart`, `lib/src/detectors/frame_timing_detector.dart`, `lib/src/controller/watchdog_controller.dart`, tests.

**Risk:** Low. Internal data representation change. External API (`frames`, `fpsPercentiles`) unchanged in type signature. Cached `List.unmodifiable` prevents external mutation while keeping O(1) indexed access (unlike `UnmodifiableListView` over `Queue` which would be O(N)).

---

### v9.11: Inner Subtree Walks — 4 Detectors

**Effort:** Medium | **Theme:** Performance | **Impact:** Restores true O(N) for the unified tree walk

**Problem:** Four detectors perform recursive inner subtree walks inside `checkElement`, defeating the v7.9 unified O(N) tree walk:

**1. AnimatedBuilderDetector (animated_builder_detector.dart:65-71):**

```dart
int subtreeSize = 0;
void countSubtree(Element child) {
  subtreeSize++;
  child.visitChildren(countSubtree);
}
element.visitChildren(countSubtree);
```

Counts subtree size to determine if an AnimatedBuilder without `child` is wrapping a large tree.

**2. GpuPressureDetector (gpu_pressure_detector.dart:99-105):**

```dart
int nodeCount = 0;
void countNodes(Element child) {
  nodeCount++;
  if (nodeCount < 20) child.visitChildren(countNodes);
}
element.visitChildren(countNodes);
```

Counts subtree size under expensive render objects (RenderOpacity, RenderClipPath, etc.).

**3. GlobalKeyDetector (global_key_detector.dart:131-142):**

```dart
void _countUserGlobalKeys(Element scrollElement, void Function(int) add) {
  void check(Element element) {
    if (element.widget.key is GlobalKey) {
      final name = element.widget.runtimeType.toString();
      if (!name.startsWith('_') && !frameworkWidgets.contains(name)) {
        add(1);
      }
    }
    element.visitChildren(check);
  }
  scrollElement.visitChildren(check);
}
```

Walks entire scrollable subtree to count user-level GlobalKeys.

**4. KeepAliveDetector (keep_alive_detector.dart:63-71):**

```dart
void countKeepAlives(Element child) {
  final typeName = child.widget.runtimeType.toString();
  if (typeName == 'KeepAlive' || typeName == '_KeepAlive') {
    _keepAliveCount++;
  }
  child.visitChildren(countKeepAlives);
}
element.visitChildren(countKeepAlives);
```

Walks entire PageView/TabBarView subtree to count KeepAlive widgets.

**Fix — use `afterElement` subtree accumulation** (same pattern as v8.1 SetState fix):

For **AnimatedBuilderDetector** and **GpuPressureDetector** (subtree size counting):
- Push 0 onto a stack in `checkElement`
- Accumulate in `afterElement` using `stack.last += childSize + 1`
- Read accumulated subtree size from stack when evaluating the flagging condition

For **GlobalKeyDetector** and **KeepAliveDetector** (type-specific counting within scrollables):
- These need to count specific widget types (GlobalKey, KeepAlive) within a scrollable's subtree, not just raw subtree size.
- Track the "owning scrollable" via a stack: push scrollable identity in `checkElement`, pop in `afterElement`. Between push and pop, count matching widgets encountered in `checkElement`.
- This replaces the inner walk with per-element accumulation during the unified walk.

**Files:** All 4 detector files, corresponding tests.

**Risk:** Medium. Requires careful stack management. Use the v8.1 SetState implementation as a proven template. Each detector's `afterElement` must correctly handle the abort-safety guarantees (stack drained on walk failure).

---

### v9.12: _aggregateIssues Allocation Storm

**Effort:** Low | **Theme:** Performance | **Impact:** Reduces redundant list building in issue pipeline

**Problem:** `_getAllIssues()` (watchdog_controller.dart:1539-1541) flattens all detector issues into a new list:

```dart
List<PerformanceIssue> _getAllIssues() {
  return [for (final d in _detectors) ...d.issues];
}
```

This is called **3 times** per timeline data cycle:
- Line 1115: in correlated mode scan
- Line 1133: in fallback mode scan
- Line 1437: in `_aggregateIssues()`

Additionally, `_aggregateIssues()` itself chains `.map().toList()` (line 1445-1451) and `.where().toList()` (line 1459-1461), creating 3+ list allocations per call.

**Fix — local snapshot, not shared cache:**

A shared `_cachedAllIssues` field is unsafe because `_getAllIssues()` is called from multiple independent paths that can interleave:
- `_onTimelineData()` → correlated mode (line 1115) and fallback mode (line 1133)
- `_onFrameStats()` → FRAME mode verdict (line 1210)
- `_aggregateIssues()` → issue pipeline (line 1437)
- `_enrichWithAllocationProfile()` → mutates `_memoryPressure.issues` (line 1329), then calls `_aggregateIssues()`

Invalidating only at `_onTimelineData()` and `_runScan()` start would miss the `_onFrameStats()` path entirely, and the enrichment mutation would read stale data. A per-field cache requires invalidation at every detector mutation point — fragile and easy to miss.

**Instead, compute once per call-site and pass through:**

```dart
// In _onTimelineData:
void _onTimelineData(ParsedTimelineData data) {
  // ... existing processing ...
  final currentIssues = _getAllIssues(); // single snapshot for this cycle
  
  // Use currentIssues for correlated mode scan...
  if (worstFrame != null && worstCorrelation != null) {
    var verdict = _analyzer.analyzeCorrelatedMode(
      frameStats: worstFrame,
      correlation: worstCorrelation,
      relatedIssues: currentIssues,  // reuse same list
    );
    // ...
  }
  
  // Fallback uses same snapshot
  if (captureVerdict == null) {
    var verdict = _analyzer.analyzeFullMode(
      frameStats: latest,
      timelineData: data,
      relatedIssues: currentIssues,  // reuse same list
    );
    // ...
  }
}
```

For `_onFrameStats()`, compute its own fresh snapshot:

```dart
void _onFrameStats(FrameStatsBuffer buffer) {
  // ... existing code ...
  if (latest != null && latest.isJank && !isVmConnected) {
    final issues = _getAllIssues(); // fresh at point of use
    verdictNotifier.value = _enrichVerdictWithNetworkContext(
      _analyzer.analyzeBasicMode(frameStats: latest, relatedIssues: issues),
    );
  }
}
```

**`_aggregateIssues()` remains unchanged** — it calls `_getAllIssues()` and gets a fresh snapshot because it always runs after detector state has been updated.

**Secondary optimization — reduce `_aggregateIssues()` intermediate allocations:**
- Replace `.map().toList()` + `.where().toList()` with a single `for` loop that stamps, filters, and collects in one pass:

```dart
void _aggregateIssues() {
  final all = _getAllIssues();
  final correlated = _detectorCorrelator.correlate(all);
  final route = _currentRouteName();
  
  final List<PerformanceIssue> visible = [];
  int suppressedCount = 0;
  for (final issue in correlated) {
    final stamped = issue.copyWith(
      debugModeDisclaimer: kDebugMode ? true : null,
      routeName: route,
      interactionContext: _interactionState,
    );
    if (config.suppressedIssues.isNotEmpty &&
        _matchesSuppression(stamped.stableId ?? stamped.title)) {
      suppressedCount++;
    } else {
      visible.add(stamped);
    }
  }
  suppressedCountNotifier.value = suppressedCount;
  issuesNotifier.value = _ranker.rank(visible, _buildRankingContext());
}
```

This eliminates 2 intermediate list allocations per call.

**Files:** `lib/src/controller/watchdog_controller.dart`, no test changes (behavior unchanged).

**Risk:** Very low. Each call-site gets a fresh snapshot. No shared mutable cache. The single-loop refactor in `_aggregateIssues` produces identical output with fewer allocations.

---

### v9.13: List.removeAt(0) → Queue/Ring Buffer

**Effort:** Low | **Theme:** Performance | **Impact:** O(1) eviction instead of O(N) in two detectors

**Problem:** Two detectors use `List.removeAt(0)` for FIFO eviction:

**NetworkMonitorDetector (network_monitor_detector.dart:104-105):**

```dart
_records.add(record);
if (_records.length > _bufferCapacity) _records.removeAt(0);  // capacity: 200
```

**MemoryPressureDetector (memory_pressure_detector.dart:89-90):**

```dart
_heapSamples.add(sample);
if (_heapSamples.length > _windowCapacity) _heapSamples.removeAt(0);  // capacity: 60
```

`List.removeAt(0)` shifts all elements left — O(N) per eviction. For `_records` at capacity 200, this means 199 element moves per new record. These are called on every HTTP response and every heap sample respectively.

**Fix:** Replace `List` with `Queue` (O(1) `removeFirst()`) or a ring buffer:

```dart
final Queue<RequestRecord> _records = Queue<RequestRecord>();

void processRecord(RequestRecord record) {
  _records.addLast(record);
  if (_records.length > _bufferCapacity) _records.removeFirst();  // O(1)
  // ...
```

Note: If downstream code uses list indexing (`_records[i]`), convert to `Queue.elementAt(i)` or maintain an `UnmodifiableListView` cache that refreshes on access.

**Files:** `lib/src/detectors/network_monitor_detector.dart`, `lib/src/detectors/memory_pressure_detector.dart`, tests.

**Risk:** Very low. Drop-in replacement. `Queue` supports `add`, `removeFirst`, `length`, `isEmpty`, iteration — all operations used by these detectors.

---

### v9.14: Highlight Overlay Self-Overhead

**Effort:** Medium | **Theme:** Performance | **Impact:** Reduces GPU/allocation cost of the diagnostic overlay itself

**Problem:** The highlight overlay (`highlight_overlay.dart`) uses three patterns that create self-overhead:

**1. `canvas.saveLayer()` (line 107):**

```dart
canvas.saveLayer(screenRect, Paint());
canvas.drawRect(screenRect, dimPaint);
// Cut out selected widget area
final clearPaint = Paint()..blendMode = BlendMode.clear;
canvas.drawRRect(..., clearPaint);
canvas.restore();
```

`saveLayer` allocates an offscreen GPU buffer — the exact GPU-expensive pattern that `GpuPressureDetector` warns users about.

**2. TextPainter allocation in paint() (lines 139-142):**

```dart
final textPainter = TextPainter(
  text: textSpan,
  textDirection: TextDirection.ltr,
)..layout(maxWidth: (h.rect.width + 100).clamp(120, 350));
```

Creates and lays out a new `TextPainter` every paint call (60fps when animating).

**3. Identity-based shouldRepaint (lines 160-163):**

```dart
bool shouldRepaint(_HighlightPainter old) =>
    !identical(old.highlights, highlights) ||
    !identical(old.selected, selected) ||
    !identical(old.theme, theme);
```

Uses `identical()` — if the highlights list is rebuilt with the same contents (common when `issuesNotifier` updates), `shouldRepaint` returns true and triggers unnecessary repaints.

**Fix:**

1. **Replace `saveLayer` with clip-based dimming:**

```dart
// Save, clip out the selected rect, draw dim, restore
canvas.save();
canvas.clipRect(screenRect);
canvas.clipRRect(selectedRRect, clipOp: ui.ClipOp.difference);
canvas.drawRect(screenRect, dimPaint);
canvas.restore();
```

No offscreen buffer needed. `ClipOp.difference` is supported on all platforms.

2. **Cache TextPainter:** Store as instance field, rebuild only when `selected` changes.

3. **Generation-counter shouldRepaint:**

Length-only comparison is insufficient — `WidgetHighlight` has no `==` operator (it contains `Rect`, `String`, `IssueSeverity`, all mutable-like fields), so element-wise comparison would require adding `operator ==` and `hashCode` to `WidgetHighlight`. Instead, use a **generation counter** that increments whenever the highlight list is rebuilt. This is cheap (single `int` comparison), correct (any content change bumps the generation), and doesn't require modifying `WidgetHighlight`.

**Bundle generation into the notifier payload** using a Dart record type. The controller currently exposes `highlightsNotifier` as `ValueNotifier<List<WidgetHighlight>>` (watchdog_controller.dart:171). A plain `int _highlightGeneration` field would be library-private to `watchdog_controller.dart` — `watchdog_overlay.dart` is a different library and cannot access it. More importantly, `HighlightOverlay` is a `StatelessWidget` — passing a plain `int` constructor parameter won't trigger rebuilds when the generation changes. The generation must flow through a `ValueNotifier` so `ValueListenableBuilder` can listen to it.

**Fix:** Change the notifier's type to carry both generation and highlights in a single record. This keeps a single `ValueListenableBuilder` (no additional listener setup) and ensures generation changes trigger rebuilds AND reach the painter:

**In the controller:**

```dart
// Change type from ValueNotifier<List<WidgetHighlight>> to record:
int _highlightGeneration = 0;
final ValueNotifier<({int generation, List<WidgetHighlight> items})>
    highlightsNotifier = ValueNotifier((generation: 0, items: []));

// Replace _collectHighlights():
void _collectHighlights() {
  _highlightGeneration++;
  highlightsNotifier.value = (
    generation: _highlightGeneration,
    items: [for (final d in _detectors) ...d.highlights],
  );
}

// Direct-clear paths (lines 655-656, 696-697):
_highlightGeneration++;
highlightsNotifier.value = (generation: _highlightGeneration, items: []);
```

**In `HighlightOverlay`** — update to destructure the record payload:

```dart
class HighlightOverlay extends StatelessWidget {
  const HighlightOverlay({
    super.key,
    required this.highlights,
    required this.selectedHighlight,
  });

  final ValueNotifier<({int generation, List<WidgetHighlight> items})> highlights;
  final ValueNotifier<WidgetHighlight?> selectedHighlight;

  @override
  Widget build(BuildContext context) {
    final theme = WatchdogTheme.of(context);
    return IgnorePointer(
      child: ValueListenableBuilder<({int generation, List<WidgetHighlight> items})>(
        valueListenable: highlights,
        builder: (_, payload, __) => ValueListenableBuilder<WidgetHighlight?>(
          valueListenable: selectedHighlight,
          builder: (_, selected, __) {
            if (payload.items.isEmpty && selected == null) {
              return const SizedBox.shrink();
            }
            return CustomPaint(
              painter: _HighlightPainter(
                highlights: payload.items,
                generation: payload.generation,
                selected: selected,
                theme: theme,
              ),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}
```

**In the painter:**

```dart
_HighlightPainter({
  required this.highlights,
  required this.generation,
  this.selected,
  required this.theme,
});

final int generation;

@override
bool shouldRepaint(_HighlightPainter old) =>
    old.generation != generation ||
    old.selected != selected ||
    old.theme != theme;
```

**Data flow:** Controller increments `_highlightGeneration` and assigns a new record to `highlightsNotifier.value` → `ValueListenableBuilder` in `HighlightOverlay` rebuilds (record is a new value, not identity-compared) → `CustomPaint` receives updated `generation` int → `shouldRepaint` compares the integer.

**Why this works:** Dart records have structural equality — `(generation: 1, items: [...])` ≠ `(generation: 2, items: [...])` — so `ValueNotifier` will always notify on generation bump even if the list contents happen to be identical references. This eliminates the stale-`shouldRepaint` bug.

**Update callers:** All existing code that reads `highlightsNotifier.value` as a `List<WidgetHighlight>` must be updated to read `.items`:
- `selectHighlightForIssue()` (watchdog_controller.dart:202,205): `highlightsNotifier.value.items`
- `refreshHighlights()` path (watchdog_controller.dart:655,696): already handled by direct-clear pattern above
- `watchdog_overlay.dart:72`: `highlights: widget.controller.highlightsNotifier` — type change is transparent, `HighlightOverlay`'s parameter type matches.

This catches all content changes (rect moved after scroll, severity changed, detail updated) because any controller-side update increments the generation. Same-content rebuilds still trigger repaint — but the highlight list is only rebuilt on actual scan completion, not on every frame, so this is acceptable overhead.

4. **Rebind selected highlight after refresh:**

`_collectHighlights()` publishes new `WidgetHighlight` objects with fresh rects (after scroll/rescan), but `selectedHighlightNotifier.value` still holds the **old** `WidgetHighlight` object with stale `rect`. The painter uses `selected.rect` to draw the selected border, so it points at the wrong coordinates even though markers moved.

**Current code path:** `refreshHighlights()` (watchdog_controller.dart:942-951) calls `_runStructuralScans()` then `_collectHighlights()`. Detectors regenerate highlights with updated rects, but `selectedHighlightNotifier` is never updated — it retains the old object.

**Fix:** After `_collectHighlights()` publishes the new list, resolve the current selection against the fresh highlights. `selectHighlightForIssue()` already matches by `widgetName` or `detectorName` (watchdog_controller.dart:208-228), but we need a lighter mechanism — match by `detectorName + widgetName` within the new list:

```dart
void _collectHighlights() {
  _highlightGeneration++;
  final items = [for (final d in _detectors) ...d.highlights];
  highlightsNotifier.value = (generation: _highlightGeneration, items: items);

  // Rebind selected highlight to fresh object with updated rect
  final selected = selectedHighlightNotifier.value;
  if (selected != null) {
    final refreshed = items.cast<WidgetHighlight?>().firstWhere(
      (h) => h!.detectorName == selected.detectorName &&
             h.widgetName == selected.widgetName,
      orElse: () => null,
    );
    selectedHighlightNotifier.value = refreshed; // null clears if widget gone
  }
}
```

This ensures the selected border tracks the widget's current position after scroll/rescan, and clears the selection if the widget is no longer in the tree. Add a test: select a highlight → scroll → call `refreshHighlights()` → assert `selectedHighlightNotifier.value.rect` matches the new position.

**Files:** `lib/src/ui/highlight_overlay.dart`, `lib/src/ui/watchdog_overlay.dart` (type change is transparent), `lib/src/controller/watchdog_controller.dart` (change notifier type, add generation counter, update all `.value` reads to `.value.items`, rebind selected highlight), tests.

**Risk:** Low. The overlay is diagnostic UI — visual fidelity matters less than in app UI. The clip-based approach produces the same visual result without `saveLayer`. The generation counter adds 1 int field — negligible. The selection rebind adds one linear scan of highlights (typically <20 items) per refresh — negligible.

---

### v9.15: Silent Exception Swallowing

**Effort:** Very Low | **Theme:** Correctness | **Impact:** Makes tree-walk failures diagnosable

**Problem:** Two locations in `WatchdogController` silently swallow exceptions:

**Line 731:**

```dart
try {
  root.visitChildElements(visitor);
} catch (_) {}
```

**Line 1018:**

```dart
try {
  scanContext.visitChildElements(visitor);
  walkCompleted = true;
} catch (_) {}
```

Both wrap `visitChildElements` — if the tree walk throws (concurrent modification, deactivated element, etc.), the exception is silently discarded. This makes failures invisible during development and debugging.

**Fix:** Log in debug mode, keep the catch for production safety:

```dart
try {
  root.visitChildElements(visitor);
} catch (e, s) {
  assert(() {
    debugPrint('Widget Watchdog: tree walk failed: $e\n$s');
    return true;
  }());
}
```

The `assert(() { ... return true; }())` pattern ensures the log is compiled out in profile/release mode (zero overhead), while making failures visible during development.

**Files:** `lib/src/controller/watchdog_controller.dart` (2 locations), no tests needed.

**Risk:** None. Catch behavior unchanged. Only adds debug-mode logging.

---

### v9.16: Mounted Check for ModalRoute.of

**Effort:** Very Low | **Theme:** Correctness | **Impact:** Prevents potential crash on detached context

**Problem:** `_currentRouteName()` (watchdog_controller.dart:1429-1433) calls `ModalRoute.of(ctx)` without checking if `ctx` is still mounted:

```dart
String? _currentRouteName() {
  if (_scaffoldFreeRouteName != null) return _scaffoldFreeRouteName;
  final ctx = _lastScanContext;
  if (ctx == null) return null;
  return ModalRoute.of(ctx)?.settings.name;
}
```

`_lastScanContext` stores a `BuildContext` from the last scan. Between scans, the context may become detached (widget disposed, page navigated away). Calling `ModalRoute.of()` on a detached context walks an invalid ancestor chain.

**Fix:**

```dart
String? _currentRouteName() {
  if (_scaffoldFreeRouteName != null) return _scaffoldFreeRouteName;
  final ctx = _lastScanContext;
  if (ctx == null || !(ctx as Element).mounted) return null;
  return ModalRoute.of(ctx)?.settings.name;
}
```

**Files:** `lib/src/controller/watchdog_controller.dart` (1 line), no tests needed.

**Risk:** None. Strictly additive guard. Returns null instead of risking an invalid ancestor walk.

---

### v9.17: Source Location Cache — Docstring Accuracy

**Effort:** Very Low | **Theme:** Correctness | **Impact:** Documentation honesty

**Problem:** `SourceLocationCache` (source_location_cache.dart:3-11) docstring says "bounded LRU cache" but the implementation is not LRU:

```dart
/// Bounded cache of widget type → abbreviated "file:line" source locations.
```

At line 31:

```dart
if (_cache.length >= maxEntries) return null;
```

When the cache reaches `maxEntries` (default 200), new widget types get `null` — no eviction occurs. This is a "first-N" or "bounded" cache, not LRU. There is no access-order tracking or eviction of least-recently-used entries.

**Fix — two options:**

**Option A (preferred): Correct the docstring.** The current behavior is actually reasonable — source locations are stable per widget type (a widget defined at `lib/foo.dart:42` doesn't move), so eviction is unnecessary. The first 200 types seen are the most common. Just fix the documentation:

```dart
/// Bounded first-N cache of widget type → abbreviated "file:line" source
/// locations. When full ([maxEntries] reached), new types return null
/// without eviction — existing lookups remain valid. Source locations are
/// stable per widget type, so eviction is unnecessary in practice.
```

**Option B: Implement actual LRU.** Use `LinkedHashMap` with access-order iteration and evict oldest on insert. Only worthwhile if apps routinely exceed 200 widget types and need fresh locations for all of them.

**Files:** `lib/src/utils/source_location_cache.dart` (docstring update), no tests.

**Risk:** None for Option A (documentation only). Low for Option B (well-understood data structure).

---

### v9 Implementation Order

| Priority | Milestone | Effort | Theme | Status |
|----------|-----------|--------|-------|--------|
| 1 | v9.1: Opacity Value Semantics (3 detectors) | Medium | Accuracy | Shipped |
| 2 | v9.2: Paint Phase Thread Classification | Very Low | Accuracy | Shipped |
| 3 | v9.3: builtOnce Parameter Ignored | Very Low | Accuracy | Shipped |
| 4 | v9.4: Layout Bottleneck O(N²) Overclaim | Low | Accuracy | Shipped |
| 5 | v9.5: CustomPainter foregroundPainter | Very Low | Accuracy | Shipped |
| 6 | v9.6: Per-Scrollable Count Accumulation | Medium | Accuracy | Shipped |
| 7 | v9.7: Image Detector Size Threshold | Low | Accuracy | Shipped |
| 8 | v9.8: Timeline Parser Over-Broad Names | Low | Accuracy | |
| 9 | v9.9: runtimeType.toString() Reduction | Medium | Performance | |
| 10 | v9.10: FrameStatsBuffer Hot-Path Allocations | Medium | Performance | |
| 11 | v9.11: Inner Subtree Walks (4 detectors) | Medium | Performance | |
| 12 | v9.12: _aggregateIssues Allocation Storm | Low | Performance | |
| 13 | v9.13: List.removeAt(0) → Queue | Low | Performance | |
| 14 | v9.14: Highlight Overlay Self-Overhead | Medium | Performance | |
| 15 | v9.15: Silent Exception Swallowing | Very Low | Correctness | Shipped |
| 16 | v9.16: Mounted Check for ModalRoute.of | Very Low | Correctness | Shipped |
| 17 | v9.17: Source Location Cache Docstring | Very Low | Correctness | Shipped (already correct) |
