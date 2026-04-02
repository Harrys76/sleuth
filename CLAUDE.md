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

- **v0.9.0** (current) — unified structural tree walk (v7.9), all v7 milestones shipped. See CHANGELOG.md for full details.
- v0.8.2: Ring buffers (v7.7), correlator sort cache (v7.8), VM reconnect polling fix (v7.10).
- v0.8.1: Accuracy fixes — HeavyCompute two-tier (v7.1), NetworkMonitor threshold (v7.2), threshold tuning (v7.3), correlator coverage (v7.4), rebuild VM fallback (v7.5), MemoryPressure warmup (v7.6).
- v0.8.0: v6 roadmap complete (22 milestones: safety, accuracy, UI polish, testing).
- v0.7.0: v4 + v5 roadmap — suppression, custom detectors, theming, export enrichment, causal graph, configurable thresholds, detector registry, network correlation, RepaintBoundary detector.
- v0.6.1: FPS counter fixes — throughput-based calculation, startup timing, target-aware color.
- v0.6.0: FloatingIssuesCard replaces DashboardSheet, resizable card, GuidePage.
- v0.5.0: Context-aware fix hints, verdict linking, UX improvements.
- v0.4.0: Accuracy fixes + correlator optimization.
- v3 roadmap: v3.1–v3.10 all shipped.
- v7 roadmap: 10/10 milestones shipped ✅ — accuracy fixes (v7.1–v7.6), performance optimizations (v7.7–v7.8, v7.10), unified tree walk (v7.9). See `doc/implementation_spec.md`.
- v8 roadmap: 5 milestones (from Codex adversarial review) — SetState O(N^2) fix, Scaffold scan-root fallback, HTTP monitor leak, platform channel classification, SetState wording. See `doc/implementation_spec.md`.
- Post-implementation audits in `doc/implementation_spec.md` (search "Post-Implementation Notes")
- 1,310 tests, 0 analysis issues
