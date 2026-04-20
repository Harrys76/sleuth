# Detector Validation Ledger

_Last updated: v0.16.2 (2026-04-18)_

Sleuth ships 23 built-in detectors. This ledger is the public reliability
statement for each one — what evidence supports its current thresholds and
heuristics, and where to find it.

The ledger is enforced by
[`test/validation/detector_metadata_audit_test.dart`](../test/validation/detector_metadata_audit_test.dart),
which runs on every `fvm flutter test` and asserts that every built-in
detector carries non-null metadata, a non-empty rationale, and — for anything
above `unvalidated` — a reproducer path that points at a file on disk.

The source of truth for each row is the detector's own
`validationMetadata` getter (grep `EvidenceTier` in `lib/src/detectors/`).

## Evidence tiers

Four tiers, ordered weakest to strongest. A detector cannot skip tiers, and
adding a new tier requires a semver major bump:

| Tier | Meaning |
|------|---------|
| `unvalidated` | Rationale is documented but thresholds are not yet backed by a hermetic reproducer or citation. Honest starting state. |
| `reproducerOnly` | A deterministic, hermetic test in `test/validation/` exercises the detector end-to-end and pins its thresholds. |
| `runtimeVerified` | `reproducerOnly` plus a checked-in profile-mode capture (timeline JSON / DevTools snapshot) showing the claimed magnitude on a reference device. |
| `externallyCited` | `runtimeVerified` plus a citation to a Flutter SDK constant, dart-lang issue, or published benchmark. |

## Ledger

**Summary:** 1 / 23 at `reproducerOnly`, 22 / 23 at `unvalidated`. No
detectors currently at `runtimeVerified` or `externallyCited`.

### Runtime detectors (2)

| Detector | Tier | Reproducer | Notes |
|---|---|---|---|
| Network Monitor | `reproducerOnly` | [`network_monitor_reproducer_test.dart`](../test/validation/network_monitor_reproducer_test.dart) | Slow-request warning (1000 ms) and critical (3000 ms) thresholds covered by hermetic `processRecord` boundary tests plus a loopback `HttpServer` exercising the full `SleuthHttpOverrides → RequestRecord → processRecord` pipeline. `coveredStableIds = {'slow_request'}` — the other four issue families (`large_response`, `request_frequency`, `http_error_spike`, `high_frequency_same_path`) are implicitly `unvalidated`. |
| Frame Timing | `unvalidated` | — | FPS target (60), warmup duration (3 s), and refresh-rate-aware jank thresholds. Not yet cited to Flutter engine sources or verified via a profile-mode capture. |

### VM-only detectors (5)

| Detector | Tier | Reproducer | Notes |
|---|---|---|---|
| Shader Jank | `unvalidated` | — | Shader-compile duration threshold for first-frame jank attribution. Not runtime-verified against Impeller/Skia shader-compile budgets or externally cited. |
| Heavy Compute | `unvalidated` | — | Frame-blocking synchronous-compute duration threshold and attribution heuristic. Not runtime-verified or externally cited. |
| Platform Channel | `unvalidated` | — | Platform-channel call-duration threshold and frequency heuristic. Not runtime-verified or cited to Flutter platform-channel performance docs. |
| Memory Pressure | `unvalidated` | — | Memory growth thresholds, warmup, capacity, and 10 s sliding-window GC-rate calculation. Not runtime-verified against a low-memory device profile or externally cited. |
| Repaint | `unvalidated` | — | Excessive-repaint rate threshold (30 paints/sec) plus animation-owner filter. Not runtime-verified against refresh-rate-specific baselines or externally cited. |

### Hybrid detectors (3)

| Detector | Tier | Reproducer | Notes |
|---|---|---|---|
| Rebuild | `unvalidated` | — | Rebuild-rate thresholds (20 / 50 builds/sec) with 30-build / 1.5 s noise floor, plus profile-mode vs debug-mode attribution source. Not runtime-verified on a reference device or externally cited. |
| GPU Pressure | `unvalidated` | — | GPU-phase frame-time threshold and sustained-pressure window. Not runtime-verified against Impeller/Skia budgets or externally cited. |
| Shallow Rebuild Risk | `unvalidated` | — | Shallow-rebuild-risk structural heuristic. Not runtime-verified or externally cited. |

### Structural detectors (13)

| Detector | Tier | Reproducer | Notes |
|---|---|---|---|
| setState Scope | `unvalidated` | — | setState scope-breadth estimation heuristic. |
| Layout Bottleneck | `unvalidated` | — | Layout-phase duration threshold for bottleneck attribution. |
| ListView | `unvalidated` | — | Sliver anti-pattern heuristics (shrinkWrap inside sliver, SliverToBoxAdapter large subtree, SliverFillRemaining misuse). |
| Image Memory | `unvalidated` | — | Decoded-image-size vs. display-size ratio threshold. |
| GlobalKey | `unvalidated` | — | GlobalKey re-creation detection heuristic and threshold. |
| Nested Scroll | `unvalidated` | — | NestedScrollView-with-inner-scrollable structural heuristic. |
| CustomPainter | `unvalidated` | — | `shouldRepaint` override heuristic and repaint-frequency threshold. |
| Keep Alive | `unvalidated` | — | `AutomaticKeepAlive` misuse structural heuristic. |
| AnimatedBuilder | `unvalidated` | — | AnimatedBuilder-without-child-parameter heuristic for subtree-rebuild detection. |
| Opacity | `unvalidated` | — | Opacity(0) skip heuristic and saveLayer-cost threshold. |
| Font Loading | `unvalidated` | — | Font-load duration threshold and missing-asset-font heuristic. |
| RepaintBoundary | `unvalidated` | — | Missing-RepaintBoundary structural heuristic around animated subtrees. |
| Startup | `unvalidated` | — | TTFF/TTI phase-breakdown thresholds and slow-startup warning gate. |

## Non-Detector Components

Some components that make per-test reliability claims are not detectors —
rankers, causal-graph rules, const deny-lists, and so on. They carry their
tier claim via the parallel `ComponentMetadata` framework and register with
`ValidatedComponentRegistry` from a `static void registerMetadata()` entry
point.

**Summary:** 0 components currently registered. The audit gate
(`test/validation/component_metadata_audit_test.dart`) enforces the same
five invariants as the detector gate on any components that do register.
v0.16.2 exercises invariants 2–5 (rationale, tier-appropriate fields,
reproducer-file contract, capture-schema contract) against dormant
synthetic `ComponentMetadata` so the gate's per-invariant logic is live
today. Invariant 1 (registration dispatch — "did you forget to call
`registerMetadata()`?") is wired but unreachable until the first real
component lands in v0.16.6; its dispatch site is trivially exercised
against an empty expected-components list today.

| Component | Tier | Reproducer | Notes |
|---|---|---|---|
| _(none yet)_ | — | — | First real registration expected in v0.16.6 alongside the `IssueRanker` tier raise. |

## Roadmap

The v0.16 milestone arc is carrying detectors up the ledger one tier raise
per release:

- **v0.16.0** — Validation methodology infrastructure (`EvidenceTier`,
  `DetectorMetadata`, audit gate contract).
- **v0.16.1** — First tier raise: `NetworkMonitorDetector` at `reproducerOnly`
  for `slow_request`.
- **v0.16.2** — Infrastructure for `runtimeVerified` and `externallyCited`:
  `ComponentMetadata` + `ValidatedComponentRegistry`, `ProfileCaptureSchema`
  with bracketing-rule triad check, pinned reference-device matrix,
  capture-authoring README, `profileCapturePath` → `profileCapturePaths`
  list rename. **← current release**
- **v0.16.3+** — One detector per release, each raise landing with its
  reproducer (and, where applicable, its bracketing triad of captures) in
  the same PR. Order not yet committed; detector selection is driven by
  which threshold is most load-bearing in real apps and which is cheapest
  to pin deterministically.

Follow-up work called out in the v0.16.1 adversarial-review cycle:

- **Canonical issue-family identifiers** (v0.16.2+ or next multi-family tier
  raise) — so `coveredStableIds` can scope parameterized stable IDs without
  relying on the "prefix up to `:`" convention.
- **Format/parse validation for `profileCapturePath`** (first
  `runtimeVerified` raise) — so file existence alone does not satisfy the
  audit gate once a detector claims a profile-mode capture backs its
  thresholds.

## How to contribute a tier raise

1. Pick a detector at `unvalidated`.
2. Write a hermetic reproducer at `test/validation/<detector_name>_reproducer_test.dart`
   that pins the detector's thresholds end-to-end.
3. Update the detector's `validationMetadata`:
   - raise `tier` to `EvidenceTier.reproducerOnly`
   - set `reproducerPath` to the new file
   - rewrite the `rationale` to describe *what* is validated and *how*
   - for multi-family detectors, pin `coveredStableIds` to the families the
     reproducer actually exercises
4. Update this ledger's row.
5. Run `fvm flutter analyze` + `fvm flutter test` — the audit gate will
   enforce the contract.
