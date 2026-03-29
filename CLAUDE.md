# Widget Watchdog

Runtime performance diagnostics package for Flutter mobile apps. 21 detectors across 4 lifecycle types (runtime, vmOnly, hybrid, structural).

## Commands

```bash
# Always use fvm for all Flutter/Dart commands
fvm flutter test                    # Run all tests (~974 tests, ~10s)
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
    detectors/                  # 21 detector implementations (one file per detector)
    network/                    # HTTP monitoring: WatchdogHttpOverrides, RequestRecord
    analyzer/                   # RenderPipelineAnalyzer, FrameEventCorrelator
    controller/                 # WatchdogController (orchestrates detectors, config, scan loop)
    vm/                         # VmServiceClient, TimelineParser
    debug/                      # DebugInstrumentationCoordinator, DebugSnapshot
    ranking/                    # IssueRanker (weighted composite scoring)
    ui/                         # Overlay widgets: dashboard, chart, issue cards, trigger button
    utils/                      # WidgetLocation helper, FixHintBuilder
test/
    mirrors lib/src/ structure + helpers/ and benchmark/
```

### Key patterns

- **Detectors** extend `BaseDetector` (in `models/base_detector.dart`). Each has a `DetectorType` enum value and `DetectorLifecycle` (runtime, vmOnly, hybrid, structural).
- **WatchdogController** owns all detectors, runs the scan loop, and manages the `FrameVerdict` pipeline.
- **Three-tier verdict**: Correlated (VM timeline matched per-frame) > Full (VM batch) > Basic (FrameTiming only). Falls back automatically.
- Test helpers live in `test/helpers/` — `benchmark_helpers.dart` and `timeline_test_helpers.dart`.

## Conventions

- New detectors: add enum value to `DetectorType`, create detector file in `detectors/`, register in `WatchdogController`, add tests mirroring existing detector test structure.
- Issues use `IssueConfidence`: confirmed (directly observed), likely (runtime + structural), possible (structural only).
- Fix hints use `FixHintBuilder` (in `utils/fix_hint_builder.dart`) — never hardcode fixHint strings in detectors.
- All public API goes through `lib/widget_watchdog.dart` barrel file.
- Package is completely disabled in release mode (`kReleaseMode` guard).

## Current state

- v0.5.0 tagged (v0.4.0: accuracy fixes + correlator optimization; v0.5.0: context-aware hints, verdict linking, UX improvements)
- v3 roadmap: v3.1–v3.3, v3.8, v3.9 shipped. Remaining: v3.4, v3.5, v3.6, v3.7, v3.10 (see `doc/implementation_spec.md`)
- Post-implementation audits in `doc/implementation_spec.md` (search "Post-Implementation Notes")
- ~974 tests, 0 analysis issues
