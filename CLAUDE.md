# Sleuth

Runtime performance diagnostics package for Flutter mobile apps. 23 detectors across 4 lifecycle types (runtime, vmOnly, hybrid, structural).

## Commands

```bash
# Always use fvm for all Flutter/Dart commands
fvm flutter test                    # Run all tests (~1,993 tests, ~18s)
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
test/
    mirrors lib/src/ structure + helpers/ and benchmark/
```

### Key patterns

- **Detectors** extend `BaseDetector` (in `models/base_detector.dart`). Each has a `DetectorType` enum value and `DetectorLifecycle` (runtime, vmOnly, hybrid, structural). Built-in detectors implement 4 lifecycle methods (`prepareScan`, `checkElement`, `afterElement`, `finalizeScan`) for the unified tree walk. Custom detectors override `scanTree` directly.
- **SleuthController** owns all detectors, runs the scan loop (unified single-pass tree walk for all 16 tree-scanning detectors), and manages the `FrameVerdict` pipeline.
- **Three-tier verdict**: Correlated (VM timeline matched per-frame) > Full (VM batch) > Basic (FrameTiming only). Falls back automatically.
- Test helpers live in `test/helpers/` — `benchmark_helpers.dart` and `timeline_test_helpers.dart`.

## Conventions

- New detectors: add enum value to `DetectorType`, create detector file in `detectors/`, implement `prepareScan`/`checkElement`/`afterElement`/`finalizeScan` (not `scanTree`), register in `SleuthController`, add tests mirroring existing detector test structure. Tests call `scanTree` (the base class wrapper) — no special test setup needed.
- Issues use `IssueConfidence`: confirmed (directly observed), likely (runtime + structural), possible (structural only).
- Fix hints use `FixHintBuilder` (in `utils/fix_hint_builder.dart`) — never hardcode fixHint strings in detectors.
- All public API goes through `lib/sleuth.dart` barrel file.
- Package is completely disabled in release mode (`kReleaseMode` guard).

## Current state

- **v0.13.0** (current) — Startup Performance Tracing: `Sleuth.init()` + `Sleuth.markInteractive()` for TTFF/TTI measurement, new `StartupDetector` (23rd detector, structural lifecycle, one-shot), `slow_startup_ttff` issue type, `StartupMetrics` model with per-phase FrameTiming breakdown and VM sub-phase enrichment slots, `IssueCategory.startup` across all UI/export surfaces, startup metrics banner in overlay, encyclopedia entry (47 total), markdown export section. Three adversarial reviews + full 23-detector accuracy audit. Fixes: clock-domain mismatch (monotonic→wall-clock TTFF), stableId prefix mapping, causal graph layout_bottleneck visibility (8 incorrect downstream rules removed, 52→44 rules), ShaderJankDetector Impeller notice removed (noisy false positive), stateful_density framework widget noise, shallow_rebuild_risk ScrollNotificationObserver suppression, NetworkMonitorDetector route-based clearing (replaces time-based staleness eviction). Test count: 1,915 → 1,993.
- v0.12.2: Post-Codex adversarial review hardening: timeline pipeline exception isolation (`_onTimelineData` try/finally + per-detector try/catch), encyclopedia placeholder leak fix (substitute all entries with fallback sentinel), cookbook slow-frame detector staleness fix (time-based eviction via `_TimestampedFrame`). One adversarial review, 3 findings fixed. See `CHANGELOG.md`.
- v0.12.1: Pillar 6 Part 2: Overlay UI, Diagnostics Output & Export. New: trigger button alignment config (`triggerButtonAlignment`/`triggerButtonOffset`), minimize/maximize/restore card controls (3-state window), recurrence badge on IssueCard, context-aware encyclopedia entries (`IssueExplanationBuilder.substitute()`), inline confidence reasoning, dismissible debug-mode banner, `Sleuth.exportSummary()` markdown export, "Copy conversation" button on AiChatPage. Adversarial review fixes: Tooltip→Semantics in overlay (OverlayPortal crash), GFM escaping in copy/export, recurrence badge overflow, semantic labels on interactive elements, cookbook detector false-positive filter. See `doc/spec_v11.md`.
- v0.12.0: Pillar 6 Part 1: Public API & Authoring Surface + real-device VM connection fix. **Breaking**: `SleuthConfig.treeScanInterval` now takes `Duration` instead of `int` ms. New: `SleuthConfig.minimal()`/`.performance()` presets, threshold doc comments on every parameter, debug-mode assert validation (14 rules), `SimpleStructuralDetector` helper base class, custom detector key gating (`disabledCustomDetectorKeys`), three-file custom detector cookbook in example app. VM fix: `controlWebServer` replaces `getInfo()` for cold-start port bind, background reconnect ladder (500ms→30s), `_connectInFlight` concurrency guard, frameStatsNotifier 5Hz throttle (prevents self-feedback rebuild loop), per-detector exception isolation in unified walk, post-dispose continuation guards. One adversarial review, 4 findings fixed (exception isolation, post-dispose guards, diag print removal, throttle test coverage). Test count: 1,825 → 1,869.
- Test count: 1,869 → 1,915 (root) + 7 → 9 (example).
- v0.11.1: Pillar 5 Part 2 demo quality enhancements: Before/After toggle in `DemoScaffold`, working fixed-pattern bodies for all 23 demos, live `MetricsBar`/`MetricChip` in 7 demos, two new combined demos (E-Commerce, Chat). Three adversarial review rounds, 18 findings + KeepAliveDetector bug fix. See `doc/spec_v11.md`.
- v0.11.0: Pillar 5 Part 1 demo infrastructure: DemoScaffold shared layout, 5 new demos (shader jank, platform channel traffic, memory pressure, GPU pressure, missing RepaintBoundary), categorized home screen (8 categories, 23 demos). Two adversarial reviews: (round 1) memory MB overcount fix, theme-aware color fix; (round 2) critical GC rate dilution fix (10s sliding window replaces lifetime-based denominator in `MemoryPressureDetector`), setState-after-dispose guards + global `debugProfilePlatformChannels` save/restore in platform channel demo, memory label clarification, RepaintBoundary description accuracy, Impeller warning banner on shader jank page. See `doc/spec_v11.md`.
- v0.10.9: Pillar 4 issue documentation quality: 8 missing encyclopedia entries (38→46 total), readingTheData for all 46 entries, build/memory/paint/raster/network content enrichment (14 entries), relatedIssues cross-references with bidirectional links derived from causal graph, related issues UI chips with scroll-to, AI context integration, content quality guardrail tests. Adversarial review: chip scroll-to bug fix (per-entry GlobalKey map), repaint_debug bidirectional relations, content threshold enrichments. See `doc/spec_v11.md`.
- v0.10.8: Pillar 3b output & presentation: confidenceReason field on all 22 detectors, severity auto-escalation (warning→critical after 30 cycles), 2 new correlator rules (structural+jank, structural+rebuild), multi-ancestor source locations, packageName extraction, session summary export (topIssues/causalEdges/frameHistogram/detectorHitRates/memoryTrendSummary), schema v3. Adversarial reviews: 3 missing stableId prefix mappings (Pillar 3b); scan chain exception safety, stable duplicate-request IDs, POST duplicate exclusion, GlobalKey route-change guard, sliver correlator coverage (full branch). See `doc/spec_v11.md`.
- v0.10.7: Pillar 3a enrichment: Expanded causal rules (37→52), RecurrenceTrend ring-buffer time-series, InteractionContext typing+appLifecycle, WidgetHeatMapEntry aggregation, FixBaseline/FixVerificationResult with 5-cycle cooldown. Adversarial review: framework filter expansion, grace period counter reset. See `doc/spec_v11.md`.
- v0.10.6: Pillar 2b resource management: Adaptive scan frequency (M4), _getAllIssues generation cache (M5), detector lazy initialization (M6), debug callback TypeNameCache (M7). Adversarial review: timer leak fix, parallel timer chain guard, concurrent detector mutation guard. See `doc/spec_v11.md`.
- v0.10.5: Pillar 2a hot-path performance: TypeNameCache (M1), highlight dirty-check (M2), timeline case-matching (M3). Reduces tree walk allocations by ~40-60%.
- v0.10.4: v11.19: Sliver anti-pattern detection in ListviewDetector (SliverToBoxAdapter large subtrees, SliverFillRemaining misuse, shrinkWrap inside slivers). See `doc/spec_v11.md`.
- v0.10.3: v11 detector audit Part 3 (6 milestones: duplicate request detection, GlobalKey recreation, subtree cost enrichment, thread attribution, warmup/builder suppression). See `doc/spec_v11.md`.
- v0.10.0: Issue Encyclopedia, contextual AI Chat, IssueCard shimmer Ask AI link, responsive action links, MediaQuery optimization, overlay UI polish. See CHANGELOG.md.
- v0.9.2: v9 accuracy/self-overhead/correctness: 17 milestones — opacity value semantics, paint phase classification, inner subtree walk elimination, highlight overlay GPU optimization, generation-counter shouldRepaint, and more.
- v0.9.1: v8 accuracy/correctness/performance fixes: SetState O(N²) fix (v8.1), scaffold scan-root fallback for Cupertino/scaffold-free apps (v8.2), HTTP monitor leak (v8.3), platform channel false positives (v8.4), SetState wording (v8.5).
- v0.9.0: Unified structural tree walk (v7.9), all v7 milestones shipped.
- v0.8.2: Ring buffers (v7.7), correlator sort cache (v7.8), VM reconnect polling fix (v7.10).
- v0.8.1: Accuracy fixes — HeavyCompute two-tier (v7.1), NetworkMonitor threshold (v7.2), threshold tuning (v7.3), correlator coverage (v7.4), rebuild VM fallback (v7.5), MemoryPressure warmup (v7.6).
- v0.8.0: v6 roadmap complete (22 milestones: safety, accuracy, UI polish, testing).
- v0.7.0: v4 + v5 roadmap — suppression, custom detectors, theming, export enrichment, causal graph, configurable thresholds, detector registry, network correlation, RepaintBoundary detector.
- v7 roadmap: 10/10 milestones shipped ✅. See `doc/spec_v7.md`.
- v8 roadmap: 5/5 milestones shipped ✅ (v8.1–v8.5). See `doc/spec_v8.md`.
- v10 roadmap: 12/12 milestones shipped ✅ (v10.1–v10.12). See `doc/spec_v10.md`.
- v9 roadmap: 17/17 milestones shipped ✅ (v9.1–v9.17). See `doc/spec_v9.md`.
- Post-implementation audits in `doc/spec_v2_audit.md` and `doc/spec_post_impl_notes.md`.
- Full spec index in `doc/implementation_spec.md`.
- v11 roadmap: 19/19 milestones shipped ✅ (v11.1–v11.19, four adversarial reviews). See `doc/spec_v11.md`.
- v11 Pillar 4: 10/10 milestones shipped ✅ (v11.20–v11.29, one adversarial review). See `doc/spec_v11.md`.
- v11 Pillar 5 Part 1: 7/7 milestones shipped ✅ (M1–M7, two adversarial reviews). See `doc/spec_v11.md`.
- v11 Pillar 5 Part 2: 7/7 milestones shipped ✅ (M8–M14, three adversarial review rounds + KeepAliveDetector bug fix). See `doc/spec_v11.md`.
- v11 Pillar 6 Part 1: 7/7 milestones shipped ✅ (M1–M7, one adversarial review). See `doc/spec_v11.md`.
- v11 Pillar 6 Part 2: 8/8 milestones shipped ✅ (M1–M8, one adversarial review round + 6 fixes). See `doc/spec_v11.md`.
- 1,993 tests (root) + 9 tests (example), 0 analysis issues
