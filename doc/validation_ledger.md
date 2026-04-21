# Detector Validation Ledger

_Last updated: v0.16.5 (2026-04-21)_

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

**Summary:** 5 / 23 at `reproducerOnly`, 18 / 23 at `unvalidated`. No
detectors currently at `runtimeVerified` or `externallyCited`. v0.16.5
staged a second `externallyCited` raise on
`NetworkMonitorDetector.slow_request.warning` (1000 ms) and reverted it
on two grounds: (1) NN/g "Response Times: The 3 Important Limits" 1.0 s
is a UI direct-manipulation feedback guideline, not a generic HTTP
latency threshold — the detector emits `slow_request` for any
uncancelled request, so the citation does not substantiate the detector
contract; (2) profile captures verify scenario begin/end marker span
only, not detector-produced issue emission. Distribution is unchanged
from v0.16.3. The three capture files (812 / 1035 / 1515 ms on iPhone
12 / iOS 17.5 / Flutter 3.41.4) stay on disk as retained orphans
pointing at v0.16.6, which re-raises once the citation is replaced with
a source matching the detector semantics AND
`ProfileCaptureSchema.validateBracket` is extended to require
detector-produced issue markers inside the scenario window.

### Runtime detectors (2)

| Detector | Tier | Reproducer | Notes |
|---|---|---|---|
| Network Monitor | `reproducerOnly` | [`network_monitor_reproducer_test.dart`](../test/validation/network_monitor_reproducer_test.dart) | Hermetic reproducer: `processRecord` boundary tests at 999 / 1000 / 2999 / 3000 / 3001 ms plus a loopback `HttpServer` exercising the full `SleuthHttpOverrides` → `_MonitoringHttpClient` → `RequestRecord` → `processRecord` pipeline. Tier history: v0.16.1 → `reproducerOnly`; v0.16.4 staged `externallyCited` raise reverted (above capture at 3117 ms ambiently bracketed warning AND critical); v0.16.5 second staged `externallyCited` raise reverted on two grounds — (a) NN/g 1.0 s is a UI direct-manipulation feedback guideline, not a generic HTTP latency threshold, (b) profile captures validate scenario marker span, not detector emission. Three capture files retained on disk as orphans for v0.16.6 reuse: [`slow_request_below.json`](../test/validation/captures/network_monitor/slow_request_below.json) (812 ms), [`slow_request_at.json`](../test/validation/captures/network_monitor/slow_request_at.json) (1035 ms), [`slow_request_above.json`](../test/validation/captures/network_monitor/slow_request_above.json) (1515 ms). `coveredStableIds = {'slow_request'}` — four other families remain implicitly `unvalidated`. |
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
| ListView | `reproducerOnly` | [`listview_reproducer_test.dart`](../test/validation/listview_reproducer_test.dart) | 3 of 8 stable-id families pinned: `non_lazy_listview` (childThreshold boundary + `.builder` lazy-path bypass), `sliver_to_box_adapter_large`, and `sliver_fill_remaining_scrollable` as a **structural adjacency check** — fires when any scrollable descendant appears under `SliverFillRemaining(hasScrollBody: false)`, with `hasScrollBody: true` as the negative control. The runtime performance pathology this pattern correlates with is not directly measured (the real anti-pattern throws a layout error in `flutter_test`, forcing a `SizedBox` wrapper around the inner scrollable); the detector is `DetectorLifecycle.structural` by declaration, so structural-only validation is internally consistent. Remaining 5 families (`non_lazy_gridview`, `non_lazy_sliver_list`, `non_lazy_sliver_grid`, `sliver_to_box_adapter_shrinkwrap`, `non_lazy_list`) are implicitly `unvalidated` — same single-family-pin precedent as v0.16.1 NetworkMonitor. |
| Image Memory | `reproducerOnly` | [`image_memory_reproducer_test.dart`](../test/validation/image_memory_reproducer_test.dart) | 50dp small-image skip threshold pinned by 40×40 / 50×50 / 51×51 / 100×100 boundary triad, ResizeImage wrapper suppression, and the "zero is NOT small" unconstrained-size policy. **Both emission branches exercised**: the `Image` widget branch and the `DecoratedBox` branch (`Container` with `BoxDecoration.image` at 100×100 fires; `DecorationImage` wrapping a `ResizeImage` suppresses). Pure structural scan — no decode dependency. `coveredStableIds = {'uncached_images'}`. |
| GlobalKey | `reproducerOnly` | [`global_key_reproducer_test.dart`](../test/validation/global_key_reproducer_test.dart) | Both families pinned with their correct scope contracts: `excessive_global_keys` is **scrollable-gated** (threshold boundary + critical above 3× threshold; bare-tree keys ignored) while `global_key_recreation` is **whole-tree** (identity-hash churn across two scans on the same scan root fires in a scrollable context AND in a bare `Column` tree; State-held stable keys do not; first scan alone is silent because `_prevKeyIds` is empty). `coveredStableIds = {'excessive_global_keys', 'global_key_recreation'}` using the prefix convention for the indexed `excessive_global_keys:<i>` family. |
| Nested Scroll | `unvalidated` | — | NestedScrollView-with-inner-scrollable structural heuristic. |
| CustomPainter | `unvalidated` | — | `shouldRepaint` override heuristic and repaint-frequency threshold. |
| Keep Alive | `unvalidated` | — | `AutomaticKeepAlive` misuse structural heuristic. |
| AnimatedBuilder | `unvalidated` | — | AnimatedBuilder-without-child-parameter heuristic for subtree-rebuild detection. |
| Opacity | `reproducerOnly` | [`opacity_reproducer_test.dart`](../test/validation/opacity_reproducer_test.dart) | Exact-zero contract pinned (0.0 fires, 0.005 and 0.5 do not), AnimatedOpacity settled-at-zero fires exactly once (inner FadeTransition suppressed by `_insideAnimatedOpacity` depth counter), **standalone `FadeTransition`** settled at 0.0 fires via the `_insideAnimatedOpacity == 0` guard (non-zero does not), and nested `Opacity(0.0)` produces one rollup issue with a count reflecting both occurrences. `coveredStableIds = {'opacity_zero'}`. |
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
  list rename.
- **v0.16.3** — Four structural detectors raised to `reproducerOnly` in a
  single release: `ImageMemoryDetector`, `OpacityDetector`,
  `ListviewDetector` (3 of 8 families), `GlobalKeyDetector`. Pure
  structural scans with cheap hermetic boundary tests — no profile-mode
  capture dependency.
- **v0.16.4** — Validation-infrastructure hardening. Staged the first
  `externallyCited` tier raise on `NetworkMonitorDetector.slow_request`
  WARNING tier (NN/g citation + iPhone 12 / iOS 17.5 below/at/above triad)
  and reverted it post-adversarial-review: the `above` capture at 3117 ms
  ambiently brackets the 3000 ms critical tier. Infrastructure landed
  anyway: `DetectorMetadata.coveredThresholds` (severity-scoped evidence
  boundaries), `DetectorMetadata.aboveCeilingMultiplier` + schema-level
  `ProfileCaptureSchema.validateBracket` upper bound on `above`
  (default 2.0 × threshold), Flutter pin rotation 3.32 → 3.41,
  `allowedTracePhases` widened to include Perfetto `traceconv` `ph:'n'`,
  and `ProfileCaptureSchema._crossCheckTraceVsObserved` symmetric
  inverse-ratio guard. iPhone 12 / iOS 17.5 added to `approvedDevicePairs`
  as a one-time rotation exception documented in
  `doc/reference_devices.md` as non-precedent.
- **v0.16.5** — Second `externallyCited` tier raise staged and reverted.
  Two grounds: (1) NN/g "Response Times: The 3 Important Limits" 1.0 s is
  a UI direct-manipulation feedback guideline, not a generic HTTP
  latency threshold — the detector emits `slow_request` for any
  uncancelled request, so the citation does not substantiate the
  detector contract; (2) profile captures verify scenario begin/end
  marker span only, not detector-produced issue emission — a capture
  triad can pass the bracket audit even if the detector were disabled.
  Audit hardening landed and stays dormant until v0.16.6 re-raise:
  backtick normalisation on the mechanism-4 prose-drift guard so
  exclusion phrases match regardless of inline-code nesting around
  identifier fragments; L2 negative assertion on
  `coveredThresholds.*.critical`; default-drift cross-check between
  `DetectorMetadata.bracketThreshold` and the detector's runtime
  default. The three capture files on disk are retained orphans under
  the manifest pointing at v0.16.6. **← current release**
- **v0.16.6+** — Re-raise `NetworkMonitorDetector.slow_request.warning`.
  Prerequisites: (a) replace citation with a generic mobile/API HTTP
  latency source matching the detector semantics OR narrow the detector
  contract to user-blocking requests and enforce scope with a gate;
  (b) extend capture helper to emit a
  `sleuth.issue.slow_request.warning` trace/log record with the
  detector-measured duration; (c) extend
  `ProfileCaptureSchema.validateBracket` to require that record inside
  the scenario window. Remaining `unvalidated` detectors cluster around
  runtime/VM-driven thresholds (frame timing, memory pressure, GPU
  pressure) where the next tier raise will typically also need a
  reference-device profile capture.

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
