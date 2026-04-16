## 0.15.5

Single-milestone UX patch that replaces the overlay's live-reordering
"card jumps while I read it" bug with a **freeze-above-on-expand**
contract. While any card is expanded, every row at and above the
deepest expanded index is frozen against what the user last saw; only
the flow section beneath keeps reordering. Collapsing the last
expanded card releases the freeze. Delivers the user's literal ask:
"while I expand an issue card, reordering issue incoming / exist will
be happen below index issue that im expanded." Supersedes the
unshipped "single-card pin-on-expand" iteration, which held only the
expanded card's slot and still let newly-critical issues re-rank
above it.

### Changed

- **`FloatingIssuesCard` state model** replaces the prior single-map
  with two coupled fields: `Map<String, int> _expandedIndices`
  (issueKey → captured-snapshot-index) and
  `List<PerformanceIssue>? _orderSnapshot` (the visible list at the
  first 0→1 expand). Class invariant
  `(orderSnapshot == null) == expandedIndices.isEmpty` is asserted at
  the entry of `applyFreezeZone`. All five mutation sites update both
  fields in the same `setState` so a frame never renders against
  half-set state: 0→1 expand, 1→0 collapse, `dispose`, `didUpdateWidget`
  controller swap, and `_pruneStaleState` when eviction empties the map.
- **Snapshot sourced from what the user saw (C1).** The
  `onExpandedChanged` closure binds a local `capturedVisibleIssues`
  copy of the `visibleIssues` list the `itemBuilder` was built from on
  this pump — not `widget.controller.issuesNotifier.value` at tap
  time. Prevents a ranker tick between build and tap from seeding the
  frozen zone with a list the user never saw.
- **`_pruneStaleState` keys freeze eviction against
  `computeVisibleIssues(issues)`** so downstream children churning
  under an expanded parent don't leak the parent's entry. Selection
  and chat stale-state checks stay on raw keys because those surfaces
  reach ALL issues (including downstream ones surfaced via expansion).
- **Pin icon (`Icons.push_pin`, 14dp, `textSecondary` @ 55%)
  repositioned** from slot 4 (between confidence and JANK) to the last
  chip slot (after `↳N`, before Checkbox) — reads as a "this row is
  held" state marker, not severity chrome. Unconditional `Semantics`
  wrap preserved (empty label + `excludeSemantics: true` when
  collapsed) so a11y node identity stays stable across toggles.

### Added

- **`applyFreezeZone` top-level `@visibleForTesting` helper** — the
  render-time transform. Takes `(visibleIssues, orderSnapshot,
  expandedIndices)`; returns a list whose first `freezeEnd + 1` entries
  follow `orderSnapshot` (resolved against live `PerformanceIssue`
  instances so severity/confidence updates still render) and whose
  remainder is the ranker flow with frozen keys filtered out.
  - **MAX rule:** `freezeEnd = max(expandedIndices.values)`. Multi-
    expand freezes `[0..max]` inclusive — cards between two expanded
    cards are held by design. MIN would still let rows above the
    second expanded card shift; MAX is the simplest rule that
    satisfies "nothing above anything I'm reading moves."
  - **Silent-drop on vanished frozen entry** (no throw;
    `_pruneStaleState` evicts the expand entry on its next sweep).
  - **Clamp on out-of-range:** `freezeEnd` is clamped to
    `min(snapshotLen − 1, visibleLen − 1)` so downstream collapses
    render rather than throw.
  - **Entry assert** enforces the class invariant and (post-impl SF3)
    includes `expandedIndices.keys` in the failure message so a
    tripped assert distinguishes a zombie key from a snapshot-only
    half-state during post-mortems.

### Fixed

- **Reading-an-expanded-card reorder bug** (primary symptom):
  `_applyDurationEscalation` flipping warning→critical at 30 cycles, a
  new CRITICAL arriving mid-read, or any other ranker churn no longer
  shuffles rows above the expanded card out from under the cursor.
- **New-critical arrival cannot appear above a card being read** — it
  enters the flow section beneath the frozen zone until the user
  collapses. Accepted tradeoff the user explicitly asked for; without
  it the freeze contract is meaningless.
- **Snapshot coupling bugs** — every mutation site now clears both
  fields together, so a stale `_orderSnapshot` paired with an empty
  `_expandedIndices` can't survive to the next frame and trip the
  invariant assert.

### Notes

- Known pre-existing tradeoff (out of scope, not a v0.15.5 regression):
  at 300dp overlay width with `title + confidence + JANK + ↳N + pin +
  Checkbox` all present, the header `Row` overflows ~40dp in the
  Checkbox tail. The pin itself stays within card bounds — F5
  regression test asserts this. Checkbox density is a v0.15.6+
  follow-up.
- **Known gap (SF4, accepted):** if a frozen *non-expanded* neighbour
  is evicted mid-read (detector staleness, `computeVisibleIssues`
  absorbing a standalone under a new root, downstream collapse), the
  frozen zone compacts and visibly shifts the expanded card up by one
  slot. Low-frequency (requires multi-scan eviction while actively
  reading); self-heals on the next `_pruneStaleState` sweep. A
  placeholder-row approach would close it at the cost of visible
  "ghost" rows; deferred.

### Tests

- +24 tests. `test/ui/floating_issues_card_test.dart` adds 11 pure-
  function `applyFreezeZone` cases — user's-exact-symptom at index 2,
  multi-expand MAX, disappeared frozen entry, snapshot-shorter and
  visible-shorter clamps, flow-order preservation, two invariant
  assert cases, plus post-impl SF2 `freezeEnd=0` and
  `freezeEnd=length-1` boundary cases — and 5 widget smoke tests
  (pin-icon visibility on expand, summary-bar count invariance,
  `dispose` dual-clear, `didUpdateWidget` controller-swap dual-clear,
  collapse releases snapshot). `test/ui/issue_card_test.dart`
  pin-indicator tests preserved under the renamed group
  `v0.15.5 freeze-above-on-expand pin indicator`, including the F5
  regression that pins the icon within card bounds at 300dp.

Plan: `doc/spec_v0_15_5_freeze_above_on_expand.md`. Post-impl
adversarial review produced 4 findings, all applied (SF1 renamed
stale `_pinnedIndices` / "pin-on-expand" doc-comment references in
`floating_issues_card.dart` and `issue_card.dart` to the new
vocabulary; SF2/SF3/SF4 per above). Test count: 2,170 → 2,194.

## 0.15.4

Single-milestone patch from `doc/detector_threshold_audit.md` §7 M3:
align `NetworkMonitorDetector` slow-request thresholds with 2025–2026
mobile-API guidance and close the asymmetry where the warning tier was
constructor-configurable but critical was hardcoded.

### Changed

- **Defaults lowered in lockstep** (industry guidance: ideal 100–300 ms,
  "slow" ~1 s, "very slow" ~3 s):
  `NetworkMonitorDetector.slowThresholdMs` 2000 → 1000,
  critical boundary 5000 → 3000,
  `SleuthConfig.slowRequestThresholdMs` 2000 → 1000.

### Added

- **`NetworkMonitorDetector.criticalSlowThresholdMs`** (default 3000) —
  promotes the previously hardcoded `_criticalSlowThresholdMs` constant
  to a constructor parameter.
- **`SleuthConfig.criticalSlowRequestThresholdMs`** (default 3000) —
  threaded through at `sleuth_controller.dart:684`.
- Debug-mode assert on both: `critical > slow` (also fires from
  `copyWith`, so `SleuthConfig().copyWith(slowRequestThresholdMs: 5000)`
  without also raising critical now throws instead of silently producing
  an unreachable critical tier). Both additions are non-breaking
  (optional params with defaults).

### Tests

+5 net. `network_monitor_detector_test.dart` gains boundary tests
(`2999 ms warning`, `3000 ms critical`), custom-threshold test, and
assert-fires test (equal + less-than). Pre-existing tests hardcoded to
2000/5000 rewritten to new defaults. `config_copy_with_test.dart` gains
assert-coverage test. `v2_integration_test.dart` pass-through extended.
2,166 → 2,170.

### Migration

To restore v0.15.3 behavior: `SleuthConfig(slowRequestThresholdMs: 2000,
criticalSlowRequestThresholdMs: 5000)`.

---

## 0.15.3

Single-milestone patch from `doc/detector_threshold_audit.md` §7 M1:
animation-aware filter on `RepaintDetector`. Closes the asymmetry where
`RebuildDetector` already exempts builder widgets via a 3× multiplier
but `RepaintDetector` had **zero** filter — any widget at ≥30 paints/sec
fired `excessive_repaint`, so a `CircularProgressIndicator` in a top bar
tripped the detector on every session.

### Added

- **`lib/src/utils/animation_owner_names.dart`** — canonical
  `@visibleForTesting` Set of 21 widget types that drive intentional
  frame-rate animations: 5 indicators (`CircularProgressIndicator`,
  `LinearProgressIndicator`, `RefreshProgressIndicator`,
  `CupertinoActivityIndicator`, `RefreshIndicator`), 3 generic builders
  (`AnimatedBuilder`, `ValueListenableBuilder`, `TweenAnimationBuilder`),
  12 implicit `Animated*` widgets (`AnimatedContainer`, `…Rotation`,
  `…Scale`, `…Size`, `…Opacity`, `…Align`, `…Padding`, `…Positioned`,
  `…PositionedDirectional`, `…Slide`, `…Switcher`, `…CrossFade`,
  `…FractionallySizedBox`), and `Hero`. Shared by detector + coordinator.
- **Per-paint owned attribution** at `_handleProfilePaint` — calls
  `isAnimationOwnedPaint(element, chain)` against the live `Element`
  and exposes results via `DebugSnapshot.animationOwnedPaintCounts`
  (Map) + `totalAnimationOwnedPaintCount` (int). Three cheapest-first
  legs: (1) chain-string regex, (2) typed ancestor walk (`maxDepth=16`),
  (3) typed descendant walk (`maxVisits=32`, `maxDepth=4`).

### Changed

Three-gate filter in `RepaintDetector`:
- **Gate A (per-widget debug):** skip `repaint_debug_$typeName` when
  the typed walk proves ownership.
- **Gate B (VM aggregate fallback):** suppress the VM gate when every
  non-zero `paintCounts` entry is owned. Empty map = no signal = fire
  normally (never silently mask a real bug).
- **Gate C (debug aggregate):** residual subtraction —
  `residualCount = totalPaintCount − ownedCount`, recompute
  `residualRate`, suppress when below threshold; otherwise surface
  `Excludes N animation-owned paints` suffix in detail.

### Why this design (KDDs)

- **KDD-2** chain-containment (not Ticker reflection) is cheaper,
  deterministic, and matches coordinator output; generic-stripping via
  `indexOf('<')` before Set lookup handles `TweenAnimationBuilder<T>`.
- **KDD-3** residual subtraction at Gate C preserves `excessive_repaint`
  signal when surrounding scene over-paints but owners are accounted for.
- **KDD-4** full exemption (repaint) vs 3× multiplier (rebuild) is
  deliberate — a `CircularProgressIndicator` *must* paint at refresh
  rate; rebuild rate on the same widget is more ambiguous.

### Post-impl hardening (5 findings from `/adversarial-review`, C1–C5)

Root cause of all five: ownership was inferred from a chain-string keyed
on `runtimeType` — a human-readable debug aid, not a robust ownership
signal. Fix moves detection to per-paint typed walks against the live
`Element`.

- **C1 polymorphic-key collision:** two `CustomPaint` widgets sharing a
  `typeName` (one inside `AnimatedBuilder`, one driven by external
  `setState`) shared one cached chain; both got fully suppressed or
  fully fired. Fixed via per-paint attribution (above).
- **C2 insufficient owner set:** original 7 entries missed the entire
  `Animated*` family + `Hero` + `RefreshIndicator`. Expanded to 21.
- **C3 chain-walks-up gap:** a bare `CircularProgressIndicator` (no
  wrapping `RepaintBoundary`) propagates the dirty mark UP to the
  nearest layer-owning ancestor, so the chain walks UP from that
  ancestor and CPI becomes a *descendant*, not an ancestor. Fixed via
  bounded descendant walk.
- **C4 chain capture exception safety:** `visitAncestorElements` can
  throw "deactivated widget's ancestor is unsafe" mid-tear-down — the
  exception used to unwind through `_handleProfilePaint` and kill the
  whole pipeline. Wrapped in try/catch at
  `debug_instrumentation_coordinator.dart`; chain enrichment is skipped
  for that event, counting continues.
- **C5 test fixture tautology:** only CPI had a real-widget test;
  everything else was hand-rolled fixtures mirroring the filter's own
  assumptions. New `test/detectors/repaint_animation_owners_real_widget_test.dart`
  adds 8 real-widget tests — each pumps the owner through
  `DebugInstrumentationCoordinator`, asserts non-empty
  `animationOwnedPaintCounts`, re-pins `elapsed: 100ms` to force Gate A
  logic. Immediately caught the `TweenAnimationBuilder<double>` vs
  `TweenAnimationBuilder` generic-stripping miss that hand-rolled tests
  could never have caught (adversarial-investigation Tactic 9).

Additional discovery during C5: `RefreshProgressIndicator`'s painted
`CustomPaint` leaf sits ~13 ancestors below its `AnimatedBuilder` owner
(Material's `_buildMaterialIndicator` decoration stack). Both the
chain-string check and descendant walk missed it, which is why
`isAnimationOwnedPaint` needs the typed *ancestor* walk as a third leg.

### Test count

2,146 → 2,166. +10 gate-algebra tests + 1 real-widget CPI anti-tautology
test (ship); +8 real-widget owner-coverage tests + 1 owned-counts
contract extension (post-impl).

## 0.15.2

UX refactor of the rebuild-stats surface after a real-device profile review.
v0.15.1 surfaced rebuild attribution through both a `rebuild_hotspot_summary`
IssueCard (warning stream) AND an always-on chip; the IssueCard collided with
the ranker and KDD-5 inflations turned route entry into a warning storm.
v0.15.2 collapses both into a single always-on **expandable inline panel**.

### Changed

- **`_RebuildStatsBanner`** is now an expandable panel. Collapsed:
  `Rebuilds: N across M widgets` + chevron. Expanded: top-3 widget rows
  (rank, name, live-tweened count, normalised bar), Pause/Resume toggle
  that freezes rendered counts, `See all N →` link pushing
  `RebuildStatsPage` drilldown with the snapshot that was on screen, and
  `incl. inflations` footnote (inline KDD-5 disclosure). Reactivity via
  `Listenable.merge([issuesNotifier, routeHistoryNotifier])` — rebuilds
  on every scan tick + route push/pop. **Pause auto-clears on route
  change** so the user never reads stale data.

### Removed

- **`rebuild_hotspot_summary` rollup IssueCard** and all supporting
  machinery: `RebuildDetector._maybeEmitRollupIssue`, `_sessionElapsed`,
  `_formatElapsed`, `_activeRouteSession`, all four rate/duration
  constants, `BaseDetector.updateActiveRouteSession` hook,
  `IssueCard.onSeeAllRebuilds` parameter, `FixHintBuilder.rebuildHotspotSummary`,
  encyclopedia entry + 4 `relatedIssues` cross-references, and the
  `'rebuild_hotspot_summary'` stableId prefix mapping. `RebuildStatsPage`
  drilldown is unchanged — only the entry point moved.

### Added

- **`TweenAnimationBuilder` in `_frameworkWidgetDenyList`** — the panel
  uses it for the live count tween; the KDD-10 audit test caught it as
  missing. Without this addition, Sleuth would re-introduce a
  self-measurement leak on its own panel.
- 5 banner tests in `floating_issues_card_test.dart`: collapsed-by-default,
  expand reveals top-3 + footer, 4th widget NOT inlined (top-3 contract
  pin), tap "See all" pushes drilldown, pause freezes counts across live
  merges.

### Fixed

- **Profile-mode KDD-5 inflations no longer pollute the warning stream** —
  route entry no longer surfaces a critical-severity card for transient
  inflations that decay as the tree stabilises. Data still visible in the
  panel but as data, not a warning.

### Post-implementation hardening (12 findings from `/adversarial-review`)

**Critical:** **C1** paused-snapshot drift — `onTap` now takes
`overrideCounts`; footer passes `_paused ? _frozenCounts : null` so
drilldown opens with what was on screen, not live-drift. **C2** redundant
"See all N" on small routes — footer link gated on `widgetCount > _topN`.
**C3** stale test docstrings rewritten for the panel-only contract.
**High:** **H1** tap targets — pause wrapped in 28×28 SizedBox, "See all"
in 24-tall SizedBox, `HitTestBehavior.opaque + Center(widthFactor: 1)`
so inner GestureDetector wins against outer header (compromise vs
Material's 48dp, documented — ~330dp test budget vs ~446dp phone).
**H2** silent auto-resume — `onPauseDiscarded` callback fires on route
change; parent shows 2s "Pause cleared — route changed" snackbar.
**H3** KDD-5 collapsed-state glyph added then reverted on user feedback
(visual competition with `Icons.repeat`); caveat stays in expanded
footnote + drilldown only. **H4** empty-state snackbar verified through
C1 callback signature change. **Medium:** **F1** collapsed pause indicator
(`Icons.pause` 10dp @ 0.5 alpha) when `_paused`. **F2** `TweenAnimationBuilder<int>`
smell audited — `begin: 0` is the seed-only value, framework substitutes
current value as new begin on rebuild (canonical, no change). **F3/P3**
hoisted `Listenable.merge` into `late final _mergedListenable` in
`initState` to eliminate per-rebuild allocation churn. **TF2** drilldown
contract test extended — pause → mutate counts → tap "See all" → assert
drilldown shows frozen values via `find.descendant(of: RebuildStatsPage)`.

Test count after hardening: 2,153 → 2,146 (banner tests rebalanced).

## 0.15.1

Hotfix for two v0.15.0 defects caught by a real-device profile run. DevTools
reported ~50–100 rebuilds while Sleuth's Build Hotspot claimed **21,352** —
the drilldown was dominated by `FloatingIssuesCard`, `IssueCard`,
`TriggerButton`, `Container`, `Padding`, `ValueListenableBuilder`,
`FadeTransition`. The v0.15.0 pipeline was measuring itself.

### Fixed

- **KDD-10 — Framework widget contamination (self-measurement).** The
  framework emission gate at `framework.dart:3503` uses
  `debugIsWidgetLocalCreation`, whose `_isLocalCreationLocationImpl` fallback
  at `widget_inspector.dart:1801-1816` returns
  `!file.contains('packages/flutter/')` when `_pubRootDirectories == null`
  (default without DevTools). So `package:sleuth/...` classifies as "user
  widget" and is emitted through `FlutterTimeline.startSync`.
  `addPubRootDirectories` is `@protected` and additive-only, so framework-
  layer exclusion is unavailable. **Fix:** `_frameworkWidgetDenyList` in
  `DebugInstrumentationCoordinator.canonicalizeTypeName` — 48 framework
  widgets used under `lib/src/ui/` + 25 Sleuth overlay widget classes.
  Checked AFTER generic stripping so `ValueListenableBuilder<int>` collapses
  first. Filter is now five layers:
  `_denyList → isRenderObjectName → identifierRegex → genericStrip → frameworkWidgetDenyList`.
  Followup audit against Flutter 3.41.4 SDK source added 3 more identifier-
  shaped frame-phase scopes (`POST_FRAME`, `COMPOSITING`, `SEMANTICS`) that
  fire ~60/sec per frame.
- **KDD-9 — Absolute-total rollup threshold was time-blind.** v0.15.0's
  `> 100 / > 300` absolute gate tripped on any long-lived route regardless
  of baseline rate. Replaced with sustained-rate: `≥ 20 builds/sec` warning,
  `≥ 50 builds/sec` critical, gated by 30-build + 1.5s noise floor. Rate
  computed via injected `DateTime Function() clock` for deterministic tests.
  Title format: `"Build Hotspot: 22.0 builds/sec (110 across 4 widgets in 5.0s)"`.

### Added

- **`test/debug/overlay_denylist_audit_test.dart`** — CI gate walking
  `lib/src/ui/**/*.dart` enforcing three invariants: every
  `Stateless/Stateful/InheritedWidget` subclass is in the denylist; every
  framework widget from a curated candidate set actually used in overlay
  code is in the denylist; no stale framework entries remain.
- **`DebugInstrumentationCoordinator.debugFrameworkWidgetDenyList`** —
  `@visibleForTesting` accessor.
- Parameterized denylist tests + rate-based threshold tests using
  test-controlled clock. Disclaimer copy updated in 3 places
  (`rebuild_detector.dart` detail, encyclopedia entry,
  `rebuild_stats_page.dart` banner) so users know overlay widgets are
  excluded from the drain.

### Changed

- `RebuildDetector` constructor takes optional `DateTime Function() clock`
  (defaults to `DateTime.now`).
- `canonicalizeTypeName` docstring updated to "five-layer filter" with
  inline KDD-10 rationale.
- Framework widgets now filtered from profile-mode drilldowns — users with
  a genuine user-space `Container` hotspot must wrap in a named subclass
  (e.g. `class ProductRow extends StatelessWidget`) to surface it.
  Disclaimer text covers this tradeoff.

Test count: 2,140 → 2,153.

## 0.15.0

Profile-mode per-widget rebuild counting via `FlutterTimeline.debugCollect()`
attributed to the active `RouteSession`. When `enableDeepDebugInstrumentation`
is true in profile, each scan cycle drains the timeline, canonicalizes every
`BUILD` scope name, and merges into `RouteSession.rebuildCountsByType`. Surfaces
as a `rebuild_hotspot_summary` rollup issue (fires at >100 session rebuilds)
with a "See all rebuilds" drilldown page. Detectors that had only structural
signal (`RebuildDetector`, `ShallowRebuildRiskDetector`, `AnimatedBuilderDetector`,
`SetStateScopeDetector`) now upgrade confidence when counts agree.

### Added

- **`DebugSnapshot.source`** (`RebuildCountSource`: `none`/`debugCallback`/
  `flutterTimeline`). Only `flutterTimeline` snapshots flow into the rollup;
  `debugCallback` stays per-detector (KDD-1).
- **`DebugInstrumentationCoordinator.installProfileMode()/uninstallProfileMode()`** —
  flips `FlutterTimeline.debugCollectionEnabled` with install-time refusal if
  flag is already true (DevTools conflict, KDD-1 + R20). Hot-restart-tolerant.
- **`canonicalizeTypeName`** three-layer filter: drops framework frame scopes
  (`BUILD`/`LAYOUT`/`PAINT`/`FINALIZE TREE`), strips generics
  (`Provider<Foo>` → `Provider`), rejects non-identifier shapes via
  `^[A-Z][A-Za-z0-9_]*$`.
- **`RouteSession.rebuildCountsByType`** (Map) + **`totalRebuilds`** with
  additive per-scan merge + JSON round-trip.
- **`rebuild_hotspot_summary` rollup issue** (emitted when
  `source==flutterTimeline && session!=null && session.totalRebuilds > 100`;
  per-type issues still fire alongside).
- **`RebuildStatsPage` drilldown** reachable via `IssueCard.onSeeAllRebuilds`
  callback (caller-gated). **Snapshot-at-open semantics (M10)** — counts
  copied at construction, never live-updates.
- **`primeExistingElements()`** coordinator helper — seeds element-seen
  Expando so the very first rebuild is counted instead of consumed as a
  first-observation placeholder.
- Encyclopedia entry for `rebuild_hotspot_summary` with bidirectional
  `relatedIssues` links.

### Changed

- **Assert-wrapper restructure (M3, 4 sites):** `_installDebugInstrumentation`,
  `_scanTree` drain, `dispose()`, `_installHeavyFlags` now use explicit
  `if (kDebugMode) {} else if (!kReleaseMode && ...) {}` mode splits.
  Previously the entire rebuild-attribution pipeline was a silent no-op in
  profile mode because `assert(() {})` stripped.
- **Drain → attribute → route-switch ordering (M7):** counts always land on
  the pre-route-change session.
- **`_scanInProgress` re-entry guard (M5)** prevents double-drain + rate
  math corruption.
- **Coordinator construction gate widened (KDD-8):** instantiated when
  `enableDebugCallbacks || enableDeepDebugInstrumentation`.

### Fixed

- **Profile-mode rebuild attribution was a silent no-op in every prior
  release** (v1 review C1/C4) — first release that actually collects data.
- **`FlutterTimeline.debugCollectionEnabled` conflict path (R20)** — install
  refuses when flag is already true.
- **Test pollution via static `FlutterTimeline._buffer`** (C6) — every
  profile test saves/restores flag in `setUp`/`tearDown`.

### Notes

- **KDD-5 semantic gap:** profile-mode counts include widget inflations
  (same `BUILD` scope covers both inflations and setState rebuilds), so route
  entry shows transient elevated counts that decay. Disclaimer surfaces
  inline on rollup detail + drilldown page.
- **R3 test limitation:** widget tests run under `kDebugMode == true`, so
  M12 controller/coordinator tests inject a fake coordinator tagged
  `RebuildCountSource.flutterTimeline` to exercise the merge pipeline
  without profile-mode compilation. Full validation is the M1 probe under
  `fvm flutter run --profile` on a physical device.

Test count: 2,092 → 2,140.

## 0.14.1

Per-tab `RouteSession` tracking for tab-shell apps (`IndexedStack`,
`StatefulShellRoute.indexedStack`, `CupertinoTabScaffold`) that share one
`ModalRoute` across tabs — each tab now gets a distinct session instead of
being conflated. Inline `TabBar` / `TabBarView` / `PageView` swipes stay inside
the outer session. One pre-impl adversarial plan review + one post-impl code
review; both folded into the code.

### Added

- **`RouteSession.scaffoldHashKey`**: `identityHashCode` of the innermost
  visible `Scaffold` Element, or `null` for scaffold-free scans. Paired with
  `routeName` to form the session's compound key.
- **`RouteSession.tabVisitIndex`**: 1-indexed ordinal for repeat visits to the
  same `(routeName, scaffoldHashKey)` pair. Used by UI + markdown exporter to
  disambiguate (e.g. `/home` → `/home (tab-2)`).
- **`RouteSession.hotReloadGeneration`**: Debug-only counter incremented on
  Flutter hot reload so consumers can group pre/post-reload sessions. `0` in
  profile/release.
- **`PerformanceIssue.scaffoldHashKey` + `tabVisitIndex`**: Stamped at
  aggregation. `routeName` kept RAW (no `(tab-N)` suffix baked in) so group-by
  filters stay stable; use **`PerformanceIssue.routeDisplayName`** getter
  (`'$routeName (tab-$tabVisitIndex)'` when `> 1`) for human-facing labels.
  UI cards, AI chat, and issue-explanation substitution all route through it.
- **`TabBarView` / `PageView` boundary filter** in the scan visitor: these
  widgets keep multiple children alive simultaneously (no `Offstage`/
  `TickerMode`/`Visibility(!visible)` marker) and used to trip the
  multi-Scaffold sibling guard, silently aborting scans. Scaffold collection
  now stops at these widgets — inline sub-tab swipes stay inside the outer
  session and detectors still run against the active sub-page.

### Changed

- **`SleuthConfig.routeHistoryCapacity` default 20 → 50**: per-tab sessions
  exhaust the old default within a few tab switches. FIFO-eviction tests now
  configure an explicit smaller cap.
- **Session markdown exporter renders tab suffix** from `tabVisitIndex`.
- `packageVersion` `'0.14.0'` → `'0.14.1'`.

### Fixed (post-adversarial review)

- **C1 `tabVisitIndex` collision after FIFO eviction**: `_computeTabVisitIndex`
  now returns `max(tabVisitIndex) + 1` across matching history entries instead
  of `count + 1`. The count-based impl could duplicate a live session's index
  once older matching entries were dropped from the deque — producing identical
  `(routeName, scaffoldHashKey, tabVisitIndex)` tuples (the exact duplicate
  rows the feature was designed to prevent). Regression test drives 8 A↔B
  switches with `routeHistoryCapacity: 3`.
- **C2 hot reload did not close active `RouteSession`**: non-structural hot
  reload preserves Element identity, so the session-keying predicate saw
  unchanged `(routeName, scaffoldHashKey)` and the pre-reload session bled
  into post-reload frames with a stale `hotReloadGeneration = 0`.
  `_reassembleInternal()` now closes `_activeRouteSession`, republishes the
  history notifier, and nulls the pointer before incrementing the generation.
- **C3 `routeName` overwrite lost raw name**: `_aggregateIssues` used to stamp
  `"$rawName (tab-N)"` into `issue.routeName`, destroying the raw name needed
  for group-by filtering. Raw preserved; display surfaces use `routeDisplayName`.
- **E1 type-unsafe `fromJson`**: per-tab field deserialization now uses `is int`
  guards and coerces non-int to null. A JS consumer stringifying large ints
  (53-bit `Number` precision) used to crash `as int?` and break the snapshot.

## 0.14.0

Route Scoping — per-route FPS, issue aggregation, health scores, and export.
Data model + programmatic API retained; overlay UI (filter bar, summary row)
removed after on-device review (historical issues not surfaceable as cards
made the filter misleading). One adversarial review, 5 findings fixed.

### Added

- **`RouteSession`**: per-route stats accumulated while a route is the active
  scan target — `healthScore` (0–100 composite: FPS 40pts + jank 30pts +
  issues 30pts, normalised to `fpsTarget`), `FrameStatsBuffer`, issue
  snapshots, scan cycle count, `toJson()`.
- **Passive route detection** via element tree walk during the unified scan
  — no `NavigatorObserver` required. Works with any router (go_router,
  auto_route, Beamer). Unnamed routes get synthetic `<unnamed-N>` names.
- **`Sleuth.routeHistory`**, **`Sleuth.routeHealthScore(name)`** static APIs.
- **`SleuthConfig.routeIgnorePatterns`** (exact + trailing `*` wildcard e.g.
  `/dialog*`) and **`routeHistoryCapacity`** (default 20, ring buffer).
- **`SleuthConfig.copyWith()`**: covers all 28 fields including 2 new route
  fields. Uses `_sentinel` pattern for nullable overrides.
- **Schema v4 export**: `SessionSnapshot.routeSessions` field with per-route
  frame stats, issue counts, health scores, FPS percentiles.
- **"Route Health" markdown table** in `Sleuth.exportSummary()` with health
  dots, FPS, issue counts, duration.

### Changed

- **Export FPS clamped to `fpsTarget`** globally + per-route (average + p50/
  p95/p99). Prevents ProMotion 120Hz idle screens from reporting values above
  the configured target.
- `packageVersion` `'0.12.1'` → `'0.14.0'`.

### Removed

- **Route filter bar + summary row from overlay**: historical issues aren't
  surfaceable as cards (only live issues appear), making the UX misleading.
  Data model, export, and programmatic API retained.
- **Route chip theme tokens**: `routeChipBg`, `routeChipSelectedBg`,
  `routeChipText`, `routeChipSelectedText`.

## 0.13.1

Dark/light mode toggle, design system tokens, `Icons.pets` brand icon, header
optimization, false-positive fix, GlobalKey demo reliability. Five adversarial
review rounds (general ×2, theme perf + design system, icon migration,
GlobalKey demo), all findings fixed.

### Added

- **`triggerIconColor` theme token** (default white — visible on severity-
  colored backgrounds in both themes).
- **In-overlay dark/light toggle** with 3-tier resolution: runtime override >
  config theme > auto-detect.
- **`Sleuth.updateTheme()`** runtime API (pass `null` to revert to auto).
- **`SleuthController.themeOverride`** `ValueListenable<SleuthThemeData?>`.
- **System brightness reactivity** via `didChangePlatformBrightness`, gated
  to auto-detect mode only.
- **Typography scale tokens** — 9 font sizes (`fontXxs`=8 → `fontDisplay`=24)
  on `SleuthThemeData`. All 8 overlay UI files migrated (~119 replacements).
- **Border radius scale tokens** — 7 radii (`radiusSm`=4 → `radiusFull`=20).
  All 8 overlay UI files migrated (~50 replacements).
- **`gripDots` light theme override** (`0xFF6B7280` gray-500 instead of the
  dark-theme white).
- **Color coupling doc** on `SleuthThemeData` constructor: intentional hex
  sharing across semantically distinct tokens + `copyWith()` independence.

### Changed

- **Brand icon: `Icons.pets`** (Material paw print) replaces dog emoji
  (`🐕`/`\u{1F415}`) and custom `SleuthLogoPainter` across trigger button,
  overlay header, guide page, example app. Tree-shaken, theme-aware.
- **Startup metrics page**: metric values right-aligned across all sections
  via `Expanded` + plain `Text`.
- **Header icon optimization**: guide icon moved to footer; highlight toggle
  36 → 24px (`_compactHeaderButton`); theme toggle added at 20px.
- **Footer Semantics consistency**: Encyclopedia/Export/Guide all wrapped in
  `Semantics(label: ..., button: true)`.

### Fixed

- **`stateful_density` false positive from Sleuth widgets**: added 8 overlay
  widget names (`SleuthOverlay`, `FloatingIssuesCard`, `TriggerButton`,
  `IssueCard`, `IssueEncyclopediaPage`, `AiChatPage`, `GuidePage`,
  `StartupMetricsPage`) to `RebuildDetector._frameworkWidgetNames`. FRAME
  mode no longer inflates structural density against itself.
- **Hardcoded spacing**: `SizedBox(width: 6)` (guide) + `SizedBox(width: 10)`
  (startup metrics) replaced with `theme.spacingXs`/`spacingSm`.
- **GlobalKey demo unreliable detection**: `itemExtent` 40 → 24dp, `itemCount`
  30 → 40 so realized GlobalKey count reliably exceeds the >20 threshold on
  all phone sizes. Old 40dp items + DemoScaffold chrome (~220-300dp) +
  trailing-only cache at scroll 0 left the count at 21-22 on medium phones
  (barely above threshold).

### Removed

- **`sleuth_logo_painter.dart`** — replaced by `Icons.pets`.

## 0.13.0

Startup Performance Tracing — measure first-frame and time-to-interactive
from `main()`, with per-phase breakdown and VM sub-phase enrichment. Three
adversarial review rounds, full 23-detector accuracy audit, causal-graph
correctness fix, and ShaderJankDetector noise removal.

### Added

- **Startup measurement API**: `Sleuth.init()` captures app start + framework
  init cost; `Sleuth.markInteractive()` records TTI; first-frame callback
  extracts vsync/build/raster breakdown from `FrameTiming`;
  `enrichStartupWithVmData()` accepts VM sub-phase + engine timestamp data.
- **`StartupDetector`** (23rd detector, structural lifecycle, one-shot): fires
  `slow_startup_ttff` when TTFF exceeds thresholds (default 1500ms warning,
  3000ms critical). Detail includes TTFF/TTI, first-frame breakdown,
  dominant phase, VM sub-phases, engine phases.
- **`StartupMetrics`**: 14 stored fields, 3 computed getters
  (`frameworkInitMs`, `preDartOverheadMs`, `engineTtffMs`), dominant-phase
  detection (50% threshold), full `copyWith`/`toJson`/`fromJson`.
- **`StartupMetricsPage`**: full-screen detail with staggered entrance
  animations, 5 conditional sections (headline, first-frame breakdown with
  progress bars, engine phases, VM sub-phases, methodology).
- **Startup metrics banner** in FloatingIssuesCard: tappable "TTFF: X ms ·
  TTI: Y ms" when data available.
- **`IssueCategory.startup`** across SleuthTheme, encyclopedia, FixHintBuilder,
  SessionMarkdownExporter, SessionSnapshot serialization.
- **`DetectorThresholds.startupTtffWarningMs`/`CriticalMs`** with validation
  asserts.

### Fixed

- **Causal graph hid `layout_bottleneck` from UI**: 8 rules made it a
  downstream effect (e.g. `setstate_scope → layout_bottleneck`). A downstream
  issue gets a `rootCauseId` and FloatingIssuesCard filters it from the
  visible list. Removed all 8 rules — `layout_bottleneck` is always a root
  cause. Rule count: 52 → 44.
- **`ShaderJankDetector` Impeller noise**: removed `shader_impeller_inactive`
  notice (fired on every page after ~2s of VM polling). On Impeller the
  detector now correctly produces zero issues.
- **`stateful_density` framework widget noise**: 32-entry
  `_frameworkWidgetNames` set + private-name filter in RebuildDetector.
- **`shallow_rebuild_risk` framework noise**: `ScrollNotificationObserver`
  added to suppressed set.
- **Clock-domain mismatch in TTFF**: monotonic `Timeline.now` delta → wall-
  clock `DateTime.now()` diff, fixes ~5-50ms skew.
- **Deferred VM enrichment buffer**: `_PendingEngineEvents` now stores all 6
  fields (4 VM sub-phases + 2 engine timestamps) — enrichment arriving before
  first-frame callback no longer lost.
- **Network issues persisted across routes**: time-based 30s staleness
  eviction replaced with route-transition clearing. Issues persist on the
  current page and clear on navigation.
- **`clearRecords()` did not clear `_activeRequests`**: in-flight tracking
  leaked across transitions, causing phantom pending-request reports.
- **`_evaluateErrors` severity/detail domain mismatch**: `serverErrors` +
  `transportFailures` were counted across the full buffer but compared
  against the 5-second peak window. All counts now scoped to the peak window.
- **In-flight responses from previous page leaked into new page**: requests
  started on page A completing after navigating to B were added to the
  buffer. `processRecord()` now drops records whose `startedAt` precedes
  the last `clearRecords()` via `_ignoreBeforeTimestamp`.

## 0.12.2

Post-Codex adversarial review hardening — three robustness fixes on the v11 branch.

### Fixed

- **Timeline pipeline exception isolation** (`SleuthController._onTimelineData`):
  `try/finally` around `_isIteratingDetectors` flag + per-detector `try/catch`
  around `processTimelineData` and `evaluateNow`. Matches the structural walk's
  isolation. A throwing custom detector in the VM pipeline used to leave
  `_isIteratingDetectors = true` permanently, deadlocking detector mutations.
- **Encyclopedia placeholder leak** (`IssueEncyclopediaPage`): raw
  `{widgetName}` / `{count}` tokens were visible when browsing without a
  context issue. Now applies `IssueExplanationBuilder.substitute()` to all
  entries with a static sentinel triggering built-in fallbacks (`'the widget'`,
  `'several'`).
- **Cookbook `SlowFrameDetector` staleness**: one slow frame could keep the
  detector reporting indefinitely because the rolling window only tracked
  slow frames (fast frames never evicted). Added `_TimestampedFrame` wrapper
  + 10s age eviction in `finalizeScan()`.

## 0.12.1

Pillar 6 Part 2: Overlay UI, Diagnostics Output & Export — upgrades every
consumer-facing surface (trigger button, floating card, issue card,
encyclopedia, export path).

### Added

- **M1 trigger button alignment**: `triggerButtonAlignment` +
  `triggerButtonOffset` on `SleuthConfig`. Four corners + center.
- **M2 minimize/maximize/restore**: 3-state window mode (`normal`/`minimized`/
  `maximized`) on the floating issues card. Minimized collapses to 54px
  header; maximized fills screen minus safe area; pre-transition geometry
  restored exactly.
- **M3 recurrence badge on IssueCard**: trending direction (escalating/stable/
  improving/new) from `RecurrenceTrend`.
- **M4 context-aware encyclopedia**: `IssueExplanationBuilder.substitute()`
  replaces `{widgetName}`, `{count}`, `{routeName}`, `{severity}`, `{title}`,
  `{stableId}` with triggering issue values. 7 templates enriched.
- **M5 inline confidence reasoning** on expanded IssueCard.
- **M6 dismissible debug-mode banner** on `FloatingIssuesCard` when
  `isDebugMode` is true. `showDebugModeBanner` config opt-out.
- **M7 `Sleuth.exportSummary()`** markdown export — frame stats, top issues,
  causal chains. Sized for Slack/PR paste.
- **M8 copy-conversation button** on AiChatPage — full AI thread + issue
  context to markdown on clipboard.

### Fixed

- **Tooltip crash in overlay** (IssueCard): `Tooltip` in `_confidenceBadge`
  → `Semantics`. Flutter 3.41.4's `Tooltip` uses `OverlayPortal` requiring
  `_RenderTheaterMarker` ancestor — absent in Sleuth's bare `Overlay` stack.
  Confidence reason now shown inline when expanded (M5) + as a11y label.
- **M7/M8 GFM escaping**: `_copyConversation` + `SessionMarkdownExporter._escape`
  now cover all 8 GFM-significant chars (`\`, `*`, `` ` ``, `#`, `[`, `]`,
  `<`, `>`, `|`) vs previous 2. Prevents structure corruption in issue titles,
  confidence reasons, message text.
- **M3 recurrence badge overflow**: `maxLines: 1` + `TextOverflow.ellipsis` +
  `Align(centerLeft)` to avoid overflow on narrow cards.
- **Semantic labels** on AI chat back/copy and floating card window controls
  (minimize/maximize/restore/dismiss-banner).
- **Cookbook `TooltipUsageDetector` false positives**: framework tooltip
  message filter (`Back`, `Close`, `Open navigation menu`, etc.) so AppBar
  back button etc. no longer flagged on every screen.

## 0.12.0

Pillar 6 Part 1: Public API & Authoring Surface — presets, threshold
documentation, debug-mode validation, `Duration`-typed intervals,
`SimpleStructuralDetector` base, key-based gating for custom detectors,
three-file custom-detector cookbook.

### Breaking

- **`SleuthConfig.treeScanInterval` now takes `Duration` instead of `int` ms.**
  Old `treeScanIntervalMs` removed. `int ms` was the most frequent foot-gun
  in user reports because nothing about the call site communicated the unit.

  ```dart
  // Before:  SleuthConfig(treeScanIntervalMs: 1000)
  // After:   SleuthConfig(treeScanInterval: Duration(seconds: 1))
  ```

### Added

- **M1 `SleuthConfig.minimal()` / `.performance()` presets**. `.minimal()`
  enables safe structural + runtime detectors and disables opt-ins (network,
  debug callbacks, deep instrumentation, AI chat). `.performance()` is tuned
  for low-overhead profile runs (structural only, 2s scan interval, capture
  buffer off).
- **M2 threshold documentation**: every `SleuthConfig` + `DetectorThresholds`
  threshold has a doc comment (meaning, default, tuning effect). Copy
  verified against each detector's gating code.
- **M3 debug-mode assert validation**: `SleuthConfig` + `DetectorThresholds`
  constructors fail fast in debug for misbehaving values (negative intervals,
  thresholds above detector cut-offs, frequency windows dividing to zero).
- **M5 `SimpleStructuralDetector`** helper base class — override `inspect(Element)`
  + call `report(...)` instead of implementing 4 lifecycle methods. Handles
  issue list, highlight list, enabled flag, per-scan reset. Exported from
  `package:sleuth/sleuth.dart`.
- **M6 custom detector key gating**: `BaseDetector.key` +
  `SleuthConfig.disabledCustomDetectorKeys: Set<String>`. Stable-keyed
  customs can be disabled via config without being removed from the list.
  Built-ins are gated by `DetectorType` via `enabledDetectors`.
- **M7 custom detector cookbook** — `example/lib/custom_detectors/`:
  `TooltipUsageDetector` (`SimpleStructuralDetector`), `SlowFrameDetector`
  (runtime + `SchedulerBinding.addTimingsCallback`), `RasterHotSpotDetector`
  (hybrid: VM raster timings + structural walk). README index, cookbook demo
  screen wired into `Sleuth.track`, `example/test/cookbook_smoke_test.dart`
  validates each against the public `package:sleuth/sleuth.dart` barrel.

### Fixed

- **Real-device first-launch VM connection**: `Service.getInfo()` →
  `Service.controlWebServer(enable: true)` to proactively start the VM web
  server on cold start. USB/WiFi launches from Android Studio used to leave
  Sleuth stuck in BASIC/FRAME mode the entire session because the web server
  hadn't bound its port.
  - 3s owned-timer timeout (no `Future.timeout` leak in tests)
  - `_connectInFlight` concurrency guard
  - IPv4→localhost rewrite for dual-stack Happy Eyeballs
  - Background reconnect ladder (500ms → 30s, 7 attempts) with mid-session
    VM-death recovery
  - Manual `reconnect()` method for "Tap to reconnect" overlay hook
- **`frameStatsNotifier` self-feedback loop**: notifier throttled to ~5 Hz
  (200ms min). 60 Hz emission made Sleuth's own overlay rebuilds dominate
  VM build-event counts and trip false `rebuild_activity` on idle screens.
- **Unified walk exception isolation**: per-detector try/catch in the visitor.
  One throwing custom detector in `checkElement` used to kill the walk for
  all 16 detectors and skip the entire subtree.
- **Post-dispose guards**: `_disposed` checks after every `await` in
  `VmServiceClient._connectImpl` to prevent leaked VmService instances +
  poll timers when dispose races with connect setup.
- README quick-start shows `SleuthConfig.minimal()` alongside the full config.

### Tests

- 1,825 → 1,869 (+44 across M1–M7, VM connection, throttle coverage).
- 5 cookbook smoke tests in `example/` confirm public-API compilation +
  live tree flagging.

## 0.11.1

Pillar 5 Part 2: Demo Quality Enhancements & Combined Demos — Before/After toggle,
live metrics bars, reproduction instructions, and two multi-detector scenarios
(E-Commerce + Chat). Three adversarial review rounds, 18 findings resolved (9
P5P2 + 4 polish + 5 demo↔detector alignment) plus a `KeepAliveDetector`
false-positive fix uncovered during chat demo migration.

### Added (M8–M14)

- **M8 Before/After toggle in DemoScaffold**: upgraded to `StatefulWidget`.
  When a demo supplies `fixedBody`, a `SegmentedButton` swaps the anti-pattern
  for its fix in-place. The ternary fully unmounts the hidden side so timers/
  animations/controllers stop automatically. Optional `onToggle` callback.
- **M9 Fixed-pattern implementations for all 23 demos** — real working fix
  bodies, not text: `ValueNotifier` + `ValueListenableBuilder` for setState
  scope, `ListView.builder` + `itemExtent`, `cacheWidth/Height`, `GlobalKey`
  as final fields, extracted `AnimatedBuilder.child`, `Isolate.run()`, etc.
- **M10 Live metrics bar** — `MetricsBar` + `MetricChip`. Wired into
  `high_level_setstate` (Bad/Fixed rebuilds), `non_lazy_list` (built count),
  `heavy_compute` (ms), `fps_stress_test` (FPS via
  `SchedulerBinding.addTimingsCallback`), `repaint_stress` (paints/sec
  sliding window), `network_stress` (request count), `memory_pressure`
  (retained MB). Resets on toggle.
- **M11 `❌ BAD / ✅ FIX / ▶ <action>` format** on every demo description.
- **M12 Combined E-Commerce demo** — 5 anti-patterns: 6-hero carousel
  full-res (ImageMemory), rotating price `AnimatedBuilder` no child, size
  chip row in `IntrinsicHeight` (LayoutBottleneck), 200-review non-lazy
  `ListView`, 4 `GlobalKey()` per build. Fixed body: all fixes + `Visibility`
  swap for previously `Opacity(0.0)` banner.
- **M13 Combined Chat demo** — tabbed 5-conversation UI using
  `AutomaticKeepAliveClientMixin` (KeepAlive), uncached circular avatars
  (ImageMemory), 40ms simulated-channel typing poll (PlatformChannelTraffic
  at 25 calls/sec > 20/sec threshold), top-level `setState` per message
  (SetStateScope + Rebuild). Fixed body debounces the poll, caps keep-alive
  to 2 tabs, isolates message list in `ValueNotifier`, extracts text input
  into own `StatefulWidget`. `debugProfilePlatformChannels` saved/restored
  on dispose.
- **M14 Home screen wiring**: E-Commerce + Chat in "Combined" category. Demo
  count 23 → 25.

### Adversarial Review (P5P2, 9 findings)

Focused on: (a) does each demo's "fix" actually eliminate the detector vs
merely mask it; (b) do new StatefulWidget demos leak timers/controllers/
client handles.

- **CRITICAL FAB double-action neutralized fix** (3 demos:
  `combined_analytics_dashboard`, `combined_social_feed`, `high_level_setstate`):
  FAB called both counter++ AND unconditional `setState(() {})`. Even with
  fixed body switched on, outer State's top-level setState rebuilt the whole
  subtree, burying `ValueListenableBuilder`'s isolated update. Worst in
  `high_level_setstate` because `_FixedBody`/`_FixedGrid` aren't const —
  top-level rebuild hit every tile. Fix: `_isFixed` field synced via
  `onToggle`; FAB only setStates when `!_isFixed`.
- **CRITICAL E-Commerce hero carousel never reached ImageMemoryDetector
  threshold**: detector fires at `count > 5`, but horizontal `ListView.builder`
  only realized 2–4 hero items due to 250px default `cacheExtent`. Fix:
  `SingleChildScrollView` + `Row` forces all 6 heroes into the tree; fixed
  version keeps `cacheWidth: 520`.
- **HIGH "fixed" reviews ListView wasn't paginated**:
  `ListView.builder(shrinkWrap: true, physics: NeverScrollable)` inside
  `SingleChildScrollView` under infinite main-axis constraints realizes every
  one of 200 items. Fix: `SizedBox(height: 480)` bounds the inner viewport;
  ~8 items realized.
- **HIGH HttpClient leak on mid-request dispose** (`network_stress_demo`):
  `_triggerFrequencySpike` awaited `Future.wait([40 gets])` then early-
  returned on `!mounted` before `client.close`. Fix: moved close into
  `finally`.
- **MEDIUM unbounded log growth** (`network_stress_demo`): `_maxLogLines = 200`
  with trim-on-append.
- **MEDIUM unbounded message list growth** (`combined_chat_demo`): 40ms timer
  did `[...notifier.value, msg]` per tick. `_maxMessagesPerTab = 100` via
  `_appendCapped` helper dropping oldest when full.
- **LOW narrow exception handling in typing poll**
  (`combined_chat_demo._startBadTypingPoll`): only caught
  `MissingPluginException` + `PlatformException`. Added `catch (_)` fallback
  + `mounted` guard.

Second-order checks: `_isFixed` gate is synchronous from `onToggle` (setState
in `_handleToggle` runs before `widget.onToggle?.call`); `try/finally` in
`_triggerFrequencySpike` runs on throw-during-await; 480px review viewport
shows a page but only realizes ~8 items.

### KeepAliveDetector False-Positive Fix

Symptom: chat fixed mode (2 of 6 tabs opting in) reported the same "excessive
keep-alive" as bad mode. Two layered bugs:

1. Detector matched `KeepAlive` widgets by type name, but Flutter's
   `AutomaticKeepAlive.build()` ALWAYS wraps its child in
   `KeepAlive(keepAlive: ...)` — string match counts every page regardless.
2. Fallback to `element.widget.keepAlive` is also wrong: `AutomaticKeepAlive`
   updates the child render object's parent data via
   `ParentDataElement.applyWidgetOutOfTurn()` — it mutates the render object
   but does NOT replace `element.widget`, so `widget.keepAlive` stays stale
   at the initial `false`.

Fix: read `element.renderObject.parentData` and cast to
`KeepAliveParentDataMixin` — the authoritative framework signal. New
`_isActiveKeepAlive()` helper in `keep_alive_detector.dart`. 2 regression
tests (`_OptOutKeepAlivePage`, `_ConfigurableKeepAlivePage`). Test count:
1,823 → 1,825.

### Review Round 5 — Migrated Demo Polish (4 findings)

1. **CRITICAL `non_lazy_list_demo`**: `builtCount.value = 0` at build start.
   On rebuild, `notifyListeners` marked ancestor `ValueListenableBuilder` in
   MetricsBar dirty during build phase, risking "setState during build"
   assert. Fix: reset moved to `_handleToggle`.
2. **TEXT `combined_chat_demo`**: description said "cacheWidth: 48" vs code's
   `64`; comment said "48px for 24×24" vs 32×32 display. Aligned to 64 and
   32×32.
3. **TEXT `combined_ecommerce_demo`**: description "cacheWidth: 400" vs code
   `520`. Aligned.
4. **CONVENTION `fps_stress_test_demo`**: missing `▶ action` marker.

### Review Round 6 — Demo ↔ Detector Alignment (5 findings)

Tightened detectors (Pillars 2a/2b/3a/3b + v11 audit) had silently drifted
demos below trigger threshold.

| # | Demo | Cause | Fix |
|---|------|-------|-----|
| 1 | `global_key_demo` | 15 keys but `threshold = 20`; description mis-stated as 10 | `_itemCount` → 25; corrected description |
| 2 | `non_lazy_list_demo` | 40 children but `childThreshold = 50` (fires on `> 50`) | `_itemCount` → 60 |
| 3 | `animated_builder_demo` | 6 bars built ~14-widget subtree, below `minSubtreeSize = 50` | `_barCount = 12`; richer `Row(SizedBox(label) + Expanded(LinearProgressIndicator) + SizedBox(%))` → ~135 widgets. `_StaticBarColumn` mirrors |
| 4 | `combined_analytics_dashboard_demo` | 25 tiles below ListView threshold; 25 GlobalKeys in `SingleChildScrollView+Column` (wrong scope — excessive branch gated by `_isInListLikeScrollable`); recreation never fired because keys were stable final `_tileKeys` | `_tileCount` → 60; removed `_tileKeys`; in-build `final tileKeys = List.generate(...)`; wrapped `_BadDashboard` in outer `AnimatedBuilder(animation: _controller)` for per-tick rebuilds. Nets: ListviewDetector (60>50) AND GlobalKey **recreation** (`churnCount = 60 ≥ 5`). Mirrors `combined_ecommerce_demo`'s pattern |
| 5 | `nested_scroll_demo` | ONE `SingleChildScrollView` with 30 children — no nesting AND below threshold. `NestedScrollDetector` needs `parentAxis != null && scrollAxis == parentAxis` + `childCount > 50` | `_itemCount` → 60; wrapped in outer `SingleChildScrollView > Column > SizedBox(height: 480) > SingleChildScrollView`. Bounded 480px viewport keeps inner scrollable from crashing on unbounded height |

**Key insight:** `GlobalKeyDetector` has **two modes with different scoping**.
Excessive branch (`global_key_detector.dart:131`) is gated by
`_isInListLikeScrollable` (only counts inside LV/GV/PV). Recreation branch
(`global_key_detector.dart:113-116`) collects `identityHashCode(key)`
**globally** in `checkElement`, NOT gated by scrollable scope. Trigger
recreation by allocating new keys inside any repeatedly-built widget.

**Demos dismissed (already fire):** `custom_painter`, `font_loading`,
`gpu_pressure`, `heavy_compute`, `high_level_setstate`, `intrinsic_height`,
`network_stress`, `opacity_zero`, `platform_channel`, `repaint_boundary`,
`repaint_stress`, `shader_jank`, `shallow_rebuild_risk`, `uncached_image`,
`combined_chat`, `combined_ecommerce`, `combined_social_feed`. Each traced
through `checkElement` against current thresholds.

## 0.11.0

Pillar 5 Part 1: Demo Infrastructure & Missing Detector Demos — DemoScaffold +
5 new demos + categorized home screen. Two adversarial review rounds.

### Added (M1–M7)

- **M1 DemoScaffold**: shared layout with collapsible description banner,
  AppBar, Expanded body slot. `BAD:`/`FIX:` annotations.
- **M2 Shader Jank demo**: `BackdropFilter(σ=20)` + `ShaderMask` +
  `ColorFiltered` + combined effects. Impeller caveat (pre-compiled shaders).
- **M3 Platform Channel Traffic demo**: rapid fire (50 concurrent), sustained
  (50/sec via `Timer.periodic`), single-call modes + scrollable log. Timer
  cancelled in `dispose`.
- **M4 Memory Pressure demo**: Dart-heap (+10MB Maps) vs native (+10MB
  `Uint8List`) buttons, GC churn mode (100 batches retain first only), bar
  chart. Per-batch KB tracking.
- **M5 GPU Pressure demo**: 10 cards each stacking
  `ClipPath(antiAliasWithSaveLayer)` → `Opacity(0.85)` →
  `BackdropFilter(σ=15)` → `ColorFiltered`, >5 descendants per node.
- **M6 RepaintBoundary demo**: uses `SingleChildScrollView+Column` (not
  `ListView.builder` which auto-wraps in RepaintBoundary). 14
  `Opacity(0.7)` cards + 1 animated `CustomPaint`. Controller disposed.
- **M7 Home screen categorization**: 8 categories (Build, Paint, GPU &
  Rendering, Layout, Memory, Network & I/O, Keys & Identity, Combined).

### Review Round 1

- **Memory MB overcount**: `_dartMB` multiplied `_dartObjects.length * 10`,
  but GC Churn retained a sentinel batch counted as full 10MB. Fixed with
  per-batch KB tracking (`_dartBatchKB` list).
- **Hardcoded light-theme color**: `Colors.grey.shade100` unreadable in dark
  mode. → `Theme.of(context).colorScheme.surfaceContainerLow`.

### Review Round 2

- **CRITICAL GC rate dilution**: `MemoryPressureDetector._evaluateGcPressure`
  used `gcPerMinute = _gcEventCount / elapsedSec * 60` — denominator grew
  unbounded across a session, so 60s of unrelated demos diluted the count
  below the 30/min threshold even when the last 5s clearly showed pressure.
  Fix: 10s sliding window (`Queue<({DateTime ts, int count})> _gcWindow`)
  with timestamp-based eviction — stable "events per 10s × 6" rate
  responsive to real bursts. 55 tests still pass.
- **HIGH setState-after-dispose in platform channel demo**:
  `_triggerRapidFire` / `_triggerSingle` awaited without `mounted` guard
  before setState. Added `if (!mounted) return;` after each await +
  internal `_addLog` guard.
- **HIGH global `debugProfilePlatformChannels` clobber**: demo hardcoded
  `= false` on dispose, stomping developer's global setting. Now captures
  prior value in `initState`, restores in `dispose`.
- **MEDIUM "Dart Heap" label misleading**: counter tracked only *retained*
  allocations, stayed at 0 during GC Churn. Renamed "Retained (Dart)";
  description explains transient churn.
- **MEDIUM RepaintBoundary demo description inaccurate**: detector checks
  non-trivial opacity values (0.0 < x < 1.0) without RepaintBoundary
  ancestor within 5 levels, not "Opacity(0.7) with 6+ descendants". Rewrote
  to enumerate the 6 flagged classes (Opacity, ClipPath, BackdropFilter,
  ShaderMask, CustomPaint, ColorFiltered).
- **MEDIUM Impeller silent failure in shader jank demo**:
  `ShaderCompilation` timeline events only fire on Skia; Impeller (iOS
  3.16+, Android 3.22+) pre-compiles offline. No public Dart API for
  backend detection — added `_ImpellerWarningBanner` instructing
  `--no-enable-impeller` relaunch.

## 0.10.9

Pillar 4: Issue Documentation Quality — encyclopedia content for all 46 issue
types, cross-references, enriched explanations, and quality guardrail tests.

### Added

- **v11.20 8 missing encyclopedia entries**: `duplicate_request`,
  `wrap_layout_bottleneck`, `sliver_to_box_adapter_large`,
  `sliver_fill_remaining_scrollable`, `sliver_to_box_adapter_shrinkwrap`,
  `global_key_recreation`, `excessive_repaint_boundary`, `runtime_font_loading`.
  Total 38 → 46. Every detector stableId now resolves.
- **v11.21 stale count fix**: removed hard-coded "37 issue types" doc comment;
  added missing `http_error_spike` to test coverage.
- **v11.22 readingTheData on all 46 entries** with real-world analogies,
  threshold interpretation, normal-vs-abnormal guidance.
- **v11.23 Build-phase enrichment**: `heavy_compute` howToFix adds
  `Isolate.run()` vs `compute()`; `setstate_scope` adds
  `ValueListenableBuilder` extraction; `animated_builder_no_child` explains
  `child` reuse.
- **v11.24 Memory/image**: `gc_pressure` adds micro-stutter + const ctor;
  `heap_growing` adds DevTools Memory walkthrough (retained vs shallow);
  `uncached_images` adds `ResizeImage`.
- **v11.25 Paint/layout**: `excessive_repaint` adds RepaintBoundary "island"
  concept; `missing_repaint_boundary` adds when-NOT-to-add; `layout_bottleneck`
  adds `CrossAxisAlignment.stretch`; `opacity_zero` adds `Visibility` flags
  (`maintainSize`/`State`/`Animation`).
- **v11.26 Raster/network/scroll**: `shader_compilation` adds Impeller context;
  `platform_channel_traffic` adds Pigeon + EventChannel patterns;
  `non_lazy_list` adds `ListView.builder` + `itemExtent`; `nested_scroll_same_axis`
  adds `CustomScrollView` migration.
- **v11.27 `relatedIssues`** field on `IssueExplanation`: all 46 entries
  populated with bidirectional cross-references from the causal graph (52
  rules). If A lists B, B lists A.
- **v11.28 Related issues UI**: "Related issues" section with tappable chips
  that expand and scroll to the target entry. AI context includes related
  issues in system prompts. Search matches related-issue display names.
- **v11.29 Guardrail tests**: word counts (whatItIs ≥ 20, whyItMatters ≥ 20,
  howToFix ≥ 30), metric thresholds in readingTheData (≥ 25/46), analogy
  patterns, code examples (≥ 10), DevTools refs (≥ 5), stableId completeness.

### Adversarial Review

- **CRITICAL chip scroll-to bug**: related-chip tap used a single
  `_scrollTargetKey` pointing to the initial `scrollToStableId` only, not the
  tapped chip's entry. Fix: per-entry `Map<String, GlobalKey> _entryKeys`.
- **LOW missing bidirectional relatedIssues**: `repaint_debug` was the only
  runtime entry without cross-refs. Added links to `excessive_repaint`,
  `excessive_repaint_debug`, `missing_repaint_boundary` (+ reverse).
- **LOW content below quality thresholds**: enriched `raster_cache_growing`,
  `gc_pressure`, `heavy_compute`, `expensive_gpu_nodes`, `excessive_repaint_debug`
  with specific numeric thresholds.

## 0.10.8

Pillar 3b: Enrichment — output & presentation.

### Added

- **`confidenceReason` on every issue**: explains *why* confidence is
  confirmed/likely/possible and what would upgrade it. Confirmed: "Measured
  directly from {source}". Likely: "{evidence1} + {evidence2}". Possible:
  "Structural scan only — {upgrade hint}". Correlator appends escalation
  context. Shown as tooltip on the IssueCard confidence badge.
- **Severity auto-escalation**: warning issues persisting 30+ cumulative scan
  cycles auto-escalate to critical. Uses existing `RecurrenceTrend.presentCount`
  — no separate state map.
- **Two new correlator rules**:
  - `EscalateStructuralWithJankRule`: `non_lazy_list`, `layout_bottleneck`,
    `nested_scroll`, etc. possible → likely when `sustained_jank`/
    `jank_detected` co-occurs.
  - `EscalateStructuralWithRebuildRule`: `animated_builder_no_child`,
    `setstate_scope` possible → likely when `rebuild_activity` co-occurs.
- **Code location precision**: `buildAncestorChain()` appends `file:line` for
  every non-framework ancestor (not just leaf). New `lookupStructured()` with
  package-name extraction; new `packageName` field on `PerformanceIssue`.
- **`sessionSummary` export**: pre-computed 5 fields in `SessionSnapshot` —
  `topIssues` (top 5 by rank), `causalEdges`, `frameHistogram` (<16/16–33/
  33–50/50–100/>100ms), `detectorHitRates`, `memoryTrendSummary`. Schema v3,
  backward compatible with v2.

### Review (Pillar 3b)

- **Missing stableId prefix mappings**: `_detectorNameFromStableId()` missed
  `shader_compilation` (shaderJank), `repaint_debug_` (repaint),
  `stateful_density` (rebuild) — fell through to 'custom' in hit rates. Added.

### Full Branch Review (Pillars 1–3)

- **HIGH scan chain exception safety**: adaptive self-rescheduling scan loop
  could die permanently if a detector threw during `_runStructuralScans()` /
  `_aggregateIssues()`, leaving `_isIteratingDetectors` stuck true. Fix:
  `try/finally` in `_scanTree` + `try/catch` in `_scheduleNextScan` callback
  (always reschedules).
- **HIGH unstable duplicate-request stableIds**: `duplicate_request:$dupIndex`
  used a per-scan loop index that jittered as records aged in/out, breaking
  recurrence + duration escalation. Fix: derive stableId from stable
  method+URL hash fingerprint.
- **MEDIUM POST false duplicates**: grouped by method+URL ignoring body. Fix:
  limit duplicate detection to idempotent methods (GET/HEAD/OPTIONS).
- **MEDIUM GlobalKey recreation false positive on route change**: cross-scan
  key identity not scoped to stable route. Fix: track scan root identity and
  reset previous key set on route change.
- **MEDIUM missing sliver stableIds in correlator**:
  `EscalateStructuralWithJankRule` covered only legacy list IDs, missing 5
  Pillar 1 sliver IDs. Added to `_structuralIds`.

## 0.10.7

Pillar 3a: Enrichment — analysis & tracking.

### Added

- **Causal rules expanded 37 → 52**: 15 new entries (8 patterns) — setState →
  rebuild, uncached images → GC pressure, animated builder → repaint, layout
  bottleneck → jank, font loading → jank, platform channel → heavy compute,
  duplicate requests → rebuilds.
- **`RecurrenceTrend`**: ring-buffered (cap 60) per-issue presence tracker
  with `TrendDirection` (worsening/improving/stable/intermittent). Replaces
  flat `_recurrenceCounts`. Stale eviction after 120 absent cycles. Exported
  as summary (trend + counts, not raw ring buffer).
- **Interaction context** gains `typing` and `appLifecycle`. Keyboard via
  `WidgetsBindingObserver.didChangeMetrics()` (debounced); lifecycle via
  `didChangeAppLifecycleState()`. Priority: navigating > typing > scrolling
  > idle > appLifecycle (deprioritized alongside scrolling in ranking).
- **`WidgetHeatMapEntry`**: per-widget issue aggregation for "top offenders",
  filters ~50 framework widget names (layout primitives, scrollables,
  scaffold/chrome, builders, buttons). Sorted by cumulative ranking score.
  Exported.
- **Fix verification**: `FixBaseline` + `FixVerificationResult`, 5-cycle
  cooldown before declaring resolved, 3-cycle hot-reload grace period (resets
  absence counters on reassemble). Status:
  resolved/improved/unchanged/worsened/newIssue. API: `Sleuth.captureBaseline()`,
  `compareToBaseline()`, `hasBaseline`, `clearBaseline()`.

### Review

- **Incomplete framework-widget filter**: `_frameworkPrefixes` missed ListView,
  GridView, Scaffold, AppBar, buttons etc. Heat map surfaced framework widgets
  as top offenders. Added 18 names across scrollables, scaffold/chrome, buttons.
- **Grace period did not reset baseline counters**: `notifyReassemble()` set
  the grace period but not `consecutiveAbsentCycles` — hot reload after 4
  absent + 1 more falsely reported resolved. Now clears on reassemble.

## 0.10.6

Pillar 2b: Resource management — reduce Sleuth's own CPU/memory/GC overhead
when the app is healthy.

### Added

- **M4 adaptive scan frequency**: `Timer.periodic(1s)` → self-rescheduling
  `Timer`. After 3 clean cycles interval doubles (capped 2s); returns to
  normal on next issue. FrameTiming + VM timeline paths remain event-driven.
  Opt out via `SleuthConfig(adaptiveScanEnabled: false)`.
- **M5 `_getAllIssues()` generation-counter cache**: method is called 4+
  times per timeline event — cached list returned when no detector produced
  fresh issues. Generation increments on structural scan, timeline evaluateNow,
  frame stats update.
- **M6 Detector lazy initialization**: factory-map pattern; only detectors
  in `enabledDetectors` constructed. `enableDetector()`/`disableDetector()`
  for runtime toggling. 3 typed (frameTiming/memoryPressure/networkMonitor)
  always constructed (special access patterns). Custom always present.
- **M7 Debug callback `TypeNameCache`** (private Map<Type, String> in
  `DebugInstrumentationCoordinator`): replaces per-callback
  `runtimeType.toString()` (~1,000 string allocs/sec). Separate from the
  global cache (not cleared per scan). Bounded naturally (~50–200).

### Review

- **M4 timer leak after dispose**: `_scheduleNextScan()` could create an
  orphan timer chain if `dispose()` ran mid-callback. Fix: `_disposed` guards
  at method entry, timer callback entry, post-frame callback entry.
- **M4 parallel timer chains**: rapid `startTreeScanning()` (e.g. hot reload
  remount) could create duplicate chains. Fix: `_scanTimerGeneration` counter
  — stale callbacks bail out.
- **M6 concurrent detector modification**: enable/disable could mutate
  `_detectors` during iteration. Fix: `_isIteratingDetectors` guard; mutations
  deferred to `_pendingDetectorMutations`, drained after iteration. Typed
  flag-flips remain immediate.

## 0.10.5

Pillar 2a: Hot-path optimizations.

### Added

- **M1 `TypeNameCache`**: shared `Map<Type, String>` eliminates redundant
  `runtimeType.toString()` during the unified walk. On a 5K-element tree with
  ~50 unique types: ~15,000 → ~50 allocations per scan. Applied across 11
  detectors + `buildAncestorChain`.
- **M2 Highlight dirty-check**: `_collectHighlights()` skips list spread +
  generation increment + notifier update when no highlights exist before or
  after the scan. Eliminates CustomPainter repaint every scan cycle during
  normal operation. Defensive selected-highlight clearing.
- **M3 Timeline parser case-matching**: `toLowerCase()` per-event → direct
  multi-case matching for all known Flutter variants (BUILD/build/Build,
  LAYOUT/layout/Layout, etc.). Eliminates 2 string allocs/event.

### Review

- **M2 stale selected highlight**: traced all paths; zero→zero cannot leave
  `selectedHighlightNotifier` stale (non-empty→empty always triggers full
  collection). Added defensive null-clear.
- **M1 custom detector cache reuse**: verified customs calling `scanTree()`
  after the walk reuse cache entries from the same cycle.
- **M3 timeline case coverage**: verified all v2.x + v3+ variants covered;
  `_isChannelEvent` handles `'Platform Channel send ...'`.

## 0.10.4

v11.19 — Sliver anti-patterns in `ListviewDetector`.

### Added

- **3 new `ListviewDetector` checks** for CustomScrollView misuse:
  - **A** `SliverToBoxAdapter` wrapping `Column`/`Row` with > 50 children
    (warning > 50, critical > 150) — defeats lazy loading.
  - **B** `SliverFillRemaining(hasScrollBody: false)` containing a scrollable
    child (ListView/GridView/CustomScrollView/SingleChildScrollView) — forces
    shrinkWrap + eager building.
  - **C** `SliverToBoxAdapter` wrapping shrinkWrap `ListView`/`GridView` —
    forces eager measurement.
- Dedup prevents double-reporting when non-lazy + shrinkWrap checks overlap.
- 3 new `FixHintBuilder` methods with replacement patterns.

### Review

- **Check B false negative**: SingleChildScrollView inside
  `SliverFillRemaining(hasScrollBody: false)` was caught by the SCSV branch
  first. Fix: record finding before running non-lazy list check; removed dead
  code from later branch.
- **Missing test coverage**: added 2 tests for Check B with SCSV and
  CustomScrollView descendants.

## 0.10.3

v11 detector audit Part 3 (v11.13–v11.18).

### Added

- **v11.13 builder-widget suppression**: `FrameTimingDetector` 3× threshold
  multiplier for `StreamBuilder`/`FutureBuilder`/`ValueListenableBuilder`
  (designed to rebuild often).
- **v11.14 warmup frame suppression**: `FrameTimingDetector` suppresses jank
  during the first 180 frames (~3s @ 60fps). Configurable via
  `SleuthConfig.frameTimingWarmupFrameCount`.
- **v11.15 duplicate request detection**: `NetworkMonitorDetector` flags ≥ 3
  identical requests (method + normalized URL) clustered within 500ms.
  Indexed stableIds (`duplicate_request:0`, `:1`). Critical at ≥ 10.
- **v11.16 GlobalKey recreation**: `GlobalKeyDetector` tracks
  `identityHashCode` across scans; symmetric churn (new ≈ gone) indicates
  keys recreated in `build()` vs stored in `State`. Asymmetric (navigation)
  filtered. Threshold default 5.
- **v11.17 KeepAlive subtree cost**: `KeepAliveDetector` reports avg subtree
  size per scrollable in issue detail (concrete cost beyond page counts).
- **v11.18 thread-attributed jank**: `FrameTimingDetector` classifies jank as
  UI-bound/raster-bound/pipeline stall/mixed from phase timestamps. Title
  includes bottleneck label; detail includes thread timing.

### Review

- **NetworkMonitor maxCluster overwrite**: sliding window count overwrote
  previous larger values. Fix: `if (clusterSize > maxCluster)`.
- **NetworkMonitor non-indexed stableId**: `duplicate_request` shared across
  endpoints → `duplicate_request:$dupIndex`.
- **3 boundary tests**: duplicate cluster at exactly 500ms window, cluster at
  501ms (split), maxCluster regression.

## 0.10.2

v10 roadmap (12 milestones) + v11 detector audit (12 milestones).

### v11 Audit Part 1 — Accuracy & Detection (v11.1–v11.6)

- **v11.1 `SliverChildListDelegate` detection**: `ListviewDetector` catches
  `ListView(children: [...])`, `GridView(children: [...])`, and
  `CustomScrollView > SliverList(delegate: SliverChildListDelegate([...]))`
  — non-builder constructors that build eagerly.
- **v11.2 `NeverScrollableScrollPhysics` suppression** in `NestedScrollDetector`
  when inner uses `NeverScrollableScrollPhysics` or is in `NestedScrollView`.
- **v11.3 Framework `IntrinsicWidth` suppression**: no flag inside
  `DropdownButton`/`AlertDialog`/`ExpansionTile`.
- **v11.4 `Wrap` excessive children**: `LayoutBottleneckDetector` flags
  `Wrap` with > 30 children.
- **v11.5 Const subtree discounting**: `SetStateScopeDetector` tracks
  element identity across scans; discounts const subtrees from rebuild scope
  count when rebuild evidence exists.
- **v11.6 Excessive `RepaintBoundary`**: `RepaintBoundaryDetector` flags > 20
  user-added boundaries in a scrollable (wasted compositing layers).

### v11 Audit Part 2 — Accuracy & Enrichment (v11.7–v11.12)

- **v11.7 `FadeTransition` at opacity 0.0**: `OpacityDetector` catches it
  with dedup vs `AnimatedOpacity`'s internal `FadeTransition`.
- **v11.8 `ColorFiltered` GPU detection** in `GpuPressureDetector` +
  `RepaintBoundaryDetector` with deep subtrees. Widget-level check (private
  `_ColorFilterRenderObject` not `is`-accessible).
- **v11.9 Small image suppression**: `ImageMemoryDetector` skips ≤ 50×50
  logical (cacheWidth/Height savings negligible).
- **v11.10 `TweenAnimationBuilder` child**: `AnimatedBuilderDetector` catches
  it without `child`; skips `isFrameworkOwned` check (always user-placed).
- **v11.11 Runtime font loading**: `FontLoadingDetector` uses
  `fontFamilyFallback` heuristic for google_fonts etc.; new
  `runtime_font_loading` stableId, escalates at ≥ 3 families.
- **v11.12 `BackdropFilter` sigma severity**: `GpuPressureDetector` extracts
  blur sigma. σ ≤ 2.0 suppressed; σ > 10.0 critical. Detail shows `σ=X.X`.

### v10 Accuracy

- **v10.1 ListView/GridView `SliverChildListDelegate`**: new stableIds
  `non_lazy_listview` / `non_lazy_gridview` + causal rules.
- **v10.2 `NeverScrollableScrollPhysics`** suppression in `NestedScrollDetector`.
- **v10.3 `DecorationImage`**: `ImageMemoryDetector` now catches images in
  `BoxDecoration` via `DecoratedBox`.
- **v10.4 `GpuPressureDetector` is-checks**: `runtimeType.toString()` +
  `contains()` → `is` for `RenderOpacity`, `RenderClipPath`,
  `RenderBackdropFilter`, `RenderShaderMask`. Eliminates allocations AND
  fixes false positive on `RenderAnimatedOpacity` (extends `RenderProxyBox`,
  not `RenderOpacity`).
- **v10.5 `LayoutBottleneckDetector` widget-level checks**: render-object
  toString → `is IntrinsicHeight`/`IntrinsicWidth`. 2 toString allocs/element
  eliminated (`checkElement` + `afterElement`).

### v10 Enrichment

- **v10.6 KeepAlive + MemoryPressure**: `EscalateKeepAliveMemoryRule`
  upgrades `excessive_keep_alive:*` possible → likely when
  `heap_growing`/`heap_near_capacity` co-occurs. New causal rules.
- **v10.7 NestedScroll + LayoutBottleneck** causal rules connecting
  `nested_scroll[_same_axis]` to `layout_bottleneck`, `rebuild_activity`.
- **v10.8 HTTP error spike**: `NetworkMonitorDetector` flags ≥ 3 failures
  (status ≥ 400 or transport failure) in 5s. New `http_error_spike`,
  `FixHintBuilder.httpErrorSpike()`, encyclopedia entry, causal rule to
  `request_frequency`.
- **v10.9 Rebuild + RepaintBoundary enrichment**:
  `EnrichRebuildRepaintBoundaryRule` annotates `rebuild_activity`/
  `rebuild_debug_*` when `missing_repaint_boundary` co-occurs
  (informational, no confidence change).

### v10 Performance

- **v10.10 `CustomPainterDetector`**: `runtimeType.toString()` →
  `'CustomPaint'` literal in highlight creation.
- **v10.11 `RepaintDetector` map**: `_hotCounts.clear()` vs `= {}` — reuses
  backing store.
- **v10.12 `NestedScrollDetector` stack**: `_scrollAxisStack.clear()` +
  `.add(null)` vs list re-creation.

## 0.10.1

Rebrand: `widget_watchdog` → `sleuth`. All classes, imports, docs, and tests updated.

## 0.10.0

v9 roadmap complete (v9.1–v9.17): Issue Encyclopedia, contextual AI Chat, and performance/correctness hardening across detectors and overlay.

### Performance

- **v9.9 — `runtimeType.toString()` elimination**: 3 of 7 call sites in scan-root resolution switched to `is` type checks (`_findVisiblePageContext`, `_findActiveRouteScanRoot`, `_containsNestedNavigator`). 4 remain on private framework types (`_OverlayEntryWidget`, `_ModalScope`, `_ModalScopeStatus`).
- **v9.10 — FrameStatsBuffer hot-path**: cached `frames` getter (no per-call `Queue.toList()`), single-pass jank counting, listener-gated `FrameStatsBuffer.from()` copy, lazy dirty-flag `fpsPercentiles()` cache.
- **v9.11 — Inner subtree walk elimination**: AnimatedBuilderDetector, GpuPressureDetector, GlobalKeyDetector, KeepAliveDetector converted from inner recursion to `afterElement` stack accumulation. Restores O(N) for all 16 tree-scanning detectors; GpuPressureDetector now reports accurate descendant counts (was capped at 20).
- **v9.12 — Single-loop `_aggregateIssues()`**: replaces `.map().toList()` + `.where().toList()` chain with one for-loop; eliminates 2 intermediate list allocations per call (7 callers).
- **v9.13 — FIFO eviction O(N) → O(1)**: `NetworkMonitorDetector._records` and `MemoryPressureDetector._heapSamples` switched `List` → `Queue` (`removeAt(0)` → `removeFirst()`). Capacities: 200 records, 60 heap samples.
- **v9.14 — Highlight overlay self-overhead**: `saveLayer` + `BlendMode.clear` dim replaced with `Path.combine(PathOperation.difference)` (no offscreen GPU buffer per frame). Generation-counter `shouldRepaint` via record-typed `highlightsNotifier`. Selected highlight rebinds to fresh rect after scroll/rescan.

### Fixed

- **v9.1 — Opacity value semantics**: `GpuPressureDetector` and `RepaintBoundaryDetector` skip `Opacity` at 1.0 (passthrough) and 0.0 (short-circuit); these don't trigger `saveLayer`. `OpacityDetector` was already correct.
- **v9.4 — Layout bottleneck overclaim**: `LayoutBottleneckDetector` distinguishes nested intrinsics (critical — exponential) vs non-nested (warning — O(N²)). Tracks nesting depth via `afterElement` with abort-safe `prepareScan` reset.
- **v9.6 — Per-scrollable accumulation**: `GlobalKeyDetector` and `KeepAliveDetector` count per-scrollable, not globally. Each emits its own issue with indexed stableIds (`excessive_global_keys:0`, `excessive_keep_alive:0`). Suppression should switch to prefix match for the old unindexed IDs.
- **v9.8 — Timeline parser event name validation**: silent data loss fix — `LAYOUT (root)` / `PAINT (root)` (Flutter 3.13+) were dropped because `.contains()` required exact match (`'layout (root)'` vs set entry `'layout'`). Root PipelineOwner events carry the primary pipeline's durations, so `flushLayoutDurations`/`flushPaintDurations` were missing their most important entries. Also removed 6 phantom entries (`buildscope`, `build_scope`, `flushlayout`/`flush_layout`, `flushpaint`/`flush_paint`) verified absent in Flutter source back to v2.x.
- **v9.15 — Silent exception swallowing**: all 8 `catch (_) {}` blocks now log via `debugPrint` inside `assert(() {}())` (zero profile/release overhead). Files: `sleuth_controller.dart` (2), `base_detector.dart`, `custom_painter_detector.dart`, `debug_instrumentation_coordinator.dart` (2), `widget_location.dart`, `source_location_cache.dart`.
- **v9.16 — Mounted check for ModalRoute.of**: `_currentRouteName()` guards `ModalRoute.of(_lastScanContext)` with a mounted check. The retained context can detach between scans and async callbacks (VM timeline, heap, scroll idle).
- **v9.17 — Source location cache docstring**: no code change — git history confirmed the docstring has always correctly described first-N bounded behavior.

### Added

- **Issue Encyclopedia**: educational "Learn more" deep-dive for every detector type, searchable, reachable from IssueCard.
- **Contextual AI Chat** (`AiChatPage`): per-issue streaming chat with starter questions, thinking indicator, expandable issue context card. Adapter-based backend.
- **Actionable fix hints** (`FixHintBuilder`): code snippets and debugging commands for every detector.

### Changed

- **UI**: shimmer "Ask AI" link in IssueCard (animated purple-blue-pink `ShaderMask`, isolated via `RepaintBoundary` + `AnimatedBuilder` static-child pattern); responsive action links (side-by-side when wide, stacked <240px via `LayoutBuilder`); MediaQuery granular accessors (`sizeOf`/`paddingOf`/`viewInsetsOf`) across `AiChatPage`/`FloatingIssuesCard`/`IssueEncyclopediaPage`; AI chat header respects `MediaQuery.paddingOf(context).top`; expandable real `IssueCard` in AI chat (capped 40% screen height).
- `SleuthThemeData`: added `aiShimmerStart`/`aiShimmerMid`/`aiShimmerEnd` tokens.
- 1,490 tests (up from 1,343), 0 analysis issues.

## 0.9.1

v8 roadmap complete (v8.1–v8.5).

### Fixed

- **v8.1 — SetState subtree counting O(N²) → O(N)**: `SetStateScopeDetector` replaced recursive `_computeSubtreeSize` with stack-based post-order accumulation in `afterElement`. Abort-safety via `notifyWalkCompleted` gate — evidence and child snapshots commit only on success. Transactional `_pendingEvidence` staging prevents partial data from aborted scans.
- **v8.2 — Scaffold scan-root fallback**: `_findVisiblePageContext` three-tier resolution — (1) Material `Scaffold` / `CupertinoPageScaffold`, (2) scaffold-free Navigator path (walks overlay for topmost route-owned onstage entry via `_ModalScope`, identity-hash route-stability gate, TickerMode onstage filter), (3) static app fallback (`NotificationListener`). `ShallowRebuildRiskDetector` + `SetStateScopeDetector` exempted from scaffold-free walk (depth/ratio semantics break). Nested-Navigator guard prevents cross-tab false positives. `refreshHighlights()` uses `_lastScanContext` to avoid route-stability side effects. Previously Cupertino and scaffold-free apps got zero structural detection.
- **v8.3 — HTTP monitor openUrl leak**: `_MonitoringHttpClient.openUrl()` wraps `_inner.openUrl()` in try/catch. On transport failure (DNS/TLS/connection-refused), emits `RequestRecord(statusCode: -1)`, calls `onRequestEnded`, rethrows. Callback isolation — `onRequestEnded` and `onRecord` run in separate try/catches so a throwing callback can't suppress the other or mask the transport exception. Same isolation on `_MonitoringRequest.close()` and `_MonitoringResponse._emitRecord()`. Survived 4 Codex adversarial reviews.
- **v8.4 — Platform channel false positives**: `TimelineParser` classifier replaced `cat.contains('embedder')` fallback with prefix match for real `debugProfilePlatformChannels` events (`Platform Channel send [channel]#[method]`). The embedder fallback incorrectly captured vsync/compositor/input events. Legacy exact names (`platformchannel`, `methodchannel`) preserved as defensive fallback.

### Changed

- **v8.5 — SetState detector wording accuracy**: user detail no longer claims `setState() was detected` (the evidence — child-identity churn — proves rebuild, not the trigger). Now says "Rebuild activity was detected"; fix hints generalized from "Move setState() calls" to "Scope rebuild triggers". Internal `hasEvidence` → `hasRebuildEvidence`. Docstring describes two-tier confidence.

### Added

- 1,343 tests (up from 1,313), 0 analysis issues.

## 0.9.0

### Changed

- **v7.9 — Unified structural tree walk**: all 16 tree-scanning detectors run in a single `O(N)` pass (was 16 separate walks). Four new `BaseDetector` lifecycle methods (`prepareScan`, `checkElement`, `afterElement`, `finalizeScan`) replace per-detector `scanTree` for built-ins. Custom detectors keep `scanTree` via legacy path. Zero test changes — base-class `scanTree` wrapper calls the 4 methods.

## 0.8.2

### Improved

- **v7.7 — Ring buffer for frame history**: `FrameStatsBuffer` replaced `List<FrameStats>` with fixed-capacity ring buffer. O(1) insert, bounded memory, no GC pressure during long sessions.
- **v7.8 — Correlator sort cache**: `FrameEventCorrelator` caches sorted event lists across rounds; ~40% correlator CPU reduction under sustained load.
- **v7.10 — VM reconnect polling fix**: `_pollTimeline()` error handler cancels the poll timer *before* invoking callbacks, preventing a 500ms error loop if `onConnectionChanged` throws. Timer cancel idempotent vs `reconnect()` cleanup.

## 0.8.1

### Improved

- **v7.1 — HeavyCompute two-tier severity**: 100–500ms → `medium`, >500ms → `high` (was all `high`).
- **v7.2 — NetworkMonitor threshold fix**: frequency comparison `>` → `>=` to match documented behavior; 30 requests in 5s now fires at the configured limit.
- **v7.3 — Threshold tuning pass**: 6 detector thresholds adjusted from real-app profiling data; fewer false positives, same sensitivity for genuine issues.
- **v7.4 — Correlator coverage expansion**: `FrameEventCorrelator` matches 3 additional timeline categories previously ignored; better phase attribution.
- **v7.5 — Rebuild VM fallback**: `RebuildDetector` falls back to structural density analysis when VM build counts are unavailable (was reporting nothing).
- **v7.6 — MemoryPressure warmup guard**: heap-growth detection ignores first 10s after connection to avoid startup-allocation false positives.

## 0.8.0

v6 roadmap complete (22 milestones).

### Improved

- **v6.1 — Controller async safety**: VM calls wrapped with 10s timeouts and disposed-state guards. `dispose()` cancels in-flight futures and timeline subscriptions. Prevents `setState after dispose` and hangs on lost VM connections.
- **v6.2 — AnimatedOpacity detection**: `OpacityDetector` now detects `AnimatedOpacity` at opacity 0 (in addition to static `Opacity`).
- **v6.3 — ShaderMask render detection**: `GpuPressureDetector` includes `RenderShaderMask` in the expensive render-tree check.
- **v6.4 — Nested scroll highlights**: `NestedScrollDetector` provides widget highlight overlays for inner and outer scroll regions.
- **v6.5/v6.6/v6.7/v6.8/v6.9 — UI polish**: 44px min tap target on header icons; `onPanUpdate` clamps card inside screen bounds every frame; floating card repositions when soft keyboard opens; `ValueListenableBuilder` listeners deduplicated; long text protected with `maxLines` + `TextOverflow.ellipsis`.
- **v6.12 — GuidePage back navigation**: hardware/system back returns from GuidePage to the floating card.
- **v6.13 — Model equality**: `PerformanceIssue` implements `==` / `hashCode` on `stableId` for correct Set/Map/dedup.
- **v6.14 — Enrichment error logging**: enrichment-chain failures log structured messages via `debugPrint` (no more silent swallowing).
- **v6.15 — Suppression precompilation**: suppression patterns compiled to `RegExp` once at config time (was per-issue per-scan).
- **v6.19 — ListView threshold tuning**: non-lazy `ListView` child-count threshold adjusted for accuracy.
- **v6.20 — TriggerButton adaptive position**: initial button position adapts to screen size (visible on all device sizes).
- **v6.21 — Spacing theme tokens**: 6 tokens (`spacingXxs`–`spacingXl`) on `SleuthThemeData`; ~67 hardcoded spacing values replaced across 4 UI files; consumers can customize overlay density via theme.
- **v6.22 — Benchmark robustness**: timing budgets use `budgetMultiplier` reading `CI` env var (no more flaky loaded-runner tests).

### Changed

- **v6.10 / v6.11 — Refactors**: `FloatingIssuesCard` and `IssueCard` build methods extracted into focused builders. Zero behavior change.
- **v6.16 — Platform declarations**: `pubspec.yaml` declares `android` + `ios` explicitly for pub.dev scoring.

### Added

- **v6.17 — Controller lifecycle tests**: 20+ tests for dispose guards, timeouts, error resilience.
- **v6.18 — UI widget tests**: widget tests for `FloatingIssuesCard`, `IssueCard`, `TriggerButton`, `GuidePage`.
- 1,294 tests, 0 analysis issues.

## 0.7.0

v4 + v5 roadmap complete.

### Added

- **v4.1 — Issue suppression**: `SleuthConfig.suppressedIssues` filters by `stableId` pattern (exact or trailing `*` wildcard), applied post-correlate / pre-rank. `suppressedCountNotifier` + `SessionSnapshot.suppressedCount`.
- **v4.2 — Custom detector plugin API**: `SleuthConfig.customDetectors: List<BaseDetector>`. Integrates into all 7 controller lifecycle points (init, debug snapshot, structural scans, highlights, timeline data, aggregation, dispose). Always enabled regardless of `enabledDetectors`. Barrel exports `BaseDetector`, `ParsedTimelineData`, `DebugSnapshot`.
- **v5.1 — Overlay theming**: `SleuthThemeData` with 60 color tokens extracted from 6 UI files. `SleuthThemeData.light()`, auto-brightness via `MediaQuery.platformBrightness`, `copyWith()`, `SleuthTheme` InheritedWidget with dark fallback.
- **v5.2 — Export enrichment**: `SessionSnapshot` schema v2 — `PhaseEvent` toJson/fromJson + rolling buffer, `GcEventSummary` + `PlatformChannelSummary` serializable wrappers, `FpsPercentiles` (p50/p95/p99), `rankingScore`/`rankingBreakdown` on `PerformanceIssue`, `recentFrames` (last 60), `schemaVersion`. All new fields nullable.
- **v5.3 — Causal issue graph**: 23 cause-effect rules build a directed graph; issues annotated with `rootCauseId`/`downstreamIds`. Confidence suppression hides `possible` downstream when root is `confirmed`/`likely`. UI: `FloatingIssuesCard` filters downstream; `IssueCard` shows `↳ N` badge + "Related effects" section. New theme token `effectsBadge`.
- **v5.4 — Configurable detector thresholds**: `DetectorThresholds` nested config on `SleuthConfig`, 10 tunable parameters. Defaults match pre-change hardcoded values; secondary severity thresholds scale as `* 2`. Barrel exports `DetectorThresholds`.
- **v5.6 — Network-to-frame correlation**: `NetworkMonitorDetector` adds `startRequest()`/`endRequest()`. `FrameVerdict` gains `pendingRequestCount` + `slowestPendingMs`. `SleuthHttpOverrides` gains `onRequestStarted`/`onRequestEnded`. All 3 verdict paths enriched; 2 new causal rules. Zero overhead when network monitoring disabled.
- **v5.8 — RepaintBoundary coverage detector** (22nd detector, `DetectorType.repaintBoundary`, structural): walks for 5 expensive GPU widget types (`Opacity`, `ClipPath`, `BackdropFilter`, `ShaderMask`, `CustomPaint`), checks for `RenderRepaintBoundary` within 3 ancestor levels. Three-tier confidence: `possible` → `likely` (>10/sec) → `confirmed` (>30/sec). 3 new causal rules.

### Changed

- **v4.4 — `FloatingIssuesCard` sub-widgets extracted**: `_StatusRow`, `_CardFooter`, `_WarningBanners`. State class 659 → 433 lines, zero behavior change.
- **v4.5 — Example app modularized**: 18 demo screens extracted from `example/lib/main.dart` (1,807 → 239 lines) into `example/lib/demos/`.
- **v5.5 — Detector registry**: 21 individual detector fields on `SleuthController` → unified `List<BaseDetector>` registry. 7 dispatch methods use lifecycle-filtered loops. Adding a detector = 1 new file + 1 enum + 1 registry line. ~-90 net lines in controller.

## 0.6.1

### Fixed

- **FPS counter precision**: `averageFps` uses microsecond-precision arithmetic (was ms); eliminates ~8% truncation inflation (6.5ms truncated to 6ms gave 167 FPS instead of 154).
- **FPS counter startup**: `_frameTiming.start()` moved before `await client.connect()` so counter captures frames during slow VM connection (1.5–10.5s) instead of showing 0.
- **FPS display capped at target**: UI clamps displayed FPS at `fpsTarget` (default 60); idle profile-mode screens show 60 instead of 120+.
- **`fpsColor` target-aware**: thresholds relative to `fpsTarget` (green ≥ 83%, amber ≥ 50%); was hardcoded 50/30 FPS.
- **`exportSnapshot` reads live buffer**: uses `_frameTiming.frameBuffer` directly when initialized.

### Added

- `TriggerButton.fpsTarget` wired from `SleuthConfig.fpsTarget`; 9 FPS throughput tests in `frame_stats_buffer_fps_test.dart`; FPS Stress Test demo screen.

## 0.6.0

### Changed

- **Replaced `DashboardSheet` with `FloatingIssuesCard`**: bottom sheet (1,241 lines) → draggable floating card (~830 lines). Removed `FrameChart`, tabs, filter chips. FPS shown on `TriggerButton`.
- **Guide redesigned**: full-screen `GuidePage` with staggered entrance animations + 4 expandable sections (Quick Start, Understanding the Card, Color Legend, Tips & Tricks).
- **Resizable card**: width/height via corner grip handle; double-tap header to maximize/restore.

### Added

- `FloatingIssuesCard`, `_CornerGripPainter` (6-dot grip inside corner radius), `GuidePage` with fade+slide animations, 9 card-resize tests.

### Removed

- `DashboardSheet`, `FrameChart`, `TabBarView` with keep-alive, filter chips, chart `AnimationController`.

## 0.5.0

### Added

- **v3.2 — Context-aware fix hints**: centralized `FixHintBuilder` with 28 static methods (one per issue type). Widget-specific, location-aware hints (reference detected widget name, ancestor chain, interaction context). `FixEffort` enum (`quick`/`medium`/`involved`); `fixEffort` nullable on `PerformanceIssue` for backward compat. UI effort badge reads from model field with keyword fallback for legacy JSON.
- **v3.3 — Issue-to-verdict linking**: amber "Jank detected" banner on Live tab when a verdict has related issues; `JANK` badge on issue cards correlated with current jank verdict; tap banner to flash correlated cards in Issues tab.
- **v3.8 — Overlay UX improvements**: widget name before ancestor chain in expanded cards; "Widget not currently visible" feedback for missing highlight targets; interaction-context filter chips on Issues tab (All/Idle/Scrolling); "About this detection" collapsible (source, confidence, verification); effort indicators (QUICK/MEDIUM/INVOLVED) on fix hint boxes; color legend in Guide tab.

### Changed

- All 21 detectors use `FixHintBuilder` instead of hardcoded strings (detector logic unchanged).
- `PerformanceIssue.fixEffort` nullable, backward compatible.
- Barrel exports `FixHintBuilder`.

## 0.4.0

### Improved

- **v3.1.1 — AnimatedBuilder threshold**: subtree size 5 → 20 (fewer false positives on normal animations). Confidence `possible` by default, `likely` only when `DebugSnapshot` confirms rebuild rate > 30/sec.
- **v3.1.2 — CustomPainter secondary heuristic**: `frequent_repaint_painter` — when no always-true painters exist but `CustomPaint` paint rate > 30/sec, warn to review `shouldRepaint`.
- **v3.1.3 — MemoryPressure warmup exclusion**: heap-trend alerts suppressed first 5s after initial sample (prevents startup-allocation false positives). GC pressure and capacity alerts unaffected. Configurable via `SleuthConfig.memoryWarmupDurationMs`.
- **v3.1.4 — NestedScroll cross-axis suppression**: horizontal ListView inside vertical ScrollView (and other cross-axis combos) no longer fires. Only same-axis nesting is flagged.
- **v3.1.5 — Opacity near-zero detection**: threshold widened from `== 0.0` to `< 0.01`. Detail text includes actual opacity value.
- **v3.1.6 — GpuPressure structural-issue preservation**: on VM disconnect, structural issues (expensive render nodes) preserved at `possible` confidence (was cleared entirely). Only VM-backed raster dominance issue removed.
- **v3.1.7 — PlatformChannel duration tracking**: fires when either frequency exceeds threshold OR cumulative duration > 8ms (`SleuthConfig.platformChannelDurationThresholdMs`). Detail includes top method names.
- **v3.9 — FrameEventCorrelator binary search**: O(E×F) linear → O(E log F) binary using pre-sorted frame lists. Behaviorally identical.

### Added

- `SleuthConfig.memoryWarmupDurationMs` (default 5000ms).
- `SleuthConfig.platformChannelDurationThresholdMs` (default 8ms).

## 0.3.0

### Added

- **v2.2 — Heap trend monitoring**: `MemoryPressureDetector` polls `getMemoryUsage()` alongside VM timeline; tracks 60-sample (30s) rolling window with linear regression. New issues: *Heap Growing* (slope > 500 KB/sec for ≥10s, warning/likely), *Heap Near Capacity* (heap usage > 80% capacity, critical/confirmed). `HeapSample` exported.
- **v2.3 — Jank CPU attribution**: on jank + VM connected, `getCpuSamples()` queried for the frame window. `CpuSampleAggregator` ranks by exclusive ticks, surfaces top 5 in `FrameVerdict.topFunctions`. Two-phase emission: verdict fires immediately, then updates with CPU attribution when samples arrive (or 500ms timeout). `CpuAttribution` exported; dashboard shows "Top: ClassName.method (N%)" on jank.
- **v2.4 — Source file:line in ancestor chains**: `buildAncestorChain()` appends `(lib/path/file.dart:line)` to leaf when `--track-widget-creation` is active (debug default). Uses `InspectorSerializationDelegate`. Cached per widget runtime type (bounded 200 entries). Zero profile-mode overhead. `SourceLocationCache.abbreviatePath()` for `lib/`-relative display.

### Changed

- `MemoryPressureDetector`: `processHeapSample()` replaces `updateHeapStats()`. Rolling-window regression replaces percentage-based growth detection.
- `FrameVerdict` gains `topFunctions: List<CpuAttribution>?` + `withTopFunctions()` copy method.
- `exportSnapshot()` includes `heapSamples` array + CPU attribution when available.
- Barrel exports `CpuAttribution`, `HeapSample`, updated `FrameVerdict`.
- Ancestor-chain framework filter: 17 additional framework widgets excluded (transitions, builders, pointer/render infra).
- IssueCard no longer shows redundant "Widget:" line when detail text already contains ancestor chain.
- README "What DevTools Still Does Better" narrowed to 2 (heap snapshots, full flame chart) — network / memory trends / CPU profiling / widget-exact attribution no longer DevTools-only.

## 0.2.0

### Breaking Changes

- `DetectorType.memoryLeak` → `DetectorType.memoryPressure` (update `enabledDetectors`).
- `DetectorType.mediaQueryRebuild` → `DetectorType.shallowRebuildRisk` (update `enabledDetectors`).
- `DetectorLifecycle.runtime` added — exhaustive switches need a new case.

### Added

- **Per-frame event correlation**: VM timeline events matched to frames by monotonic timestamp overlap (replaces batch attribution).
- **Three-tier verdict degradation**: Correlated > Full > Basic, falls back automatically based on VM connectivity and correlation quality.
- **FrameTiming upgrades**: `totalSpan` (vsyncStart→rasterFinish) as primary jank indicator; pipeline stall detection; scheduler delay detection; build-to-raster gap measurement.
- **Debug attribution hooks** (`enableDebugCallbacks`): opt-in per-widget rebuild/repaint via `debugOnRebuildDirtyWidget` + `debugOnProfilePaint`. Default false to avoid DevTools conflict.
- **Heavy debug instrumentation** (`enableDeepDebugInstrumentation`): per-widget timeline events via 6 Flutter debug globals with save/restore lifecycle. UI shows purple warning banner when active.
- **Two-tier config model**: simple top-level switches + expert `advanced` block (`DebugInstrumentationConfig`).
- **Issue ranking**: weighted composite score (severity + frame impact + confidence + recurrence) drives dashboard order.
- **Route tagging**: automatic `routeName` stamping via `ModalRoute.of()`; shown in expanded cards.
- **Interaction context**: `idle`/`scrolling`/`navigating` stamped on issues ("During: scrolling").
- **Rolling jank capture buffer**: worst-N frame retention (default 50, `captureBufferCapacity`). Evicts mildest frames when full.
- **JSON session export**: `Sleuth.exportSnapshot()` + `exportSnapshotJson()`. Dashboard export button copies to clipboard.
- **Source-location enrichment**: ancestor chain attribution on structural + debug-backed issues ("Widget: Outer > Middle > Inner").
- **Timeline enrichment**: dirty widget names/counts extracted from enriched VM timeline args (build scope, layout, paint phases).
- **Rebuild/repaint widget highlights**: visual overlay rects correlated from `DebugSnapshot` + enriched VM names.
- `stableId` on `PerformanceIssue` (UI state persistence across scans); `ancestorChain` for source-location guidance.
- `ObservationSource` enum (VM timeline / debug callback / structural / combined); UI shows left-border accent (green/purple/gray).
- Confidence badges: Confirmed / Likely / Possible with color-coded chips.
- **20th detector**: Repaint detector (hybrid: VM + debug callback).
- **Self-overhead benchmark suite** (29 tests): per-detector scan overhead, full-scan scaling, timeline processing, buffer bounds, issue/highlight count limits.
- **Validation matrix** (`doc/validation_matrix.md`): per-platform release-readiness grid, degradation verification, detector coverage checklist.
- **Degradation contract integration tests** (9): VM disconnect/reconnect, verdict path switching, detector group isolation.
- **5 new example demos**: Opacity Zero, AnimatedBuilder No Child, Shallow Rebuild Risk, Font Loading Stress, Repaint Stress.

### Changed

- `MemoryLeakDetector` → `MemoryPressureDetector` (honest framing — monitors GC frequency + heap growth, not individual object leaks).
- `MediaQueryRebuildDetector` → `ShallowRebuildRiskDetector` (finds shallow StatefulWidgets during high build activity; does not observe actual `MediaQuery.of()` usage).
- `RebuildDetector` labels widget names as screen context, not proven attribution. Title → "High Rebuild Activity".
- `GpuPressureDetector` confidence corrected (was reversed): `confirmed` for observed raster dominance, `likely` when expensive render nodes also found.
- `OpacityDetector`: no longer claims GPU waste for `Opacity(0.0)` — repurposed as correctness hint (widget still participates in hit testing, layout, semantics). Confidence → `possible`, category → `layout`.
- Removed dead `analyzeBasicMode()` from `RenderPipelineAnalyzer`.
- `fpsTarget` now drives jank thresholds (was hardcoded 16/33ms regardless of target).
- `IssueConfidence` doc comments describe evidence tiers accurately.

### Fixed

- Erroneous `* 1024 * 1024` on `pictureCacheBytes` in `FrameTimingDetector` — `FrameTiming.pictureCacheBytes` already returns bytes.
- Chart budget line + color thresholds use per-frame `frameBudgetMs` (was hardcoded 16/33ms) — correctly supports 120fps mode.

## 0.1.0

- Initial release.
- 19 performance detectors (VM-only, hybrid, structural).
- Dual-mode analysis (Full VM Timeline + Basic SchedulerBinding).
- In-app overlay with live FPS chart, issue dashboard, guide.
- Debug-mode warning banner.
- Configurable thresholds and detector selection.
- Zero release overhead (`kReleaseMode` guard).
