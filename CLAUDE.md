# Sleuth

Runtime performance diagnostics package for Flutter mobile apps. 23 detectors across 4 lifecycle types (runtime, vmOnly, hybrid, structural).

## Commands

```bash
# Always use fvm for all Flutter/Dart commands
fvm flutter test                    # Run all tests (~2,634 tests, ~30s)
fvm flutter test test/detectors/    # Run detector tests only
fvm flutter analyze                 # Static analysis (must be 0 issues)
fvm flutter pub publish --dry-run   # Verify publish readiness

# Example app
cd example && fvm flutter run --profile   # Profile mode (recommended)
cd example && fvm flutter run             # Debug mode
cd example && fvm flutter test            # Cookbook smoke tests (9 tests)
```

## Architecture

```
lib/
  sleuth.dart          # Public API barrel file + Sleuth entry point
  src/
    models/                     # Data classes: PerformanceIssue, FrameStats, FrameVerdict, BaseDetector
    detectors/                  # 23 detector implementations (one file per detector)
    network/                    # HTTP monitoring: SleuthHttpOverrides, RequestRecord
    analyzer/                   # RenderPipelineAnalyzer, FrameEventCorrelator
    controller/                 # SleuthController (orchestrates detectors, config, scan loop)
    vm/                         # VmServiceClient, TimelineParser
    debug/                      # DebugInstrumentationCoordinator, DebugSnapshot
    ranking/                    # IssueRanker (weighted composite scoring)
    ui/                         # Overlay widgets: FloatingIssuesCard, IssueCard, AiChatPage, IssueEncyclopediaPage, TriggerButton, SleuthTheme
    utils/                      # WidgetLocation helper, FixHintBuilder, TypeNameCache
    validation/                 # EvidenceTier, DetectorMetadata, ComponentMetadata, ProfileCaptureSchema
test/
    mirrors lib/src/ structure + helpers/ and benchmark/
    validation/                 # Per-detector reproducers, audit invariants, capture schema tests
```

### Key patterns

- **Detectors** extend `BaseDetector` (in `models/base_detector.dart`). Each has a `DetectorType` enum value and `DetectorLifecycle` (runtime, vmOnly, hybrid, structural). Built-in detectors implement 4 lifecycle methods (`prepareScan`, `checkElement`, `afterElement`, `finalizeScan`) for the unified tree walk. Custom detectors override `scanTree` directly.
- **SleuthController** owns all detectors, runs the scan loop (unified single-pass tree walk for all 16 tree-scanning detectors), and manages the `FrameVerdict` pipeline.
- **Three-tier verdict**: Correlated (VM timeline matched per-frame) > Full (VM batch) > Basic (FrameTiming only). Falls back automatically.
- **Evidence tier ledger**: every built-in detector carries `DetectorMetadata` declaring its `EvidenceTier` (`unvalidated` / `reproducerOnly` / `runtimeVerified` / `externallyCited`). Raises require a hermetic reproducer + audit-gate entries. Ledger: `doc/validation_ledger.md`.
- **Reproducer path convention**: `reproducerPath` points at `test/validation/<d>_reproducer_test.dart` (purpose-written, v0.16.3 / v0.17.1) or `test/detectors/<d>_detector_test.dart` (reused unit tests, v0.17.2). Both pass `isPathInsideRepo`. Pick whichever fits the detector's test shape.
- **Family declaration**: `coveredStableIds` for bare/colon-parametric families (`excessive_keep_alive:<i>`); `parametricFamilies` (since v0.17.3) for underscore-parametric (`repaint_debug_<typeName>`). Matcher requires non-empty suffix after `_`.
- Test helpers live in `test/helpers/` — `benchmark_helpers.dart` and `timeline_test_helpers.dart`.

## Conventions

- New detectors: add enum value to `DetectorType`, create detector file in `detectors/`, implement `prepareScan`/`checkElement`/`afterElement`/`finalizeScan` (not `scanTree`), register in `SleuthController`, add tests mirroring existing detector test structure. Tests call `scanTree` (the base class wrapper) — no special test setup needed.
- Issues use `IssueConfidence`: confirmed (directly observed), likely (runtime + structural), possible (structural only).
- Fix hints use `FixHintBuilder` (in `utils/fix_hint_builder.dart`) — never hardcode fixHint strings in detectors.
- All public API goes through `lib/sleuth.dart` barrel file.
- Package is completely disabled in release mode (`kReleaseMode` guard).

## Current state

**v0.18.0** (current) — Ledger distribution: **22/23 `reproducerOnly`, 1/23 `runtimeVerified`, 0/23 `unvalidated`**. `NetworkMonitorDetector.slow_request` (warning tier, 1000 ms threshold) is the first runtimeVerified raise — three on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.x) recorded via the new in-app capture procedure (markScenarioBegin/End + Sleuth.exportCaptureJson + iOS clipboard). Phase A capture infrastructure shipped: scenario markers, exportCaptureJson, retainTimeline gate, schemaVersion v1, severity-scoped trace records, above>at invariant, severity-boundary cross-check. v0.18.1 must land `Sleuth.flushTimelineNow()` before any other vmOnly detector raises (HeavyCompute, ShaderJank, MemoryPressure, GpuPressure, PlatformChannel) — they hit the polling-cadence emission-timing constraint NetworkMonitor sidesteps via runtime lifecycle + 200 ms dwell. See `doc/capture_procedure.md` + `doc/validation_ledger.md`.

**v0.17.6** — Ledger distribution: **23/23 `reproducerOnly`, 0/23 `unvalidated`**. No detectors at `runtimeVerified` or `externallyCited`. Tier-quality audit COMPLETE — evidence ships in two within-tier strata (the third "reused unit-test suites" stratum is now empty):
1. **Parser-boundary exercised** (8 detectors): v0.17.4 ShaderJank, HeavyCompute, PlatformChannel, MemoryPressure (vmOnly batch); v0.17.5 GpuPressure, ShallowRebuildRisk (hybrid batch); v0.17.6 Repaint, Rebuild (final hybrid batch — all paths exercised in one file via cross-harness composition).
2. **Real `pumpWidget` + `scanTree`** (13 structural detectors, v0.16.3 / v0.17.1 batches).

Note: Stratum 1 covers the 8 v0.17.2-batch detectors that originally pointed at `test/detectors/*_detector_test.dart` reused unit tests. Stratum 2 (13 structural) detectors still legitimately use real `pumpWidget` for their primary path; they are NOT a regression — the structural lifecycle has no parser boundary to exercise.

**v0.17.6** closed the parser-boundary gap for the final 2 hybrid detectors (Repaint + Rebuild). Repaint reproducer pins all 3 emission paths plus broad **Gate B animation-owned suppression** via `expect(issues, isEmpty)` (regression cannot leak through any of VM aggregate, per-widget, or aggregate-debug). Rebuild reproducer pins **builder-widget 3× threshold multiplier** with two pieces of evidence — full builder triad on `StreamBuilder` (29/30/91) AND paired non-builder/builder fixture at identical rate=25 (`MyWidget` fires at `> 10`, `StreamBuilder` suppressed at `< 30`). **Source-mode `RebuildCountSource.flutterTimeline`** per-type suppression pinned (KDD-5 inflations) with default-source negative control. Both detectors pin reconnect-flush behaviour (cold-init `vmConnected=false → true` stages `_pendingVmWindowCount=0`) and `_maxHighlightsPerType=3` cap (5 instances → 3 highlights). Single-call window-staging pattern: advance fake clock by 1100 ms BEFORE `processTimelineData` so the call closes the window atomically.

**v0.17.5** closed the parser-boundary gap for 2 hybrid detectors (GpuPressure + ShallowRebuildRisk). Cross-harness composition pattern: hybrid reproducers import both `vm_reproducer_harness.dart` (for `parseAndAssertShape`) and `structural_reproducer_harness.dart` (for `scanAndIssues`). VM state survives across `scanAndIssues` because `prepareScan` only clears per-scan accumulators, not VM-window state. ShallowRebuildRisk reproducer pins all 3 gate states including the silent `vmConnected=true && buildCount ≤ 20` no-fire branch + DebugSnapshot upgrade in BOTH duplicated `_evaluate` branches (VM-backed + structural-fallback). GpuPressure reproducer pins RenderOpacity opacity-value short-circuit + BackdropFilter sigma 3-band (highlight severity escalates critical at >10.0; `expensive_gpu_nodes` issue severity stays `warning`) + confidence correlation matrix (4 sub-cases including raster-present-but-non-dominant). Detector rationales enumerate 4 RenderObject checks + 1 widget-level (`ColorFiltered`) check explicitly.

**v0.17.4** closed the parser-boundary gap for 4 of 8 v0.17.2-batch detectors. New shared harness `test/validation/_helpers/vm_reproducer_harness.dart` with parser-drop guard (`parseAndAssertShape`). MemoryPressure rationale discloses 3 skipped upstream hops (`VmServiceClient.getMemoryUsage` repack, `EventStreams.kGC` stream, `VmServiceClient._readRssBytes()` / `ProcessInfo.currentRss`). Anchor block `_v0172Expectations` → `_v0174Expectations`.

**v0.17.3** closed the audit methodology gap that forced v0.17.2 to ship two partial-coverage narrowings. Added `DetectorMetadata.parametricFamilies: Set<String>?` as peer namespace to `coveredStableIds` — matcher credits `<family>_<non-empty-suffix>` literals. `RepaintDetector` + `RebuildDetector` drop narrowings; all 3 underscore-parametric families (`repaint_debug`, `rebuild_debug`) declared + audit-tracked. Literal-provenance matcher hardened via 8-point structural provenance model (sticky-binding release, subtree-taint boundary, Rule-1 shadow detection, over-bound `fold`/`reduce` closure params). 12 regression fixtures.

**Next forward motion** — `reproducerOnly` → `runtimeVerified` raises. Need checked-in profile-mode captures (timeline JSON / DevTools snapshot) showing claimed magnitude on reference device. NetworkMonitor has 3 capture files orphaned on disk (`consumeBy: '0.18.0'`) — lowest-friction candidate but blocked on (a) replacing NN/g citation, (b) extending capture helper to emit `sleuth.issue.slow_request.warning` trace record, (c) extending `ProfileCaptureSchema.validateBracket` to require it. Other candidates: any of the 6 Stratum-1 vmOnly/hybrid detectors with deterministic timeline footprint (HeavyCompute and ShaderJank are simplest — single-stableId, single-axis thresholds).

**NetworkMonitor re-raise prerequisites** (deferred to v0.18.0): (1) replace NN/g citation (rejected twice — UI direct-manipulation guideline, not generic HTTP latency threshold); (2) extend capture helper to emit `sleuth.issue.slow_request.warning` trace record with detector-measured duration; (3) extend `ProfileCaptureSchema.validateBracket` to require that record inside scenario window.

For version history v0.17.4 and earlier see `CHANGELOG.md`. Spec docs in `doc/spec_v*.md`.
