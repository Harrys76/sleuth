# Detector Validation Ledger

_Last updated: v0.17.2 (2026-04-24)_

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
| `reproducerOnly` | A deterministic, hermetic test (at `test/validation/<d>_reproducer_test.dart` for purpose-written reproducers OR `test/detectors/<d>_detector_test.dart` for detectors whose existing unit tests already exercise the emission path) pins the detector's thresholds and stableId families. Structural reproducers drive real `pumpWidget` + `scanTree`; vmOnly reproducers drive `processTimelineData` / `processHeapSample` directly (the VM → `TimelineParser` → detector contract is NOT exercised at this tier). |
| `runtimeVerified` | `reproducerOnly` plus a checked-in profile-mode capture (timeline JSON / DevTools snapshot) showing the claimed magnitude on a reference device. |
| `externallyCited` | `runtimeVerified` plus a citation to a Flutter SDK constant, dart-lang issue, or published benchmark. |

## Ledger

**Summary:** **23 / 23 at `reproducerOnly`, 0 / 23 at `unvalidated`**
in v0.17.2. No detectors at `runtimeVerified` or `externallyCited`.
**Tier not uniform.** v0.17.2 vmOnly reproducers drive detector
entrypoints directly (`processTimelineData` / `processHeapSample`);
VM → `TimelineParser` → detector boundary not exercised. Prior
structural batches (v0.16.3, v0.17.1) drove real `pumpWidget` +
`scanTree` — materially stronger evidence. v0.17.2 raises the final
8 vmOnly + hybrid detectors in a single bulk batch:
`ShaderJankDetector`, `HeavyComputeDetector`, `PlatformChannelDetector`,
`MemoryPressureDetector`, `GpuPressureDetector`, `RepaintDetector`,
`RebuildDetector`, and `ShallowRebuildRiskDetector`. Reproducers reuse
the existing `test/detectors/*_detector_test.dart` suites — fixtures are
synthetic and predate the validation methodology, disclosed in each
rationale. Two partial-coverage disclosures ship in this batch:
`RepaintDetector` (parametric `repaint_debug_<typeName>` uncovered) and
`RebuildDetector` (`rebuild_activity` + parametric
`rebuild_debug_<typeName>` uncovered). v0.17.1 raised 9 structural
detectors in a single bulk batch: `LayoutBottleneckDetector`,
`NestedScrollDetector`, `CustomPainterDetector`,
`AnimatedBuilderDetector`, `KeepAliveDetector`, `FontLoadingDetector`,
`RepaintBoundaryDetector`, `SetStateScopeDetector`, and
`StartupDetector` — all pure structural or one-shot scans. A parameterised anchor test
(`detector_metadata_audit_test.dart` → `v0.17.1 structural batch
pinned at reproducerOnly`) pins the (type → reproducerPath →
coveredStableIds) triple for all 9 so silent rename / stableId drift
/ path churn trips CI. v0.16.6 raised `FrameTimingDetector`
unvalidated → `reproducerOnly` (4 stableIds) and backfilled
`ListviewDetector` coverage 3 → all 8 stableIds. v0.16.5 staged a
second `externallyCited` raise on
`NetworkMonitorDetector.slow_request.warning` (1000 ms) and reverted
it: (1) NN/g "Response Times" 1.0 s is a UI direct-manipulation
feedback guideline, not a generic HTTP latency threshold; (2) profile
captures verify scenario marker span only, not detector-produced
issue emission. v0.16.6 shipped without re-raising NetworkMonitor;
re-raise deferred to v0.18.0 (orphan manifest `consumeBy: '0.18.0'`
after v0.17.0 bumped the lifecycle). Three capture files
(812 / 1035 / 1515 ms on iPhone 12 / iOS 17.5 / Flutter 3.41.4) stay
on disk as retained orphans with `consumeBy: '0.18.0'`.

### Runtime detectors (2)

| Detector | Tier | Reproducer | Notes |
|---|---|---|---|
| Network Monitor | `reproducerOnly` | [`network_monitor_reproducer_test.dart`](../test/validation/network_monitor_reproducer_test.dart) | Hermetic reproducer: `processRecord` boundary tests at 999 / 1000 / 2999 / 3000 / 3001 ms plus a loopback `HttpServer` exercising the full `SleuthHttpOverrides` → `_MonitoringHttpClient` → `RequestRecord` → `processRecord` pipeline. Tier history: v0.16.1 → `reproducerOnly`; v0.16.4 staged `externallyCited` raise reverted (above capture at 3117 ms ambiently bracketed warning AND critical); v0.16.5 second staged `externallyCited` raise reverted on two grounds — (a) NN/g 1.0 s is a UI direct-manipulation feedback guideline, not a generic HTTP latency threshold, (b) profile captures validate scenario marker span, not detector emission. Three capture files retained on disk as orphans for v0.16.7 reuse (manifest `consumeBy: '0.16.7'`): [`slow_request_below.json`](../test/validation/captures/network_monitor/slow_request_below.json) (812 ms), [`slow_request_at.json`](../test/validation/captures/network_monitor/slow_request_at.json) (1035 ms), [`slow_request_above.json`](../test/validation/captures/network_monitor/slow_request_above.json) (1515 ms). `coveredStableIds = {'slow_request'}` — four other families remain implicitly `unvalidated`. |
| Frame Timing | `reproducerOnly` | [`frame_timing_reproducer_test.dart`](../test/validation/frame_timing_reproducer_test.dart) | Four stableIds pinned by hermetic reproducer: `sustained_jank` (≥3 severe frames in a 60-frame window), `jank_detected` (>15% jank frames, ≥5-frame sample), `raster_cache_thrashing` (≥15 consecutive frames of ≥20% picture-cache-count fluctuation, seeded by `previous.pictureCacheCount > 5`), and `raster_cache_growing` (≥30 consecutive frames of monotonic picture-cache-count growth). Reproducer bypasses warmup via `warmupDuration: Duration.zero`; every stableId has a synthetic `FrameStats` path plus a real `FrameTiming` integration leg via `handleTimingsForTest` so hand-written synthetic fixtures cannot encode the detector's own expected shape (anti-tautology, Tactic 9). Impeller-zero suppression (all four cache metrics zero for ≥30 frames) pinned by a dedicated `pictureCacheBytes: 1` belt-and-suspender test. v0.17.0 added a `FPS semantics` group (6 tests via the real `handleTimingsForTest` path) pinning rolling-window `actualFps` against batched delivery, window slides, 120 Hz capacity, and null-rasterFinishUs handling — stableId coverage unchanged because FPS reporting is orthogonal to jank classification. Next raise (reproducerOnly → `runtimeVerified`) requires a profile-mode capture triad with a detector-emitted trace record inside the scenario window; a subsequent raise to `externallyCited` additionally requires a Flutter docs citation matching the 16.67 ms budget semantics. |

### VM-only detectors (5)

| Detector | Tier | Reproducer | Notes |
|---|---|---|---|
| Shader Jank | `reproducerOnly` | [`shader_jank_detector_test.dart`](../test/detectors/shader_jank_detector_test.dart) | Shader-compile duration threshold pinned via `processTimelineData` with synthetic shader-compile events. `coveredStableIds = {'shader_compilation'}`. Fixtures synthetic (predate methodology). |
| Heavy Compute | `reproducerOnly` | [`heavy_compute_detector_test.dart`](../test/detectors/heavy_compute_detector_test.dart) | Frame-gap threshold pinned via synthetic timeline events. `coveredStableIds = {'heavy_compute'}`. Fixtures synthetic. |
| Platform Channel | `reproducerOnly` | [`platform_channel_detector_test.dart`](../test/detectors/platform_channel_detector_test.dart) | >20/sec call-frequency threshold pinned via synthetic channel-call events. `coveredStableIds = {'platform_channel_traffic'}`. Fixtures synthetic. |
| Memory Pressure | `reproducerOnly` | [`memory_pressure_detector_test.dart`](../test/detectors/memory_pressure_detector_test.dart) | All 4 emission families pinned via synthetic heap/RSS timeseries: `gc_pressure`, `heap_growing`, `heap_near_capacity`, `native_memory_growing`. Warmup + 10 s sliding-window guards pinned. Fixtures synthetic. |
| Repaint | `reproducerOnly` | [`repaint_detector_test.dart`](../test/detectors/repaint_detector_test.dart) | **Partial coverage.** `coveredStableIds = {'excessive_repaint', 'excessive_repaint_debug'}`. Parametric `repaint_debug_<typeName>` family uncovered at detector scope (uses `_` separator; audit gate prefix convention uses `:`). Fixtures synthetic. |

### Hybrid detectors (3)

| Detector | Tier | Reproducer | Notes |
|---|---|---|---|
| Rebuild | `reproducerOnly` | [`rebuild_detector_test.dart`](../test/detectors/rebuild_detector_test.dart) | Two families pinned: `stateful_density` + `rebuild_activity` (warning at `buildCount > rebuildsPerSecThreshold` default 10/sec, critical at `> 3 × threshold` = 30/sec; test-pinned at 15 → warning and 35 → critical). Known narrowing: parametric `rebuild_debug_<typeName>` uses `_` separator, outside audit prefix convention. Fixtures synthetic. |
| GPU Pressure | `reproducerOnly` | [`gpu_pressure_detector_test.dart`](../test/detectors/gpu_pressure_detector_test.dart) | Both emission families pinned: `raster_dominance` (VM timeline raster > UI × 2.0 sustained) and `expensive_gpu_nodes` (tree walk corroborated by raster pressure). Confidence downgrade on VM disconnect pinned. Fixtures synthetic. |
| Shallow Rebuild Risk | `reproducerOnly` | [`shallow_rebuild_risk_detector_test.dart`](../test/detectors/shallow_rebuild_risk_detector_test.dart) | `shallow_rebuild_risk` pinned via real `pumpWidget` tree with shallow StatefulWidget + VM-staged high-build-activity data. Framework-widget suppression pinned. Fixtures synthetic. |

### Structural detectors (13)

| Detector | Tier | Reproducer | Notes |
|---|---|---|---|
| setState Scope | `reproducerOnly` | [`setstate_scope_reproducer_test.dart`](../test/validation/setstate_scope_reproducer_test.dart) | **Structural / possible-confidence path only** pinned: widest public StatefulWidget owns > `dirtyRatioThreshold` of tree AND `_maxSubtreeSize > minSubtreeSize`. Private-named widgets skipped (`!name.startsWith("_")`), animation-scope suppression, and below-minSubtreeSize silence pinned as negative controls. The DebugSnapshot confidence-upgrade path (likely / confirmed via rebuild-counter correlation) is a known gap not covered at this tier — documented in the detector rationale. Thresholds tuned down in tests to validate classification semantics, not threshold values. `coveredStableIds = {'setstate_scope'}`. |
| Layout Bottleneck | `reproducerOnly` | [`layout_bottleneck_reproducer_test.dart`](../test/validation/layout_bottleneck_reproducer_test.dart) | Both families pinned: `layout_bottleneck` (IntrinsicHeight / IntrinsicWidth structural trigger) and `wrap_layout_bottleneck` (Wrap with > `wrapChildThreshold` children, strict-greater). Pure structural scan — no layout-phase timing dependency — so the reproducer covers the full runtime trigger path. `coveredStableIds = {'layout_bottleneck', 'wrap_layout_bottleneck'}`. |
| ListView | `reproducerOnly` | [`listview_reproducer_test.dart`](../test/validation/listview_reproducer_test.dart) | All 8 stable-id families pinned (v0.16.6 backfill from 3 → 8). Non-lazy construction families: `non_lazy_listview`, `non_lazy_gridview`, `non_lazy_sliver_list`, `non_lazy_sliver_grid` (each with list-delegate eager + builder-lazy negative control), and `non_lazy_list` (`SingleChildScrollView` + `Column`/`Row` above threshold, at-threshold silent). Sliver boundary families: `sliver_to_box_adapter_large` (Column subtree above threshold), `sliver_to_box_adapter_shrinkwrap` (Check-C gate pinned by a three-test triad — shrinkWrap:true fires, shrinkWrap:false silent, many-children-in-list-delegate routes to Check A non_lazy_listview not Check C, pinning the isNonLazy bypass), and `sliver_fill_remaining_scrollable` as a **structural adjacency check** — fires when any scrollable descendant appears under `SliverFillRemaining(hasScrollBody: false)`, with `hasScrollBody: true` as the negative control. The runtime performance pathology the sliver_fill_remaining pattern correlates with is not directly measured (the real anti-pattern throws a layout error in `flutter_test`, forcing a `SizedBox` wrapper around the inner scrollable); the detector is `DetectorLifecycle.structural` by declaration, so structural-only validation is internally consistent. v0.16.N re-raise to `runtimeVerified` would require a profile-mode capture triad per family demonstrating measurable frame-budget impact under the non-lazy construction path. |
| Image Memory | `reproducerOnly` | [`image_memory_reproducer_test.dart`](../test/validation/image_memory_reproducer_test.dart) | 50dp small-image skip threshold pinned by 40×40 / 50×50 / 51×51 / 100×100 boundary triad, ResizeImage wrapper suppression, and the "zero is NOT small" unconstrained-size policy. **Both emission branches exercised**: the `Image` widget branch and the `DecoratedBox` branch (`Container` with `BoxDecoration.image` at 100×100 fires; `DecorationImage` wrapping a `ResizeImage` suppresses). Pure structural scan — no decode dependency. `coveredStableIds = {'uncached_images'}`. |
| GlobalKey | `reproducerOnly` | [`global_key_reproducer_test.dart`](../test/validation/global_key_reproducer_test.dart) | Both families pinned with their correct scope contracts: `excessive_global_keys` is **scrollable-gated** (threshold boundary + critical above 3× threshold; bare-tree keys ignored) while `global_key_recreation` is **whole-tree** (identity-hash churn across two scans on the same scan root fires in a scrollable context AND in a bare `Column` tree; State-held stable keys do not; first scan alone is silent because `_prevKeyIds` is empty). `coveredStableIds = {'excessive_global_keys', 'global_key_recreation'}` using the prefix convention for the indexed `excessive_global_keys:<i>` family. |
| Nested Scroll | `reproducerOnly` | [`nested_scroll_reproducer_test.dart`](../test/validation/nested_scroll_reproducer_test.dart) | Both families pinned: `nested_scroll` (inner-Scrollable count > `childThreshold`, strict-greater) and `nested_scroll_same_axis` (parent + inner sharing vertical axis). `NeverScrollableScrollPhysics` suppression and cross-axis silence pinned as negative controls so the axis-match contract cannot silently regress. `coveredStableIds = {'nested_scroll', 'nested_scroll_same_axis'}`. |
| CustomPainter | `reproducerOnly` | [`custom_painter_reproducer_test.dart`](../test/validation/custom_painter_reproducer_test.dart) | Both emission branches pinned: `always_repaint_painter` (shouldRepaint self-comparison returns true, exercised on both `painter` and `foregroundPainter` slots) and `frequent_repaint_painter` (paintsPerSecond > 30 via injected `DebugSnapshot`, silent at threshold — strict-greater). The "always-repaint suppresses frequent" ordering contract pinned as a negative control. `coveredStableIds = {'always_repaint_painter', 'frequent_repaint_painter'}`. |
| Keep Alive | `reproducerOnly` | [`keep_alive_reproducer_test.dart`](../test/validation/keep_alive_reproducer_test.dart) | Parameterised `excessive_keep_alive:<i>` family pinned on a PageView with `AutomaticKeepAliveClientMixin` pages, above `threshold` (strict-greater). Pages are visited via `PageController.jumpToPage` so `_isActiveKeepAlive` reads parent-data `true` — the stale `element.widget.keepAlive` path stays false otherwise. ListView suppression, `wantKeepAlive=false` silence, and at-threshold silence pinned as negative controls. Family-prefix convention pinned at the `:` separator. `coveredStableIds = {'excessive_keep_alive'}`. |
| AnimatedBuilder | `reproducerOnly` | [`animated_builder_reproducer_test.dart`](../test/validation/animated_builder_reproducer_test.dart) | `animated_builder_no_child` pinned on both `AnimatedBuilder` and `TweenAnimationBuilder` (`ImplicitlyAnimatedWidget` bypass of `isFrameworkOwned`), at the `subtreeSize > minSubtreeSize` boundary (strict-greater). The `child`-provided silence and no-AnimatedBuilder silence pinned as negative controls. `coveredStableIds = {'animated_builder_no_child'}`. |
| Opacity | `reproducerOnly` | [`opacity_reproducer_test.dart`](../test/validation/opacity_reproducer_test.dart) | Exact-zero contract pinned (0.0 fires, 0.005 and 0.5 do not), AnimatedOpacity settled-at-zero fires exactly once (inner FadeTransition suppressed by `_insideAnimatedOpacity` depth counter), **standalone `FadeTransition`** settled at 0.0 fires via the `_insideAnimatedOpacity == 0` guard (non-zero does not), and nested `Opacity(0.0)` produces one rollup issue with a count reflecting both occurrences. `coveredStableIds = {'opacity_zero'}`. |
| Font Loading | `reproducerOnly` | [`font_loading_reproducer_test.dart`](../test/validation/font_loading_reproducer_test.dart) | Both families pinned: `runtime_font_loading` (custom `fontFamily` + non-empty `fontFamilyFallback`, exercised on both Text and RichText paths) and `multiple_custom_fonts` (distinct-family count > `maxFamilies`, strict-greater). System-font suppression, no-fallback silence, and duplicate-family dedup pinned as negative controls. The detector's source comment claiming DefaultTextStyle inheritance is NOT covered is stale — Text materialises an internal RichText with the inherited style merged into its TextSpan, so the RichText branch in `checkElement` actually observes the inherited family; documented inline in the reproducer for a future source-comment cleanup. `coveredStableIds = {'runtime_font_loading', 'multiple_custom_fonts'}`. |
| RepaintBoundary | `reproducerOnly` | [`repaint_boundary_reproducer_test.dart`](../test/validation/repaint_boundary_reproducer_test.dart) | Both families pinned: `missing_repaint_boundary` (Opacity 0<x<1 and ClipPath without RepaintBoundary ancestor within `maxAncestorDepth`) and `excessive_repaint_boundary` (> 20-boundary hardcoded threshold in CustomScrollView with `addRepaintBoundaries: false`). Opacity 0.0 / 1.0 passthrough suppression and framework-managed ListView auto-boundary skip (-1 sentinel) pinned as negative controls. Fixtures use Opacity, not CustomPaint, to keep the missing-branch test cross-detector clean. `coveredStableIds = {'missing_repaint_boundary', 'excessive_repaint_boundary'}`. |
| Startup | `reproducerOnly` | [`startup_reproducer_test.dart`](../test/validation/startup_reproducer_test.dart) | `slow_startup_ttff` pinned via injected `StartupMetrics` through the `@visibleForTesting` `Sleuth.setStartupMetricsForTest` hook: ttffMs >= `ttffWarningMs` fires at warning severity, ttffMs >= `ttffCriticalMs` promotes to critical, ttffMs < warning threshold silent (strict-less), ttffMs null silent, no StartupMetrics at all silent, and the one-shot `_consumed` guard pinned by second-`prepareScan` no-op. Detector is `prepareScan`-only (element methods are no-ops). `coveredStableIds = {'slow_startup_ttff'}`. |

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
component lands; its dispatch site is trivially exercised
against an empty expected-components list today.

| Component | Tier | Reproducer | Notes |
|---|---|---|---|
| _(none yet)_ | — | — | First real registration expected in v0.16.7+ alongside an `IssueRanker` tier raise. |

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
  and reverted it: the `above` capture at 3117 ms
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
  Audit hardening landed and stays dormant until re-raise:
  backtick normalisation on the mechanism-4 prose-drift guard so
  exclusion phrases match regardless of inline-code nesting around
  identifier fragments; L2 negative assertion on
  `coveredThresholds.*.critical`; default-drift cross-check between
  `DetectorMetadata.bracketThreshold` and the detector's runtime
  default. The three capture files on disk are retained orphans under
  the manifest with `consumeBy: '0.16.7'`.
- **v0.16.6** — Two simultaneous tier raises in one PR.
  `FrameTimingDetector` raised `unvalidated` → `reproducerOnly` pinning
  4 stableIds (`sustained_jank`, `jank_detected`,
  `raster_cache_thrashing`, `raster_cache_growing`) via hermetic
  reproducer bypassing warmup (`warmupDuration: Duration.zero`) and
  exercising both synthetic `FrameStats` and real-pipeline
  `FrameTiming` paths per-stableId (anti-tautology, Tactic 9).
  Impeller-zero suppression pinned by a dedicated `pictureCacheBytes: 1`
  belt-and-suspender test. `ListviewDetector` `coveredStableIds`
  backfilled 3 → all 8 (added `non_lazy_gridview`,
  `non_lazy_sliver_list`, `non_lazy_sliver_grid`,
  `sliver_to_box_adapter_shrinkwrap`, `non_lazy_list`); Check-C gate
  pinned by a three-test triad covering the `isNonLazy` bypass.
  Retained-orphan manifest bumped `consumeBy: '0.16.6'` → `'0.16.7'`
  for all three `slow_request` capture files. Ledger distribution:
  6/23 `reproducerOnly`, 17/23 `unvalidated`.
- **v0.17.0** — FPS semantics rewrite. `FrameStatsBuffer` exposes
  `actualFps` (count-based rolling 1 s window anchored on
  `FrameTiming.rasterFinish`) alongside renamed `throughputFps`
  (latency-derived, v4 formula). `averageFps` retained as alias.
  `FrameStatsSummary` JSON bumped v4 → v5 additively; `FrameTiming`
  reproducer extended with 6 FPS-semantics tests. StableId coverage
  unchanged — FPS reporting is orthogonal to jank classification, so
  no tier change. Retained-orphan manifest bumped
  `consumeBy: '0.16.7'` → `'0.18.0'` for all three `slow_request`
  capture files (re-raise window extended with the minor bump). Ledger
  distribution unchanged: 6/23 `reproducerOnly`, 17/23 `unvalidated`.
- **v0.17.1** — Bulk structural batch. Nine detectors raised
  `unvalidated` → `reproducerOnly` in a single release:
  `LayoutBottleneckDetector`, `NestedScrollDetector`,
  `CustomPainterDetector`, `AnimatedBuilderDetector`,
  `KeepAliveDetector`, `FontLoadingDetector`,
  `RepaintBoundaryDetector`, `SetStateScopeDetector`, and
  `StartupDetector`. All nine are pure structural or one-shot scans
  (no VM-timeline dependency); hermetic reproducers under
  `test/validation/` cover the runtime trigger path end-to-end
  (anti-tautology, Tactic 9: real `pumpWidget` + `scanTree(root)` for
  structural detectors, injected `StartupMetrics` via the
  `@visibleForTesting` hook for Startup). Shared scan harness lives
  at `test/validation/_helpers/structural_reproducer_harness.dart`
  (plumbing only — detector-specific fixture construction stays
  inline so shared code does not re-encode detector assumptions).
  Parameterised anchor test pins the (type → reproducerPath →
  coveredStableIds) triple for all nine. `SetStateScopeDetector`
  covers the STRUCTURAL / possible-confidence path only — the
  DebugSnapshot confidence-upgrade path (likely / confirmed via
  rebuild-counter correlation) is a known gap documented in the
  detector rationale. Ledger distribution: **15/23
  `reproducerOnly`, 8/23 `unvalidated`**.
- **v0.17.2** — Bulk vmOnly + hybrid batch. Final 8 detectors raised
  `unvalidated` → `reproducerOnly`: `ShaderJankDetector`,
  `HeavyComputeDetector`, `PlatformChannelDetector`,
  `MemoryPressureDetector`, `GpuPressureDetector`, `RepaintDetector`,
  `RebuildDetector`, `ShallowRebuildRiskDetector`. Reproducers reuse
  existing `test/detectors/*_detector_test.dart` suites (fixtures
  synthetic, same-author provenance). **Pipeline gap**: vmOnly
  reproducers drive detector entrypoints directly; VM →
  `TimelineParser` → detector boundary not exercised. Format-level
  regressions at that hop pass audit silently. One narrowing shipped
  for both `RepaintDetector` and `RebuildDetector`: parametric
  underscore-separator families (`repaint_debug_<typeName>`,
  `rebuild_debug_<typeName>`) not declarable under audit's `:`
  prefix convention. Ledger distribution: **23/23 `reproducerOnly`,
  0/23 `unvalidated`** — detector-scope only (family-scope coverage
  not universal per disclosures above). **← current release**
- **v0.18.0+** — Re-raise `NetworkMonitorDetector.slow_request.warning`
  (hard deadline — orphan manifest `consumeBy: '0.18.0'` blocks the
  release unless re-raised or orphans deleted). Also drops the
  `FrameStatsBuffer.averageFps` alias — downstream consumers must
  migrate to `throughputFps` or `actualFps` explicitly.
  Prerequisites: (a) replace citation with a generic mobile/API HTTP
  latency source matching the detector semantics OR narrow the detector
  contract to user-blocking requests and enforce scope with a gate;
  (b) extend capture helper to emit a
  `sleuth.issue.slow_request.warning` trace/log record with the
  detector-measured duration; (c) extend
  `ProfileCaptureSchema.validateBracket` to require that record inside
  the scenario window. Remaining `unvalidated` detectors cluster around
  runtime/VM-driven thresholds (memory pressure, GPU pressure) where
  the next tier raise will typically also need a reference-device
  profile capture.

Follow-up work from v0.16.1:

- **Canonical issue-family identifiers** (still deferred; v0.16.6's
  multi-family raise scoped by bare stable ID, not parameterized
  `<family>:<hash>`, so the "prefix up to `:`" convention remained
  sufficient) — will replace the convention once a parameterized-ID
  family needs tier-scoped coverage.
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
