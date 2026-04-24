# Sleuth

Runtime performance diagnostics package for Flutter mobile apps. 23 detectors across 4 lifecycle types (runtime, vmOnly, hybrid, structural).

## Commands

```bash
# Always use fvm for all Flutter/Dart commands
fvm flutter test                    # Run all tests (~2,493 tests, ~30s)
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
- **Known audit gap — underscore-parametric families**: `checkReproducerFile` prefix match uses `:` only (`value == id || value.startsWith('$id:')`). StableIds using `_` as separator (`repaint_debug_<typeName>`, `rebuild_debug_<typeName>`) cannot be family-declared. Two detectors ship with documented narrowings. Future fix: extend matcher to support explicit family patterns beyond `:`.
- Test helpers live in `test/helpers/` — `benchmark_helpers.dart` and `timeline_test_helpers.dart`.

## Conventions

- New detectors: add enum value to `DetectorType`, create detector file in `detectors/`, implement `prepareScan`/`checkElement`/`afterElement`/`finalizeScan` (not `scanTree`), register in `SleuthController`, add tests mirroring existing detector test structure. Tests call `scanTree` (the base class wrapper) — no special test setup needed.
- Issues use `IssueConfidence`: confirmed (directly observed), likely (runtime + structural), possible (structural only).
- Fix hints use `FixHintBuilder` (in `utils/fix_hint_builder.dart`) — never hardcode fixHint strings in detectors.
- All public API goes through `lib/sleuth.dart` barrel file.
- Package is completely disabled in release mode (`kReleaseMode` guard).

## Current state

**v0.16.6** (current) — Two simultaneous tier raises in one PR. `FrameTimingDetector` raised `unvalidated` → `reproducerOnly` with 4 stableIds pinned (`sustained_jank`, `jank_detected`, `raster_cache_thrashing`, `raster_cache_growing`) via hermetic reproducer bypassing warmup (`warmupDuration: Duration.zero`) and exercising both synthetic `FrameStats` and real-pipeline `FrameTiming` paths per-stableId (anti-tautology, Tactic 9). Impeller-zero suppression pinned by `pictureCacheBytes: 1` belt-and-suspender test. `ListviewDetector` coveredStableIds backfilled 3 → all 8 (added `non_lazy_gridview`, `non_lazy_sliver_list`, `non_lazy_sliver_grid`, `sliver_to_box_adapter_shrinkwrap`, `non_lazy_list`); Check-C gate pinned by a three-test triad covering the isNonLazy bypass. Ledger distribution: `6/23 reproducerOnly, 17/23 unvalidated`.

**v0.16.5** — Second `externallyCited` raise on `NetworkMonitorDetector.slow_request.warning` staged and reverted. Detector stays at `reproducerOnly`. Audit hardening retained (mechanism-4 backtick-stripping matcher, default-drift cross-check, L2 `*.critical` negative assertion, retained-orphan manifest with `consumeBy: '0.16.7'` after v0.16.6 bumped the lifecycle).

**NetworkMonitor v0.16.N re-raise prerequisites** (unchanged from v0.16.5): (1) replace citation with a source matching detector semantics (or narrow contract); (2) extend capture helper to emit `sleuth.issue.slow_request.warning` trace record with detector-measured duration; (3) extend `ProfileCaptureSchema.validateBracket` to require that record inside scenario window.

For version history v0.16.4 and earlier see `CHANGELOG.md`. Spec docs in `doc/spec_v*.md`.
