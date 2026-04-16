# spec v0.15.3 — RepaintDetector animation filter (M1)

**Status:** plan, not yet implemented. Targets Sleuth v0.15.3, the first calibration-pass release after v0.15.2. Single-milestone scope: M1 from `doc/detector_threshold_audit.md` §7 — RepaintDetector is the only detector with no animation-aware filter, and is the highest-leverage fix surfaced by the pass-2 grill of the threshold audit.

**Source:** `doc/detector_threshold_audit.md` §7.2 M1 ("Asymmetric animation filter — Repaint vs Rebuild").

**Out of scope for v0.15.3 (deferred to follow-ups):**
- Transition widgets (`RotationTransition`, `FadeTransition`, etc.) — `widget_location.dart:_frameworkNames` strips them from ancestor chains, so chain-containment cannot see them. Coordinator-side capture changes are needed first.
- Pure-VM mode coverage (no `DebugSnapshot`) — Gate B without per-widget data has no chain to inspect; deferred until a separate VM-side widget attribution path exists.
- RebuildDetector's latent generics bug (`_builderWidgetTypes` set entries fail to match `ValueListenableBuilder<int>` because `_typeName()` does not strip generics in the rebuild path) — separate detector, separate fix, tracked but not in this milestone.
- ImageMemoryDetector measurement-semantics rework (audit §7.1).
- NetworkMonitor `slowThresholdMs` two-constant fix.
- FrameTimingDetector frame-count → duration-based warmup.

These are pinned in **Remaining Notes** at the bottom for future milestones.

---

## 1. Goal

Suppress false-positive `excessive_repaint`, `excessive_repaint_debug`, and `repaint_debug_*` issues when the rapidly-painting widget is inside the subtree of a known intentional animation widget. After the fix:

- A screen with a `CircularProgressIndicator` (or `LinearProgressIndicator`, `RefreshProgressIndicator`, `CupertinoActivityIndicator`) painting at 60 Hz must **not** fire any `repaint_*` issue.
- A screen with a user-built `AnimatedBuilder`, `ValueListenableBuilder`, or `TweenAnimationBuilder` whose painted child is one of the above three must **not** fire.
- A screen with an actually-pathological repaint (e.g. an unbatched `setState` driving a non-animation `CustomPaint` at 60 Hz) **must still fire** — the filter must not silently mask real bugs.

---

## 2. The fatal Phase-6 finding the draft missed

The original draft assumed `snapshot.paintCounts` would contain keys like `'CircularProgressIndicator'`, `'AnimatedBuilder'`, etc., and would key-match against a 17-entry filter set. Source verification refuted this:

- `RenderObject.debugCreator` is set on `RenderObjectElement`s — i.e. the nearest ancestor of the `RenderObject` that *has* a render object. `CircularProgressIndicator` is a `StatefulWidget` whose tree is `Builder → AnimatedBuilder → ConstrainedBox → CustomPaint → RenderCustomPaint`. The first `RenderObjectWidget` is `ConstrainedBox`/`CustomPaint`, so the painted `RenderObject`'s creator element is the `CustomPaint` element.
- `_handleProfilePaint` (`debug_instrumentation_coordinator.dart:601`) keys the count on `creator.element.widget.runtimeType` — verified as `'CustomPaint'`, **not** `'CircularProgressIndicator'`.
- `_typeName()` (`debug_instrumentation_coordinator.dart:90`) does not canonicalize. `_handleProfilePaint` does not call `canonicalizeTypeName`.

Verified against:
- `~/fvm/versions/stable/packages/flutter/lib/src/material/progress_indicator.dart:1162-1180` — the `_buildMaterialIndicator` body is `ConstrainedBox(child: CustomPaint(painter: _CircularProgressIndicatorPainter()))`. There is no intermediate `RenderObjectWidget` between `CustomPaint` and the `RenderCustomPaint`.

**Conclusion:** key-matching against `paintCounts` does not work. The plan must instead inspect the **ancestor chain** captured alongside each paint sample, because the chain DOES walk up through the user-named animation widget. The chain-containment approach is the rewrite that follows.

---

## 3. Key design decisions

### KDD-1 — Chain-containment, not key-containment

The filter checks `snapshot.ancestorChains[typeName]` (a precomputed string like `"HomePage > CircularProgressIndicator > AnimatedBuilder > ConstrainedBox > CustomPaint"`) and asks: "does this string contain any animation-owner widget name?" Match on word boundary so `AnimatedBuilder` does not also match an unrelated `CustomAnimatedBuilderUtility`.

This works because the chain is captured at *paint time* via `buildAncestorChain(creator.element)` — the same element that owned the paint. The chain walks up the user code and includes the intentional animation owner.

### KDD-2 — Filter set narrowed to 7 entries

`widget_location.dart:_frameworkNames` strips many candidate filter widgets from the ancestor chain entirely. There is no point putting strings in the filter set that the chain will never contain. The 7-entry set:

```dart
static const _animationOwnerNames = <String>{
  // Material / Cupertino built-in indicators
  'CircularProgressIndicator',
  'LinearProgressIndicator',
  'RefreshProgressIndicator',
  'CupertinoActivityIndicator',
  // Generic builder pattern (user-driven animations)
  'AnimatedBuilder',
  'ValueListenableBuilder',
  'TweenAnimationBuilder',
};
```

**Excluded and why:**
- `Ticker`, `AnimationController` — not widgets, never appear in chain.
- `RotationTransition`, `FadeTransition`, `ScaleTransition`, `SizeTransition`, `SlideTransition`, `PositionedTransition`, `DecoratedBoxTransition`, `FractionalTranslation` — stripped by `widget_location.dart:_frameworkNames`. **Defer to follow-up:** either remove from the strip set (changes ancestor chain output for every detector) or capture a parallel un-stripped chain just for this filter. Both are bigger than v0.15.3.
- `Builder`, `ListenableBuilder` — also stripped. Less critical; users wrapping an animation in a plain `Builder` is rare.
- `StreamBuilder`, `FutureBuilder`, `StreamBuilderBase` — these are async-data builders, not animation drivers. Including them would suppress real repaint pathologies driven by streams.

### KDD-3 — Three-gate coverage with one helper

RepaintDetector has three firing gates (`repaint_detector.dart:213-230`). The filter must apply at each:

| Gate | Method | Filter strategy |
|---|---|---|
| **A** per-widget debug | `_evaluateDebugDataPerWidget` | **Skip** the typeName when its chain matches. Issue is keyed per-widget so we just don't emit. |
| **B** VM aggregate | `_evaluateVmData` | **Fallthrough** — no per-widget data on this path. Suppress only when `_allPaintsAnimationOwned(snapshot)` returns true (every type in `paintCounts` matches the filter). Otherwise fire normally. |
| **C** debug aggregate | `_evaluateDebugData` | **Subtract** the per-type counts of matched types from `totalPaintCount`, recompute `paintsPerSecond` against remaining counts, suppress if the remainder is below threshold. |

One private helper performs the chain check; gates A and C call it per-type, gate B calls a roll-up wrapper.

### KDD-4 — Full exemption (not a 3× multiplier)

RebuildDetector uses a `× 3` threshold multiplier for its `_builderWidgetTypes` set. RepaintDetector takes a stronger position: full exemption when the chain matches. Reason:

- A `CircularProgressIndicator` paints once per frame, by design. There is no "paint rate" that is too high for it to be a bug — it's the `Curves.linear` rotation. A 3× multiplier would still fire on 120 Hz devices.
- The cost of a false negative (a real repaint bug behind a `CircularProgressIndicator`-decorated screen) is bounded: the underlying widget would still surface via `excessive_rebuild`, `setstate_scope`, `repaint_debug_<other_type>`, or VM-thread saturation if it were truly pathological.
- The cost of a false positive (a per-session `CircularProgressIndicator` warning that erodes Sleuth's credibility) is unbounded: see audit §C4.

Documented inline in the helper as a deliberate asymmetry vs RebuildDetector.

### KDD-5 — `confidenceReason` updated to disclose the filter

Every issue RepaintDetector emits gains an updated `confidenceReason` string:

```
"Animation-driven widgets (CircularProgressIndicator, AnimatedBuilder, …) are exempt from this rate."
```

So when a real bug fires, the user sees what the detector did *not* count, building trust in the remaining count.

### KDD-6 — Polymorphic-key honesty

The chain captured for a typeName is captured **on first occurrence** (`debug_instrumentation_coordinator.dart:584`, `:607`). If two distinct `CustomPaint` widgets appear in the same window — one inside a `CircularProgressIndicator`, one that is a user's static decoration — they share the key `'CustomPaint'` and the cached chain reflects whichever was seen first. The filter will then either:

- Suppress both (false negative) if the indicator was first.
- Suppress neither (false positive — current behavior) if the decoration was first.

**Decision:** accept the limitation, document it, and add a **chain-recapture fallback** as a follow-up. For v0.15.3 the filter is correct on the *common* case (one polymorphic key, one ancestor) and silent on the rare case (collision). Documented in the helper docstring and surfaced as a deferred follow-up in **Remaining Notes**.

The alternative (capture every chain seen for a key, not just the first) requires changing coordinator semantics, increases per-paint allocation, and has cross-detector blast radius. Out of scope for v0.15.3.

---

## 4. Implementation steps

Follow this order — each step lands a self-contained change that compiles and passes existing tests.

### Step 1 — Add the filter set + helper

`lib/src/detectors/repaint_detector.dart`:

```dart
/// Widget type names that drive intentional, frame-rate animations.
/// When any of these appears in a paint's ancestor chain, the paint
/// is exempt from `excessive_repaint*` and `repaint_debug_*` firing.
///
/// **Deliberate asymmetry vs RebuildDetector**: RebuildDetector uses
/// a 3× multiplier for its `_builderWidgetTypes` set; RepaintDetector
/// is full-exemption. See spec_v0_15_3 KDD-4 for rationale.
///
/// **Polymorphic-key limitation (KDD-6)**: the ancestor chain is
/// captured on first occurrence per `typeName` key. If two distinct
/// `CustomPaint` widgets share the key, the chain reflects whichever
/// was seen first. Accepted limitation; chain-recapture is a follow-up.
@visibleForTesting
static const animationOwnerNames = <String>{
  'CircularProgressIndicator',
  'LinearProgressIndicator',
  'RefreshProgressIndicator',
  'CupertinoActivityIndicator',
  'AnimatedBuilder',
  'ValueListenableBuilder',
  'TweenAnimationBuilder',
};

// Word-boundary regex over the union, computed once.
static final _animationOwnerRegex = RegExp(
  r'\b(' + animationOwnerNames.join('|') + r')\b',
);

/// Returns true if the cached ancestor chain for [typeName] contains
/// any animation-owner name. Returns false when no chain is captured
/// (defaults to firing — preserves current behavior).
bool _isAnimationOwned(DebugSnapshot snapshot, String typeName) {
  final chain = snapshot.ancestorChains[typeName];
  if (chain == null) return false;
  return _animationOwnerRegex.hasMatch(chain);
}
```

Marked `@visibleForTesting` to allow tests to assert the membership table directly.

### Step 2 — Gate A: skip on match

`_evaluateDebugDataPerWidget` (`repaint_detector.dart:266`). Inside the `for (final entry in snapshot.paintCounts.entries)` loop, after computing `rate` but before the `_issues.add(…)` call, add:

```dart
if (_isAnimationOwned(snapshot, entry.key)) continue;
```

### Step 3 — Gate B fallthrough wrapper

Add a helper to check whether **every** non-zero entry in `paintCounts` is animation-owned:

```dart
bool _allPaintsAnimationOwned(DebugSnapshot snapshot) {
  if (snapshot.paintCounts.isEmpty) return false;
  for (final entry in snapshot.paintCounts.entries) {
    if (entry.value <= 0) continue;
    if (!_isAnimationOwned(snapshot, entry.key)) return false;
  }
  return true;
}
```

Returns false when there's no per-widget data (no chains to inspect → preserve current behavior, do not silently mask).

### Step 4 — Gate B: suppress when fully owned

In `_evaluate()` (`repaint_detector.dart:213-230`), the `if (_issues.isEmpty && hasFreshVm && vmWindowCount > 0)` branch dispatches into `_evaluateVmData`. Wrap the call:

```dart
if (_issues.isEmpty && hasFreshVm && vmWindowCount > 0) {
  if (hasFreshDebug && _allPaintsAnimationOwned(debugSnapshot)) {
    // All per-widget activity is animation-owned; do not fire VM aggregate.
  } else {
    _evaluateVmData(vmWindowCount, enrichedDirtyTotal);
  }
}
```

The `hasFreshDebug` guard is critical: without per-widget data, we have no chains to inspect, so we must NOT silently suppress the VM gate (false negative on pure-VM mode users). Pure-VM mode coverage is deferred (see Remaining Notes).

### Step 5 — Gate C: subtract animation-owned counts

`_evaluateDebugData` (`repaint_detector.dart:306`) uses `snapshot.totalPaintCount` and `snapshot.paintsPerSecond`. These include animation-owned paints. Replace with a residual computation:

```dart
void _evaluateDebugData(DebugSnapshot snapshot) {
  final ownedCount = _animationOwnedCount(snapshot);
  final residualCount = snapshot.totalPaintCount - ownedCount;
  if (residualCount <= 0) return;
  final us = snapshot.elapsed.inMicroseconds;
  if (us == 0) return;
  final residualRate =
      residualCount / (us / Duration.microsecondsPerSecond);
  if (residualRate < paintFrequencyThreshold) return;
  // … existing issue construction, but using residualRate / residualCount
  //   in the title/detail strings
}

int _animationOwnedCount(DebugSnapshot snapshot) {
  var n = 0;
  for (final entry in snapshot.paintCounts.entries) {
    if (_isAnimationOwned(snapshot, entry.key)) {
      n += entry.value;
    }
  }
  return n;
}
```

The subtraction is conservative: any paint without a chain (or whose chain is empty) is **not** subtracted, so the worst case is the current behavior.

### Step 6 — Update `confidenceReason` strings

All three gates' issue construction sites get an updated `confidenceReason`:

```
'Aggregate paint rate excludes animation-driven widgets '
'(CircularProgressIndicator, AnimatedBuilder, …).'
```

For Gate A, the per-widget reason becomes:

```
'Direct widget attribution — non-animation widgets only.'
```

### Step 7 — Real-widget falsification test

`test/detectors/repaint_detector_test.dart` — add a new `group('animation-owner suppression')` with a real-widget pump test (not a fixture-only test):

```dart
testWidgets('CircularProgressIndicator does not fire excessive_repaint',
    (tester) async {
  // Install the coordinator under test (see step 8 for harness)
  // Pump a screen containing a single CircularProgressIndicator
  // Pump 100 frames so paint counts accumulate
  // Run a scan on the detector
  // Assert: detector.issues is empty
});
```

This is the **anti-tautology** test (adversarial-investigation Tactic 9). Hand-rolled fixtures with author-chosen keys are confirmation-bias machines; this test runs the whole pipeline against a real Flutter widget tree, so the keys are whatever Flutter actually produces — not what the test author thinks they should be.

### Step 8 — Test infra feasibility check (PREREQUISITE for step 7)

Before writing step 7's pumped-widget test, verify that the existing test harness supports:

- Installing a `DebugInstrumentationCoordinator` in widget-test mode (`testWidgets` runs in `kDebugMode == true`, which is the only mode `_handleProfilePaint` is available — the path is gated on `enableDeepDebugInstrumentation` regardless of mode, but the test must drive paints).
- Pumping enough frames to accumulate `paintCounts` and capture an `ancestorChains` entry.
- Producing a `DebugSnapshot` from the live coordinator and feeding it to `RepaintDetector.updateDebugSnapshot()`.

The existing `test/helpers/rebuild_capture_helpers.dart` (added in v0.15.0) is the closest precedent — read it first. If the harness exists, step 7 is straightforward. If it doesn't, either:

(a) extend the harness with a paint-capture variant, OR
(b) downgrade step 7 to a fixture-style test where the fixture is **constructed from a real captured chain** (run a one-shot script during plan execution that pumps the widget, prints the chain, and pastes it into the test as a const string). Option (b) is weaker but acceptable as long as the chain string is captured from real widget output rather than guessed.

**Action item for implementation:** read `test/helpers/rebuild_capture_helpers.dart` first thing. Decision (a) vs (b) is internal-to-implementation, not a user-decision.

### Step 9 — Hand-rolled fixture tests for the helper logic

In addition to the real-widget test, add fast unit tests for the helper's branches:

1. `_isAnimationOwned` returns true for a chain containing `'CircularProgressIndicator'`.
2. Returns true for a chain containing `'AnimatedBuilder'`.
3. Returns true for a chain containing both.
4. Returns false for a chain containing none.
5. Returns false for `null` chain (no entry).
6. Returns false for a chain containing `'CustomAnimatedBuilderUtility'` (word-boundary defense).
7. Gate A: per-widget loop skips animation-owned entries.
8. Gate B: `_allPaintsAnimationOwned` returns true when every entry matches; false when one doesn't.
9. Gate C: residual computation suppresses when subtraction drops below threshold; fires when it doesn't.
10. The full membership table (`animationOwnerNames` size == 7, exact contents).

These tests are fixture-based and use hand-rolled chain strings — they validate the helper against itself, which is fine *for the helper logic*. Test #7 is the real-widget test from step 7.

### Step 10 — Update the audit document

`doc/detector_threshold_audit.md` §1 row 2 (RepaintDetector): change verdict from `🔧 ²⬆` to `✅ shipped v0.15.3` with a one-line note linking to this spec. Same in §7.1 RepaintDetector row.

§7.2 M1 — append a closing line: "**Shipped in v0.15.3** as chain-containment filter. See `doc/spec_v0_15_3_repaint_animation_filter.md`."

### Step 11 — CHANGELOG, CLAUDE.md, encyclopedia

- `CHANGELOG.md` — new `## v0.15.3` section: "RepaintDetector animation-aware filter (audit §7 M1). Adds chain-containment exemption for the 7 most common animation drivers. Closes the v0.15.2 false-positive loop on screens with `CircularProgressIndicator`."
- `CLAUDE.md` — new bullet under Current state pointing to v0.15.3.
- `lib/src/utils/issue_explanation_builder.dart` — encyclopedia entries for `excessive_repaint`, `excessive_repaint_debug`, and `repaint_debug` get a new "What this detector excludes" section listing the 7 animation owners.

---

## 5. Files changed

| Path | Change | Lines (est.) |
|---|---|---|
| `lib/src/detectors/repaint_detector.dart` | Add filter set, regex, helper, three gate integrations | ~60 |
| `lib/src/utils/issue_explanation_builder.dart` | Append exclusion note to 3 encyclopedia entries | ~15 |
| `test/detectors/repaint_detector_test.dart` | New `animation-owner suppression` group: 10 unit tests + 1 widget test | ~180 |
| `doc/detector_threshold_audit.md` | Mark M1 shipped in §1, §7.1, §7.2 | ~6 |
| `CHANGELOG.md` | New `## v0.15.3` section | ~10 |
| `CLAUDE.md` | Current-state bullet | ~3 |
| `pubspec.yaml` | Bump to `0.15.3` | 1 |

**Not changed:** `debug_instrumentation_coordinator.dart` (chains are already captured, see §3 KDD-1 evidence in §2). `widget_location.dart` (its strip set stays as-is; transition coverage is deferred). `rebuild_detector.dart` (asymmetric on purpose, see KDD-4).

---

## 6. Risk summary

| # | Risk | Severity | Likelihood | Mitigation |
|---|---|---|---|---|
| R1 | Polymorphic key collision (KDD-6): two `CustomPaint` types share the key, suppression is wrong-handed | Medium | Low | Documented limitation; chain-recapture deferred |
| R2 | Pure-VM mode users get no benefit (no chains → Gate B unfiltered) | Low | Medium | Explicit `hasFreshDebug` guard on Gate B; documented |
| R3 | Transition widgets (`RotationTransition` etc.) still fire | Medium | Medium | Deferred — strip-set rework needed first |
| R4 | Word-boundary regex false-match on a user widget literally named `AnimatedBuilder2` | Low | Very Low | `\b…\b` boundaries protect against this; test #6 asserts |
| R5 | A real repaint bug behind a `CircularProgressIndicator`-decorated screen is silently suppressed | Medium | Low | Surfaces via parallel detectors (`excessive_rebuild`, `setstate_scope`, VM-thread saturation); documented in `confidenceReason` |
| R6 | `_animationOwnerRegex` rebuilt on every `_isAnimationOwned` call | Low | High (perf) | `static final` ensures one-time construction |
| R7 | Step 7 widget test cannot be written because harness doesn't support paint capture | Medium | Medium | Step 8 prerequisite mandates harness check first; fallback to captured-chain fixture |
| R8 | `confidenceReason` string changes break existing snapshot tests | Low | High | Update test fixtures in same change; no semantic impact |

---

## 7. Open questions

1. **Step 8 outcome — does the test harness already support coordinator-installed paint capture?** Internal to implementation. If yes → step 7 is a clean widget test. If no → fall back to a chain-captured fixture (still real data, just collected via a one-shot script). Resolved during implementation.

(No user-decision questions remain. KDD decisions §3.1–§3.6 are all defended in the body.)

---

## 8. Test specifications (full)

**Unit tests** (10) in `test/detectors/repaint_detector_test.dart` `group('animation-owner suppression')`:

| # | Name | Asserts |
|---|---|---|
| T1 | `chain with CircularProgressIndicator suppresses` | `_isAnimationOwned` returns true |
| T2 | `chain with AnimatedBuilder suppresses` | true |
| T3 | `chain with both suppresses` | true |
| T4 | `chain with no animation owner does not suppress` | false |
| T5 | `null chain does not suppress (default-fire)` | false |
| T6 | `partial-match string does not falsely suppress` | `'CustomAnimatedBuilderUtility'` returns false |
| T7 | `Gate A: per-widget loop emits zero issues for animation-owned typename` | `detector.issues` empty |
| T8 | `Gate B: _allPaintsAnimationOwned returns true iff every entry matches` | both branches |
| T9 | `Gate C: residual subtraction suppresses below threshold and fires above` | both branches |
| T10 | `animationOwnerNames membership table is the locked 7 entries` | `Set` equality |

**Widget test** (1):

| # | Name | Asserts |
|---|---|---|
| W1 | `real CircularProgressIndicator pumped through the coordinator does not fire excessive_repaint` | `detector.issues.where((i) => i.stableId.startsWith('repaint'))` is empty after 100 frames |

**Regression check** — re-run all 36 existing repaint detector tests; none should break. The change is additive (new exemption path) on the firing side and adjusts `confidenceReason` strings (which have low test coverage).

---

## 9. Verification commands

```bash
# unit + widget tests for the changed detector
fvm flutter test test/detectors/repaint_detector_test.dart

# full suite
fvm flutter test

# static analysis (must be 0)
fvm flutter analyze

# example app smoke-test (CircularProgressIndicator demo)
cd example && fvm flutter test
```

**Real-device falsification** (must run before merge): `cd example && fvm flutter run --profile`, navigate to a screen with a `CircularProgressIndicator`, observe the Sleuth overlay for ~30 seconds. Expected: zero `repaint_*` issues. Compare against v0.15.2 baseline on the same screen.

---

## 10. Plan Review Pass

Phase 6 of `/deep-plan` ran `/adversarial-review` on the draft of this plan. The findings table below records the review's output and how the rewrite folded each finding in. **Single invocation:** Phase 6 ran during planning; only one *additional* invocation happens during implementation (the post-implementation pass at the end of step 11).

| # | Severity | Finding | Resolution |
|---|---|---|---|
| C1 | Critical | Filter assumed `paintCounts` keys would be `'CircularProgressIndicator'` etc.; verification proved keys are `'CustomPaint'` (nearest RenderObjectWidget). Key-matching is fundamentally wrong. | **Plan rewritten.** Chain-containment via `snapshot.ancestorChains` replaces key-matching. KDD-1 documents the source verification. |
| C2 | Critical | Tests used hand-written fixtures whose authors picked the keys — testing the code against itself, not against reality (fixture tautology). | Step 7 (real-widget pump) added; step 8 (test infra prerequisite) added; KDD-6 explicitly addresses the polymorphic-key collision. |
| H1 | High | Filter set assumed widgets that `widget_location.dart` strips would survive in the chain. | Filter set narrowed from 17 to 7. KDD-2 justifies each excluded widget. |
| H2 | High | Gate B (VM aggregate) had no path to inspect chains — silent miss when per-widget data was unavailable. | KDD-3 + step 4: explicit `hasFreshDebug` guard; pure-VM mode deferred to Remaining Notes. |
| H3 | High | Gate C (debug aggregate) used unmodified `paintsPerSecond` — animation owners would still inflate the rollup. | Step 5: residual subtraction. |
| M1 | Medium | The `_animationOwnerRegex` was constructed inside `_isAnimationOwned`, allocating per call. | KDD-1 + step 1: `static final` regex computed once. |
| M2 | Medium | Word-boundary semantics not asserted — `'AnimatedBuilder2'` could partial-match. | Test T6 added; `\b…\b` boundaries on the regex. |
| M3 | Medium | `confidenceReason` strings did not disclose the filter — users would lose trust in the *remaining* count. | KDD-5 + step 6: explicit disclosure in all three gates. |
| L1 | Low | RebuildDetector latent generics bug noticed during cross-detector review (`_typeName()` in rebuild path doesn't strip generics). | Out of scope; pinned in Remaining Notes. |
| L2 | Low | Severity asymmetry vs RebuildDetector (3× multiplier vs full exemption) was unjustified in the draft. | KDD-4 added explicit defense. |

**Adversarial plan-review finding count: 10** (2 Critical, 3 High, 3 Medium, 2 Low). All folded in. The Critical findings forced a full plan rewrite — the version above is the rewrite, not a patched draft.

---

## 11. Adversarial review scope (post-implementation)

After step 11 lands, run `/adversarial-review` ONE additional time over this scope:

**In scope:**
- `lib/src/detectors/repaint_detector.dart` (the diff)
- `lib/src/utils/issue_explanation_builder.dart` (entries for `excessive_repaint*`, `repaint_debug`)
- `test/detectors/repaint_detector_test.dart` (the `animation-owner suppression` group)

**Transitive in scope** (will be exercised in new ways):
- `lib/src/debug/debug_instrumentation_coordinator.dart` `_handleProfilePaint` and `_ancestorChains` — confirm that the existing capture semantics hold under the test harness used in step 7/W1.
- `lib/src/utils/widget_location.dart` `_frameworkNames` — confirm strip-set still produces chains containing the 7 animation owner names. Risk R3 documented as a known gap.

**Out of scope:**
- Other detectors (RebuildDetector latent generics bug — pinned).
- Coordinator paint-capture rework.
- Strip-set rework for transition widgets.

The single post-implementation review is the one mentioned in step 11 above. There are no other invocations.

---

## 12. Remaining notes / deferred follow-ups

These were surfaced during plan synthesis but are not part of v0.15.3:

1. **Transition widget coverage.** `RotationTransition`, `FadeTransition`, `ScaleTransition`, etc. are stripped by `widget_location.dart:_frameworkNames`. To support them, either (a) remove those entries from the strip set (broad blast radius — every detector's ancestor chain output changes), or (b) add a parallel un-stripped-chain field on `DebugSnapshot` for the filter. Choice deferred to v0.15.4+ along with audit findings on other detectors.
2. **Chain-recapture for polymorphic keys (KDD-6).** Capture every distinct chain seen for a `typeName`, not just the first. Closes R1. Cross-detector consequences need scoping.
3. **Pure-VM mode coverage (R2).** Without a `DebugSnapshot`, Gate B has no chains. A separate VM-side widget attribution path is needed.
4. **RebuildDetector latent generics bug.** `_builderWidgetTypes` set entries are bare strings (`AnimatedBuilder`), but `_rebuildCounts` is keyed by `_typeName()` which does not strip generics. `ValueListenableBuilder<int>` silently fails the membership check. Separate detector, separate fix; tracked here so it isn't lost.
5. **Other audit §7 actions.** ImageMemoryDetector measurement-semantics fix (§7.1), NetworkMonitor `slowThresholdMs` two-constant change, FrameTimingDetector frame-count → duration warmup, MemoryPressureDetector GC-rate threshold + young/old-space split. All ranked behind M1 because their fix is mechanically simpler but their leverage is lower.
