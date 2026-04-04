# Widget Watchdog

Runtime performance diagnostics package for Flutter mobile apps. 22 detectors across 4 lifecycle types (runtime, vmOnly, hybrid, structural).

## Commands

```bash
# Always use fvm for all Flutter/Dart commands
fvm flutter test                    # Run all tests (~1,310 tests, ~16s)
fvm flutter test test/detectors/    # Run detector tests only
fvm flutter analyze                 # Static analysis (must be 0 issues)
fvm flutter pub publish --dry-run   # Verify publish readiness

# Example app
cd example && fvm flutter run --profile   # Profile mode (recommended)
cd example && fvm flutter run             # Debug mode
```

## Architecture

```
lib/
  widget_watchdog.dart          # Public API barrel file + WidgetWatchdog entry point
  src/
    models/                     # Data classes: PerformanceIssue, FrameStats, FrameVerdict, BaseDetector
    detectors/                  # 22 detector implementations (one file per detector)
    network/                    # HTTP monitoring: WatchdogHttpOverrides, RequestRecord
    analyzer/                   # RenderPipelineAnalyzer, FrameEventCorrelator
    controller/                 # WatchdogController (orchestrates detectors, config, scan loop)
    vm/                         # VmServiceClient, TimelineParser
    debug/                      # DebugInstrumentationCoordinator, DebugSnapshot
    ranking/                    # IssueRanker (weighted composite scoring)
    ui/                         # Overlay widgets: FloatingIssuesCard, GuidePage, IssueCard, TriggerButton
    utils/                      # WidgetLocation helper, FixHintBuilder
test/
    mirrors lib/src/ structure + helpers/ and benchmark/
```

### Key patterns

- **Detectors** extend `BaseDetector` (in `models/base_detector.dart`). Each has a `DetectorType` enum value and `DetectorLifecycle` (runtime, vmOnly, hybrid, structural). Built-in detectors implement 4 lifecycle methods (`prepareScan`, `checkElement`, `afterElement`, `finalizeScan`) for the unified tree walk. Custom detectors override `scanTree` directly.
- **WatchdogController** owns all detectors, runs the scan loop (unified single-pass tree walk for all 16 tree-scanning detectors), and manages the `FrameVerdict` pipeline.
- **Three-tier verdict**: Correlated (VM timeline matched per-frame) > Full (VM batch) > Basic (FrameTiming only). Falls back automatically.
- Test helpers live in `test/helpers/` — `benchmark_helpers.dart` and `timeline_test_helpers.dart`.

## Conventions

- New detectors: add enum value to `DetectorType`, create detector file in `detectors/`, implement `prepareScan`/`checkElement`/`afterElement`/`finalizeScan` (not `scanTree`), register in `WatchdogController`, add tests mirroring existing detector test structure. Tests call `scanTree` (the base class wrapper) — no special test setup needed.
- Issues use `IssueConfidence`: confirmed (directly observed), likely (runtime + structural), possible (structural only).
- Fix hints use `FixHintBuilder` (in `utils/fix_hint_builder.dart`) — never hardcode fixHint strings in detectors.
- All public API goes through `lib/widget_watchdog.dart` barrel file.
- Package is completely disabled in release mode (`kReleaseMode` guard).

## Current state

- **v0.9.1** (current) — v8 accuracy/correctness/performance fixes: SetState O(N²) fix (v8.1), scaffold scan-root fallback for Cupertino/scaffold-free apps (v8.2), HTTP monitor leak (v8.3), platform channel false positives (v8.4), SetState wording (v8.5). See CHANGELOG.md.
- v0.9.0: Unified structural tree walk (v7.9), all v7 milestones shipped.
- v0.8.2: Ring buffers (v7.7), correlator sort cache (v7.8), VM reconnect polling fix (v7.10).
- v0.8.1: Accuracy fixes — HeavyCompute two-tier (v7.1), NetworkMonitor threshold (v7.2), threshold tuning (v7.3), correlator coverage (v7.4), rebuild VM fallback (v7.5), MemoryPressure warmup (v7.6).
- v0.8.0: v6 roadmap complete (22 milestones: safety, accuracy, UI polish, testing).
- v0.7.0: v4 + v5 roadmap — suppression, custom detectors, theming, export enrichment, causal graph, configurable thresholds, detector registry, network correlation, RepaintBoundary detector.
- v7 roadmap: 10/10 milestones shipped ✅. See `doc/spec_v7.md`.
- v8 roadmap: 5/5 milestones shipped ✅ (v8.1–v8.5). See `doc/spec_v8.md`.
- v9 roadmap: 4/17 milestones shipped (v9.2, v9.3, v9.5, v9.7). See `doc/spec_v9.md`.
- Post-implementation audits in `doc/spec_v2_audit.md` and `doc/spec_post_impl_notes.md`.
- Full spec index in `doc/implementation_spec.md`.
- 1,351 tests, 0 analysis issues
