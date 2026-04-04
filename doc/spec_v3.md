## v3 Roadmap: Precision & Developer Experience

### Goal

Make Widget Watchdog's detections **more accurate** and its overlay **more actionable**. v1 built the framework, v2 closed the DevTools gap. v3 focuses on two themes:

1. **Detection precision** — reduce false positives, eliminate false negatives, leverage unused Flutter/VM APIs
2. **Developer experience** — make the path from "I see an issue" to "I know what to fix in my code" as short as possible

### Design Principles

1. **Every detection must earn its place.** A false positive trains developers to ignore the tool. Each detector improvement in v3 must either reduce false positives or increase attribution specificity — never trade one for the other.
2. **Context-aware, not generic.** Fix hints must reference the specific widget, route, and interaction state. "Use const constructors" is a textbook answer; "MyListItem rebuilds 25×/sec — extract its children as const StatelessWidgets" is actionable.
3. **Show, don't tell.** When the overlay says something is wrong, the developer should be able to tap through to understand *why* and *where* — with visual highlighting, ancestor chains, and confidence explanations.

### Scope

| Feature | Category | Effort | Priority |
|---------|:---:|:---:|:---:|
| v3.1 Detection accuracy fixes (7 items) | Accuracy | Small | #1 |
| v3.2 Context-aware fix hints | DX | Medium | #2 |
| v3.3 Issue-to-verdict linking | DX | Small | #3 |
| v3.4 Native memory tracking | New capability | Medium | #4 |
| v3.5 Allocation-rate detection | New capability | Medium | #5 |
| v3.6 Raster cache trend analysis | New capability | Medium | #6 |
| v3.7 CPU attribution call chains | Accuracy | Medium | #7 |
| v3.8 Overlay UX improvements (6 items) | DX | Medium | #8 |
| v3.9 FrameEventCorrelator optimization | Performance | Small | #9 |
| v3.10 Inter-detector correlation | Accuracy | Large | #10 |

---

### v3.1: Detection Accuracy Fixes

**Problem:** Seven specific detector behaviors produce false positives or use incorrect test logic. These are the highest-ROI fixes because they improve trust with zero new features.

#### 3.1.1 AnimatedBuilder threshold too aggressive

**Current:** `animated_builder_detector.dart` fires at `subtreeSize > 5`.
**Problem:** Normal animations with 6+ children trigger warnings. A simple fade transition with a card containing an image, text, and button (subtreeSize ~8) will fire.
**Fix:** Raise threshold to 20. Additionally, require corroboration from RepaintDetector (paint rate > 30/sec on the same widget type) before escalating confidence beyond `possible`.
**Acceptance criteria:** AnimatedBuilder with subtreeSize 15 and no elevated paint rate → no issue. AnimatedBuilder with subtreeSize 25 + paint rate 40/sec → `likely` confidence.

#### 3.1.2 CustomPainter `shouldRepaint` test is incorrect

**Current:** `custom_painter_detector.dart:57` calls `shouldRepaint(painter)` passing the *same* painter instance as both current and old.
**Problem:** This tests self-equality, not the actual `shouldRepaint` comparison logic. A painter that correctly compares fields will still return `true` when compared to itself if any mutable field changed since construction.
**Fix:** Create a second instance of the same runtime type (if possible via `debugCreator` or reflection) and test `shouldRepaint(secondInstance)`. If a second instance cannot be created, fall back to checking whether the painter class overrides `shouldRepaint` at all (structural heuristic).
**Acceptance criteria:** CustomPainter that returns `old.color != color` in `shouldRepaint` → no false positive when color hasn't changed. CustomPainter that returns `true` unconditionally → flagged.

#### 3.1.3 MemoryPressure fires on app startup

**Current:** `memory_pressure_detector.dart` begins evaluation immediately. Initial Dart heap allocation (class loading, widget tree construction, image decoding) produces a legitimate steep growth slope that triggers "Heap Growing" within the first 5 seconds.
**Fix:** Add a warmup exclusion period (5 seconds after first `processHeapSample` call). During warmup, samples are collected for the rolling window but `_evaluate()` returns early without producing issues.
**Acceptance criteria:** App that allocates 50MB in first 3 seconds then stabilizes → no heap growth alert during warmup. App that allocates 50MB continuously for 15 seconds → alert fires after warmup period ends.
**Config:** `memoryWarmupDurationMs` (default 5000), added to `WatchdogConfig`.

#### 3.1.4 NestedScroll false positive on cross-axis nesting

**Current:** `nested_scroll_detector.dart` flags all `Scrollable inside Scrollable` regardless of axis.
**Problem:** Horizontal ListView inside vertical SingleChildScrollView is a standard, intentional pattern. The detector fires a warning for this common layout.
**Fix:** Check scroll axis on both parent and child Scrollable. Same-axis nesting → flag. Cross-axis nesting → suppress unless `NeverScrollableScrollPhysics` is NOT applied (indicating both axes are live-scrollable, which causes gesture conflicts).
**Acceptance criteria:** Horizontal ListView inside vertical ScrollView → no issue. Vertical ListView inside vertical ScrollView (no NeverScrollableScrollPhysics) → issue.

#### 3.1.5 Opacity threshold too strict

**Current:** `opacity_detector.dart` only flags `opacity == 0.0`.
**Problem:** `opacity: 0.001` is visually invisible but still pays the full `saveLayer` cost. Developers using very-near-zero opacity for fade-out animations that didn't complete will miss this.
**Fix:** Flag `opacity < 0.01` (visually invisible). Adjust detail text: "Opacity is near-zero (${opacity.toStringAsFixed(3)}) — widget is invisible but still participates in layout, hit testing, and semantics."
**Acceptance criteria:** `Opacity(opacity: 0.005)` → flagged. `Opacity(opacity: 0.5)` → not flagged.

#### 3.1.6 GpuPressure clears structural issues on VM disconnect

**Current:** `gpu_pressure_detector.dart:42` clears ALL issues when VM disconnects.
**Problem:** Expensive render nodes (ClipPath, BackdropFilter, deep Opacity trees) found during tree scan are valid structural findings. They should persist even without VM timing data — just at lower confidence.
**Fix:** On VM disconnect, keep structural-only issues (those from `scanTree`) but downgrade confidence to `possible`. Clear only the VM-backed issues (raster ratio measurements).
**Acceptance criteria:** VM connected: "Raster dominance (1.8×) with ClipPath at depth 6" → confidence `likely`. VM disconnects: issue persists as "Expensive render node: ClipPath at depth 6" → confidence `possible`.

#### 3.1.7 PlatformChannel lacks per-call context

**Current:** `platform_channel_detector.dart` counts calls per second but doesn't measure per-call duration or identify which method channels are involved.
**Problem:** 25 fast async calls (< 1ms each) are harmless but trigger the warning. 3 blocking synchronous calls (50ms each) cause real jank but might not hit the frequency threshold.
**Fix:** Extract method name from timeline event args (`'method'` or `'interface'` key). Track both frequency AND cumulative duration per second. Flag if either: (a) frequency > threshold, or (b) cumulative duration > half the frame budget.
**Acceptance criteria:** 25 calls × 0.5ms = 12.5ms total → frequency warning only (at threshold). 3 calls × 50ms = 150ms total → duration critical even though frequency is low.
**Config:** `platformChannelDurationThresholdMs` (default 8, half of 16ms frame budget).

#### Testing plan

Each fix requires:
- Unit test proving the false positive no longer fires
- Unit test proving the true positive still fires
- Existing tests updated if threshold values change

Estimated: ~20 new tests.

---

### v3.2: Context-Aware Fix Hints

**Problem:** Fix hints are currently static strings baked into each detector at detection time. They read like textbook advice ("Use const constructors, extract child widgets") regardless of what the detector actually found. When `widgetName`, `ancestorChain`, and `interactionContext` are available, they are shown in the issue card but NOT referenced in the fix hint.

**Approach:** Introduce a `FixHintBuilder` utility that detectors call instead of hardcoding strings. The builder receives the detection context (`widgetName`, `ancestorChain`, `interactionContext`, `observationSource`) and generates a hint that references the specific widget and situation.

**Design decisions:**

1. **Builder, not template.** A simple template engine (`"Replace {widget} with..."`) is too rigid. Different detectors need different hint structures. A builder function per detector type allows full control while centralizing the context-injection pattern.

2. **Effort indicators.** Each hint includes a rough effort estimate: `Quick` (< 5 min, e.g., add `const`), `Medium` (< 30 min, e.g., extract widgets), `Involved` (> 30 min, e.g., refactor layout hierarchy). These are human-written per detector, not computed.

3. **Fallback to current behavior.** If no widget context is available (e.g., purely structural detection without `widgetName`), the builder returns the current generic hint. No regression.

**Examples:**

| Detector | Current hint | Context-aware hint |
|----------|-------------|-------------------|
| Rebuild | "Use const constructors, extract child widgets..." | "MyListItem rebuilds 25×/sec during scrolling. Quick: check if MyListItem's children use const constructors. Medium: extract the subtitle and trailing widgets into separate StatelessWidgets." |
| ImageMemory | "Add cacheWidth/cacheHeight to Image widgets..." | "3 uncached images in ProductCard (via Scaffold > ListView > ProductCard). Quick: add `cacheWidth: 200` to each Image widget in ProductCard." |
| LayoutBottleneck | "Replace IntrinsicHeight with fixed sizes..." | "IntrinsicHeight found in CartItem ancestor chain. Medium: measure CartItem's actual height and replace IntrinsicHeight with SizedBox(height: N)." |

**Files changed:**
- New: `lib/src/utils/fix_hint_builder.dart`
- Modified: All 21 detector files (replace hardcoded strings with builder calls)
- Modified: `lib/src/models/performance_issue.dart` (no model changes needed — `fixHint` remains a String)

**Acceptance criteria:**
- When `widgetName` is available, fix hint contains the widget name
- When `ancestorChain` is available, fix hint references the location
- When `interactionContext` is `scrolling`, scroll-specific advice is included
- Effort indicator present on every hint
- All existing fix hint tests updated

**Testing:** ~21 tests (one per detector verifying context-aware output).

---

### v3.3: Issue-to-Verdict Linking

**Problem:** The Live tab shows "Sustained Jank: 4 severe frames (22% janky)" but doesn't connect to the Issues tab. The developer must manually switch tabs and correlate. `FrameVerdict.relatedIssues` already contains the linked issues, but the UI doesn't expose this connection.

**Approach:**

1. **Jank banner on Live tab.** When the latest verdict indicates jank AND `relatedIssues.isNotEmpty`, show a tappable banner below the chart: "3 issues may be causing jank → View Issues". Tapping switches to the Issues tab.

2. **Issue highlighting from verdict.** When a verdict is tapped in the Live tab's detail area, temporarily highlight the related issues in the Issues tab (border pulse or background flash for 2 seconds).

3. **Verdict badge on issue cards.** Issues that appear in the current verdict's `relatedIssues` get a small "Jank" badge in collapsed view, indicating they are correlated with active frame drops — not just structural findings.

**Files changed:**
- `lib/src/ui/dashboard_sheet.dart` — jank banner widget, tab switching logic
- `lib/src/ui/issue_card.dart` — optional "Jank" badge

**Acceptance criteria:**
- Jank frame with 2 related issues → banner shows "2 issues may be causing jank"
- Tapping banner switches to Issues tab
- Non-jank verdict → no banner
- Related issues display "Jank" badge in collapsed card view

**Testing:** 4 widget tests (banner visibility, tap behavior, badge rendering, no-jank state).

---

### v3.4: Native Memory Tracking

**Problem:** Widget Watchdog monitors only the Dart heap via `getMemoryUsage()`. Native memory (GPU textures, platform channel buffers, Impeller resources, decoded images before Dart wrapping) is invisible. A developer can have a stable Dart heap but a growing RSS that eventually triggers OOM.

**Approach:** Use `ProcessInfo.currentRss` (from `dart:io`) alongside existing heap polling to track process-level resident memory. The gap between RSS and Dart heap usage reveals native memory consumption.

**Design decisions:**

1. **Piggybacked on heap poll.** Read `ProcessInfo.currentRss` in the same `_pollTimeline` cycle that calls `getMemoryUsage()`. No additional timer or polling loop.

2. **New fields on HeapSample.** Add `rssBytes` and computed `nativeBytes` (rss − heapUsage) to `HeapSample`. Backward-compatible: both nullable, serialized only when present.

3. **New issue type: native memory growth.** If `nativeBytes` grows > 1MB/sec sustained over 10 seconds, emit a warning: "Native memory growing: +N MB in 10s. Check for undisposed textures, platform channel buffers, or large decoded images."

4. **Platform guard.** `ProcessInfo.currentRss` is not available on web. Guard with try/catch; if unavailable, `rssBytes` stays null and native tracking is silently disabled.

**Files changed:**
- `lib/src/models/heap_sample.dart` — add `rssBytes: int?`, `nativeBytes: int?`
- `lib/src/vm/vm_service_client.dart` — read `ProcessInfo.currentRss` in heap poll
- `lib/src/detectors/memory_pressure_detector.dart` — add native growth evaluation
- `lib/src/models/session_snapshot.dart` — serialize new fields in export

**Acceptance criteria:**
- `HeapSample` includes `rssBytes` when `ProcessInfo` available
- Native memory growth > 1MB/sec for 10s → warning issue
- `ProcessInfo` unavailable (web) → graceful fallback, no crash
- Existing heap trend tests unaffected

**Performance budget:** `ProcessInfo.currentRss` is a synchronous syscall. Measured at < 50μs on Android/iOS. No frame budget impact at 2Hz polling.

**Testing:** 8 tests (HeapSample serialization with rss, native growth detection, threshold boundary, platform fallback, no regression on existing heap tests).

---

### v3.5: Allocation-Rate Detection

**Problem:** The memory pressure detector knows *that* the heap is growing but not *what* is allocating. Developers get "Heap Growing: +2MB/sec" but have no idea which classes or widgets are responsible.

**Approach:** Use `VmService.getAllocationProfile(isolateId, reset: true)` to get per-class allocation deltas between scan intervals. Surface the top-5 allocating classes when memory pressure is detected.

**Design decisions:**

1. **On-demand, not continuous.** Only call `getAllocationProfile` when the memory pressure detector has already flagged growth. This avoids overhead during normal operation.

2. **Delta-based.** Call with `reset: true` to get allocation counts since the last call. The first call establishes a baseline; subsequent calls show deltas.

3. **Enrichment model (like CPU attribution).** Add `topAllocators: List<AllocationEntry>?` to the memory pressure issue (via a new `AllocationEntry` data class: `className`, `instancesDelta`, `bytesDelta`, `percentage`). Two-phase emission: phase 1 emits the heap growth issue immediately, phase 2 re-emits with `topAllocators` when `getAllocationProfile` returns.

4. **Framework filtering.** Exclude Dart SDK internal classes (`_List`, `_GrowableList`, `_InternalLinkedHashMap`, etc.) unless they dominate > 50% of allocations. Show user-authored classes preferentially.

**Files changed:**
- New: `lib/src/models/allocation_entry.dart`
- `lib/src/vm/vm_service_client.dart` — add `getAllocationProfile()` method with timeout
- `lib/src/detectors/memory_pressure_detector.dart` — two-phase enrichment for heap growth issues
- `lib/src/controller/watchdog_controller.dart` — wire allocation profile query on heap growth detection
- `lib/widget_watchdog.dart` — export `AllocationEntry`

**Acceptance criteria:**
- Heap growth detected → `getAllocationProfile` called
- Top 5 non-framework classes shown with instance count and byte delta
- Phase 1 issue emitted immediately (no topAllocators)
- Phase 2 issue re-emitted with topAllocators within 500ms
- No allocation profile call when heap is stable
- VM disconnected → graceful null (phase 1 stands)

**Performance budget:** `getAllocationProfile` is a medium-weight RPC (~5-20ms). Called only when heap growth is already flagged (~1-2 calls per incident). Negligible impact.

**Testing:** 10 tests (mock getAllocationProfile, framework filtering, two-phase emission, null VM, empty profile, delta calculation, serialization roundtrip).

---

### v3.6: Raster Cache Trend Analysis

**Problem:** `FrameTiming` provides `layerCacheCount`, `layerCacheBytes`, `pictureCacheCount`, and `pictureCacheBytes` per frame, but Widget Watchdog only uses `layerCacheCount` and `pictureCacheBytes` for display. Cache thrashing (rapid allocate/evict cycles) and unbounded cache growth are invisible.

**Approach:** Track cache metrics across a rolling window of frames. Detect two patterns:
1. **Cache thrashing:** `pictureCacheCount` fluctuates by > 20% between consecutive frames for 10+ consecutive frames. Indicates the cache is too small or content is not reusable.
2. **Cache growth:** `pictureCacheBytes + layerCacheBytes` grows monotonically for 30+ frames. Indicates unbounded cache accumulation (leak).

**Design decisions:**

1. **Enhance FrameTimingDetector.** This is a natural extension of the existing detector — it already processes every `FrameStats`. Add cache trend tracking to the existing `addFrame()` method.

2. **Impeller awareness.** Under Impeller (Flutter 3.27+ default on iOS/Android API 29+), raster cache semantics change. Cache counts may be zero or report differently. If all cache metrics are zero for 30+ consecutive frames, suppress cache analysis and add a note: "Raster cache metrics unavailable (Impeller renderer)."

3. **New issue types:** `IssueCategory.raster` with titles "Raster Cache Thrashing" and "Raster Cache Growing".

**Files changed:**
- `lib/src/detectors/frame_timing_detector.dart` — add cache trend tracking
- `lib/src/models/frame_stats.dart` — add `pictureCacheCount` field (currently missing)

**Acceptance criteria:**
- 15 consecutive frames with > 20% pictureCacheCount variation → "Raster Cache Thrashing" warning
- 30 consecutive frames with monotonic cache byte growth → "Raster Cache Growing" warning
- All-zero cache metrics for 30 frames → suppress analysis, no false positive
- Impeller note shown when metrics unavailable

**Testing:** 6 tests (thrashing detection, growth detection, Impeller suppression, threshold boundaries, mixed stable/thrashing patterns).

---

### v3.7: CPU Attribution Call Chains

**Problem:** Current CPU attribution returns top-N functions by exclusive ticks (function at stack[0] only). A result like "layout() 42%" doesn't tell the developer *which of their widgets* triggered the expensive layout. The developer must still open DevTools to trace the call chain.

**Approach:** Extend `CpuSampleAggregator` to return call chains instead of flat function names. For each top function, include the caller chain up to the first user-authored frame.

**Design decisions:**

1. **Inclusive + exclusive.** Return both exclusive ticks (function was executing) and inclusive ticks (function was in the call stack). Show "MyBuild.build → RenderFlex.performLayout → layout: 42% (28% exclusive)".

2. **User-frame root.** Walk the stack from top (index 0) upward until hitting a function whose library doesn't start with `dart:` or `package:flutter/`. That's the "user root" — the developer's code that triggered the framework work.

3. **Max chain depth: 5.** Truncate chains longer than 5 frames with "..." to avoid overwhelming the UI.

4. **Model change.** `CpuAttribution` gains `callChain: List<String>?` (nullable for backward compatibility) and `inclusivePercentage: double?`. UI shows the chain when available.

**Files changed:**
- `lib/src/vm/cpu_sample_aggregator.dart` — inclusive tick counting, call chain extraction
- `lib/src/models/cpu_attribution.dart` — add `callChain` and `inclusivePercentage` fields
- `lib/src/ui/dashboard_sheet.dart` — render call chains in verdict detail

**Acceptance criteria:**
- CPU sample with stack `[layout, performLayout, build, MyWidget.build]` → chain: `MyWidget.build → performLayout → layout`
- Inclusive percentage ≥ exclusive percentage for all functions
- Framework-only stacks (no user code) → chain is framework root with note "(framework)"
- Empty samples → null chain (backward compatible)

**Testing:** 8 tests (chain extraction, user-root detection, framework-only stack, truncation at depth 5, inclusive vs exclusive, serialization roundtrip).

---

### v3.8: Overlay UX Improvements

Six targeted improvements to the overlay UI. Each is small individually but together they transform the developer's diagnostic workflow.

#### 3.8.1 Widget name before ancestor chain

**Current:** `issue_card.dart:197-211` — when `ancestorChain` is present, `widgetName` is skipped.
**Fix:** Always show `widgetName` first (it's the signal), then `ancestorChain` as drill-down context. Never skip one for the other.

#### 3.8.2 Highlight not-found feedback

**Current:** When a developer taps a highlight checkbox but the widget is off-screen or not in the tree, nothing happens.
**Fix:** Show a SnackBar: "Widget not currently visible. Navigate to the screen where this issue occurs."

#### 3.8.3 Interaction context filter

**Current:** `interactionContext` is displayed but not filterable.
**Fix:** Add a filter row at the top of the Issues tab: `All | Idle | Scrolling | Navigating`. Default: All. Deprioritize scrolling-time issues slightly in ranking (multiply recurrence score by 0.7 for scrolling context).

#### 3.8.4 "About this detection" expandable section

**Current:** Source and confidence badges are shown but not explained.
**Fix:** Add a collapsible "About this detection" row in expanded issue view. Content:
- "Based on: {source description}"
- "Confidence: {confidence} — {explanation}"
- "Accuracy note: {mode-specific caveat}"
- "Verify with: {DevTools recommendation}"

#### 3.8.5 Effort indicators on fix hints

**Current:** Fix hints are plain text.
**Fix:** Prefix each hint with an effort badge. Format: "Quick: ..." / "Medium: ..." / "Involved: ...". Effort is determined per-detector, not computed.

#### 3.8.6 Color legend in Guide tab

**Current:** Green can mean "confirmed confidence", "VM source", or "no issues" depending on context.
**Fix:** Add a "Color Legend" section to the Guide tab explaining all color codings: severity colors, confidence badges, source badges, and mode indicators.

**Files changed:**
- `lib/src/ui/issue_card.dart` — items 3.8.1, 3.8.2, 3.8.4, 3.8.5
- `lib/src/ui/dashboard_sheet.dart` — items 3.8.3, 3.8.6
- `lib/src/ranking/issue_ranker.dart` — item 3.8.3 (scrolling deprioritization)

**Testing:** 10 widget tests (widget name ordering, snackbar visibility, filter states, about section content, effort badge rendering, legend content).

---

### v3.9: FrameEventCorrelator Optimization

**Problem:** `frame_event_correlator.dart:77-93` performs a linear scan of all eligible frames for each timeline event. With 100+ buffered frames and 50+ events per batch, this is O(n×m) and will degrade at high frame rates or long sessions.

**Approach:** Pre-sort frames by `buildStartUs`. For each event, binary search for the matching frame window instead of linear scan.

**Design decisions:**

1. **Sorted frame index.** Build a sorted list of `(buildStartUs, rasterFinishUs, frameIndex)` tuples once per correlation call. Binary search on `buildStartUs` to find candidate frames, then check `rasterFinishUs` bound.

2. **Cross-frame event splitting.** If an event's duration spans two frame boundaries, assign proportionally (by time overlap) to each frame. Currently assigned to first frame only.

**Files changed:**
- `lib/src/analyzer/frame_event_correlator.dart`

**Acceptance criteria:**
- Correlation results identical to current implementation (no regression)
- O(n log n) instead of O(n²) verified by benchmark
- Cross-frame events split proportionally

**Performance budget:** Current cost at 100 frames × 50 events ≈ 5000 comparisons. After optimization: ~350 comparisons (100 × log₂(50)).

**Testing:** 5 tests (correctness parity, cross-frame split, edge cases at frame boundaries, empty input, single frame).

---

### v3.10: Inter-Detector Correlation

**Problem:** Detectors fire independently. A developer might see "Excessive Rebuilds", "High Paint Frequency", and "GPU Raster Dominance" as three separate issues when they share a single root cause (a wide setState). Worse, some detectors produce false positives that another detector's data could suppress.

**Approach:** Add a `DetectorCorrelator` post-processing step that runs after all detectors have produced issues. It merges, suppresses, or escalates issues based on cross-detector evidence.

**Design decisions:**

1. **Post-processing, not coupling.** Detectors remain independent. `DetectorCorrelator` reads the combined issue list and adjusts it. This preserves testability and avoids circular dependencies between detectors.

2. **Correlation rules (initial set):**

| Rule | Condition | Action |
|------|-----------|--------|
| Rebuild + SetStateScope → merge | Same `widgetName` on both issues | Merge into single "Wide setState in {widget}" issue with combined evidence. Confidence: `likely`. |
| GPU Pressure + CustomPainter → escalate | GPU raster ratio > 1.5× AND CustomPainter shouldRepaint=true | Escalate CustomPainter from `possible` → `likely`. Add cross-reference in detail. |
| Memory Pressure + ImageMemory → escalate | Heap growing AND uncached images > 3 | Escalate ImageMemory from `possible` → `likely`. Add "contributing to heap growth" to detail. |
| AnimatedBuilder + RepaintDetector → suppress | AnimatedBuilder flagged but RepaintDetector has no elevated paint rate for that widget type | Suppress AnimatedBuilder issue (false positive). |
| Rebuild + RepaintDetector → deduplicate | Same widget flagged by both with overlapping evidence | Keep higher-confidence issue, suppress the other. |

3. **Extensible.** Rules are data-driven (list of `CorrelationRule` objects), not hardcoded control flow. New rules can be added without modifying the correlator engine.

**Files changed:**
- New: `lib/src/analyzer/detector_correlator.dart`
- `lib/src/controller/watchdog_controller.dart` — call correlator after `_aggregateIssues()`

**Acceptance criteria:**
- Rebuild + SetStateScope on same widget → single merged issue
- AnimatedBuilder without paint pressure → suppressed
- GPU + CustomPainter → CustomPainter escalated to `likely`
- Rules applied after all detectors run, before UI rendering
- No circular dependencies between detectors

**Testing:** 12 tests (one per rule + edge cases: no matches, all rules fire, empty issue list, single issue).

---

### v3 Implementation Order

Recommended: v3.1 → v3.9 → v3.3 → v3.8 → v3.2 → v3.4 → v3.7 → v3.6 → v3.5 → v3.10

Rationale:
- **v3.1 first** — accuracy fixes are the highest-ROI, lowest-risk changes. They make the tool more trustworthy immediately.
- **v3.9 early** — performance fix prevents degradation as other features add load.
- **v3.3 + v3.8 before v3.2** — UI quick wins improve DX before the larger fix-hint overhaul.
- **v3.4/v3.7/v3.6/v3.5** — new capabilities can be shipped incrementally.
- **v3.10 last** — inter-detector correlation depends on stable detector behavior from v3.1.

### v3 Version Plan

| Version | Features | Breaking? |
|---------|----------|:---------:|
| 0.4.0 | v3.1 accuracy fixes, v3.9 correlator optimization | No |
| 0.5.0 | v3.3 verdict linking, v3.8 UX improvements, v3.2 context-aware hints | No |
| 0.6.0 | v3.4 native memory, v3.6 raster cache, v3.7 call chains | No (new nullable fields) |
| 0.7.0 | v3.5 allocation-rate detection, v3.10 inter-detector correlation | No |

All v3 features add nullable fields or new classes — zero breaking changes to the existing public API.

### Deferred from v3 (Future Candidates)

These items were evaluated during the v3 research phase but deferred due to high effort, low immediate ROI, or dependency on external tooling:

| Item | Why deferred | Revisit when |
|------|-------------|-------------|
| Memory leak detection via `getRetainingPath` | High effort (~7 days). Requires WeakReference tracking, object ID management, and complex UI for retention path display. | User demand for object-level leak detection beyond heap trends. |
| Rebuild-to-frame correlation ("widget X caused jank frame Y") | Requires combining `debugOnRebuildDirtyWidget` timestamps with `FrameEventCorrelator` per-frame windows. High complexity, moderate UI payoff. | After v3.7 (call chains) is shipped and validated. |
| Custom service extensions (`ext.widgetWatchdog.*`) | Useful for CI integration but no current users requesting it. | When CI/CD performance regression testing is a stated goal. |
| GC mode recommendations (`requestPerformanceMode`) | `DartPerformanceMode` is useful but auto-switching could cause unexpected behavior. | After gathering real-world data on GC pressure patterns from v3.4/v3.5. |
| Hot reload detection + detector state reset | Timeline `HotReload` events could trigger detector reset, preventing stale state. Low priority — stale state resolves within one scan cycle. | If users report false positives after hot reload. |
| `UserTag` for overhead isolation | Tag Widget Watchdog's own code to filter from CPU samples. Low impact — package overhead is < 1% in profile mode. | If self-overhead ever becomes measurable in CPU attribution. |

---

