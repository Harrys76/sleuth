## v8 Roadmap: Accuracy & Correctness Fixes

Origin: Codex adversarial review (2026-03-31) identified 5 issues in detector accuracy, scan-path assumptions, and resource lifecycle. One finding (correlator trust metric) was verified as a misread and excluded.

---

### v8.1: SetState Subtree Count — O(N^2) → O(N) ✅ Shipped

**Effort:** Low | **Theme:** Performance | **Impact:** Removes self-inflicted jank on large trees

**Problem:** `SetStateScopeDetector.checkElement()` (lines 143-150) recursively counts the entire subtree below every non-framework `StatefulElement`. For a tree with S stateful widgets and N total elements, this is O(S×N) — effectively O(N^2). Since scans run on the UI thread every 1s, the sleuth can create its own jank on large trees.

**Current code (setstate_scope_detector.dart:143-150):**
```dart
int subtreeSize = 0;
void countSubtree(Element child) {
  subtreeSize++;
  child.visitChildren(countSubtree);
}
element.visitChildren(countSubtree);
```

This nested walk inside `checkElement` defeats the v7.9 unified O(N) tree walk.

**Fix:** Use `afterElement` (post-order callback) with a stack-based subtree size accumulator and **inline max tracking** — no per-element map:

1. Add `List<int> _subtreeSizeStack` instance variable (stack only — no `Map<Element, int>`).
2. Repurpose existing scalar fields: `int _maxSubtreeSize` (line 67), `String? _widestStatefulWidget` (line 68), `Element? _widestElement` (line 69). All three already exist and are reset in `prepareScan`. No new fields needed except the stack.
3. In `prepareScan`: clear the stack. The existing resets (`_maxSubtreeSize = 0`, `_widestStatefulWidget = null`, `_widestElement = null` at lines 106-108) already handle the scalar fields.
4. In `checkElement`: push 0 onto `_subtreeSizeStack` (start counting children for this element).
5. In `afterElement`: pop from stack to get this element's subtree size, add `childSubtreeSize + 1` to parent's running total (peek at stack top). The `+1` counts the element itself — without it, leaves stay at 0 and parents only accumulate grandchildren, undercounting the entire tree. **Track max inline:** if the element is a `StatefulElement`, passes the private-name and framework-widget exclusions (same filters as existing `checkElement` lines 117-120: `!name.startsWith('_') && !isFrameworkWidget(widget)`), and `subtreeSize > _maxSubtreeSize`, update `_maxSubtreeSize`, store the name in `_widestStatefulWidget` (String) and the element in `_widestElement` (Element). No map storage needed.
6. In `finalizeScan`: use `_maxSubtreeSize` / `_widestStatefulWidget` / `_widestElement` directly — no lookup required. `finalizeScan` already uses `_widestStatefulWidget` as a String (lines 172, 178, 190, 203, 210) and `_widestElement` as an Element (lines 174, 182, 217, 247).

```dart
// In afterElement:
final subtreeSize = _subtreeSizeStack.removeLast();
if (_subtreeSizeStack.isNotEmpty) {
  _subtreeSizeStack.last += subtreeSize + 1;
}
// Track max inline — no element-keyed map needed.
// Preserve the same filters as the existing checkElement (lines 117-120):
// skip private-named and framework-owned StatefulWidgets so that
// Scaffold, Navigator, Overlay, etc. never become the "widest" candidate.
if (element is StatefulElement && subtreeSize > _maxSubtreeSize) {
  final name = element.widget.runtimeType.toString();
  if (!name.startsWith('_') && !isFrameworkWidget(element.widget)) {
    _maxSubtreeSize = subtreeSize;
    _widestStatefulWidget = name;    // String — used by finalizeScan for display/lookup
    _widestElement = element;         // Element — used for highlights/animation check
  }
}
```

This computes all subtree sizes in a single O(N) post-order pass. The stack is populated and fully drained within a single scan — no per-scan element references survive in the stack. This avoids the memory retention hazard of a `Map<Element, int>`: the controller's navigation early-return path (sleuth_controller.dart:608-624) returns before `prepareScan` runs, so a per-element map would retain the previous page's entire element graph until the next successful scan. With stack-only + scalar fields, the stack itself retains nothing.

**Retention closure for `clearSnapshots()`:** The scalar field `_widestElement` (Element?) survives navigation aborts: the early-return path (lines 608-624) calls `clearSnapshots()` (lines 94-98) which clears `_childSnapshots` and `_rebuildEvidence` but does NOT null `_widestElement` or `_widestStatefulWidget`. Since `prepareScan` (which does reset them at lines 106-108) only runs during a successful scan, `_widestElement` can retain the previous page's element graph across aborted scans — the same class of retention hazard that motivates eliminating the per-element map. **Fix:** Expand `clearSnapshots()` to also null both fields:

```dart
void clearSnapshots() {
  _childSnapshots.clear();
  _rebuildEvidence.clear();
  _evidenceWindowStart = DateTime.now();  // ← preserve existing reset
  _widestElement = null;          // ← add
  _widestStatefulWidget = null;   // ← add
}
```

This ensures no element reference survives across navigation-abort cycles, closing the retention gap completely.

**Key detail:** `afterElement` is called after `element.visitChildren(visitor)` in the unified walk (sleuth_controller.dart:790-792), confirming post-order semantics.

**Files:** `lib/src/detectors/setstate_scope_detector.dart` (~30 lines changed + `clearSnapshots()` expansion), `test/detectors/setstate_scope_detector_test.dart` (existing tests should pass unchanged — behavioral contract is identical).

**Risk:** Low. Same issues emitted, same thresholds, same confidence. Only the subtree size computation method changes. The `clearSnapshots()` expansion ensures no element references are retained between scans — including across navigation-abort cycles.

**Post-Implementation Notes (2026-04-02):**
- 1,313 tests pass (3 new: abort safety × 2, clearSnapshots retention), 0 analysis issues
- Survived 5 Codex adversarial reviews — each review drove a hardening fix:
  - Review 1: Stack-empty check missed first-element throws → moved `_totalElements == 0` guard above snapshot swap
  - Review 2: Between-siblings abort left stack empty with partial data → added `notifyWalkCompleted()` explicit completion signal to `BaseDetector` and controller
  - Review 3: `_rebuildEvidence` double-count on aborted walks → transactional `_pendingEvidence` staging map, merged only in `notifyWalkCompleted()`
  - Reviews 4-5: Controller-wide `_walkCompleted` flag can suppress valid scans when a later detector throws → accepted as correct conservative tradeoff (false negatives > false positives; self-heals next cycle; requires persistently-throwing detector which test suite would catch)
- `notifyWalkCompleted()` added as a new `BaseDetector` hook (no-op default) — called by controller after unified walk success and by `BaseDetector.scanTree` after single-detector walk success
- Benchmark: SetStateScopeDetector now uses `defaultBudgetUs` (5ms) instead of `setStateBudgetUs` (15ms); added to linear-scaling test (15 detectors)
- Future improvement identified: per-detector exception isolation in the controller's unified walk loop (wrap individual detector callbacks in try/catch) — benefits all 16 detectors, orthogonal to v8.1, tracked for post-v8.2

---

### v8.2: Scaffold Scan-Root Fallback (Cupertino/Custom Apps)

**Effort:** Medium-High | **Theme:** Accuracy | **Impact:** Unlocks structural detection for single-scaffold Cupertino and scaffold-free layouts

**Problem:** `_findVisiblePageContext` (sleuth_controller.dart:663-723) only recognizes `Scaffold` by runtime type string (line 684: `if (name == 'Scaffold')`). Returns `null` when no scaffold found or when multiple scaffolds are visible. In `_scanTree` (line 607-624), `null` causes an early return — all 16 structural detectors are completely skipped, highlights are cleared, and the interaction state is set to `navigating`.

**Impact:** Apps using `CupertinoPageScaffold`, `CupertinoTabScaffold`, or custom scaffold-free layouts get **zero structural detection**. This is a silent false-negative for the entire Cupertino ecosystem.

**Known remaining gap:** Stable multi-scaffold layouts (nested navigators, split-view, `Scaffold` inside `Drawer`) will still get zero structural detection because `scaffolds.length > 1 → return null` is preserved. Solving this requires route-root / navigator-ownership disambiguation — a separate, larger effort that should be its own milestone if demand warrants it.

**Note:** `refreshHighlights()` (line 736) already has a fallback: `_findVisiblePageContext(ctx) ?? ctx`. But the main `_scanTree` path (called every 1s by the scan loop) does not.

**Current scan-root logic:**
```dart
if (name == 'Scaffold') {         // line 684 — Material only
  scaffolds.add(element);
}
...
if (scaffolds.isEmpty) return null;  // line 695 — Cupertino apps always hit this
if (scaffolds.length > 1) return null; // line 699 — route transitions
```

**Fix — two-tier approach:**

1. **Expand scaffold recognition** (line 684): Add `CupertinoPageScaffold` to the name check.

```dart
if (name == 'Scaffold' ||
    name == 'CupertinoPageScaffold') {
  scaffolds.add(element);
}
```

   **Also add `CupertinoPageScaffold` to detector framework skip lists.** Material `Scaffold` is already skip-listed in both `SetStateScopeDetector.isFrameworkWidget()` (via `widget is Scaffold` at line 337) and `ShallowRebuildRiskDetector.frameworkWidgets` (via `'Scaffold'` string at line 91). `CupertinoPageScaffold` does NOT extend `Scaffold` (separate class hierarchy in the Cupertino library), so the existing `is Scaffold` type check does not match it. Without this addition, the scaffold-path unified walk descends through `CupertinoPageScaffold` and both detectors treat it as a user widget: `SetStateScopeDetector` would flag it for owning most of the page subtree (ratio >50%), and `ShallowRebuildRiskDetector` would flag it at depth ~2 (within `depthThreshold = 3`). Add `'CupertinoPageScaffold'` to: (a) `SetStateScopeDetector._frameworkWidgetNames` set (line 361-381), and (b) `ShallowRebuildRiskDetector.frameworkWidgets` const set (line 90-102).

**Why not `CupertinoTabScaffold`:** Unlike `Scaffold` and `CupertinoPageScaffold` which wrap a single page's content, `CupertinoTabScaffold` retains **all** tab subtrees simultaneously in the element tree — inactive tabs are offstage but still present as children. The existing scan-root logic walks UP from the scaffold to find the page widget's parent, then the unified walk descends from there visiting all descendants. Since the unified walk has no offstage pruning (by design — `KeepAliveDetector` and `ImageMemoryDetector` need offstage access), anchoring the scan root above `CupertinoTabScaffold` would traverse hidden tab subtrees, inflating subtree sizes and producing cross-tab false positives. Handling `CupertinoTabScaffold` correctly requires resolving the **active tab's subtree** explicitly — a separate effort that should be its own milestone if demand warrants it.

2. **Add fallback for scaffold-free screens** (line 695) — but preserve transition suppression.

   **Critical constraints:**

   - The `null` return from `_findVisiblePageContext` serves a dual purpose: "no scaffold found" AND "ambiguous navigation state." In `_scanTree` (lines 607-624), `null` triggers highlight clearing, SetState snapshot clearing, and `navigating` stamping. Unconditionally returning `_appChildContext` when `scaffolds.isEmpty` would force scanning during scaffold-free route transitions — producing cross-route false positives and losing the `navigating` sentinel.

   - The `Offstage`/`TickerMode` guards (lines 670-673) only exist in `_findVisiblePageContext`, NOT in `_runStructuralScans`. The unified walk visitor (lines 785-792) traverses every descendant unconditionally. Global offstage pruning in the shared walk is NOT safe: `KeepAliveDetector` explicitly targets offstage `AutomaticKeepAlive` widgets, and `ImageMemoryDetector` flags oversized images regardless of visibility. Adding `Offstage`/`TickerMode` early returns to the shared walk would blind both detectors to their primary targets.

   **Scan-root contract invariant** (must be preserved by any fallback):

   `_runStructuralScans` calls `scanContext.visitChildElements(visitor)` (line 796) — the scan root element itself is **never visited**, only its children. The existing scaffold path (lines 701-722) accounts for this: it walks UP from the Scaffold past the user's page widget, returning the **parent** of the topmost user widget so that `visitChildElements` includes the page widget as its first visited element. Any new scan-root fallback MUST return the parent of the topmost widget to scan, not the widget itself — otherwise the topmost widget is silently excluded from all 16 detectors.

   **Approach — navigator-walk active route resolution (no `ModalRoute.of`):**

   Keep `scaffolds.isEmpty → return null` as the default. Add a **conditional** fallback that resolves a route-local scan root below the navigator boundary.

   **Why not `ModalRoute.of`**: `_findVisiblePageContext` receives `root` which is `_overlayContext` — the context captured from `SleuthOverlay` (sleuth_overlay.dart:48-104). This context sits ABOVE the app's navigator in the element tree (the overlay Stack contains the app as its first child). `ModalRoute.of(context)` walks UP from the given context looking for an ancestor `ModalRoute` — since `_overlayContext` is above the navigator, there is no ancestor route, and it returns null. Therefore `ModalRoute.of` is NOT a viable option. The fallback must walk DOWN the tree to find the navigator and its active route.

   **(a) `_findActiveRouteScanRoot(root)` — use topmost route's overlay entry as scan root**: Walk the tree downward from `root` looking for the **outermost** `Navigator` element (outermost to avoid collapsing into nested navigator subtrees like bottom tabs). Once found, walk into the Navigator's internal `Overlay`, collect onstage overlay entries, and identify the topmost **route-owned** entry (distinguished from non-route entries via `_ModalScope` check). Return the **overlay entry element** as the scan root. Separately capture a route context below `_ModalScopeStatus` for `ModalRoute.of` stamping.

   **Verified overlay entry tree structure (from Flutter SDK source):**
   ```
   _OverlayEntryWidget (overlay.dart:296)
     └─ TickerMode(enabled: tickerEnabled) (overlay.dart:419)
         └─ _RenderTheaterMarker (overlay.dart:421)
             └─ Builder(builder: entry.builder) (overlay.dart:426)
                 └─ [route content — for ModalRoute entries:]
                     _ModalScope (routes.dart:1075)
                       └─ AnimatedBuilder (routes.dart:1179)
                           └─ RestorationScope (routes.dart:1183)
                               └─ _ModalScopeStatus (routes.dart:1188)
                                   └─ Offstage(offstage: route.offstage) (routes.dart:1194)
                                       └─ ~13 more wrappers → buildPage() (routes.dart:1235)
   ```

   Key facts verified from SDK:
   - **Onstage/offstage** is controlled by `TickerMode(enabled: tickerEnabled)` at the overlay entry level (`_OverlayEntryWidgetState.build()`, overlay.dart:418-429), **NOT** by `Offstage`. Background maintained routes get `tickerEnabled: false` (set in `OverlayState.build()`, overlay.dart:883). The `Offstage` widget lives deep inside `_ModalScopeState.build()` (routes.dart:1194) and controls route-level visibility within an already-onstage entry — it is NOT the overlay-level onstage/offstage signal.
   - **`ModalRoute.of(context)`** (routes.dart:1315-1321) uses `InheritedModel.inheritFrom<_ModalScopeStatus>`. Since `_ModalScopeStatus` is a **DESCENDANT** of `_ModalScope` (built at routes.dart:1188, inside `_ModalScopeState.build()`), `ModalRoute.of` only works from a context **BELOW** `_ModalScopeStatus` in the ancestor chain — NOT from the overlay entry, NOT from `_ModalScope` itself. Any context at or above `_ModalScope` returns null.
   - **User widgets** are ~20 levels deep from the overlay entry (~17 from `_ModalScope`) due to `_ModalScopeState.build()`'s extensive wrapper chain (AnimatedBuilder → RestorationScope → `_ModalScopeStatus` → Offstage → PageStorage → Builder → Actions → PrimaryScrollController → FocusScope → RepaintBoundary → ListenableBuilder → transitions → ... → `buildPage()`). No scan-root anchor in this chain can put user widgets within `ShallowRebuildRiskDetector`'s `depthThreshold = 3`.

   **Design decisions based on verified tree:**

   1. **Scan root = overlay entry** (not `_ModalScope`): The overlay entry is the natural subtree boundary — each route's entire content lives under its `_OverlayEntryWidget`. Using `_ModalScope` would be deeper but gains nothing: depth normalization is impossible from any anchor in the route wrapper chain (user widgets are ~17 levels below `_ModalScope`), and `ModalRoute.of` doesn't work from `_ModalScope` context either (since `_ModalScopeStatus` is a descendant, not ancestor).

   2. **Route stamping = separate captured context**: Since `ModalRoute.of` requires a context below `_ModalScopeStatus`, the scan root (overlay entry) cannot be used for route stamping. Instead, `_captureRouteName` (see pseudocode below) descends from the overlay entry to find `_ModalScopeStatus`, calls `ModalRoute.of` on a child element below it, and stores only the resulting `String?` as `_scaffoldFreeRouteName` — no Element reference is retained. Used in `_currentRouteName()` when available. This cleanly separates scan-root selection from route attribution.

   3. **ShallowRebuildRiskDetector + SetStateScopeDetector = exempt for scaffold-free scans**: Both detectors have scan-root-dependent semantics that break when the scan root is the overlay entry instead of the parent of the topmost user widget. `ShallowRebuildRiskDetector` is depth-dependent: user widgets sit at depth ~20 from the overlay entry — no feasible anchor normalizes this to depth ≤ 3. `SetStateScopeDetector` is ratio-dependent: `_totalElements` (incremented for every visited element at `setstate_scope_detector.dart:115`) is inflated by ~20 framework wrapper elements between the overlay entry and `buildPage()`. These wrappers increase the denominator without increasing any user widget's `_maxSubtreeSize` (which counts elements below the `StatefulElement`, not above it). For a page with N=100 user-content elements, the ratio shifts from `maxSubtreeSize / 100` to `maxSubtreeSize / 120` — a ~17% reduction that pushes borderline cases below the 50% threshold (`dirtyRatioThreshold`, line 22), creating false negatives. Rather than silently produce wrong results, honestly exempt both detectors via the `_isScaffoldFreeScan` flag. **14 of 16 structural detectors still run** — a massive improvement over the current 0/16 for scaffold-free apps. See section (e) for details.

   **Why route-owned identification, not z-order:** Navigator's internal Overlay hosts not only route entries but also non-route UI (tooltips insert via `Overlay.of(context)`, hero flights create transient entries, snackbar overlays are non-route). Simply taking the **topmost** (last in child order) onstage entry is z-order selection, not route selection — a tooltip or hero-flight entry could be last in child order, causing scans to run against that tiny subtree instead of the page. Instead, distinguish route entries from non-route entries using **`_ModalScope`**: every `ModalRoute` (including `DialogRoute`) wraps its content in `_ModalScope` → `_ModalScopeStatus` → ... → user content. `_ModalScope` is ~4 levels deep inside the overlay entry (entry → TickerMode → `_RenderTheaterMarker` → Builder → `_ModalScope`) and is **unique to route-owned entries**. Non-route entries (tooltips, hero flights, snackbar overlays) lack `_ModalScope` entirely. Iterate onstage entries in reverse (topmost first) and return the first one containing `_ModalScope` — this is the topmost route entry, guaranteed.

   **Dialog behavior note:** `DialogRoute` is a `ModalRoute` subclass, so dialog overlay entries contain `_ModalScope` and are correctly identified as route-owned. When a dialog is showing, the topmost route-owned entry IS the dialog's entry. Scanning the dialog's subtree is the correct behavior — it's the visible page. This differs from the existing Material scaffold path where `scaffolds.length > 1` suppresses scanning during dialogs (the dialog's Scaffold is the second scaffold). The scaffold-free path is actually MORE correct here — it scans whatever is on top rather than suppressing entirely. Tooltips, hero flights, and snackbar overlays are correctly skipped because they lack `_ModalScope`.

   ```dart
   if (scaffolds.isEmpty) {
     // Walk DOWN to find the outermost Navigator, then use
     // the topmost route's overlay entry as the scan root.
     final scanRoot = _findActiveRouteScanRoot(root);
     if (scanRoot != null) {
       _isScaffoldFreeScan = true;  // overlay-entry root → exempt 2 detectors (14/16)
       if (_isRouteStable()) return scanRoot;
       return null;  // unstable route → navigating sentinel
     }
     // scanRoot is null — distinguish WHY:
     // _navigatorFound is set by _findActiveRouteScanRoot during its
     // Navigator search. true = Navigator exists but unsafe to scan
     // (nested Nav guard, no route-owned entry, etc.) → sentinel.
     // false = no Navigator at all → genuine static app → fallback.
     if (_navigatorFound) return null;  // unsafe → navigating sentinel
     // No Navigator at all — static app fallback.
     // _isScaffoldFreeScan stays false → all 16 detectors active.
     // NotificationListener root has no wrapper depth/inflation issues.
     return _appChildContext;
   }
   ```

   ```dart
   /// Walk from [root] to find the outermost Navigator's topmost
   /// route-owned onstage overlay entry. Returns the overlay entry
   /// element as the scan root. Also resolves _scaffoldFreeRouteName
   /// (route name string) for route stamping — no Element retained.
   ///
   /// Onstage/offstage filtering uses TickerMode(enabled:) — the
   /// immediate child of _OverlayEntryWidget (overlay.dart:418-429).
   /// Background maintained routes have tickerEnabled: false
   /// (overlay.dart:883). NOT Offstage — that lives deep inside
   /// _ModalScopeState.build() (routes.dart:1194).
   ///
   /// Route-owned entries are identified by _ModalScope at depth ~4
   /// (entry → TickerMode → _RenderTheaterMarker → Builder →
   /// _ModalScope). Non-route entries (tooltips, hero flights,
   /// snackbar overlays) lack this wrapper.
   Element? _findActiveRouteScanRoot(Element root) {
     Element? navigator;
     // Find the outermost Navigator (stop at first match).
     void findNav(Element el) {
       if (navigator != null) return;
       if (el.widget.runtimeType.toString() == 'Navigator') {
         navigator = el;
         return; // don't descend — we want outermost
       }
       el.visitChildElements(findNav);
     }
     root.visitChildElements(findNav);
     _navigatorFound = navigator != null;  // caller uses this to distinguish
                                            // "no Navigator" from "unsafe to scan"
     if (navigator == null) return null;

     // Walk into Navigator → Overlay → collect onstage overlay entries.
     // _OverlayEntryWidgetState.build() (overlay.dart:418-429) returns:
     //   TickerMode(enabled: widget.tickerEnabled, child: ...)
     // Background maintained routes have tickerEnabled: false
     // (set by OverlayState.build(), overlay.dart:883).
     // Onstage entries have tickerEnabled: true.
     final onstageEntries = <Element>[];
     void collectEntries(Element el) {
       final name = el.widget.runtimeType.toString();
       if (name == '_OverlayEntryWidget' || name == 'OverlayEntry') {
         // Filter for onstage entries via TickerMode check.
         // The immediate child of _OverlayEntryWidget is always
         // TickerMode (overlay.dart:419). Background maintained
         // routes have enabled: false. Without this filter,
         // background ModalRoute entries (which also contain
         // _ModalScope) would pass _isRouteOwnedEntry and could
         // be returned as the scan root.
         bool isBackground = false;
         el.visitChildElements((child) {
           if (child.widget is TickerMode &&
               !(child.widget as TickerMode).enabled) {
             isBackground = true;
           }
         });
         if (!isBackground) onstageEntries.add(el);
         return;
       }
       el.visitChildElements(collectEntries);
     }
     navigator!.visitChildElements(collectEntries);

     // Iterate in reverse (last = topmost) — return the first
     // route-owned overlay entry as the scan root.
     //
     // No multi-entry count guard: multiple onstage route-owned
     // entries are NORMAL for non-opaque routes (dialogs, popups,
     // modal bottom sheets). PopupRoute.opaque returns false
     // (routes.dart:2394), so the underlying page route stays
     // onstage permanently. A count guard would suppress scanning
     // for every stable dialog — the same state the spec claims
     // to support. Transition detection is handled by
     // _isRouteStable() (identity hash), not by entry count.
     for (final entry in onstageEntries.reversed) {
       if (_isRouteOwnedEntry(entry)) {
         // Guard: bail out if the route subtree contains a nested
         // Navigator. Nested Navigators retain offstage routes that
         // the unified walk would traverse, producing cross-tab
         // false positives. Failing safe to null preserves accuracy.
         // The scaffold path has the same gap (pre-existing) — this
         // guard makes the NEW scaffold-free path conservative at launch.
         if (_containsNestedNavigator(entry)) return null;
         _captureRouteName(entry);
         _currentActiveEntryHash = entry.hashCode;
         return entry;  // overlay entry element as scan root
       }
     }
     // No route-owned entry found (all entries are transient UI).
     return null;
   }

   /// Walk the overlay entry subtree looking for a nested Navigator.
   /// Returns true if any Navigator element is found below the scan
   /// root. Terminates early on first match. Cost: O(N) worst case
   /// but typically terminates quickly (Navigator is near the top of
   /// user content, not deeply buried). Only runs on the scaffold-free
   /// path — scaffold path is unaffected.
   bool _containsNestedNavigator(Element entry) {
     bool found = false;
     void check(Element el) {
       if (found) return;
       if (el.widget.runtimeType.toString() == 'Navigator') {
         found = true;
         return;
       }
       el.visitChildElements(check);
     }
     entry.visitChildElements(check);
     return found;
   }

   /// Check if an overlay entry is route-owned by looking for
   /// _ModalScope within the first ~5 levels. Route entries have
   /// _ModalScope at depth ~4 (entry → TickerMode →
   /// _RenderTheaterMarker → Builder → _ModalScope, per
   /// overlay.dart:418-429 and routes.dart:1075).
   /// Non-route entries (tooltips, hero flights) lack it entirely.
   /// Depth limit prevents descending into the page subtree.
   bool _isRouteOwnedEntry(Element entry) {
     bool found = false;
     void check(Element el, int depth) {
       if (found || depth > 5) return;
       if (el.widget.runtimeType.toString() == '_ModalScope') {
         found = true;
         return;
       }
       el.visitChildElements((child) => check(child, depth + 1));
     }
     entry.visitChildElements((child) => check(child, 0));
     return found;
   }

   /// Resolve route name for scaffold-free scans. Walk from the
   /// overlay entry to find _ModalScopeStatus (routes.dart:1188),
   /// then call ModalRoute.of on its first child to get the route
   /// name. Stores only the String name — no Element retained.
   /// _ModalScopeStatus is an InheritedModel inside _ModalScope.build()
   /// — ModalRoute.of (routes.dart:1315) uses
   /// inheritFrom<_ModalScopeStatus>, so the context must be BELOW
   /// _ModalScopeStatus for it to find the inherited widget as ancestor.
   void _captureRouteName(Element entry) {
     _scaffoldFreeRouteName = null;
     Element? scopeStatusChild;
     void findScopeStatus(Element el, int depth) {
       if (scopeStatusChild != null || depth > 10) return;
       if (el.widget.runtimeType.toString() == '_ModalScopeStatus') {
         el.visitChildElements((child) {
           scopeStatusChild ??= child;
         });
         return;
       }
       el.visitChildElements((child) => findScopeStatus(child, depth + 1));
     }
     entry.visitChildElements((child) => findScopeStatus(child, 0));
     if (scopeStatusChild != null) {
       _scaffoldFreeRouteName =
           ModalRoute.of(scopeStatusChild!)?.settings.name;
     }
     // scopeStatusChild is local — Element reference not retained.
   }
   ```

   **Route attribution integration:** Update `_currentRouteName()` (line 1200-1204) to use `_scaffoldFreeRouteName` when available:

   ```dart
   String? _currentRouteName() {
     if (_scaffoldFreeRouteName != null) return _scaffoldFreeRouteName;
     final ctx = _lastScanContext;
     if (ctx == null) return null;
     return ModalRoute.of(ctx)?.settings.name;
   }
   ```

   **Fields:** Add `String? _scaffoldFreeRouteName`, `bool _isScaffoldFreeScan`, `bool _navigatorFound = false`, `int _currentActiveEntryHash = 0`, and `int _lastActiveEntryHash = 0` to `SleuthController`. Clear `_scaffoldFreeRouteName = null` and `_isScaffoldFreeScan = false` at the **start** of every `_scanTree` call (before `_findVisiblePageContext`). This ensures: scaffold path → field stays null (never set); scaffold-free overlay-entry path → field set by `_captureRouteName`; navigating sentinel → field null (cleared before early return); static-app fallback → field stays null (no Navigator). No stale route name or Element can survive across scan paths. Set `_isScaffoldFreeScan = true` **only** when using the scaffold-free overlay-entry path (Navigator found, `_findActiveRouteScanRoot` returns non-null). The static-app fallback (`_appChildContext`) does NOT set this flag — its `NotificationListener` scan root has no wrapper-depth or ratio-inflation issues, so all 16 detectors run. `_lastActiveEntryHash` is **never** reset by the navigating sentinel — it persists across sentinel cycles so `_isRouteStable()` can confirm stability. In `_runStructuralScans`, exempt both `ShallowRebuildRiskDetector` and `SetStateScopeDetector` from the walk when `_isScaffoldFreeScan` is true (see section e).

   **`refreshHighlights()` isolation:** The existing `refreshHighlights()` method (sleuth_controller.dart:729-740) currently calls `_findVisiblePageContext()` to re-resolve the scan root on each scroll-triggered refresh. With the new scaffold-free state, this creates a side-effect hazard: `_findVisiblePageContext()` calls `_findActiveRouteScanRoot` (sets `_currentActiveEntryHash`), `_isRouteStable()` (mutates `_lastActiveEntryHash`), and sets `_isScaffoldFreeScan`. A scroll-triggered refresh between a route push and the next periodic `_scanTree` would mutate the hash before `_scanTree` runs, causing `_scanTree` to see the new route as already stable — bypassing the navigating sentinel (no highlight clear, no snapshot clear, no `navigating` interaction state). **Fix:** Change `refreshHighlights()` to use `_lastScanContext` (the scan root from the most recent `_scanTree`) instead of calling `_findVisiblePageContext()`. This eliminates all side effects:

   ```dart
   void refreshHighlights() {
     if (!highlightEnabledNotifier.value) return;
     if (_interactionState == InteractionContext.navigating) return;
     final scanContext = _lastScanContext;  // reuse last confirmed scan root
     if (scanContext == null) return;
     final element = scanContext as Element;
     if (!element.mounted) return;
     _runStructuralScans(scanContext);
     _collectHighlights();
   }
   ```

   **Why this is safe:** (1) If `_lastScanContext` is null (navigating sentinel fired), the null check returns early — no scanning during transitions. (2) If `_lastScanContext` points to the previous page (push happened between scans), highlights show stale positions for at most 1 scan interval — consistent with the stale-issue window already documented. (3) The `_isScaffoldFreeScan` flag from the last `_scanTree` correctly governs the detector exemption for the same scan root. (4) `_runStructuralScans` still produces fresh detector data for updated widget positions (the purpose of highlight refresh). Only scan-root resolution and route-stability bookkeeping are removed from the refresh path.

   **(b) Route-stability check — identity hash only**: Transition suppression for the scaffold-free path uses `_isRouteStable()`, which tracks the topmost route-owned overlay entry's identity hash across scans. When the hash changes (push, pop, replacement, dialog open), the check returns false → null → navigating sentinel clears stale state. When the hash is stable across consecutive scans, scanning proceeds.

   **Why NOT a multi-entry count guard:** A count-based guard (`routeOwnedCount > 1 → suppress`) was considered but **rejected** because it creates an irreconcilable contradiction with dialog/popup routes. `PopupRoute.opaque` returns `false` permanently (routes.dart:2394). `OverlayState.build()` (overlay.dart:870-876) keeps all entries onstage until one is `opaque`. So when a dialog is open, both the underlying page route and the dialog route are onstage, both pass `_isRouteOwnedEntry` (both have `_ModalScope`), and a count guard would suppress scanning for every stable dialog. This is indistinguishable from a transition state in the element tree: during a push animation, `TransitionRoute._handleStatusChanged` (routes.dart:301-304) also sets `opaque = false`, making both entries onstage temporarily. The identity hash detects the *change* (new topmost entry = different hash), not the *count* — correctly handling both transitions and dialogs.

   **Fields:** Add `int _lastActiveEntryHash = 0` to `SleuthController`. (The corresponding `_currentActiveEntryHash` is set by `_findActiveRouteScanRoot` during each scan cycle.)

   **Logic:** After `_findActiveRouteScanRoot` selects the topmost route-owned entry, `_currentActiveEntryHash` is set to that entry's `hashCode`. Compare with the previous scan's value. If different (any route change), return false → navigating sentinel clears stale state, update `_lastActiveEntryHash` to the new value. If same (stable — whether single page, or page+dialog), return true. **Do NOT reset `_lastActiveEntryHash` in the navigating sentinel** — the hash must persist across sentinel cycles so `_isRouteStable()` can confirm stability on the next scan. The `_lastActiveEntryHash == 0` codepath only applies to the very first scan after `SleuthController` initialization (when `_lastActiveEntryHash` has never been set). After a route change, the hash-change detection itself provides one scan interval of suppression: hash changes (A→B) → false → sentinel → next scan sees B==B → stable → scanning resumes. This adapts to the configured `treeScanIntervalMs` (not fixed at 1s — see `sleuth_controller.dart:1437,1491`): the route must be stable for at least one full scan interval before scanning resumes.

   **Transition suppression walkthrough — normal push (300ms animation):**
   1. Scan at T=0s: page A, hash=A, stable → scan
   2. Push B at T=0.3s, animation runs 300ms
   3. Animation completes at T=0.6s: B.opaque=true → A goes background
   4. Scan at T=1.0s: topmost=B, hash=B ≠ A → `_isRouteStable()` returns false (updates `_lastActiveEntryHash = B`) → null → sentinel (clears highlights)
   5. Scan at T=2.0s: topmost=B, hash=B == lastHash=B → **stable** → scan B

   **Dialog walkthrough — `showDialog()`:**
   1. Scan at T=0s: page A, hash=A, stable → scan
   2. `showDialog()` at T=0.3s, dialog animation runs 150ms
   3. Animation completes at T=0.45s: dialog open, page stays onstage (dialog.opaque=false)
   4. Scan at T=1.0s: topmost=dialog C, hash=C ≠ A → false (updates `_lastActiveEntryHash = C`) → sentinel
   5. Scan at T=2.0s: topmost=dialog C, hash=C == lastHash=C → **stable** → scan dialog

   **Edge case — very long animation (>1s):** Scanning resumes after 1 full scan interval post-hash-change (step 4 detects change → step 5 confirmed stable). At the default 1s interval, this means scanning resumes at T=2s after the push. Animations exceeding 1s are extremely rare. For the uncommon case of a custom transition that exceeds 1 scan interval, the scan at step 5 may see a still-animating page — the same behavior the scaffold path has for dialog transitions (dialogs don't have Scaffold, so `scaffolds.length == 1` and scanning proceeds immediately during the dialog entrance animation). For shorter `treeScanIntervalMs` (e.g., 200ms), the one-interval gate means scanning resumes at T=0.4s after push (step 4 at T=0.2s, step 5 at T=0.4s) — comfortably after a 300ms animation completes at T=0.3s. This adapts to the configured interval rather than assuming 1s.

   **Why `hashCode` for identity:** Each route push (including `pushReplacement`) creates a new `_OverlayEntryWidget` element with a unique identity hash (Dart's default `hashCode` for objects is identity-based). So: push → new top entry → different hash → unstable. Pop → previous entry now on top → different hash → unstable. Replace → new entry replaces old → different hash → unstable. Dialog open → dialog entry now topmost → different hash → unstable (then stabilizes). Same route stable → same element → same hash → stable. No Element retention — `hashCode` is an `int`.

   ```dart
   bool _isRouteStable() {
     // _currentActiveEntryHash is set by _findActiveRouteScanRoot
     // during the same scan cycle. No multi-entry guard — dialogs
     // and transitions are both detected by hash change alone.
     //
     // _lastActiveEntryHash is NEVER reset by the navigating sentinel.
     // It persists across sentinel cycles so this method can confirm
     // stability on the scan immediately following a hash change.
     // The == 0 check only fires on the very first scan after
     // SleuthController initialization.
     if (_lastActiveEntryHash == 0) {
       // Initial startup — record but don't accept yet.
       _lastActiveEntryHash = _currentActiveEntryHash;
       return false;
     }
     final stable = _currentActiveEntryHash == _lastActiveEntryHash;
     _lastActiveEntryHash = _currentActiveEntryHash;
     return stable;
   }
   ```

   **(c) No global offstage pruning + nested Navigator guard**: The unified walk in `_runStructuralScans` remains unchanged — all detectors (including `KeepAliveDetector` and `ImageMemoryDetector`) continue to see offstage subtrees. Route-transition filtering stays in scan-root selection where it belongs. The scan root is the active route's overlay entry element — inactive routes from the **outer** Navigator are excluded by virtue of being in separate overlay entries outside the scan root's subtree.

   **Nested Navigator guard:** `_findActiveRouteScanRoot` checks for nested Navigators in the selected overlay entry subtree via `_containsNestedNavigator`. If any `Navigator` element is found, the function returns `null` → navigating sentinel → no scan. This prevents cross-tab false positives from hidden inner routes (tab stacks, shell routes, in-page flows) that would otherwise be traversed by the unified walk. The guard terminates early on first match and only runs on the scaffold-free path — scaffold path is unaffected.

   **Result for scaffold-free apps with nested Navigators:** 0/16 structural detectors (same as current behavior — no regression). Scaffold-free apps WITHOUT nested Navigators get the full 14/16 detectors. The scaffold path has the **identical** nested Navigator gap (pre-existing, shipping since v0.x) — resolving it for both paths requires **route-root / navigator-ownership disambiguation**, which should be its own future milestone if demand warrants it.

   **(d) Static scaffold-free apps** (no Navigator at all): For apps that don't use Navigator (single-screen utilities, embedded widgets), `_findActiveRouteScanRoot` returns null **with `_navigatorFound = false`**. The caller checks `_navigatorFound` to distinguish this from "Navigator exists but unsafe to scan" (nested Navigator guard, no route-owned entry) where `_navigatorFound = true` and the correct action is navigating sentinel. Only when `_navigatorFound == false` does the caller fall back to `_appChildContext` — the `NotificationListener` element that wraps `widget.child` in `SleuthOverlay.build()` (sleuth_overlay.dart:60-66). Since there's no navigator, there are no inactive routes to worry about — the entire app subtree IS the visible page.

   **Why NotificationListener, not the app widget itself:** `_runStructuralScans` calls `visitChildElements` on the scan root — and `visitChildElements` visits children only, never the element itself. If we used the app widget element (e.g., `MyCustomApp`) as scan root, that widget would be invisible to all 16 detectors. The `NotificationListener` element is the correct parent because: (a) `visitChildElements` on it visits `widget.child` (the app widget) as its first child — solving the skip problem; (b) it contains **only** the app subtree — no `HighlightOverlay`, `TriggerButton`, or `FloatingIssuesCard` siblings (those are separate `Stack` children); (c) `NotificationListener` itself is a framework `ProxyElement` — no detector targets it (correctly skipped). The Stack parent was also considered but rejected: `visitChildElements` on the Stack visits ALL children including sleuth instrumentation UI, producing false positives on our own widgets.

   **(e) ShallowRebuildRiskDetector + SetStateScopeDetector exemption for scaffold-free path**: Two of the 16 structural detectors have scan-root-dependent semantics that produce wrong results when the scan root is the overlay entry instead of the parent of the topmost user widget:

   **ShallowRebuildRiskDetector — depth-dependent:** The scaffold path returns the parent of the topmost user widget so `visitChildElements` visits the user widget at depth 1, well within `depthThreshold = 3`. The scaffold-free path returns the overlay entry element — user widgets are ~20 levels deep due to `_ModalScopeState.build()`'s extensive wrapper chain (verified from routes.dart:1176-1242: AnimatedBuilder → RestorationScope → `_ModalScopeStatus` → Offstage → PageStorage → Builder → Actions → PrimaryScrollController → FocusScope → RepaintBoundary → ListenableBuilder → transitions → ... → `buildPage()`). `ShallowRebuildRiskDetector` increments `_depth` for **every** element in `checkElement` (line 81), including all these framework wrappers. No scan-root anchor in the route wrapper chain can normalize depth to ≤ 3 — even `_ModalScope` has ~17 wrapper levels below it before `buildPage()`.

   **SetStateScopeDetector — ratio-dependent:** `_totalElements` is incremented for every visited element (`setstate_scope_detector.dart:115`), including the ~20 framework wrapper elements between the overlay entry and `buildPage()`. These wrappers increase the denominator of the ratio `_maxSubtreeSize / _totalElements` (line 168) without increasing any user widget's `_maxSubtreeSize` (which counts elements **below** that `StatefulElement` via `countSubtree`, lines 144-149 — ancestors are not counted). On the scaffold path, the scan root excludes these wrappers entirely. On the scaffold-free path, they inflate `_totalElements` by ~20. Impact by page size: N=200 → ratio reduced ~9%; N=100 → reduced ~17% (e.g., 60% → 50%, hitting the `dirtyRatioThreshold` boundary); N=80 → reduced ~20% (e.g., 60% → 48%, **false negative**). The alternative — subtracting a wrapper offset from `_totalElements` — is fragile because it depends on knowing the exact wrapper count, which changes if Flutter modifies `_ModalScopeState.build()`.

   **Resolution:** Exempt both detectors from the scaffold-free **walk** via the `_isScaffoldFreeScan` flag (set in `_findVisiblePageContext` **only** when using the overlay-entry scan root — i.e., when `_findActiveRouteScanRoot` returns non-null). The static-app fallback (`_appChildContext` = `NotificationListener` element) does NOT set this flag because its scan root has no `_ModalScope` wrapper chain — user widgets are at depth 1 from the `NotificationListener`, and `_totalElements` is not inflated. Static apps get **full 16/16 detectors**. In `_runStructuralScans`, still call `prepareScan` and `finalizeScan` for both detectors on every scan (scaffold, scaffold-free, or static), but skip them during the `checkElement`/`afterElement` walk when `_isScaffoldFreeScan` is true. This is critical for stale-issue prevention: both detectors accumulate state during the walk (`_usages` for ShallowRebuildRiskDetector, `_newSnapshots`/`_typeInstanceCounts`/`_totalElements` for SetStateScopeDetector) that feeds into `finalizeScan`. If `prepareScan` runs (clearing walk state) but `checkElement` is skipped, `finalizeScan` finds no data and produces zero `_issues`. Without this lifecycle pairing, skipping the detectors entirely would leave `_issues` from the previous scaffold-based scan persisting into scaffold-free scans, because the controller aggregates `d.issues` from ALL detectors regardless of whether they participated. Specifically: `ShallowRebuildRiskDetector._issues` is only cleared during `finalizeScan` → `_evaluate()` (line 118-120), which reads from `_usages` (cleared in `prepareScan`, line 77); `SetStateScopeDetector._issues` is cleared in `prepareScan` (line 102), so its lifecycle is simpler but the pairing is still needed for `_childSnapshots` swap (line 164 — `_childSnapshots = _newSnapshots`) to prevent stale rebuild evidence. **Detector coverage by scan path:** scaffold path → 16/16 (existing); scaffold-free overlay-entry path → 14/16 (exempts ShallowRebuild + SetStateScope); static-app fallback → 16/16 (no wrapper issues). All three paths are a massive improvement over the current 0/16 for scaffold-free apps.

   **AnimatedBuilderDetector framework recognition:** The route wrapper chain includes `AnimatedBuilder` (from `_ModalScopeState.build()`, routes.dart:1179) created WITHOUT a `child` parameter — all content is built inside the `builder` callback. On scaffold-free scans, the unified walk visits this framework `AnimatedBuilder`, and `AnimatedBuilderDetector.checkElement()` (`animated_builder_detector.dart:60`) matches `widget is AnimatedBuilder && widget.child == null`. Its `isFrameworkOwned()` helper (`animated_builder_detector.dart:142-153`) walks up to the nearest `StatefulElement` (= `_ModalScope`) and delegates to `SetStateScopeDetector.isFrameworkWidget()`. However, `_ModalScope` is NOT in `_frameworkWidgetNames` (lines 361-381) and matches no `is` type check — so `isFrameworkOwned` returns false. The subtree below this `AnimatedBuilder` is the entire page content (>> `minSubtreeSize` of 50), producing a false positive `animated_builder_no_child` on every scaffold-free scan. On the scaffold path, this never happens because the scan root is below `_ModalScope` (walked up from Scaffold to user page parent), so the walk never visits the route wrapper chain. **Fix:** Add `'_ModalScope'` to `SetStateScopeDetector._frameworkWidgetNames` set (line 361-381). This makes `isFrameworkOwned` correctly return true for `AnimatedBuilder` instances owned by `_ModalScope`. Side-effect analysis: on scaffold path, `_ModalScope` is above the scan root (never visited) — no behavioral change; on scaffold-free path, `SetStateScopeDetector` is already exempted from the walk — adding `_ModalScope` to its name list has no effect on its own detection logic; only `AnimatedBuilderDetector.isFrameworkOwned()` is impacted (correctly).

3. **Keep multi-scaffold suppression as-is** (line 699): The current `scaffolds.length > 1 → return null` is the correct conservative behavior. For legitimate multi-scaffold layouts (e.g., nested navigators), the proper future fix is **route-root / navigator-ownership disambiguation** — walking navigator boundaries to identify which scaffold owns the active route. This is a separate, larger effort and should not weaken the current guard.

**Files:** `lib/src/detectors/setstate_scope_detector.dart` (~2 lines: add `'CupertinoPageScaffold'` and `'_ModalScope'` to `_frameworkWidgetNames` set), `lib/src/detectors/shallow_rebuild_risk_detector.dart` (~1 line: add `'CupertinoPageScaffold'` to `frameworkWidgets` const set in `checkElement`), `lib/src/controller/sleuth_controller.dart` (~65-75 lines changed: `CupertinoPageScaffold` added to scaffold name check, `_findActiveRouteScanRoot` helper returning topmost route-owned overlay entry element (no multi-entry count guard — dialogs would be falsely suppressed), `_isRouteOwnedEntry` helper with depth-limited `_ModalScope` search, `_containsNestedNavigator` guard (bails out if overlay entry subtree contains a nested Navigator — prevents cross-tab false positives), `_captureRouteName` helper resolving route name string via `_ModalScopeStatus` descendant context (no Element retained), TickerMode-based onstage entry filtering, identity-hash-only transition suppression via `_isRouteStable()` with hash-change gate (no sentinel reset — hash persists across cycles), `_scaffoldFreeRouteName` field (String — cleared at start of `_scanTree`), `_isScaffoldFreeScan` flag (cleared at start of `_scanTree`), `_navigatorFound` flag (set by `_findActiveRouteScanRoot` — distinguishes "no Navigator" from "Navigator found but unsafe to scan" so static-app fallback only fires when no Navigator exists), `_currentActiveEntryHash`/`_lastActiveEntryHash` fields for identity tracking, `_currentRouteName` updated to use `_scaffoldFreeRouteName`, scaffold-free fallback in `_findVisiblePageContext`, ShallowRebuildRiskDetector + SetStateScopeDetector walk exemption in `_runStructuralScans` — both still run `prepareScan`/`finalizeScan` to clear stale state, `refreshHighlights()` changed to use `_lastScanContext` instead of calling `_findVisiblePageContext()` — eliminates route-stability hash mutation and stale scaffold-free flag side effects from scroll-triggered refreshes), `lib/src/ui/sleuth_overlay.dart` (~3-5 lines to expose `NotificationListener` element as `_appChildContext` for static-app fallback — the parent of `widget.child`, not the app widget itself), `test/controller/` (new tests for: CupertinoPageScaffold scan-root, scaffold-free stateless route root, scaffold-free stateful route root, dialog-over-page scanning topmost route entry correctly (2 onstage route-owned entries — dialog scanned not suppressed), tooltip/hero overlay entry correctly skipped via `_ModalScope` absence, tooltip/snackbar overlay entry does NOT trigger false navigation detection, background maintained route correctly filtered via TickerMode check, static scaffold-free app fallback, nested Navigator detected in scan root → returns null with _navigatorFound=true → navigating sentinel NOT static-app fallback (guard prevents cross-tab false positives), route transition detected by identity hash change → navigating sentinel, route stabilization after transition via hash-change gate → scanning resumes, route name correctly resolved for scaffold-free scans, route replacement detected by entry identity hash, stale route name not carried into scaffold-path scans, ShallowRebuildRiskDetector + SetStateScopeDetector walk exempted for overlay-entry scaffold-free scans (14/16 detectors active), static-app fallback runs all 16/16 detectors (no exemption — NotificationListener root has no wrapper issues), stale issues cleared after scaffold→scaffold-free transition for both exempted detectors).

**Risk:** Medium. The main novelty is walking Navigator → Overlay → TickerMode-filtered entries → route-owned entry (via `_ModalScope` check) → overlay entry as scan root + route name resolution via `_ModalScopeStatus` descendant context. This depends on three Flutter internals: (1) Navigator's Overlay structure (`_OverlayEntryWidget` children), (2) `_OverlayEntryWidgetState.build()` wrapping in `TickerMode(enabled: tickerEnabled)` (overlay.dart:418-429) with background routes getting `tickerEnabled: false` (overlay.dart:883), and (3) `ModalRoute` wrapping content in `_ModalScope` → ... → `_ModalScopeStatus` (routes.dart:1075-1188). All three are stable Flutter invariants across recent versions but are not public API contracts — a major Flutter refactor could break them. The `_isRouteOwnedEntry` shallow check (depth ≤ 5) is defensive: if Flutter adds wrapper levels between the overlay entry and `_ModalScope`, it returns false (failing safe to null/navigating sentinel rather than scanning the wrong subtree). The `_captureRouteName` depth limit (≤ 10) accommodates the known ~8-level path from overlay entry to `_ModalScopeStatus`; route name is resolved immediately and no Element reference is retained. The static-app fallback uses the `NotificationListener` element (parent of `widget.child` in `SleuthOverlay.build()`) as `_appChildContext` — `visitChildElements` visits the app widget as its first child, ensuring full detector coverage including the root widget, while excluding sleuth UI siblings. **Stale-state prevention:** `_scaffoldFreeRouteName` and `_isScaffoldFreeScan` are cleared at the start of every `_scanTree` call, preventing stale scaffold-free state from surviving into scaffold-path or navigating-sentinel scans. **`refreshHighlights()` isolation:** `refreshHighlights()` uses `_lastScanContext` instead of calling `_findVisiblePageContext()` — this prevents scroll-triggered refreshes from mutating `_lastActiveEntryHash` (which would bypass transition suppression) or reusing stale `_isScaffoldFreeScan` flags (which would incorrectly exempt detectors). Only `_scanTree()` resolves scan roots and updates route-stability state. **Known tradeoff — stale refresh window:** If the user navigates and scrolls within the same scan interval (before `_scanTree` detects the push), `refreshHighlights()` rescans the old page's subtree via the stale `_lastScanContext`. For `pushReplacement`, the old element becomes unmounted and the `element.mounted` check returns early (no crash). For regular pushes, stale highlights persist for at most 1 scan interval before `_scanTree` fires the navigating sentinel and clears everything. This is a deliberate tradeoff: the alternative (calling `_findVisiblePageContext()` in refresh) causes the far worse navigating-sentinel bypass bug documented in review 21. The stale-refresh window matches the existing scaffold path's transition behavior and is acceptable for a debug-mode diagnostic tool. **Transition suppression — identity hash only (no multi-entry guard):** `_isRouteStable()` detects route changes via topmost entry identity hash change → null → navigating sentinel. A multi-entry count guard was rejected because `PopupRoute.opaque` returns `false` permanently (routes.dart:2394), keeping both dialog and page entries onstage — indistinguishable from a transition where `TransitionRoute._handleStatusChanged` (routes.dart:301-304) temporarily sets `opaque = false`. The hash correctly detects the *change* without false-suppressing stable dialogs. **Edge case:** Very long animations (>1 scan interval) may be scanned mid-transition after the hash stabilizes — same behavior as scaffold path for dialog transitions. **Detector exemption strategy:** `ShallowRebuildRiskDetector` and `SetStateScopeDetector` both still run `prepareScan`/`finalizeScan` on scaffold-free scans, only skipping `checkElement`/`afterElement` in the walk. For `ShallowRebuildRiskDetector`, this clears `_usages` and produces zero `_issues`. For `SetStateScopeDetector`, `prepareScan` clears `_issues`, `_highlights`, resets `_totalElements`/`_maxSubtreeSize`, and `finalizeScan` swaps `_childSnapshots = _newSnapshots` (empty) — preventing stale rebuild evidence from persisting. Both detectors' stale issues are correctly cleared across scaffold→scaffold-free transitions. **Nested Navigator guard:** `_containsNestedNavigator` walks the overlay entry subtree for any Navigator element; if found, returns null (fails safe to navigating sentinel). This prevents the scaffold-free path from scanning hidden inner routes. Terminates early on first match. The scaffold path's identical gap is pre-existing and unchanged. **Stale-issue window during scaffold-free transitions:** The hash-change gate in `_isRouteStable()` creates a 1-2 scan interval window where `issuesNotifier` holds stale issues from the previous page (issues are not cleared during the navigating sentinel — see `_scanTree` lines 608-624). This is the **same behavior and similar duration** as the scaffold path during route transitions (documented and verified in `interaction_context_test.dart:203-246`: "Issues are not re-aggregated during navigation — the notifier still holds the old issues"). This is acceptable for a debug-mode diagnostic tool: highlights are cleared immediately, stale issues are stamped with the old route name (visually identifiable), and the interaction state is `navigating`. **Static-app fallback and hidden subtrees:** The `_appChildContext` fallback (when `_navigatorFound == false`) scans the entire app widget subtree via the unified walk, which has no Offstage/TickerMode filtering by design (`KeepAliveDetector` and `ImageMemoryDetector` need offstage access). If a no-Navigator app uses `IndexedStack` or `Offstage` to manage multiple "pages" manually, hidden subtrees would be included in the scan. This is a known limitation accepted for three reasons: (1) it requires no Navigator at all — no `MaterialApp`, `CupertinoApp`, or `WidgetsApp` anywhere (all create Navigator internally), making it an extremely niche pattern; (2) adding walk-level filtering would break `KeepAliveDetector` and `ImageMemoryDetector`; (3) practical impact is mild — extra elements from hidden pages inflate `_totalElements` (denominator), actually REDUCING `SetStateScopeDetector` sensitivity, and `ShallowRebuildRiskDetector` would flag hidden-page widgets at structural-only confidence. No code change needed. **Non-ModalRoute route detection:** `_isRouteOwnedEntry` identifies route-owned overlay entries by checking for `_ModalScope` within depth ≤ 5. This correctly distinguishes route entries from non-route entries (tooltips, hero flights, snackbars) because `_ModalScope` is created exclusively by `ModalRoute.createOverlayEntries()` (routes.dart:1059-1075). Custom Route subclasses that extend `Route`, `OverlayRoute`, or `TransitionRoute` directly (skipping `ModalRoute`) would not have `_ModalScope` in their entry subtree, causing `_findActiveRouteScanRoot` to return null with `_navigatorFound = true` → navigating sentinel indefinitely. This is a known limitation accepted because: (1) virtually all real-world routes extend `ModalRoute` — `MaterialPageRoute`, `CupertinoPageRoute`, `PageRouteBuilder`, all GoRouter page types, `PopupRoute`, `DialogRoute`, `ModalBottomSheetRoute` all go through the `ModalRoute` → `PageRoute` → `Route` hierarchy; (2) `_ModalScope` is the only reliable route-ownership marker accessible from the element tree — `ModalRoute.of()` can't be used (context is above Navigator), and the entry widget itself (`_OverlayEntryWidget`) doesn't distinguish route vs non-route entries; (3) falling back to "any onstage entry" when no `_ModalScope` is found would defeat the tooltip/hero/snackbar filtering entirely. The intersection of "scaffold-free" + "custom non-ModalRoute" is vanishingly small. **Mixed Material/Cupertino scaffold nesting:** The expanded scaffold collector (checking both `'Scaffold'` and `'CupertinoPageScaffold'`) walks the entire subtree via `visitChildElements`, so a Material `Scaffold` that nests a `CupertinoPageScaffold` as a descendant would collect both, triggering `scaffolds.length > 1 → return null` (transition suppression). In practice this is a non-issue: `CupertinoPageScaffold` is a page-level root scaffold (provides nav bar, background color, keyboard resize) — the same role as `Scaffold`. Nesting one inside the other is architecturally incoherent; mixed Material/Cupertino apps use each scaffold type as the root of different pages, not nested within each other. The actual benefit of the expanded check is improved cross-scaffold-type transition detection: a push from a Material page (`Scaffold`) to a Cupertino page (`CupertinoPageScaffold`) now correctly triggers `scaffolds.length > 1` suppression during the transition, where previously the Cupertino scaffold was invisible to the collector and scanning could fire mid-transition. Needs thorough testing with: CupertinoApp + CupertinoPageScaffold (scaffold path), scaffold-free Navigator with stateless page (overlay entry root), scaffold-free Navigator with dialog open (topmost = dialog, underlying page onstage, scanning NOT suppressed), scaffold-free Navigator with tooltip visible (tooltip entry skipped — does NOT trigger navigation), scaffold-free Navigator with background maintained route (TickerMode filter), static scaffold-free app (static fallback), nested Navigator detected in scan root → returns null with _navigatorFound=true → navigating sentinel NOT static-app fallback (guard prevents cross-tab false positives), route transition detected by hash change → navigating sentinel, route stabilization after hash-change suppression → scan resumes, route name resolved correctly for scaffold-free scans, route replacement detected by entry identity hash, stale route name cleared on scaffold-path transition, ShallowRebuildRiskDetector + SetStateScopeDetector walk exempted for scaffold-free scans (14/16 detectors active), stale issues cleared after scaffold→scaffold-free transition for both exempted detectors, refreshHighlights() uses _lastScanContext (does not call _findVisiblePageContext — no route-stability hash mutation or stale flag side effects from scroll-triggered refreshes).

#### Post-Implementation Notes (v8.2) — Shipped

1. **CupertinoPageScaffold scaffold recognition:** Added `'CupertinoPageScaffold'` to the scaffold name check in `_findVisiblePageContext` and to both detector framework skip lists (`SetStateScopeDetector._frameworkWidgetNames`, `ShallowRebuildRiskDetector.frameworkWidgets`).
2. **Three-tier scan-root resolution:** Scaffold path (Material + Cupertino) → scaffold-free Navigator path (overlay entry) → static app fallback (NotificationListener). All three tiers tested and working.
3. **`_ModalScope<dynamic>` generic parameter discovery:** Spec assumed `runtimeType.toString()` returns `'_ModalScope'` — actual runtime value is `'_ModalScope<dynamic>'` (includes generic parameter). Fixed with `startsWith('_ModalScope')` in both `_isRouteOwnedEntry` and `SetStateScopeDetector.isFrameworkWidget()`. Same approach handles all instantiations (`_ModalScope<Object?>`, etc.).
4. **Overlay entry depth limit increased from 5 to 7:** Spec assumed entry → TickerMode → `_RenderTheaterMarker` → Builder → `_ModalScope` (depth 4). Actual tree includes `_EffectiveTickerMode` and `Semantics` wrappers, pushing `_ModalScope` to depth ~5. Increased `_isRouteOwnedEntry` depth limit to 7 for safety margin. Verified via diagnostic tests that progressively dumped the actual Flutter element tree structure.
5. **`_captureRouteName` depth limit set to 10:** `_ModalScopeStatus` appears ~1-2 levels deeper than `_ModalScope`. Depth 10 accommodates the known ~8-level path from overlay entry to `_ModalScopeStatus`.
6. **refreshHighlights isolation:** Changed from calling `_findVisiblePageContext()` (which would mutate hash state and scaffold-free flags) to using `_lastScanContext` (reuses last confirmed scan root without side effects). Only `_scanTree()` resolves scan roots and updates route-stability state.
7. **Detector exemption:** `ShallowRebuildRiskDetector` and `SetStateScopeDetector` exempted from scaffold-free walk via `_isScaffoldFreeScan` flag. Both still run `prepareScan`/`finalizeScan` to clear stale state. `notifyWalkCompleted` only called for walked detectors. Static-app fallback runs all 16/16 detectors (no exemption).
8. **No changes to `sleuth_overlay.dart`:** `_resolveAppChildContext` finds the `NotificationListener` by walking down from the overlay root, no overlay widget changes needed. Cached after first resolution with mount-check.
9. **16 new tests in 8 groups:** CupertinoPageScaffold recognition (2), scaffold-free Navigator path (3), route name resolution (1), nested Navigator guard (1), static app fallback (2), detector exemption (2), stale state prevention (2), refreshHighlights isolation (1), framework skip list coverage (2).
10. **Test count:** 1,327 → 1,343. All pass, 0 analysis issues.

---

### v8.3: HTTP Monitor — openUrl Leak on Connection Failure

**Effort:** Very Low | **Theme:** Correctness | **Impact:** Prevents phantom pending requests

**Problem:** `_MonitoringHttpClient.openUrl()` (http_monitor.dart:102-117) calls `_onRequestStarted` (line 106) before `await _inner.openUrl()` (line 107) with **no try/catch**. If `_inner.openUrl()` throws (DNS failure, TLS error, proxy timeout), `_onRequestEnded` is never called. This permanently inflates `_activeRequests` in `NetworkMonitorDetector`, corrupting `pendingRequestSnapshot()` and polluting verdict network context.

**Current code (http_monitor.dart:102-117):**
```dart
Future<HttpClientRequest> openUrl(String method, Uri url) async {
  if (_isExcluded(url)) return _inner.openUrl(method, url);
  final startTime = DateTime.now();
  final requestId = _nextRequestId++;
  _onRequestStarted?.call(requestId, startTime);
  final request = await _inner.openUrl(method, url);  // ← can throw
  return _MonitoringRequest(...);
}
```

**The fix pattern already exists** in `_MonitoringRequest.close()` (lines 275-300): try/catch that calls `_onRequestEnded` and emits a failure `RequestRecord` with `statusCode: -1`.

**Fix:** Wrap the `_inner.openUrl()` call in try/catch:

```dart
Future<HttpClientRequest> openUrl(String method, Uri url) async {
  if (_isExcluded(url)) return _inner.openUrl(method, url);
  final startTime = DateTime.now();
  final requestId = _nextRequestId++;
  _onRequestStarted?.call(requestId, startTime);
  try {
    final request = await _inner.openUrl(method, url);
    return _MonitoringRequest(...);
  } catch (_) {
    _onRequestEnded?.call(requestId);
    final durationMs = DateTime.now().difference(startTime).inMilliseconds;
    _onRecord(RequestRecord(
      url: url.toString(),
      method: method,
      statusCode: -1,
      durationMs: durationMs,
      responseBytes: 0,
      startedAt: startTime,
    ));
    rethrow;
  }
}
```

**Files:** `lib/src/network/http_monitor.dart` (~12 lines added), `test/network/http_monitor_test.dart` (2-3 new tests: openUrl failure emits record, openUrl failure calls onRequestEnded, openUrl failure rethrows).

**Risk:** None. Strictly additive error handling. Existing behavior unchanged on success. The `rethrow` preserves the original exception for callers.

#### Post-Implementation Notes (v8.3) — Shipped

1. **`openUrl()` try/catch added:** Wraps `_inner.openUrl()` in try/catch. On failure: calls `_onRequestEnded`, emits `RequestRecord(statusCode: -1)`, rethrows.
2. **Callback isolation (from Codex adversarial review):** Both `openUrl()` and the pre-existing `_MonitoringRequest.close()` catch blocks now wrap monitoring callbacks (`_onRequestEnded`, `_onRecord`) in an inner try/catch. If a callback throws, the inner catch swallows it so the original transport exception (`SocketException`, `HandshakeException`, etc.) always reaches the caller. Without this, a broken callback could replace the real network error, breaking retry logic and error handling.
3. **4 failure-path tests:** `_FailingHttpOverrides` + `_FailingHttpClient` helpers. Tests verify: onRequestEnded called with correct ID, failure record emitted with statusCode -1, original exception rethrown unchanged, **throwing onRecord cannot mask the transport exception** (regression test from adversarial review).
4. **Success-path callback isolation (from Codex adversarial review #2):** `_MonitoringResponse._emitRecord()` now wraps `_onRequestEnded` and `_onRecord` in separate try/catch blocks. This ensures: (a) a throwing callback cannot escape into the caller's onDone/onError handler, and (b) a throwing `_onRequestEnded` cannot suppress `_onRecord`. Two new tests with `_SuccessHttpOverrides` + `_FakeRequest`/`_FakeResponse` mock helpers verify both scenarios.
5. **Known limitation (documented, not fixed):** If a caller obtains a response but never consumes the body (`listen()` never called), `_emitRecord()` never runs. This is a pre-existing architectural issue that only affects apps with existing socket leak bugs (not consuming a response body leaks the underlying connection regardless of monitoring). Fixing requires fundamentally changing the streaming model — disproportionate risk for a scenario that requires pre-existing buggy app code.
6. **Test count:** 1,313 → 1,319. All pass, 0 analysis issues.
7. **Failure-path callback isolation (from Codex adversarial review #3):** The `openUrl()` and `_MonitoringRequest.close()` failure catch blocks originally wrapped both `_onRequestEnded` and `_onRecord` in a **single** inner try/catch. If `_onRequestEnded` threw, `_onRecord` was skipped — silently dropping the failure record from monitoring. This was inconsistent with `_emitRecord()` (success path) which already had separate try/catch per callback. Fix: split into two separate try/catch blocks, matching `_emitRecord()`. New test: `throwing onRequestEnded does not suppress failure record`. Test count: 1,319 → 1,320.

---

### v8.4: Platform Channel — Tighten Embedder Classification

**Effort:** Low | **Theme:** Accuracy | **Impact:** Eliminates false positives on platform channel detector

**Problem:** `TimelineParser.parse()` (timeline_parser.dart:219) classifies events as platform channel traffic when `_channelNames.contains(name) || cat.contains('embedder')`. The `cat.contains('embedder')` branch captures **all** embedder-thread activity — vsync callbacks, compositor scheduling, input event processing — not just MethodChannel/EventChannel traffic.

Downstream, `PlatformChannelDetector` counts these events at line 64 (`_recentCallCount += data.platformChannelEvents.length`) and fires `platform_channel_traffic` when count exceeds 20/sec. An app with zero platform channel calls can trigger this detector purely from normal embedder activity.

**Current classification (timeline_parser.dart:219):**
```dart
} else if (_channelNames.contains(name) || cat.contains('embedder')) {
  channels.add(event);
```

**_channelNames allowlist (lines 107-111):**
```dart
static const _channelNames = {
  'platformchannel',
  'platform_channel',
  'methodchannel',
};
```

**Note on case sensitivity:** The parser already lowercases event names at line 155 (`final name = (json['name'] as String? ?? '').toLowerCase()`), so test fixtures using `name: 'PlatformChannel'` become `'platformchannel'` and match the existing allowlist via the name path — NOT just via `cat.contains('embedder')`. The name-only allowlist already covers the test fixtures correctly. The core problem remains: `cat.contains('embedder')` catches all embedder-thread events (vsync callbacks, compositor scheduling, etc.) as platform channel traffic, inflating `PlatformChannelDetector` counts.

**Fix — two steps (step 1 is a hard prerequisite for step 2):**

1. **[PREREQUISITE] Capture real VM timeline traces** from the example app exercising MethodChannel, EventChannel, and BasicMessageChannel. Record the actual `name` and `cat` values Flutter emits. Verify which events are real platform channel traffic vs. unrelated embedder activity. **This step must complete and the verified allowlist must be locked before step 2 ships.** The current `_channelNames` only contains `platformchannel`, `platform_channel`, `methodchannel` — it does NOT include `eventchannel` or `basicmessagechannel`, which may be needed based on trace results.

2. **Remove the `cat.contains('embedder')` fallback** and update `_channelNames` to include all verified channel event names from step 1. Add both **positive tests** (MethodChannel, EventChannel, BasicMessageChannel events are classified correctly) and **negative tests** (non-channel embedder events like `VsyncProcessCallback`, compositor scheduling are excluded):

```dart
} else if (_channelNames.contains(name)) {
  channels.add(event);
```

**Files:** `lib/src/vm/timeline_parser.dart` (1-3 lines changed — allowlist expansion + embedder removal), `test/vm/timeline_parser_test.dart` (positive tests for each channel type + negative tests for non-channel embedder events), `test/helpers/timeline_test_helpers.dart` (update `platformChannelData` helper to remove `cat: 'embedder'` dependency).

**Risk:** Low. The name-only allowlist already covers the existing test fixtures via lowercase normalization. The hard prerequisite (trace capture) ensures the allowlist is complete before the embedder fallback is removed. No channel type can be silently dropped because step 1 must enumerate all verified names before step 2 changes the classifier.

#### Post-Implementation Notes (v8.4) — Shipped

**Hard prerequisite resolved without live trace capture.** Source code analysis of Flutter's `platform_channel.dart` revealed the actual event format: `debugProfilePlatformChannels` emits events with `name: 'Platform Channel send [channelName]#[methodName]'` via `dart:developer Timeline.startSync`. Only MethodChannel emits these; EventChannel and BasicMessageChannel do not emit timeline events. The `cat` field is empty or `'Dart'`, NOT `'embedder'`.

**Critical finding:** The classifier was fundamentally wrong, not just "too broad." Real platform channel events (`'platform channel send music#gettrack'`) matched NEITHER `_channelNames.contains(name)` (no exact match) NOR `cat.contains('embedder')` (wrong category). The `cat.contains('embedder')` fallback only caught unrelated embedder noise (vsync, compositor, input events) — real channel events were silently dropped.

**Changes applied:**
1. **`_channelPrefix` constant added** (`'platform channel send '`) for prefix-based matching of real `debugProfilePlatformChannels` events.
2. **Classifier replaced:** `_channelNames.contains(name) || cat.contains('embedder')` → `_channelNames.contains(name) || name.startsWith(_channelPrefix)`. Exact-match `_channelNames` kept as legacy fallback.
3. **Test helper updated:** `platformChannelData()` `cat` changed from `'embedder'` to `''` (documentation accuracy — helper creates pre-classified data, so `cat` doesn't affect classification).
4. **Detector docstring updated:** "monitors Embedder events" → "monitors platform channel timeline events".
5. **7 new tests:** 4 positive (real prefix format, two legacy exact names, case insensitivity) + 3 negative (embedder vsync, compositor, generic events NOT classified as channels).
6. **Test count:** 1,320 → 1,327. All pass, 0 analysis issues.

**Note:** `debugProfilePlatformChannels` defaults to `false`. Sleuth does not currently enable it. Auto-enabling via VM service evaluation is a separate future enhancement. This fix ensures the classifier works correctly when events are present and stops generating false positives from embedder noise.

---

### v8.5: SetState Detector — Wording Accuracy

**Effort:** Very Low | **Theme:** Accuracy | **Impact:** Honest reporting of evidence

**Problem:** The `SetStateScopeDetector` claims "setState() was detected" (line 206) when it only observed child widget identity churn between scan cycles. This proves the element rebuilt, but not *why* — parent rebuilds, inherited widget updates, and `didUpdateWidget` all produce the same signal. The wording overclaims causality.

**User-facing strings that need updating:**

| Location | Current wording | Issue |
|----------|----------------|-------|
| `setstate_scope_detector.dart:134` | `// build() ran on this State — setState was called` | Code comment — misleading |
| `setstate_scope_detector.dart:206-207` | `setState() was detected rebuilding this wide subtree.` | Detail text — overclaims |
| `setstate_scope_detector.dart:236-237` | `Any setState() on this widget would rebuild most of the visible tree.` | Detail text — acceptable (hypothetical framing) |
| `fix_hint_builder.dart:518` | `Move setState() calls to smaller, focused widgets.` | Fix hint — overclaims trigger |

**Strings that should NOT change:**

| Location | String | Reason |
|----------|--------|--------|
| `stableId: 'setstate_scope'` | Keep | Changing breaks suppression patterns |
| `DetectorType.setStateScope` | Keep | Enum value, API surface |
| Title: `Wide setState Scope` | Keep | Describes the anti-pattern category, not the evidence |
| Causal rules referencing `setstate_scope` | Keep | Graph edges, not user-facing |

**Fix:**

1. **Line 134 comment:** `// Child widget identity changed — this element rebuilt`
2. **Lines 206-207 detail:** `Rebuild activity was detected on this wide subtree.` (drop "setState()")
3. **Line 518 fix hint:** `Scope rebuild triggers to smaller, focused widgets.` (generic wording)

The `hasEvidence` variable should be renamed to `hasRebuildEvidence` for clarity. The `hasRebuildEvidenceFor` method name is already correct.

**Files:** `lib/src/detectors/setstate_scope_detector.dart` (3-4 string changes), `lib/src/utils/fix_hint_builder.dart` (1 string change), `test/detectors/setstate_scope_detector_test.dart` (update string assertions if any match exact detail text).

**Risk:** None. No behavioral change. Stable IDs, detector types, and causal graph rules are all unchanged.

#### Post-Implementation Notes (v8.5) — Shipped

All spec changes applied plus one additional finding:

1. **Detail text (has-evidence path):** "setState() was detected rebuilding this wide subtree" → "Rebuild activity was detected on this wide subtree" — done.
2. **Fix hint:** "Move setState() calls to smaller, focused widgets" → "Scope rebuild triggers to smaller, focused widgets" — done.
3. **`hasEvidence` → `hasRebuildEvidence`:** Renamed across all 6 occurrences in `finalizeScan()` and `_addHighlight()` — done.
4. **Class docstring (lines 10-12, not in original spec):** "AND are actually calling setState(), causing wide rebuilds" → "Confidence is upgraded when rebuild activity is observed (child widget identity churn between scans)." Initial edit overclaimed by saying "AND are showing rebuild activity" — the `else if (!hasAnimScope)` branch emits at `possible` confidence without any rebuild evidence (purely structural). Adversarial review caught this; corrected to two-tier description.
5. **Line 134 comment:** Already fixed in v8.1 — confirmed still correct ("Child widget identity changed — this element rebuilt").
6. **No test changes needed:** Grep confirmed zero test assertions match any changed strings. All 1,313 tests pass.

---

### v8 Implementation Order

| Priority | Milestone | Effort | Theme | Status |
|----------|-----------|--------|-------|--------|
| 1 | v8.1: SetState O(N^2) Subtree Fix | Low | Performance | Shipped ✅ |
| 2 | v8.2: Scaffold Scan-Root Fallback | Medium-High | Accuracy | Shipped ✅ |
| 3 | v8.3: HTTP Monitor openUrl Leak | Very Low | Correctness | Shipped ✅ |
| 4 | v8.4: Platform Channel Classification | Low | Accuracy | Shipped ✅ |
| 5 | v8.5: SetState Wording Accuracy | Very Low | Accuracy | Shipped ✅ |

**v0.9.1 shipped:** v8.1 + v8.2 + v8.3 + v8.4 + v8.5 (5/5 milestones). 1,343 tests, 0 analysis issues.

**v8 roadmap complete.** All 5 milestones shipped.

---

