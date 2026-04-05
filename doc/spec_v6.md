## v6 Roadmap: Robustness, Accuracy & Polish

Twenty-two improvements across four themes: controller safety, detector accuracy, UI polish, and test coverage. Identified via comprehensive package audit after v0.7.0 release.

---

### v6.1: Controller Async Safety — VM Service Timeouts & Dispose Guards ✅ Shipped

**Problem:** Three async safety issues in `SleuthController`:

1. **No timeouts on VM service calls.** `getCpuSamples()` and `getAllocationProfile()` are called via `.then()` chains with no timeout. If the VM service hangs (e.g., device disconnects mid-call), these futures block indefinitely, and late callbacks may update disposed notifiers.

2. **Future callbacks survive dispose.** The `.then()` chain at line ~998 can complete after `dispose()` is called. While `_disposed` is checked at a few points, the chain between checks is not atomic — a dispose between the check and the notifier update causes a use-after-dispose.

3. **Silent error swallowing.** `.catchError((_) {})` on lines ~1026-1042 silently discards all errors from `getAllocationProfile` and `getIsolate`. Failures are invisible — no logging, no metrics, no way to debug enrichment gaps.

**Approach:**

1. Wrap all VM service future calls with `.timeout(Duration(seconds: 5))`.
2. Capture a `_disposeGeneration` counter. Increment on dispose. In every `.then()` callback, check `if (_disposeGeneration != gen) return` before touching any state.
3. Replace `catchError((_) {})` with `catchError((e) { debugPrint('Sleuth: allocation enrichment failed: $e'); })` — visible in debug, silent in release.

**Files changed:**
- `lib/src/controller/sleuth_controller.dart` — add timeout, generation guard, and debug logging to enrichment chains

**Testing:**
1. VM call that exceeds timeout → enrichment skipped, no hang
2. Dispose during in-flight CPU attribution → callback is no-op
3. Dispose during in-flight allocation profile → callback is no-op
4. VM service throws → error logged in debug, issue still emitted without enrichment

**Risk:** Low. Changes are confined to async callback chains. No public API changes.

---

### v6.2: OpacityDetector — Add AnimatedOpacity Detection ✅ Shipped

**Problem:** `OpacityDetector` only checks `widget is Opacity` (line 51). An `AnimatedOpacity(opacity: 0.0, ...)` with zero opacity is functionally identical waste — the widget still participates in layout, hit testing, and semantics — but is never flagged.

**Current state:** The detector checks `widget is Opacity && widget.opacity < 0.01`. `AnimatedOpacity` is a different class that wraps `RenderAnimatedOpacity`, not `RenderOpacity`.

**Approach:** Add `widget is AnimatedOpacity` check. For `AnimatedOpacity`, read the current opacity from the render object (`RenderAnimatedOpacity.opacity.value`) since the widget's `opacity` field is the target value (animation may still be in progress).

**Design decisions:**
- Only flag `AnimatedOpacity` when the render object's **current** opacity is < 0.01 (not the target). This avoids false positives during fade-out animations where the target is 0 but the widget is still partially visible.
- Same stableId (`opacity_zero`) since the fix is the same: use `Visibility` instead.
- If `renderObject` is null or not `RenderAnimatedOpacity`, skip (defensive).

**Files changed:**
- `lib/src/detectors/opacity_detector.dart` — add `AnimatedOpacity` branch in visitor

**Testing:**
1. `AnimatedOpacity(opacity: 0.0)` → flagged
2. `AnimatedOpacity(opacity: 0.5)` → not flagged
3. Regular `Opacity(opacity: 0.0)` → still flagged (regression check)

**Risk:** Low. Additive detection logic, same stableId.

---

### v6.3: GpuPressureDetector — Add RenderShaderMask to Render Tree Check ✅ Shipped

**Problem:** `GpuPressureDetector` lists `ShaderMask` in the widget-level detection (line 74) but never checks for `RenderShaderMask` in the render tree visitor (lines 94-96). Only `RenderOpacity`, `RenderClipPath`, and `RenderBackdropFilter` are checked. This means ShaderMask widgets are counted as GPU-expensive at the widget level but never detected at the render level, creating an inconsistency.

**Approach:** Add `ro is RenderShaderMask` to the render tree visitor's type check alongside the existing three types.

**Files changed:**
- `lib/src/detectors/gpu_pressure_detector.dart` — add `RenderShaderMask` to render visitor

**Testing:**
1. Widget tree with `ShaderMask` → detected in render tree node count
2. Render tree counts match widget tree counts for all 4 types

**Risk:** Very low. One line change.

---

### v6.4: NestedScrollDetector — Add Widget Highlights ✅ Shipped

**Problem:** `NestedScrollDetector` is the only structural detector that doesn't generate `WidgetHighlight` entries. When highlights are enabled, nested scroll issues are invisible in the overlay while all other structural issues are visually marked.

**Approach:** Add `_highlights` list, generate a `WidgetHighlight` for the parent scrollable when a nested scroll pattern is detected. Use severity `warning` and include the inner/outer scroll types in the detail string.

**Files changed:**
- `lib/src/detectors/nested_scroll_detector.dart` — add `_highlights` list, override `highlights` getter, generate highlights in `scanTree()`

**Testing:**
1. Nested scroll detected → highlight generated with correct rect
2. No nested scroll → highlights empty
3. Dispose → highlights cleared

**Risk:** Very low. Additive.

---

### v6.5: UI Tap Targets — Increase Header Icon Button Size ✅ Shipped

**Problem:** Header icon buttons in `FloatingIssuesCard` use `padding: EdgeInsets.all(8)` around a 16px icon, yielding ~32x32 tap targets. The minimum recommended touch target on mobile is 48x48 (Material Design guidelines, WCAG 2.5.5).

**Approach:** Increase padding to `EdgeInsets.all(14)` (14 + 16 + 14 = 44, close enough with GestureDetector's built-in hit slop of 8px extending the effective target to ~52x52). Alternatively, switch `_headerIconButton` to use Flutter's `IconButton` with `constraints: BoxConstraints(minWidth: 44, minHeight: 44)` and `visualDensity: VisualDensity.compact`.

**Design decision:** Use `IconButton` with compact density — it provides built-in ink splash, semantics, and proper hit testing while maintaining the current visual size.

**Files changed:**
- `lib/src/ui/floating_issues_card.dart` — replace `_headerIconButton` GestureDetector with `IconButton`

**Testing:**
1. Visually verify tap targets are at least 44x44
2. Existing card interaction tests still pass

**Risk:** Low. Visual-only change.

**Post-Implementation Notes:** Replaced `_headerIconButton` GestureDetector with `IconButton` using `constraints: BoxConstraints(minWidth: 44, minHeight: 44)` and `visualDensity: VisualDensity.compact`. Added tooltips to all 3 header buttons (Guide, Show/Hide overlay, Close). Follows same pattern as the existing footer export `IconButton`.

---

### v6.6: UI Drag Safety — Clamp Offset in onPanUpdate ✅ Shipped

**Problem:** The drag handler updates `_cardOffset` in `onPanUpdate` without bounds checking. The clamp happens in `build()`, meaning there's a one-frame delay where the card can render partially off-screen. On fast drags, this creates visible visual glitches.

**Approach:** Move the clamping logic into `onPanUpdate` so the offset is always valid before `setState()` is called. Extract the clamping calculation into a `_clampOffset(Offset raw, Size screenSize)` helper shared by both `onPanUpdate` and `build()`.

**Files changed:**
- `lib/src/ui/floating_issues_card.dart` — extract `_clampOffset()`, use in `onPanUpdate`

**Testing:**
1. Drag to screen edge → card stays within bounds every frame
2. Rapid drag gestures → no visual glitch

**Risk:** Low.

**Post-Implementation Notes:** Used field-caching approach: `_cachedTopPadding` and `_cachedEffectiveWidth` set at top of `build()`, read by `onPanUpdate` handler. Calls `_clampOffset()` (from v6.10) immediately after accumulating delta in `onPanUpdate`, so stored offset is always valid. No parameter threading through `_buildCardBody`/`_buildHeader` — cleaner than growing method signatures.

---

### v6.7: UI Keyboard Awareness ✅ Shipped

**Problem:** The card's vertical position is clamped to `screenSize.height - 100`, but doesn't account for keyboard height. On mobile with a soft keyboard visible, the card can be completely hidden behind the keyboard with no way to reposition it.

**Approach:** Read `MediaQuery.of(context).viewInsets.bottom` and subtract it from the available height when clamping the card's Y position. This automatically pushes the card up when the keyboard appears.

**Files changed:**
- `lib/src/ui/floating_issues_card.dart` — account for `viewInsets.bottom` in vertical clamping

**Testing:**
1. Keyboard visible → card pushed above keyboard
2. Keyboard dismissed → card returns to previous position

**Risk:** Low.

**Post-Implementation Notes:** Added optional `keyboardHeight` parameter to `_clampOffset` (default 0, preserves all existing behavior). Bottom clamp becomes `screenSize.height - 100 - keyboardHeight`. Added `_cachedKeyboardHeight` field for gesture handler access. `mq.viewInsets.bottom` read in `build()` — keyboard open/close triggers rebuild via MediaQuery dependency, card automatically pushed above keyboard.

---

### v6.8: UI Listener Deduplication ✅ Shipped

**Problem:** `FloatingIssuesCard` registers two separate listeners on the same `issuesNotifier` (line 66-68):
```dart
widget.controller.issuesNotifier.addListener(_onVerdictChanged);
widget.controller.issuesNotifier.addListener(_pruneStaleState);
```
Both call `setState()`, causing two rebuilds per notification. On a jank-heavy app, this doubles the overlay's rebuild frequency unnecessarily.

**Approach:** Combine into a single listener that calls both functions:
```dart
void _onIssuesChanged() {
  _pruneStaleState();
  _onVerdictChanged();
}
```

**Files changed:**
- `lib/src/ui/floating_issues_card.dart` — merge two listeners into one

**Testing:**
1. Issue notification → single rebuild (verify with debugPrintRebuildDirtyWidgets or counter)
2. Prune + verdict logic both still execute

**Risk:** Very low.

**Post-Implementation Notes:** Added `_onIssuesChanged()` that calls `_pruneStaleState()` then `_onVerdictChanged()`. Single listener registration on `issuesNotifier` in `initState`/`dispose`. `_onVerdictChanged` remains independently registered on `verdictNotifier`. Both original methods unchanged — combined method just sequences them. If both call `setState()`, the second finds element already dirty and is a no-op.

---

### v6.9: UI Text Overflow Protection ✅ Shipped

**Problem:** Several `Text` widgets in banner and warning areas lack `maxLines` + `overflow: TextOverflow.ellipsis`. When the card is resized to a narrow width, these texts overflow horizontally:
- Debug mode banner (line ~620)
- Instrumentation active message (line ~643)
- "Widget not visible" message (line ~690)

**Approach:** Add `maxLines` and `overflow: TextOverflow.ellipsis` to all banner Text widgets. Use `softWrap: true` where multiline is intentional.

**Files changed:**
- `lib/src/ui/floating_issues_card.dart` — add overflow protection to banner texts

**Testing:**
1. Resize card to minimum width → no text overflow
2. Full-width card → text displays normally

**Risk:** Very low.

**Post-Implementation Notes:** Added `maxLines` + `overflow: TextOverflow.ellipsis` to 4 banner Text widgets in `_WarningBanners`: debug mode (maxLines: 2), instrumentation (maxLines: 3), export success (maxLines: 1), highlight not found (maxLines: 2). All inside Expanded wrappers so width is already constrained — the maxLines prevents excessive vertical expansion at narrow widths.

---

### v6.10: UI Build Method Extraction — FloatingIssuesCard ✅ Shipped

**Problem:** `FloatingIssuesCard.build()` is 112 lines — well above the 50-line guideline. It mixes position clamping math, gesture handling, and widget tree construction in one method, making it hard to understand and modify.

**Approach:** Extract into focused methods:
- `_clampOffset()` — position math (already needed for v6.6)
- `_buildCardStack()` — the inner Stack with header + content
- `_buildResizeHandle()` — the resize gesture area

The `build()` method becomes a ~30 line method that computes position and delegates to these builders.

**Files changed:**
- `lib/src/ui/floating_issues_card.dart` — extract 3 methods from build()

**Testing:** Existing UI tests pass unchanged.

**Risk:** Low. Refactoring only.

**Post-Implementation Notes:** Extracted 3 methods: `_clampOffset()` (position math), `_buildCardBody()` (ConstrainedBox + Material + Column), `_buildResizeHandle()` (Positioned resize handle). `build()` reduced from 112 to ~35 lines. `_clampOffset()` is ready for v6.6 to call from `onPanUpdate`.

---

### v6.11: UI Build Method Extraction — IssueCard ✅ Shipped

**Problem:** `IssueCard.build()` spans 345 lines. The Column children array runs from line 111 to 421 — nearly impossible to navigate.

**Approach:** Extract the expanded content section (lines ~202-421) into `_buildExpandedContent()`. This single extraction cuts the build method roughly in half.

**Files changed:**
- `lib/src/ui/issue_card.dart` — extract `_buildExpandedContent()`

**Testing:** Existing UI tests pass unchanged.

**Risk:** Low. Refactoring only.

**Post-Implementation Notes:** Extracted `_buildExpandedContent(PerformanceIssue, SleuthThemeData)` returning `List<Widget>` (spread into Column with `..._buildExpandedContent()`). `build()` reduced from 346 to ~125 lines. All 6 existing helper methods unchanged.

---

### v6.12: GuidePage Back Navigation ✅ Shipped

**Problem:** GuidePage handles only its own back-arrow `IconButton`. On Android, pressing the system back button closes the app instead of the guide. On iOS, the edge-swipe gesture doesn't work either.

**Approach:** Wrap GuidePage content in `PopScope(canPop: false, onPopInvokedWithResult: ...)` that calls the close callback when the system back gesture is triggered.

**Files changed:**
- `lib/src/ui/guide_page.dart` — add `PopScope` wrapper

**Testing:**
1. System back gesture → guide closes (not the app)
2. Back arrow button → still works

**Risk:** Very low.

**Post-Implementation Notes:** Wrapped outermost `Material` in `PopScope(canPop: false, onPopInvokedWithResult: ...)`. Added test using `tester.binding.handlePopRoute()` to verify system back calls `onClose`. 3 tests total in guide_page_test.dart.

---

### v6.13: Model Equality — PerformanceIssue ✅ Shipped

**Problem:** `PerformanceIssue` doesn't override `==` / `hashCode`. If issues are stored in Sets (e.g., for deduplication) or used as Map keys, identity-based comparison causes subtle bugs — two identical issues from consecutive scans are treated as different objects.

**Approach:** Override `==` and `hashCode` based on `stableId` — the field designed for identity. Two issues with the same `stableId` are the same issue (possibly with updated severity/confidence). This matches how suppression and causal graph matching already work.

**Design decision:** Use `stableId` only (not all fields) because issues update their severity/confidence/detail across scans while remaining the "same" issue. `stableId` is the semantic identity.

**Files changed:**
- `lib/src/models/performance_issue.dart` — add `==` and `hashCode` overrides on `stableId`

**Testing:**
1. Two issues with same stableId → equal
2. Two issues with different stableId → not equal
3. Set<PerformanceIssue> deduplicates by stableId

**Risk:** Medium. Any code relying on identity-based inequality of same-stableId issues would break. Audit all `Set<PerformanceIssue>` and `Map<PerformanceIssue, ...>` usages first.

**Post-Implementation Notes:**
- Shipped. `==` returns true when both have non-null `stableId` and they match; `hashCode` delegates to `stableId.hashCode` (or `super.hashCode` when null).
- Null `stableId` guard: two issues with `stableId == null` are NOT equal by value — falls back to identity comparison. Matches the existing `stableId ?? title` fallback pattern.
- Full audit confirmed zero existing code uses `==`/`!=` on PerformanceIssue objects — zero breakage.
- 9 new tests: same stableId equality, different stableId, null stableId isolation, null vs non-null, identical reference, Set dedup, hashCode consistency, hashCode distribution, Map key behavior.
- `const` constructor preserved — note that `const` objects with identical fields are Dart-canonicalized (same instance via `identical`).

---

### v6.14: Controller Error Logging — Enrichment Chain Visibility ✅ Shipped

**Problem:** Enrichment chain errors are silently swallowed by `.catchError((_) {})`. When `getAllocationProfile` or `getIsolate` fail, there's zero visibility into why enrichment data is missing from snapshots.

**Note:** This is a subset of v6.1 but can be implemented independently if v6.1's generation-guard pattern is deferred.

**Approach:** Replace `catchError((_) {})` with `catchError((e) { assert(() { debugPrint('Sleuth: $e'); return true; }()); })` — visible in debug mode, zero-cost in release.

**Files changed:**
- `lib/src/controller/sleuth_controller.dart` — replace 3 silent catch blocks

**Testing:**
1. VM service throws → debug message printed
2. Release mode → no output (assert removed by tree shaking)

**Risk:** Very low.

---

### v6.15: Suppression Pattern Precompilation ✅ Shipped

**Problem:** `_matchesSuppression` rebuilds wildcard-to-regex conversion on every call. With 22 detectors emitting issues every scan cycle and a non-trivial suppression list, this is repeated work.

**Approach:** Precompile suppression patterns to `RegExp` objects at controller construction time. Store as `List<RegExp> _compiledSuppressions`. Match against these in `_matchesSuppression`.

**Files changed:**
- `lib/src/controller/sleuth_controller.dart` — precompile patterns in constructor, use in matching

**Testing:**
1. Wildcard pattern `opacity_*` still suppresses `opacity_zero`
2. Exact pattern `non_lazy_list` still works
3. Performance: matching 100 issues against 10 patterns is faster (benchmark optional)

**Risk:** Very low.

**Post-Implementation Notes:**
- Shipped. Used split exact/prefix approach instead of RegExp — `Set<String>` for O(1) exact matches, `List<String>` for prefix patterns (trailing `*` stripped).
- `_compileSuppressions()` called once in constructor body. No `updateConfig()` exists — config is final.
- All 8 existing suppression tests pass unchanged (behavioral equivalence).

---

### v6.16: Pubspec Platform Declarations ✅ Shipped

**Problem:** `pubspec.yaml` doesn't include `platforms:` section. While optional, declaring platforms improves pub.dev discoverability and communicates supported targets explicitly.

**Approach:** Add platform declarations matching the README's platform support matrix.

**Files changed:**
- `pubspec.yaml` — add `platforms:` section

```yaml
platforms:
  android:
  ios:
  macos:
  linux:
  windows:
```

**Risk:** None.

**Post-Implementation Notes:**
- Shipped. Added `platforms: {android:, ios:}` to pubspec.yaml. Limited to mobile — desktop technically works but isn't the target audience. No `web:` due to unconditional `dart:io` imports.

---

### v6.17: Test Gap — Controller Lifecycle Tests ✅ Shipped

**Problem:** No tests for `SleuthController.initialize()` (only `initializeDetectorsForTest()` is tested), dispose-during-active-scan, concurrent frame processing, or config changes mid-session. These are the highest-risk untested code paths.

**Approach:** Add 10 tests in 3 groups:
1. Pre-initialization safety: notifier defaults, exportSnapshot, dispose-before-init
2. Dispose lifecycle: notifier access after dispose, heap sample feed after dispose, recurrence cleanup
3. Concurrent data processing: rapid timeline batches, interleaved data sources, suppression config, tree scan

**Files changed:**
- `test/controller/lifecycle_test.dart` — new file (10 tests)
- `lib/src/controller/sleuth_controller.dart` — `_detectorsReady` guard in `dispose()` to prevent `LateInitializationError` when disposing before initialization

**Risk:** Low. Test-only changes + one-line production guard.

**Post-Implementation Notes:**
- Discovered that `dispose()` crashed with `LateInitializationError` when called before `_initializeDetectors()` — `_detectors` is `late final` and was accessed unconditionally. Fixed by adding `_detectorsReady` bool set in `_initializeDetectors()`, checked in `dispose()`.
- Cannot use `_initialized` for the dispose guard because `initializeDetectorsForTest()` sets `_detectors` without setting `_initialized = true`.
- Tests use `initializeDetectorsForTest()` exclusively — real `initialize()` requires VM service unavailable in test environment.

---

### v6.18: Test Gap — UI Widget Tests ✅ Shipped

**Problem:** `TriggerButton` and `HighlightOverlay` have zero direct tests. Other UI widgets (`FloatingIssuesCard`, `IssueCard`) have meaningful coverage via 6 existing test files.

**Approach:** Add smoke tests for the two untested widgets:
1. `trigger_button_test.dart` — 7 tests: render, tap callback, issue count badge, no badge when empty, debug warning badge, FPS text, drag
2. `highlight_overlay_test.dart` — 4 tests: empty state (no CustomPaint), highlights render CustomPaint, selected highlight, IgnorePointer wrapper

**Files changed:**
- `test/ui/trigger_button_test.dart` — new file (7 tests)
- `test/ui/highlight_overlay_test.dart` — new file (4 tests)

**Risk:** Low. Test-only changes.

**Post-Implementation Notes:**
- Narrowed scope: `FloatingIssuesCard` and `IssueCard` already have 6 test files with meaningful coverage. `SleuthOverlay` calls `controller.initialize()` which requires VM service. Focused on the two widgets with genuinely zero tests.
- Tests use isolated `ValueNotifier` instances — no controller dependency. Each test creates and disposes its own notifiers.
- TriggerButton uses `LayoutBuilder` which needs finite constraints; wrapping in `MaterialApp > Scaffold` provides this.

---

### v6.19: ListviewDetector Threshold Tuning ✅ Shipped

**Problem:** The non-lazy list threshold of 20 children is aggressive. A login form with 25 static `TextFormField` widgets in a `SingleChildScrollView + Column` gets flagged, but this is an intentional design choice — the list is small enough that lazy building adds no benefit.

**Approach:** Increase default threshold from 20 to 50. The existing `maxListChildren` config parameter already allows user override, so this is just a default change. At 50 items, the performance cost of non-lazy rendering is measurable; below that, it's noise.

**Files changed:**
- `lib/src/controller/sleuth_controller.dart` — change `maxListChildren` default from 20 to 50
- `test/detectors/listview_detector_test.dart` — update threshold-boundary tests

**Risk:** Low. Reduces false positives. Users who want the stricter threshold can set `maxListChildren: 20`.

**Status:** ✅ Shipped

**Post-Implementation Notes (2026-03-31):**
1. **Wider blast radius than spec:** Both detector constructor defaults updated (ListviewDetector + NestedScrollDetector), not just SleuthConfig. Also updated description strings and doc comments that hardcoded ">20".
2. **NestedScrollDetector tests also affected:** The spec only listed `listview_detector_test.dart`, but `nested_scroll_detector_test.dart` shares the `maxListChildren` config parameter and had 2 tests with threshold-dependent child counts (25 children, 45 children) that needed updating to 55 and 105 respectively.
3. **Suppression test also affected:** `test/controller/suppression_test.dart` used `_opacityAndListTree()` with 25 children to trigger `non_lazy_list` — updated to 55.
4. **Severity thresholds at new default:** Warning at 51-100 children, highlight critical at 101-150, issue critical at 151+ (ListviewDetector uses 3× multiplier for issue severity, NestedScrollDetector uses 2× multiplier).

---

### v6.20: TriggerButton Adaptive Initial Position ✅ Shipped

**Problem:** TriggerButton's initial position is hardcoded to `Offset(16, 100)`. On very small screens or landscape orientation, this may place the button at an awkward position or partially off-screen.

**Approach:** ~~Initialize position based on screen size in `didChangeDependencies()` (first call only)~~ Use nullable `_position` with lazy initialization in the existing `LayoutBuilder` builder callback: `_position ??= Offset((constraints.maxWidth - 72).clamp(...), (constraints.maxHeight * 0.4).clamp(...))`. Bottom-right quadrant. Still draggable to any position after that.

**Files changed:**
- `lib/src/ui/trigger_button.dart` — adaptive initial position via LayoutBuilder lazy init
- `test/ui/trigger_button_test.dart` — new test verifying adaptive positioning

**Testing:**
1. Small screen → button visible and accessible
2. Large screen → button visible in right area
3. After drag → position persists regardless of initial

**Risk:** Very low.

**Status:** ✅ Shipped

**Post-Implementation Notes (2026-03-31):**
1. **LayoutBuilder lazy init instead of didChangeDependencies:** The spec suggested `didChangeDependencies()` + MediaQuery, but TriggerButton already has a LayoutBuilder. Used nullable `_position` with `??=` in the builder callback — matches FloatingIssuesCard's established pattern, uses actual layout constraints instead of full screen size, and requires no additional MediaQuery dependency.
2. **Position formula:** `Offset((constraints.maxWidth - 72).clamp(0, maxWidth - 56), (constraints.maxHeight * 0.4).clamp(0, maxHeight - 78))`. The 72 = 56 (button width) + 16 (right margin). Clamp bounds match existing drag clamping from v6.6.
3. **Force-unwrap safety:** `_position!` is used in drag handler and margin — safe because `??=` runs at the top of the builder, before any widget reads the value.

---

### v6.21: Hardcoded Spacing → Theme Tokens ✅ Shipped

**Problem:** While `SleuthThemeData` centralizes all colors, spacing and sizing remain hardcoded throughout UI files: `EdgeInsets.fromLTRB(10, 6, 4, 4)`, `screenSize.height * 0.30`, `SizedBox(height: 6)`, etc. This makes the overlay's density impossible to customize and creates maintenance burden.

**Approach:** Add spacing tokens to `SleuthThemeData`:
```dart
final double spacingXs;  // 4
final double spacingSm;  // 6
final double spacingMd;  // 8
final double spacingLg;  // 12
final double spacingXl;  // 16
```

Replace hardcoded values in all UI files with `theme.spacingMd`, `theme.spacingLg`, etc.

**Files changed:**
- `lib/src/ui/sleuth_theme.dart` — add spacing tokens
- `lib/src/ui/floating_issues_card.dart` — use spacing tokens
- `lib/src/ui/issue_card.dart` — use spacing tokens
- `lib/src/ui/trigger_button.dart` — use spacing tokens
- `lib/src/ui/guide_page.dart` — use spacing tokens
- `test/ui/sleuth_theme_test.dart` — spacing token tests

**Risk:** Low. Visual change — verify overlay looks identical with default spacing values.

**Post-Implementation Notes:**
- Expanded from 5 to 6 tokens: added `spacingXxs = 2` (7 instances in codebase). The 2/4/6/8/12/16 scale matches standard Tailwind compact spacing.
- Value 10 (8 instances, mostly banners/headers) left hardcoded — doesn't fit the 2/4/6/8/12/16 scale cleanly.
- Values 1, 3, 5, 14, 20, 22, 24 left hardcoded as micro-adjustments or context-specific spacing.
- ~67 of 105 spacing instances tokenized (the 6 most common values).
- `const` removal accepted as trade-off: `const EdgeInsets.all(8)` → `EdgeInsets.all(theme.spacingMd)`. Impact negligible for diagnostic overlay.
- Spacing is theme-independent: both dark and light constructors use identical spacing defaults.
- `_categoryChip` static method in guide_page.dart lacks `theme` parameter — left hardcoded rather than adding a parameter for one 2px value.
- `_buildIssuesList` in floating_issues_card.dart: hoisted `theme` variable out of `if (issues.isEmpty)` block to make it available in the non-empty branch.
- highlight_overlay.dart and sleuth_overlay.dart: no EdgeInsets/SizedBox spacing values to tokenize.
- 1,294 tests pass, 0 analysis issues.

---

### v6.22: Benchmark Test Robustness ✅ Shipped

**Problem:** Benchmark tests use wall-clock `Stopwatch` measurements with fixed budgets. On loaded CI runners or slower devices, tests flake because actual timing varies. The warmup period (5 iterations) may be insufficient for JIT compilation.

**Approach:**
1. Increase warmup from 5 to 20 iterations
2. Add `budgetMultiplier` (2x on CI) via `Platform.environment` detection
3. Add `BenchmarkResult` class with min/max/stdDev/coefficientOfVariation
4. Add `benchmarkWithStats()` function returning `BenchmarkResult`
5. Apply `budgetMultiplier` to all 3 benchmark test files

**Files changed:**
- `test/helpers/benchmark_helpers.dart` — add `BenchmarkResult`, `benchmarkWithStats()`, `budgetMultiplier`, increase warmup
- `test/benchmark/scan_overhead_test.dart` — apply `budgetMultiplier` to budgets
- `test/benchmark/v2_overhead_test.dart` — apply `budgetMultiplier` to budgets
- `test/benchmark/timeline_processing_test.dart` — apply `budgetMultiplier` to budgets

**Risk:** Very low. Test infrastructure only.

**Post-Implementation Notes:**
- Used `Platform.environment` from `dart:io` instead of `bool.hasEnvironment` — the latter only detects `--dart-define` values, not shell env vars that CI systems set.
- `benchmarkUs()` signature unchanged (returns `double`) for backwards compatibility with 30+ call sites.
- `memory_footprint_test.dart` has no timing budgets — not modified.

---

### v6 Implementation Order

| Priority | Milestone | Effort | Theme | Dependencies |
|----------|-----------|--------|-------|--------------|
| 1 | v6.1: Controller Async Safety | Medium | Safety | None | **Shipped** |
| 2 | v6.14: Error Logging | Low | Safety | None (subset of v6.1) | **Shipped** (done in v6.1) |
| 3 | v6.2: OpacityDetector AnimatedOpacity | Low | Accuracy | None | **Shipped** |
| 4 | v6.3: GpuPressure ShaderMask | Very Low | Accuracy | None | **Shipped** |
| 5 | v6.4: NestedScroll Highlights | Low | Accuracy | None | **Shipped** |
| 6 | v6.5: Tap Targets | Low | UI Polish | None | **Shipped** |
| 7 | v6.6: Drag Clamping | Low | UI Polish | None | **Shipped** |
| 8 | v6.7: Keyboard Awareness | Low | UI Polish | None | **Shipped** |
| 9 | v6.8: Listener Dedup | Very Low | UI Polish | None | **Shipped** |
| 10 | v6.9: Text Overflow | Very Low | UI Polish | None | **Shipped** |
| 11 | v6.10: FloatingIssuesCard Extract | Low | UI Polish | v6.6 (shared helper) | **Shipped** |
| 12 | v6.11: IssueCard Extract | Low | UI Polish | None | **Shipped** |
| 13 | v6.12: GuidePage Back Nav | Very Low | UI Polish | None | **Shipped** |
| 14 | v6.13: Model Equality | Low | Safety | None | **Shipped** |
| 15 | v6.15: Suppression Precompile | Very Low | Performance | None | **Shipped** |
| 16 | v6.16: Platform Declarations | Very Low | Pub.dev | None | **Shipped** |
| 17 | v6.17: Controller Lifecycle Tests | Medium | Tests | v6.1 (tests the fixes) | **Shipped** |
| 18 | v6.18: UI Widget Tests | Medium | Tests | v6.5–v6.12 (tests after refactor) | **Shipped** |
| 19 | v6.19: ListView Threshold | Very Low | Accuracy | None | **Shipped** |
| 20 | v6.20: TriggerButton Position | Very Low | UI Polish | None | **Shipped** |
| 21 | v6.21: Spacing Tokens | Medium | UI Polish | None | **Shipped** |
| 22 | v6.22: Benchmark Robustness | Low | Tests | None | **Shipped** |

All 22 v6 milestones shipped in **v0.8.0**.

---

