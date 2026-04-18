# Sleuth v0.16 Validation Sprint — Spec

## Title & Goal

**Title:** Raise every detector and every in-scope non-detector reliability
claim in Sleuth out of `unvalidated` before the v0.17 MCP milestone.

**Goal — HIGH CONFIDENCE exit criterion:** by the end of v0.16.6, every
detector and every in-scope non-detector reliability claim ships at its
natural ceiling tier. Target distribution for the 23 detectors:

- **2 detectors at `externallyCited`** — FrameTiming, NetworkMonitor. These
  two have threshold numbers backed by Flutter SDK constants or published
  responsiveness research (not "pattern-is-recommended" guidance).
- **8 detectors at `runtimeVerified`** — the 5 VM-only detectors (Shader
  Jank, Heavy Compute, Platform Channel, Memory Pressure, Repaint) + 3
  hybrid detectors (Rebuild, GPU Pressure, Shallow Rebuild Risk). Each
  ships with ≥3 checked-in profile-mode captures from a pinned reference
  device bracketing the threshold (below / at / above).
- **13 detectors at `reproducerOnly`** — all 13 structural detectors
  (setState Scope, Layout Bottleneck, ListView, Image Memory, GlobalKey,
  Nested Scroll, CustomPainter, Keep Alive, AnimatedBuilder, Opacity, Font
  Loading, RepaintBoundary, Startup). These are tree-shape heuristics; the
  Flutter docs that back the *pattern* (e.g. "use `ListView.builder` for
  large lists", "prefer `cacheWidth` on images") do not back Sleuth's
  specific threshold magnitude, so forcing them to `externallyCited` would
  be citation inflation. Rationale links to the pattern docs belong in the
  ledger's Notes column, not in `citationUrl`.

**In-scope non-detector components (10):**

1. `IssueRanker` (additive weighted score, 4 signals + transient-context
   modifier).
2. `CausalGraphRule` in `lib/src/analyzer/causal_graph.dart` — the 44
   downstream-edge rules used during issue correlation.
3. `DetectorCorrelator`'s 9 `CorrelationRule` subclasses in
   `lib/src/analyzer/detector_correlator.dart` — each ships distinct
   suppression / merge / escalation / enrichment logic with threshold
   numbers.
4. `RouteSession.healthScore` composite formula.
5. VM reconnect ladder + frame-budget constants.
6. `DebugInstrumentationCoordinator._frameworkWidgetDenyList` — the 49
   framework/Sleuth-overlay widget names that prevent Sleuth from measuring
   itself (v0.15.1 KDD-10). Already has an audit test; needs a
   `ComponentMetadata` wrapper.
7. `AnimationOwnerNames` (21 entries in
   `lib/src/utils/animation_owner_names.dart`) — the v0.15.3 animation-owner
   filter. Already has tests; needs a `ComponentMetadata` wrapper.
8. `SleuthController._applyDurationEscalation` 30-cycle warning→critical
   severity escalation (v0.10.8).
9. `FixVerificationResult` 5-cycle cooldown (v0.10.7) — the stability
   window before a fix is reported as verified.
10. `TimelineParser` phase-code classification — the B/E/b/e/X/i matrix
    for Dart VM timeline events. Load-bearing for every VM-driven detector;
    a single phase miscode silently drops events (the exact failure mode
    the flutter-expert skill's KDD calls out).

Target distribution for these 10: each reaches `reproducerOnly` minimum,
with opportunistic raises to `runtimeVerified` where a profile-mode capture
from v0.16.4 incidentally covers the claim (e.g. VM reconnect ladder during
a real 30 s USB-disconnect event).

**Explicitly deferred non-detector claims (v0.17.x+):** performance-only
internals whose failure degrades performance without breaking correctness:
`RecurrenceTrend` ring-buffer window size, `WidgetHeatMapEntry` aggregation
weights, adaptive scan interval (v0.10.6 M4), `_getAllIssues` generation
cache (v0.10.6 M5), `TypeNameCache` (v0.10.5 M1), highlight dirty-check
(v0.10.5 M2), `CpuSampleAggregator` fold thresholds. These ship
`unvalidated` at v0.16.6 exit, with an explicit ledger footnote naming
each and why it's deferred. This is not a silent escape hatch — the
deferral list is checked into the ledger.

The CI audit gate enforces both contracts (detector + component metadata)
and also validates the profile-capture format for anything claiming
`runtimeVerified`. The D3 follow-up from v0.16.1 lands in this sprint as
a prerequisite, not a deferred item.

`doc/validation_ledger.md` at end of v0.16.6: all 23 detector rows off
`unvalidated`; new "Non-Detector Components" section lists the 10 in-scope
components at `reproducerOnly` or stronger; a closing "Explicitly Deferred"
section names the 7 `unvalidated` perf internals with per-item rationale.

This is the final v0.16.x arc. MCP server work (v0.17.0) begins after this
ledger is clean.

## Scope

**In scope:**

1. A parallel `ComponentMetadata` + `ComponentMetadataProvider` framework
   for non-detector components, mirroring the existing `DetectorMetadata`
   / `DetectorMetadataProvider` shape.
2. A `ValidatedComponentRegistry` singleton that in-scope components
   register with at first access; the audit gate walks the registry rather
   than reflecting on classes (Dart does not expose static members on the
   class interface — this is the F1 pattern from v0.16.0).
3. Hermetic reproducers for every detector's primary threshold or
   heuristic, keyed against the existing `validationMetadata.reproducerPath`
   contract.
4. Hermetic reproducers for the 10 in-scope non-detector claims.
5. CI audit gate extension: walks both detectors and components; validates
   profile-capture schema; enforces the capture-bracketing rule (≥3
   captures per `runtimeVerified` detector, magnitude bounds recorded).
6. Ledger (`doc/validation_ledger.md`) and public-API barrel updates.

**Out of scope (deferred):**

- Tier raises beyond each detector's natural ceiling. Pattern-level Flutter
  docs are linked in the ledger Notes column, not promoted to
  `externallyCited`.
- Reliability-claim validation for the 7 performance-only internals listed
  in the Title & Goal's deferral block. These are caught in v0.17.x.
- New detectors, overlay UI changes, threshold retunes. Any bug surfaced
  during reproducer authoring that isn't blocking the reproducer itself is
  filed as a follow-up, not fixed in the sprint.
- Reference-device matrix broader than one iOS + one Android pinned model.
  Cross-device calibration is a v0.18+ conversation.
- Automation of profile-capture authoring. Manual DevTools export +
  metadata annotation is the v0.16.x process.
- MCP server work — moves to v0.17.0 after v0.16.6 ships.

## Dependency Diagram

```
v0.16.1 (shipped) — methodology + first tier raise (NetworkMonitor slow_request)
      │
      ▼
v0.16.2 — Infrastructure: ComponentMetadata + profile-capture contract
  ├── ComponentMetadata + ComponentMetadataProvider mixin
  ├── ValidatedComponentRegistry singleton + registration contract
  ├── Audit gate extension — walks non-detector components
  ├── Audit gate extension — validates profile-capture schema + bracketing
  ├── Reference-device policy + pinned device models documented
  ├── Capture-authoring checklist (DevTools export → metadata annotation)
  └── Public barrel exports the new types
        │
        ▼
v0.16.3 — 13 structural detectors → reproducerOnly
  ├── 13 hermetic structural reproducers (tree-shape heuristics)
  ├── Ledger Notes column links pattern-level Flutter docs where they exist
  └── All 13 structural detectors out of unvalidated
        │
        ▼
v0.16.4 — 8 VM-driven detectors → runtimeVerified
  ├── 5 VM-only + 3 hybrid: each with reproducer + ≥3 profile-mode captures
  ├── Captures bracket threshold (below / at / above) with magnitude bounds
  ├── Captures checked in under test/validation/captures/
  ├── Reference-device runs documented (script + pinned device per capture)
  └── Format-parse audit gate enforces capture schema + bracketing rule
        │
        ▼
v0.16.5 — 2 runtime detectors → externallyCited
  ├── FrameTimingDetector: Flutter engine vsync constants +
  │     refresh-rate budgets (60/90/120 Hz) cited
  ├── NetworkMonitorDetector: Nielsen/Miller responsiveness windows +
  │     Web Vitals TTFB (corrected numbers: 800/1800 ms) cited
  └── Both already have reproducers — this milestone adds the captures
        + verified citation URLs needed to cross to externallyCited
        │
        ▼
v0.16.6 — 10 non-detector components + ledger clean
  ├── IssueRanker → reproducerOnly (additive weighted-score formula)
  ├── CausalGraphRule (44 rules) → reproducerOnly
  ├── 9 DetectorCorrelator CorrelationRule subclasses → reproducerOnly
  ├── RouteSession.healthScore → reproducerOnly
  ├── VM reconnect ladder + frame budgets → reproducerOnly
  │     (runtimeVerified if v0.16.4 captures include a disconnect event)
  ├── _frameworkWidgetDenyList → reproducerOnly (wrap existing audit test)
  ├── AnimationOwnerNames → reproducerOnly (wrap existing tests)
  ├── _applyDurationEscalation 30-cycle → reproducerOnly
  ├── FixVerification 5-cycle cooldown → reproducerOnly
  ├── TimelineParser phase classification → reproducerOnly
  └── Ledger sweep: honest ceiling-lowering rationale + deferral footnote
        │
        ▼
v0.17.0 — MCP server (unblocked, ledger fully green)
```

Each milestone's reproducer set lands in the same PR as the tier raise and
ledger update for the detectors / components it covers. The audit gate
catches any skew between metadata and reproducer file existence.

## v0.16.2 — Infrastructure

No tier raises this milestone. The goal is to ship the framework work that
later milestones need.

### ComponentMetadata framework

Create `lib/src/validation/component_metadata.dart`:

```dart
class ComponentMetadata {
  const ComponentMetadata({
    required this.componentName,
    required this.tier,
    required this.rationale,
    this.citationUrl,
    this.reproducerPath,
    this.profileCapturePath,
    this.coveredClaimIds,
  });

  final String componentName; // e.g. 'IssueRanker', 'CausalGraphRule'
  final EvidenceTier tier;
  final String rationale;
  final String? citationUrl;
  final String? reproducerPath;
  final String? profileCapturePath;
  final Set<String>? coveredClaimIds; // parallel to coveredStableIds
}

mixin ComponentMetadataProvider {
  ComponentMetadata get validationMetadata;
}
```

Export `ComponentMetadata` + `ComponentMetadataProvider` from
`lib/sleuth.dart`.

### ValidatedComponentRegistry — resolves the registration gap

The detector audit walks `SleuthController.detectorsForAudit` because
detectors are controller-owned instances. Non-detector components have no
uniform ownership model: `IssueRanker` is a helper class, `CausalGraphRule`
is a `const` rule registry, the VM reconnect ladder is a constant array
in a service client, `_frameworkWidgetDenyList` is a `const Set` inside a
debug coordinator. Dart does not expose static members on the class
interface, so reflection-on-types is not an option (F1 from v0.16.0).

Resolution: a top-level `ValidatedComponentRegistry` singleton living at
`lib/src/validation/validated_component_registry.dart`:

```dart
class ValidatedComponentRegistry {
  static final ValidatedComponentRegistry instance =
      ValidatedComponentRegistry._();
  ValidatedComponentRegistry._();

  final List<ComponentMetadata> _components = [];

  void register(ComponentMetadata metadata) => _components.add(metadata);
  List<ComponentMetadata> get all => List.unmodifiable(_components);
}
```

Registration contract: each in-scope component publishes its metadata by
calling `ValidatedComponentRegistry.instance.register(_metadata)` from a
top-level `void _ensureRegistered()` initialiser in its own library file,
guarded against double-registration. The audit test imports the library of
every in-scope component (so its initialiser runs), then asserts the
registry contains the expected 10 entries.

This pattern sidesteps the Dart-interface limitation AND lets components
with no natural instance (e.g. `const` rule registries) participate
uniformly. The audit gate does not care how a component chose to publish
metadata — only that it's in the registry.

### Audit gate extensions

Add `test/validation/component_metadata_audit_test.dart` walking
`ValidatedComponentRegistry.instance.all`. Five invariants mirror the
detector gate:

1. Every in-scope component (expected: 10) is registered.
2. Each `ComponentMetadata` has a non-null, non-empty `rationale`.
3. `reproducerOnly` or stronger ⇒ `reproducerPath` points at a file that
   exists on disk.
4. `runtimeVerified` or stronger ⇒ `profileCapturePath` points at a file
   that exists AND parses against `ProfileCaptureSchema`.
5. `externallyCited` ⇒ `citationUrl` is non-null, non-empty, and passes a
   shape check (not a verification of content — verification is a
   human-review responsibility).

### Profile-capture schema + bracketing gate (D3 follow-up)

Today the audit gate only asserts file existence for `profileCapturePath`.
v0.16.4 is the first milestone to ship `runtimeVerified` detectors, so the
format-parse gate must land in v0.16.2.

**Schema definition:** `test/validation/profile_capture_schema.dart`:

```dart
/// Minimum fields required on a Sleuth profile capture. DevTools Chrome
/// Trace Event Format provides traceEvents; Sleuth requires hand-annotated
/// metadata (see test/validation/captures/README.md).
class ProfileCaptureSchema {
  static const required = {
    'traceEvents',   // list of Chrome Trace Event objects
    'sleuthMetadata', // object, hand-annotated post-export
  };

  static const requiredMetadata = {
    'device',            // e.g. "iPhone 13 mini"
    'deviceOsVersion',   // e.g. "iOS 17.6.1"
    'flutterVersion',    // e.g. "3.32.5"
    'captureCommand',    // exact fvm flutter run command used
    'scenario',          // what was done to trigger the event
    'expectedMagnitude', // {min, observed, max} in event-appropriate units
    'captureDate',       // ISO 8601
  };
}
```

The `sleuthMetadata` wrapper is a deliberate deviation from vanilla
DevTools exports. DevTools does not auto-emit `device` or `flutterVersion`,
so requiring them under a known namespace gives the audit gate a clean
assertion target AND makes the human-annotation step unambiguous. The
capture-authoring checklist (below) walks through the annotation.

**Bracketing rule:** each `runtimeVerified` detector must ship ≥3 captures
named `<detector>_below.json`, `<detector>_at.json`, `<detector>_above.json`
that exercise the threshold at three magnitudes. The audit gate verifies:

- All three files exist and parse.
- `sleuthMetadata.expectedMagnitude.observed` of `_below` is below the
  detector's threshold, `_at` is within ±10% of threshold, `_above` is
  above threshold.

Single captures are statistically weak evidence that a threshold is
correctly tuned — bracketing proves the threshold actually discriminates
the three regimes on the reference device.

### Capture-authoring checklist

Provide `test/validation/captures/README.md` documenting:

1. Running `fvm flutter run --profile` on the pinned reference device with
   the demo scenario mounted.
2. Opening DevTools → Performance tab → recording a timeline.
3. Exporting as JSON (DevTools menu: "Export timeline").
4. Opening the export in an editor; adding the `sleuthMetadata` wrapper at
   the root with the fields listed in `ProfileCaptureSchema.requiredMetadata`.
5. Trimming `traceEvents` to the relevant window if the file exceeds ~2 MB.
6. Committing under `test/validation/captures/<detector>_<variant>.json`.

The checklist is mandatory reading for anyone landing a tier raise — one
skipped annotation and the audit gate rejects the PR. That friction is
intentional: it replaces "a capture exists" (weak) with "a capture exists
and is provably from a pinned device at a specific magnitude" (strong).

### Reference-device policy — pinned models

**iOS baseline (pinned):** iPhone 13 mini, running iOS 17.6.1, profile
mode (`fvm flutter run --profile --device-id <id>`), Flutter stable 3.32.x.

**Android baseline (pinned):** Pixel 7 (non-Pro), running Android 14 (API
34), profile mode, Flutter stable 3.32.x.

Pinning to a specific model + OS version is deliberate. "iPhone 13 or
later" and "latest stable iOS" both bitrot — a year from now they mean
different hardware. The pin rotates once per calendar year, with the
rotation landing in its own changelog-worthy release, not silently inside
another tier raise.

Captures from other devices are rejected by the gate. Contributors can
propose new reference devices in a discussion issue, but cross-device
calibration is deferred to v0.18+.

## v0.16.3 — 13 structural detectors → reproducerOnly

Each detector gets a reproducer at
`test/validation/<detector_snake_name>_reproducer_test.dart`. Pattern: a
hermetic widget test mounts the anti-pattern, runs `scanTree(element)`,
asserts the expected `PerformanceIssue` emits with the right
`severity` / `confidence` / `stableId`, then mounts the corrected pattern
and asserts no issue emits.

All 13 structural detectors ship at `reproducerOnly`. For the 5 whose
pattern (not threshold) is documented externally, the ledger's Notes
column links the doc as context — `citationUrl` stays null because the
doc does not back Sleuth's specific threshold number.

| Detector | Threshold / heuristic | Ceiling tier | Ledger Notes link (pattern-level only) |
|---|---|---|---|
| setState Scope | Subtree-breadth estimation | `reproducerOnly` | — |
| Layout Bottleneck | IntrinsicHeight/Width presence, Wrap with N children | `reproducerOnly` | — |
| ListView | Non-builder constructor, sliver misuse | `reproducerOnly` | Flutter `ListView.builder` docs (recommends builder for large lists; does not define "large") |
| Image Memory | Decoded-vs-display ratio | `reproducerOnly` | Flutter `Image.cacheWidth` docs (recommends sizing; does not define a ratio threshold) |
| GlobalKey | Cross-scan recreation, scrollable density | `reproducerOnly` | — |
| Nested Scroll | Scroll-in-scroll pattern | `reproducerOnly` | — |
| CustomPainter | `shouldRepaint` always true | `reproducerOnly` | — |
| Keep Alive | N `AutomaticKeepAlive` in same scrollable | `reproducerOnly` | — |
| AnimatedBuilder | No `child:` param on large subtree | `reproducerOnly` | `AnimatedBuilder` API docs (documents `child`; does not define "large subtree") |
| Opacity | Opacity(0.0), AnimatedOpacity(0.0), FadeTransition(0.0) | `reproducerOnly` | — |
| Font Loading | Non-system font, fontFamilyFallback heuristic | `reproducerOnly` | — |
| RepaintBoundary | Expensive-GPU widget without boundary | `reproducerOnly` | Flutter performance best-practices guide (recommends boundary; does not define "expensive subtree") |
| Startup | TTFF-budget breach | `reproducerOnly` | Flutter app-startup docs + Android Vitals cold-start guidance (describes measurement; does not define Sleuth's TTFF budget) |

**Determinism assumption (H2):** the v0.16.3 pattern assumes `scanTree`
emission is deterministic given the same tree. Three detectors have
cross-scan state that breaks this assumption:

- **GlobalKey** (cross-scan recreation detection) — reproducer mounts,
  scans twice with a controlled key swap in between, asserts emission on
  the second scan.
- **Rebuild** (time-windowed noise floor) — reproducer injects a fake
  clock to advance deterministically; controller honours the injected
  clock (already done in v0.15.1).
- **Nested Scroll** (ancestor-resolution visit order) — reproducer uses a
  fixed tree topology; no ordering ambiguity within a single scan.

Any detector whose reproducer requires multi-scan orchestration or clock
injection lands the hermetic harness in the same PR as the reproducer,
not separately. If a detector can't be made deterministic in ≤2 working
days of reproducer work, file a follow-up and drop the detector to
"reproducer in progress" in the ledger rather than shipping a flaky test.

## v0.16.4 — 8 VM-driven detectors → runtimeVerified

Each detector gets three artifacts:

1. Hermetic reproducer at
   `test/validation/<detector>_reproducer_test.dart`, driven by synthetic
   timeline JSON via `test/helpers/timeline_test_helpers.dart`.
2. **Three profile-mode captures** (bracketing rule from v0.16.2):
   `<detector>_below.json`, `<detector>_at.json`, `<detector>_above.json`
   from pinned-reference-device runs. Each capture's `sleuthMetadata`
   includes `expectedMagnitude.{min, observed, max}` in the detector's
   native unit (µs, bytes/sec, paints/sec, etc.).
3. Reproducer file opens each of its three captures, invokes the detector
   against the timeline window, and asserts: `_below` → no issue emits,
   `_at` → issue emits at warning severity (or critical if the threshold
   boundary is the critical one), `_above` → issue emits at critical
   severity. This closes the gap where "capture exists" proves nothing
   about threshold tuning.

### VM-only (5)

| Detector | Threshold | Reproducer fixture | Capture bracket (below / at / above) |
|---|---|---|---|
| Shader Jank | Shader-compile duration during first-frame window | Synthetic `ShaderCompile` event inside warmup | Cold-start scenarios with primed cache / mixed cache / fully unprimed shader cache |
| Heavy Compute | UI-thread `Duration` event threshold | Synthetic UI-phase Duration event | `sleep(8ms)` / `sleep(16ms)` / `sleep(50ms)` in tap handler |
| Platform Channel | Call-duration + frequency heuristic | Async `'b'/'e'` pairs per send | 1 call/sec / 5 calls/sec / 30 calls/sec plugin-loop |
| Memory Pressure | GC-rate sliding-window + heap-growth regression | Synthetic GC events + heap poll | Idle / moderate allocation / unbounded allocation loops |
| Repaint | Per-widget paint-rate, animation-owner filter | Stubbed `DebugSnapshot` | 15 paints/sec / 30 paints/sec / 60 paints/sec unthrottled subtree |

### Hybrid (3)

| Detector | Threshold | Reproducer fixture | Capture bracket |
|---|---|---|---|
| Rebuild | Sustained-rate + 30-build / 1.5 s noise floor | Synthetic `FlutterTimeline.debugCollect()` output | 10 builds/sec / 20 builds/sec / 50 builds/sec Provider storm |
| GPU Pressure | Raster-thread dominance ratio, sustained window | Synthetic raster-phase events | Static scene / one `BackdropFilter` / three stacked `BackdropFilter`s |
| Shallow Rebuild Risk | Tree-depth + build-count coupling | Shallow-stateful fixture + synthetic build counts | Provider-storm scene (shallow-Stateful variant): 10/20/50 builds/sec |

**Capture-authoring note:** the initial pass is manual — follow the
capture-authoring checklist from v0.16.2. Automation is explicit v0.18+
work; three captures × 8 detectors = 24 captures for v0.16.4, with total
storage budget ≤ 48 MB (2 MB/capture ceiling). If a single capture exceeds
2 MB after trimming, open a follow-up to tighten the capture window rather
than gzip'ing.

**Ordering:** ship detectors in this order so earlier runs can produce
opportunistic byproducts for v0.16.6:

1. Memory Pressure (byproduct: long-duration capture usable for
   `_applyDurationEscalation` reproducer).
2. Rebuild (byproduct: deep-tree capture usable for `_frameworkWidgetDenyList`
   self-measurement regression check).
3. Heavy Compute, Platform Channel, Shader Jank, Repaint, GPU Pressure,
   Shallow Rebuild Risk.

## v0.16.5 — 2 runtime detectors → externallyCited

### FrameTimingDetector

- **Citations (all verified and URL-pinned before tier raise):**
  - Flutter engine vsync-period constants in
    `packages/flutter/lib/src/scheduler/binding.dart` (grep
    `kDefault`; pin commit SHA in the ledger because the file evolves).
  - `FrameTiming.vsyncStart` / `buildStart` / `rasterFinish` API docs in
    `dart:ui` (pin Flutter version in ledger).
  - Android Vitals "frozen frame" definition (700 ms) and "janky frame"
    definition (16.67 ms @ 60 Hz baseline) — via the Android developer
    docs page on render performance (verify URL is still live; link rot
    check is part of the PR).
- **Captures (required):** two profile-mode captures at 60 Hz and 120 Hz,
  each showing jank-frame classification matching the refresh-rate-aware
  thresholds. Bracketing rule applies: `_below`/`_at`/`_above` per
  refresh-rate, so 6 captures total.
- **Existing reproducer:** `handleTimingsForTest`-driven test from v0.16.0;
  extended to load the 6 captures and verify classification matches.

### NetworkMonitorDetector

- **Current state:** `reproducerOnly` for `slow_request` (v0.16.1).
- **This milestone raises ALL 5 issue families:** `slow_request`,
  `large_response`, `request_frequency`, `http_error_spike`,
  `high_frequency_same_path` — Layer 1 (boundary) + Layer 2 (loopback
  HttpServer) reproducers per family. Existing v0.16.1 test refactored to
  parameterise across families without duplication.
- **Citations (verified, replaces v0.16.1 spec's broken set):**
  - **Nielsen/Miller perceived-responsiveness windows (100 ms / 1 s / 10 s)
    — Jakob Nielsen, *Usability Engineering* (1993), building on Robert
    Miller's 1968 paper.** These are the authoritative source for the 1 s
    "feels like waiting" threshold that backs NetworkMonitor's 1000 ms
    slow-request boundary. Do NOT attribute to Apple HIG.
  - **Google Web Vitals TTFB — 800 ms (good), 1800 ms (poor).** TTFB is
    page-load first-byte, not arbitrary API latency, so cite this as
    context — it supports the *magnitude* of Sleuth's thresholds, not as
    the definitional source. The v0.16.1 spec's numbers (1000/1800) were
    wrong; corrected here to 800/1800.
  - **Android developer docs — App startup time targets (cold ≤ 5 s)**
    as context for the 3000 ms critical threshold (a failed network call
    blocking startup at 3 s already puts cold-start in danger of
    exceeding the 5 s target). Verify URL before commit.
  - **Dropped from the v0.16.1 spec:** "Apple HIG perceived-responsiveness
    windows" (provenance was Nielsen, not Apple); "Android Vitals
    HttpClient perf best-practices" (document does not exist as named);
    the wrong Web Vitals numbers.
- **Captures:** loopback-server Layer 2 reproducer already produces
  deterministic traces; commit one real-device capture per family (5
  captures) hitting a remote test endpoint for Layer 3 evidence.
- **`coveredStableIds` expansion:** drop the `{'slow_request'}` pin; all
  5 families now covered.

## v0.16.6 — 10 non-detector components + ledger clean

Each component gets `ComponentMetadata` registered with
`ValidatedComponentRegistry` and a reproducer under `test/validation/`.

### IssueRanker → reproducerOnly

- **Actual claim (verified against `lib/src/ranking/issue_ranker.dart:101-104`):**
  ```
  score = (severityScore × 100) + (frameImpactScore × 8)
        + (confidenceScore × 5) + (recurrence × 2)
  ```
  With transient-context deprioritization: if
  `issue.interactionContext ∈ {scrolling, appLifecycle}`, `recurrence` is
  multiplied by 0.7 before the final sum. Score is **additive** across
  **four signals**, not multiplicative across three.

- **Reproducer:** golden test at
  `test/validation/issue_ranker_reproducer_test.dart`. Fixture of 10
  crafted `PerformanceIssue` instances covering:
  - Each severity × confidence combination pinned to a known score.
  - Transient-context pair: same issue with `scrolling` vs `idle` context,
    scores differ by the `recurrence × 2 × 0.3` expected delta.
  - Pure recurrence ordering: 5 issues identical except recurrence count.
  - Pure frame-impact ordering: 5 issues identical except category.
- **`coveredClaimIds`:** `{'additive_score_v1'}`. A re-weighting or
  formula change in v0.18+ raises a new claim ID.

### CausalGraphRule (44 rules) → reproducerOnly

- **Claim:** 44 downstream-edge causal rules in
  `lib/src/analyzer/causal_graph.dart`'s `_causalRules` const list, used
  by `CausalGraphRule extends CorrelationRule`. Rule count pinned at 44;
  the stale `// 44 causal rules` comment at causal_graph.dart:39 is
  reconciled with an audit-test assertion so the two never drift.
- **Reproducer:** parameterised test at
  `test/validation/causal_graph_reproducer_test.dart`. One `test()` per
  rule. Minimal input shape triggers the edge; assertion pins the
  downstream annotation.
- **`coveredClaimIds`:** the 44 rule names (one per rule). Audit gate
  fails if a rule name appears in the code list but not in
  `coveredClaimIds`, enforcing test coverage on every future rule add.

### DetectorCorrelator's 9 CorrelationRule subclasses → reproducerOnly

- **Claim:** 9 class-based correlation rules in
  `lib/src/analyzer/detector_correlator.dart`:
  `SuppressAnimatedBuilderRule`, `MergeRebuildSetStateRule`,
  `EscalateGpuCustomPainterRule`, `EscalateMemoryImageRule`,
  `EscalateKeepAliveMemoryRule`, `EscalateStructuralWithJankRule`,
  `EscalateStructuralWithRebuildRule`, `EnrichRebuildRepaintBoundaryRule`,
  `DeduplicateRebuildRepaintRule`. Each has distinct suppression / merge
  / escalation / enrichment logic with threshold numbers.
- **Reproducer:** 9 hermetic tests at
  `test/validation/detector_correlator_reproducer_test.dart`. Each mounts
  the two-or-three issues the rule operates over, invokes the rule, and
  asserts the exact annotation, merge, escalation, or deduplication
  outcome.
- **`coveredClaimIds`:** the 9 class names.

### RouteSession.healthScore → reproducerOnly

- **Actual claim (verified against `lib/src/models/route_session.dart:116-150`):**
  ```
  healthScore = fpsComponent + (30 - jankPenalty) + (30 - issuePenalty)
  ```
  Where:
  - `fpsComponent = (averageFps / fpsTarget) × 40`, clamped to [0, 40].
  - `jankPenalty = (jankFrames / totalFrames) × 30`, clamped to [0, 30].
  - `issuePenalty = min(criticalCount × 10 + warningCount × 3, 30)` —
    **severity-weighted, not flat 30**.
  - Result rounded and clamped to [0, 100].
- **Two short-circuits:**
  - `total == 0 && issueSnapshots.isEmpty` → returns 100 (no data =
    healthy).
  - `total == 0 && issueSnapshots.isNotEmpty` → grants full 40
    `fpsComponent` despite zero frame data. Degenerate edge case where a
    route with only pre-frame issues scores higher than a route with
    frames + same issues. Pin this behaviour in the reproducer so a
    future refactor can't silently change it.
- **Reproducer:** golden test at
  `test/validation/route_session_health_score_reproducer_test.dart`. 7
  fixture routes:
  1. Healthy (target FPS, no jank, no issues) → 100.
  2. Jank-bound (target FPS, 50% jank frames, no issues) → 85.
  3. Issue-bound (target FPS, no jank, 1 critical + 2 warnings) → 84.
  4. Combined (half-target FPS, 25% jank, 1 critical) → pinned integer.
  5. Short-circuit A: no frames, no issues → 100.
  6. Short-circuit B: no frames, with issues → pinned integer proving
     fpsComponent defaults to 40.
  7. Issue-penalty clamp: 10 criticals → issuePenalty caps at 30.
- **Possible runtimeVerified upgrade:** reference-device session capture
  showing the formula produces a sensible score against a real route.
  Opportunistic — don't block the milestone.
- **`coveredClaimIds`:** `{'health_score_v1'}`.

### VM reconnect ladder + frame-budget constants

- **Claim:** reconnect ladder `[1 s, 2 s, 4 s, 8 s, 16 s]` recovers within
  ~31 s of disconnect (C3 from v0.16.0).
- **Reproducer:** deterministic-clock test on the scheduler at
  `test/validation/vm_reconnect_ladder_reproducer_test.dart`.
- **Opportunistic runtimeVerified:** if a v0.16.4 capture run naturally
  includes a USB-disconnect event showing the ladder firing, commit that
  capture with ladder-recovery metadata. Otherwise ship `reproducerOnly`.
- **Frame-budget constants** (refresh-rate-derived): arithmetic unit test
  pinning the derivation from `kDefault` constants.
- **`coveredClaimIds`:** `{'reconnect_ladder_v1', 'frame_budget_60hz',
  'frame_budget_90hz', 'frame_budget_120hz'}`.

### `_frameworkWidgetDenyList` → reproducerOnly

- **Claim:** the 49-entry deny list in
  `DebugInstrumentationCoordinator._frameworkWidgetDenyList` prevents
  Sleuth from self-measuring (v0.15.1 KDD-10).
- **Existing evidence:** `test/debug/overlay_denylist_audit_test.dart`
  already walks `lib/src/ui/**/*.dart` asserting coverage.
- **v0.16.6 delta:** wrap with `ComponentMetadata`. No new reproducer —
  the existing audit test IS the reproducer. Point `reproducerPath` at it.
- **`coveredClaimIds`:** `{'denylist_v0_15_1'}`.

### `AnimationOwnerNames` → reproducerOnly

- **Claim:** the 21-entry owner list in `lib/src/utils/animation_owner_names.dart`
  filters animation-owned paints from `RepaintDetector`'s excessive-repaint
  rate (v0.15.3).
- **Existing evidence:** `test/detectors/repaint_animation_owners_real_widget_test.dart`
  exercises all 21 owners.
- **v0.16.6 delta:** wrap with `ComponentMetadata`. Point `reproducerPath`
  at the existing test.
- **`coveredClaimIds`:** `{'animation_owners_v0_15_3'}`.

### `_applyDurationEscalation` 30-cycle → reproducerOnly

- **Claim:** warning-severity issues persisting for ≥30 cycles auto-escalate
  to critical (v0.10.8).
- **Reproducer:** deterministic-cycle test at
  `test/validation/duration_escalation_reproducer_test.dart`. Fixture:
  inject a synthetic warning issue, tick the controller 29 times
  (still warning), tick once more (escalates to critical), tick 10 more
  (stays critical), clear the issue (decay ignored — escalation is
  one-way by design).
- **`coveredClaimIds`:** `{'duration_escalation_v0_10_8'}`.

### `FixVerificationResult` 5-cycle cooldown → reproducerOnly

- **Claim:** a fix is reported as `verified` only after 5 consecutive
  cycles without the issue re-firing (v0.10.7).
- **Reproducer:** deterministic-cycle test at
  `test/validation/fix_verification_reproducer_test.dart`. Fixture: issue
  fires, disappears, ticks 4 cycles (still `probationary`), ticks one
  more (now `verified`), re-fires (drops back to unverified), ensures
  counter resets.
- **`coveredClaimIds`:** `{'fix_cooldown_v0_10_7'}`.

### `TimelineParser` phase classification → reproducerOnly

- **Claim:** Dart VM timeline phase codes are classified correctly across
  all six forms (`'X'` complete, `'B'`/`'E'` sync begin/end, `'b'`/`'e'`
  async begin/end, `'i'`/`'I'` instant). Silently dropping a phase form
  is the classic format-boundary bug (flutter-expert KDD).
- **Reproducer:** parameterised test at
  `test/validation/timeline_parser_phase_classification_reproducer_test.dart`.
  One `test()` per phase-code × event-type cell: build scope, layout
  scope, paint scope, raster scope, platform-channel async
  (debugProfilePlatformChannels wraps in `TimelineTask` → lowercase
  async `'b'`/`'e'`), shader-compile instant. 20+ test cases total.
- **`coveredClaimIds`:** the phase-code × event-type matrix cells.

### Ledger sweep + honesty pass

Walk `doc/validation_ledger.md` one final time:

1. **For every row declared at a tier higher than its current evidence:**
   either land the evidence (citation / capture / reproducer extension)
   or lower the declared ceiling.
2. **Every ceiling-lowering decision ships with:**
   - A written rationale block in the ledger (e.g. "GlobalKey density
     thresholds have no authoritative Flutter / Android / iOS guidance
     defining 'too many' — `reproducerOnly` is the natural ceiling").
   - A linked follow-up issue capturing what citation research was
     attempted and what was missing. The follow-up is a genuine pointer
     to future work, not a silent shelving.
   - Ceiling lowerings are logged in the v0.16.6 CHANGELOG entry with the
     detector name + one-line reason — reviewers reading release notes
     see the honesty trail, not just the ledger.
3. **Deferred components footnote:** the ledger's closing section lists
   the 7 explicitly deferred performance-only internals
   (`RecurrenceTrend`, `WidgetHeatMapEntry` aggregation, adaptive scan
   interval, `_getAllIssues` cache, `TypeNameCache`, highlight dirty-check,
   `CpuSampleAggregator`) with a per-item reason.

Exit condition: every ledger row is consistent with its declared tier;
zero detector rows at `unvalidated`; component section populated with the
10 in-scope components; deferred-components section names the 7 perf
internals; framework ready for MCP.

## Success criteria

A single `fvm flutter test` invocation at the end of v0.16.6 must:

1. Pass all root tests including the new reproducers. Estimated net new
   tests: **+150 to +200** across the sprint — runtimeVerified reproducers
   include capture-parse validation + 3-way bracketing assertions.
2. Pass **both** audit gates — detector metadata + component metadata —
   walking all 23 detectors and all 10 components.
3. Pass the new profile-capture schema gate on every checked-in capture
   file, AND the bracketing rule on every `runtimeVerified` detector's
   capture triplet.
4. Pass `fvm flutter analyze` with 0 issues.

And `doc/validation_ledger.md` must show:

- **Detectors section:** 2 rows at `externallyCited`, 8 rows at
  `runtimeVerified`, 13 rows at `reproducerOnly`. Zero rows at
  `unvalidated`.
- **Non-Detector Components section:** 10 rows at `reproducerOnly`
  minimum; any at `runtimeVerified` list their capture path.
- **Explicitly Deferred section:** 7 performance-only internals at
  `unvalidated` with per-item rationale.
- A closing paragraph naming every detector that intentionally ships
  below its original-draft ceiling and why — honesty beats inflation.

(This block is the single source of truth for the exit distribution. Any
deviation during implementation means the spec is wrong, not that the
implementation should drift.)

## Adversarial-review checkpoints

Run `/adversarial-review` after each milestone (v0.16.2, 3, 4, 5, 6)
individually; run `/advanced-adversarial-review` once at the end of
v0.16.6 on the full sprint delta before tagging the final release. The
sprint is the final v0.16.x arc, so it inherits the same
triangulation-before-tag discipline v0.16.0 and v0.16.1 followed.

## Known tradeoffs / assumed-accepted

- **Not every detector reaches `externallyCited`.** Only 2 of 23 ship at
  `externallyCited` in v0.16.6 because only 2 have threshold numbers
  backed by authoritative external sources. Pattern-level Flutter docs
  (e.g. "use `ListView.builder`") are linked in the ledger Notes column
  but don't promote the detector — Sleuth's specific thresholds are not
  in those docs. This is a bar-raising change from the original spec
  draft, motivated by F5 in the adversarial review: pattern-level
  citations are strictly weaker than `reproducerOnly` for a *threshold*
  claim, and inflating the tier damages the ledger's signal.
- **Structural detectors do not reach `runtimeVerified`.** A "50+
  descendant subtree" has no profile-capture magnitude. Capturing that
  `setState(() => ...)` on such a subtree causes jank on a reference
  device is possible, but the causal link is probabilistic (depends on
  what else was on screen) and would require multiple captures per
  detector to establish. The v0.18+ conversation.
- **Reference-device matrix = one pinned iOS + one pinned Android model.**
  Cross-device calibration (budget behaviour across refresh rates,
  chipsets, ARM / x86) is a v0.18+ conversation. One-device captures
  with ≥3-way bracketing are a meaningful floor, not a ceiling.
- **Non-detector reliability claims inventory is wider than the original
  4.** v0.16.6 covers 10 components. 7 performance-only internals are
  explicitly deferred to v0.17.x with per-item rationale in the ledger.
  The sprint does not perform an exhaustive reliability-claim audit of
  every file in `lib/src/`; new claims discovered post-sprint ship
  `unvalidated` by default and are caught in v0.17.x follow-ups.
- **One-per-release cadence abandoned.** The v0.16.1 ledger advertised
  "one detector per release"; the sprint compresses that to 3 validation
  releases (0.16.3, 4, 5) + 1 components release (0.16.6) preceded by
  one infrastructure release (0.16.2) because shipping 22+ releases for
  a validation arc is disproportionate to the work involved.
- **Profile-capture storage cost.** Each capture is typically 200 KB – 2
  MB of timeline JSON. 8 VM-driven detectors × 3 captures + 2 runtime
  detectors × 3-6 captures + opportunistic byproducts ≈ ~40-60 MB of new
  test fixtures. Acceptable for a diagnostics package; if it balloons
  past 100 MB, gzip-compress captures and extend the schema validator to
  decompress on read.
- **Capture-authoring is manual.** DevTools export → hand-annotation →
  commit is labour-intensive. Automation is explicit v0.18+ work; the
  v0.16.x process trades engineer time for schema rigor, which is the
  right tradeoff when the alternative is silent format drift.
- **Citation verification is a human-review responsibility.** The audit
  gate validates `citationUrl` is non-null-non-empty and shape-valid; it
  does not fetch the URL or verify the content matches Sleuth's claim.
  Every PR raising a tier to `externallyCited` is reviewed by a second
  engineer who clicks through the citation and confirms it backs the
  specific threshold. This is documented in CONTRIBUTING.md as part of
  the v0.16.2 landing.
