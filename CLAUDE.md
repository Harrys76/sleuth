# Widget Watchdog

Runtime performance diagnostics package for Flutter mobile apps. 21 detectors across 4 lifecycle types (runtime, vmOnly, hybrid, structural).

## Commands

```bash
# Always use fvm for all Flutter/Dart commands
fvm flutter test                    # Run all tests (~1,121 tests, ~12s)
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
    ui/                         # Overlay widgets: FloatingIssuesCard, GuidePage, IssueCard, TriggerButton
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
- v0.6.0: Replaced DashboardSheet (bottom sheet, 1,241 lines) with FloatingIssuesCard (draggable floating card, ~830 lines). Removed FrameChart, tabs, filter chips. FPS now shown on TriggerButton. Guide is a full-screen GuidePage with staggered animations and 4 expandable sections. Card is resizable (width + height) via corner grip handle; double-tap header to maximize.
- v0.6.1: FPS counter fixes — throughput-based calculation with microsecond precision, startup timing fix (frames captured during VM connect), target-aware `fpsColor`, FPS capped at `fpsTarget` in UI, `exportSnapshot` reads live detector buffer.
- v3 roadmap: v3.1–v3.10 all shipped
- v4 roadmap: v4.1 issue suppression (shipped), v4.2 custom detector API (shipped), v4.4 card widget extraction (shipped), v4.5 example app extraction (shipped) — all complete (see `doc/implementation_spec.md`)
- v4.1: `suppressedIssues: Set<String>` on `WatchdogConfig` — filters by stableId pattern (exact or trailing `*` wildcard) post-correlate, pre-rank. `suppressedCountNotifier` for UI. `SessionSnapshot.suppressedCount` for export.
- v4.2: `customDetectors: List<BaseDetector>` on `WatchdogConfig` — plugin API for domain-specific detectors. Custom detectors extend `BaseDetector`, declare `DetectorLifecycle`, and integrate into all 7 controller lifecycle points (init, debug snapshot, structural scans, highlights, timeline data, issue aggregation, dispose). Always enabled regardless of `enabledDetectors`. Barrel file exports `BaseDetector`, `ParsedTimelineData`, `DebugSnapshot`.
- v4.4: Extracted 3 private widgets (`_StatusRow`, `_CardFooter`, `_WarningBanners`) from `_FloatingIssuesCardState` — reduced state class from 659 to 433 lines. Zero behavior change.
- v4.5: Extracted 18 demo screens from `example/lib/main.dart` (1,807 lines) into individual files under `example/lib/demos/`. `main.dart` reduced to 239 lines (app + router + route model).
- v5.1: Overlay theming — extracted ~150 hardcoded hex colors from 6 UI files into `WatchdogThemeData` (60 tokens). Dark defaults match every original value exactly. `WatchdogThemeData.light()` for light-background apps. Auto-brightness detection via `MediaQuery.platformBrightness`. `copyWith()` for custom overrides. `WatchdogTheme` InheritedWidget with dark fallback for test compatibility. Zero visual change for existing users.
- Post-implementation audits in `doc/implementation_spec.md` (search "Post-Implementation Notes")
- ~1,121 tests, 0 analysis issues
