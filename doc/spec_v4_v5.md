## v4 Roadmap: Extensibility & Developer Experience

This roadmap focuses on making Sleuth customizable for teams with domain-specific needs, reducing UI file complexity, and improving developer workflow.

### v4.1: Issue Suppression List

**Problem:** Issues reappear every scan cycle. Developers who intentionally use patterns that trigger detectors (e.g., `Opacity(0)` for animations, a non-lazy ListView with exactly 25 items) cannot dismiss issues persistently. The only option is to disable the entire detector via `enabledDetectors`, which is too coarse — it silences *all* instances of that detector type, not just the known-intentional ones.

**Current suppression mechanisms:**
- **Detector-level:** `enabledDetectors` disables entire detector types (too coarse)
- **Correlator-level:** 5 evidence-based rules suppress/merge cross-detector (automatic, not user-controlled)
- **UI-level:** None — no dismiss, suppress, or ignore controls exist

**Approach:** Add `suppressedIssues: Set<String>` to `SleuthConfig`. Filter by `stableId` (or `title` fallback) in `_aggregateIssues()` after correlation but before ranking. This is the minimal insertion point — one `where` clause.

**Design decisions:**

1. **Filter point: post-correlate, pre-rank.** Suppression happens in `_aggregateIssues()` (line ~1081) after `DetectorCorrelator.correlate()` but before `IssueRanker.rank()`. This ensures:
   - Correlation rules still see suppressed issues (a suppressed rebuild issue can still merge with a setState issue)
   - Suppressed issues don't appear in the ranked list or UI
   - Ranking context (`jankActive`, `recurrenceCounts`) excludes suppressed issues

2. **Match on `stableId ?? title`.** This is already the canonical identifier pattern used by `IssueRanker` (line 64), `_updateRecurrence()` (line 1139), and `FloatingIssuesCard` (line 102). Using the same pattern means the config strings match what's displayed in the UI.

3. **Prefix matching with `*` suffix.** Support `'rebuild_debug_*'` to suppress all per-widget rebuild issues. Simple `startsWith` check — no regex. Exact match first, then prefix check if no exact match found.

4. **No runtime UI for adding suppressions.** Config-only (compile-time). Reasoning: this is a developer tool, and suppression decisions should be explicit in code (reviewable in PRs), not hidden in runtime state. A future version could add a "Copy stableId" button to issue cards for convenience.

5. **Suppressed count shown in UI.** The floating card footer shows "3 issues suppressed" when suppressions are active, so developers know the list isn't the full picture.

**Implementation:**

```dart
// SleuthConfig addition:
const SleuthConfig({
  // ... existing fields ...
  this.suppressedIssues = const {},
});
final Set<String> suppressedIssues;

// In _aggregateIssues():
final correlated = _detectorCorrelator.correlate(all);
final filtered = config.suppressedIssues.isEmpty
    ? correlated
    : correlated.where((issue) {
        final id = issue.stableId ?? issue.title;
        if (config.suppressedIssues.contains(id)) return false;
        return !config.suppressedIssues.any(
          (pattern) => pattern.endsWith('*') &&
              id.startsWith(pattern.substring(0, pattern.length - 1)),
        );
      }).toList();
final ranked = _ranker.rank(filtered, ...);
```

**Files changed:**
- `lib/src/controller/sleuth_controller.dart` — add `suppressedIssues` to `SleuthConfig`, add filter in `_aggregateIssues()`, track suppressed count
- `lib/src/ui/floating_issues_card.dart` — show "N issues suppressed" in footer when count > 0
- `lib/sleuth.dart` — no change (SleuthConfig already exported)

**Acceptance criteria:**
- `suppressedIssues: {'opacity_zero'}` hides all opacity issues
- `suppressedIssues: {'rebuild_debug_*'}` hides all per-widget rebuild issues
- Suppressed issues still participate in correlation rules (e.g., rebuild + setState merge)
- Unsuppressed issues are unaffected in ranking and display
- Footer shows suppressed count when > 0
- Empty `suppressedIssues` (default) has zero overhead (early return before `.where()`)
- Export snapshot includes suppressed count but not suppressed issues

**stableId reference for documentation:**

| Detector | stableId(s) |
|----------|-------------|
| FrameTiming | `sustained_jank`, `jank_detected` |
| ShaderJank | `shader_compilation` |
| HeavyCompute | `heavy_compute` |
| MemoryPressure | `gc_pressure`, `heap_growing`, `heap_near_capacity`, `native_memory_growing` |
| Rebuild | `rebuild_debug_$TYPE`, `rebuild_activity` |
| Repaint | `repaint_debug_$TYPE`, `excessive_repaint`, `excessive_repaint_debug` |
| GpuPressure | `raster_dominance`, `expensive_gpu_nodes` |
| ShallowRebuildRisk | `shallow_rebuild_risk` |
| SetStateScope | `setstate_scope` |
| LayoutBottleneck | `layout_bottleneck` |
| ListView | `non_lazy_list` |
| ImageMemory | `uncached_images` |
| GlobalKey | (falls back to title) |
| NestedScroll | (falls back to title) |
| CustomPainter | `always_repaint_painter`, `frequent_repaint_painter` |
| KeepAlive | `excessive_keep_alive` |
| AnimatedBuilder | `animated_builder_no_child` |
| Opacity | `opacity_zero` |
| FontLoading | `multiple_custom_fonts` |
| Network | `slow_request`, `large_response`, `request_frequency` |

**Testing:** 8 tests:
1. Empty suppression set — all issues pass through (zero overhead)
2. Exact stableId match — issue filtered
3. Title fallback match — issue without stableId filtered by title
4. Prefix wildcard — `rebuild_debug_*` matches `rebuild_debug_MyWidget`
5. Suppressed issue still participates in correlation (rebuild + setState merge)
6. Ranking context excludes suppressed issues
7. Suppressed count tracked correctly
8. Export snapshot includes suppressed count

**Performance budget:** One `.where()` pass over typically 0–10 issues. Negligible.

**Post-Implementation Notes (v4.1):**

Shipped as planned with minor refinements:

1. **`_matchesSuppression()` helper** extracted as a private method on `SleuthController` for clarity. Iterates `config.suppressedIssues` once per issue — O(P×I) where P = pattern count, I = issue count. Negligible for typical sizes (< 10 patterns, < 20 issues).

2. **`suppressedCountNotifier`** added as a `ValueNotifier<int>` on `SleuthController`. Footer uses a scoped `ValueListenableBuilder<int>` so only the count text rebuilds — no full-footer rebuilds.

3. **`SessionSnapshot.suppressedCount`** field added with conditional JSON serialization (`if > 0`). Backward compatible — old JSON without the field deserializes to 0 via `?? 0` fallback.

4. **Recurrence tracking**: `_updateRecurrence()` runs on the post-suppression list (`issuesNotifier.value`). Suppressed issues don't accumulate recurrence counts. This is correct — recurrence only matters for ranked/displayed issues. If unsuppressed later, the issue starts fresh.

5. **stableId reference table correction**: GlobalKey and NestedScroll detectors DO have stableIds (`excessive_global_keys`, `nested_scroll`, `nested_scroll_same_axis`) — the spec table was inaccurate. Also missing from the table: `raster_cache_thrashing`, `raster_cache_growing`, `platform_channel_traffic`, `stateful_density`, `FrameTiming.raster_cache_*`.

6. **10 tests** (vs. 8 planned): added tests for no-issues-yields-zero and JSON-absent-when-zero edge cases. Test file: `test/controller/suppression_test.dart`.

7. **Total test count**: 1,089 (up from 1,079). 0 analysis issues.

---

### v4.2: Custom Detector Plugin API

**Problem:** The 21 built-in detectors cover common Flutter anti-patterns, but teams have domain-specific performance concerns that the package can't anticipate. Examples:
- "Our video player widget shouldn't rebuild during playback"
- "Any widget tree deeper than 50 levels in our design system is a bug"
- "Our analytics SDK shouldn't make network calls during scroll"

Currently, adding a detector requires modifying `DetectorType` enum, `SleuthController` fields, `_initializeDetectors()`, `_runStructuralScans()`, `_getAllIssues()`, `_collectHighlights()`, and `dispose()` — 7 touch points in library-internal code.

**Approach:** Add `customDetectors: List<BaseDetector>` to `SleuthConfig`. The controller integrates them into existing scan, aggregation, highlight, and disposal lifecycles without requiring enum changes or controller modifications.

**Design decisions:**

1. **No new `DetectorType` enum values.** Custom detectors don't need a `DetectorType` because the enum is only used for `enabledDetectors` filtering — and custom detectors are explicitly opted-in by passing them in config. Custom detectors use `DetectorType` internally for their own identity but are not filtered by `enabledDetectors`.

2. **Use existing `DetectorLifecycle` for routing.** Custom detectors declare their lifecycle (structural, runtime, hybrid, vmOnly) and the controller routes data to them accordingly:
   - `structural` → called in `_runStructuralScans()` via `scanTree(context)`
   - `hybrid` → called in `_runStructuralScans()` + receives `processTimelineData()` + `evaluateNow()`
   - `vmOnly` → receives `processTimelineData()` only
   - `runtime` → self-managed (like FrameTimingDetector)

3. **`BaseDetector` is the plugin interface.** No new abstract class needed. `BaseDetector` already defines every hook a detector needs: `scanTree()`, `issues`, `highlights`, `isEnabled`, `updateDebugSnapshot()`, `evaluateNow()`, `dispose()`. Custom detectors extend `BaseDetector` exactly like built-in ones.

4. **DetectorType gains a `custom` value.** Single new enum value for all custom detectors. Used only for identification in issue metadata — not for config filtering.

5. **Lifecycle routing via list iteration.** The controller maintains `List<BaseDetector> _customDetectors` and iterates them at each lifecycle trigger point. This is O(n) where n is typically 1–3 custom detectors — negligible overhead.

6. **Custom detector issues participate in correlation and ranking.** They flow through the same `_aggregateIssues()` pipeline: correlate → stamp → rank → notify. Custom detectors benefit from the existing ranking system without extra work.

**Implementation sketch:**

```dart
// DetectorType addition:
enum DetectorType {
  // ... existing 21 values ...
  custom,
}

// SleuthConfig addition:
const SleuthConfig({
  // ... existing fields ...
  this.customDetectors = const [],
});
final List<BaseDetector> customDetectors;

// Controller:
late final List<BaseDetector> _customDetectors;

void _initializeDetectors() {
  // ... existing 21 detectors ...
  _customDetectors = config.customDetectors.map((d) {
    d.isEnabled = true;
    return d;
  }).toList();
}

void _runStructuralScans(BuildContext scanContext) {
  // ... existing 15 detector calls ...
  for (final d in _customDetectors) {
    if (d.isEnabled && d.requiresTreeScan) d.scanTree(scanContext);
  }
}

List<PerformanceIssue> _getAllIssues() {
  return [
    // ... existing 21 detector issues ...
    for (final d in _customDetectors) ...d.issues,
  ];
}

void _collectHighlights() {
  highlightsNotifier.value = <WidgetHighlight>[
    // ... existing detector highlights ...
    for (final d in _customDetectors) ...d.highlights,
  ];
}

void _onTimelineData(ParsedTimelineData data) {
  // ... existing detector calls ...
  for (final d in _customDetectors) {
    if (d.lifecycle == DetectorLifecycle.vmOnly ||
        d.lifecycle == DetectorLifecycle.hybrid) {
      d.processTimelineData(data);
    }
  }
  for (final d in _customDetectors) {
    if (d.lifecycle == DetectorLifecycle.hybrid) {
      d.evaluateNow();
    }
  }
}

void dispose() {
  // ... existing detector disposal ...
  for (final d in _customDetectors) {
    d.dispose();
  }
}
```

**But `processTimelineData` is not on `BaseDetector`.** Currently, each detector defines its own `processTimelineData(ParsedTimelineData)` signature. The base class has no such method. Options:
- **Option A:** Add `void processTimelineData(ParsedTimelineData data) {}` to `BaseDetector` as a no-op default. Simple, non-breaking.
- **Option B:** Use `if (d is TimelineAware) d.processTimelineData(data)` mixin check. More principled but more complex.
- **Recommendation:** Option A — matches the existing pattern where `scanTree()`, `updateDebugSnapshot()`, and `evaluateNow()` are all no-op defaults on `BaseDetector`.

**Files changed:**
- `lib/src/models/base_detector.dart` — add `DetectorType.custom`, add `processTimelineData()` no-op default
- `lib/src/controller/sleuth_controller.dart` — add `customDetectors` to config, integrate into all lifecycle points
- `lib/sleuth.dart` — export `BaseDetector` (currently only exports `DetectorType` and `DetectorLifecycle`)
- `README.md` — document custom detector usage with example

**Acceptance criteria:**
- Custom structural detector receives `scanTree()` calls every scan cycle
- Custom hybrid detector receives `scanTree()` + `processTimelineData()` + `evaluateNow()`
- Custom detector issues appear in ranked list alongside built-in issues
- Custom detector highlights appear in overlay
- Custom detector is disposed on controller disposal
- Empty `customDetectors` (default) has zero overhead
- Built-in detector behavior completely unchanged

**Example usage for README:**

```dart
class VideoRebuildDetector extends BaseDetector {
  VideoRebuildDetector() : super(
    type: DetectorType.custom,
    lifecycle: DetectorLifecycle.structural,
    name: 'Video Rebuild',
    description: 'Flags VideoPlayer rebuilds during playback',
  );

  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  @override List<PerformanceIssue> get issues => _issues;
  @override bool get isEnabled => _isEnabled;
  @override set isEnabled(bool v) => _isEnabled = v;

  @override
  void scanTree(BuildContext context) {
    _issues.clear();
    void visitor(Element element) {
      // Domain-specific detection logic
      element.visitChildren(visitor);
    }
    context.visitChildElements(visitor);
  }

  @override void dispose() => _issues.clear();
}

// Usage:
Sleuth.track(
  config: SleuthConfig(
    customDetectors: [VideoRebuildDetector()],
  ),
  child: MyApp(),
);
```

**Testing:** 10 tests:
1. Custom structural detector receives scanTree calls
2. Custom hybrid detector receives scanTree + processTimelineData + evaluateNow
3. Custom vmOnly detector receives processTimelineData only
4. Custom detector issues in aggregated list
5. Custom detector highlights in overlay
6. Custom detector disposed on controller dispose
7. Disabled custom detector skipped
8. Empty customDetectors list — zero overhead
9. Custom detector issues participate in ranking
10. Multiple custom detectors coexist

**Performance budget:** One list iteration per lifecycle trigger per custom detector. Typically 1–3 custom detectors × 1 call/sec = negligible.

**Post-Implementation Notes (v4.2):**

Shipped as planned with minor refinements:

1. **No `_customDetectors` field on controller.** The spec sketched `late final List<BaseDetector> _customDetectors` on the controller, but the implementation reads directly from `config.customDetectors` at each lifecycle point. Since `SleuthConfig` is immutable and `customDetectors` is a `final List`, there's no benefit to copying it. One fewer field, one fewer init step.

2. **`processTimelineData()` added to `BaseDetector` (Option A).** Added as a no-op default matching the existing pattern (`scanTree()`, `evaluateNow()`, `updateDebugSnapshot()`). Required adding `@override` to 8 existing detectors (gpu_pressure, heavy_compute, memory_pressure, platform_channel, rebuild, repaint, shader_jank, shallow_rebuild_risk).

3. **Barrel file exports expanded.** Three new public API exports: `BaseDetector` (added to existing `show` clause), `ParsedTimelineData` (from `timeline_parser.dart`), and `DebugSnapshot` (from `debug_snapshot.dart`). Enables consumers to write custom detectors using only `package:sleuth/sleuth.dart` — no `src/` imports needed.

4. **Disposal ownership documented.** Added one line to the `customDetectors` doc comment: "The controller disposes custom detectors when it is itself disposed." Prevents surprises if consumers hold a separate reference to a detector.

5. **`enabledDetectors` interaction:** Custom detectors bypass the `enabledDetectors` filter entirely — they're always enabled because they were explicitly passed. Disabling is possible via `detector.isEnabled = false` directly.

6. **`isEnabled` guard consistency.** All 7 lifecycle wiring points guard with `d.isEnabled` except `_getAllIssues()` and `_collectHighlights()` — matching the built-in detector pattern where disabled detectors simply produce empty issue/highlight lists.

7. **12 tests** (vs. 10 planned): added `_TestVmOnlyDetector` class for vmOnly lifecycle coverage and a suppression integration test (`test_custom_*` wildcard). Test file: `test/controller/custom_detector_test.dart`.

8. **Total test count**: 1,101 (up from 1,089). 0 analysis issues.

---

**Post-Implementation Notes (v4.4):**

Shipped as planned. Pure refactor — zero behavior change.

1. **Three widgets extracted.** `_StatusRow` (80 lines), `_CardFooter` (46 lines), `_WarningBanners` (95 lines) — all private `StatelessWidget`s in the same file. Combined extraction: 226 lines moved out of `_FloatingIssuesCardState`.

2. **State class reduced from 659 to 433 lines.** The remaining state class handles core orchestration: positioning, resize, issue management, and the header/issues-list builders whose state coupling was too tight for clean extraction.

3. **`_WarningBanners` uses `Column(mainAxisSize: MainAxisSize.min)`.** This introduces a Column-inside-Column in the parent build, but `mainAxisSize: MainAxisSize.min` ensures identical layout behavior — the inner Column takes only the space its children need.

4. **Zero state coupling confirmed for `_StatusRow` and `_CardFooter`.** Both read exclusively from `SleuthController` notifiers via `ValueListenableBuilder`, requiring only `controller` (and `onExport` callback for footer) as constructor parameters.

5. **All 70 UI tests passed unchanged on first run.** No test modifications needed — the widget tree output is identical.

6. **Skipped `_CardHeader` and `_IssuesList` extraction.** Both have moderate-to-heavy state coupling (`_cardOffset`, `_cardWidth`, `_showGuide` for header; `_expandedIssueId`, `_selectedIssueId`, `_cachedJankKeys` for issues). Extraction would move complexity without reducing it.

---

**Post-Implementation Notes (v4.5):**

Shipped with a simpler structure than spec'd — one file per demo instead of grouping by theme.

1. **18 individual files, no barrel file.** The spec proposed grouping small demos into `simple_demos.dart`, `animated_demos.dart`, etc. with a barrel file. Implementation chose one file per demo for maximum navigability — each file is fully self-contained and named after its class. `main.dart` imports all 18 directly; no barrel needed for 18 predictable imports.

2. **`main.dart` reduced from 1,807 to 239 lines.** Contains only: imports (20 lines), `main()`, `SleuthDemoApp`, `DemoHome` (navigation list), and `_DemoRoute` data class. All demo class definitions and helper classes removed.

3. **Helper classes stayed private in their demo files.** `_BadCirclePainter` (CustomPainterDemo), `_WavePainter` (RepaintStressDemo), `_DashboardChartPainter` (CombinedAnalyticsDashboardDemo), `_KeepAliveItem` (KeepAliveDemo) — each kept `_` prefix and moved with their demo.

4. **Import cleanup.** `main.dart` no longer needs `dart:io`, `dart:math`, or `dart:ui` — only used by individual demos. Each demo file imports only what it needs (`dart:math` for HeavyCompute/CombinedAnalytics/FpsStress, `dart:io` for NetworkStress, `dart:ui` for FpsStress).

5. **All 1,101 tests passed.** 0 analysis issues on both root package and example app. Example-only refactor with zero library impact.

---

### v4.4: FloatingIssuesCard Widget Extraction

**Problem:** `floating_issues_card.dart` is 841 lines with one 643-line State class. While functional, this size makes the file difficult to navigate, review, and modify. The state class has clear logical sections that map to distinct UI regions.

**Current file structure (841 lines):**
- Lines 20–29: `fpsColor()` helper function
- Lines 31–42: `FloatingIssuesCard` StatefulWidget
- Lines 45–687: `_FloatingIssuesCardState` (643 lines — the monolith)
- Lines 691–807: `_IssuesSummaryBar` StatelessWidget (already extracted)
- Lines 811–840: `_CornerGripPainter` CustomPainter (already extracted)

**State variables in `_FloatingIssuesCardState`:**
| Variable | Used by |
|----------|---------|
| `_cardOffset` | Header (drag), Build (positioning) |
| `_expandedIssueId` | Issues list |
| `_selectedIssueId` | Issues list |
| `_exportFeedbackVisible` | Warning banners, Footer |
| `_highlightNotFoundVisible` | Warning banners |
| `_showGuide` | Header, Build (conditional) |
| `_cachedJankKeys` | Issues list |
| `_exportFeedbackTimer` | Footer → Banner |
| `_highlightNotFoundTimer` | Issues list → Banner |
| `_cardWidth` | Header (resize), Build (sizing) |
| `_cardHeight` | Build (sizing), Resize handle |

**Approach:** Extract self-contained UI sections into private widgets in the same file. Pass state via constructor parameters and callbacks. Don't create new files — this is internal decomposition, not public API refactoring.

**Design decisions:**

1. **Same-file extraction, not multi-file.** These are private implementation widgets (`_StatusRow`, `_CardFooter`). Putting them in separate files would require making them public (losing the `_` prefix encapsulation) or using `part`/`part of` (Dart anti-pattern). Keep them in the same file as private classes.

2. **Extract by state coupling, not by visual region.** Priority order:
   - **Zero-coupling first:** Sections that read only from controller notifiers (no local state)
   - **Callback-coupling second:** Sections that need state but can receive it via constructor + callback
   - **Skip tightly-coupled:** Sections where extraction would just move state without reducing complexity

3. **Extraction candidates (ordered by value):**

| Widget | Lines | State Coupling | Extract? |
|--------|-------|----------------|----------|
| `_StatusRow` | 82 | None (reads controller notifiers) | **Yes — highest value** |
| `_CardFooter` | 31 | None (callback only) | **Yes — trivial** |
| `_WarningBanners` | 94 | 2 bool states + 2 timers | **Yes — pass via constructor** |
| `_CardHeader` | 111 | Card offset + width + guide toggle | **Maybe — moderate coupling** |
| `_IssuesList` | 58 | 3 state vars (expanded, selected, jank keys) | **Maybe — significant coupling** |

4. **Target: reduce `_FloatingIssuesCardState` from 643 to ~400 lines.** Extract `_StatusRow` (82), `_CardFooter` (31), and `_WarningBanners` (94) = 207 lines moved out. The remaining state class is ~436 lines — still large but focused on core orchestration (positioning, resize, issue management).

**Files changed:**
- `lib/src/ui/floating_issues_card.dart` — extract 3 widgets within the same file

**Acceptance criteria:**
- `_StatusRow`, `_CardFooter`, `_WarningBanners` are separate private StatelessWidgets
- No behavior change — all existing UI tests pass without modification
- State class reduced by ~200 lines
- No new files created
- No public API changes

**Testing:** Existing 70 UI tests must pass unchanged. No new tests needed (this is a refactor, not a feature).

**Risk:** Low. Pure refactoring with no behavior change. All state flows through constructor parameters.

---

### v4.5: Example App Demo Extraction

**Problem:** `example/lib/main.dart` is 1,807 lines containing 24 widget classes (18 demo screens + 6 helper classes). While the routing structure is clean (`_DemoRoute` model + `DemoHome` list), the file is unwieldy to navigate and individual demos are hard to find.

**Current structure:**
- Lines 1–31: App entry point + MaterialApp
- Lines 36–224: `DemoHome` + `_DemoRoute` model
- Lines 230–1277: 15 single-pattern demo screens
- Lines 1285–1678: 2 combined multi-detector demos
- Lines 1683–1807: FPS stress test demo

**Approach:** Extract demos into `example/lib/demos/` directory. Keep `main.dart` as the router with `DemoHome`. Group small demos by complexity.

**Design decisions:**

1. **Extraction threshold: >100 lines or complex state.** Demos under 60 lines with trivial state stay inline in a grouped file. Larger demos get their own file.

2. **File structure:**
```
example/lib/
  main.dart                              # App entry + DemoHome router (~230 lines)
  demos/
    demos.dart                           # Barrel file
    simple_demos.dart                    # 6 small stateless demos (<60 lines each)
    animated_demos.dart                  # CustomPainter, AnimatedBuilder, Repaint demos
    state_management_demos.dart          # HighLevelSetState, ShallowRebuild, KeepAlive
    heavy_compute_demo.dart              # HeavyCompute (68 lines, complex async)
    network_stress_demo.dart             # NetworkStress (160 lines, complex async)
    combined_social_feed_demo.dart       # CombinedSocialFeed (162 lines)
    combined_analytics_demo.dart         # CombinedAnalytics (185 lines)
    fps_stress_test_demo.dart            # FpsStressTest (124 lines)
```

3. **`main.dart` stays as the router.** `DemoHome` + `_DemoRoute` model + `SleuthDemoApp` remain. Demos are imported via barrel file. This keeps the entry point clean and navigation easy to understand.

4. **Barrel file for clean imports.** `demos/demos.dart` exports all demo classes. `main.dart` has a single import.

5. **Helper classes travel with their demo.** `_BadCirclePainter` moves with `CustomPainterDemo`, `_WavePainter` with `RepaintStressDemo`, `_DashboardChartPainter` with `CombinedAnalyticsDashboardDemo`, `_KeepAliveItem` with `KeepAliveDemo`.

**Files changed:**
- `example/lib/main.dart` — reduce to ~230 lines (DemoHome + routing)
- `example/lib/demos/demos.dart` — new barrel file
- `example/lib/demos/simple_demos.dart` — new: NonLazyList, IntrinsicHeight, UncachedImage, OpacityZero, FontLoading, GlobalKey, NestedScroll
- `example/lib/demos/animated_demos.dart` — new: CustomPainter, AnimatedBuilder, RepaintStress
- `example/lib/demos/state_management_demos.dart` — new: HighLevelSetState, ShallowRebuild, KeepAlive
- `example/lib/demos/heavy_compute_demo.dart` — new
- `example/lib/demos/network_stress_demo.dart` — new
- `example/lib/demos/combined_social_feed_demo.dart` — new
- `example/lib/demos/combined_analytics_demo.dart` — new
- `example/lib/demos/fps_stress_test_demo.dart` — new

**Acceptance criteria:**
- `main.dart` reduced from 1,807 to ~230 lines
- All demo screens still accessible via `DemoHome`
- `cd example && fvm flutter run` works without errors
- No library code changes — example-only refactor

**Testing:** Manual verification — `fvm flutter run` in example app, navigate to each demo.

**Risk:** Very low. Example app changes only, no library impact.

---

### Implementation Order

| Priority | Milestone | Effort | Status |
|----------|-----------|--------|--------|
| 1 | v4.1: Issue Suppression | Small | Shipped |
| 2 | v4.4: Card Widget Extraction | Small | Shipped |
| 3 | v4.5: Example App Extraction | Small | Shipped |
| 4 | v4.2: Custom Detector API | Medium | Shipped |

All v4 milestones complete. v4.3 (Shake-to-Open) was removed — native platform code would change the package type from pure Dart to plugin, which is disproportionate for this feature.

---

## v5 Roadmap

Eight milestones across three themes: overlay polish, detection accuracy, and export/correlation.

---

### v5.1: Overlay Theming — SleuthTheme + Light/Dark Mode

**Problem:** The entire overlay UI is hardcoded to a dark theme. Every color (~40 hex literals), font size (~15 values), and dimension (~12 sizing constants) are scattered across 6 files (`floating_issues_card.dart`, `issue_card.dart`, `trigger_button.dart`, `guide_page.dart`, `sleuth_overlay.dart`, `highlight_overlay.dart`). Light-theme apps get an unreadable overlay. Consumers have zero customization path.

**Current state:**
- Card background: `Color(0xF51E1E2E)` — unique dark value
- Header: `Color(0xFF374151)`, text: `Color(0xFFD1D5DB)`, `Color(0xFF9CA3AF)`
- FPS colors: 3 hardcoded RGB values in `fpsColor()` free function
- Issue card: 3 background states (jank flash, highlighted, default), 5 severity accent colors, 8 category badge colors
- Guide page: `Color(0xFF1E1E2E)` background
- Trigger button: size 56x78, initial position `Offset(16, 100)` — all hardcoded
- Card sizing: min 220x250, default 300px wide, corner radius 16px — all hardcoded
- No `Theme.of(context).brightness` checks anywhere

**Approach:** Create a `SleuthThemeData` class containing all visual tokens. The overlay reads from this theme, with a sensible dark default and an auto-generated light variant. Consumers optionally provide their own via `SleuthConfig`.

**Design decisions:**

1. **`SleuthThemeData` class** — immutable data class with all color, sizing, and typography tokens. Provides `SleuthThemeData.dark()` and `SleuthThemeData.light()` factory constructors. Consumers can extend either with `copyWith()`.

2. **Auto-detect brightness** — If no explicit theme provided in config, read `MediaQuery.platformBrightnessOf(context)` and select dark/light defaults. Consumers can override with `SleuthConfig(theme: SleuthThemeData.dark())` to force a specific mode.

3. **Token categories:**
   - `cardBackground`, `cardBorder`, `headerBackground` — card chrome
   - `textPrimary`, `textSecondary`, `textMuted` — text hierarchy
   - `severityCritical`, `severityWarning`, `severityOk` — issue severity
   - `categoryBuild`, `categoryRaster`, `categoryMemory`, `categoryNetwork`, `categoryLayout`, `categoryStructural`, `categoryGeneral`, `categoryPlatform` — category badges
   - `fpsGood`, `fpsWarning`, `fpsCritical` — FPS indicator
   - `accentPrimary`, `accentSecondary` — interactive elements
   - `triggerButtonSize`, `cardMinWidth`, `cardMinHeight`, `cardDefaultWidth`, `cardCornerRadius` — sizing
   - `fontSizeSmall`, `fontSizeMedium`, `fontSizeLarge` — typography scale

4. **Propagation via InheritedWidget** — `_SleuthTheme` InheritedWidget placed above overlay in the widget tree. All overlay widgets read via `_SleuthTheme.of(context)`. No parameter drilling.

5. **Migration strategy** — Replace hardcoded values file-by-file: issue_card.dart first (most colors), then floating_issues_card.dart, trigger_button.dart, guide_page.dart, highlight_overlay.dart. Each file is a standalone commit.

**Files changed:**
- `lib/src/ui/sleuth_theme.dart` — new: `SleuthThemeData` class + `_SleuthTheme` InheritedWidget
- `lib/src/ui/floating_issues_card.dart` — replace ~15 hardcoded colors with theme reads
- `lib/src/ui/issue_card.dart` — replace ~20 hardcoded colors with theme reads
- `lib/src/ui/trigger_button.dart` — replace sizing/colors with theme reads
- `lib/src/ui/guide_page.dart` — replace background/text colors with theme reads
- `lib/src/ui/highlight_overlay.dart` — replace highlight colors with theme reads
- `lib/src/ui/sleuth_overlay.dart` — wrap overlay tree in `_SleuthTheme`
- `lib/src/controller/sleuth_controller.dart` — add `theme` field to `SleuthConfig`
- `lib/sleuth.dart` — export `SleuthThemeData`

**Acceptance criteria:**
- Default overlay looks identical to current dark theme (visual regression test)
- Light-theme app → overlay auto-selects light colors
- `SleuthConfig(theme: SleuthThemeData.dark().copyWith(cardBackground: Colors.blue))` works
- All 6 overlay files read from theme, zero hardcoded color hex literals remain
- Existing UI tests pass unchanged

**Testing:** 8–10 tests:
1. Default theme matches dark factory
2. Light factory has distinct colors from dark
3. `copyWith` overrides individual tokens
4. InheritedWidget propagation to child widgets
5. Brightness auto-detection (mock MediaQuery)
6. Explicit theme overrides auto-detection
7. Sizing tokens applied to card/trigger
8. FPS color function reads from theme

**Risk:** Medium. Touches all UI files but is a mechanical find-and-replace. Main risk is visual regressions in edge cases (transparency compositing with different background colors).

**Post-Implementation Notes (v5.1):**

Shipped. All acceptance criteria met. Implementation details vs. original spec:

- **60 color tokens** (not ~40 + sizing + typography as originally spec'd). Sizing and typography tokens were excluded — they're layout concerns that break layouts if changed and don't need theme-awareness.
- **`SleuthThemeData`** is `const`-constructable with const redirecting constructors for `.dark()` and `.light()`. All `Color(...)` literals are const, so this works without factory constructors.
- **`SleuthTheme`** (public class, not `_SleuthTheme`) — `of(context)` returns `const SleuthThemeData()` (dark) when no ancestor exists, ensuring all existing tests pass without modification.
- **Token naming** uses semantic names (`textPrimary`/`textSecondary`/`textTertiary`/`textQuaternary`/`textSubtle` instead of `textMuted`). Category tokens match `IssueCategory` enum values exactly (`categoryBuild`, `categoryLayout`, etc.).
- **Badge and banner pairs** (bg + text) are separate tokens for independent override. Doc comments warn to always override both together.
- **`fpsColor()` free function deleted** — replaced by `SleuthThemeData.fpsColor()` method. Both consumers (trigger_button, floating_issues_card) migrated before deletion.
- **`_fixEffort()` free function** now takes `SleuthThemeData theme` parameter instead of hardcoded colors.
- **CustomPainters** (`_HighlightPainter`, `_CornerGripPainter`) receive theme/colors via constructor since `paint()` has no BuildContext. `shouldRepaint` includes theme comparison.
- **Guide page static helpers** take `SleuthThemeData theme` parameter. `_GuideStep` and `_LegendRow` StatelessWidgets read `SleuthTheme.of(context)` in their own `build()`.
- **Auto-detection** uses `MediaQuery.maybeOf(context)?.platformBrightness` (not `platformBrightnessOf`). Re-resolves on system brightness changes because `MediaQuery` dependency triggers rebuild.
- **Tests:** 20 new tests in `test/ui/sleuth_theme_test.dart` (17) and `test/ui/theme_auto_detect_test.dart` (3). Total: 1,121 tests, 0 analysis issues.
- **Files changed:** 9 modified + 2 new (theme data class, 2 test files). Zero `Color(0x` references remain in any UI file except `sleuth_theme.dart`.

---

### v5.2: Export Enrichment — Phase Events, GC, FPS Percentiles

**Problem:** `SessionSnapshot` exports aggregate stats but drops granular data that consumers need for offline root-cause analysis. Phase events (per-frame build/layout/paint/raster breakdowns), GC events, platform channel events, and FPS trend data are all computed internally but never included in exports.

**Current export fields:**
- `frameStatsSummary` — aggregate (jank count, avg FPS, worst frame)
- `capturedFrames` — worst 50 frames with verdict + related issues
- `currentIssues` — latest ranked list
- `recentRequests` — HTTP records
- `heapSamples` — memory samples
- `suppressedCount` — hidden issue count

**Missing data identified during research:**
1. Phase events (`ParsedTimelineData.phaseEvents`) — per-frame build/layout/paint/raster with dirty widget names
2. GC events — frequency, pause durations, types
3. Platform channel events — call frequency, latency
4. FPS percentiles — p50, p95, p99 over session
5. Frame sequence — last N frames (not just worst), for trend analysis
6. Ranking metadata — `rankingScore` and breakdown on each issue
7. Schema version — for forward-compatible parsing

**Approach:** Extend `SessionSnapshot` with optional fields. All new fields default to null/empty so existing consumers aren't broken. Add `schemaVersion: 2` for parsers to detect new format.

**Design decisions:**

1. **Opt-in granularity** — New fields are nullable. `exportSnapshot()` always includes them when data is available. Consumers that don't need granularity ignore null fields.

2. **Phase events capped** — Store last 100 phase events (rolling buffer in controller). Each event includes: `timestamp`, `phaseName`, `durationUs`, `dirtyWidgets: List<String>?`.

3. **FPS percentiles** — Computed from the existing `_frameStatsBuffer` (capacity 50). Add `fpsP50`, `fpsP95`, `fpsP99` calculated at export time.

4. **Ranking score on issues** — Add `rankingScore: double` and `rankingBreakdown: Map<String, double>` to `PerformanceIssue`. Populated by `IssueRanker` during ranking pass.

5. **Schema version** — `schemaVersion: 2` (v1 is the current implicit format). Increment on breaking changes.

**Files changed:**
- `lib/src/models/session_snapshot.dart` — add phaseEvents, gcEvents, platformChannelEvents, fpsPercentiles, frameSequence, schemaVersion fields
- `lib/src/models/performance_issue.dart` — add rankingScore, rankingBreakdown fields
- `lib/src/ranking/issue_ranker.dart` — populate rankingScore during rank()
- `lib/src/controller/sleuth_controller.dart` — store phase event buffer, populate new snapshot fields in exportSnapshot()
- `lib/sleuth.dart` — no barrel changes needed (types already exported)

**Acceptance criteria:**
- `exportSnapshotJson()` includes phaseEvents, gcEvents, fpsPercentiles when data available
- Issues include `rankingScore` in export
- `schemaVersion: 2` in all exports
- Existing tests pass unchanged (new fields are additive)
- Export size stays reasonable (<500KB for typical 60-second session)

**Testing:** 6–8 tests:
1. Schema version is 2
2. Phase events capped at 100
3. FPS percentiles computed correctly from buffer
4. Ranking score populated on exported issues
5. Empty session produces valid export (all new fields null/empty)
6. Export round-trip (toJson → fromJson preserves new fields)

**Risk:** Low. Additive changes only. No behavior change for existing consumers.

**Post-Implementation Notes (v5.2):**

Shipped as planned with the following decisions:

1. **Layer separation for GcEventSummary/PlatformChannelSummary:** Spec proposed `fromTimelineEvent` factories on the model classes, but models/ has zero `package:vm_service` imports. Instead, the controller extracts fields from `TimelineEvent.json!` inline and passes plain values to the model constructor. Cleaner layer boundary.

2. **FPS percentiles — sorted ascending semantics:** `fpsPercentiles()` sorts FPS values ascending and picks indices at `floor((N-1) * p)`. p50 = median, p95/p99 = higher FPS (the "good" end). This means p99 >= p95 >= p50 — the percentile represents "X% of frames had FPS at or below this value."

3. **`rankWithScores()` vs modifying `rank()`:** Added `rankWithScores()` as a separate method to avoid `copyWith` allocations on the per-scan hot path. Only the export path calls it. `rank()` unchanged.

4. **Pre-init guard:** `exportSnapshot()` now guards `_buildRankingContext()` with `_initialized` check. Before init, `_frameTiming` is `late final` and uninitialized — uses `const IssueRankingContext()` fallback.

5. **Schema version:** `schemaVersion` defaults to 2 in constructor (non-nullable int). `fromJson` defaults absent field to 1 for backward compat. All new fields nullable so v1 consumers calling `fromJson` on v2 data ignore unknown keys gracefully.

6. **Buffer capacities:** Phase events: 100, GC events: 50, platform channel events: 50. All use `List` with `removeAt(0)` FIFO eviction. O(n) per eviction but n is small and this is a cold path (only during VM timeline polling).

7. **`recentFrames` vs `capturedFrames`:** Both included in export. `capturedFrames` = worst 50 jank frames (curated). `recentFrames` = last 60 frames regardless of jank (temporal window for trend analysis).

8. **Test count:** 1,121 → 1,165 (+44 tests). New tests in: serialization_test.dart (PhaseEvent, GcEventSummary, PlatformChannelSummary, FpsPercentiles, ranking fields, FrameStatsSummary fpsPercentiles, SessionSnapshot v2), fps_percentiles_test.dart, issue_ranker_test.dart (rankWithScores), export_snapshot_test.dart (buffer tests, v2 export fields, JSON roundtrip).

Files changed: 14 (8 lib + 1 barrel + 5 test). 2 new model files, 1 new test file.

---

### v5.3: Causal Issue Graph — Root-Cause Clustering

**Problem:** Detectors run independently and report issues individually. When a high-level setState causes rebuilds, which cause layout bottlenecks, which cause heavy compute, the user sees 3–4 separate issues instead of one root cause with downstream effects. This clutters the issue list and makes prioritization harder.

**Current correlation (5 rules in `detector_correlator.dart`):**
1. Suppress AnimatedBuilder if no paint issues
2. Merge rebuild + setState evidence
3. Escalate GPU + CustomPainter confidence
4. Escalate memory + image confidence
5. Deduplicate rebuild/repaint (keep higher confidence)

**What's missing:**
- No multi-hop causal chains (A → B → C)
- No root-cause identification (which issue is the origin?)
- No downstream suppression (low-confidence effects hidden when root is clear)
- Issues reported independently even when clearly related

**Approach:** Add a post-correlation pass that builds a directed graph of issue relationships, identifies root causes, and collapses downstream issues into the root's detail section.

**Design decisions:**

1. **Causal rules (6 initial chains):**
   - `setState_scope` → `rebuild_*` → `heavy_compute` (setState triggers rebuilds, rebuilds block main thread)
   - `setState_scope` → `rebuild_*` → `layout_bottleneck` (rebuilds cause layout passes)
   - `uncached_image` → `memory_pressure` (large images cause heap growth)
   - `always_repaint_painter` → `repaint_*` → `gpu_pressure` (paint thrashing causes raster work)
   - `animated_builder_no_child` → `rebuild_*` (AnimatedBuilder rebuilds subtree every tick)
   - `non_lazy_list` → `rebuild_*` → `heavy_compute` (eager list builds all children)

2. **Graph structure** — `Map<String, Set<String>>` adjacency list keyed by stableId. Built from causal rule matching after standard correlation.

3. **Root identification** — Issues with no incoming edges in the graph are roots. Downstream issues get `rootCause: String?` field pointing to root's stableId.

4. **UI presentation** — Root issues shown normally. Downstream issues collapsed into root's expanded detail as "Related effects: ..." with muted styling. Count shown as badge.

5. **Confidence adjustment** — Downstream issues with `possible` confidence suppressed entirely when root is `confirmed` or `likely`. Downstream `likely` issues demoted to sub-items.

**Files changed:**
- `lib/src/analyzer/causal_graph.dart` — new: `CausalGraphAnalyzer` with rule definitions and graph builder
- `lib/src/analyzer/detector_correlator.dart` — call `CausalGraphAnalyzer` after existing 5 rules
- `lib/src/models/performance_issue.dart` — add `rootCause: String?`, `downstreamIssues: List<String>?`
- `lib/src/ui/issue_card.dart` — render downstream issues in expanded section

**Acceptance criteria:**
- setState → rebuild → heavy_compute chain collapses to single root issue with 2 downstream
- Root issue shows "2 related effects" badge
- Expanding root shows downstream details
- Standalone issues (no causal chain) render unchanged
- Existing 5 correlation rules still applied first

**Testing:** 10–12 tests:
1. Single-hop chain detected (A → B)
2. Multi-hop chain detected (A → B → C)
3. Root identification (no incoming edges)
4. Downstream suppression at `possible` confidence
5. Multiple independent chains in same scan
6. No chain when issues have different stableId patterns
7. Cycle prevention (A → B → A doesn't infinite loop)
8. Empty graph (no chains) produces unchanged output
9. UI: root shows downstream count badge
10. UI: expanding root shows downstream detail

**Risk:** Medium. Core correlation logic changes could affect existing issue ordering. Requires careful regression testing against all 5 existing rules.

**Post-Implementation Notes (v5.3):**

Implemented 2026-03-30. All acceptance criteria met. ~35 new tests (22 causal graph unit, 2 correlator integration, 5 serialization, 6 widget tests). Total test count: ~1,200.

Key implementation details that diverged from or refined the original spec:

1. **18 causal rules, not 6.** Original spec outlined 6 high-level chains. Implementation expanded to 18 discrete `CausalRule` entries covering all stableId combinations: `setstate_scope` (2 effects), `uncached_images` (2 effects), `always_repaint_painter` (3 effects), `animated_builder_no_child` (2 effects), `non_lazy_list` (4 effects), `rebuild_activity` (2 effects), `rebuild_debug_*` (2 effects). Trailing `*` wildcard for prefix matching (same convention as `config.suppressedIssues`).

2. **Field names: `rootCauseId` / `downstreamIds`**, not `rootCause` / `downstreamIssues` as originally spec'd. Clearer that these are stableId references, not object references. Both nullable String?/List<String>? with backward-compat null defaults.

3. **`CausalGraphRule extends CorrelationRule`**, registered as 6th rule in `DetectorCorrelator._rules`. Runs last — after merge/escalation/deduplication have simplified the issue set. Class name is `CausalGraphRule` (not `CausalGraphAnalyzer` as spec suggested).

4. **Suppression-orphan handling in UI.** If a root issue is suppressed by user config (v4.1 `suppressedIssues`), downstream issues with `rootCauseId` set would become invisible orphans. `FloatingIssuesCard` handles this: if `rootCauseId != null` but the referenced root is NOT in the current issue list, the downstream issue is treated as standalone (shown in main list). Filter logic: `issues.where((i) => i.rootCauseId == null || !allIds.contains(i.rootCauseId))`.

5. **1 new theme token: `effectsBadge`** — `Color(0xFF64748B)` (slate-500). Used at 0.2 alpha for badge background. Same value for dark and light themes.

6. **IssueCard downstream section** — "Related effects (N):" header with compact rows (severity icon + category badge + title). Max 5 visible, "and N more..." overflow text. Effects count badge `↳ N` in header row after JANK badge.

7. **No SessionSnapshot schema change needed.** `rootCauseId` and `downstreamIds` are on `PerformanceIssue` which already serializes to JSON in exports. Nullable fields with null defaults maintain backward compat — no schema version bump required.

8. **`_IssuesSummaryBar` counts only visible issues** (where `rootCauseId == null` or root not in list), not all issues in the pipeline.

Files changed (10):
- `lib/src/models/performance_issue.dart` — +2 fields, copyWith, toJson, fromJson
- `lib/src/analyzer/causal_graph.dart` — NEW (~190 lines)
- `lib/src/analyzer/detector_correlator.dart` — +import, +1 rule
- `lib/src/ui/sleuth_theme.dart` — +1 token
- `lib/src/ui/issue_card.dart` — +downstreamIssues param, badge, expanded section
- `lib/src/ui/floating_issues_card.dart` — +downstream filter, lookup, pass-through
- `test/analyzer/causal_graph_test.dart` — NEW (22 tests)
- `test/analyzer/detector_correlator_test.dart` — +2 integration tests
- `test/models/serialization_test.dart` — +5 tests
- `test/ui/issue_card_downstream_test.dart` — NEW (6 widget tests)

---

### v5.4: Configurable Detector Thresholds

**Problem:** 13 of 21 detectors have thresholds buried in their class bodies with no exposure via `SleuthConfig`. Consumers cannot tune detection sensitivity for their specific app characteristics (e.g., high-refresh 120Hz displays need tighter shader jank thresholds, battery-critical apps need lower platform channel limits).

**Currently configurable (8 detectors):**
- FrameTiming: `warningThresholdMs`, `criticalThresholdMs`, `fpsTarget`
- Rebuild: `rebuildsPerSecThreshold`
- Network: `slowRequestThresholdMs`, `frequencyLimit`, `largeResponseThresholdBytes`
- Memory: `warmupDurationMs`
- ListView: `maxListChildren`
- GlobalKey: `maxGlobalKeys`
- PlatformChannel: `platformChannelLimit`, `platformChannelDurationThresholdMs`
- Repaint: (via constructor but not config-exposed)

**Not configurable (13 detectors):**
- ShaderJank: 100ms threshold
- HeavyCompute: 8ms gap threshold
- GpuPressure: 1.5× raster/UI ratio
- MemoryPressure: 512 KB/sec growth, 80% capacity
- ShallowRebuildRisk: depth ≤3, >2 rebuilds
- SetStateScope: >50% tree ownership, >2 rebuilds
- Opacity: <0.01 opacity
- KeepAlive: >5 alive
- NestedScroll: >20 children
- LayoutBottleneck: (binary — any IntrinsicHeight/Width)
- CustomPainter: (binary — shouldRepaint always true)
- AnimatedBuilder: >20 subtree size
- FontLoading: >3 custom font families
- ImageMemory: (binary — missing cacheWidth/cacheHeight)

**Approach:** Add a `DetectorThresholds` nested config class to `SleuthConfig`. Each detector reads its threshold from config if provided, falling back to current hardcoded defaults.

**Design decisions:**

1. **`DetectorThresholds` class** — flat structure with named parameters matching detector names. All optional with current values as defaults.

2. **Only expose meaningful thresholds** — Skip binary detectors (LayoutBottleneck, CustomPainter, ImageMemory) where the threshold is "present or not." Focus on numeric thresholds that consumers might reasonably tune.

3. **Thresholds exposed (10 new parameters):**
   - `shaderJankMs` (default 100)
   - `heavyComputeGapMs` (default 8)
   - `gpuPressureRatio` (default 1.5)
   - `memoryGrowthBytesPerSec` (default 512000)
   - `memoryCapacityPercent` (default 0.8)
   - `shallowRebuildMaxDepth` (default 3)
   - `setStateScopeOwnershipPercent` (default 0.5)
   - `keepAliveMax` (default 5)
   - `animatedBuilderMinSubtreeSize` (default 20)
   - `fontLoadingMaxFamilies` (default 3)

4. **Controller wiring** — `_initializeDetectors()` passes config thresholds to detector constructors. No detector reads config directly.

**Files changed:**
- `lib/src/controller/sleuth_controller.dart` — add `DetectorThresholds` class, wire to detector constructors in `_initializeDetectors()`
- 10 detector files — add constructor parameters for thresholds (replace hardcoded values)
- `lib/sleuth.dart` — export `DetectorThresholds`

**Acceptance criteria:**
- `SleuthConfig(thresholds: DetectorThresholds(shaderJankMs: 50))` lowers shader detection sensitivity
- Default behavior identical (all defaults match current hardcoded values)
- All detector tests pass unchanged (tests use default thresholds)
- New tests verify custom thresholds are respected

**Testing:** 10 tests (one per new threshold):
1. Each new threshold parameter overrides detector default
2. Default thresholds produce identical behavior to current code

**Risk:** Low. Mechanical refactor — replace hardcoded constant with constructor parameter. Main risk is missing a usage site inside a detector.

**Post-Implementation Notes** (Implemented 2026-03-30):

1. **`DetectorThresholds` in own file** — Created `lib/src/controller/detector_thresholds.dart` (not inline in controller), following the `DebugInstrumentationConfig` pattern. Non-null field on `SleuthConfig` with `const DetectorThresholds()` default — thresholds always apply, no null checks needed.

2. **Three categories of detector changes:**
   - 6 detectors already had constructor params (ShaderJank, HeavyCompute, GpuPressure, ShallowRebuild, SetStateScope, KeepAlive) — just needed config wiring in `_initializeDetectors()`
   - 2 detectors needed new constructor params (AnimatedBuilder: `minSubtreeSize`, FontLoading: `maxFamilies`) — replaced hardcoded literals
   - 1 detector needed static const → instance field conversion (MemoryPressure: `growthThresholdBytesPerSec`, `capacityThresholdPercent`) — kept `_sustainedGrowthDurationSec` and `_nativeGrowthThresholdBytesPerSec` as static consts (too granular to expose)

3. **Secondary severity threshold fix** — ShaderJank had `ms >= 200` (hardcoded critical) and GpuPressure had `ratio > 3.0` (hardcoded critical). Both were exactly `defaultThreshold * 2` by coincidence. Converted to `thresholdMs * 2` and `rasterMultiplierThreshold * 2` respectively so critical boundaries scale properly with custom thresholds. KeepAlive already used `threshold * 2` correctly.

4. **Test count:** 1,219 total (+16 new threshold tests across 8 test files). New test file: `test/controller/detector_thresholds_test.dart` (3 tests). Custom threshold tests added to: shader_jank (3), gpu_pressure (3), memory_pressure (3), shallow_rebuild_risk (2), keep_alive (1), animated_builder (2), font_loading (2).

5. **Files changed (16):**
   - `lib/src/controller/detector_thresholds.dart` — NEW (~70 lines)
   - `lib/src/controller/sleuth_controller.dart` — +import, +field, +wiring in `_initializeDetectors()`
   - `lib/src/detectors/animated_builder_detector.dart` — +`minSubtreeSize` constructor param
   - `lib/src/detectors/font_loading_detector.dart` — +`maxFamilies` constructor param
   - `lib/src/detectors/memory_pressure_detector.dart` — static const → constructor params
   - `lib/src/detectors/shader_jank_detector.dart` — critical threshold scales with `thresholdMs * 2`
   - `lib/src/detectors/gpu_pressure_detector.dart` — critical threshold scales with `rasterMultiplierThreshold * 2`
   - `lib/sleuth.dart` — +export
   - `test/controller/detector_thresholds_test.dart` — NEW (3 tests)
   - `test/detectors/shader_jank_detector_test.dart` — +3 custom threshold tests
   - `test/detectors/gpu_pressure_detector_test.dart` — +3 custom threshold tests
   - `test/detectors/memory_pressure_detector_test.dart` — +3 custom threshold tests
   - `test/detectors/shallow_rebuild_risk_detector_test.dart` — +2 custom threshold tests
   - `test/detectors/keep_alive_detector_test.dart` — +1 custom threshold test
   - `test/detectors/animated_builder_detector_test.dart` — +2 custom threshold tests
   - `test/detectors/font_loading_detector_test.dart` — +2 custom threshold tests

---

### v5.5: Detector Registry Pattern

**Problem:** The controller has 21 hardcoded `late final` detector fields (lines 74–101). Adding or removing a detector requires touching 6+ methods: `_initializeDetectors()`, `_getAllIssues()`, `_runStructuralScans()`, `_collectHighlights()`, debug snapshot routing, and `dispose()`. This is error-prone and makes the controller file grow linearly with detector count.

**Current pattern:**
```dart
late final RebuildDetector _rebuildDetector;
late final OpacityDetector _opacityDetector;
// ... 19 more
```

Each referenced explicitly in `_getAllIssues()`:
```dart
..._rebuildDetector.issues,
..._opacityDetector.issues,
// ... 19 more spreads
```

**Approach:** Replace individual fields with a `List<BaseDetector>` registry. Lifecycle dispatch uses detector metadata (`DetectorLifecycle`, `isEnabled`) instead of hardcoded per-detector calls.

**Design decisions:**

1. **Single `_detectors` list** — `late final List<BaseDetector> _detectors`. Built in `_initializeDetectors()` from both built-in and custom detectors.

2. **Lifecycle-based dispatch** — Replace hardcoded detector calls with filtered iterations:
   ```dart
   // Before: _rebuildDetector.scanTree(ctx); _opacityDetector.scanTree(ctx); ...
   // After: for (final d in _detectors) if (d.isEnabled && d.requiresTreeScan) d.scanTree(ctx);
   ```

3. **Named access preserved** — For detectors that need specific access (e.g., `_networkMonitor` for HTTP overrides), keep typed getters:
   ```dart
   NetworkMonitorDetector get _networkMonitor => _detectors.whereType<NetworkMonitorDetector>().first;
   ```

4. **Debug snapshot routing** — Currently hardcoded to 9 specific detectors. Replace with `for (final d in _detectors) if (d.isEnabled) d.updateDebugSnapshot(snapshot)`.

5. **`_getAllIssues()` simplification:**
   ```dart
   // Before: 21 explicit spreads
   // After: _detectors.expand((d) => d.issues).toList()
   ```

6. **Disposal:**
   ```dart
   // Before: 21 explicit .dispose() calls
   // After: for (final d in _detectors) d.dispose();
   ```

**Files changed:**
- `lib/src/controller/sleuth_controller.dart` — replace 21 `late final` fields with `_detectors` list, refactor 6 methods
- `lib/src/models/base_detector.dart` — add `requiresTreeScan` getter (already implicitly there via lifecycle check)

**Acceptance criteria:**
- Controller has single `_detectors` list, no individual detector fields (except typed getters for special access)
- `_initializeDetectors()`, `_getAllIssues()`, `_runStructuralScans()`, `_collectHighlights()`, debug snapshot routing, and `dispose()` all use list iteration
- All 1,101 tests pass unchanged
- Adding a new detector requires: create class + add to `_initializeDetectors()` list (1 method, 1 line)

**Testing:** Existing tests provide full coverage. No new tests needed — this is a pure internal refactor.

**Risk:** Medium. Touches the core controller file heavily. Any missed dispatch point silently drops detector functionality. Must verify every lifecycle path dispatches to all detectors.

**Post-Implementation Notes** (Implemented 2026-03-30):

1. **3 typed fields, not `whereType` getters** — Plan originally suggested `whereType<T>().first` getters for typed access, but direct `late final` fields assigned during `_initializeDetectors()` are simpler and avoid repeated list scans. `_frameTiming`, `_memoryPressure`, `_networkMonitor` are assigned at init and never change.

2. **`vmConnected` no-op setter added to BaseDetector** — Enables `_syncVmState()` to iterate all detectors without type-checking. Only 4 hybrid detectors (Rebuild, Repaint, GpuPressure, ShallowRebuildRisk) override it. Added `@override` annotation to all 4. Cost: 17 no-op calls on rare connect/disconnect events.

3. **NetworkMonitor made non-nullable** — Was `NetworkMonitorDetector?` but always created in `_initializeDetectors()`. Made `late final NetworkMonitorDetector` — eliminated 4 null-checks. Added `_initialized` guard in `exportSnapshot()` for pre-init safety (same pattern as `_memoryPressure`).

4. **SetStateScopeDetector.clearSnapshots() handled via `is` check** — Not on BaseDetector, only called on route transition. Replaced `_setStateScope.clearSnapshots()` with `for (final d in _detectors) { if (d is SetStateScopeDetector) d.clearSnapshots(); }`. This was a missed typed-access call not caught during planning.

5. **Custom detectors merged into `_detectors`** — `config.customDetectors` appended to the list in `_initializeDetectors()`. Eliminated 7 separate `for (final d in config.customDetectors)` loops. Custom detectors now receive `vmConnected` and `updateDebugSnapshot` calls (both no-ops unless overridden).

6. **7 dispatch methods refactored:**
   - `_getAllIssues()` — 21 spreads + nullable + custom loop → `[for (final d in _detectors) ...d.issues]`
   - `_runStructuralScans()` — 15 explicit calls + custom loop → lifecycle-filtered `d.requiresTreeScan` loop
   - `_collectHighlights()` — 12 spreads + custom loop → single loop
   - Debug snapshot routing — 6 calls + custom loop → single loop (all detectors, no-op safe)
   - `_onTimelineData()` — 9 calls + 2 evaluateNow + custom loops → lifecycle-filtered loops; `_frameTiming.updateTimelineData(data)` stays as typed call (custom method not on BaseDetector)
   - `_syncVmState()` — 4 typed assignments → single loop
   - `dispose()` — 21 calls + nullable + custom loop → single loop

7. **Test count:** 1,219 total (unchanged — pure internal refactor, all existing tests validate behavioral equivalence).

8. **Files changed (6):**
   - `lib/src/models/base_detector.dart` — +`vmConnected` no-op setter (+3 lines)
   - `lib/src/controller/sleuth_controller.dart` — replaced 21 fields with `_detectors` list + 3 typed fields, refactored 7 dispatch methods (~-90 net lines)
   - `lib/src/detectors/rebuild_detector.dart` — +`@override` on `vmConnected` setter
   - `lib/src/detectors/repaint_detector.dart` — +`@override` on `vmConnected` setter
   - `lib/src/detectors/gpu_pressure_detector.dart` — +`@override` on `vmConnected` setter
   - `lib/src/detectors/shallow_rebuild_risk_detector.dart` — +`@override` on `vmConnected` setter

---

### v5.6: Network-to-Frame Correlation

**Problem:** Network monitoring and frame analysis are completely decoupled. The system cannot answer "was this jank frame caused by a pending slow request?" or "did this HTTP response parsing block the UI thread?" Frame verdicts have no awareness of concurrent network activity.

**Current state:**
- `NetworkMonitorDetector` records requests in a ring buffer (200 max) with timestamps, durations, and sizes
- `FrameVerdict` knows about UI/raster timing, CPU attribution, and phase events
- No linkage between the two — network issues and frame issues are reported independently

**Approach:** Enrich `FrameVerdict` with network context: count of pending requests and slowest pending duration during the frame window. Add a correlation rule that escalates network issues when they co-occur with jank frames.

**Design decisions:**

1. **`FrameVerdict` enrichment** — Add `pendingRequestCount: int` and `slowestPendingMs: int?` fields. Populated from `NetworkMonitorDetector`'s active request tracking.

2. **Active request tracking** — `NetworkMonitorDetector` already records `startedAt` and completion. Add `_activeRequests: Set<RequestRecord>` for in-flight requests. On frame verdict generation, query count and max duration.

3. **New correlation rule** — `EscalateNetworkJankRule`: If jank frame has `pendingRequestCount > 0` and `slowestPendingMs > slowThreshold`, escalate any `network_slow_request` issue from `possible` to `likely`.

4. **Export inclusion** — `pendingRequestCount` and `slowestPendingMs` included in `SessionSnapshot.capturedFrames` for offline analysis.

**Files changed:**
- `lib/src/models/frame_verdict.dart` — add `pendingRequestCount`, `slowestPendingMs` fields
- `lib/src/detectors/network_monitor_detector.dart` — add `_activeRequests` tracking, expose `pendingRequestSnapshot()` method
- `lib/src/controller/sleuth_controller.dart` — populate network fields when generating verdict
- `lib/src/analyzer/detector_correlator.dart` — add `EscalateNetworkJankRule`

**Acceptance criteria:**
- Jank frame during slow request shows `pendingRequestCount: 1` in verdict
- Network issue escalated from `possible` to `likely` when co-occurring with jank
- Export includes network context per captured frame
- No overhead when no network requests are active

**Testing:** 6 tests:
1. Pending request count populated during jank
2. Pending request count is 0 when no active requests
3. Slowest pending duration calculated correctly
4. Correlation rule escalates confidence
5. No escalation when request completes before frame
6. Export includes network context

**Risk:** Low. Additive fields on existing models. Network detector already tracks all needed data.

**Post-Implementation Notes (v5.6):**

Shipped. Key deviations from original spec:

1. **Paired callbacks, not active request set** — Original spec proposed `_activeRequests: Set<RequestRecord>`. Implemented as `Map<int, DateTime> _activeRequests` keyed by monotonic request ID. Paired `onRequestStarted(id, startedAt)` / `onRequestEnded(id)` callbacks on `SleuthHttpOverrides` fire from `_MonitoringHttpClient.openUrl()` (start) and `_MonitoringResponse._emitRecord()` + `_MonitoringRequest.close()` catch (end). Request IDs ensure correct pairing with concurrent requests.

2. **No escalation rule — causal graph instead** — Original spec proposed `EscalateNetworkJankRule` to escalate `network_slow_request` from `possible` to `likely`. However, all 3 network issues are already `IssueConfidence.confirmed` (directly measured). Replaced with 2 causal graph rules: `slow_request → heavy_compute` and `request_frequency → rebuild_activity` (20 total rules). These work within existing confidence suppression.

3. **`withNetworkContext()` follows `withTopFunctions()` pattern** — Network enrichment happens synchronously before verdict emission in all 3 paths (correlated, full, basic) via `_enrichVerdictWithNetworkContext()`. CPU attribution happens asynchronously after. `withTopFunctions()` preserves network fields.

4. **Zero-overhead guarantee** — When network monitoring disabled: callbacks null, `_activeRequests` empty, enrichment returns immediately. When active but no in-flight requests: `pendingRequestSnapshot()` returns `(0, null)`, enrichment returns original verdict.

5. **Backward compatibility** — All new fields nullable (`pendingRequestCount: int?`, `slowestPendingMs: int?`). Callbacks optional on `SleuthHttpOverrides`. New methods additive on `NetworkMonitorDetector`. No schema version bump needed (nested in existing `CaptureEntry.verdict`).

Files changed: `network_monitor_detector.dart` (+30), `frame_verdict.dart` (+35), `http_monitor.dart` (+25), `sleuth_controller.dart` (+20), `causal_graph.dart` (+4). Tests: 12 new tests across 3 files. Total: 1,231 tests, 0 analysis issues.

---

**Post-Implementation Notes (v5.8):**

Shipped. Key deviations from original spec:

1. **Lifecycle is `structural`, not `hybrid`** — Spec said "Hybrid detector" but existing patterns (`CustomPainterDetector`, `AnimatedBuilderDetector`) show structural detectors receive debug snapshots via `updateDebugSnapshot()` (controller delivers to all enabled detectors regardless of lifecycle). `hybrid` adds VM timeline routing which this detector doesn't need.

2. **Three-tier confidence (not two-tier)** — Spec described `possible` and `likely`/`confirmed` from VM repaint evidence. Implemented 3 tiers matching `CustomPainterDetector` pattern: `possible` (structural only), `likely` (debug paint rate >10/sec), `confirmed` (>30/sec). Uses `paintsPerSecondForType()` across all 5 expensive widget types, taking the max rate.

3. **3 causal graph rules added (not in spec)** — Spec didn't mention causal rules. Added `missing_repaint_boundary → {excessive_repaint, excessive_repaint_debug, raster_dominance}` paralleling existing `always_repaint_painter` rules. Total: 23 causal rules.

4. **Severity scales with finding count** — 1-3 findings: `warning`. 4+: `critical`. Provides signal strength without being noisy.

5. **Dominant widget type in fix hint** — Tracks most common expensive widget type across findings and passes it to `FixHintBuilder.missingRepaintBoundary()` for specific code example in the hint.

Files changed: `base_detector.dart` (+2), `fix_hint_builder.dart` (+20), `repaint_boundary_detector.dart` (new, +160), `sleuth_controller.dart` (+3), `causal_graph.dart` (+5). Tests: 12 new tests across 2 files. Total: 1,243 tests, 0 analysis issues.

---

### v5.8: RepaintBoundary Coverage Detector

**Problem:** Flutter developers often forget to add `RepaintBoundary` widgets around expensive animated subtrees. When a deep subtree with GPU-heavy operations (Opacity, ClipPath, BackdropFilter, CustomPaint) repaints, the repaint propagates up the tree, causing unnecessary work. No existing detector flags this gap.

**Current related detectors:**
- `RepaintDetector` — flags high repaint frequency but doesn't suggest where to add boundaries
- `GpuPressureDetector` — flags raster-heavy operations but doesn't check for boundary presence
- `CustomPainterDetector` — flags always-repaint painters but doesn't check parent boundary

**Approach:** New structural detector that identifies deep subtrees containing expensive GPU operations (Opacity, ClipPath, BackdropFilter, ShaderMask, CustomPaint) without a `RepaintBoundary` ancestor within 3 levels. Combined with repaint evidence from the debug snapshot, the detector can escalate from structural observation to confirmed performance issue.

**Design decisions:**

1. **Detection logic** — During `scanTree()`, walk the render tree looking for expensive render objects (`RenderOpacity`, `RenderClipPath`, `RenderBackdropFilter`, `RenderShaderMask`, `RenderCustomPaint`). For each, check if a `RenderRepaintBoundary` exists within 3 ancestor levels. If not, flag as structural finding.

2. **Confidence escalation** — `possible` if structural only (expensive node without boundary). `likely` if co-occurring with high repaint count from debug snapshot. `confirmed` if VM repaint evidence shows >30 repaints/sec on the subtree.

3. **Lifecycle** — Hybrid detector. Structural scan provides the "where" (which widget), debug snapshot provides the "how bad" (repaint frequency).

4. **Fix hint** — `FixHintBuilder.missingRepaintBoundary(widgetName, ancestorChain)` suggesting `RepaintBoundary` insertion point.

5. **DetectorType** — Add `DetectorType.repaintBoundary` to the enum.

**Files changed:**
- `lib/src/models/base_detector.dart` — add `DetectorType.repaintBoundary`
- `lib/src/detectors/repaint_boundary_detector.dart` — new detector
- `lib/src/utils/fix_hint_builder.dart` — add `missingRepaintBoundary()` method
- `lib/src/controller/sleuth_controller.dart` — register in detector list
- `lib/sleuth.dart` — no changes needed (DetectorType already exported)

**Acceptance criteria:**
- Expensive GPU widget without RepaintBoundary ancestor → `possible` issue
- Same + high repaint rate → `likely` or `confirmed`
- Fix hint suggests specific insertion point
- No false positives on widgets already inside RepaintBoundary
- Widget tree with RepaintBoundary at root → no issue

**Testing:** 8 tests:
1. CustomPaint without boundary → flagged
2. CustomPaint with direct RepaintBoundary parent → not flagged
3. CustomPaint with boundary 2 levels up → not flagged
4. CustomPaint with boundary 4+ levels up → flagged
5. Multiple expensive nodes, one boundary covers all → not flagged
6. High repaint evidence escalates confidence
7. Fix hint includes widget name and ancestor chain
8. Detector disabled → no issues

**Risk:** Low. New detector — additive. No changes to existing detection behavior.

---

### v5 Implementation Order

| Priority | Milestone | Effort | Dependencies | Status |
|----------|-----------|--------|--------------|--------|
| 1 | v5.1: Overlay Theming | Medium | None | Shipped |
| 2 | v5.2: Export Enrichment | Low-Medium | None | Shipped |
| 3 | v5.4: Configurable Thresholds | Low | None | Shipped |
| 4 | v5.5: Detector Registry | Medium | None (but makes v5.8 easier) | Shipped |
| 5 | v5.3: Causal Issue Graph | Medium | None | Shipped |
| 6 | v5.6: Network-to-Frame Correlation | Low-Medium | None | Shipped |
| 7 | v5.8: RepaintBoundary Detector | Low-Medium | v5.5 (uses registry) | Shipped |

v5.7 (Accessibility) was removed — low value for a developer-only diagnostics overlay that is disabled in release builds. All other v5 milestones shipped.

---

