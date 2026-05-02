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

**v0.19.13** (current) — `HeavyComputeDetector.heavy_compute.critical` raised to **runtimeVerified** via `additionalBrackets`. First tier-stack raise (warning + critical brackets on one family). Critical: threshold 16 ms, atTolerance 0.60 (at-band [16, 25.6]), aboveCeilingMultiplier 1.875 (ceiling 30 ms). Both brackets stamp BUILD ms into `extraTraceArgs.observedDurationMs` and declare `observedAxisArgKey: 'observedDurationMs'` so the audit gate cross-checks operator-Stopwatch against detector-measured value. `checkAdditionalBrackets` cross-spec uniqueness tuple now `(stableId, severityLabel, argKey)` so tier-stack raises don't false-collide. 6 on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.x) — both triads re-recorded under the new arg. Capture screen: tier-mode dropdown + `_legSpec` resolver retunes target ms + scenario + file name per tier; `exportCaptureJson` receives `bracketStableId`/`bracketSeverityLabel` for clipboard-time validation; `dispose()` closes orphan scenarios; `SafeArea` wraps log. Anchor: 13 pins covering both brackets. Reproducer: 7 critical-band cases through 30001µs (no super-tier); schema-edge test pins the 25.6/25.601 seam. `fvm flutter analyze` clean.

**Distribution (current)**: 20/23 reproducerOnly base, 8/23 effective runtimeVerified families (slow_request, large_response, request_frequency, heap_growing, platform_channel_traffic, jank_detected, rebuild_activity; HeavyCompute now at runtimeVerified for both warning + critical via additionalBrackets).

### Recent releases (one-line)

- **v0.19.12** — `RebuildDetector.rebuild_activity.warning` raised to runtimeVerified; baseline subtraction (`setBaseline(int)` + `peakObservedRebuildRate`); per-leg inline baseline + `_Pulse` const-child widget.
- **v0.19.11** — `RebuildDetector` capture-pipeline plumbing (lastObservedRebuildRate, resetCaptureState VM-window clear, dedupIdentityMicros + extraTraceArgs); RebuildActivityCaptureScreen demo.
- **v0.19.10** — NetworkMonitor capture hardening; `lastObservedPeakCount` + `flushFrequencyEvaluation()`; `bracketStableId`/`bracketSeverityLabel` in `exportCaptureJson`.
- **v0.19.9** — `additionalBrackets` schema; `large_response.warning` + `request_frequency.warning` runtimeVerified raises.
- **v0.19.8** — `BracketSpec` const class + `additionalBrackets` field; per-spec audit (capture paths, coveredThresholds, cross-spec uniqueness).
- **v0.19.7** — `FrameTimingDetector.jank_detected.warning` raised to runtimeVerified (percent axis, `observedAxisReduction: 'last'`).
- **v0.19.6** — Capture-mode plumbing for FrameTiming; `observedAxisReduction` schema field; `'percent'` approved unit.
- **v0.19.5** — TimelineParser B/E reconstruction extended to LAYOUT/PAINT/raster (Impeller compatibility); `Sleuth.diagnoseCaptureState()`.
- **v0.19.4** — `PlatformChannelDetector.platform_channel_traffic.warning` raised; cooldown semantics suppress duplicate fires.
- **v0.19.3** — `MemoryPressureDetector.heap_growing.warning` raised; `Sleuth.suspendNonEssentialTimelineStreams()`/`resumeAllTimelineStreams()`.
- **v0.19.2** — Cursor sweep + `.gitattributes` for capture fixtures.
- **v0.19.1** — `cursorsByTid` per-tid composite cursor (capture-mode dedup); `_sessionGeneration` reconnect guard.
- **v0.19.0** — **BREAKING**: `sleuthMetadata.role` required; cross-batch BUILD B/E reconstruction; audit gate routes off `effectiveMaxTier`.
- **v0.18.2** — `HeavyComputeDetector.heavy_compute.warning` raised (first vmOnly).
- **v0.18.1** — `Sleuth.flushTimelineNow()`; producer-side dedup; `requireUniqueDetectedAtMicros` opt-in.
- **v0.18.0** — `NetworkMonitorDetector.slow_request.warning` first runtimeVerified raise; capture infrastructure (markScenarioBegin/End, exportCaptureJson, schemaVersion v1).

For full release notes see `CHANGELOG.md`. Spec docs in `doc/spec_v*.md`.
