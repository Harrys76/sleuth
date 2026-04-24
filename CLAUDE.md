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

**v0.17.4** (current) — Ledger distribution: **23/23 `reproducerOnly`, 0/23 `unvalidated`**. No detectors at `runtimeVerified` or `externallyCited`. Evidence NOT uniform across the 23 — three within-tier strata:
1. **Parser-boundary exercised** (4 detectors, v0.17.4 rewrite): ShaderJank, HeavyCompute, PlatformChannel, MemoryPressure. Reproducers at `test/validation/*_reproducer_test.dart` feed raw `List<TimelineEvent>` through `TimelineParser.parse()` into the detector.
2. **Real `pumpWidget` + `scanTree`** (13 structural detectors, v0.16.3 / v0.17.1 batches).
3. **Reused unit-test suites** (4 detectors still queued for rewrite): GpuPressure, Repaint, Rebuild, ShallowRebuildRisk. `reproducerPath` still points at `test/detectors/*_detector_test.dart` with synthetic `ParsedTimelineData` construction bypassing the parser boundary.

**v0.17.4** closed the parser-boundary gap for 4 of 8 v0.17.2-batch detectors. New shared harness `test/validation/_helpers/vm_reproducer_harness.dart` with parser-drop guard (`parseAndAssertShape`). MemoryPressure rationale discloses 3 skipped upstream hops (`VmServiceClient.getMemoryUsage` repack, `EventStreams.kGC` stream, `VmServiceClient._readRssBytes()` / `ProcessInfo.currentRss`). Anchor block `_v0172Expectations` → `_v0174Expectations`.

**v0.17.3** closed the audit methodology gap that forced v0.17.2 to ship two partial-coverage narrowings. Added `DetectorMetadata.parametricFamilies: Set<String>?` as peer namespace to `coveredStableIds` — matcher credits `<family>_<non-empty-suffix>` literals. `RepaintDetector` + `RebuildDetector` drop narrowings; all 3 underscore-parametric families (`repaint_debug`, `rebuild_debug`) declared + audit-tracked. Literal-provenance matcher hardened via 8-point structural provenance model (sticky-binding release, subtree-taint boundary, Rule-1 shadow detection, over-bound `fold`/`reduce` closure params). 12 regression fixtures.

**Next forward motion** — options are (a) continue the tier-quality audit with v0.17.5 (2 hybrid: GpuPressure, ShallowRebuildRisk) + v0.17.6 (2 structural: Repaint, Rebuild); OR (b) `reproducerOnly` → `runtimeVerified` raises: need checked-in profile-mode captures (timeline JSON / DevTools snapshot) showing claimed magnitude on reference device. NetworkMonitor has 3 capture files orphaned on disk (`consumeBy: '0.18.0'`) — lowest-friction candidate. Recommend (a) first for audit-trail coherence.

**NetworkMonitor re-raise prerequisites** (deferred to v0.18.0): (1) replace NN/g citation (rejected twice — UI direct-manipulation guideline, not generic HTTP latency threshold); (2) extend capture helper to emit `sleuth.issue.slow_request.warning` trace record with detector-measured duration; (3) extend `ProfileCaptureSchema.validateBracket` to require that record inside scenario window.

For version history v0.17.3 and earlier see `CHANGELOG.md`. Spec docs in `doc/spec_v*.md`.
