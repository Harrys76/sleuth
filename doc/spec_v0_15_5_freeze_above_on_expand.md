# Freeze-Above-on-Expand for Issue List (v0.15.5)

## Scope

**Goal:** When any card is expanded, freeze the order of the issues at and above
the deepest expanded index so nothing the user is reading shifts under their
eyes. Only the flow below that boundary keeps reordering per the ranker. Collapse
releases the freeze. Multi-expand uses a MAX rule: `freezeEnd = max(expandedIndices.values)`.

**Non-goals:**
- No animation of reorders (deferred; may return behind a config flag in v0.15.6+).
- No toast for critical arrivals — new criticals arriving while a card is
  expanded are re-ordered beneath the frozen zone. This is the accepted
  tradeoff the user asked for: if you are reading, nothing above you moves.
- No changes to the ranker, severity escalation, or downstream nesting logic.
- No change to `_IssueCardState._toggle()` semantics — each card continues to
  own its own expand state.
- No explicit "pin/unpin while expanded" affordance. Collapse IS release.
- Pin icon stays as a state hint, moved from position 4 (between confidence
  badge and JANK chip) to the last chip slot (after the `↳N` downstream badge,
  before the Checkbox) so it reads as a "this row is held" marker rather than
  competing with severity/confidence chrome.

**Target version:** 0.15.5 (patch — UX fix only; no public API change).

**Supersedes:** shipped-but-uncommitted "single-card pin-on-expand"
(`doc/spec_v0_15_5_pin_on_expand.md`, now deleted). Pin-on-expand held one
card at its index but let everything else flow freely, including above the
expanded card — so criticals could still appear and re-rank ABOVE whatever
the user was reading. User rejected the UX with: "reordering issue
incoming / exist will be happen below index issue that im expanded."

## Dependency Diagram

```
SleuthController.issuesNotifier  ──►  ValueListenableBuilder
                                           │
                                           ▼
                              computeVisibleIssues(issues)          ◄── unchanged from pin-on-expand
                                           │
                                           ▼
                       applyFreezeZone(                              ◄── new
                         visibleIssues,
                         orderSnapshot,              ◄── List<PerformanceIssue>? (captured on 0→1 expand)
                         expandedIndices,            ◄── Map<String,int>
                       )
                                           │
                                           ▼
                    ┌──────────────────────┼─────────────────────────┐
                    ▼                      ▼                         ▼
          _IssuesSummaryBar        ListView.builder           downstream lookup
          (uses visibleIssues —    (uses orderedIssues —      (uses raw issues —
           pre-freeze, order-       post-freeze + keyed        unchanged)
           invariant)               findChildIndexCallback)
                                           │
                                           ▼
                                      IssueCard
                                  (pin icon if _expanded)
                                           │
                                           ▼
                                 onExpandedChanged(expanded)
                                           │
                                           ▼
                          Map<String, int> _expandedIndices
                          List<PerformanceIssue>? _orderSnapshot
                          - Set together on 0→1 (capture snapshot,
                            write first entry)
                          - Cleared together on 1→0 (release snapshot,
                            drop last entry)
                          - Evicted by _pruneStaleState against
                            computeVisibleIssues (both fields together)
                          - Cleared in dispose and on controller swap
                            (didUpdateWidget)
                          - Class invariant asserted inside
                            applyFreezeZone:
                              (orderSnapshot == null) ==
                                  expandedIndices.isEmpty
```

## Class Invariant

`_orderSnapshot` and `_expandedIndices` are **coupled state**. At all times:

```
(_orderSnapshot == null) == _expandedIndices.isEmpty
```

Enforced by an `assert` at the entry of `applyFreezeZone`. Every site that
mutates one of them must mutate the other in the same `setState` to preserve
the invariant across frames.

Mutation sites that uphold this:

1. **`onExpandedChanged(true)`** — on 0→1 transition: capture snapshot
   *before* writing the first entry. On 1→N (N>1): no snapshot change.
2. **`onExpandedChanged(false)`** — on 1→0 transition: drop last entry, then
   null the snapshot. On N→N−1 (N>1): no snapshot change.
3. **`_pruneStaleState`** — if pruning empties `_expandedIndices`, null the
   snapshot in the same `setState`.
4. **`didUpdateWidget` controller swap** — clear both.
5. **`dispose`** — clear both.

## Implementation Steps

### Step 1 — State model rename + snapshot field

In `_FloatingIssuesCardState`:

```dart
/// Maps `issueKey → index-at-expand-time`. Snapshot-relative: each value is
/// the issue's position in `_orderSnapshot` at the moment the user expanded
/// it, not whatever the ranker says today.
final Map<String, int> _expandedIndices = <String, int>{};

/// The visible-issues list captured the first time the user expanded any
/// card. Positions 0..max(_expandedIndices.values) are drawn from this
/// snapshot. Null when no card is expanded.
List<PerformanceIssue>? _orderSnapshot;
```

Removed: `_pinnedIndices` (replaced by `_expandedIndices`).

### Step 2 — Snapshot lifecycle

```dart
itemBuilder: (_, index) {
  final issue = orderedIssues[index];
  final issueKey = issue.stableId ?? issue.title;
  final capturedIndex = index;
  // C1: snapshot must match what the user saw, not the live notifier.
  // `capturedVisibleIssues` is the pre-freeze list the `itemBuilder` was
  // built from on this pump. If we looked up `issuesNotifier.value` at
  // callback time, a ranker tick between build and tap would poison the
  // snapshot with a list the user never saw.
  final capturedVisibleIssues = visibleIssues;
  return IssueCard(
    key: ValueKey(issueKey),
    initiallyExpanded: _expandedIndices.containsKey(issueKey),
    onExpandedChanged: (expanded) {
      setState(() {
        if (expanded) {
          if (_expandedIndices.isEmpty) {
            _orderSnapshot =
                List<PerformanceIssue>.of(capturedVisibleIssues);
          }
          _expandedIndices[issueKey] = capturedIndex;
        } else {
          _expandedIndices.remove(issueKey);
          if (_expandedIndices.isEmpty) {
            _orderSnapshot = null;
          }
        }
      });
    },
  );
},
```

### Step 3 — `applyFreezeZone` pure helper (`@visibleForTesting`)

```dart
@visibleForTesting
List<PerformanceIssue> applyFreezeZone({
  required List<PerformanceIssue> visibleIssues,
  required List<PerformanceIssue>? orderSnapshot,
  required Map<String, int> expandedIndices,
}) {
  // Class invariant — coupled state must be coupled at every render.
  assert(
    (orderSnapshot == null) == expandedIndices.isEmpty,
    'orderSnapshot/expandedIndices must be set together or cleared together',
  );
  if (expandedIndices.isEmpty || orderSnapshot == null) {
    return visibleIssues;
  }
  // MAX rule — multi-expand freezes down to the deepest expanded index.
  var freezeEnd = expandedIndices.values.first;
  for (final v in expandedIndices.values) {
    if (v > freezeEnd) freezeEnd = v;
  }
  final maxSnapshotIdx = orderSnapshot.length - 1;
  final maxVisibleIdx = visibleIssues.length - 1;
  if (freezeEnd > maxSnapshotIdx) freezeEnd = maxSnapshotIdx;
  if (freezeEnd > maxVisibleIdx) freezeEnd = maxVisibleIdx;
  if (freezeEnd < 0) return visibleIssues;

  final frozenKeys = <String>{
    for (var i = 0; i <= freezeEnd; i++)
      orderSnapshot[i].stableId ?? orderSnapshot[i].title,
  };
  final visibleById = <String, PerformanceIssue>{
    for (final i in visibleIssues) (i.stableId ?? i.title): i,
  };
  final frozen = <PerformanceIssue>[];
  for (var i = 0; i <= freezeEnd; i++) {
    final snap = orderSnapshot[i];
    final key = snap.stableId ?? snap.title;
    final live = visibleById[key];
    if (live != null) frozen.add(live);
  }
  final flow = <PerformanceIssue>[
    for (final i in visibleIssues)
      if (!frozenKeys.contains(i.stableId ?? i.title)) i,
  ];
  return <PerformanceIssue>[...frozen, ...flow];
}
```

Notes:
- **Frozen zone** uses snapshot order but **live instances** (so severity/confidence/ranker updates still render).
- **Vanished frozen entries** are silently dropped on the current render;
  `_pruneStaleState` evicts the expand entry on its next sweep.
- **Snapshot shorter** (downstream collapse shrank visible) and **visible
  shorter** (list churned below freeze) both clamp, no throw.

### Step 4 — `_pruneStaleState` dual clear

```dart
final visible = computeVisibleIssues(issues);
final visibleKeys = {for (final i in visible) i.stableId ?? i.title};

var changed = false;

final expandedBefore = _expandedIndices.length;
_expandedIndices.removeWhere((id, _) => !visibleKeys.contains(id));
if (_expandedIndices.length != expandedBefore) changed = true;

// Dual clear — preserves the class invariant when the last expanded card
// is absorbed under a newly-present root (or evicted for any other reason).
if (_expandedIndices.isEmpty && _orderSnapshot != null) {
  _orderSnapshot = null;
  changed = true;
}
```

Selection and chat surfaces still reach ALL issues (not just visible) and
stay on raw-key — same convention as before.

### Step 5 — Render path

```dart
final visibleIssues = computeVisibleIssues(issues);
final orderedIssues = applyFreezeZone(
  visibleIssues: visibleIssues,
  orderSnapshot: _orderSnapshot,
  expandedIndices: _expandedIndices,
);
// M5: summary bar uses visibleIssues (pre-freeze).
return Column(
  children: [
    _IssuesSummaryBar(issues: visibleIssues),
    Expanded(
      child: ListView.builder(
        itemCount: orderedIssues.length,
        findChildIndexCallback: (Key key) {
          if (key is! ValueKey<String>) return null;
          final target = key.value;
          for (var i = 0; i < orderedIssues.length; i++) {
            if ((orderedIssues[i].stableId ?? orderedIssues[i].title)
                == target) {
              return i;
            }
          }
          return null;
        },
        itemBuilder: /* see Step 2 */,
      ),
    ),
  ],
);
```

### Step 6 — Pin indicator repositioning

In `issue_card.dart`, the header `Row` chip order becomes:

```
title · confidence badge · JANK chip · ↳N downstream badge · [pin] · Checkbox
```

(Pin was previously at position 4 between confidence and JANK; now at the
last chip slot before the Checkbox.) Rationale: the pin is now a "held row"
state hint, not a severity-adjacent chrome. It reads more naturally at the
tail.

```dart
Semantics(
  label: _expanded ? 'Pinned while expanded' : '',
  excludeSemantics: !_expanded,
  child: _expanded
      ? Padding(
          padding: EdgeInsets.only(left: theme.spacingXs),
          child: Icon(
            Icons.push_pin,
            size: 14,
            color: theme.textSecondary.withValues(alpha: 0.55),
          ),
        )
      : const SizedBox.shrink(),
),
```

The unconditional Semantics wrap (M3 from the prior iteration) is preserved:
label empty and `excludeSemantics: true` when collapsed so the a11y node
identity stays stable across expand/collapse.

### Step 7 — Dispose + controller swap

```dart
@override
void dispose() {
  // ...
  _expandedIndices.clear();
  _orderSnapshot = null;
  super.dispose();
}

@override
void didUpdateWidget(covariant FloatingIssuesCard oldWidget) {
  super.didUpdateWidget(oldWidget);
  if (oldWidget.controller != widget.controller) {
    // ... listener swaps ...
    _expandedIndices.clear();
    _orderSnapshot = null;
    // other transient fields ...
  }
}
```

## Files Changed

| File | Change | Category |
|---|---|---|
| `lib/src/ui/floating_issues_card.dart` | `_expandedIndices`, `_orderSnapshot`, `applyFreezeZone`, snapshot lifecycle, dual-clear prune | must change |
| `lib/src/ui/issue_card.dart` | Pin icon moved to last chip slot | must change |
| `pubspec.yaml` | 0.15.4 → 0.15.5 | must change |
| `CHANGELOG.md` | v0.15.5 entry | must change |
| `CLAUDE.md` | Prepend v0.15.5 | must change |
| `test/ui/floating_issues_card_test.dart` | 9 `applyFreezeZone` tests + 5 widget smoke tests | must change |
| `test/ui/issue_card_test.dart` | Group rename (pin-on-expand → freeze-above-on-expand pin indicator) | must change |
| `lib/sleuth.dart` | **No change** — no public symbols added | — |
| `lib/src/ranking/issue_ranker.dart` | **No change** | — |
| `lib/src/controller/sleuth_controller.dart` | **No change** | — |

## Risk Summary

| # | Risk | S × L | Mitigation |
|---|---|---|---|
| R1 | Snapshot + map disagree after a mutation path | HIGH × LOW | Assert in `applyFreezeZone`, every mutation site updates both in one `setState` |
| R2 | Snapshot captures live notifier instead of what user saw | HIGH × LOW | `capturedVisibleIssues` closure-captured in itemBuilder (C1) |
| R3 | Frozen entry vanishes mid-frame (downstream absorb, detector evict) | MED × MED | Silent drop on current render, `_pruneStaleState` evicts on next sweep |
| R4 | Pin at last-chip position overflows at 300dp | LOW × MED | Existing F5 regression test asserts pin rect stays inside card bounds; pre-existing Checkbox-tail overflow is out of scope |
| R5 | Multi-expand MAX rule buries non-expanded cards between two expanded ones | LOW × MED | Accepted tradeoff; consistent with "nothing above moves while reading" contract |
| R6 | Controller swap leaves stale snapshot referencing old controller's issues | LOW × LOW | `didUpdateWidget` dual-clear |

## UI/UX Design Considerations

- **Freeze extent:** everything from index 0 through the deepest expanded
  card's captured index, inclusive. Cards between two expanded cards are
  also frozen.
- **Critical arrival while expanded:** new critical lands at its ranker
  position **within the flow section only** (below the frozen zone). It
  cannot appear above the frozen zone. This is the user's explicit
  request.
- **Scroll position:** unaffected; `ValueKey` + `findChildIndexCallback`
  preserve element identity across reorders.
- **Pin icon:** 14dp, 55% alpha, last chip slot. Non-interactive — pure
  state hint.
- **Dark mode:** `theme.textSecondary` already adapts.

## Open Questions

**OQ1 (deferred):** Pre-existing 300dp header overflow in the Checkbox tail
(~40dp). Not a v0.15.5 regression; tracked as follow-up. F5 regression test
drains the known exception and asserts only the pin-specific invariant
(pin stays inside card bounds).

## Test Specifications

**Pure algorithm (`applyFreezeZone`):** 9 tests — empty no-op, user's exact
symptom at index 2, multi-expand MAX, disappeared frozen entry, snapshot
shorter than captured index, visible shorter than snapshot, flow order
preservation, both invariant asserts.

**Widget smoke:** 5 tests — pin icon toggles with expand/collapse, summary
bar count invariant, dispose clears both fields, `didUpdateWidget`
controller swap clears both fields, collapse releases snapshot so
subsequent mutations render freely.

**Integration:** `issue_card_test.dart` existing 3 pin-indicator tests
preserved (group renamed).

## Verification

1. `fvm flutter analyze` — 0 issues.
2. `fvm flutter test test/ui/floating_issues_card_test.dart test/ui/issue_card_test.dart` — all tests pass.
3. `fvm flutter test` — full suite.
4. **`cd example && fvm flutter run --profile`** — real-device smoke:
   - Expand the card at index 2. Wait 30+ seconds past an
     `_applyDurationEscalation` cycle and a likely new-critical arrival.
   - Verify: index-0..2 zone is visually frozen. Any new critical appears
     at index 3+. No card above the expanded one moves.
   - Collapse. Verify: list resumes natural ranker order.
   - Expand cards at indices 1 AND 4. Verify freeze extends to index 4.
   - DevTools Performance capture: overlay rebuilds not in Sleuth's own
     rebuild stats panel (denylist still holds).

## Plan Review Pass

Phase 6 adversarial review executed on the DRAFT freeze-above-on-expand plan
before implementation. 16 findings addressed:

| # | Finding | Disposition |
|---|---|---|
| C1 | Snapshot captures live notifier instead of what user saw | **FIXED** — `capturedVisibleIssues` closure-captured in itemBuilder |
| C2 | Coupled-state invariant unstated | **FIXED** — class invariant documented + assert in `applyFreezeZone` |
| C3 | Controller swap leaves stale snapshot | **FIXED** — `didUpdateWidget` dual-clear |
| C4 | Phase 5 residue (pin-on-expand terminology) | **FIXED** — full rename + spec rewrite |
| FS1 | Frozen entry vanishes mid-render → index error | **FIXED** — silent drop + next-sweep eviction |
| FS2 | Snapshot length < captured index → range error | **FIXED** — clamp in `applyFreezeZone` |
| FS3 | Visible length < freezeEnd → range error | **FIXED** — clamp in `applyFreezeZone` |
| FS4 | Multi-expand with non-sequential indices | **FIXED** — MAX rule; frozen zone is `[0..max]` |
| H1 | Dispose only clears one field | **FIXED** — dispose dual-clear |
| H2 | `_pruneStaleState` only clears one field | **FIXED** — prune dual-clear |
| H3 | Pin icon position jumps across expand | **FIXED** — pin at last chip slot consistent; unconditional Semantics |
| O1 | MAX rule buries cards between two expanded | **ACCEPTED TRADEOFF** — documented |
| O2 | Animation deferred | **ACCEPTED** — may return behind config flag in v0.15.6+ |
| O3 | Critical cannot surface above frozen zone | **ACCEPTED TRADEOFF** — this is the user's explicit ask |
| OQ1 | 300dp Checkbox-tail overflow | **DEFERRED** — pre-existing, not a v0.15.5 regression |
| T1 | Snapshot-shorter and visible-shorter branches untested | **FIXED** — 2 dedicated clamp tests |

Only ONE additional invocation of `/adversarial-review` runs during
implementation — the post-implementation code review. Phase 6 already ran
during planning (this section is its record).

## Adversarial Review Scope (post-implementation)

Scope for the `/adversarial-review` run AFTER implementation:

- **In scope:**
  - `lib/src/ui/floating_issues_card.dart` — `applyFreezeZone`, snapshot
    lifecycle, dual-clear paths, `didUpdateWidget` controller swap.
  - `lib/src/ui/issue_card.dart` — pin icon at last chip slot, Semantics
    wrap.
  - `test/ui/floating_issues_card_test.dart` and
    `test/ui/issue_card_test.dart` — fixture audit, assertion coverage.
  - Transitively exercised: `computeVisibleIssues`,
    `findChildIndexCallback`, `_IssueCardState._toggle()`.
- **Out of scope:**
  - Ranker internals, detector outputs, VM pipeline, export/AI-chat.
  - `_selectedIssueId` / `_chatIssueStableId` raw-vs-visible convention —
    known parallel shape question, explicit follow-up.
- **Tactic emphasis:**
  - **Tactic 1 (assumption attack):** the class invariant must hold at
    every mutation point — any path that updates one field without the
    other is a bug. Enumerate and verify all 5 mutation sites.
  - **Tactic 2 (edge cases):** freezeEnd = 0, freezeEnd = length-1,
    multi-expand with non-sequential indices, concurrent prune mid-expand,
    controller swap mid-expand.
  - **Tactic 9 (fixture audit):** confirm tests exercise the real wiring
    (widget smoke) in addition to the pure `applyFreezeZone` helper, so
    a regression in the snapshot lifecycle can't masquerade as a passing
    unit test.
  - **Tactic 11 (symptom persistence):** primary symptom is "cards above
    shift while I read." Verify the fix addresses both (a) rank reorder
    mid-expand and (b) new critical arrival mid-expand. No other
    mechanism produces the same user-visible symptom.

## Remaining Notes

- **Follow-up milestone candidate:** same raw-vs-visible question for
  `_selectedIssueId`, `_chatIssueStableId`, `_chatHistories`. Deferred.
- **Animation layer (Layer 2):** if ever added, gate behind
  `SleuthConfig.animateOverlayReorders: bool` (default false). Extend
  `_frameworkWidgetDenyList` with `AnimatedList`, `AnimatedSwitcher` and
  `animation_owner_names.dart` for `RepaintDetector` suppression. Out of
  scope for v0.15.5.
- **Why MAX rule (not MIN or SUM):** MIN would still let cards above the
  second expanded one shift under the user. SUM is nonsensical. MAX
  delivers the contract "nothing above anything I'm reading moves" at the
  cost of cards between two expanded cards also staying put — the
  simplest rule that satisfies the promise.
- **Known gap: adjacency eviction can shift the expanded card.** When a
  frozen card other than the expanded one is evicted from the visible
  set mid-read (detector staleness eviction, `computeVisibleIssues`
  absorbing a standalone under a new root, downstream collapse, etc.),
  the frozen zone compacts and visibly moves the expanded card up by
  one slot. The expanded card's index inside the zone changes even
  though the zone itself is still "frozen" by identity. Frequency: low
  — requires a multi-scan eviction of a frozen adjacent card while the
  user is actively reading an expanded card below it. Mitigation:
  `_pruneStaleState` releases the freeze on the next sweep once the
  expand entry is orphaned, and Flutter's frame batching typically
  absorbs the visual glitch in a single frame. A placeholder-row
  approach (preserving slot geometry for vanished frozen entries) would
  close the gap at the cost of visible "ghost" cards; deferred beyond
  v0.15.5.

Plan is ready for implementation.
