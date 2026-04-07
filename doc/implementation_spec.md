# Sleuth Implementation Spec

## Objective

Build `sleuth` into an honest in-app DevTools alternative with:

- a mobile-first Flutter performance workflow for Android and iOS apps
- strong default detectors that are actually trustworthy
- clear separation between measured runtime signals and heuristic guidance
- public messaging that matches what the code can prove
- a stable path for later advanced work on frame-correlated VM analysis

## Roadmap Structure

This document is organized in four layers:

- `Core Foundation`: the minimum work required to make the profiler framework technically honest, maintainable, and publishable
- `Advanced Profiling`: stronger attribution and deeper runtime analysis built on top of that foundation
- `Framework Expansion`: higher-value workflow and UX features that make the package more useful in day-to-day performance work
- `Precision & DX`: accuracy improvements, false positive reduction, new VM APIs, and developer experience overhaul for the overlay UI

This is not a "small v1" plan. It is a staged profiler-framework roadmap where the core layer exists to make the advanced layers trustworthy.

## Product Positioning

For v1, the package should be positioned as:

- VM-powered runtime diagnostics for Flutter mobile apps
- frame timing plus optional VM timeline plus widget-tree heuristics
- faster, more actionable in-app triage than DevTools for common issues

It should not claim:

- exact per-frame diagnosis
- exact offending widget detection
- leak tracking unless leak tracking is truly implemented

## Platform Capability Disclosure

This needs to be explicit in the README and package docs.

- Frame timing mode is the universal baseline and should be the primary story.
- Full VM mode is best-effort and platform-dependent.
- Android and iOS are the primary target platforms.
- Desktop is a secondary environment that may still be useful for development and validating full VM analysis behavior.
- Physical iOS devices are a good candidate for full VM analysis.
- Android full VM analysis may work on real devices depending on VM service connectivity, but should not be presented as universally reliable.
- Android emulator/device workflows should expect fallback behavior more often than desktop.

Acceptance criteria:

- The README states that frame timing mode is the primary cross-platform path.
- The README states that Android and iOS are the primary target platforms.
- The README explains that full VM mode is best-effort.
- No user-facing copy implies full VM mode is equally reliable on all platforms.

## Operational Guarantees

The profiler framework should define explicit expectations for:

- target-platform validation
- fallback and degradation behavior
- package self-overhead

### Mobile-first validation matrix

Required primary validation targets:

- Android real device
- Android emulator
- iOS real device

Secondary validation target:

- desktop, only as a secondary environment for development convenience and full-mode behavior validation

Required runtime modes:

- debug
- profile

For each target/mode combination, validation should record:

- whether the app boots with the package enabled
- whether the overlay works
- whether the `FrameTiming` path works
- whether VM full mode connects
- which detector groups are active:
  - frame/runtime
  - VM-backed
  - structural
  - debug instrumentation
- what UI warning/state is shown
- whether confidence or verdict behavior is degraded

Acceptance criteria:

- Release readiness is evaluated against a written validation matrix, not ad hoc spot checks. ✅
  Implemented as `doc/validation_matrix.md` with per-platform/mode grids, expected behavior
  reference, degradation verification checklist, detector coverage checklist, and sign-off template.
- Mobile targets are treated as the primary compatibility contract. ✅
  Android (device + emulator) and iOS grids are primary; desktop grid is secondary.

### Degradation contract

The product should define consistent fallback behavior when VM full mode is unavailable or partial.

Required rules:

- `FrameTiming` mode remains available whenever possible and is the baseline runtime path.
- VM-backed detectors must be disabled or downgraded when VM service connectivity is unavailable.
- The UI must explicitly state when the package is operating without full VM analysis.
- Confidence and verdict wording must degrade automatically when only partial signals are available.
- The package should prefer "limited analysis" over silent failure.

Acceptance criteria:

- Each detector group has a defined fallback behavior.
- Users can tell from the UI when the package is running in reduced-capability mode.
- No detector silently presents VM-strength claims when only fallback signals are available.

### Self-overhead constraints

The profiler framework must define constraints on its own overhead.

Required constraints:

- no extra tree walks when the overlay is off unless explicitly required by an enabled detector
- highlight collection remains conditional
- callback aggregation is bounded and allocation-light
- no unbounded buffers for events, issues, or histories
- debug instrumentation overhead must be measurable and documented

Future requirement:

- add a small benchmark or measurement workflow to validate package overhead over time ✅ Implemented as `test/benchmark/` suite: per-detector scan overhead (15 detectors × 1000 elements), full scan at 100/500/1000/3000 elements, linearity regression test, timeline processing benchmarks, memory/buffer bounds. All tests assert CI-friendly overhead budgets. 592→606+ tests.

Acceptance criteria:

- The package has explicit self-overhead rules in the spec.
- Instrumentation and analysis paths are bounded by design.
- Overhead-sensitive features are documented with their tradeoffs.

## Definition Of Confidence

- `Confirmed`: directly observed runtime condition or directly observable widget state.
- `Likely`: real runtime signal plus a plausible structural cause.
- `Possible`: structural or indirect heuristic only.

Confidence should describe evidence quality, not marketing certainty.

Confidence-to-copy rules:

- `Confirmed` may use wording like `observed`, `measured`, or `detected`.
- `Likely` may use wording like `likely caused by` or `likely related to`.
- `Possible` should use wording like `may be related to`, `possible`, or `heuristic`.
- Copy must not be stronger than the confidence level assigned to the issue.

---

## Spec File Index

The full spec is split by roadmap era. Each file is self-contained.

| File | Lines | Content | Status |
|------|-------|---------|--------|
| [spec_core_foundation.md](spec_core_foundation.md) | 365 | Milestones 1–7: README, memory, config, dedup, registry, confidence, verdict | All shipped |
| [spec_advanced_profiling.md](spec_advanced_profiling.md) | 203 | Frame correlation, debug instrumentation strategy | All shipped |
| [spec_v2.md](spec_v2.md) | 724 | Framework expansion + v2 roadmap (network, heap, CPU attribution, source location) | All shipped |
| [spec_v2_audit.md](spec_v2_audit.md) | 357 | v2 post-implementation audit (6 gaps, all resolved) | Complete |
| [spec_v3.md](spec_v3.md) | 440 | v3 roadmap: precision & developer experience (10 milestones) | All shipped |
| [spec_post_impl_notes.md](spec_post_impl_notes.md) | 891 | Post-implementation notes: v0.4.0, v3.x, v0.5.0, confidence audit, demo, v0.6.x | Complete |
| [spec_v4_v5.md](spec_v4_v5.md) | 1115 | v4 (extensibility & DX) + v5 (causal graph, thresholds, registry, network) | All shipped |
| [spec_v6.md](spec_v6.md) | 545 | v6: robustness, accuracy & polish (22 improvements) | All shipped |
| [spec_v7.md](spec_v7.md) | 260 | v7: performance & accuracy (10 milestones) | All shipped |
| [spec_v8.md](spec_v8.md) | 668 | v8: accuracy & correctness fixes (5 milestones) | All shipped |
| [spec_v9.md](spec_v9.md) | 1255 | **v9: accuracy, self-overhead & correctness (17 milestones)** | **All shipped** |
| [spec_v10.md](spec_v10.md) | 820 | **v10: performance, accuracy & enrichment (12 milestones)** | **All shipped** |
| [spec_v11.md](spec_v11.md) | 280 | **v11: detector audit — gaps, false positives & enrichment (12 milestones)** | **All shipped** |
| [spec_ui_features.md](spec_ui_features.md) | 180 | UI features: Issue Encyclopedia, AI Chat, IssueCard shimmer, overlay polish | All shipped |
