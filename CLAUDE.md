# Sleuth

Runtime performance diagnostics package for Flutter mobile apps. 20 detectors across 4 lifecycle types (runtime, vmOnly, hybrid, structural).

## Commands

```bash
# Always use fvm for all Flutter/Dart commands
fvm flutter test                    # Run all tests (~2,881 tests, ~30s)
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
    detectors/                  # 20 detector implementations (one file per detector)
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
- **SleuthController** owns all detectors, runs the scan loop (unified single-pass tree walk for all 12 tree-scanning detectors), and manages the `FrameVerdict` pipeline.
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

**v0.29.1** (current) — `IssueEncyclopediaPage` "Learn more" now resolves parametric / dynamic-suffix stableIds (`tracked_resource_concurrent:<name>`, `excessive_keep_alive:<i>`, `repaint_debug_<typeName>`, etc.) to the bare-family encyclopedia entry. New public `IssueExplanationBuilder.canonicalId(String)`; encyclopedia uses it for the scroll-target containsKey check, scroll, and row highlight.

**v0.29.0** — `tracked_resource_concurrent.warning` raised to runtimeVerified via `perStableIdTier`. Bracket threshold 6, atTolerance 0.5 (at-band [6, 9]), aboveCeilingMultiplier 3.0 (ceiling 18), `observedAxisArgKey: 'liveInstanceCount'`, `requireUniqueDetectedAtMicros: true`. New `PerformanceIssue.captureTraceStableId` routes parametric `tracked_resource_concurrent:<name>` emissions through the bare family for byte-exact bracket matching; UI `stableId` + equality unchanged. Detector ships `flushConcurrentEvaluation()`, `untrackAll(name)`, `resetCaptureState()`, per-name `lastObservedLiveCountFor(name)` / `peakObservedLiveCountFor(name)` getters (aggregate getters retained for back-compat; capture screens must use per-name). Long-lived family stays reproducerOnly — 300 s threshold exceeds scenario window; long-lived emissions deliberately omit `captureTraceStableId`.

**v0.28.0** — New `Sleuth.setResourceThreshold(name, {maxConcurrent, longLivedSeconds})` per-name override for `TrackedResourceDetector`. Merge semantics — omitted/invalid axis preserves prior; explicit both-null clears. Override stored in separate map → survives empty-bucket sweep, LRU eviction, and `isEnabled=false` toggle; `dispose()` clears. Issue `extraTraceArgs` always stamps `effectiveMaxConcurrent`/`effectiveLongLivedSeconds` + `thresholdSource` (`override`/`global`). Non-positive + cap-overflow silently drop via `droppedOverridesCount` (runtime guard). Pre-init calls warn once-per-session.

**v0.27.0** — New `TrackedResourceDetector` (runtime, opt-in). `Sleuth.trackResource(name, resource)` / `Sleuth.untrackResource(name, resource)` API. Two stableIds, both `confirmed`: `tracked_resource_concurrent:<name>.warning` (>5 live instances same name) + `tracked_resource_long_lived:<name>.warning` (single instance alive past 5 min). Pure Dart — `WeakReference` + Finalizer token-keyed bookkeeping; cross-isolate calls no-op. LRU cap (default 1000) bounds in-memory bucket map; eviction detaches per-ref Finalizer entries. Causal edges `tracked_resource_{concurrent,long_lived}:* → heap_growing`. Tier `reproducerOnly`. 19 → 20 detectors.

**v0.26.0** — `stream_resource_growth.warning` raised to runtimeVerified (iPhone 12 / iOS 17.5 / Flutter 3.41.4 capture triad; threshold 50 instances on `topGrowthDelta` axis, atTolerance 0.6, aboveCeilingMultiplier 3.0). Detector gate switched from summed `netDelta` to single-class `top.delta`. `MemoryPressureDetector.gcRateThresholdPerMin` default 30 → 60.

**v0.25.0** (BREAKING) — Multi-parent causal UI + removal of `rootCauseId` singular. `IssueCard.parentIssues` + `_causedBySection` widget (cap 5, "(+N suppressed)" annotation). `computeVisibleIssues`: ≥2 parents always visible; 1 parent collapses or surfaces orphan; 0 parents visible. BREAKING: singular `rootCauseId` field, JSON key, `fromJson` read, `effectiveRootCauseIds` getter — all removed. v0.24.x-only snapshots must re-export through v0.24.2 before import. `rootCauseIds` invariant: null or non-empty (fromJson coerces empty → null).

**v0.24.2** — Multi-parent causal-graph annotation (data model layer). `CausalGraphRule.apply()` writes `rootCauseIds: List<String>?` plural; every reaching root claims each downstream. `toJson` dual-emitted singular for v0.24.1-reader back-compat (removed v0.25.0).

**v0.24.1** — Cross-detector polish for `stream_resource_growth`. 3 new `CausalGraphRule` edges (`stream_resource_growth → heap_growing` / `heap_near_capacity` / `gc_pressure`). Markdown export (`activeEdges`) lists every parallel cause→effect pair; UI annotation in v0.24.1 was single-owner (severity-then-index); v0.24.2 lifts the UI to multi-parent. Schema regression guard for the 4 detector-side extraTraceArgs keys.

**v0.24.0** — New `StreamResourceDetector` (vmOnly): retained async-resource flag via `getAllocationProfile` class-instance diff over K=4 window, gated on recent `MemoryPressureDetector.heap_growing`. New `MemoryPressureDetector.isHeapGrowingActive([windowMicros])`. New `Sleuth.streamResourceDetector` accessor. 18 → 19 detectors.

**v0.23.0** — `GpuPressureDetector.raster_dominance` idle false-positive fixed (MAX-of-frame numerator + `maxFrameRasterFloorUs` gate). `HeavyComputeDetector` emissions persist via monotonic Stopwatch (`emissionPersistence`, default 10s). New `PerformanceIssue.sourceRoute`: persisted issues stamp route at emission; aggregator prefers `sourceRoute` over live route. Wired through heavy_compute + platform_channel via `sourceRouteProvider`. CSV Import demo capped at 500K.

**v0.22.0** — `sustained_jank.critical` raise withdrawn; bracket axis (sliding 240-frame-window severeCount) non-composable with operator-claimed K. Captures + capture screen + retainedOrphans entries removed. Reproducer-tier coverage retained.

**v0.21.0** — `RepaintDetector.excessive_repaint.warning` raised to runtimeVerified via `perStableIdTier` on three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures (32-distinct-`CustomPaint` workload routes emission through VM aggregate path). Adds `peakObservedPaintCount` + `flushPaintEvaluation()` + `resetCaptureState()` plumbing + `Sleuth.repaintDetector` / `Sleuth.lastCaptureExportFailure` static accessors.

**v0.20.2** — Example-app polish: tile subtitles trimmed to ≤40 chars; heavy_compute description drops hard "300 ms" claim; network_stress search uses `Uri.replace(queryParameters)` (RFC 3986 encoding).

**v0.20.1** — `FrameTimingDetector` + `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` per emission via `DetectorThresholds.startupPhaseWindowSeconds` (default 5).

**v0.20.0** — BREAKING: 5 low-value detectors removed (`animatedBuilder`, `opacity`, `shallowRebuildRisk`, `nestedScroll`, `globalKey`); 23 → 18 detectors.

**Distribution (current)**: 18/20 reproducerOnly base + 2/20 runtimeVerified base, 14 effective runtimeVerified family-severity pairs across 11 unique stableIds (slow_request {warning + critical}, large_response.warning, request_frequency.warning, heap_growing.warning, platform_channel_traffic.warning, jank_detected.warning, rebuild_activity {warning + critical}, heavy_compute {warning + critical}, excessive_repaint.warning, stream_resource_growth.warning, tracked_resource_concurrent.warning). `tracked_resource_long_lived` family stays reproducerOnly — its 300 s threshold is too long for an on-device capture scenario window.

### Recent releases (one-line)

- **v0.29.1** — `IssueEncyclopediaPage` learn-more now resolves parametric / dynamic-suffix stableIds via new `IssueExplanationBuilder.canonicalId(String)` helper. Fixes silent no-scroll for `tracked_resource_concurrent:<name>`, `excessive_keep_alive:<i>`, `repaint_debug_<typeName>`, etc.
- **v0.29.0** — `tracked_resource_concurrent.warning` runtimeVerified via `perStableIdTier` (threshold 6, atTolerance 0.5, aboveCeilingMultiplier 3.0; iPhone 12 capture triad). `PerformanceIssue.captureTraceStableId` routes parametric → bare family. Detector ships `flushConcurrentEvaluation()`, `untrackAll(name)`, `resetCaptureState()`, per-name peak/last getters.
- **v0.28.0** — `Sleuth.setResourceThreshold(name, ...)` per-name override. Merge semantics; bucket-independent; survives `isEnabled` toggle. Always stamps `extraTraceArgs.effective{MaxConcurrent,LongLivedSeconds}/thresholdSource`.
- **v0.27.0** — New `TrackedResourceDetector` (runtime, opt-in) + `Sleuth.trackResource` / `Sleuth.untrackResource` API. WeakRef + token-keyed Finalizer; two `confirmed` parametric stableIds. Causal edges to `heap_growing`. 19 → 20 detectors.
- **v0.26.0** — `stream_resource_growth.warning` runtimeVerified (iPhone 12 capture triad). Detector gate switched to single-class `top.delta` so firing axis matches bracket axis. `gcRateThresholdPerMin` 30 → 60. `'instances'` unit added.
- **v0.22.0** — `sustained_jank.critical` raise withdrawn (bracket axis non-composable with operator-claimed K). Captures + capture screen + retainedOrphans entries removed; reproducer-tier coverage retained.
- **v0.21.0** — `RepaintDetector.excessive_repaint.warning` raised to runtimeVerified via `perStableIdTier` (32-distinct-`CustomPaint` workload routes through VM aggregate path). `Sleuth.repaintDetector` + `Sleuth.lastCaptureExportFailure` static accessors; `peakObservedPaintCount` + `flushPaintEvaluation()` + `resetCaptureState()` plumbing.
- **v0.20.2** — Example-app polish: tile subtitles ≤40 chars; heavy_compute description drops hard "300 ms" claim; network_stress search uses `Uri.replace(queryParameters)` (RFC 3986).
- **v0.20.1** — `FrameTimingDetector` + `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` per emission via `DetectorThresholds.startupPhaseWindowSeconds` (default 5).
- **v0.20.0** — BREAKING: 5 low-value detectors removed (`animatedBuilder`, `opacity`, `shallowRebuildRisk`, `nestedScroll`, `globalKey`); 23 → 18 detectors.
- **v0.19.27** — Test polish on top of v0.19.26: `Sleuth.track()` auto-init regression test + `delta == 0` cold_start inclusive-boundary pin. No detector or distribution change.
- **v0.19.26** — `ShaderJankDetector` emits `extraTraceArgs.shaderWarmupContext` ('cold_start' | 'hot_path' | 'keyframe') via `Sleuth.dartEntryMonotonicUs` + `ParsedTimelineData.phaseEvents` build-event correlation; new `DetectorThresholds.coldStartShaderWindowSeconds` (default 5) + `shaderKeyframeWindowMs` (default 100); tier unchanged (reproducerOnly).
- **v0.19.25** — Test + doc polish. cwd guard extended to the `checkCapturePathPerDirectoryNamingUniformity` group (5 tests); validation-tier docs (README + ledger) refreshed and summary count corrected to 21/23 reproducerOnly + 2/23 runtimeVerified base.
- **v0.19.24** — Behavioral wiring test for `checkMinInBandSamplesPerSpec` (replaces source-grep); explicit cwd guard on `critical_above.json` real-capture test; ledger stale `← current release` marker removed.
- **v0.19.23** — `BracketSpec.minInBandSamples` opt-in + `checkMinInBandSamplesPerSpec` invariant (per-leg in-band sample count); `rebuild_activity.critical` opts in at 2.
- **v0.19.22** — `critical_above.json` re-recorded with `targetRebuildRate: 70` (was 65); two in-band emissions [65, 70] redundant against single-spike loss.
- **v0.19.21** — `RebuildDetector.rebuild_activity.critical` raised to runtimeVerified via `additionalBrackets[0]` (threshold 31, atTolerance 0.65, aboveCeilingMultiplier 2.7); 3 on-device captures + capture-screen tier dropdown; cross-leg `_persistentRewriteError` flag on memory + platform screens.
- **v0.19.20** — Capture-screen retry-budget short-circuit (memory + platform); `MemoryPressureDetector.gc_pressure` emission stamps `observedGcEvents` + `dedupIdentityMicros` from `_gcOverageStart`.
- **v0.19.19** — Capture re-record on iPhone 12 / iOS 17.5 / Flutter 3.41.4 (`heap_growing` + `platform_channel_traffic`, both `legacyObservedAxisAllowlist` entries consumed); `checkDetectorAxisInRoleBand` invariant; capture-screen post-process so `expectedMagnitude.observed` = detector slope/count; axis-fidelity full coverage.
- **v0.19.18** — `MemoryPressureDetector.heap_growing` `observedSlopeBytesPerSec` plumbing + `checkCapturesCarryObservedAxisArg` capture-fidelity invariant + typed `LegacyObservedAxisEntry` allowlist with `consumeBy` deadline.
- **v0.19.17** — `FrameTimingDetector.sustained_jank` emission stamps (observedSevereCount/observedJankPercent/bufferSize + `_emissionSeq` dedupIdentityMicros); attempted `sustained_jank.critical` raise withdrawn (axis non-composability); audit gains `checkRuntimeVerifiedRequiresObservedAxisArgKey`.
- **v0.19.16** — Audit + schema polish: `_validateScenarioMatchesPath` routes through `package:path`; tightened bounds `atTolerance ∈ [0, 0.65]` and `aboveCeilingMultiplier ∈ (1, 3]`; `path` promoted to `dependencies`.
- **v0.19.15** — Audit invariant hardening: `checkCanonicalCoveredThresholdBacking` (every dotted entry in canonical `coveredThresholds` must be backed by a matching `(stableId, severityLabel)`), `checkBracketBoundsSanity` (numeric guards on tolerance/reduction fields), `checkCapturePathPerDirectoryNamingUniformity` (per-directory capture-name shape pin); `ProfileCaptureSchema.parseFile` cross-checks `metadata.scenario` against file basename.
- **v0.19.14** — `NetworkMonitorDetector.slow_request.critical` raised to runtimeVerified via `additionalBrackets[2]`; second tier-stack raise; both brackets stamp `observedDurationMs` and tighten `observedAxisTolerance` to 0.10; `_endScenarioOnce` helper makes capture-screen scenario closing idempotent.
- **v0.19.13** — `HeavyComputeDetector.heavy_compute.critical` raised to runtimeVerified via `additionalBrackets`; first tier-stack raise; both brackets stamp `observedDurationMs` for cross-check; `checkAdditionalBrackets` uniqueness tuple bumped to `(stableId, severityLabel, argKey)`.
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

For full release notes see `CHANGELOG.md`.
