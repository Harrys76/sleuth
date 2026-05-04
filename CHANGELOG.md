## 0.20.1

`FrameTimingDetector` and `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` on each emission. README + dartdoc gain a "Measurement window" note: Sleuth reports frame total duration from `FrameTiming` (build-to-raster span), not vsync delivery cadence.

- New `DetectorThresholds.startupPhaseWindowSeconds` (default 5). Classification reads `Timeline.now` at emission time — emission-time semantics, not event-time. A startup-phase frame whose callback delivery is delayed past the window boundary tags `'steady'`. Differs from `ShaderJankDetector.shaderWarmupContext` (per-event timestamp); the two tags are related but not aligned at the boundary.
- Buffer-aggregated emissions (`sustained_jank` 60-frame, `rebuild_activity` 1-second, raster-cache 30+ frames) tag from emission-time `Timeline.now`. A buffer straddling the boundary tags `'steady'` once `Timeline.now` exceeds the threshold.
- Null `Sleuth.dartEntryMonotonicUs` (init not called) or negative delta omits the key rather than fabricating a value.
- `rebuild_activity` runtimeVerified bracket axis (`observedRebuildRate`) co-exists with the new key. Audit-gate `validateBracket` reads named keys directly; multi-key emissions remain extractable.
- The tag is observable in capture-mode trace records and audit-gate replay; not serialized into saved JSON snapshots.
- Both detectors expose `appStartMonotonicUsForTest` constructor parameter for deterministic tests.

2,862 unit + integration tests passing; `fvm flutter analyze` clean. No detector logic, public API, or schema-version change.

## 0.20.0

**BREAKING**: 5 low-value detectors removed. Distribution: 23 → 18 detectors.

### Removed

- `DetectorType.animatedBuilder` — subset of `rebuild_detector` (AnimatedBuilder misuse manifests as rebuild storms; covered upstream).
- `DetectorType.opacity` — symptom-of-symptom (`Opacity` → `saveLayer` → jank already caught by `frame_timing.jank_detected`).
- `DetectorType.shallowRebuildRisk` — predictive heuristic; real signal caught by `rebuild_detector` from VM-timeline evidence.
- `DetectorType.nestedScroll` — Flutter's own `Vertical viewport was given unbounded height` diagnostic is more authoritative.
- `DetectorType.globalKey` — correctness lint, not perf; framework throws on duplicate `GlobalKey`.

Orphaned config fields removed: `SleuthConfig.maxGlobalKeys`, `DetectorThresholds.shallowRebuildMaxDepth`, `DetectorThresholds.animatedBuilderMinSubtreeSize`.

### Migration

Drop the 5 removed `DetectorType` references from `enabledDetectors`. `rebuild_detector` + `frame_timing` still surface AnimatedBuilder, opacity-jank, and rebuild-storm patterns from runtime evidence.

```dart
// BEFORE (v0.19.x):
SleuthConfig(enabledDetectors: {
  DetectorType.opacity, DetectorType.rebuild, DetectorType.frameTiming,
});

// AFTER (v0.20.0):
SleuthConfig(enabledDetectors: {
  DetectorType.rebuild, DetectorType.frameTiming,
});
```

v0.19 snapshots remain readable in v0.20 — serialization is `stableId`-keyed; encyclopedia + causal-graph rules retain removed-stableId entries for replay context. Users pinned at `^0.19.x` will not auto-upgrade.

### Distribution

16/18 reproducerOnly base + 2/18 runtimeVerified base. 11 effective runtimeVerified family-severity pairs across 8 unique stableIds (unchanged — none of the 5 removed carried raises).

2,851 unit + integration tests passing; `fvm flutter analyze` clean. Benchmark thresholds in `test/benchmark/` are machine-load-sensitive and may flake on slower hardware.

## 0.19.27

Test polish on top of v0.19.26. No detector logic change; tier distribution unchanged.

- `test/sleuth_test.dart`: new `Sleuth.track auto-init` group. Two-stage assertion (pre-call `isNull` after `Sleuth.resetStartupForTest`, post-call `isNotNull`) directly fails when `init()` is removed from `Sleuth.track()`. Mounted via `tester.pumpWidget` so SleuthOverlay disposal clears the static `_controller` at teardown.
- `test/validation/shader_jank_reproducer_test.dart`: new `delta == 0 inclusive boundary` test in the `shaderWarmupContext attribution` group. Pins the inclusive lower bound of the cold_start guard `deltaUs >= 0 && deltaUs < window`. Companion to the existing negative-delta `hot_path` test — together they pin both sides of `>= 0`.

3,007 unit + integration tests passing; `fvm flutter analyze` clean. Benchmarks in `test/benchmark/` use machine-load-sensitive timing thresholds and may flake on slower hardware.

## 0.19.26

`ShaderJankDetector` emits `extraTraceArgs.shaderWarmupContext` discriminating shader-compile origin. No tier change; ShaderJank stays `reproducerOnly`.

- New emission key `'shaderWarmupContext'` with values `'cold_start' | 'hot_path' | 'keyframe'`. Cold_start: shader compile within `coldStartShaderWindowSeconds` (default 5) of `Sleuth.dartEntryMonotonicUs`, gated on non-negative delta so VM ring-buffer replay of pre-init events does not trivially classify as cold_start. Keyframe: build event preceding shader compile within `shaderKeyframeWindowMs` (default 100) — one-sided causal window. Hot_path: fallback when neither matches. Cold_start takes precedence over keyframe.
- `Sleuth.track()` now calls `Sleuth.init()` at entry (idempotent via existing `_initCalled` guard) so the documented quick-start `runApp(Sleuth.track(child: MyApp()))` captures `dartEntryMonotonicUs`. Without this, the cold_start branch silently no-ops on the primary integration path.
- `Sleuth.dartEntryMonotonicUs` public getter exposes the existing `_dartEntryMonotonicUs` static. Same monotonic clock as `PhaseEvent.timestampUs`, so detectors can compare timeline-event timestamps against app-start without normalization.
- `DetectorThresholds.coldStartShaderWindowSeconds` (default 5) + `DetectorThresholds.shaderKeyframeWindowMs` (default 100) added with `>= 1` asserts and dartdoc covering raise/lower guidance.
- Detector iterates `data.phaseEvents.where(shader)` instead of `data.shaderCompileDurations` for per-event timestamps. Impeller-zero suppression preserved (empty-poll counter checks the filtered phaseEvents list). `shaderCompileData` test helper populates `phaseEvents` alongside `shaderCompileDurations` so existing unit-test fixtures still drive the detector.
- 5 new reproducer tests pin attribution outcomes: cold_start within window, hot_path past window, keyframe with 50ms-before build event, hot_path with 200ms-before build event (keyframe-window negative control), hot_path on negative delta (pre-init shader event). Mockable app-start clock via `appStartMonotonicUsForTest` constructor parameter.

3,005 tests passing. `fvm flutter analyze` clean.

## 0.19.25

Test + doc polish. No detector changes; tier distribution unchanged.

- cwd guard added to 5 tests in the `checkCapturePathPerDirectoryNamingUniformity` group of `audit_invariants_test.dart` — each skips with `markTestSkipped('CWD is not the package root; skipping.')` when run from a non-package-root directory instead of failing with a cryptic `FileSystemException` on the relative-path read inside `writeCapture`. Matches the v0.19.24 pattern.
- `README.md` + `doc/validation_ledger.md` refreshed: summary count corrected to **21 / 23 reproducerOnly base + 2 / 23 runtimeVerified base** (was misreported as 20 / 3 — recounted against `EvidenceTier` in `lib/src/detectors/`); Roadmap section flagged as historical narrative through v0.16.6 with pointer to `CHANGELOG.md`; "How to contribute a tier raise" rewritten to cover both `reproducerOnly` and `runtimeVerified` raise paths; obsolete v0.16.x present-tense framing and a fulfilled v0.18.0+ "hard deadline" bullet rewritten to past-tense shipped state.

3,000 tests passing. `fvm flutter analyze` clean.

## 0.19.24

Test polish. No detector changes; distribution unchanged.

- `runRuntimeTierAudit wires checkMinInBandSamplesPerSpec end-to-end`: source-grep wiring smoke test replaced with behavioral test that constructs synthetic `DetectorMetadata` (1 in-band per leg vs `minInBandSamples: 2`), invokes `runRuntimeTierAudit`, and asserts the failure list contains `minInBandSamples=2`. Indirection-proof — helper extraction or conditional gating breaks the new test, while the prior source-grep would silently accept either.
- `real-capture fixture: critical_above.json passes invariant`: explicit `pubspec.yaml` existence check replaces the implicit `Directory.current` assumption, mirroring the `markTestSkipped('CWD is not the package root; skipping.')` pattern used elsewhere in the file.

3,000 tests passing. `fvm flutter analyze` clean.

## 0.19.23

`BracketSpec.minInBandSamples` opt-in schema field + `checkMinInBandSamplesPerSpec` audit invariant. No detector raises; distribution unchanged.

- `BracketSpec.minInBandSamples` (default null = no enforcement). When non-null, each leg's capture (at + above) must contain ≥N in-span detector samples whose `extraTraceArgs.<observedAxisArgKey>` value lies in the leg's role band. Per-leg semantics, not summed across legs. Below-leg exempt.
- `checkMinInBandSamplesPerSpec` invariant wired into `runRuntimeTierAudit`. Scoped to `additionalBrackets` (top-level extension lands when needed). `checkBracketBoundsSanity` rejects `minInBandSamples < 1` when non-null.
- `RebuildDetector.rebuild_activity.critical` (`additionalBrackets[0]`) opts into `minInBandSamples: 2`. Single in-band peak captures with N sub-band emissions no longer certify the bracket band; re-records must sustain ≥2 in-band detector samples per leg.
- 13 new tests pin null-default opt-in, count thresholds, per-leg semantics, cross-role membership, integer boundaries, real-capture fixture, missing-file silent skip, tier gating, and a comment-stripping source-grep that fails fast if the wiring is removed.

3,000 tests passing. `fvm flutter analyze` clean.

## 0.19.22

`critical_above.json` re-recorded with redundant in-band emissions. No detector raises; distribution unchanged.

- `RebuildActivityCaptureScreen._criticalLegs.above.targetRebuildRate`: 65 → 70. Headroom under above-ceiling 83 widens enough that thermal throttling on a 6 s sustained leg leaves multiple in-band emissions instead of a single peak spike.
- `test/validation/captures/rebuild_detector/critical_above.json` re-recorded (iPhone 12 / iOS 17.5 / Flutter 3.41.4 profile mode). Critical events now [65, 43, 70, 44, 43] vs prior [72, 43, 43, 42, 42]: two in-band peaks instead of one. Max-reduction picks 70 ∈ (51, 83]; either in-band event could drop without invalidating the audit-gate cross-check.

2,987 tests passing. `fvm flutter analyze` clean.

## 0.19.21

`RebuildDetector.rebuild_activity.critical` raised to runtimeVerified. Cross-leg short-circuit on memory + platform capture screens. Distribution: 10 → 11 family-severity pairs.

- `RebuildDetector.validationMetadata.additionalBrackets[0]`: `BracketSpec` for `rebuild_activity.critical` (threshold 31, atTolerance 0.65, aboveCeilingMultiplier 2.7, `observedAxisArgKey: 'observedRebuildRate'`, `observedAxisReduction: 'max'`). At-band [31, 51], above-band (51, 83]. `coveredThresholds` extends to include `rebuild_activity.critical`.
- 3 on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.4 profile mode) at `test/validation/captures/rebuild_detector/critical_{below,at,above}.json` — observed rates 28 / 40 / 72 BUILDs/sec under baseline subtraction.
- `RebuildActivityCaptureScreen` gains a tier dropdown (warning / critical). Tier drives scenario name, capture-file basename, and `bracketSeverityLabel` parameter; switching tiers clears stashed capture state so an operator cannot export a warning capture tagged under the critical bracket. Mid-leg tier switch blocked at fire time.
- `MemoryPressureCaptureScreen` + `PlatformChannelCaptureScreen`: top-level `_persistentRewriteError` flag. Once any leg's catch-block sees a persistent post-process `rewriteError`, every subsequent leg short-circuits at `_runLeg` entry. Restart-screen is the only recovery path (clear-log does not reset — `_replaceExpectedObserved` shape compatibility must be re-proven).
- 6 new `rebuild_activity.critical` reproducer tests pin axis stamping + severity boundary + at-band/above-band/above-ceiling integer boundaries.
- New `capture_screen_audit_test.dart`: source-grep audit asserts the `_persistentRewriteError` field, setter, and entry guard are present in both screens. Cheap regression net for capture-screen code with no widget-test coverage.

2,987 tests passing. `fvm flutter analyze` clean.

## 0.19.20

Capture-screen retry-budget short-circuit + `gc_pressure` overage-window stamping. No detector raises; distribution unchanged.

- `MemoryPressureCaptureScreen` + `PlatformChannelCaptureScreen`: persistent `_replaceExpectedObserved` `rewriteError` now exhausts the per-leg retry budget so identical failures stop looping; log instructs restart.
- `MemoryPressureDetector.gc_pressure` emission stamps `extraTraceArgs.observedGcEvents` (10 s sliding-window count) + `dedupIdentityMicros` from a new `_gcOverageStart` pin. Same-overage emissions collapse to one trace event per episode (cuts ambient noise from N events to 1 in unrelated captures).
- `_gcOverageStart` clears in `resetCaptureState` / `reset` / `dispose` and on the no-emit else-branch (`windowEvents <= 5`) so distinct overages get distinct identities.
- 3 new reproducer tests pin axis stamping + same/distinct-overage identity (the distinct-identity test mutation-kills if the else-branch clear is removed).

2,979 tests passing. `fvm flutter analyze` clean.

## 0.19.19

Closes the schema two-axis gap: bracket-band claim is now enforced against the detector-stamped axis value, with full per-event coverage. **No detector raises**; distribution unchanged.

- Captures re-recorded on iPhone 12 / iOS 17.5 / Flutter 3.41.4: `heap_growing_{below,at,above}.json` carry `observedSlopeBytesPerSec`; `platform_channel_traffic_{below,at,above}.json` carry `observedCount`. Both v0.19.18 `legacyObservedAxisAllowlist` entries consumed.
- Capture screens (`MemoryPressureCaptureScreen`, `PlatformChannelCaptureScreen`) post-process the wrapped JSON to rewrite `expectedMagnitude.observed` to the detector-stamped slope/count. Schema bracket-band check, per-record cross-check, and `checkDetectorAxisInRoleBand` then reduce to the same authoritative number.
- New audit invariant `checkDetectorAxisInRoleBand` (`test/validation/_support/audit_invariants.dart`) asserts the reduced detector value lies in the role's bracket band — disjoint at the at/above boundary (above-leg detector value must strictly exceed `threshold × (1 + atTolerance)`) so role assignment is unambiguous from the detector alone.
- Full-coverage enforcement: `checkCapturesCarryObservedAxisArg` fails when `carrying < matched`; `checkDetectorAxisInRoleBand` independently fails when `samples.length < matchCount`. A producer regression on one emission path cannot ride on a stamped sibling.
- `last` reduction tied-ts pinned via insertion-order secondary sort key in `_checkIssueTraceRecordPresent` and `checkDetectorAxisInRoleBand` — last-inserted wins, no dependency on `List.sort` stability.
- `ProfileCaptureSchema.findScenarioSpan` made public; `checkDetectorAxisInRoleBand` reuses it so both checks share strict exactly-one-pair marker enforcement.
- `MemoryPressureDetector.observedAxisTolerance` reverted to schema default 0.25 (post-process eliminates operator-vs-detector divergence by construction). `checkBracketBoundsSanity` bound restored to `(0, 0.25]`.

2,976 tests passing. `fvm flutter analyze` clean.

## 0.19.18

`MemoryPressureDetector.heap_growing` emission gains `extraTraceArgs.observedSlopeBytesPerSec` (stringified bytes/sec) + `observedAxisArgKey` declaration on the canonical bracket. **No detector raises**; distribution unchanged. Per-detector audit now enforces both presence (declaration) AND fidelity (captures actually carry the arg) for every runtimeVerified+ bracket.

- Detector: `heap_growing` emission stamps `observedSlopeBytesPerSec` (regression slope, bytes/sec) into `extraTraceArgs`. Existing 3 `heap_growing` capture JSONs predate the stamp; cross-check fidelity is allowlisted via `legacyObservedAxisAllowlist` with `consumeBy=0.21.0` pending on-device re-record.
- Audit: `checkRuntimeVerifiedRequiresObservedAxisArgKey` (presence-only invariant on argKey declaration) and `checkCapturesCarryObservedAxisArg` (fidelity invariant — every matched at/above capture record carries a parseable value for the declared argKey) both wired into `runRuntimeTierAudit` + per-detector audit loop. Allowlist exempts grandfathered brackets via typed `LegacyObservedAxisEntry` with `consumeBy` deadline enforced by `checkLegacyObservedAxisManifest` — same lifecycle shape as `retainedOrphans`.
- Allowlist entries: `MemoryPressureDetector.heap_growing.warning` and `PlatformChannelDetector.platform_channel_traffic.warning` (both `consumeBy=0.21.0`; the existing platform_channel captures predate the v0.19.4 `observedCount` stamp landing on the emission path and were not refreshed at the time).
- Schema: backward-compat skip semantics pinned by a regression test in `profile_capture_schema_test.dart` — declared argKey + records lacking the arg must skip silently (load-bearing for every detector with pre-stamp captures).
- `BracketSpec.observedAxisArgKey` and `DetectorMetadata.observedAxisArgKey` docstrings now name the fidelity contract (declaration ≠ active cross-check; `checkCapturesCarryObservedAxisArg` enforces fidelity outside the allowlist).

2,964 tests passing. `fvm flutter analyze` clean.

## 0.19.17

`FrameTimingDetector.sustained_jank` emission gains `extraTraceArgs.observedSevereCount` + `observedJankPercent` + `bufferSize` plumbing and `dedupIdentityMicros` via `_emissionSeq` tie-breaking. **No detector raises**. Distribution unchanged at 10 effective runtimeVerified family-severity pairs across 8 unique stableIds.

- The `sustained_jank.critical` raise was dropped: the bracket axis (sliding-window severeCount) is non-composable with operator-claimed K under the schema's current axis reductions. Captures at `test/validation/captures/frame_timing/sustained_jank_{below,at,above}.json` ship as reproducer-tier provisional evidence via the `retainedOrphans` allowlist; `sustained_jank` stays at the detector's base reproducerOnly tier.
- `checkRuntimeVerifiedRequiresObservedAxisArgKey`: new audit invariant rejects runtimeVerified+ brackets that omit `observedAxisArgKey`. Exercised by the multi-axis E2E pipeline test and 6 unit tests.
- `BracketSpec.observedAxisTolerance` and `.observedAxisReduction` docstrings note that the values are inert when `observedAxisArgKey` is null.
- `FrameTimingSustainedJankCaptureScreen`: below-leg `_belowScenarioDurationMs` reverted to the 6 s scenario length matching at/above legs; correctness relies on the absence-of-event check, not span duration. At/above legs reject the export when `severeFiredCount < targetSevere` so ambient-only severeCount cannot pass as confounded evidence.

2,957 tests passing. `fvm flutter analyze` clean.

## 0.19.16

Audit + schema polish. No detector raises; no public API changes; schemaVersion stays v1. Distribution unchanged at 9/23 effective runtimeVerified families.

- `_validateScenarioMatchesPath` (in `ProfileCaptureSchema`) now routes parent-dir and basename lookups through `package:path` (`p.basename`, `p.basenameWithoutExtension`). Fixes silent over-strict behavior on trailing-separator parent paths and aligns with the audit-side helper. Promotes `path` from `dev_dependencies` to `dependencies` since `lib/` now imports it.
- Operator-typo file `.json` (no name before extension): `package:path` dotfile semantics make the suffix rule strict (`scenario.endsWith('_.json')`) — rejected with the standard scenario-mismatch error.
- `checkBracketBoundsSanity` tightens two bounds:
  - `atTolerance`: `[0, 1.0]` → `[0, 0.65]`. Production max 0.60 (heavy_compute critical) leaves small headroom; future widening past 0.65 requires explicit code change.
  - `aboveCeilingMultiplier`: `(1.0, 5.0]` → `(1.0, 3.0]`. Production max 2.7 (RebuildDetector); same review-on-widen contract.

2,949 tests passing. `fvm flutter analyze` clean.

## 0.19.15

Audit invariant hardening. No detector raises; schemaVersion stays v1. Distribution unchanged at 9/23 effective runtimeVerified families.

- `checkCanonicalCoveredThresholdBacking`: every dotted entry in canonical `coveredThresholds` must be backed by a matching `(stableId, severityLabel)` across the canonical bracket and `additionalBrackets[*]`. Tier-gated to runtimeVerified+/externallyCited. Closes the tier-stack severity gap where canonical declaring `{slow_request.warning, slow_request.critical}` could pass even if `additionalBrackets[2]` (the critical evidence) were dropped — the family-prefix check at the existing `checkPerStableIdTier` level matched on `slow_request.` regardless of which severity was actually backed.
- `checkBracketBoundsSanity`: numeric guards on tolerance and reduction fields applied to canonical and every `additionalBrackets[*]`. `observedAxisTolerance ∈ (0, 0.25]` (matches schema default and current production max), `atTolerance ∈ [0, 1.0]`, `aboveCeilingMultiplier ∈ (1, 5]`, `observedAxisReduction ∈ {max, last}`. Prevents silent widening that defeats bracket meaning.
- `checkCapturePathPerDirectoryNamingUniformity`: every committed capture in a directory must use one shape relating `sleuthMetadata.scenario` to the file basename (basename-exact OR a common scenario-prefix where every file shares the prefix string). Non-conforming scenarios fail the audit. Mixed shapes or mismatched prefixes within one directory fail.
- `ProfileCaptureSchema.parseFile` (and `_parseOrThrowWithLabel` on the bracket-triad path) cross-checks `metadata.scenario` against the file basename. Accepts `scenario == basename` or `scenario.endsWith('_<basename>')` — covers directory-prefixed (`frame_timing_jank_detected_below`) and family-prefixed (`rebuild_activity_below`) shapes. Only escape: immediate parent directory named `_fixtures` (negative-test fixtures). **Stricter validation in parseFile()** — committed captures whose scenario field disagrees with the filename, including prose scenarios, now reject. `parse(List<int>)` byte-only entry is unchanged (no file context).
- 24 new tests across `audit_invariants_test.dart` and `profile_capture_schema_test.dart`. Production NetworkMonitor + HeavyCompute + RebuildDetector metadata exercised against the new backing invariant. Synthetic test fixtures across `_writeRoleCapture`, `cloneWithFieldOverride`, `writeCaptureFile`, and `_writeCapture` derive scenario from filename so future tempdir captures satisfy the cross-check by construction.

2,948 tests passing. `fvm flutter analyze` clean.

## 0.19.14

`NetworkMonitorDetector.slow_request.critical` raised to **runtimeVerified** via `additionalBrackets[2]`. Second tier-stack raise. Backfills `observedAxisArgKey: 'observedDurationMs'` on the canonical slow_request bracket. Distribution: **9/23 effective runtimeVerified families**; every runtimeVerified bracket now declares an observed-axis cross-check.

- Detector: `slow_request` emission stamps `extraTraceArgs.observedDurationMs` (worst record's `durationMs`). Critical `BracketSpec` — `threshold: 3000`, `atTolerance: 0.40` (at-band [3000, 4200]), `aboveCeilingMultiplier: 2.0` (ceiling 6000 ms), `requireUniqueDetectedAtMicros: true`. Both brackets share `observedAxisArgKey: 'observedDurationMs'` + `observedAxisTolerance: 0.10` (loopback measurement paths agree to the millisecond); cross-spec uniqueness tuple `(stableId, severityLabel, argKey)` distinguishes the pair via severityLabel. `coveredThresholds` expands to `{slow_request.warning, slow_request.critical}`.
- Capture screen: severity-tier sub-dropdown (warning / critical) on slow_request mode. `_slowRequestLegSpec(_Tier, _Leg)` resolver tunes target ms + band bounds + scenario name + capture file name per active tier. Critical legs: below=2700 ms (warning fires; critical does not), at=3600 ms, above=5000 ms. `_endScenarioOnce` helper makes scenario closing idempotent — dispose's emission and per-mode catch-block emission for the same scenario can no longer double-emit. `SafeArea` wraps body.
- Reproducer: 5 critical-band cases (4200 / 4201 / 6000 / 6001 ms + observedDurationMs stamp assertion). Layer 2 end-to-end case at 3500 ms confirms `.critical` fires through the SleuthHttpOverrides pipeline with the arg stamped.
- Schema-edge test: `validateBracket` accepts observed=4200 ms / rejects 4200.001 ms at threshold=3000, atTolerance=0.40.
- Anchor: NetworkMonitor block covers both slow_request brackets + canonical `observedAxisArgKey` pin + critical BracketSpec block + 4-tuple cross-spec uniqueness check.
- Captures: 6 on-device recordings (iPhone 12 / iOS 17.5 / Flutter 3.41.x) — warning + critical triads both carry `observedDurationMs`; operator-Stopwatch and detector-stamped value match to the millisecond.

## 0.19.13

`HeavyComputeDetector.heavy_compute.critical` raised to **runtimeVerified** via `additionalBrackets`. First tier-stack raise (warning + critical brackets on one family). Distribution: **8/23 effective runtimeVerified families**.

- Detector: critical `BracketSpec` — `threshold: 16`, `atTolerance: 0.60` (at-band [16, 25.6]), `aboveCeilingMultiplier: 1.875` (ceiling 30 ms). `coveredThresholds` expands to `{warning, critical}`. Both brackets declare `observedAxisArgKey: 'observedDurationMs'` and the detector stamps BUILD ms into `extraTraceArgs` so the audit gate cross-checks operator-Stopwatch observed against detector-side measurement (closes wrong-magnitude gap when `magnitudeSourceEventName: ''` bypasses BUILD-derivation).
- Audit invariant `checkAdditionalBrackets`: cross-spec uniqueness tuple bumped to `(stableId, severityLabel, observedAxisArgKey)`. Trace event names `sleuth.issue.<id>.<severity>` differ by severity, so the prior 2-tuple false-collided on tier-stack raises. 2 tests pin the new accept cases.
- Capture screen: tier-mode dropdown drives `_legSpec(_Tier, _Leg)` resolver — target ms, band bounds, scenario name, capture file name retune per active tier. Critical legs: below=12 ms, at=20 ms, above=27 ms. `exportCaptureJson` receives `bracketStableId` + `bracketSeverityLabel` so trace-record presence (or absence on below) is validated at clipboard-copy time. `dispose()` emits `markScenarioEnd` for any in-flight scenario. `SafeArea` wraps the log.
- Reproducer: 7 critical-band cases (18000 / 24000 / 24001 / 25600 / 25601 / 30000 / 30001µs) pin `.critical` emission across the band. 25600/25601µs straddle the schema's 0.60 at-band upper edge.
- Schema-edge test: `validateBracket` accepts observed=25.6 ms / rejects 25.601 ms at threshold=16, atTolerance=0.60.
- Anchor: 13 explicit pins covering both brackets.
- Captures: 6 on-device recordings (iPhone 12 / iOS 17.5 / Flutter 3.41.x) — both warning and critical triads carry `observedDurationMs` for cross-check.

## 0.19.12

`RebuildDetector.rebuild_activity.warning` raised to **runtimeVerified** via `perStableIdTier`. First raise requiring baseline subtraction: iOS profile-mode framework activity emits ~10–15 BUILDs/sec ambient, exceeding the default 10/sec threshold. Distribution: **20/23 reproducerOnly base, 7/23 effective runtimeVerified families**.

- Detector: `setBaseline(int)` + `baselineRebuildRate` + `peakObservedRebuildRate` getters. `_evaluateVmData` subtracts baseline before threshold gate, severity, and `extraTraceArgs.observedRebuildRate`. Default 0 → no-op subtraction → live monitoring unchanged. `vmConnected = false` clears baseline so capture-mode subtraction cannot leak into post-reconnect live monitoring. `FixHintBuilder` receives raw `buildCount` so user-facing prose reflects total observed activity, not internal baseline-corrected.
- Bracket params: `bracketThreshold: 11`, `bracketAtTolerance: 0.65` (at-band [11, 18.15]), `aboveCeilingMultiplier: 2.7` (ceiling 29.7 strictly under critical 30), `observedAxisArgKey: 'observedRebuildRate'`, `observedAxisReduction: 'max'`, `bracketRequireUniqueDetectedAtMicros: true`.
- Capture screen: inline baseline measurement per leg (3s idle scenario before pulse phase) keeps subtraction current with overlay state. `_Pulse` widget uses const `SizedBox.shrink` child for 1-BUILD-per-tick semantics. `dispose()` calls `setBaseline(0)` to release pollution.
- 3 on-device captures at `test/validation/captures/rebuild_detector/{below,at,above}.json` (iPhone 12 / iOS 17.5 / Flutter 3.41.x).
- Anchor: lifted out of `_v0174Expectations` batch into dedicated runtimeVerified anchor with 12 explicit pin assertions.
- Tests: 7 new detector tests (baseline + peak + vmConnected reset + critical-tier baseline-correction); regression test pins `_legs` ↔ committed JSON `expectedMagnitude.min/max` coherence + schemaVersion=v1; capture-shape pin asserts exactly 1 begin/end marker per JSON.

2,903 tests passing. `fvm flutter analyze` clean.

## 0.19.11

`RebuildDetector` capture-pipeline plumbing for a future `rebuild_activity.warning` runtimeVerified raise. No tier change; metadata flips once three on-device captures land. Distribution unchanged from v0.19.10.

- Detector: `lastObservedRebuildRate` getter (field-write precedes threshold gate); `resetCaptureState()` clears 5 VM-window fields + re-anchors `_windowStart`; `rebuild_activity` emission stamps `dedupIdentityMicros` + `observedRebuildRate` in `extraTraceArgs`.
- Public API (non-breaking): `Sleuth.rebuildDetector` getter; `RebuildDetector` barrel-exported.
- Capture screen `rebuild_activity_capture_screen.dart` (NEW): Stopwatch-throttled Ticker drives setState on plain StatefulWidget at 5/15/20 per sec; refresh-rate-independent (60/90/120 Hz). Plain Stateful avoids builder-widget 3× threshold multiplier.
- Controller: `RebuildDetector` promoted to typed field (4 typed + 19 factory = 23). `resetCaptureState` chains into detector's reset.
- Tests: 4 detector + 1 reproducer grep guard (forbids `60 / leg.targetRebuildRate`, requires `1000 / leg.targetRebuildRate`).

2,893 tests passing. `fvm flutter analyze` clean.

## 0.19.10

NetworkMonitor capture-pipeline hardening. No tier change. Distribution unchanged from v0.19.9. Closes `request_frequency` below-leg producer asymmetry — detector exposes windowed peak so operators export detector-measured evidence.

- Detector: `lastObservedPeakCount` getter (always-on, O(200) bounded); `flushFrequencyEvaluation()` peak-only recompute (idempotent, no emission); `clearRecords()` resets peak.
- Public API (non-breaking): `Sleuth.networkMonitor` getter; `NetworkMonitorDetector` barrel-exported. `Sleuth.exportCaptureJson` accepts optional `bracketStableId` + `bracketSeverityLabel` — refuses export when at/above legs lack matching `sleuth.issue.<stableId>.<severity>` event in span, or below contains one.
- Capture screen `network_monitor_capture_screen.dart`: reads `lastObservedPeakCount` after `flushFrequencyEvaluation()`; calls `Sleuth.flushTimelineNow(timeout: 2s)` before `markScenarioEnd`. `large_response` envelope constant 32 → 10.
- Tests: 5 detector + 1 dedup + 1 producer-wiring grep.

Existing v0.19.9 captures remain valid. 2,888 tests passing. `fvm flutter analyze` clean.

## 0.19.9

First multi-axis runtimeVerified raise via the v0.19.8 `additionalBrackets` schema. `NetworkMonitorDetector` raises 2 more families through `perStableIdTier`: `large_response.warning` (1 MiB, bytes axis) and `request_frequency.warning` (30 events / 5 s window, events axis). `slow_request.warning` from v0.18.0 unchanged. Distribution: **20/23 reproducerOnly base, 6/23 effective runtimeVerified families** (7 effective family raises across 4 multi-family detectors). No BREAKING; no public API changes.

- `perStableIdTier`: 3 entries at `runtimeVerified` (slow_request, large_response, request_frequency). `http_error_spike` and `high_frequency_same_path` stay at base `reproducerOnly`.
- `additionalBrackets[0]` — `large_response`: threshold 1048576 bytes, atTolerance 0.10 (deterministic loopback bytes), aboveCeilingMultiplier 2.0 (above-band ceiling 2 MiB << 5 MiB critical), `observedAxisArgKey: 'observedResponseBytes'`.
- `additionalBrackets[1]` — `request_frequency`: threshold 30 events, atTolerance 0.50 (iOS scheduling jitter; mirrors v0.19.4 PlatformChannel), aboveCeilingMultiplier 2.0 (ceiling 60, narrowed at audit time by `above > at_observed`), `observedAxisArgKey: 'observedRequestCount'`. Detector emits warning severity only; schema event-name severity filter would scope a future critical raise without metadata change.
- Both specs: `requireUniqueDetectedAtMicros: true`, `requireDetectorTraceRecord: true`. `large_response` and `request_frequency` emissions stamp `dedupIdentityMicros` and export the observed-axis value to `extraTraceArgs` so the audit gate cross-checks capture-side magnitude against detector-recorded value.
- Capture screen: mode dropdown (slowRequest / largeResponse / requestFrequency); loopback `HttpServer` with `?delay=N` and `?bytes=N` query params; `Sleuth.suspendNonEssentialTimelineStreams()` for the 5.5 s frequency span.
- Six new on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.x) at `test/validation/captures/network_monitor/{large_response,request_frequency}_{below,at,above}.json`.
- NetworkMonitor anchor pins all 3 `perStableIdTier` raises and both BracketSpec entries with full field literals. 2 new reproducer tests for `extraTraceArgs` shape.

2,881 tests passing (+2 net from v0.19.8). `fvm flutter analyze` clean.

## 0.19.8

Schema extension for detectors with 2+ runtimeVerified evidence axes on the same family. No tier raises; no public API breaks; captureSchemaVersion unchanged. Distribution unchanged from v0.19.7: **20/23 reproducerOnly base, 4/23 effective runtimeVerified families**. v0.19.9+ uses the new field for the first multi-axis raise (PlatformChannel duration axis, NetworkMonitor / MemoryPressure non-canonical families).

- New `BracketSpec` const class + `DetectorMetadata.additionalBrackets: List<BracketSpec>?`. Empty list rejected. Top-level fields treated as logical spec #0 for cross-spec checks.
- `ProfileCaptureSchema._validateOneBracket` is the shared body. Public `validateBracket(...)` preserved via synthetic-spec wrapper (error text byte-for-byte identical to v0.19.7). New `validateBracketSpec(BracketSpec, {File...})` is the spec-driven entry.
- `runRuntimeTierAudit` in `audit_invariants.dart` runs the full per-tier helper chain (`checkCoveredThresholds` → `checkSeverityScopedCeiling` → `checkBracketCount` → `checkBracketValidation` → `checkAdditionalBrackets` → `checkAdditionalCapturePaths` → `checkAdditionalBracketValidation`). Both audit-walker switch branches (`runtimeVerified`, `externallyCited`) and the synthetic E2E pipeline test call this same function so wiring is verified by CI even when no shipped detector populates `additionalBrackets`.
- Per-spec audit checks on `additionalBrackets[*]`: repo-containment + existence + schema-parse on capture paths; `coveredThresholds` entries validated as `<stableId>.<severity>` matching `spec.stableId`/`spec.severityLabel` (severity ∈ `{warning, critical, info}`); cross-spec uniqueness on canonicalised `(stableId, observedAxisArgKey)`; capture-path disjointness across canonical + all specs (via `path.canonicalize`); severity-scoped `coveredThresholds` requires explicit `aboveCeilingMultiplier` (no default-2.0 inheritance).
- `checkPerStableIdTier` proves coverage through `coveredThresholds` entries — a runtimeVerified family in `perStableIdTier` requires a matching `<familyId>.<severity>` entry in either canonical `coveredThresholds` or some `BracketSpec.coveredThresholds`. StableId match alone is no longer sufficient.
- Orphan-capture-audit walks `meta.additionalBrackets?.expand((s) => s.profileCapturePaths)`.
- 5 detector anchor blocks pin `additionalBrackets isNull`.

29 new tests cover: per-spec required-fields, empty-list rejection, cross-spec collision matrix, mixed-mode collision, synthetic-spec error-text equivalence (NaN, below-violation, at-band overflow), perStableIdTier coverage rule, stableId-vs-coveredThresholds mismatch rejection, severity-typo rejection, capture-path overlap detection, per-spec severity-scoped ceiling, end-to-end pipeline group on synthetic metadata. 2,879 tests passing (+29 net from v0.19.7). `fvm flutter analyze` clean.

## 0.19.7

`FrameTimingDetector.jank_detected` raised to **runtimeVerified** via `perStableIdTier`. Warning tier only; critical (`sustained_jank`) and cache-family stableIds stay implicitly reproducerOnly. Distribution: **20/23 reproducerOnly base, 4/23 effective runtimeVerified families**.

Three on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.x) at `test/validation/captures/frame_timing/jank_detected_{below,at,above}.json` bracket the rounded `jankPercent > 15` gate on a denominator-independent percent axis. Below leg silent; at/above legs each carry 49 emissions with `observedJankPercent` 24% / 28% LAST in span at full 240-frame buffer.

Metadata:

- `bracketThreshold: 16` — detector rounds `jankPercent` to int + uses strict `> 15`, so first reachable observed value is 16. Setting threshold=15 would accept captures the detector cannot emit.
- `bracketUnit: 'percent'`, `bracketAtTolerance: 0.50` (at-band [16, 24]), `aboveCeilingMultiplier: 1.85` (above-band (24, 29.6]).
- `observedAxisArgKey: 'observedJankPercent'`, `observedAxisReduction: 'last'`. jankPercent over a rolling buffer is non-monotone — MAX picks early small-sample-size transient instead of operator-intended steady-state band.
- `bracketRequireUniqueDetectedAtMicros: true`. `coveredThresholds: {jank_detected.warning}`.

2,850 tests passing. `fvm flutter analyze` clean.

## 0.19.6

Structural prerequisites for the v0.19.7 `jank_detected.warning` runtimeVerified raise. No tier raises this release. Distribution unchanged from v0.19.5: **20/23 reproducerOnly base, 3/23 effective runtimeVerified families**. No BREAKING; no public API changes.

Detector:

- `FrameTimingDetector.captureMode` ctor flag (from `SleuthConfig.captureMode`) short-circuits `_isPastWarmup()` so a bracket scenario fits inside one screen interaction without waiting out the 3 s warmup gate. Default `false`.
- `_evaluateJank` switched from `if/else if` to `if/if`. When both gates fire (severeCount ≥ 3 AND jankPercent > 15), BOTH stableIds emit concurrently. The prior `else if` made warning-tier signal unreachable on devices with ambient severeCount ≥ 3. Other runtimeVerified+ detectors already emit parallel multi-stableId issues; IssueRanker composite-score ordering handles it.
- `jank_detected` emission stamps `dedupIdentityMicros = DateTime.now().microsecondsSinceEpoch + (_emissionSeq++)`. `extraTraceArgs` exports `observedJankCount`, `observedJankPercent`, `observedWorstFrameMs`, `bufferSize`.
- `FrameTimingDetector.reset()` clears buffer + `_issues` + warmup anchors (preserves `_emissionSeq`); auto-invoked by `SleuthController.resetCaptureState()`.

Schema: `DetectorMetadata.observedAxisReduction: 'max' | 'last'` (default `'max'`). `'last'` is required for non-monotone windowed-aggregate observables (jankPercent over rolling buffer). `'percent'` added to `ProfileCaptureSchema.approvedUnits`.

New `FrameTimingCaptureScreen` example demo: 60 Hz pre-flight, captureMode pre-flight, rate-based UI-thread injector via `Ticker` (spins 18 ms on every Nth animation frame matched to leg's target jankPercent — below 0%, at 20%, above 27%), 6 s scenario span with per-leg `Sleuth.suspendNonEssentialTimelineStreams()`, validator extracts LAST in-span `jank_detected.warning` emission's `observedJankPercent` and rejects when its `bufferSize` arg < 180 frames.

6 new reproducer tests pin captureMode warmup short-circuit, `extraTraceArgs` shape, `_emissionSeq` monotonicity across `reset()`, reset semantics, parallel-emission overlap fixture. 2,850 tests passing (+6 net from v0.19.5). `fvm flutter analyze` clean.

## 0.19.5

Parser-hardening release. No tier raises. Distribution unchanged from v0.19.4: **20/23 reproducerOnly base, 3/23 effective runtimeVerified families** (HeavyCompute.heavy_compute base + MemoryPressure.heap_growing per-family + PlatformChannel.platform_channel_traffic base). No BREAKING, no public API changes.

### TimelineParser — B/E reconstruction extended to LAYOUT, PAINT, raster

iOS profile mode (Impeller) emits LAYOUT, PAINT, and raster events as nested `B`/`E` pairs with no `X`-form complete events (`LAYOUT (root)` wraps `LAYOUT`; `PAINT (root)` wraps `PAINT`; raster trio `GPURasterizer::Draw` → `Rasterizer::DoDraw` → `Rasterizer::DrawToSurfaces` nests on the raster thread). Pre-v0.19.5 the parser dropped these silently. v0.19.5 extends the v0.18.2 BUILD reconstruction pattern via shared `_reconstructPhaseBE` helper with **stack-drain-empty outermost-only emission** — a duration is credited only when the popped E closes the outermost scope per thread, so nested same-phase scopes do not double-count. Skia X-form path unchanged.

- New `_pendingPhaseBeginsCapPerTid = 100` cap (mirrors BUILD's). `VmServiceClient` carries three new pending-begins maps (`_pendingLayoutBegins`, `_pendingPaintBegins`, `_pendingRasterBegins`) threaded through `TimelineParser.parse()`, cleared in `_cleanup()`, swept via shared `_evictStaleBegins` helper at the existing 30-second age cutoff.
- 9 new parser tests pin: single-pair `dur` reconstruction per phase, outermost-only emission for nested pairs, cross-batch reconstruction, per-tid isolation, X-form backward-compat.
- On-device verification (iPhone 12 / iOS 17.5 / Flutter 3.41.x): 155 frames over 3 s with averaged outermost-raster `dur` ≈ 2.12 ms/frame.

### Sleuth — new diagnostic accessor

`Sleuth.diagnoseCaptureState()` returns `(initialized, captureMode, vmConnected)` for capture-mode tooling to surface specific environmental state without requiring Console.app or `flutter run` terminal access.

### GpuPressure raster_dominance raise — attempted, not shipped

A `raster_dominance` runtimeVerified raise was investigated and not shipped. Three structural blockers documented in `doc/validation_ledger.md`: (1) the `_lastRasterUs / _lastUiUs > 2.0` ratio axis is unforceable on iOS profile mode given steady-state UI cost ~3-5 ms/frame vs single-filter raster ~2 ms/frame; (2) `ProfileCaptureSchema._crossCheckTraceVsObserved` skips for non-time units, so a `'ratio'` bracket has no independent schema witness; (3) `processTimelineData` overwrite-not-accumulate splices raster numerator and UI denominator across different polls. Future raster-related raise needs an absolute-ms axis and single-poll-snapshot detector evaluation. Detector stays at `reproducerOnly`.

### Verification

- 2,844 tests passing (+9 net from v0.19.4 = parser B/E reconstruction tests).
- `fvm flutter analyze` clean.

## 0.19.4

`PlatformChannelDetector.platform_channel_traffic` raised to **runtimeVerified** (base-tier raise — single-family detector, HeavyCompute pattern). Distribution: **20/23 reproducerOnly base, 3/23 effective runtimeVerified families** (HeavyCompute.heavy_compute base, MemoryPressure.heap_growing per-family, PlatformChannel.platform_channel_traffic base). Frequency axis only — the 8 ms cumulative-duration axis and 41 calls/sec critical tier remain implicitly reproducerOnly. No BREAKING, no public API changes.

### PlatformChannelDetector

- **True cooldown semantics.** `_evaluateWindow` no longer emits a fresh issue on every overload-positive evaluation cycle. When threshold is exceeded but the cooldown counter is still draining from a prior fire, the detector now suppresses the new emission, decrements the counter, and retains the prior `_lastEmittedIssue` (preserving its `dedupIdentityMicros`). This matters for capture-mode scenario brackets — a multi-second overload would otherwise emit one trace record per detector cycle and break the audit-gate's per-scenario count check (saw 2 trace records inside a 2.5 s `above` capture span). After cooldown drains, normal re-fire stamps a fresh dedup identity. **Behavior change for live monitoring**: under sustained overload, the floating issues card now shows ONE persistent platform-channel-traffic card instead of a re-emit per evaluation cycle. Less spam, same surfaced state.
- **Severity-mismatch fresh-emission rule.** Cooldown suppression has one carve-out: if the current window's severity differs from the retained issue's severity (warning ↔ critical in either direction), the detector emits a fresh issue with a new `dedupIdentityMicros` instead of retaining the stale severity. Replaces the v0.19.4 initial pass's one-way warning→critical exception with a symmetric rule. Live monitoring surfaces both escalations (warning → critical) and de-escalations (critical → warning) in real time rather than holding stale severity UI for up to 3 cycles. Same-severity sustained overloads still suppress normally.
- **Cross-leg state reset.** `PlatformChannelDetector.reset()` clears `_recentCallCount`, `_cumulativeDurationUs`, `_methodCounts`, `_windowStart`, `_cooldownCyclesRemaining`, `_lastEmittedIssue`, and `_issues`. `SleuthController.resetCaptureState()` (called from `Sleuth.markScenarioBegin`) now also resets the PlatformChannelDetector instance. Without this, a back-to-back capture leg that started inside the prior leg's 3-cycle cooldown drain would have its first overload window suppressed AND blocked by the controller's composite-key dedup on the retained leg-1 issue identity → zero in-span trace records → validator rejects. The reset clears detector-internal state only; controller-level `_captureEmittedKeys` stays persistent across scenarios so retainTimeline buffer replays cannot re-record stale issues.
- **Detector-observed axis cross-check.** Detector now stamps `_recentCallCount` and `_cumulativeDurationUs` into the trace event args via `PerformanceIssue.extraTraceArgs`. The audit gate cross-checks the capture's send-side `expectedMagnitude.observed` against the detector's `args["observedCount"]` within ±25% tolerance. Mislabeled-leg captures (operator reports at-band send rate while detector saw above-band count, or vice versa) now fail audit instead of silently bracketing the wrong band. Backward compatible: pre-v0.19.5 captures recorded before the field was added skip the cross-check at the per-record-arg level.
- **`platform_channel_traffic` warning tier** (frequency axis: > 20 calls per 1 s evaluation window) raised from base reproducerOnly to **runtimeVerified**. Three on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.x) at below (15 calls/sec sub-threshold), at (25 calls/sec in-band), above (35 calls/sec) bracket bands recorded via the new `PlatformChannelCaptureScreen`. `bracketAtTolerance: 0.50` → at-band [20, 30]; `aboveCeilingMultiplier: 1.95` → above-band ceiling 39 calls/sec, kept strictly under the 41-call (>20×2) critical-escalation boundary so above-leg cannot ambiently bracket the critical tier. `bracketRequireUniqueDetectedAtMicros: true` enforces single-issue replay protection.
- `platform_channel_traffic` `PerformanceIssue` carries `dedupIdentityMicros = _windowStart.microsecondsSinceEpoch`. Stable per-window identity across all polls during one cooldown cycle → SleuthController composite-key dedup collapses N polls observing the same firing window to one trace record.

### Example app — capture infrastructure

- **New `PlatformChannelCaptureScreen`** under `example/lib/demos/`. Adapted from `MemoryPressureCaptureScreen` for the short-scenario PlatformChannel workload: 1.5 s of `MethodChannel.invokeMethod('ping')` calls in parallel `Future.wait` batches (sequential awaits would cap effective send rate at ~12-80/sec on iOS wireless debug, making the above band unreachable) + 1.5 s post-allocation dwell + 200 ms post-end barrier (dwell extended from 800 ms after initial captures showed only 43 ms scenario-end headroom on the at-leg; 1500 ms covers three detector poll cycles so future re-captures on warmer/throttled devices stay inside the span). `debugProfilePlatformChannels = true` set per-leg in try/finally so the framework flag does not leak into post-leg live monitoring. Channel reuses the existing `sleuth_demo_channel` registered at `example/ios/Runner/AppDelegate.swift:21-25` (handler returns `result(nil)`). No stream narrowing — the 2.5 s scenario span stays well inside VM ring-buffer capacity even with default Dart + Embedder + GC streams enabled. Retry budget 5 per leg; out-of-band runs do NOT export. Post-capture validator parses the wrapped JSON and rejects exports with unexpected `sleuth.issue.platform_channel_traffic.warning` count inside the scenario span.

### Audit anchor block

- `PlatformChannelDetector` lifted out of `_v0174Expectations` reproducerOnly batch into the new `PlatformChannelDetector pinned at runtimeVerified (v0.19.4)` anchor block. Pins all bracket fields + two prose-drift guards: (1) critical-tier prose-drift (rationale must not claim 41 calls/sec is captured-bracketed without a coveredThresholds entry), (2) duration-axis prose-drift (rationale must not claim the 8 ms cumulative axis is runtime-verified by captures without a separate ms-unit triad).

### Capture screen — in-screen validator parity

- `_validateTraceRecords` now mirrors the audit gate's `bracketRequireUniqueDetectedAtMicros` invariant — every in-span warning record must carry a parseable `detectedAtMicros` arg, AND the count of unique values must equal the record count. Previously the screen reported "Export OK" for captures that CI later rejected for replay inflation or missing dedup identity. The new check rejects the export with an operator-friendly diagnostic before clipboard copy.

### Verification

- 2,835 tests passing (was 2,828 in v0.19.3; +7 net = +1 detector_metadata_audit anchor block + +1 platform_channel cooldown regression + +1 escalation-through-cooldown regression + +1 extraTraceArgs export + +1 de-escalation-through-cooldown regression + +1 severity-oscillation regression + +1 reset() back-to-back-leg regression).
- `fvm flutter analyze` clean.

### Known limitations

- The 41 calls/sec critical tier and the 8 ms cumulative-duration axis remain implicitly reproducerOnly. A future raise needs (a) a critical-tier capture campaign bracketing 41 calls/sec, OR (b) a duration-axis capture triad with `unit: 'ms'` and a second perStableIdTier entry. Neither piggybacks on the warning-frequency raise.
- `debugProfilePlatformChannels` is a top-level Flutter framework flag — concurrent capture screens or operator workflows that touch this flag during a leg would interleave events. The capture screen scopes the flag per-leg via try/finally, so the failure mode is "operator manually flips the flag mid-leg" only.

## 0.19.3

`MemoryPressureDetector.heap_growing` raised to **runtimeVerified** via `perStableIdTier`. Distribution: **21/23 reproducerOnly base, 2/23 effective runtimeVerified families** (HeavyCompute.heap_compute base, MemoryPressure.heap_growing per-family). Other 3 MemoryPressure families (gc_pressure, heap_near_capacity, native_memory_growing) stay base reproducerOnly. No BREAKING. New public API: `Sleuth.suspendNonEssentialTimelineStreams()` + `Sleuth.resumeAllTimelineStreams()` for capture procedures that need to suppress Embedder/GC stream churn during long allocation phases.

### MemoryPressureDetector

- **`heap_growing` warning tier** (slope > 512 KB/s sustained ≥ 10 s) raised from reproducerOnly to **runtimeVerified** via `DetectorMetadata.perStableIdTier` extension. Three on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.x) at below (314 KB/s sub-threshold), at (574 KB/s in-band), above (825 KB/s) bracket bands recorded via the new `MemoryPressureCaptureScreen`. `bracketAtTolerance: 0.50` → at-band [512000, 768000]; `aboveCeilingMultiplier: 2.0` → above-band ceiling 1024000. `bracketRequireUniqueDetectedAtMicros: true` enforces single-issue replay protection.
- `vmConnected = false` setter clears all identity-bearing session state (heap samples, sustained-growth start, native-growth start, capacity rolling window, first-sample marker, GC sliding window). Without this cleanup, `_sustainedGrowthStart` survived disconnect and the first post-reconnect `heap_growing` emission carried a `dedupIdentityMicros` derived from a prior-session timestamp, corrupting producer-side composite-key dedup.
- `heap_growing` `PerformanceIssue` carries `dedupIdentityMicros = _sustainedGrowthStart.microsecondsSinceEpoch`. Stable per-trigger identity across all polls during one sustained-growth episode → SleuthController composite-key dedup collapses N polls to one trace record.

### Capture infrastructure

- **New public API: `Sleuth.suspendNonEssentialTimelineStreams()` / `Sleuth.resumeAllTimelineStreams()`** narrow the VM timeline stream allowlist to `Dart` only during scenario spans. Disables Embedder + GC streams (high-volume per-frame paint/raster/build/GC events) so the default ~50k-event ring buffer cannot overflow during 30 s+ allocation phases that would otherwise roll scenario markers off mid-leg. MemoryPressure detector observes heap via `getMemoryUsage` RPC and GC via `EventStreams.kGC` subscription — both independent of timeline streams, so narrowing is safe. Triple-gated on `kReleaseMode + captureMode`.
- `SleuthController.resetCaptureState()` (called by `Sleuth.markScenarioBegin`) now also calls `_memoryPressure.reset()` so the detector's regression window starts fresh on scenario allocation only — pre-scenario flat samples would otherwise dilute the slope below threshold even when the allocator rate is well above it.
- `ProfileCaptureSchema.approvedUnits` extended with `bytes/sec` (size-per-time rate unit) for heap_growing's slope axis.
- `lib/sleuth.dart:443-457` doc-impl drift fix: comment on `markScenarioBegin` no longer claims it clears the producer-side dedup set (it does not — the set persists across scenarios by design; only per-detector record buffers reset).

### Example app — capture infrastructure

- **New `MemoryPressureCaptureScreen`** under `example/lib/demos/`. Adapted from `HeavyComputeCaptureScreen` for wall-clock-bound `heap_growing`: 30 s sustained allocation (fills detector regression window with ramp samples) + 600 ms pre-end dwell (heap-poll lands issue inside scenario span) + 800 ms post-end dwell (VM-service buffer flush before `exportCaptureJson` reads). Calibration retry budget 5 per leg. Stream narrowing during scenario via the new Sleuth API. Stash-then-export pattern: `exportCaptureJson` runs immediately after `markScenarioEnd` while markers still in buffer. Post-capture validator parses the wrapped JSON and rejects exports with unexpected `sleuth.issue.heap_growing.warning` count inside the scenario span.
- `SleuthController.exportCaptureJson` adds debugPrint diagnostics at each null-return path (VM client null/disconnected, empty events, scenario markers not found) so capture-procedure failures pinpoint root cause without source dives.

### PerformanceIssue.copyWith

- Added `int? dedupIdentityMicros` parameter (silent-drop bug fix). `MemoryPressureDetector.enrichHeapGrowingIssue` calls `copyWith` to attach top-allocator data; without this propagation the clone nullified the dedup identity, breaking capture-mode dedup for any subsequent emission against the same trigger.

### Verification

- 2,828 tests passing (was 2,822 in v0.19.2; +6 net = +2 memory_pressure reproducer + +3 PerformanceIssue copyWith + +1 detector_metadata_audit anchor block).
- `fvm flutter analyze` clean.

### Known limitations

- A scenario where `_sustainedGrowthStart` resets mid-allocation (slope dip + resume) can emit ≥ 2 trace records with distinct dedup identities. The capture-screen post-validator catches this and rejects the export. Automated detector-side window-break suppression deferred — would require a hysteresis layer between slope-cross and `_sustainedGrowthStart` reset, surfacing a separate verification surface.
- The `heap_growing` capture procedure narrows VM timeline streams to `Dart` only during scenarios, masking Embedder/GC events from any concurrent debugger / DevTools session for the ~31 s leg duration. Restored automatically post-scenario.

## 0.19.2

Polish release — clears v0.19.1 known-limitations. No new tier raises, no public API changes, no BREAKING.

### VmServiceClient

- `_sweepStalePendingBegins` now also evicts stale `_lastProcessedTsByTid` cursors **in non-capture polling mode only** (`retainTimeline=false`). Capture mode (`retainTimeline=true`) retains cursors for the session lifetime because the VM buffer is intentionally re-read across polls and the cursor is the dedup mechanism preventing replay of retained events. The pending-begins age sweep stays unconditional in both modes — orphan B is a leak regardless of buffer-retention strategy. Cutoff: `anchorTs - 30s` per the new `_cursorMaxIdleMicros` constant. Idle-poll sessions (no events) skip the sweep — gap documented below.

### Layer-3 NetworkMonitor reproducer tests

- 2 new time-window tests pin `_frequencyWindowMs=5000` boundary semantics:
  - `request_frequency`: 5+5 records spread across 6s gap → silent (peak window holds 5, equal to limit).
  - `http_error_spike`: 2+2 errors spread across 6s gap → silent (peak window holds 2, below ≥3 threshold).

### `.gitattributes`

- New `.gitattributes` rule for `test/validation/captures/**/*.json`: `-text -diff linguist-vendored=true`. Prevents Windows-CRLF byte drift, collapses fixture JSONs in PR diffs, marks them as vendored data. SHA pin in `profile_capture_schema_anchor_test.dart` remains the primary safety net against IDE auto-format.

### Verification

- 2,822 tests passing (was 2,818 in v0.19.1; +4 net = +1 cursor sweep + +2 time-window + +1 capture-mode no-evict regression).
- `fvm flutter analyze` clean.

### Known limitations

- Cursor sweep runs only on polls with at least one event. Sessions that go fully idle for hours retain accumulated cursors until the next active poll. Worst case bounded by OS thread limit (~1024 unique tids per process).
- `.gitattributes` cannot prevent IDE auto-format on save. SHA pin remains the safety net for the anchor fixture.

## 0.19.1

Hardening release — capture-mode dedup, reconnect-race fix, audit-gate tightening. No new tier raises, no public API changes, no BREAKING.

### Parser

- `TimelineParser.parse(..., {cursorsByTid})` — new per-tid composite cursor (`TimelineCursor = ({int lastTs, Set<String> seenSignatures})`) that dedups events across calls. Skips re-observed events using `(tid, ts, ph, name, id)` signature so two distinct events sharing `(tid, ts)` (instant events with different names; async pairs with different `id`) coexist correctly. Same-name same-microsecond sync events remain conflated (protocol-indistinguishable).
- Without this cursor, capture mode (`retainTimeline=true`) re-reads the full retained buffer per poll and inflates `buildEventCount`, `buildScopeDurations`, `gcEvents`, `platformChannelEvents`.
- `VmServiceClient` threads a long-lived `_lastProcessedTsByTid` map through parse calls. Cleared on `_cleanup()`.

### VmServiceClient

- New `_sessionGeneration` int field bumped at the start of `_cleanup()`. `_pollTimeline` captures the generation at start and re-checks after each await (`getVMTimeline`, `clearVMTimeline`, `getMemoryUsage`) before writing session-shared maps, firing callbacks, or running `_sweepStalePendingBegins`. Without the fence, an in-flight poll resuming after a reconnect could repopulate cleared maps with stale state and evict fresh begins using the prior session's anchor ts.

### Audit gate

- `checkPerStableIdTier` rejects empty `perStableIdTier: {}` as misconfiguration.
- `DetectorMetadata.perStableIdTier` doc clarifies single-family detectors set base `tier` directly — `perStableIdTier` is for multi-family detectors where a single base tier would over- or under-claim.

### Layer-3 NetworkMonitor reproducer tests

Replaced credit-only tests with boundary triads pinning operator semantics per family with EXPLICIT threshold values (no default reliance):

- `large_response`: `>= largeResponseBytes` at limit-1 / limit / 2×.
- `request_frequency`: `> frequencyLimit` at limit / limit+1 / 2×limit.
- `http_error_spike`: `>= 3` → warning, `>= 10` → critical.
- `high_frequency_same_path`: `>= 3` → warning, `>= 10` → critical.

### Verification

- 2,818 tests passing (was 2,809 in v0.19.0; +9 net).
- `fvm flutter analyze` clean.

### Known limitations (deferred to v0.20.0+)

- `_lastProcessedTsByTid` grows across session lifetime (one entry per unique `tid` ever observed). Bounded by OS thread limit; ~16KB worst case. Age-based pruning planned.
- Layer-3 boundary triads use frozen `fakeNow`. Pin COUNT thresholds correctly but don't cover time-window edge cases (records spread beyond `_frequencyWindowMs`).
- Single-family-detector convention is documented but not audit-enforced.

## 0.19.0

**Hardening release — four deferred items closed. BREAKING schema change.** No new tier raises.

### BREAKING — `sleuthMetadata.role` is now a required capture field

`ProfileCaptureSchema.parse` / `parseFile` / `validateBracket` reject any capture whose
`sleuthMetadata` block lacks a `role` key set to `'below'`, `'at'`, or `'above'`. Pre-v0.19.0
capture files fail with `Missing required sleuthMetadata key: "role"`. The minor version bump
signals this break per pre-1.0 SemVer convention.

**Migration:** for each pre-v0.19.0 capture, add a `"role"` field to its `sleuthMetadata` block
matching the capture's bracket leg. The `tool/wrap_capture.dart` CLI accepts `--role` (or
falls back to filename suffix `_below.json` / `_at.json` / `_above.json`) so re-running the
wrap step regenerates a v0.19.0-compliant capture. The 6 in-tree production captures + 9
fixtures + anchor were backfilled in this release.

### Detector ledger

The detector ledger summary shifts from **21 / 23 at `reproducerOnly` + 2 / 23 at
`runtimeVerified`** to **22 / 23 at `reproducerOnly` + 1 / 23 at `runtimeVerified`** because
`NetworkMonitorDetector`'s *base* tier dropped from `runtimeVerified` to `reproducerOnly` —
the on-device evidence for `slow_request` is preserved via the new `perStableIdTier` raise
(effective tier per family is unchanged), but the four other emitted families
(`large_response`, `request_frequency`, `http_error_spike`, `high_frequency_same_path`) are
no longer mechanically over-claimed by the detector-level tag. `HeavyComputeDetector`
(single-family) keeps its base `runtimeVerified` tag.

### Parser cross-batch BUILD reconstruction (`lib/src/vm/timeline_parser.dart`, `lib/src/vm/vm_service_client.dart`)

- `TimelineParser.parse(events, {pendingBuildBegins})` now optionally takes a per-tid pending-begins
  map and threads it across poll batches, so a `BUILD ph: 'B'` in poll N is reconstructed against
  its `BUILD ph: 'E'` in poll N+1. Without this, every poll boundary that fell mid-build dropped
  one BUILD on the floor.
- `VmServiceClient` carries a `_pendingBuildBegins: Map<int, List<Map<String, dynamic>>>` instance
  field across `_pollTimeline()` invocations and clears it on `clearVMTimeline()` and `_cleanup()`
  so a polled-then-cleared timeline cannot leak begins into the next session.
- Per-tid cap of 100 (oldest-drop) prevents an unbounded begin from leaking memory if its end never
  arrives. Three new tests in `test/vm/timeline_parser_test.dart`: cross-batch reconstruction,
  fresh-default backward-compat (32 existing callers unchanged), cap overflow.

### Structural role plumbing (replaces filename-suffix heuristic)

- `Sleuth.exportCaptureJson` and `SleuthController.exportCaptureJson` take a required `role`
  parameter (`'below' | 'at' | 'above'`). The role is emitted into `sleuthMetadata.role` as a
  first-class structural field — no more filename-suffix sniffing.
- `ProfileCaptureSchema.parse` / `parseFile` enforce the role union and read the AB-1 inverse-ratio
  bypass directly from `sleuthMetadata.role == 'below'`. The `expectingNoEmission` shim from v0.18.2
  remains for the audit-test path; the schema now also accepts the role-driven equivalent so callers
  can drop the explicit shim.
- `tool/wrap_capture.dart` adds a `--role` CLI flag with filename-derived fallback (`_below.json` /
  `_at.json` / `_above.json`) so existing capture workflows keep working.
- `test/validation/_support/audit_invariants.dart` removed the `_below.json` filename heuristic and
  the TODO marker — `checkCapturePaths` now relies on the role field in metadata.
- 9 _fixtures captures + 6 production captures (heavy_compute / network_monitor below/at/above)
  backfilled with explicit `role` field. Anchor-fixture SHA pin updated to match the new bytes.

### Per-family-tier metadata (`lib/src/validation/detector_metadata.dart`)

- `DetectorMetadata.perStableIdTier: Map<String, EvidenceTier>?` lets a detector raise specific
  families above the base tier. Effective per-family tier is `perStableIdTier[id] ?? tier`;
  `effectiveMaxTier` drives the audit gate's tier-specific field-presence checks.
- New audit invariants: keys must be in `coveredStableIds`; values must be `>= tier` (raises only,
  never downgrades); when bracket fields are set, the `bracketStableId`'s effective tier must be
  `runtimeVerified` or stronger.
- `NetworkMonitorDetector` is the first user. Base tier drops to `reproducerOnly`;
  `perStableIdTier: {'slow_request': EvidenceTier.runtimeVerified}` preserves the on-device
  evidence guarantee. `coveredStableIds` now lists all five emitted families honestly. Layer 3
  reproducer tests credit the four newly declared families via AST-provable string literals.

### Removed

- `VmServiceClient.pollTimelineForTest` deprecated alias removed (long-dead testing-only
  symbol — all callers migrated to `pollTimelineSync`).

## 0.18.2

**Second `runtimeVerified` tier raise — `HeavyComputeDetector.heavy_compute` (warning tier, 8 ms threshold).** First vmOnly detector raised via the v0.18.1 `Sleuth.flushTimelineNow()` API. Distribution shifts to **21 / 23 at `reproducerOnly`, 2 / 23 at `runtimeVerified`, 0 / 23 at `unvalidated`**. Critical tier (16 ms) stays implicitly `unvalidated` until per-family-tier metadata extension lands.

### Capture infrastructure

- `TimelineParser` now reconstructs `BUILD` `dur` from `ph: 'B'` / `ph: 'E'` pairs (per-thread stack to handle interleaved threads). iOS profile mode emits BUILDs as begin/end pairs only — `ph: 'X'` complete-form BUILDs do not appear on iOS captures. Without this fix, `HeavyComputeDetector` saw zero BUILDs from real iOS captures and never emitted issue trace records. Fixes the structural blocker that deferred HeavyCompute from v0.18.0.
- `SleuthController.exportCaptureJson` magnitude derivation also handles B/E pair reconstruction (was X-only).
- `HeavyComputeDetector` issues now stamp `detectedAt` from `event.timestampUs` (`DateTime.fromMicrosecondsSinceEpoch(event.timestampUs)`) instead of `DateTime.now()`. Stable per-BUILD identifier so producer-side composite-key dedup collapses repeated observations of the same BUILD across polls. Eliminates re-emission inflation when stale BUILDs linger in the retained Timeline buffer across capture legs.
- `SleuthController.resetCaptureState` no longer clears `_captureEmittedKeys` (only clears per-detector record buffers like `NetworkMonitor.clearRecords`). The dedup set persists across scenarios so stale BUILDs in the retained Timeline buffer cannot false-positive into the next leg's scenario span. Stable per-event `detectedAt` (above) ensures legitimate new emissions are never suppressed.
- `ProfileCaptureSchema.parse` / `parseFile` accept `expectingNoEmission: true` (set by `validateBracket` on the below-leg). Skips the AB-1 inverse-ratio check whose 100× ceiling false-positives on below-leg semantics (sub-threshold workload paired with normal-sized scenario span including `flushTimelineNow` + dwell). `_requireNoIssueTraceRecord` enforces below-role honesty.
- `tool/wrap_capture.dart` and audit-test invariants thread `expectingNoEmission` through to honor the below-role exemption.

### Capture screen

- `example/lib/demos/heavy_compute_capture_screen.dart` restructured for the v0.18.1 `flushTimelineNow` pattern. `markScenarioBegin` + workload run inside `build()` so the BUILD timeline event encloses the workload; `await Sleuth.flushTimelineNow()` + 200 ms dwell + `markScenarioEnd` move into the `addPostFrameCallback` so the issue trace event lands inside the scenario span.
- Removed inline 5-retry auto-tune (polluted BUILD with cumulative warmup work). Each tap = one workload = one clean BUILD event. Adaptive learning happens across taps: each captured run's measured ms refines `_iterationsPerMs` so subsequent taps converge.
- Above-leg target lowered 13.5 ms → 12.5 ms so iPhone variance ±20% stays inside the (12, 15] above-band ceiling (was hitting the 16 ms critical threshold).
- `magnitudeSourceEventName: ''` skips `exportCaptureJson`'s BUILD derivation (workload BUILD's `B` event fires before `markScenarioBegin` — orphan E in span). Stopwatch measurement is the authoritative observed magnitude, mirroring NetworkMonitor's pattern.

### HeavyCompute metadata (`lib/src/detectors/heavy_compute_detector.dart`)

- `tier: EvidenceTier.runtimeVerified` (raised from `reproducerOnly`).
- `profileCapturePaths`: 3 captures (`heavy_compute_below.json`, `heavy_compute_at.json`, `heavy_compute_above.json`) under `test/validation/captures/heavy_compute/`. Recorded on iPhone 12 / iOS 17.5 / Flutter 3.41.x.
- `bracketStableId: 'heavy_compute'`, `bracketSeverityLabel: 'warning'`, `bracketThreshold: 8`, `bracketUnit: 'ms'`.
- `bracketAtTolerance: 0.50` (at-band [8, 12] ms; default ±10% unreachable due to iPhone CPU/thermal variance).
- `aboveCeilingMultiplier: 1.875` (above-ceiling 15 ms; clears 16 ms critical so above-leg cannot ambiently bracket critical).
- `coveredStableIds: {'heavy_compute'}`, `coveredThresholds: {'heavy_compute.warning'}`.
- `bracketRequireUniqueDetectedAtMicros: true` — opt into the v0.18.1 strong invariant so audit gate rejects single-issue replay forgery.

### Audit-gate ledger

- `test/validation/detector_metadata_audit_test.dart` gains `HeavyComputeDetector pinned at runtimeVerified (v0.18.2)` anchor pin (mirrors NetworkMonitor's anchor). HeavyCompute removed from `_v0174Expectations` (which pins the reproducerOnly batch).
- `_singleDetectorAnchors` includes `DetectorType.heavyCompute`.
- `doc/validation_ledger.md` summary line + HeavyCompute row updated.

### Tests

- 2,793 tests passing (was 2,791; added 2 parser B/E pair tests; replaced one expectation-flip test).
- `test/vm/timeline_parser_test.dart` gains `Begin/End BUILD pairs reconstruct PhaseEvents (iOS profile mode)` + `Begin/End BUILD pairs across threads do not cross-contaminate`.
- `test/validation/profile_capture_schema_test.dart` gains the v0.18.1 strong-invariant tests (rejects synthetic replay; rejects stripped-args forgery).

### Behavioural changes (iOS dev/profile-mode users)

The parser B/E reconstruction (above) closes a gap that left every iOS profile-mode session blind to BUILD events. Three OTHER detectors that consume `data.phaseEvents.where(phase == build)` are now exercised on iOS where they previously emitted nothing:

- `RebuildDetector` — surfaces builder-rebuild patterns from iOS BUILDs whose B-event args carry `build scope dirty list`.
- `RepaintDetector` — observes paint-phase phaseEvents.
- `ShallowRebuildRiskDetector` — observes BUILD events as a corroboration signal alongside its existing `buildEventCount` consumption.

iOS dev/profile builds that previously appeared clean may now show new issue cards from these detectors. The issues were always present; the parser just couldn't see iOS BUILDs. This is correct behaviour, not a regression. Production release builds are unaffected (Sleuth as a whole is gated on `kReleaseMode`).

### Known limitations

- HeavyCompute critical tier (16 ms) remains implicitly `unvalidated` — `DetectorMetadata` carries one tier per detector instance. Per-family-tier metadata extension deferred. Raising critical to `runtimeVerified` would require 3 additional on-device captures bracketing 16 ms.
- `HeavyComputeDetector._createGenericIssue` (fallback path for raw `buildScopeDurations` without `phaseEvents`) still uses `DateTime.now()` for `detectedAt` because no source-event timestamp is available. iOS profile-mode captures take the enriched path (B/E reconstruction populates `phaseEvents`), so this fallback does not affect runtimeVerified evidence quality in practice. Future runtimeVerified raises that exercise this fallback path must replace `DateTime.now()` with a stable identifier first.
- Parser B/E reconstruction handles BUILD only. iOS profile-mode emits LAYOUT, PAINT, RASTER, SHADER as B/E pairs too. Future runtimeVerified raises of detectors consuming those phases (e.g., ShaderJank's `shaders` list) will need parser extension first.
- Below-leg AB-1 bypass uses a filename-suffix heuristic (`_below.json`) inside `checkCapturePaths`. New runtimeVerified detectors that violate the naming convention would either false-fail (suffix mismatch) or false-pass (suffix coincidence). v0.18.3 should plumb role explicitly through the metadata.
- Above-leg framework BUILD wire duration includes overhead beyond the workload's Stopwatch measurement (setState bookkeeping, child rebuilds). On iPhone 12 / iOS 17.5 the overhead is small enough that the observed (Stopwatch) and BUILD wire dur stay on the same severity tier. On other devices, BUILD wire dur could exceed 16 ms and trigger critical instead of warning. Capture procedure docs updated to note this — operators who hit "Missing detector trace record" on above-leg should lower the workload target.

---

## 0.18.1

**Hardening release fulfilling the v0.18.0 commitment** — closes four architectural items + three procedural items required before any other vmOnly detector tier raise. Distribution unchanged: **22 / 23 at `reproducerOnly`, 1 / 23 at `runtimeVerified`**. v0.18.2+ tier raises (HeavyCompute, ShaderJank, MemoryPressure, GpuPressure, PlatformChannel) now have the infrastructure they need.

> **Single-issue replay protection ON by default for NetworkMonitor.** `validateBracket` gains `requireUniqueDetectedAtMicros: true` (opt-in via `DetectorMetadata.bracketRequireUniqueDetectedAtMicros`). NetworkMonitor's triad was re-recorded under v0.18.1 producer-side dedup (3 distinct captures: below 815 ms / 0 records, at 1030 ms / 1 record / 1 unique microsecond, above 1501 ms / 1 record / 1 unique microsecond) and the metadata opts in. The audit gate now rejects any capture replay (N records sharing one `detectedAtMicros`) for NetworkMonitor's `slow_request.warning` claim. v0.18.2+ vmOnly tier raises (HeavyCompute, ShaderJank, etc.) should opt in at metadata-flip time.

### Public API

- `Sleuth.flushTimelineNow({Duration? timeout})` — synchronous VM-timeline poll + drain of any pending detector issue-record emissions before the returned Future completes. Caller MUST `await`. Designed for the vmOnly capture procedure: `markScenarioBegin → workload → await flushTimelineNow → markScenarioEnd` so vmOnly detector traces (HeavyCompute, ShaderJank, MemoryPressure, GpuPressure, PlatformChannel) land inside the scenario span instead of post-dating it on the next 500 ms poll tick. Triple-gated like `markScenarioBegin/End`; production sessions pay zero overhead. Optional `timeout` parameter throws `TimeoutException` on unresponsive VM.

### Internal contracts

- `SleuthController._recordIssuesForCapture` now dedupes emissions by composite key `'<detectorRuntimeType>|<stableId>|<severity>|<detectedAtMicros>'`. Without dedup, the VM polling cadence (~500 ms) re-emits the same issue at every poll tick within a single scenario span, producing inflated trace records that defeat downstream uniqueness analysis. Dedup set cleared by `markScenarioBegin` AND by the new `SleuthController.resetCaptureState()` method (called automatically inside `markScenarioBegin`).
- `SleuthController.resetCaptureState()` — clears the dedup set AND per-detector record buffers (`NetworkMonitor.clearRecords`, plus equivalents for future runtimeVerified detectors). Multi-leg capture flows (Below → At → Above on a single screen) no longer leak leg N records into leg N+1 emissions; `markScenarioBegin` invokes this automatically so screens following the standard pattern get the reset for free.
- `VmServiceClient.pollTimelineSync()` — public name for the previously test-only `pollTimelineForTest`. Capture procedure depends on this synchronously. The `pollTimelineForTest` alias is retained as `@Deprecated` for one release for existing test-code callers.

### Schema validation (`profile_capture_schema.dart`)

- `validateBracket` gains optional `requireUniqueDetectedAtMicros: true` parameter (default `false`). When enabled, every in-span `sleuth.issue.<stableId>.<severity>` instant event in the at + above captures must carry a distinct `detectedAtMicros` arg. Rejects single-issue replay (N records all stamped with one microsecond) AND emission inflation from binaries lacking the producer dedup. Failure message names the file and the inflation count for direct re-recording guidance.
- `DetectorMetadata.bracketRequireUniqueDetectedAtMicros` (default `false`) — per-detector opt-in for the strong invariant. Audit test plumbs the flag through `checkBracketValidation` → `validateBracket`. NetworkMonitor opts in starting v0.18.1; v0.18.2+ tier raises should opt in at metadata-flip time once their captures are recorded under producer dedup.

### Captures

- NetworkMonitor `slow_request_{below,at,above}.json` re-recorded on v0.18.1 binary (iPhone 12 / iOS 17.5 / Flutter 3.41.x). Producer dedup yields 0 / 1 / 1 records respectively, each with a unique `detectedAtMicros`. Magnitudes: below 815 ms (sub-1000 ms threshold), at 1030 ms (in [1000, 1100] band), above 1501 ms (in (1000, 2000] above-ceiling).

### Audit gate documentation

- `test/validation/detector_metadata_audit_test.dart` — explicit comment block above `tier-appropriate fields are populated` documenting that the `checkBracketValidation(... requireTraceRecord: true)` invocation IS the v0.18.0 hardening commitment item 4 ("CI audit gate against tree-state vs claim drift"). New regression-guard test (`audit gate is wired for every runtimeVerified detector`) structurally pins the expectation so a future refactor that drops `validateBracket` from the runtimeVerified branch fails CI before merge.

### Capture procedure docs (`doc/capture_procedure.md`)

- HeavyCompute deferred section replaced with the v0.18.1 vmOnly pattern using `flushTimelineNow`.
- New "Multi-leg recovery" subsection — `markScenarioBegin` auto-resets producer state, so contributors following the procedure should NOT need to kill-and-restart between legs. Cold-launch documented as a fallback only, for VM-service-wedged states (thermal throttle, crashed background isolate, dropped USB wireless link).
- Common failure modes table extended with the inflation-rejection diagnostic.

### Deferred to v0.18.2+

- **Pre-commit hook**: the v0.18.0 CHANGELOG cited "pre-commit/CI audit gate." The CI audit gate is now in place (steps above) and runs on every PR via `fvm flutter test`; the local pre-commit variant adds friction without catching anything CI does not, so it is deferred. Re-evaluate if drift incidents recur.
- (none — Step 7 NetworkMonitor recapture + strong-invariant opt-in landed in v0.18.1; see "Captures" above.)

---

## 0.18.0

**First `runtimeVerified` tier raise — `NetworkMonitorDetector.slow_request` (warning tier, 1000 ms threshold).** Three real on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.x) recorded via the new in-app capture procedure. Distribution: **22 / 23 at `reproducerOnly`, 1 / 23 at `runtimeVerified`, 0 / 23 at `unvalidated`**. Critical tier (3000 ms) stays `reproducerOnly`.

### Capture infrastructure (Phase A)

- `Sleuth.markScenarioBegin(name)` / `Sleuth.markScenarioEnd(name)` — public API emitting `sleuth.scenario.begin` / `sleuth.scenario.end` instant trace events. Triple-gated on `kReleaseMode`, `SleuthConfig.captureMode`, and non-null name; production sessions never emit. Markers pin the scenario span the audit gate uses to scope detector trace records.
- `Sleuth.exportCaptureJson(...)` — public API composing a wrapped capture JSON from the VM Timeline buffer. Filters events to the matching scenario span by `args.name` (not just by event-name string), derives `expectedMagnitude.observed` from in-span events of the named source (`magnitudeSourceEventName` parameter, defaults `'BUILD'`), wraps with `sleuthMetadata` (schemaVersion `'v1'`). Returns a String the caller writes / shares however they want; library does no file I/O.
- `VmServiceClient(retainTimeline: true)` — wired automatically when `SleuthConfig.captureMode: true`. The polling loop skips `clearVMTimeline()` so a later `exportCaptureJson` call can still see scenario-span events that the polling loop already processed. Production sessions clear after every poll.
- `VmServiceClient.fetchRawTimelineEventsJson()` — non-clearing snapshot of the trace buffer, returning Chrome Trace Event Format JSON-encodable maps.
- `CaptureHelper.recordIssue` + `CaptureHelper.composeIssueEvent` — shared format constants (`capture_event_constants.dart`) define the wire format `sleuth.issue.<stableId>.<severity>` instant events that `_recordIssuesForCapture` emits. The schema parser and emitter route through the same constants; the cross-check round-trip test pins emitter↔parser agreement.

### Schema validation (`profile_capture_schema.dart`)

- `validateBracket(...)` accepts `requireDetectorTraceRecord: true` + `stableId` + `severityLabel` + `atTolerance` parameters. The trace-record gate searches each capture for a `sleuth.issue.<stableId>.<severity>` instant event whose `ts` lies inside the scenario marker span; warning-tier audits reject `.critical` events and vice versa.
- `schemaVersion: 'v1'` field required in `sleuthMetadata` when `requireDetectorTraceRecord: true`.
- `above.observed > at.observed` invariant added — schema rejects semantically inverted triads (at/above bands can overlap when atTolerance is wide; the ordering invariant catches the inversion that bracket math alone misses).
- Severity-scoped trace-record matching — single severity per call, no warning-OR-critical fallback.

### Detector metadata (`detector_metadata.dart`)

- `bracketStableId` + `bracketSeverityLabel` fields — required at `runtimeVerified` so the audit gate can search for the matching trace record.
- `bracketAtTolerance` field — per-detector at-band relative tolerance. Defaults to schema's 0.10 when null.

### Capture procedure tooling

- `tool/wrap_capture.dart` — CLI for wrapping raw DevTools timeline JSON exports with `sleuthMetadata`. New flags: `--severity-boundary <ms>` (repeatable; refuses captures whose observed/BUILD pair straddles a detector severity threshold), `--force` (override safety checks). BUILD-event cross-check rejects observed/BUILD divergence beyond ±10%. Refuses to clobber existing output, refuses double-wrap, refuses `--input` == `--output`.
- `example/lib/demos/network_monitor_capture_screen.dart` — drives the capture procedure end-to-end. Loopback HTTP server delivers deterministic delays (800 / 1020 / 1500 ms); operator taps a leg, scenario markers fire, request runs, 200 ms post-completion dwell lets `_recordIssuesForCapture` flush the trace event into the buffer inside the scenario span, then `markScenarioEnd` closes the span. Export button calls `Sleuth.exportCaptureJson` and copies the wrapped JSON to the iOS clipboard. Operator pastes into Notes / Mail / AirDrop note → sends to Mac.
- `example/lib/main.dart` — `--dart-define=SLEUTH_CAPTURE_MODE=true` enables capture mode. `enableDebugCallbacks` and `enableDeepDebugInstrumentation` are gated off in capture mode so BUILD events arrive as sync `'X'` (with `dur`) instead of async `'b'/'e'` pairs.

### NetworkMonitorDetector tier raise

- `validationMetadata` flipped: `tier: runtimeVerified`, `bracketStableId: 'slow_request'`, `bracketSeverityLabel: 'warning'`, `bracketThreshold: 1000`, `bracketUnit: 'ms'`, `aboveCeilingMultiplier: 2.0` (above-ceiling 2000 ms stays clear of 3000 ms critical), `profileCapturePaths: [3 captures]`, `coveredThresholds: {'slow_request.warning'}`.
- Three captures at `test/validation/captures/network_monitor/slow_request_{below,at,above}.json`: below 809 ms (sub-threshold, no detector emission), at 1024 ms (in `[1000, 1100]` at-band, 3 trace records inside scenario span), above 1503 ms (in `(1000, 2000]` warning band, 14 trace records inside scenario span).

### Documentation

- `doc/capture_procedure.md` — end-to-end capture procedure for v0.18.0+ runtimeVerified raises. Documents the USB-with-app-relaunch flow needed when DevTools holds the VM service subscription on first launch, the `200 ms post-completion dwell before markScenarioEnd` to land the issue trace event inside the scenario span, the iOS clipboard export, and the multi-leg state-contamination caveat (kill the app and start fresh between sessions if a leg failed or was retried).
- `doc/validation_ledger.md` — distribution updated to 22/23 reproducerOnly + 1/23 runtimeVerified.

### v0.18.1 hardening (committed)

The current procedure for `runtimeVerified` raises is fragile in three ways. None corrupt the v0.18.0 evidence chain (the three captures verified-valid, audit gate passes, trace records are real detector emissions inside the scenario span), but they limit reproducibility for future captures and other detector raises. v0.18.1 will land:

1. **`Sleuth.flushTimelineNow()` API** — synchronous VM Timeline poll + detector emit + return. Required for all future runtimeVerified raises so issue trace events land inside the scenario span deterministically rather than via the timing-dependent dwell.
2. **Audit gate dedupe by `args.detectedAtMicros`** — `_recordIssuesForCapture` re-emits every current detector issue on every callback, so a single issue can produce dozens of trace events with identical `detectedAtMicros`. The audit gate will dedupe by that field and require ≥1 unique value created INSIDE the scenario span (proves issue was detected during the span, not just re-emitted there).
3. **Per-leg detector state reset** — capture screens call `clearRecords()` on the relevant detector before each leg so stale state from prior recordings cannot leak into the next leg's trace.
4. **Pre-commit / CI audit gate** — runs `validateBracket(... requireDetectorTraceRecord: true)` on every detector's `profileCapturePaths` automatically. Catches tree-state vs. claim drift (the kind of orchestration mistake where `profileCapturePaths` references files that don't actually contain v1-conformant content).
5. **Multi-leg contamination warning** — capture procedure doc adds explicit "kill the app and start fresh from step 1 if a leg fails or is re-tapped" guidance.
6. **Re-emission inflation guard** — `_recordIssuesForCapture` will dedupe by issue identity so the VM trace buffer doesn't fill linearly with span duration.

Until v0.18.1 lands, **no other vmOnly detectors should raise to `runtimeVerified`** — HeavyCompute, ShaderJank, MemoryPressure, GpuPressure, and PlatformChannel all hit the polling-cadence emission-timing constraint that the dwell pattern only sidesteps for runtime-lifecycle detectors with naturally long scenario spans (NetworkMonitor's 1+ second HTTP requests). HeavyCompute deferred specifically — see "Deferred to v0.18.1+" section in `doc/capture_procedure.md`.

## 0.17.6

**Tier-quality audit — hybrid batch (final 2 of 8).** Purpose-rewrote `RepaintDetector` and `RebuildDetector` with hermetic reproducers at `test/validation/{repaint,rebuild}_reproducer_test.dart`. Both detectors are hybrid — VM `processTimelineData` + DebugSnapshot per-widget + structural fallback. Reproducers exercise all paths in one file via cross-harness composition (`vm_reproducer_harness` + `structural_reproducer_harness` imported together; matchers re-exported via `show` so no symbol conflict). Tier unchanged (`reproducerOnly`); evidence strength improved for the final 2 of 8 v0.17.2-batch detectors. Stratum-1 coverage now 8/23 detectors, up from 6/23 at v0.17.5. The "reused unit-test suites" stratum is empty — every detector now either drives a parser/transport boundary, exercises a direct production entrypoint with disclosed skipped hops (MemoryPressure), or pumps a real widget tree (13 structural detectors). Tier-quality audit complete.

### Added

- `test/validation/repaint_reproducer_test.dart` — 19 tests across 8 axes:
  - VM aggregate `excessive_repaint` triad (strict `> 30/sec`: 30 → no fire, 31 → warning, 61 → critical at `> 2×`).
  - **Enrichment plumbing** — PAINT events with `args: {'dirty count': '5'}` exercise `TimelineParser._parseIntArg` → `PhaseEvent.dirtyCount` → detector's `_pendingEnrichedDirtyTotal` → atomic stage with window count → enriched detail suffix in emitted issue.
  - **Exact-1000ms boundary** — staging gate is `>= 1000ms`. A regression flipping to strict `>` would only fail at the boundary; reproducer pins the boundary explicitly.
  - Aggregate-debug `excessive_repaint_debug` triad (residual rate `>= 30/sec`: 29/30/61) — `vmConnected=false` routes the snapshot through the aggregate-debug path.
  - Per-widget `repaint_debug_<typeName>` triad (residual rate `>= 30/sec`: 29/30/61).
  - **Gate B animation-owned suppression** pinned with three configurations: (a) all paints owned (broad `expect(issues, isEmpty)` — regression cannot leak through any of the three emission paths simultaneously), (b) partial ownership (residual fires per-widget), (c) **mixed-type ownership** — Spinner fully owned + Chart unowned with sub-threshold residual; `_allPaintsAnimationOwned` AND-semantics returns false → VM fallback fires. Single-type fixture cannot distinguish AND from OR; mixed-type pins the iteration semantics.
  - **Reconnect-flush** — disconnect after VM emission then reconnect; cold-init false→true stages `_pendingVmWindowCount=0` so the first post-reconnect `_evaluate` clears prior issues.
  - **Highlights** — severity correlation between issue and `WidgetHighlight`, plus `_maxHighlightsPerType=3` cap proven by mounting 5 instances of one type and asserting only 3 highlights emit.

- `test/validation/rebuild_reproducer_test.dart` — 25 tests across 11 axes:
  - VM aggregate `rebuild_activity` triad (strict `> 10/sec`: 10/11/31, critical at `> 3×`).
  - **Enrichment plumbing** — BUILD events with `args: {'build scope dirty list': '[Foo, Bar]'}` exercise `TimelineParser._parseDirtyList` → `PhaseEvent.dirtyList` → detector's `_pendingEnrichedNames` → top-3 dirty-widget detail suffix.
  - **Exact-1000ms boundary** — same `>= 1000ms` staging gate pinned for the rebuild detector.
  - Per-widget non-builder `rebuild_debug_<typeName>` triad (rate `>= 10/sec`: 9/10/31).
  - Per-widget builder `rebuild_debug_StreamBuilder` triad (rate `>= 30/sec`, 3× multiplier: 29/30/91).
  - **Builder-multiplier paired evidence** — at the SAME rate=25/sec, `MyWidget` fires (25 > 10) and `StreamBuilder` is suppressed (25 < 30). Without the paired test the multiplier could be a coincidental gate; this pins the threshold-shift behaviour.
  - **Source-mode `RebuildCountSource.flutterTimeline`** per-type suppression (KDD-5: profile-mode counts include initial widget inflations, so per-type emission is gated off; default `RebuildCountSource.none` keeps the per-type path live for backwards-compat with pre-v15 const-literal fixtures). Both branches pinned: flutterTimeline at warning rate → no fire, default source at same rate → fires.
  - Structural-fallback `stateful_density` triad — 11 public-named StatefulWidgets fires warning at `vmConnected=false`, 9 stays below threshold, 30 private-named (`_`-prefix) widgets are filtered out.
  - Reconnect-flush for VM emission path.
  - `_maxHighlightsPerType=3` cap pinned.
  - **Highlight ↔ issue parity** (Group G) — 2 tests: (a) flutterTimeline source: both `issues` empty AND `highlights` empty (regression that derives `_hotTypes` without source filtering would paint hot-widget overlays alongside the suppressed issue); (b) `AnimatedBuilder` at rate=35: both issue severity AND highlight severity warning (regression using `rebuildsPerSecThreshold * 3` instead of `effectiveThreshold * 3` would over-escalate the highlight to critical 60 units before the issue).
  - **Stale VM stage replay** (Group H) — flutterTimeline + VM-staged in tick 1: next empty scan does NOT replay `rebuild_activity` from the staged window. Pins the unconditional `_pendingVmWindowCount = null` clear in `_evaluate`'s fresh-debug branch.

All "no-fire" boundary tests use broad `expect(issues, isEmpty)` rather than narrow `lacksStableId('X')` so a regression introducing a new bogus stableId would fail. All "fires" tests assert `expect(issues, hasLength(1))` so a regression that double-emits would fail.

### Fixed

- **`RebuildDetector` highlight emission diverged from issue gate on two axes.** `_hotRebuildTypes` (rebuild_detector.dart:213) iterated `snapshot.rebuildCounts` without checking `snapshot.source`, so a `flutterTimeline` snapshot painted hot-widget overlays even though `_evaluate` correctly suppressed the issue (KDD-5 inflation gate). Added the source-mode skip at the top of `_hotRebuildTypes`. Separately, `checkElement` (rebuild_detector.dart:190) computed highlight critical severity using `rebuildsPerSecThreshold * 3` (= 30) regardless of builder status; for builder widgets the issue path uses `effectiveThreshold * 3` (= 90). At rate=35 a builder widget's highlight escalated to critical while the issue stayed warning. `checkElement` now reads `_builderWidgetTypes` membership through the canonicalized base name and uses the same `effectiveThreshold * 3` gate as `_evaluateDebugData`. Highlight ↔ issue parity reproducer tests (Group G) pin both axes.
- **`RebuildDetector` consumed staged VM data even when no signal needed it** (rebuild_detector.dart:282-326). Combined fix for two related bugs in `_evaluate`'s fresh-debug branch: (a) the `flutterTimeline + totalRebuilds > 0 + hasFreshVm` fall-through path left `_pendingVmWindowCount` staged, so the next scan replayed it as `rebuild_activity` after enrichment + tree context had been discarded — ghost issue surfacing 1+ seconds late, often after navigation; (b) when `_evaluateDebugData` ran on a non-flutterTimeline snapshot but no individual type crossed its per-type threshold (rebuild storm spread across many sub-threshold types), the unconditional VM clear silently dropped a real `rebuild_activity` signal. The fresh-debug branch now (i) calls `_evaluateVmData` as a same-tick fallback when `_evaluateDebugData` emits nothing AND VM has staged data, and (ii) clears `_pendingVmWindowCount` unconditionally so flutterTimeline+VM cannot leave stale state. Stale-replay reproducer test (Group H) and same-tick-fallback reproducer test (Group I) pin both contracts.
- **Generic builder type names bypassed the 3× threshold multiplier** (rebuild_detector.dart:191, 221, 326-329). `_builderWidgetTypes` set has bare names (`'StreamBuilder'`, `'FutureBuilder'`, `'ValueListenableBuilder'`, etc.). Debug-callback `_rebuildCounts` is keyed by raw `runtimeType.toString()` (no canonicalization in this path); production widgets surface as `StreamBuilder<int>`, `FutureBuilder<DataModel>`, etc. `_builderWidgetTypes.contains('StreamBuilder<int>')` returned false → builder fired at the non-builder threshold (10/sec instead of 30/sec) and escalated critical at 30/sec instead of 90. Three call sites in `RebuildDetector` (issue path, highlight Priority 1, highlight severity) now route through `baseTypeName(...)` before the set lookup. New `baseTypeName(String)` helper exported from `lib/src/utils/type_name_cache.dart`. Generic-builder canonicalization reproducer tests (Group J) pin the fix with `StreamBuilder<int>` at warning + just-below-threshold rates.
- **`ShallowRebuildRiskDetector` framework allowlist bypassed `_ModalScope<dynamic>`** (shallow_rebuild_risk_detector.dart:109). Same generic-suffix pattern as the builder bug. The allowlist set contained bare `'_ModalScope'`; production `_ModalScope<dynamic>` arriving from `typeNameCache.lookup` failed the `contains(name)` check. Every Navigator route then materialised a shallow Stateful that the filter should have excluded, blaming Flutter's own modal-scope infrastructure for `shallow_rebuild_risk` warnings. Now uses `baseTypeName(name)` before the set lookup. Reproducer mounts a fixture matching the production runtime-type shape (`_ModalScope<int>`) at shallow depth and asserts the issue does not fire.
- **`SetStateScopeDetector` animation-scope suppression missed generic `ValueListenableBuilder<T>` / `ListenableBuilder<T>`** (setstate_scope_detector.dart:421). The fallback name-equality check (`name == 'ValueListenableBuilder'`) failed for production runtime types (`ValueListenableBuilder<int>` etc.), so notifier-driven pages reported false-positive `setstate_scope` warnings. Now canonicalizes via `baseTypeName(...)` before equality. Note the line-414 `el.widget is AnimatedWidget` type-test correctly catches generic `AnimatedBuilder<T>` etc. without name comparison and was unaffected. Reproducer mounts a wide subtree containing `ValueListenableBuilder<int>` and asserts the issue stays suppressed.

### Changed

- 2 detector `validationMetadata` blocks: `reproducerPath` flipped from `test/detectors/*_detector_test.dart` to `test/validation/*_reproducer_test.dart`. Rationales rewritten to (a) state the parser-boundary leg is now exercised, (b) name every gate the reproducer pins, (c) explicitly call out Gate B (Repaint) and the builder-multiplier paired evidence (Rebuild) so a regression that breaks the rationale's pinned behaviour is visible at the rationale level.
- 2 anchor entries flipped in `test/validation/detector_metadata_audit_test.dart` `_v0174Expectations` map (DetectorType.repaint line 173, DetectorType.rebuild line 178). Atomic update with the detector source.
- `doc/validation_ledger.md` — 2 row rationales rewritten. Stratum classification at top updated from three to two strata (the "reused unit-test suites" stratum is now empty). Version-history block adds v0.17.6 entry; `← current release` marker moved from v0.17.5 to v0.17.6.

### Notes

- Existing `test/detectors/{repaint,rebuild}_detector_test.dart` unchanged (additive-only invariant — the original unit tests still pass and remain useful for fast iteration on detector internals).
- `_vmConnected` defaults to false in both detectors; reproducer setUp blocks explicitly set true with comment naming the precondition. Otherwise VM-backed tests would silently fall into structural fallback (high-likelihood failure mode caught during plan review on the v0.17.4 / v0.17.5 batches).
- `processTimelineData` stages `_pendingVmWindowCount` only when the call's elapsed timestamp ≥ 1000 ms past `_windowStart`. Reproducer advances the fake clock by 1100 ms BEFORE each `processTimelineData` call so a single call closes the window atomically — no two-call helper needed.
- `fvm flutter analyze` clean, `fvm flutter test` all green.

## 0.17.5

**Tier-quality audit — hybrid batch (2 of remaining 4).** Purpose-rewrote `GpuPressureDetector` and `ShallowRebuildRiskDetector` with hermetic reproducers at `test/validation/{gpu_pressure,shallow_rebuild_risk}_reproducer_test.dart`. Both detectors are hybrid — VM `processTimelineData` + structural `scanTree` legs both fire emission paths. Reproducers exercise both legs in one file via cross-harness composition (`vm_reproducer_harness` + structural harness imported together; matchers re-exported via `show` so no symbol conflict). ShallowRebuildRisk adds a third leg pinning DebugSnapshot confidence-upgrade ordering. Tier unchanged (`reproducerOnly`); evidence strength improved for 6 of 8 v0.17.2-batch detectors. Remaining 2 (Repaint + Rebuild) queued for v0.17.6.

### Added

- `test/validation/gpu_pressure_reproducer_test.dart` — 22 tests across 4 axes:
  - `raster_dominance` VM ratio triad (1.99 / 2.0 / 2.01) + critical at `> 4.0` + `hasRasterTiming` precondition (zero-UI negative control proves the gate isn't just `vmConnected`).
  - Structural matrix over 4 RenderObject checks plus 1 widget-level check: `RenderOpacity` (4-axis: opacity-value × subtree — opacity=0.0 / 1.0 short-circuit suppressed even with deep subtree, opacity=0.5 + small subtree suppressed by subtree gate, opacity=0.5 + deep subtree fires), `RenderBackdropFilter` 3-band sigma (≤2.0 suppressed, (2.0, 10.0] warning highlight, >10.0 critical highlight — `expensive_gpu_nodes` issue severity stays `warning`; only the corresponding `WidgetHighlight` entry escalates to critical), `RenderClipPath`, `RenderShaderMask`, plus `element.widget is ColorFiltered` (no public RenderObject type for ColorFiltered).
  - Nested expense node test (Opacity wrapping Opacity) verifies subtree-stack arithmetic — both inner and outer accumulate correctly.
  - Confidence correlation matrix: `expensive_gpu_nodes.confidence` is `likely` only when `hasRasterDominance` true; `possible` in 3 sub-cases (vmConnected=false; vmConnected=true + no raster events; vmConnected=true + ratio ≤ 2.0).
  - VM-disconnect downgrade: setter removes `raster_dominance` and downgrades `expensive_gpu_nodes` confidence in-place.

- `test/validation/shallow_rebuild_risk_reproducer_test.dart` — 12 tests across 5 axes:
  - **Three gate states pinned exhaustively**: (1) vmConnected=true + buildCount=20 → no fire (strict `>20`); (2) vmConnected=true + buildCount=21 → fire warning/possible; (3) vmConnected=false → structural fallback fire ("VM unavailable" detail); **(4) vmConnected=true + buildCount=15 → silent no-fire** (activity-low branch — regression that flips gate to `>=` shows up here only).
  - Structural depth threshold default 3 pinned at boundary (depth 3 fires inclusive, depth 4 does not).
  - Framework allowlist (13 names) verified by Navigator-only tree producing zero usages.
  - DebugSnapshot confidence upgrade with explicit ordering pin (`updateDebugSnapshot` BEFORE `scanAndIssues`) + rate=0 negative case proving `rebuildsPerSecond > 0` gate.
  - VM-disconnect immediate-effect contract (`_lastBuildCount` + `_issues` cleared synchronously).

### Changed

- 2 detector `validationMetadata` blocks: `reproducerPath` flipped from `test/detectors/*_detector_test.dart` to `test/validation/*_reproducer_test.dart`. Rationales rewritten to enumerate every gate explicitly. GpuPressure rationale names 4 RenderObject checks + 1 widget-level (`ColorFiltered`) check + opacity-value short-circuit + sigma 3-band (with the highlight-severity-only critical escalation made explicit) + confidence correlation. ShallowRebuildRisk rationale names all 3 gate states + depth threshold + 13-name allowlist (Navigator-only test coverage; other 12 entries implicitly uncovered) + DebugSnapshot ordering requirement + VM-disconnect immediate-effect.
- 2 anchor entries flipped in `test/validation/detector_metadata_audit_test.dart` `_v0174Expectations` map (DetectorType.gpuPressure line 168, DetectorType.shallowRebuildRisk line 183). Atomic update.
- `doc/validation_ledger.md` — 2 row rationales rewritten. Version-history block adds v0.17.5 entry; `← current release` marker moved from v0.17.4 to v0.17.5.

### Notes

- Existing `test/detectors/{gpu_pressure,shallow_rebuild_risk}_detector_test.dart` unchanged (additive-only invariant).
- `_vmConnected` defaults to false in both detectors; reproducer setUp blocks explicitly set true with comment naming the precondition. Otherwise VM-backed tests would silently fall into structural fallback (high-likelihood failure mode caught during plan review).
- `BackdropFilter` requires a `Stack` ancestor for the engine to materialise the blur layer; without it Flutter substitutes a non-blur RenderObject and `is RenderBackdropFilter` fails. Reproducer fixture wraps in `Stack`.
- `Stack` import collision between `flutter/widgets` and `vm_service` resolved via `import 'package:vm_service/vm_service.dart' hide Stack;`.
- `fvm flutter analyze` clean, `fvm flutter test` all green.

## 0.17.4

**Tier-quality audit — vmOnly batch (4 of 8).** Purpose-rewrote the 4 vmOnly reproducers pointed at `test/detectors/*_detector_test.dart` by v0.17.2 with hermetic reproducers at `test/validation/*_reproducer_test.dart`. Tier unchanged (`reproducerOnly`); evidence strengthened — vmOnly reproducers now feed raw `List<TimelineEvent>` through real `TimelineParser.parse()` into the detector, exercising the VM → parser → detector boundary that the original v0.17.2 fixtures bypassed by hand-constructing `ParsedTimelineData` directly. Remaining 4 detectors (2 hybrid + 2 structural) stay on v0.17.2 fixtures until v0.17.5 / v0.17.6.

### Added

- `test/validation/_helpers/vm_reproducer_harness.dart` — shared harness for vmOnly / hybrid reproducer tests. Exports `buildEvent()` wrapping `TimelineEvent.parse` with a `!` assertion (malformed JSON fails loudly, not silently) and `parseAndAssertShape(events, expected)` — runs events through `TimelineParser.parse()` and asserts the output matches a `ParsedShape` record exactly. Any silent drop (unknown name casing, wrong phase code, missing `dur` on `'X'`) fails the test with a pointer at the mismatch instead of letting a reproducer appear to misbehave downstream.
- `test/validation/shader_jank_reproducer_test.dart` — 100 ms inclusive duration triad + 2× critical + Impeller-zero suppression via consecutive empty polls + shader-name variant coverage (`ShaderCompilation`, `Pipeline::Create`, lowercase).
- `test/validation/heavy_compute_reproducer_test.dart` — 8 ms strict duration triad + 2× critical (16001µs) + 2× warning-boundary pin (16000µs exactly, strict-greater critical escalation). All three emission paths covered: enriched `_createIssue` ("Heavy Build:" + dirtyList parsed from `'build scope dirty list'` arg), unenriched `_createIssue` ("Heavy Computation:" with `ts`), and fallback `_createGenericIssue` (BUILD event without `ts` — parser populates `buildScopeDurations` but skips `phaseEvents`, detector takes raw-durations branch).
- `test/validation/platform_channel_reproducer_test.dart` — both emission axes pinned independently. Frequency axis: >20/sec strict triad + 2× critical at 41 calls + 40 calls held at warning (critical-escalation inequality). Duration axis: >8000µs cumulative per 1s window strict triad at 7998/8000/8001µs using 3 sync `'X'` events (isolates duration from frequency axis — the original reproducer covered only frequency). Both parser-accepted phase variants covered: lowercase async `'b'` (real `debugProfilePlatformChannels` output via `TimelineTask`) and sync `'X'` with `MethodChannel` name. Uppercase sync `'B'` async-shaped events asserted non-emitting — the canonical format-boundary trap for channel observers (CLAUDE.md §"Dart VM Timeline event formats").
- `test/validation/memory_pressure_reproducer_test.dart` — 4 stableIds pinned at detector entrypoints (`processHeapSample` + `recordGcCycle`): `gc_pressure` (>5 cycles / 10 s sliding window = >30/min, with age-out), `heap_growing` (slope >512 KB/s sustained ≥10 s), `heap_near_capacity` (>80% AND 4-of-5 samples AND correlated `heap_growing`), `native_memory_growing` (RSS-heap gap >1 MB/s sustained ≥10 s). Null-`rssBytes` (web) + zero-heap + zero-capacity null-coalesce edges asserted non-emitting.

### Changed

- Anchor block `_v0172Expectations` → `_v0174Expectations` in `test/validation/detector_metadata_audit_test.dart`. Documents the v0.17.2 initial raise and v0.17.4–v0.17.6 reproducer-rewrite lifecycle. Test description renamed from `'v0.17.2 vmOnly + hybrid batch pinned at reproducerOnly'` to `'v0.17.4+ reproducer-rewrite batch pinned at reproducerOnly'`.
- 4 detector `validationMetadata.reproducerPath` fields flipped from `test/detectors/*_detector_test.dart` to `test/validation/*_reproducer_test.dart` (ShaderJank, HeavyCompute, PlatformChannel, MemoryPressure). Rationales rewritten to describe the TimelineParser-boundary exercise.
- MemoryPressureDetector rationale explicitly discloses three upstream hops skipped by the reproducer: (1) `VmServiceClient.getMemoryUsage` `null → 0` repack (zero-coalesce edge exercised; repack itself is not); (2) `EventStreams.kGC → _onGcEvent → recordGcCycle` (called directly, bypassing VM-service stream plumbing — TimelineParser's over-counting `gcEvents` list is NOT used by this detector); (3) `VmServiceClient._readRssBytes() → ProcessInfo.currentRss` is the OS-level RSS collection boundary sourcing `HeapSample.rssBytes` and gating `native_memory_growing` — reproducer injects `rssBytes` directly so the null-edge is exercised but the `ProcessInfo` call and its try/catch are not.
- `doc/validation_ledger.md` — 4 row rationales rewritten with the TimelineParser-boundary improvement and skipped-hop disclosure (MemoryPressure).

### Notes

- Existing `test/detectors/*_detector_test.dart` files unchanged; they remain as regression suites. New reproducers are additive.
- `fvm flutter analyze` clean, `fvm flutter test` all green.

## 0.17.3

**Audit methodology gap closed: underscore-parametric families, first-class across the pipeline.** The v0.17.2 audit matcher treated the `:` separator as the only family-parametric form, so `repaint_debug_<typeName>` and `rebuild_debug_<typeName>` families were undeclarable. v0.17.3 adds `DetectorMetadata.parametricFamilies: Set<String>?` as a peer namespace to `coveredStableIds`, and promotes it to first-class status across every audit surface (literal-provenance matcher, namespace tracker, top-level metadata gate, stronger-tier threshold cross-reference). `RepaintDetector` and `RebuildDetector` drop their partial-coverage disclosures; both detectors now declare all emitted families and the audit proves coverage via detector-derived literal assertions.

### Added

- `DetectorMetadata.parametricFamilies` field — underscore-parametric family prefixes. Matcher credits `<family>_<non-empty-suffix>` literals.
- Bare/colon and underscore-parametric families tracked in independent namespaces (`matchedBareFamilies`, `matchedParametricFamilies`). A literal credited in one namespace does NOT satisfy a declaration in the other; declaring the same name in both namespaces is rejected at the metadata gate.
- Top-level metadata invariant accepts EITHER non-empty `coveredStableIds` OR non-empty `parametricFamilies` for tiers stronger than `unvalidated`. Empty/whitespace entries rejected in both namespaces.
- `checkCoveredThresholds` + `_stableIdCovers` accept `parametricFamilies` for stronger-tier validation. Dotted entries (`repaint_debug.warning`) resolve against family declarations; concrete instances (`repaint_debug_CustomPaint.warning`) resolve via the `_` non-empty-suffix rule.
- 10 regression tests in `audit_invariants_test.dart` covering the tightened matcher: detector-derived `expect(issue.stableId, ...)` shape, underscore-parametric positive / negative cases, false-positive guard, real-literal anchor (`repaint_debug_CustomPaint`), mixed + parametric-only declarations.
- v0.17.2 anchor block expectations tuple expanded to `(reproducerPath, coveredStableIds, parametricFamilies?)`. All other anchor blocks (v0.16.3, v0.17.1, NetworkMonitor, FrameTiming) gain explicit `meta.parametricFamilies == null` assertion.

### Changed

- `_isCreditedLiteral` tightened to require detector-derived provenance. Four accepted AST shapes: direct argument to `hasStableId` / `hasStableIdPrefix` / `lacksStableId`; operand of `==` / `!=` against `<x>.stableId`; argument to `<x>.stableId.startsWith` / `contains` / `endsWith`; argument to `expect(<actual>, ...)` where `<actual>` subtree references `.stableId`. Self-assertion tautologies (`expect('foo', equals('foo'))`) no longer credit the coverage gate.
- `RepaintDetector` declares `parametricFamilies: {'repaint_debug'}`. Rationale drops narrowing prose.
- `RebuildDetector` declares `parametricFamilies: {'rebuild_debug'}`. Rationale drops narrowing prose.
- `rebuild_detector_test.dart` gains `expect(issue.stableId, 'rebuild_debug_TestCounterWidget')` assertion in the real-captured debug-callback test (was only a `reason:` string before).
- `doc/validation_ledger.md` — repaint + rebuild rows updated from "Partial coverage" to "All families covered"; summary drops the family-scope-not-universal caveat for those 2 detectors.
- `CLAUDE.md` — family declaration convention documented (`coveredStableIds` vs `parametricFamilies`); "known audit gap" note removed.

### Provenance hardening (CR1 / CR2 / CR3 / CR4 + P3 / P4 / P5 / P8)

Second hardening pass surfaced a sticky-binding leak, whole-subtree taint via descendant scan, name-shadowing of Rule-1 helpers, and over-bound closure parameters on `fold`/`reduce`. The tightened matcher previously only proved `.stableId` is syntactically present; synthetic `class FakeIssue { String stableId; }` still credited. Converged on an 8-point structural provenance model:

- **Structural receiver-chain walker (`_expressionIsDetectorDerived`)**. Replaces the earlier subtree-containment rule. Walks only through aliasing shapes that preserve detector provenance: `MethodInvocation` (direct required-token construction, or recursion through element-preserving methods on a derived receiver, or producer methods like `scanTree` / `scanFrame` / `issues` on a required-token instance), `InstanceCreationExpression` (required-token type), `PropertyAccess` / `PrefixedIdentifier` / `SimpleIdentifier` (alias lookup), `IndexExpression`, `ParenthesizedExpression`, `AwaitExpression`, `AsExpression`. List literals, map literals, conditionals, binary ops, spread elements, collection-if/for, `map`/`expand`/`followedBy`/`reduce`/`fold`/`whereType`/unknown extension methods → NOT derived.
- **Full add/remove lifecycle on `detectorBoundIdentifiers`**. `visitVariableDeclaration` + `visitAssignmentExpression` ADD when RHS is structurally derived, REMOVE when not (any assignment operator). Closes the sticky-set leak where `final issue = FakeIssue(...)` after a prior derived binding kept `issue` in the bound set.
- **Pattern destructuring kill**. `visitPatternVariableDeclaration` + `visitPatternAssignment` conservatively REMOVE every declared/assigned name (Dart 3 `(a, b) = ...` rebinding cannot be proven per-slot). Record, list, map, object, cast, null-check, null-assert, parenthesized, logical-and, logical-or patterns all enumerated.
- **for-in binder handling**. `visitForStatement` detects `ForEachPartsWithDeclaration`, rebinds the `DeclaredIdentifier` loop variable based on `_expressionIsDetectorDerived(iterable)`, and restores prior state on loop exit. Real pattern `for (final issue in detector.scanTree(root))` credits via producer-method whitelist; fabricated `for (final issue in [FakeIssue('foo')])` fails to credit.
- **Closure-param whitelist by method position**. `visitFunctionExpression` adds a parameter to the bound set ONLY when the enclosing method is in `_closureParamPositions` AND its position matches the element-iteration slot: `where/firstWhere/lastWhere/singleWhere/any/every/map/forEach/expand/takeWhile/skipWhile` → position 0; `reduce/fold` → position 1 (accumulator is position 0 and does NOT bind). Scoped push/pop — closure params do not leak out of the closure body.
- **Shadow detection for Rule-1**. `visitFunctionDeclaration` + `visitMethodDeclaration` + `visitVariableDeclaration` flag any local definition of `hasStableId` / `hasStableIdPrefix` / `lacksStableId`. When the flag is set, Rule-1 rejects credit in the file — a local stub could be an always-true helper that bypasses detector-output proof.
- **Rule-4 covers `expectLater`** alongside `expect` (P8).
- **Prefix-collision rejection** in `parametricFamilies`. Top-level metadata audit adds a pair-wise check: for families `(a, b)` with `a.startsWith('${b}_')` or vice versa, failure raised. Prevents single literal `foo_bar_baz` from crediting both `{'foo'}` and `{'foo_bar'}` (P3).

Total regression fixtures added over both hardening passes: 12. New anchors in this pass:
- Rule-1 positive (without local stub — shadow detection otherwise rejects)
- Rule-2 positive (`.where((i) => i.stableId == 'LIT')` closure parameter)
- Rule-3 positive (`<x>.stableId.startsWith('LIT_')`)
- Tautology negative (`expect('foo', equals('foo'))` must fail — P5)
- FakeIssue anti-bypass (synthetic `stableId` getter must fail — P1)
- CR1 reassignment-kill (sticky set must release prior binding on non-derived re-declaration)
- CR2 list-literal smuggling (composite-expression taint must not propagate)
- CR4 fold accumulator (caller-controlled `acc` position must not bind)
- for-in shadow kill (`for (final issue in fakeList)` must invalidate)
- for-in positive (`for (final issue in detector.scanTree(...))` must credit)
- Pattern-destructure kill (`(issue, _) = (FakeIssue(...), 0)` must invalidate)
- Shadow rejection (local `Matcher hasStableId(...)` must reject Rule-1)

### Notes

- `DetectorMetadata` is public API; `parametricFamilies` is nullable → pure additive, no backward-compat impact.
- No serialisation of `DetectorMetadata` exists downstream; no schema versioning needed.
- Residual risks (LOW): cross-test undeclared-name reuse leaks (real reproducers always declare per-test); unknown iterable extension methods fail-closed (authors migrate to the whitelisted forms); mixed-detector reproducer can theoretically credit wrong detector. All require deliberate authorship; the audit is a CI hygiene gate, not a security boundary.
- `fvm flutter analyze` clean, `fvm flutter test` 2,634 tests green.

## 0.17.2

**All 23 detectors at `reproducerOnly`.** Final 8 vmOnly + hybrid detectors flipped from `unvalidated`: `ShaderJankDetector`, `HeavyComputeDetector`, `PlatformChannelDetector`, `MemoryPressureDetector`, `GpuPressureDetector`, `RepaintDetector`, `RebuildDetector`, `ShallowRebuildRiskDetector`. Reproducers point at existing `test/detectors/*_detector_test.dart` suites.

**Tier not uniform.** vmOnly reproducers drive `processTimelineData` / `processHeapSample` directly; the VM → `TimelineParser` → detector boundary is NOT exercised. Prior-batch structural reproducers (v0.16.3, v0.17.1) drove real `pumpWidget` + `scanTree` — materially stronger evidence. "23/23 `reproducerOnly`" is registry-level only.

### Added

- v0.17.2 anchor block in `detector_metadata_audit_test.dart` pinning (type → reproducerPath → coveredStableIds) for 8 detectors + null extended-fields.
- 4 `expect(issue.stableId, ...)` assertions in existing tests: `shallow_rebuild_risk`, `gpu_pressure` (both families), `rebuild` (stateful_density + rebuild_activity at warning + critical).

### Changed

- 8 detector `validationMetadata` blocks flipped to `reproducerOnly`. `RebuildDetector` covers `{stateful_density, rebuild_activity}` (warning at `> rebuildsPerSecThreshold` default 10/sec, critical at `> 3×` = 30/sec, pinned by tests at 15 → warning and 35 → critical).
- `detector_metadata_audit_test.dart` refactored: anchor expectations maps lifted to file-scope consts; `anchoredTypes` derived from those maps' keys. Single source of truth — deleting an anchor block automatically fires the ratchet.
- `doc/validation_ledger.md` — summary recount 15/23 → 23/23; 8 row flips; v0.17.2 roadmap entry; tier description expanded.

### Notes

- **Two partial-coverage disclosures**, same root cause: underscore-parametric families unrepresentable in audit schema (`:` separator only).
  - `RepaintDetector`: parametric `repaint_debug_<typeName>` not declarable.
  - `RebuildDetector`: parametric `rebuild_debug_<typeName>` same issue.
- `reproducerPath` points at `test/detectors/` for this batch (existing unit tests used directly). Prior batches used purpose-written `test/validation/*_reproducer_test.dart`. Both pass `isPathInsideRepo`.
- Fixture provenance disclosed in each rationale: reproducer reuses existing unit tests; fixtures synthetic, same-author provenance. This is provenance disclosure, not evidence-strength equivalence with structural batches.
- `fvm flutter analyze` clean, `fvm flutter test` 2614/2614 green.

## 0.17.1

**Bulk structural validation batch.** Nine structural detectors raised `unvalidated` → `reproducerOnly`: `LayoutBottleneckDetector`, `NestedScrollDetector`, `CustomPainterDetector`, `AnimatedBuilderDetector`, `KeepAliveDetector`, `FontLoadingDetector`, `RepaintBoundaryDetector`, `SetStateScopeDetector`, `StartupDetector`. All nine are pure structural or one-shot scans, so hermetic reproducers cover the runtime trigger path end-to-end. Ledger distribution: **15/23 `reproducerOnly`, 8/23 `unvalidated`**.

### Added

- **9 hermetic reproducers** under `test/validation/` (60 tests). Each pins positive-trigger + boundary silence + negative controls for every family the detector emits. `StartupDetector` reproducer uses the `@visibleForTesting` `Sleuth.setStartupMetricsForTest` hook.
- **Shared scan harness** at `test/validation/_helpers/structural_reproducer_harness.dart` — `scanAndIssues` drives the unified walk directly so walker exceptions propagate to the test.
- **Anchor blocks** in `test/validation/detector_metadata_audit_test.dart` for the v0.17.1 batch and the v0.16.3 pre-ratchet detectors (imageMemory, opacity, globalKey, listview). Every `reproducerOnly+` detector has a (type → reproducerPath → coveredStableIds) triple and an allowlist entry — silent rename, stableId drift, or path churn fails CI.
- **Strengthened `checkReproducerFile` gate.** Stable-id literals are credited only via a parent-chain walk that rejects `NamedExpression` ancestors (`reason:`/`skip:` bypass) and non-null-target MethodInvocations (String extension-method bypass). `coveredStableIds` is set-tracked — every declared family must be observed.

### Changed

- **9 detector `validationMetadata` blocks flipped** to `reproducerOnly` with rationales, `reproducerPath`, and `coveredStableIds` set to the families the reproducer actually exercises.
- **`doc/validation_ledger.md`** — summary recount (6/23 → 15/23), 9 structural rows flipped, v0.17.1 roadmap entry added.
- **`FontLoadingDetector` source comment** rewritten — the detector DOES cover `DefaultTextStyle` inheritance via Text's internal `RichText` materialisation (previous comment claimed otherwise).

### Notes

- **`SetStateScopeDetector` covers the structural / possible-confidence path only.** Uncovered at this tier: rebuild-evidence branch (likely / possible), severity branching (`ratio > 0.5 ? critical : warning`), DebugSnapshot confidence upgrade.
- **`RepaintBoundaryDetector.excessive_repaint_boundary`** at-threshold pin is out of reach: the scrollable pipeline injects extra RepaintBoundary nodes the detector counter observes, regardless of `addRepaintBoundaries: false`.
- **Reproducer thresholds are tuned down from production defaults** (e.g. `minSubtreeSize: 1`, `maxFamilies: 1`, `childThreshold: 3`) to cross boundaries on small hermetic trees — tests validate classification semantics, not threshold values.
- `fvm flutter analyze` clean, `fvm flutter test` all green (2,613 tests).

## 0.17.0

**FPS semantics rewrite.** Sleuth now exposes two frame-rate metrics instead of one: count-based `actualFps` (frames presented in a rolling 1 s window anchored on `FrameTiming.rasterFinish`) and latency-derived `throughputFps` (the v4 formula, `1e6 / avg(frame_duration_us)`). `averageFps` is retained as an alias for v4 consumers and scheduled for removal in v0.18.0. `FrameStatsSummary` JSON schema bumped `v4 → v5` additively; the new fields backfill from `averageFps` when reading v4 snapshots so no consumer has to migrate.

### Added

- **`FrameStatsBuffer.actualFps`** — rolling 1 s count-based FPS, anchored on the latest `FrameStats.rasterFinishUs` (engine monotonic clock, not `DateTime.now()`) so batched `addTimingsCallback` delivery does not distort the count. Memoised; invalidated on `add()` and `clear()`.
- **`FrameStatsBuffer.windowSampleCount`** — number of frames with non-null `rasterFinishUs` inside the 1 s window. Drives the UI warm-up placeholder (`—` until ≥ 3 samples ≈ 50 ms @ 60 Hz).
- **`FrameStatsBuffer.throughputFps`** — renamed getter for the existing latency-derived formula. `averageFps` kept as a plain alias (no `@Deprecated` annotation — avoids lint-noise explosion across internal consumers).
- **Auto-sized buffer capacity.** `FrameStatsBuffer({int? capacity, int fpsTarget = 60})` defaults capacity to `(fpsTarget * 2).clamp(60, 240)` so a ProMotion 120 Hz device retains a full 1 s window (120 frames) without eviction. Explicit `capacity:` still honoured.
- **`FrameStats.copyWith()`** — lets `addFrameForTest` auto-inject a monotonic `rasterFinishUs` when the caller omits it, so pre-v0.17.0 tests don't silently observe `actualFps == 0`.
- **`FrameStatsSummary.actualFps` / `.actualFpsRaw` / `.throughputFps`** — three new fields on the export. `actualFpsRaw` carries the device rate (e.g. 120 on ProMotion) clamped at a 240 Hz ceiling so pathological clock-stuck inputs cannot overflow the buffer-count bound; `actualFps` is clamped to `SleuthConfig.fpsTarget` for UI parity.
- **UI warm-up placeholder.** `_StatusRow` and `TriggerButton` show `—` in `textTertiary` until the frame buffer has 3 entries. Prevents a red `0 FPS` flash at app launch or after navigation.
- **Info-icon + inline explainer** on `_StatusRow` — tap the `Icons.info_outline` glyph to reveal a 2-line explainer and the `_ThroughputDetailRow` (`_FpsCell` for ACTUAL + TPUT side-by-side). 28 dp tap target matches the `_RebuildStatsBanner` pause precedent (v0.15.2 H1 overlay-budget compromise).
- **Primary UI numeral is `throughputFps`.** `actualFps` counts frames Flutter actually presented — it collapses to a few frames/sec on idle screens because the engine skips vsync when nothing changes. `throughputFps` stays representative of the engine's rendering capacity and matches pre-v0.17.0 overlay behaviour. `actualFps` remains visible in the expanded detail row and in snapshot exports (`FrameStatsSummary.actualFps` + `actualFpsRaw`).
- **6 new tests in `test/validation/frame_timing_reproducer_test.dart`** (FPS semantics group) — all via the real `handleTimingsForTest` path: 60 monotonic frames over 1 s → 60, 120 monotonic @ `fpsTarget: 120` → 120, batched delivery → 60 regardless of arrival pattern, 90-frame window slide → ~60, zero frames → 0, null `rasterFinishUs` → counted in `latest` but not in the window.
- **9 new tests in `test/models/frame_stats_buffer_fps_test.dart`** — window boundary (left-inclusive), non-monotonic timestamp handling (latest anchor holds), `fpsTarget=120` capacity retention, `clear()` full reset, memoisation consistency, empty buffer, auto-sized vs explicit capacity, alias parity.
- **3 new tests in `test/models/serialization_test.dart`** — v4 → v5 `fromJson` backfill chain, v5 round-trip, v5 → v4 reader simulation (stripped keys still parse), `schemaVersion` default bump, and a **golden-file gate** (`test/models/_fixtures/session_snapshot_v5_golden.json`) so any PR that adds a `FrameStatsSummary` field without updating the fixture fails CI.
- **2 new tests in `test/models/route_session_test.dart`** — `healthScore` rename-only preservation (pre-v0.17.0 inputs yield identical scores) and warm-up robustness (single frame does not collapse the score — step 6 decision).

### Changed

- **`SessionSnapshot.schemaVersion` default `4 → 5`.** Additive bump: all v4 fields retained, v4 consumers reading v5 snapshots continue to read `averageFps` unchanged (UI path clamps stay in place).
- **`FrameTimingDetector._onTimings`** populates `FrameStats.rasterFinishUs` from `timing.timestampInMicroseconds(FramePhase.rasterFinish)`; the detector treats `0` as absent (some engine/platform combos omit the phase) so `actualFps` does not poison its window with a zero anchor.
- **`SleuthController.exportSnapshot()`** emits clamped `actualFps` / `throughputFps` (UI parity) plus uncapped `actualFpsRaw` so external consumers can see the device's real rate on 120 Hz hardware. `packageVersion` bumped `0.15.1 → 0.17.0`.
- **`RouteSession.healthScore`** uses `throughputFps` (rename only, formula unchanged). Chosen over `actualFps` because health scoring must be robust at low sample counts (startup, idle, navigation) where `actualFps` would collapse toward the frame count. `toJson` emits the same clamped `averageFps` field name so existing exports are byte-identical.
- **`session_markdown_exporter.dart`** — the `Average FPS` single-line row becomes two lines: `Actual FPS` + `Throughput FPS`. Consumers of the v4 field name will read from `averageFps` on the summary (alias).
- **`FrameTimingDetector.validationMetadata.rationale`** — append documenting that v0.17.0 adds FPS-semantics exposure without changing stableId coverage (jank detection is orthogonal to FPS reporting).
- **`_frameworkWidgetDenyList`** in `debug_instrumentation_coordinator.dart` — `_ThroughputDetailRow` + `_FpsCell` added so Sleuth does not self-measure its new overlay widgets in profile mode (KDD-10).

### Notes

- Zero migration for v4 consumers — `averageFps` still emitted, still populated from `throughputFps`.
- The `@Deprecated` annotation was intentionally NOT applied to `FrameStatsBuffer.averageFps`. A deprecation annotation would flood `flutter analyze` with warnings across internal consumers (C-4 plan-review finding). Removal is scheduled for v0.18.0; the alias keeps the transition silent.
- Retained-orphan manifest `consumeBy: '0.16.7' → '0.18.0'` across all three NetworkMonitor `slow_request` capture files to track with the real re-raise window; the v0.16.5 prerequisites stay unresolved.
- `fvm flutter analyze` clean, `fvm flutter test` all green (2,541 tests).

## 0.16.6

**Two simultaneous tier raises in one PR.** `FrameTimingDetector` raised `unvalidated` → `reproducerOnly` pinning 4 stableIds, and `ListviewDetector` coveredStableIds backfilled 3 → all 8. Ledger distribution: `6/23 reproducerOnly, 17/23 unvalidated`.

### Added

- **`test/validation/frame_timing_reproducer_test.dart`** — hermetic reproducer pinning `sustained_jank` (≥3 severe frames in 60-frame window), `jank_detected` (>15% jank frames, ≥5-frame sample), `raster_cache_thrashing` (≥15 consecutive frames of ≥20% picture-cache-count fluctuation), `raster_cache_growing` (≥30 consecutive frames of monotonic picture-cache-count growth). Every stableId has a synthetic `FrameStats` path (`addFrameForTest`) plus a real-pipeline `FrameTiming` leg (`handleTimingsForTest`) so hand-written fixtures cannot encode the detector's own expected shape. Impeller-zero suppression pinned by a dedicated `pictureCacheBytes: 1` belt-and-suspender test.
- **FrameTiming audit anchor** in `test/validation/detector_metadata_audit_test.dart`: pins `tier == reproducerOnly`, `reproducerPath`, all 6 extended-claim fields `isNull`, and the 4-id `coveredStableIds` set.
- **5 new ListView reproducer groups** (~13 tests) covering `non_lazy_gridview`, `non_lazy_sliver_list`, `non_lazy_sliver_grid`, `sliver_to_box_adapter_shrinkwrap` (3-test triad pinning Check C gate: shrinkWrap:true fires, shrinkWrap:false silent, many-children-list-delegate routes to Check A), and `non_lazy_list`.

### Changed

- **`FrameTimingDetector.validationMetadata`** — tier `unvalidated` → `reproducerOnly`; `reproducerPath` set; `coveredStableIds` declares the 4 ids.
- **`ListviewDetector.validationMetadata`** — `coveredStableIds` expanded 3 → 8; rationale enumerates all 8 families including `sliver_to_box_adapter_shrinkwrap` isNonLazy bypass and `sliver_fill_remaining_scrollable` structural-adjacency caveat.
- **`doc/validation_ledger.md`** — summary `5/23 reproducerOnly, 18/23 unvalidated` → `6/23 reproducerOnly, 17/23 unvalidated`; FrameTiming + ListView rows rewritten; Roadmap split into shipped v0.16.6 bullet + renamed v0.16.7+ bullet (deferred NetworkMonitor re-raise); `← current release` marker moved v0.16.5 → v0.16.6.
- **Retained-orphan manifest `consumeBy: '0.16.6'` → `'0.16.7'`** across all three NetworkMonitor `slow_request` capture files, `test/validation/detector_metadata_audit_test.dart` (3 manifest entries + prose anchors), `lib/src/detectors/network_monitor_detector.dart` (rationale `"v0.16.6 re-raise"` → `"v0.16.7+ re-raise"`), and `CLAUDE.md` current-state block. v0.16.6 shipped without re-raising NetworkMonitor; re-raise deferred to v0.16.7+ pending the same three prerequisites documented in v0.16.5.

### Notes

- Zero migration — no public API, schema, config, or default change.
- `fvm flutter analyze` clean, `fvm flutter test` all green.

## 0.16.5

**Second `externallyCited` tier raise for `NetworkMonitorDetector.slow_request.warning` staged and reverted; audit hardening retained.** The NN/g 1.0 s boundary is a UI direct-manipulation feedback guideline, not a generic HTTP latency threshold — the detector fires on any uncancelled request, so the citation does not substantiate the detector contract. Profile captures validate scenario-marker span only, not detector-produced emission. Detector ships at `reproducerOnly` (unchanged from v0.16.1). v0.16.4/v0.16.5 infrastructure (`coveredThresholds`, `aboveCeilingMultiplier`, `ProfileCaptureSchema`, L2/mechanism-4 guards, retained-orphan manifest) stays landed for v0.16.6 re-raise.

### Changed

- **`NetworkMonitorDetector.validationMetadata`** — tier `externallyCited` → `reproducerOnly`. `citationUrl` / `profileCapturePaths` / `bracketThreshold` / `bracketUnit` / `coveredThresholds` / `aboveCeilingMultiplier` nulled. Rationale enumerates the three v0.16.6 re-raise prerequisites: match citation semantics to detector contract (or narrow the contract), extend capture helper to emit a `sleuth.issue.slow_request.warning` trace record, extend `ProfileCaptureSchema.validateBracket` to require that record inside the scenario window. `reproducerPath` + `coveredStableIds: {'slow_request'}` preserved.
- **`test/validation/detector_metadata_audit_test.dart`** — anchor renamed to `'pinned at reproducerOnly (v0.16.5)'`; asserts `tier == reproducerOnly` and extended-claim fields all `isNull`. L2 negative assertion, mechanism-4 guard, and default-drift cross-check wired dormantly so they fire on v0.16.6 re-raise.
- **Retained-orphan manifest** repopulated for all three captures (`slow_request_below.json` @ 812 ms, `slow_request_at.json` @ 1035 ms, `slow_request_above.json` @ 1515 ms) with `consumeBy: '0.16.6'`, pinned to iPhone 12 / iOS 17.5 / Flutter 3.41. Closes the gap where nulled `profileCapturePaths` would otherwise trip `checkCaptureOrphans` on the retained files.
- **`test/validation/ledger_sync_test.dart`** — pinned row regex `` | `externallyCited` | `` → `` | `reproducerOnly` | ``.
- **`doc/validation_ledger.md`** — summary `1/23 externallyCited, 4/23 reproducerOnly, 18/23 unvalidated` → `5/23 reproducerOnly, 18/23 unvalidated`. Network Monitor row and roadmap bullet document the revert plus the three v0.16.6 prerequisites.
- **Capture `captureNotes`** in all three `slow_request_*.json` — orphan-retention framing (`Retained orphan (v0.16.5). ... Tracked in retainedOrphans manifest with consumeBy='0.16.6'`).

### Audit hardening (retained)

- **L2 negative assertion** on NetworkMonitor anchor: `meta.coveredThresholds` contains no `*.critical` entries. Dormant at reproducerOnly; fires on v0.16.6 re-raise to block silent broadening of a warning-tier claim to critical.
- **Mechanism-4 matcher backtick normalisation.** Inline-code fragments like `` `reproducerOnly` `` or `` `slow_request.warning` `` caused exclusion-phrase matching to silently fail. Matcher now strips backticks then collapses whitespace before lowercasing: `rationale.replaceAll('\`', ' ').replaceAll(RegExp(r'\s+'), ' ').toLowerCase()`.
- **Default-drift cross-check.** When `meta.bracketThreshold` is non-null, anchor asserts `NetworkMonitorDetector().slowThresholdMs == meta.bracketThreshold`. Dormant at reproducerOnly; catches drift between constructor default and metadata in either direction once v0.16.6 sets the field.

### Deferred

- **Detector-emission evidence in captures.** Helper emits scenario markers but no `sleuth.issue.slow_request.warning` trace record — captures prove the helper delayed, not that the detector classified. Non-blocking at `reproducerOnly`; v0.16.6 re-raise lands both the capture-helper and schema extensions before re-setting `profileCapturePaths`.

### Notes

- Detector ledger distribution: `5/23 reproducerOnly, 18/23 unvalidated` (unchanged from v0.16.4).
- Zero migration; no public API change.
- Test count stable at 2,493 root + 9 example. `fvm flutter analyze` clean, `fvm flutter test` all green.

## 0.16.4

**Validation infrastructure release.** The planned first `externallyCited` tier raise on `NetworkMonitorDetector.slow_request` was staged and reverted in the same release: the `above`-bracket capture at 3117 ms simultaneously brackets the WARNING (1000 ms) AND the CRITICAL (3000 ms) thresholds, so the file on disk ambiently validates a claim the detector rationale explicitly scopes out. `NetworkMonitorDetector` ships at `reproducerOnly` (unchanged from v0.16.1). Downstream infrastructure added during the staged raise — Flutter-pin rotation, schema ph=`n` acceptance, symmetric AB-1 inverse guard, new `aboveCeilingMultiplier` schema ceiling, `coveredThresholds` / `aboveCeilingMultiplier` fields on `DetectorMetadata`, capture-helper example screen, README documenting both Chrome-native and Perfetto traceconv export paths, one-time matrix exception for iPhone 12 / iOS 17.5 — lands as committed so v0.16.5 can re-raise trivially once a real `[1000, 2000)` `above` capture is recorded.

### Added

- **`DetectorMetadata.coveredThresholds`** (`Set<String>?`) — scoping field that names exactly which thresholds a tier claim covers, e.g. `{'slow_request.warning'}`. Lets a detector with multiple tiers (warning / critical) raise one tier independently without silently implying the others. Dormant in v0.16.4; wired for v0.16.5's scoped re-raise.
- **`DetectorMetadata.aboveCeilingMultiplier`** (`double?`) — upper-bound multiplier for the `above`-bracket capture's observed magnitude, default 2.0 at schema side. Prevents a single `above` capture from ambiently bracketing a higher tier: e.g. with threshold=1000 and `aboveCeilingMultiplier: 2.0`, an `above` observed at 3117 ms is rejected because it exceeds `threshold × 2.0 = 2000`.
- **`ProfileCaptureSchema.defaultAboveCeilingMultiplier = 2.0`** + new `aboveCeilingMultiplier` named parameter on `validateBracket`. The guard runs after the existing `aboveObs > threshold` check: `if (aboveObs > threshold * aboveCeilingMultiplier) throw FormatException(...)`. `aboveCeilingMultiplier <= 1.0` is rejected at call time so a contributor can't disable the guard by setting the multiplier to the threshold itself.
- **`NetworkMonitor Capture Helper` screen** in the example app — three preset delay knobs (800 / 1020 / **1500** ms, updated for warning-tier-only scope) that hit a loopback `HttpServer` with controlled response delays and emit `sleuth.scenario.begin` / `sleuth.scenario.end` instant markers so AB-1 can bind the observed magnitude to the scenario span rather than the full capture duration. The `above` preset is deliberately capped in `[1000, 2000)` so the artifact cannot ambiently bracket the 3000 ms critical tier. Reproducible by any contributor who wants to re-record the bracket on a different device.
- **iPhone 12 / iOS 17.5** added to `ProfileCaptureSchema.approvedDevicePairs` as a **one-time exception** to the annual rotation policy. `doc/reference_devices.md` frames this as non-precedent: future requests for mid-cycle matrix changes are rejected. The addition is kept — the v0.16.4 capture helper emits markers the iPhone 12 / iOS 17.5 pair will consume during the v0.16.5 re-raise.
- **Two profile-mode DevTools captures** at `test/validation/captures/network_monitor/` retained for v0.16.5 reuse: `slow_request_below.json` (observed 812 ms) and `slow_request_at.json` (1035 ms). `slow_request_above.json` (3117 ms) was **deleted** — a fresh `above` capture inside `[1000, 2000)` will land with the v0.16.5 re-raise.
- **3 new regression tests** in `test/validation/profile_capture_schema_test.dart` covering the ceiling guard: `above` beyond ceiling is rejected, `aboveCeilingMultiplier <= 1.0` is rejected at call time, default multiplier accepts a happy-path fixture.

### Changed

- **`NetworkMonitorDetector.validationMetadata`** — staged at `EvidenceTier.externallyCited`, reverted to `EvidenceTier.reproducerOnly`. `citationUrl`, `profileCapturePaths`, `bracketThreshold`, `bracketUnit` are null again. Rationale rewritten to document the revert + v0.16.5 re-raise plan (re-record `above` in `[1000, 2000)`, wire `coveredThresholds: {'slow_request.warning'}`, and populate `aboveCeilingMultiplier` on the metadata literal so the schema ceiling guard fires in CI). `reproducerPath` and `coveredStableIds: {'slow_request'}` are preserved from v0.16.1.
- **⚠ Matrix policy — one-time exception retained**. `ProfileCaptureSchema.approvedFlutterMajorMinor` rotated `'3.32'` → `'3.41'` mid-cycle because the recording environment (Flutter 3.41.4 stable) ships iOS `FlutterImplicitEngineDelegate` / `FlutterSceneDelegate` bindings and a `vm_service` patch level that the example project depends on; it cannot be downgraded to 3.32 without a multi-file compat regression. **This is a one-time exception, not a policy change** — `doc/reference_devices.md` explicitly disallows future mid-cycle rotations. `_flutterVersionPattern` regex retuned `^3\.32\.\d+(?:[-+][0-9A-Za-z.\-]+)?` → `^3\.41\.\d+(?:[-+][0-9A-Za-z.\-]+)?`. Anchor fixture's `flutterVersion` bumped `'3.32.5'` → `'3.41.4'` with matching SHA-256 digest update in `profile_capture_schema_anchor_test.dart` (`b8cfcc6f...`). Anchor now declares `provenance: "shape-faithful synthetic"` field. Six synthetic fixture `flutterVersion` fields rotated in lockstep.
- **`ProfileCaptureSchema.allowedTracePhases`** widened to include `'n'` (async nestable instant) — the form Perfetto's `traceconv` emits for Dart's `Timeline.instantSync(...)` when converting on-disk `.pftrace` binaries to Chrome Trace JSON. The Chrome-native path uses `'i'`/`'I'`; both are now accepted so real DevTools captures parse. Scenario-marker walker accepts all three.
- **`ProfileCaptureSchema._crossCheckTraceVsObserved`** adds a symmetric guard: previously only `observedMicros/spanMicros > 100×` failed (fabricated long observation with short marker span); now `spanMicros/observedMicros > 100×` also fails (markers placed too wide — window contains unrelated work like cold-start warmup or idle dwell).
- **`doc/reference_devices.md`** — matrix table Flutter column `3.32.x` → `3.41.x` (all rows); `approvedFlutterMajorMinor` snippet rotated; "One-time exception: v0.16.4 matrix additions" section explicitly rejects the earlier carve-out; "Why Flutter 3.41.x" section documents why 3.41 over 3.40 or 3.42.
- **`doc/validation_ledger.md`** — summary `5 / 23 at reproducerOnly, 18 / 23 at unvalidated` stays unchanged (NetworkMonitor revert keeps the v0.16.3 distribution). Network Monitor row documents the staged-and-reverted raise plus the v0.16.5 plan. Roadmap v0.16.4 bullet reframes the release as infrastructure + revert; v0.16.5 bullet added for the scoped re-raise.
- **`test/validation/detector_metadata_audit_test.dart`** — pinned NetworkMonitor assertion retargeted: `tier == reproducerOnly`, `citationUrl` / `profileCapturePaths` / `bracketThreshold` / `bracketUnit` all `isNull`. Documents the tier history (v0.16.1 `reproducerOnly` → v0.16.4 `reproducerOnly` after staged `externallyCited` revert) inline.
- **`test/validation/ledger_sync_test.dart`** — pinned row regex reverted `` | `externallyCited` | `` → `` | `reproducerOnly` | ``.
- **`test/validation/_support/audit_invariants.dart`** — `checkBracketValidation` helper gains `aboveCeilingMultiplier` named parameter, forwarded to `ProfileCaptureSchema.validateBracket` with `?? defaultAboveCeilingMultiplier` fallback. Detector audit thread the metadata field through.
- **`test/validation/captures/README.md`** — scenario markers section documents both `ph:"i"` (Chrome DevTools native export) and `ph:"n"` (Perfetto traceconv export) paths explicitly; capture protocol updated to `800 / 1020 / 1500 ms` presets with the warning-tier-only scope note; critical-tier protocol reserved for a future raise. Flutter regex example rotated to `^3\.41\.\d+`.
- **`example/lib/demos/network_monitor_capture_screen.dart`** — per-request handler wrapped in try/catch so a client disconnect mid-delay surfaces in the in-screen log; `listen` attaches `onError`; dispose nulls fields before fire-and-forget `close(force: true)` so stray late callbacks short-circuit; mid-bind dispose releases the port rather than leak it; header body text updated to reference the `[1000, 2000)` ceiling.

### Notes

- Detector ledger distribution unchanged from v0.16.3: `0/23 externallyCited, 5/23 reproducerOnly, 18/23 unvalidated`. The `externallyCited` raise is deferred to v0.16.5.
- Zero migration for consumers. All v0.16.4 additions (`coveredThresholds`, `aboveCeilingMultiplier`, `defaultAboveCeilingMultiplier`, `aboveCeilingMultiplier` named param on `validateBracket`) are optional with safe defaults.
- v0.16.5 re-raise prerequisites: (1) re-record `above` capture in `[1000, 2000)` on iPhone 12 / iOS 17.5 / Flutter 3.41.4 using the capture helper's **Above (1500 ms)** preset; (2) set `coveredThresholds: {'slow_request.warning'}` on NetworkMonitor's metadata; (3) leave `aboveCeilingMultiplier` unset so the default 2.0 fires (`1500 ≤ 2000` passes; a future drift above 2000 ms fails CI).
- `fvm flutter analyze` clean, `fvm flutter test` all green (2,431 → 2,493, +62 tests covering the hardening work below). `fvm flutter pub publish --dry-run` clean.

### Hardening

- **`coveredThresholds` validator wiring.** `DetectorMetadata.coveredThresholds` was declarable but not enforced: a detector could set `coveredThresholds: {'slow_request.warning'}` without any bracket capture covering that threshold and the audit gate stayed silent. `checkBracketValidation` in `test/validation/_support/audit_invariants.dart` now threads `coveredThresholds` through to `ProfileCaptureSchema.validateBracket`, which asserts every named threshold resolves to a numeric value in the capture's `expectedMagnitude` map and at least one capture's `bracketThreshold` equals that value. Unreferenced thresholds and missing-capture cases each fire a distinct `FormatException` with the offending key.
- **Typed `coveredThresholds` structural validator.** The initial validator accepted any non-empty `Set<String>` as valid. `checkCoveredThresholds` now enforces: exactly one dot when severity-scoped; non-empty stableId and severity halves; severity ∈ `{info, warning, critical}`; stableId prefix-matches `coveredStableIds` (exact or via the `:<param>` convention); non-dotted entries rejected when `bracketThreshold` is set, since a numeric claim is inherently severity-scoped. Detector audit threads `coveredStableIds` + `bracketThreshold` through on both `runtimeVerified` and `externallyCited` arms.
- **`aboveCeilingMultiplier` propagation from metadata literal to validator.** Default 2.0 fired correctly from `ProfileCaptureSchema.defaultAboveCeilingMultiplier`, but a detector declaring `aboveCeilingMultiplier: 1.5` on its metadata had that value silently dropped at the audit boundary. `checkBracketValidation` now reads the metadata field and forwards it (with the default fallback). `checkSeverityScopedCeiling` further requires an explicit multiplier whenever `coveredThresholds` names a severity-scoped entry — the schema default is convenience, not a tier-scoped claim.
- **At-band vs above-band collision guard on `aboveCeilingMultiplier`.** A multiplier of `1.05` with the default 10% at-band tolerance accepted an `above` magnitude inside the at-band window itself, collapsing the bracket's three-point structure. `validateBracket` now asserts `aboveCeilingMultiplier > 1 + atTolerance` at call time and rejects the combination with a `FormatException` naming both values.
- **Finite-number guard across `ProfileCaptureSchema`.** `validateBracket` and `_validateExpectedMagnitude` accepted `NaN` / `±Infinity` / exponent-overflow numeric values from JSON (Dart's `jsonDecode` silently coerces `1e400` to `double.infinity`), poisoning the `min <= observed <= max` check (`NaN < x` is always false) and the AB-1 trace-vs-observed ratio (finite / infinity = 0, infinity / finite = infinity). New `_requireFinitePositive` / `_requireFiniteNonNegative` helpers gate every numeric read site — `bracketThreshold`, `atTolerance`, `aboveCeilingMultiplier`, `expectedMagnitude.{min,observed,max}` — and `_crossCheckTraceVsObserved` explicitly guards the derived `ratio` / `inverseRatio` values.
- **Orphan capture audit.** v0.16.4 deleted `slow_request_above.json` and nulled `NetworkMonitorDetector.profileCapturePaths`, but kept `slow_request_below.json` + `slow_request_at.json` on disk for v0.16.5 reuse. New `checkCaptureOrphans` helper in `audit_invariants.dart` walks the captures directory (skipping `_fixtures/` and non-JSON), harvests every detector's `profileCapturePaths` via `SleuthController.detectorsForAudit`, and flags any file that's neither referenced nor allowlisted. Paths canonicalized via `package:path` so `./captures/...` vs `captures/...` drift can't mask a referenced file.
- **Retained-orphan typed manifest + lifecycle.** The first allowlist was `Map<String, String>` — rationale only, no schema parse, no cross-check against the capture on disk, no lifecycle. A capture whose metadata drifted (wrong device, stale Flutter patch, observed outside its declared band) sat dormant until a human re-reviewed the list, and a skipped milestone left the file as a permanent orphan. New `RetainedOrphanEntry` class (role / device / deviceOsVersion / flutterMajorMinor / unit / observedMin / observedMax / consumeBy / owningClaim / rationale) plus `checkRetainedOrphanManifest` helper that (a) runs `ProfileCaptureSchema.parseFile` on every entry — malformed JSON, missing file, or schema drift fails audit; (b) cross-checks parsed `sleuthMetadata` device / OS / flutterVersion-major.minor / unit / observed-in-band against the manifest declaration; (c) fails entries where `currentReleaseVersion` (parsed from `pubspec.yaml`) has reached or passed the declared `consumeBy` semver. `detector_metadata_audit_test.dart` carries typed entries for the two slow_request below/at captures (`consumeBy: '0.16.5'`, `owningClaim: 'NetworkMonitorDetector.slow_request.warning'`).
- **Capture-helper midpoint docstring.** The 1500 ms `above` preset's relationship to the schema ceiling is now documented as the midpoint rule `preset ≈ threshold × (1 + aboveCeilingMultiplier) / 2`. At `threshold = 1000 ms` and `defaultAboveCeilingMultiplier = 2.0` (ceiling 2000 ms), the midpoint is exactly 1500 ms, giving ~500 ms headroom on each side against device-jitter overshoot. Single source of truth: `ProfileCaptureSchema.defaultAboveCeilingMultiplier`.

## 0.16.3

**Four structural detectors raised to `reproducerOnly`.** `ImageMemoryDetector`, `OpacityDetector`, `ListviewDetector`, `GlobalKeyDetector` each now carry a hermetic reproducer pinning thresholds end-to-end through real `scanTree`. Pure-structural only — no profile capture, VM timeline, or decode dependency.

### Added

- **`test/validation/image_memory_reproducer_test.dart`** (+8 tests) — `uncached_images`: 40/50/51/100 dp boundary triad (50 dp skip inclusive), `ResizeImage` suppression, "zero is NOT small" policy; **both emission branches exercised** — `Image` widget AND `DecoratedBox` (`Container(decoration: BoxDecoration(image: DecorationImage))` at 100×100 fires; `ResizeImage`-wrapped `DecorationImage` suppresses). Uses 58-byte 1×1 PNG via `MemoryImage`; structural scan, decode irrelevant.
- **`test/validation/opacity_reproducer_test.dart`** (+7 tests) — `opacity_zero`: exact-zero contract (0.0 fires; 0.005 and 0.5 do not); `AnimatedOpacity(0.0)` settled fires exactly once (`_insideAnimatedOpacity` depth counter suppresses inner `FadeTransition`); **standalone `FadeTransition`** settled at 0.0 fires via `_insideAnimatedOpacity == 0` guard, at 0.5 does not (via `_FadeTransitionHost` stateful helper with `SingleTickerProviderStateMixin` + `AnimationController(duration: Duration.zero)..value = 0.0`); nested `Opacity(0.0)` produces one rollup issue with count 2.
- **`test/validation/listview_reproducer_test.dart`** (+8 tests) — 3 of 8 families: `non_lazy_listview` (childThreshold boundary 5/6/20, `.builder` lazy bypass — `SliverChildBuilderDelegate` ≠ `SliverChildListDelegate`); `sliver_to_box_adapter_large`; `sliver_fill_remaining_scrollable` (`hasScrollBody: false` fires, `hasScrollBody: true` does not). Remaining 5 families stay implicitly `unvalidated` — same single-family-pin precedent as v0.16.1 NetworkMonitor.
- **`test/validation/global_key_reproducer_test.dart`** (+7 tests) — both families with distinct scope contracts: `excessive_global_keys` is **scrollable-gated** (3 at-threshold no fire, 4 fires, 10 critical; bare-tree keys ignored — counted only while `ListView`/`GridView`/`PageView` on internal stack); `global_key_recreation` is **whole-tree** (records before stack gate) — fresh `GlobalKey()` in scrollable context AND in bare `Column` both fire via min(newKeys, goneKeys) ≥ recreationThreshold; State-held stable keys do not; first scan alone silent (`_prevKeyIds` empty). `coveredStableIds` uses prefix convention for indexed `excessive_global_keys:<i>` emissions.

### Changed

- Four `validationMetadata` getters raised in lockstep: `tier` → `reproducerOnly`, `reproducerPath` set, `coveredStableIds` declared, rationale rewritten to describe what each reproducer validates.
- **`doc/validation_ledger.md`** — summary `1 / 23` → `5 / 23 at reproducerOnly, 18 / 23 at unvalidated`; structural rows link reproducer files; `sliver_fill_remaining_scrollable` row reframed as **structural adjacency check** (detector is `DetectorLifecycle.structural` by declaration; real eager-build anti-pattern throws a layout error in `flutter_test`, requiring a `SizedBox` wrapper — structural-only validation is internally consistent); roadmap line added; date 2026-04-21.
- **`test/validation/_support/audit_invariants.dart`** — `checkReproducerFile` hardened: (a) required-token identifier credit scoped to inside test-wrapper callbacks via `FunctionExpression`-with-`MethodInvocation`-parent tracking (`_wrapperNames = {test, testWidgets, group, setUp, setUpAll, tearDown, tearDownAll}`) — pre-hardening credited any SimpleIdentifier in the file including top-level type annotations like `late XyzDetector _unused;`; (b) new `tokensInstantiated` set requires at least one `XyzDetector(...)` call inside a test scope — handles both `InstanceCreationExpression` (explicit `new`/`const`) and implicit-new `MethodInvocation` since `parseString` is syntactic-only; (c) declared `coveredStableIds` must have at least one entry appear as a string literal in scope using the prefix convention; `NamedType` annotations credited via explicit `visitNamedType` override because analyzer 6.x stores `NamedType.name2` as a Token (default `RecursiveAstVisitor` descent misses it). New `requireInstantiation` flag defaults `true` for detectors; component audit opts out (utilities like `ProfileCaptureSchema` expose only static methods). +5 helper unit tests pin each rule.

### Notes

- No public API, schema, or dependency changes. Migration zero.
- Patch bump (0.16.2 → 0.16.3) fits pre-1.0 v0.16 arc semver.
- `fvm flutter analyze` clean, `fvm flutter test` all green, `fvm flutter pub publish --dry-run` clean. Test count 2,391 → 2,427.

## 0.16.2

**Validation infrastructure — second v0.16 milestone.** Extends the detector reliability ledger with machinery needed to raise claims to `runtimeVerified` and `externallyCited`: non-detector component framework, profile-mode capture schema, bracketing rule, pinned reference-device policy, and dormant-gate coverage exercising every new code path ahead of the first real tier raise (v0.16.4).

### Added

- **`ComponentMetadata` + `ComponentMetadataProvider` mixin** (`lib/src/validation/component_metadata.dart`) — parallel framework to `DetectorMetadata` for non-detector components (helpers, const rule tables). Same field shape except `componentName` (components lack uniform `runtimeType` naming) and `coveredClaimIds` (parallels `coveredStableIds`). Full-field structural `operator ==` / `hashCode` (`Object.hashAll` ordered for `profileCapturePaths`, `Object.hashAllUnordered` for `coveredClaimIds`) so `const` instances from different compilation units compare equal.
- **`ValidatedComponentRegistry`** (`@internal`) — append-only, idempotent singleton populated via explicit `static void registerMetadata()` entry points called from the audit test's `setUpAll`. Dart's lazy top-level initialisers fire on first read, not on import, so explicit dispatch makes "forgot to register" a compile-time error. `register` throws `StateError` on collision (same `componentName` + differing metadata) with both the existing and incoming metadata in the message.
- **`ProfileCaptureSchema`** (`lib/src/validation/profile_capture_schema.dart`) — `parse()` + `parseFile()` + `validateBracket()`. Validates the `sleuthMetadata` wrapper on DevTools Chrome Trace Event exports:
  - Required keys, pair-matched device / OS, pinned Flutter major.minor.
  - `expectedMagnitude.{min, observed, max}` numeric, **all > 0** (zero / negative rejected), `min ≤ observed ≤ max`, `unit` required non-empty string (AB-1 cross-check no-ops without it).
  - ISO-8601 `captureDate` round-tripped through `toIso8601String()` — catches silent rollover (`2026-13-45` → `2027-02-14`). Sub-second fractions and `Z` / `+00:00` zone forms normalised before comparison.
  - `traceEvents` required, non-empty, ≥10 entries, every entry a JSON object with a recognised `ph` phase from the full Chrome Trace Event Format set (`B`/`E`/`X`/`b`/`e`/`i`/`I`/`M`/`C`/`s`/`f`/`t`).
  - Pre-`jsonDecode` duplicate-key scanner — captures repeated `sleuthMetadata` keys in raw source (e.g. `"device": "iPhone", "device": "Pixel"`) and fails parse so a merge conflict or careless edit cannot silently flip captured provenance (RFC 8259 §4 silently takes last write).
  - UTF-8 BOM strip, CRLF / lone-CR normalisation before decode.
  - `_flutterVersionPattern` accepts optional pre-release (`-1.0.pre`) and build-metadata (`+channel-stable`) suffixes on the pinned major.minor; pin stays strict on major.minor (3.32), patch and suffix free.
- **`validateBracket()`** — below / at / above triad rule against three captures spanning a threshold (±10% at-band default). Provenance cross-check iterates `device`, `deviceOsVersion`, `flutterVersion` across the triad and throws `FormatException` on any mismatch so a bracket cannot claim one environment in the at-capture while below was run on a different device.
- **AB-1 cross-check** — trace-vs-observed ratio invariant. Span bound to `scenarioBeginMarker` / `scenarioEndMarker` instant pair (ph=`i`), not min/max across the whole capture, so a claim against a specific event is measured against that event, not adjacent work noise. `maxObservedToSpanRatio = 100`.
- **Shared audit-invariant module** (`test/validation/_support/audit_invariants.dart`) — five invariants shared between detector and component audit gates: rationale non-empty, tier-appropriate fields, citation URL (parseable http/https URI with authority, host rejection for RFC1918 IPv4 `10/8`/`172.16/12`/`192.168/16`, link-local `169.254/16`, IPv6 `fe80::/10` link-local, IPv6 `fc00::/7` ULA — family-discriminated via `InternetAddress.tryParse`), reproducer-file contract (AST-based gate via `package:analyzer` — `_ReproducerAstVisitor extends RecursiveAstVisitor` flips `hasTestInvocation` only on real `test(...)` / `testWidgets(...)` `MethodInvocation` nodes; credits required tokens only when they appear as `SimpleIdentifier` AST nodes, not inside string literals or comments; `${test(...)}` interpolation expressions correctly credited), capture-schema contract (every declared capture run through `ProfileCaptureSchema.parseFile`). Path-traversal defence via `p.canonicalize` — absolute paths, `../../` escapes, and symlink escapes fail the gate even if the target file exists. Block-comment-aware citation parsing.
- **`test/validation/profile_capture_schema_test.dart`** (+27) — unit coverage: happy-path parsing against anchor + bracket fixtures; negative parsing against bad fixtures (`missing_device.json`, `bad_iso_date.json`, `min_gt_observed.json`); programmatic negatives (missing traceEvents, non-approved device, non-approved OS on approved device, non-pinned Flutter version, zero / negative magnitude, ISO-8601 rollover at month 13 / day 45 / hour 25 / minute 60, millisecond fraction round-trip); encoding hardening (BOM stripping, CRLF normalisation); `validateBracket` positive + failure modes (swapped below/above, at above tolerance, missing file surfaces path, triad provenance mismatch on each of device / OS / Flutter); dormant-gate fake `DetectorMetadataProvider` at `runtimeVerified` walking every `profileCapturePaths` code path ahead of v0.16.4.
- **`test/validation/profile_capture_schema_anchor_test.dart`** (+3) — grounds schema against the anchor DevTools export fixture; pins device, OS, Flutter major.minor.
- **`test/validation/component_metadata_audit_test.dart`** (+9) — audit gate for non-detector components. Mirrors the five detector invariants against synthetic `ComponentMetadata`. `_expectedRegisteredComponents` empty for v0.16.2; first real entry lands v0.16.6. Invariants 2–5 (rationale, tier-appropriate fields, reproducer-file contract, capture-schema contract) run against synthetic `ComponentMetadata` today; invariant 1 (registration dispatch) wired but only exercises a trivial empty-expected-list loop until v0.16.6.
- **`test/validation/ledger_sync_test.dart`** — counts per-tier rows between `## Ledger` and `## Non-Detector Components` headings in `doc/validation_ledger.md`, cross-checks against `detectorsForAudit` tier counts AND the `N / TOTAL at \`tier\`` summary denominator. A tier raise in code without a corresponding ledger update (or vice versa) fails CI.
- **Filesystem-walk gates** — new tests walk `lib/src/` for `class X ... with ComponentMetadataProvider` patterns asserting each declared class appears in `_expectedRegisteredComponents`; parallel walk over `lib/src/detectors/` for `class X extends BaseDetector` cross-checked against `controller.detectorsForAudit` runtime types (skipping `_`-prefixed privates and `SimpleStructuralDetector`). A component that publishes metadata but forgets its `registerMetadata()` dispatch, or a detector file shipping without controller registration, is a hard failure.
- **Public API coverage test** — `validation_public_api_test.dart` extended to assert `ComponentMetadata`, `ComponentMetadataProvider`, and `ProfileCaptureSchema` are reachable through the public `package:sleuth/sleuth.dart` barrel.
- **Anchor fixture byte fingerprint** — SHA-256 pin on `anchor_devtools_export.json` via `_expectedAnchorSha256` const. Intentional updates (e.g. replacing synthetic anchor with real DevTools export in v0.16.4) require updating the constant in the same PR — one-line diff flags "anchor changed" for reviewers.
- **Capture fixtures** — 3 dormant-gate bracket fixtures (`dormant_bracket_below.json`, `_at.json`, `_above.json`) synthesised around a 1000 ms threshold; anchor DevTools export (`anchor_devtools_export.json`) as shape-faithful synthetic (to be replaced in-place with real DevTools export at first v0.16.4 raise); 3 negative fixtures (`missing_device.json`, `bad_iso_date.json`, `min_gt_observed.json`). 6 fixtures padded with 11 synthetic events each so invariant-under-test surfaces instead of blanket "no events" rejection. Provenance ledger in `test/validation/captures/_fixtures/README.md`.
- **`doc/reference_devices.md`** — pinned reference-device matrix (iPhone 13 mini + iOS 17.6.1 / Pixel 7 + Android 14 / Flutter 3.32.x) + annual rotation policy (dedicated release, not silently inside a tier-raise PR).
- **`test/validation/captures/README.md`** — capture authoring checklist for contributors raising a detector / component to `runtimeVerified`.
- **`CONTRIBUTING.md`** — top-level contribution guide with validation pointers, analyzer / test gates, tier-raise artefact requirements.

### Changed

- **`DetectorMetadata.profileCapturePath` (`String?`) → `profileCapturePaths` (`List<String>?`)** — bracketing rule requires three captures per threshold (below / at / above). Audit gate asserts **exactly 3** entries at `runtimeVerified` / `externallyCited` via `_expectBracketCaptures(label, meta, failures)`; every declared capture run through `ProfileCaptureSchema.parseFile` so malformed captures fail CI.
- Public barrel (`lib/sleuth.dart`) exports `ComponentMetadata`, `ComponentMetadataProvider`, `ProfileCaptureSchema`. `ValidatedComponentRegistry` intentionally NOT exported (`@internal`).
- `pubspec.yaml` — `package:meta ^1.15.0` promoted to direct dep (was transitive); `package:analyzer ^6.0.0` added as dev-only dep for the AST reproducer gate (not re-exported).

### Migration

Source-breaking on `DetectorMetadata`. Zero real detectors set `profileCapturePath` in v0.16.1 (all `runtimeVerified` slots empty until v0.16.4), so no in-tree callers. Forks carrying a `runtimeVerified` raise:

```diff
-  profileCapturePath: 'path/to/capture.json',
+  profileCapturePaths: ['path/to/capture.json'],
```

Patch-milestone bump (0.16.1 → 0.16.2) — v0.16 line is pre-1.0 validation infrastructure; no shipping detector relies on the field.

### Notes

- Test count: 2,238 → 2,391. `fvm flutter analyze` clean, `fvm flutter test` all green (example 9/9).
- Spec OQ1 (anchor-fixture provenance) and OQ4 (pair-matched device policy) from `doc/spec_v0_16_validation_methodology.md` resolved in-release; remaining OQs carry through to v0.16.3+.
- Deferred to v0.16.3: ledger-sync coverage of the `else`-branch dormant path (fires once a component registers, target v0.16.6).


## 0.16.1

**Per-detector validation — first milestone.** Rolls the v0.16.0 methodology
contract onto the detector surface: every shipped detector now declares a
`DetectorMetadata` entry; `NetworkMonitorDetector` is the first detector to
ship at `EvidenceTier.reproducerOnly` with a hermetic reproducer. The CI
audit gate deferred from v0.16.0 lands alongside, enforcing the contract on
every subsequent milestone.

### Added

- **`test/validation/detector_metadata_audit_test.dart`** — the audit gate
  deferred from v0.16.0. Walks `SleuthController.detectorsForAudit` (a new
  `@visibleForTesting` getter that filters out user-authored
  `config.customDetectors`) and asserts per-detector invariants published in
  `DetectorMetadata`'s doc: mixin presence, non-null metadata, non-empty
  rationale, tier-appropriate fields (`reproducerOnly` / `runtimeVerified` →
  `reproducerPath` non-null; `externallyCited` → `citationUrl` + `reproducerPath`
  non-null), and file-exists check on declared reproducer paths when the
  test CWD is the package root. A final pin-test anchors
  `NetworkMonitorDetector` at `reproducerOnly` so a future demotion fails a
  test instead of silently regressing the reliability ledger.
- **`test/validation/network_monitor_reproducer_test.dart`** — two-layer
  hermetic reproducer cited by `NetworkMonitorDetector.validationMetadata
  .reproducerPath`. Layer 1 exercises `processRecord` at the exact threshold
  boundaries (999/1000/2999/3000/3001 ms) and asserts the `critical > slow`
  reachability invariant. Layer 2 drives the full pipeline
  (`SleuthHttpOverrides → _MonitoringHttpClient → _MonitoringRequest →
  _MonitoringResponse → RequestRecord → processRecord`) against a loopback
  `HttpServer`, proving the proxy measures real durations and emits records
  that reach the detector.
- **`SleuthController.detectorsForAudit`** — `@visibleForTesting` getter
  exposing the registered built-in detectors (custom detectors filtered
  out). The audit gate's access point.

### Changed

- **22 built-in detectors bulk-seeded at `EvidenceTier.unvalidated`.** Every
  detector now mixes in `DetectorMetadataProvider` and returns a
  `const DetectorMetadata` with a detector-specific rationale describing what
  heuristic or threshold is not yet runtime-verified. Subsequent milestones
  raise one detector at a time. The metadata is non-breaking — it adds
  surface, not required parameters.
- **`NetworkMonitorDetector` is the first detector at
  `EvidenceTier.reproducerOnly`.** `reproducerPath` points at the new
  hermetic test file. The detector's 1000 ms / 3000 ms thresholds and the
  `critical > slow` reachability invariant are now covered by the two-layer
  reproducer.
- **`DetectorMetadata` + `DetectorMetadataProvider` doc comments tightened.**
  `DetectorMetadata` now documents the audit gate as live since v0.16.1 with
  the exact tier-appropriate field requirements the gate enforces.
  `DetectorMetadataProvider` drops the unreachable "landing with the first
  per-detector validation PR" claim (v0.16.1 IS that PR) and states the
  honest contract: v0.16.1 seeds every shipped detector, subsequent
  milestones raise one at a time.

### Fixed

- **`SleuthHttpOverrides` + `drain()` / `.asFuture()` terminal-event leak
  (AB1).** `_MonitoringResponse.listen()` previously returned the inner
  subscription directly and relied on its wrapping `onDone` closure to emit
  the `RequestRecord`. `Stream.drain()` internally calls `listen(null,
  cancelOnError: true).asFuture(futureValue)` and
  `StreamSubscription.asFuture()` REPLACES the subscription's `_onDone` —
  so any consumer using `drain()` or `.asFuture()` silently lost the
  terminal event and the proxy never emitted. `_MonitoringResponse.listen()`
  now returns a new `_MonitoringSubscription<T>` wrapper that (a) overrides
  `asFuture` to complete from a proxy-owned `Completer<void>` rather than
  delegating to `_inner.asFuture`, preserving the terminal-event emission
  regardless of how the caller consumes the stream; (b) overrides `cancel`
  to fire the terminal emit before cancelling so early-abort consumers
  still produce a `RequestRecord`; and (c) delegates all other
  subscription operations (`onData`/`onError`/`onDone`/`pause`/`resume`/
  `isPaused`) to the inner subscription unchanged. The reproducer now
  includes regression tests for both `drain()` and `.listen(...).asFuture()`
  consumption paths.
- **Example `network_stress_demo.dart` FIX bodies use `await for` (AB0).**
  The FIX demonstrations for cached (`_triggerCached`) and paginated
  (`_triggerPaginated`) flows previously used `response.drain<void>()` and
  `response.listen(...).asFuture<void>()` respectively — contradicting the
  inline warnings in the BAD bodies and silently bypassing the very
  detector the milestone advertises. Both switched to the same `await for`
  pattern used in the BAD bodies, with matching comments explaining the
  terminal-event constraint.

### Notes

- Test count: 2,225 → 2,238 (+8 reproducer + 5 audit gate).
- Plan approved after deep-plan + scope-confirmation.

## 0.16.0

**Validation methodology** — infrastructure milestone that introduces the
contract Sleuth will use to certify every detector threshold and feature
heuristic. Does not validate any individual detector's numbers — that work is
split across follow-up milestones (v0.16.1…v0.16.N), each raising one
detector's `EvidenceTier` with a linked reproducer. This release ships the
methodology itself: the tier enum, per-detector metadata mixin, reproducer
harness pattern, and four HEAD bugfixes surfaced during methodology plan review.

### Changed

- **`FrameTimingDetector` warmup is duration-gated (C1).** Added
  `warmupDuration` constructor parameter (default 3 s) combined AND-wise with
  `warmupFrameCount`. Jank evaluation now requires both gates: enough frames
  seen AND enough wall-time elapsed since the first frame. The prior
  `warmupFrameCount: 180` default silently under-warmed on 120 Hz devices (180
  frames ÷ 120 Hz = 1.5 s, not the intended 3 s window). Defaults in
  `SleuthConfig` now carry the duration (`frameTimingWarmupDuration`) and
  lower the frame count to 0 — the duration gate is the primary knob.
- **Per-detector exception isolation widened (C2).** Prior to v0.16.0, only
  `checkElement` / `afterElement` were wrapped in per-detector try/catch. One
  misbehaving detector in `prepareScan`, `notifyWalkCompleted`, `finalizeScan`,
  or the legacy `scanTree` loop would halt the unified walk and prevent
  sibling detectors from running. All five scan-loop stages now wrap each
  detector individually with `debugPrint` in the `assert` block so a crash
  surfaces in debug builds and is isolated in release.
- **VM reconnect ladder widened 7 s → ~31 s (C3).** Extended the reconnect
  backoff sequence in `VmServiceClient` from `[1 s, 2 s, 4 s]` to
  `[1 s, 2 s, 4 s, 8 s, 16 s]` to match the ~30 s reconnect window the
  CLAUDE.md docstring already advertised. Improves recovery on real-device
  runs where a USB/WiFi hiccup can drop the VM for > 7 s.
- **`PerformanceIssue.fromJson` defensive casts (C4).** `topAllocators`,
  `rankingScore`, `rankingBreakdown`, and `downstreamIds` now use
  `is`-guarded type checks matching the existing `scaffoldHashKey` /
  `tabVisitIndex` defensive pattern. A malformed payload from a JavaScript
  consumer (53-bit number coercion) or an out-of-version snapshot no longer
  crashes the deserializer — offending entries are silently dropped to null /
  filtered out.

### Added

- **`lib/src/validation/evidence_tier.dart`** — frozen 4-tier enum
  (`unvalidated`, `reproducerOnly`, `runtimeVerified`, `externallyCited`)
  ordered weakest-to-strongest. New tiers require a semver major bump.
- **`lib/src/validation/detector_metadata.dart`** — `DetectorMetadata` data
  class + `DetectorMetadataProvider` mixin. Every shipping detector will
  expose a metadata entry describing its strongest evidence tier, a one-to-
  two sentence rationale, optional citation URL
  (`externallyCited`), and optional reproducer path (`reproducerOnly` and
  above).
- **`doc/spec_v0_16_validation_methodology.md`** — full spec including
  dependency diagram, per-step implementation plan, risk table, reproducer
  harness pattern, and Plan Review Pass.

### Deferred (to follow-up milestones)

- **`test/validation/detector_metadata_audit_test.dart`** — CI audit gate that
  walks every concrete `BaseDetector` and asserts non-null metadata. Deferred
  to the first per-detector validation PR so the audit fires meaningfully
  rather than on a 23-detector `unvalidated` seed commit.
- **Per-detector metadata seeding.** Each follow-up milestone raises one
  detector's tier with a linked reproducer; seeding happens alongside that
  PR, not as a bulk change.
- **Validating the 23 detectors' numbers.** That is the *point* of shipping
  this methodology — v0.16.0 is the contract, v0.16.1+ is the application.

### Post-implementation hardening (11 fixes)

Multiple review passes on the v0.16.0 diff folded the following
robustness fixes into the release:

- **Warmup gate reads monotonic vsync, not per-callback wall clock.**
  The initial fix used `DateTime.now()` stamped once per
  `addTimingsCallback` batch. Flutter can deliver many frames in a
  single callback — a cold start with 60+ buffered frames collapsed to
  one `DateTime.now()` tick — keeping the 3 s gate closed far past the
  intended warmup window. `FrameTimingDetector` now tracks
  `_firstFrameVsyncUs` (from `FrameTiming.vsyncStart`) and measures
  elapsed warmup against `frames.last.vsyncStartUs - _firstFrameVsyncUs`.
  Falls back to wall-clock only when `vsyncStartUs` is null (synthetic
  test frames). New `@visibleForTesting handleTimingsForTest(...)`
  bridge drives the real `_onTimings` pipeline from unit tests.
  Regression test feeds 200 `FrameTiming`s spanning 500 ms and asserts
  the gate stays closed.
- **`PerformanceIssue.fromJson` per-entry allocator hardening.** The
  outer `topAllocators` List-shape guard let a payload like
  `{'topAllocators': [{'className': 42}]}` crash inside
  `AllocationEntry.fromJson`'s strict casts. Added
  `_tryParseAllocationEntries` helper that wraps each entry parse in
  try/catch — malformed entries drop silently, valid siblings survive.
  Regression tests cover JS-string-coercion, mixed valid/invalid,
  stringified `rankingScore`, and mixed-type `downstreamIds`.
- **Validation API exported from `lib/sleuth.dart`.** `EvidenceTier`
  and `DetectorMetadataProvider` were reachable only via
  `package:sleuth/src/validation/...`. Added the `export` lines and a
  `test/validation/validation_public_api_test.dart` smoke test that
  imports ONLY the public barrel.
- **`PerformanceIssue.fromJson` guarded enum parsing.** Required enum
  fields (`severity`, `category`, `confidence`) and optional enum
  fields (`observationSource`, `interactionContext`, `fixEffort`) were
  doing raw `IssueSeverity.values.byName(...)`. A payload with
  `severity: 42` (JS coercion) or `severity: 'warn'` (typo) aborted
  the whole snapshot. Added `_tryParseEnum<T>` helper and routed all
  six enum fields through it. Required fields fall back to neutral
  defaults; optional fields drop to null.
- **`_tryParseAllocationEntries` narrowed catch.** The helper used
  bare `catch (_)`, swallowing `StackOverflowError`, `OutOfMemoryError`,
  `StateError`, and other `Error` subclasses signalling VM instability.
  Narrowed to `on TypeError catch (_)` + `on Exception catch (_)`.
- **`EvidenceTier` ordering fully pinned.** Smoke test asserted only 2
  of 4 ordinals. Strengthened to pin the full name sequence + ordinal
  sequence so any reorder/rename of the stable-contract enum fails.
- **`DetectorMetadataProvider` API contract clarified.** The mixin
  docstring claimed detectors would implement via a static `metadata`
  field "so the audit test can reflect on types without constructing
  instances." Dart does not treat static members as class interface
  members; a static field on a mixin subtype is not reachable
  polymorphically. Replaced docstring with the honest contract:
  `validationMetadata` is an instance getter backed by a `const`
  literal, the audit walks `SleuthController`'s registered instances,
  detector constructors must be side-effect-free.
- **Stage wrappers profile-safe + detector quarantine.** Per-detector
  try/catch in `_runStructuralScans` used `assert(() { debugPrint(...);
  return true; }())`. `assert()` is stripped in profile mode (Sleuth's
  primary runtime target), so a misbehaving detector failed silently.
  Additionally, a detector that threw in `prepareScan` was still called
  in every subsequent stage. Combined fix: (1) replaced all seven
  assert+debugPrint blocks with
  `FlutterError.reportError(FlutterErrorDetails(...))` which survives
  profile-mode compilation, and (2) added per-scan
  `Set<BaseDetector> failedDetectors` consulted at the top of every
  subsequent per-detector stage. Eight regression tests verify both
  contracts.
- **Aggregation filter for failed detectors.** The quarantine only
  suppressed *later* stage callbacks. Aggregation —
  `_getAllIssues()` / `_collectHighlights()` — still spread `...d.issues`
  and `...d.highlights` for every detector. A detector that committed
  49 findings before throwing on element 50 leaked those into
  `issuesNotifier`. Promoted the per-scan `failedDetectors` set to a
  controller-owned field consulted at both aggregation sites.
- **`PerformanceIssue.fromJson.detectedAt` used unguarded
  `DateTime.parse`.** Malformed ISO strings or non-string payloads
  threw and aborted the whole factory. Replaced with `... is String
  ? DateTime.tryParse(...) : null` so a malformed timestamp degrades
  a single field to null instead of poisoning the snapshot.
- **Detector-failure tests tightened.** `_ScopedErrorCapture` now
  forwards to `_previous?.call(details)` so framework errors still
  propagate. Per-stage matchers asserted `expect(matching, isNotEmpty)`
  which passed even if a stage accidentally emitted twice; tightened
  to `matching.length == 1` AND `nonMatching` is empty. Every test
  that expects a thrown detector error now drains it with
  `tester.takeException()`.

### Notes

- Test count: 2,220 → 2,225.
- `fvm flutter analyze` → 0 issues. `fvm flutter test` → all pass.
- F2 (`PerformanceIssue.fromJson` enum-drift cascade) deferred to v0.17
  MCP milestone; the factory carries an explicit lossy-import scope
  note pointing at v0.17 as the first-class import milestone.

## 0.15.5

Single-milestone UX patch that replaces the overlay's live-reordering
"card jumps while I read it" bug with a **freeze-above-on-expand**
contract. While any card is expanded, every row at and above the
deepest expanded index is frozen against what the user last saw; only
the flow section beneath keeps reordering. Collapsing the last
expanded card releases the freeze. Delivers the user's literal ask:
"while I expand an issue card, reordering issue incoming / exist will
be happen below index issue that im expanded." Supersedes the
unshipped "single-card pin-on-expand" iteration, which held only the
expanded card's slot and still let newly-critical issues re-rank
above it.

### Changed

- **`FloatingIssuesCard` state model** replaces the prior single-map
  with two coupled fields: `Map<String, int> _expandedIndices`
  (issueKey → captured-snapshot-index) and
  `List<PerformanceIssue>? _orderSnapshot` (the visible list at the
  first 0→1 expand). Class invariant
  `(orderSnapshot == null) == expandedIndices.isEmpty` is asserted at
  the entry of `applyFreezeZone`. All five mutation sites update both
  fields in the same `setState` so a frame never renders against
  half-set state: 0→1 expand, 1→0 collapse, `dispose`, `didUpdateWidget`
  controller swap, and `_pruneStaleState` when eviction empties the map.
- **Snapshot sourced from what the user saw (C1).** The
  `onExpandedChanged` closure binds a local `capturedVisibleIssues`
  copy of the `visibleIssues` list the `itemBuilder` was built from on
  this pump — not `widget.controller.issuesNotifier.value` at tap
  time. Prevents a ranker tick between build and tap from seeding the
  frozen zone with a list the user never saw.
- **`_pruneStaleState` keys freeze eviction against
  `computeVisibleIssues(issues)`** so downstream children churning
  under an expanded parent don't leak the parent's entry. Selection
  and chat stale-state checks stay on raw keys because those surfaces
  reach ALL issues (including downstream ones surfaced via expansion).
- **Pin icon (`Icons.push_pin`, 14dp, `textSecondary` @ 55%)
  repositioned** from slot 4 (between confidence and JANK) to the last
  chip slot (after `↳N`, before Checkbox) — reads as a "this row is
  held" state marker, not severity chrome. Unconditional `Semantics`
  wrap preserved (empty label + `excludeSemantics: true` when
  collapsed) so a11y node identity stays stable across toggles.

### Added

- **`applyFreezeZone` top-level `@visibleForTesting` helper** — the
  render-time transform. Takes `(visibleIssues, orderSnapshot,
  expandedIndices)`; returns a list whose first `freezeEnd + 1` entries
  follow `orderSnapshot` (resolved against live `PerformanceIssue`
  instances so severity/confidence updates still render) and whose
  remainder is the ranker flow with frozen keys filtered out.
  - **MAX rule:** `freezeEnd = max(expandedIndices.values)`. Multi-
    expand freezes `[0..max]` inclusive — cards between two expanded
    cards are held by design. MIN would still let rows above the
    second expanded card shift; MAX is the simplest rule that
    satisfies "nothing above anything I'm reading moves."
  - **Silent-drop on vanished frozen entry** (no throw;
    `_pruneStaleState` evicts the expand entry on its next sweep).
  - **Clamp on out-of-range:** `freezeEnd` is clamped to
    `min(snapshotLen − 1, visibleLen − 1)` so downstream collapses
    render rather than throw.
  - **Entry assert** enforces the class invariant and (post-impl SF3)
    includes `expandedIndices.keys` in the failure message so a
    tripped assert distinguishes a zombie key from a snapshot-only
    half-state during post-mortems.

### Fixed

- **Reading-an-expanded-card reorder bug** (primary symptom):
  `_applyDurationEscalation` flipping warning→critical at 30 cycles, a
  new CRITICAL arriving mid-read, or any other ranker churn no longer
  shuffles rows above the expanded card out from under the cursor.
- **New-critical arrival cannot appear above a card being read** — it
  enters the flow section beneath the frozen zone until the user
  collapses. Accepted tradeoff the user explicitly asked for; without
  it the freeze contract is meaningless.
- **Snapshot coupling bugs** — every mutation site now clears both
  fields together, so a stale `_orderSnapshot` paired with an empty
  `_expandedIndices` can't survive to the next frame and trip the
  invariant assert.

### Notes

- Known pre-existing tradeoff (out of scope, not a v0.15.5 regression):
  at 300dp overlay width with `title + confidence + JANK + ↳N + pin +
  Checkbox` all present, the header `Row` overflows ~40dp in the
  Checkbox tail. The pin itself stays within card bounds — F5
  regression test asserts this. Checkbox density is a v0.15.6+
  follow-up.
- **Known gap (SF4, accepted):** if a frozen *non-expanded* neighbour
  is evicted mid-read (detector staleness, `computeVisibleIssues`
  absorbing a standalone under a new root, downstream collapse), the
  frozen zone compacts and visibly shifts the expanded card up by one
  slot. Low-frequency (requires multi-scan eviction while actively
  reading); self-heals on the next `_pruneStaleState` sweep. A
  placeholder-row approach would close it at the cost of visible
  "ghost" rows; deferred.

### Tests

- +24 tests. `test/ui/floating_issues_card_test.dart` adds 11 pure-
  function `applyFreezeZone` cases — user's-exact-symptom at index 2,
  multi-expand MAX, disappeared frozen entry, snapshot-shorter and
  visible-shorter clamps, flow-order preservation, two invariant
  assert cases, plus post-impl SF2 `freezeEnd=0` and
  `freezeEnd=length-1` boundary cases — and 5 widget smoke tests
  (pin-icon visibility on expand, summary-bar count invariance,
  `dispose` dual-clear, `didUpdateWidget` controller-swap dual-clear,
  collapse releases snapshot). `test/ui/issue_card_test.dart`
  pin-indicator tests preserved under the renamed group
  `v0.15.5 freeze-above-on-expand pin indicator`, including the F5
  regression that pins the icon within card bounds at 300dp.

Plan: `doc/spec_v0_15_5_freeze_above_on_expand.md`. Post-impl
review produced 4 findings, all applied (SF1 renamed
stale `_pinnedIndices` / "pin-on-expand" doc-comment references in
`floating_issues_card.dart` and `issue_card.dart` to the new
vocabulary; SF2/SF3/SF4 per above). Test count: 2,170 → 2,194.

## 0.15.4

Single-milestone patch from `doc/detector_threshold_audit.md` §7 M3:
align `NetworkMonitorDetector` slow-request thresholds with 2025–2026
mobile-API guidance and close the asymmetry where the warning tier was
constructor-configurable but critical was hardcoded.

### Changed

- **Defaults lowered in lockstep** (industry guidance: ideal 100–300 ms,
  "slow" ~1 s, "very slow" ~3 s):
  `NetworkMonitorDetector.slowThresholdMs` 2000 → 1000,
  critical boundary 5000 → 3000,
  `SleuthConfig.slowRequestThresholdMs` 2000 → 1000.

### Added

- **`NetworkMonitorDetector.criticalSlowThresholdMs`** (default 3000) —
  promotes the previously hardcoded `_criticalSlowThresholdMs` constant
  to a constructor parameter.
- **`SleuthConfig.criticalSlowRequestThresholdMs`** (default 3000) —
  threaded through at `sleuth_controller.dart:684`.
- Debug-mode assert on both: `critical > slow` (also fires from
  `copyWith`, so `SleuthConfig().copyWith(slowRequestThresholdMs: 5000)`
  without also raising critical now throws instead of silently producing
  an unreachable critical tier). Both additions are non-breaking
  (optional params with defaults).

### Tests

+5 net. `network_monitor_detector_test.dart` gains boundary tests
(`2999 ms warning`, `3000 ms critical`), custom-threshold test, and
assert-fires test (equal + less-than). Pre-existing tests hardcoded to
2000/5000 rewritten to new defaults. `config_copy_with_test.dart` gains
assert-coverage test. `v2_integration_test.dart` pass-through extended.
2,166 → 2,170.

### Migration

To restore v0.15.3 behavior: `SleuthConfig(slowRequestThresholdMs: 2000,
criticalSlowRequestThresholdMs: 5000)`.

---

## 0.15.3

Single-milestone patch from `doc/detector_threshold_audit.md` §7 M1:
animation-aware filter on `RepaintDetector`. Closes the asymmetry where
`RebuildDetector` already exempts builder widgets via a 3× multiplier
but `RepaintDetector` had **zero** filter — any widget at ≥30 paints/sec
fired `excessive_repaint`, so a `CircularProgressIndicator` in a top bar
tripped the detector on every session.

### Added

- **`lib/src/utils/animation_owner_names.dart`** — canonical
  `@visibleForTesting` Set of 21 widget types that drive intentional
  frame-rate animations: 5 indicators (`CircularProgressIndicator`,
  `LinearProgressIndicator`, `RefreshProgressIndicator`,
  `CupertinoActivityIndicator`, `RefreshIndicator`), 3 generic builders
  (`AnimatedBuilder`, `ValueListenableBuilder`, `TweenAnimationBuilder`),
  12 implicit `Animated*` widgets (`AnimatedContainer`, `…Rotation`,
  `…Scale`, `…Size`, `…Opacity`, `…Align`, `…Padding`, `…Positioned`,
  `…PositionedDirectional`, `…Slide`, `…Switcher`, `…CrossFade`,
  `…FractionallySizedBox`), and `Hero`. Shared by detector + coordinator.
- **Per-paint owned attribution** at `_handleProfilePaint` — calls
  `isAnimationOwnedPaint(element, chain)` against the live `Element`
  and exposes results via `DebugSnapshot.animationOwnedPaintCounts`
  (Map) + `totalAnimationOwnedPaintCount` (int). Three cheapest-first
  legs: (1) chain-string regex, (2) typed ancestor walk (`maxDepth=16`),
  (3) typed descendant walk (`maxVisits=32`, `maxDepth=4`).

### Changed

Three-gate filter in `RepaintDetector`:
- **Gate A (per-widget debug):** skip `repaint_debug_$typeName` when
  the typed walk proves ownership.
- **Gate B (VM aggregate fallback):** suppress the VM gate when every
  non-zero `paintCounts` entry is owned. Empty map = no signal = fire
  normally (never silently mask a real bug).
- **Gate C (debug aggregate):** residual subtraction —
  `residualCount = totalPaintCount − ownedCount`, recompute
  `residualRate`, suppress when below threshold; otherwise surface
  `Excludes N animation-owned paints` suffix in detail.

### Why this design (KDDs)

- **KDD-2** chain-containment (not Ticker reflection) is cheaper,
  deterministic, and matches coordinator output; generic-stripping via
  `indexOf('<')` before Set lookup handles `TweenAnimationBuilder<T>`.
- **KDD-3** residual subtraction at Gate C preserves `excessive_repaint`
  signal when surrounding scene over-paints but owners are accounted for.
- **KDD-4** full exemption (repaint) vs 3× multiplier (rebuild) is
  deliberate — a `CircularProgressIndicator` *must* paint at refresh
  rate; rebuild rate on the same widget is more ambiguous.

### Post-impl hardening (5 findings, C1–C5)

Root cause of all five: ownership was inferred from a chain-string keyed
on `runtimeType` — a human-readable debug aid, not a robust ownership
signal. Fix moves detection to per-paint typed walks against the live
`Element`.

- **C1 polymorphic-key collision:** two `CustomPaint` widgets sharing a
  `typeName` (one inside `AnimatedBuilder`, one driven by external
  `setState`) shared one cached chain; both got fully suppressed or
  fully fired. Fixed via per-paint attribution (above).
- **C2 insufficient owner set:** original 7 entries missed the entire
  `Animated*` family + `Hero` + `RefreshIndicator`. Expanded to 21.
- **C3 chain-walks-up gap:** a bare `CircularProgressIndicator` (no
  wrapping `RepaintBoundary`) propagates the dirty mark UP to the
  nearest layer-owning ancestor, so the chain walks UP from that
  ancestor and CPI becomes a *descendant*, not an ancestor. Fixed via
  bounded descendant walk.
- **C4 chain capture exception safety:** `visitAncestorElements` can
  throw "deactivated widget's ancestor is unsafe" mid-tear-down — the
  exception used to unwind through `_handleProfilePaint` and kill the
  whole pipeline. Wrapped in try/catch at
  `debug_instrumentation_coordinator.dart`; chain enrichment is skipped
  for that event, counting continues.
- **C5 test fixture tautology:** only CPI had a real-widget test;
  everything else was hand-rolled fixtures mirroring the filter's own
  assumptions. New `test/detectors/repaint_animation_owners_real_widget_test.dart`
  adds 8 real-widget tests — each pumps the owner through
  `DebugInstrumentationCoordinator`, asserts non-empty
  `animationOwnedPaintCounts`, re-pins `elapsed: 100ms` to force Gate A
  logic. Immediately caught the `TweenAnimationBuilder<double>` vs
  `TweenAnimationBuilder` generic-stripping miss that hand-rolled tests
  could never have caught (anti-tautology real-widget coverage).

Additional discovery during C5: `RefreshProgressIndicator`'s painted
`CustomPaint` leaf sits ~13 ancestors below its `AnimatedBuilder` owner
(Material's `_buildMaterialIndicator` decoration stack). Both the
chain-string check and descendant walk missed it, which is why
`isAnimationOwnedPaint` needs the typed *ancestor* walk as a third leg.

### Test count

2,146 → 2,166. +10 gate-algebra tests + 1 real-widget CPI anti-tautology
test (ship); +8 real-widget owner-coverage tests + 1 owned-counts
contract extension (post-impl).

## 0.15.2

UX refactor of the rebuild-stats surface after a real-device profile review.
v0.15.1 surfaced rebuild attribution through both a `rebuild_hotspot_summary`
IssueCard (warning stream) AND an always-on chip; the IssueCard collided with
the ranker and KDD-5 inflations turned route entry into a warning storm.
v0.15.2 collapses both into a single always-on **expandable inline panel**.

### Changed

- **`_RebuildStatsBanner`** is now an expandable panel. Collapsed:
  `Rebuilds: N across M widgets` + chevron. Expanded: top-3 widget rows
  (rank, name, live-tweened count, normalised bar), Pause/Resume toggle
  that freezes rendered counts, `See all N →` link pushing
  `RebuildStatsPage` drilldown with the snapshot that was on screen, and
  `incl. inflations` footnote (inline KDD-5 disclosure). Reactivity via
  `Listenable.merge([issuesNotifier, routeHistoryNotifier])` — rebuilds
  on every scan tick + route push/pop. **Pause auto-clears on route
  change** so the user never reads stale data.

### Removed

- **`rebuild_hotspot_summary` rollup IssueCard** and all supporting
  machinery: `RebuildDetector._maybeEmitRollupIssue`, `_sessionElapsed`,
  `_formatElapsed`, `_activeRouteSession`, all four rate/duration
  constants, `BaseDetector.updateActiveRouteSession` hook,
  `IssueCard.onSeeAllRebuilds` parameter, `FixHintBuilder.rebuildHotspotSummary`,
  encyclopedia entry + 4 `relatedIssues` cross-references, and the
  `'rebuild_hotspot_summary'` stableId prefix mapping. `RebuildStatsPage`
  drilldown is unchanged — only the entry point moved.

### Added

- **`TweenAnimationBuilder` in `_frameworkWidgetDenyList`** — the panel
  uses it for the live count tween; the KDD-10 audit test caught it as
  missing. Without this addition, Sleuth would re-introduce a
  self-measurement leak on its own panel.
- 5 banner tests in `floating_issues_card_test.dart`: collapsed-by-default,
  expand reveals top-3 + footer, 4th widget NOT inlined (top-3 contract
  pin), tap "See all" pushes drilldown, pause freezes counts across live
  merges.

### Fixed

- **Profile-mode KDD-5 inflations no longer pollute the warning stream** —
  route entry no longer surfaces a critical-severity card for transient
  inflations that decay as the tree stabilises. Data still visible in the
  panel but as data, not a warning.

### Post-implementation hardening (12 findings)

**Critical:** **C1** paused-snapshot drift — `onTap` now takes
`overrideCounts`; footer passes `_paused ? _frozenCounts : null` so
drilldown opens with what was on screen, not live-drift. **C2** redundant
"See all N" on small routes — footer link gated on `widgetCount > _topN`.
**C3** stale test docstrings rewritten for the panel-only contract.
**High:** **H1** tap targets — pause wrapped in 28×28 SizedBox, "See all"
in 24-tall SizedBox, `HitTestBehavior.opaque + Center(widthFactor: 1)`
so inner GestureDetector wins against outer header (compromise vs
Material's 48dp, documented — ~330dp test budget vs ~446dp phone).
**H2** silent auto-resume — `onPauseDiscarded` callback fires on route
change; parent shows 2s "Pause cleared — route changed" snackbar.
**H3** KDD-5 collapsed-state glyph added then reverted on user feedback
(visual competition with `Icons.repeat`); caveat stays in expanded
footnote + drilldown only. **H4** empty-state snackbar verified through
C1 callback signature change. **Medium:** **F1** collapsed pause indicator
(`Icons.pause` 10dp @ 0.5 alpha) when `_paused`. **F2** `TweenAnimationBuilder<int>`
smell audited — `begin: 0` is the seed-only value, framework substitutes
current value as new begin on rebuild (canonical, no change). **F3/P3**
hoisted `Listenable.merge` into `late final _mergedListenable` in
`initState` to eliminate per-rebuild allocation churn. **TF2** drilldown
contract test extended — pause → mutate counts → tap "See all" → assert
drilldown shows frozen values via `find.descendant(of: RebuildStatsPage)`.

Test count after hardening: 2,153 → 2,146 (banner tests rebalanced).

## 0.15.1

Hotfix for two v0.15.0 defects caught by a real-device profile run. DevTools
reported ~50–100 rebuilds while Sleuth's Build Hotspot claimed **21,352** —
the drilldown was dominated by `FloatingIssuesCard`, `IssueCard`,
`TriggerButton`, `Container`, `Padding`, `ValueListenableBuilder`,
`FadeTransition`. The v0.15.0 pipeline was measuring itself.

### Fixed

- **KDD-10 — Framework widget contamination (self-measurement).** The
  framework emission gate at `framework.dart:3503` uses
  `debugIsWidgetLocalCreation`, whose `_isLocalCreationLocationImpl` fallback
  at `widget_inspector.dart:1801-1816` returns
  `!file.contains('packages/flutter/')` when `_pubRootDirectories == null`
  (default without DevTools). So `package:sleuth/...` classifies as "user
  widget" and is emitted through `FlutterTimeline.startSync`.
  `addPubRootDirectories` is `@protected` and additive-only, so framework-
  layer exclusion is unavailable. **Fix:** `_frameworkWidgetDenyList` in
  `DebugInstrumentationCoordinator.canonicalizeTypeName` — 48 framework
  widgets used under `lib/src/ui/` + 25 Sleuth overlay widget classes.
  Checked AFTER generic stripping so `ValueListenableBuilder<int>` collapses
  first. Filter is now five layers:
  `_denyList → isRenderObjectName → identifierRegex → genericStrip → frameworkWidgetDenyList`.
  Followup audit against Flutter 3.41.4 SDK source added 3 more identifier-
  shaped frame-phase scopes (`POST_FRAME`, `COMPOSITING`, `SEMANTICS`) that
  fire ~60/sec per frame.
- **KDD-9 — Absolute-total rollup threshold was time-blind.** v0.15.0's
  `> 100 / > 300` absolute gate tripped on any long-lived route regardless
  of baseline rate. Replaced with sustained-rate: `≥ 20 builds/sec` warning,
  `≥ 50 builds/sec` critical, gated by 30-build + 1.5s noise floor. Rate
  computed via injected `DateTime Function() clock` for deterministic tests.
  Title format: `"Build Hotspot: 22.0 builds/sec (110 across 4 widgets in 5.0s)"`.

### Added

- **`test/debug/overlay_denylist_audit_test.dart`** — CI gate walking
  `lib/src/ui/**/*.dart` enforcing three invariants: every
  `Stateless/Stateful/InheritedWidget` subclass is in the denylist; every
  framework widget from a curated candidate set actually used in overlay
  code is in the denylist; no stale framework entries remain.
- **`DebugInstrumentationCoordinator.debugFrameworkWidgetDenyList`** —
  `@visibleForTesting` accessor.
- Parameterized denylist tests + rate-based threshold tests using
  test-controlled clock. Disclaimer copy updated in 3 places
  (`rebuild_detector.dart` detail, encyclopedia entry,
  `rebuild_stats_page.dart` banner) so users know overlay widgets are
  excluded from the drain.

### Changed

- `RebuildDetector` constructor takes optional `DateTime Function() clock`
  (defaults to `DateTime.now`).
- `canonicalizeTypeName` docstring updated to "five-layer filter" with
  inline KDD-10 rationale.
- Framework widgets now filtered from profile-mode drilldowns — users with
  a genuine user-space `Container` hotspot must wrap in a named subclass
  (e.g. `class ProductRow extends StatelessWidget`) to surface it.
  Disclaimer text covers this tradeoff.

Test count: 2,140 → 2,153.

## 0.15.0

Profile-mode per-widget rebuild counting via `FlutterTimeline.debugCollect()`
attributed to the active `RouteSession`. When `enableDeepDebugInstrumentation`
is true in profile, each scan cycle drains the timeline, canonicalizes every
`BUILD` scope name, and merges into `RouteSession.rebuildCountsByType`. Surfaces
as a `rebuild_hotspot_summary` rollup issue (fires at >100 session rebuilds)
with a "See all rebuilds" drilldown page. Detectors that had only structural
signal (`RebuildDetector`, `ShallowRebuildRiskDetector`, `AnimatedBuilderDetector`,
`SetStateScopeDetector`) now upgrade confidence when counts agree.

### Added

- **`DebugSnapshot.source`** (`RebuildCountSource`: `none`/`debugCallback`/
  `flutterTimeline`). Only `flutterTimeline` snapshots flow into the rollup;
  `debugCallback` stays per-detector (KDD-1).
- **`DebugInstrumentationCoordinator.installProfileMode()/uninstallProfileMode()`** —
  flips `FlutterTimeline.debugCollectionEnabled` with install-time refusal if
  flag is already true (DevTools conflict, KDD-1 + R20). Hot-restart-tolerant.
- **`canonicalizeTypeName`** three-layer filter: drops framework frame scopes
  (`BUILD`/`LAYOUT`/`PAINT`/`FINALIZE TREE`), strips generics
  (`Provider<Foo>` → `Provider`), rejects non-identifier shapes via
  `^[A-Z][A-Za-z0-9_]*$`.
- **`RouteSession.rebuildCountsByType`** (Map) + **`totalRebuilds`** with
  additive per-scan merge + JSON round-trip.
- **`rebuild_hotspot_summary` rollup issue** (emitted when
  `source==flutterTimeline && session!=null && session.totalRebuilds > 100`;
  per-type issues still fire alongside).
- **`RebuildStatsPage` drilldown** reachable via `IssueCard.onSeeAllRebuilds`
  callback (caller-gated). **Snapshot-at-open semantics (M10)** — counts
  copied at construction, never live-updates.
- **`primeExistingElements()`** coordinator helper — seeds element-seen
  Expando so the very first rebuild is counted instead of consumed as a
  first-observation placeholder.
- Encyclopedia entry for `rebuild_hotspot_summary` with bidirectional
  `relatedIssues` links.

### Changed

- **Assert-wrapper restructure (M3, 4 sites):** `_installDebugInstrumentation`,
  `_scanTree` drain, `dispose()`, `_installHeavyFlags` now use explicit
  `if (kDebugMode) {} else if (!kReleaseMode && ...) {}` mode splits.
  Previously the entire rebuild-attribution pipeline was a silent no-op in
  profile mode because `assert(() {})` stripped.
- **Drain → attribute → route-switch ordering (M7):** counts always land on
  the pre-route-change session.
- **`_scanInProgress` re-entry guard (M5)** prevents double-drain + rate
  math corruption.
- **Coordinator construction gate widened (KDD-8):** instantiated when
  `enableDebugCallbacks || enableDeepDebugInstrumentation`.

### Fixed

- **Profile-mode rebuild attribution was a silent no-op in every prior
  release** (v1 review C1/C4) — first release that actually collects data.
- **`FlutterTimeline.debugCollectionEnabled` conflict path (R20)** — install
  refuses when flag is already true.
- **Test pollution via static `FlutterTimeline._buffer`** (C6) — every
  profile test saves/restores flag in `setUp`/`tearDown`.

### Notes

- **KDD-5 semantic gap:** profile-mode counts include widget inflations
  (same `BUILD` scope covers both inflations and setState rebuilds), so route
  entry shows transient elevated counts that decay. Disclaimer surfaces
  inline on rollup detail + drilldown page.
- **R3 test limitation:** widget tests run under `kDebugMode == true`, so
  M12 controller/coordinator tests inject a fake coordinator tagged
  `RebuildCountSource.flutterTimeline` to exercise the merge pipeline
  without profile-mode compilation. Full validation is the M1 probe under
  `fvm flutter run --profile` on a physical device.

Test count: 2,092 → 2,140.

## 0.14.1

Per-tab `RouteSession` tracking for tab-shell apps (`IndexedStack`,
`StatefulShellRoute.indexedStack`, `CupertinoTabScaffold`) that share one
`ModalRoute` across tabs — each tab now gets a distinct session instead of
being conflated. Inline `TabBar` / `TabBarView` / `PageView` swipes stay inside
the outer session. One pre-impl plan review + one post-impl code
review; both folded into the code.

### Added

- **`RouteSession.scaffoldHashKey`**: `identityHashCode` of the innermost
  visible `Scaffold` Element, or `null` for scaffold-free scans. Paired with
  `routeName` to form the session's compound key.
- **`RouteSession.tabVisitIndex`**: 1-indexed ordinal for repeat visits to the
  same `(routeName, scaffoldHashKey)` pair. Used by UI + markdown exporter to
  disambiguate (e.g. `/home` → `/home (tab-2)`).
- **`RouteSession.hotReloadGeneration`**: Debug-only counter incremented on
  Flutter hot reload so consumers can group pre/post-reload sessions. `0` in
  profile/release.
- **`PerformanceIssue.scaffoldHashKey` + `tabVisitIndex`**: Stamped at
  aggregation. `routeName` kept RAW (no `(tab-N)` suffix baked in) so group-by
  filters stay stable; use **`PerformanceIssue.routeDisplayName`** getter
  (`'$routeName (tab-$tabVisitIndex)'` when `> 1`) for human-facing labels.
  UI cards, AI chat, and issue-explanation substitution all route through it.
- **`TabBarView` / `PageView` boundary filter** in the scan visitor: these
  widgets keep multiple children alive simultaneously (no `Offstage`/
  `TickerMode`/`Visibility(!visible)` marker) and used to trip the
  multi-Scaffold sibling guard, silently aborting scans. Scaffold collection
  now stops at these widgets — inline sub-tab swipes stay inside the outer
  session and detectors still run against the active sub-page.

### Changed

- **`SleuthConfig.routeHistoryCapacity` default 20 → 50**: per-tab sessions
  exhaust the old default within a few tab switches. FIFO-eviction tests now
  configure an explicit smaller cap.
- **Session markdown exporter renders tab suffix** from `tabVisitIndex`.
- `packageVersion` `'0.14.0'` → `'0.14.1'`.

### Fixed (post-review)

- **C1 `tabVisitIndex` collision after FIFO eviction**: `_computeTabVisitIndex`
  now returns `max(tabVisitIndex) + 1` across matching history entries instead
  of `count + 1`. The count-based impl could duplicate a live session's index
  once older matching entries were dropped from the deque — producing identical
  `(routeName, scaffoldHashKey, tabVisitIndex)` tuples (the exact duplicate
  rows the feature was designed to prevent). Regression test drives 8 A↔B
  switches with `routeHistoryCapacity: 3`.
- **C2 hot reload did not close active `RouteSession`**: non-structural hot
  reload preserves Element identity, so the session-keying predicate saw
  unchanged `(routeName, scaffoldHashKey)` and the pre-reload session bled
  into post-reload frames with a stale `hotReloadGeneration = 0`.
  `_reassembleInternal()` now closes `_activeRouteSession`, republishes the
  history notifier, and nulls the pointer before incrementing the generation.
- **C3 `routeName` overwrite lost raw name**: `_aggregateIssues` used to stamp
  `"$rawName (tab-N)"` into `issue.routeName`, destroying the raw name needed
  for group-by filtering. Raw preserved; display surfaces use `routeDisplayName`.
- **E1 type-unsafe `fromJson`**: per-tab field deserialization now uses `is int`
  guards and coerces non-int to null. A JS consumer stringifying large ints
  (53-bit `Number` precision) used to crash `as int?` and break the snapshot.

## 0.14.0

Route Scoping — per-route FPS, issue aggregation, health scores, and export.
Data model + programmatic API retained; overlay UI (filter bar, summary row)
removed after on-device review (historical issues not surfaceable as cards
made the filter misleading). One review round, 5 findings fixed.

### Added

- **`RouteSession`**: per-route stats accumulated while a route is the active
  scan target — `healthScore` (0–100 composite: FPS 40pts + jank 30pts +
  issues 30pts, normalised to `fpsTarget`), `FrameStatsBuffer`, issue
  snapshots, scan cycle count, `toJson()`.
- **Passive route detection** via element tree walk during the unified scan
  — no `NavigatorObserver` required. Works with any router (go_router,
  auto_route, Beamer). Unnamed routes get synthetic `<unnamed-N>` names.
- **`Sleuth.routeHistory`**, **`Sleuth.routeHealthScore(name)`** static APIs.
- **`SleuthConfig.routeIgnorePatterns`** (exact + trailing `*` wildcard e.g.
  `/dialog*`) and **`routeHistoryCapacity`** (default 20, ring buffer).
- **`SleuthConfig.copyWith()`**: covers all 28 fields including 2 new route
  fields. Uses `_sentinel` pattern for nullable overrides.
- **Schema v4 export**: `SessionSnapshot.routeSessions` field with per-route
  frame stats, issue counts, health scores, FPS percentiles.
- **"Route Health" markdown table** in `Sleuth.exportSummary()` with health
  dots, FPS, issue counts, duration.

### Changed

- **Export FPS clamped to `fpsTarget`** globally + per-route (average + p50/
  p95/p99). Prevents ProMotion 120Hz idle screens from reporting values above
  the configured target.
- `packageVersion` `'0.12.1'` → `'0.14.0'`.

### Removed

- **Route filter bar + summary row from overlay**: historical issues aren't
  surfaceable as cards (only live issues appear), making the UX misleading.
  Data model, export, and programmatic API retained.
- **Route chip theme tokens**: `routeChipBg`, `routeChipSelectedBg`,
  `routeChipText`, `routeChipSelectedText`.

## 0.13.1

Dark/light mode toggle, design system tokens, `Icons.pets` brand icon, header
optimization, false-positive fix, GlobalKey demo reliability. Five
review rounds (general ×2, theme perf + design system, icon migration,
GlobalKey demo), all findings fixed.

### Added

- **`triggerIconColor` theme token** (default white — visible on severity-
  colored backgrounds in both themes).
- **In-overlay dark/light toggle** with 3-tier resolution: runtime override >
  config theme > auto-detect.
- **`Sleuth.updateTheme()`** runtime API (pass `null` to revert to auto).
- **`SleuthController.themeOverride`** `ValueListenable<SleuthThemeData?>`.
- **System brightness reactivity** via `didChangePlatformBrightness`, gated
  to auto-detect mode only.
- **Typography scale tokens** — 9 font sizes (`fontXxs`=8 → `fontDisplay`=24)
  on `SleuthThemeData`. All 8 overlay UI files migrated (~119 replacements).
- **Border radius scale tokens** — 7 radii (`radiusSm`=4 → `radiusFull`=20).
  All 8 overlay UI files migrated (~50 replacements).
- **`gripDots` light theme override** (`0xFF6B7280` gray-500 instead of the
  dark-theme white).
- **Color coupling doc** on `SleuthThemeData` constructor: intentional hex
  sharing across semantically distinct tokens + `copyWith()` independence.

### Changed

- **Brand icon: `Icons.pets`** (Material paw print) replaces dog emoji
  (`🐕`/`\u{1F415}`) and custom `SleuthLogoPainter` across trigger button,
  overlay header, guide page, example app. Tree-shaken, theme-aware.
- **Startup metrics page**: metric values right-aligned across all sections
  via `Expanded` + plain `Text`.
- **Header icon optimization**: guide icon moved to footer; highlight toggle
  36 → 24px (`_compactHeaderButton`); theme toggle added at 20px.
- **Footer Semantics consistency**: Encyclopedia/Export/Guide all wrapped in
  `Semantics(label: ..., button: true)`.

### Fixed

- **`stateful_density` false positive from Sleuth widgets**: added 8 overlay
  widget names (`SleuthOverlay`, `FloatingIssuesCard`, `TriggerButton`,
  `IssueCard`, `IssueEncyclopediaPage`, `AiChatPage`, `GuidePage`,
  `StartupMetricsPage`) to `RebuildDetector._frameworkWidgetNames`. FRAME
  mode no longer inflates structural density against itself.
- **Hardcoded spacing**: `SizedBox(width: 6)` (guide) + `SizedBox(width: 10)`
  (startup metrics) replaced with `theme.spacingXs`/`spacingSm`.
- **GlobalKey demo unreliable detection**: `itemExtent` 40 → 24dp, `itemCount`
  30 → 40 so realized GlobalKey count reliably exceeds the >20 threshold on
  all phone sizes. Old 40dp items + DemoScaffold chrome (~220-300dp) +
  trailing-only cache at scroll 0 left the count at 21-22 on medium phones
  (barely above threshold).

### Removed

- **`sleuth_logo_painter.dart`** — replaced by `Icons.pets`.

## 0.13.0

Startup Performance Tracing — measure first-frame and time-to-interactive
from `main()`, with per-phase breakdown and VM sub-phase enrichment. Three
review rounds, full 23-detector accuracy audit, causal-graph
correctness fix, and ShaderJankDetector noise removal.

### Added

- **Startup measurement API**: `Sleuth.init()` captures app start + framework
  init cost; `Sleuth.markInteractive()` records TTI; first-frame callback
  extracts vsync/build/raster breakdown from `FrameTiming`;
  `enrichStartupWithVmData()` accepts VM sub-phase + engine timestamp data.
- **`StartupDetector`** (23rd detector, structural lifecycle, one-shot): fires
  `slow_startup_ttff` when TTFF exceeds thresholds (default 1500ms warning,
  3000ms critical). Detail includes TTFF/TTI, first-frame breakdown,
  dominant phase, VM sub-phases, engine phases.
- **`StartupMetrics`**: 14 stored fields, 3 computed getters
  (`frameworkInitMs`, `preDartOverheadMs`, `engineTtffMs`), dominant-phase
  detection (50% threshold), full `copyWith`/`toJson`/`fromJson`.
- **`StartupMetricsPage`**: full-screen detail with staggered entrance
  animations, 5 conditional sections (headline, first-frame breakdown with
  progress bars, engine phases, VM sub-phases, methodology).
- **Startup metrics banner** in FloatingIssuesCard: tappable "TTFF: X ms ·
  TTI: Y ms" when data available.
- **`IssueCategory.startup`** across SleuthTheme, encyclopedia, FixHintBuilder,
  SessionMarkdownExporter, SessionSnapshot serialization.
- **`DetectorThresholds.startupTtffWarningMs`/`CriticalMs`** with validation
  asserts.

### Fixed

- **Causal graph hid `layout_bottleneck` from UI**: 8 rules made it a
  downstream effect (e.g. `setstate_scope → layout_bottleneck`). A downstream
  issue gets a `rootCauseId` and FloatingIssuesCard filters it from the
  visible list. Removed all 8 rules — `layout_bottleneck` is always a root
  cause. Rule count: 52 → 44.
- **`ShaderJankDetector` Impeller noise**: removed `shader_impeller_inactive`
  notice (fired on every page after ~2s of VM polling). On Impeller the
  detector now correctly produces zero issues.
- **`stateful_density` framework widget noise**: 32-entry
  `_frameworkWidgetNames` set + private-name filter in RebuildDetector.
- **`shallow_rebuild_risk` framework noise**: `ScrollNotificationObserver`
  added to suppressed set.
- **Clock-domain mismatch in TTFF**: monotonic `Timeline.now` delta → wall-
  clock `DateTime.now()` diff, fixes ~5-50ms skew.
- **Deferred VM enrichment buffer**: `_PendingEngineEvents` now stores all 6
  fields (4 VM sub-phases + 2 engine timestamps) — enrichment arriving before
  first-frame callback no longer lost.
- **Network issues persisted across routes**: time-based 30s staleness
  eviction replaced with route-transition clearing. Issues persist on the
  current page and clear on navigation.
- **`clearRecords()` did not clear `_activeRequests`**: in-flight tracking
  leaked across transitions, causing phantom pending-request reports.
- **`_evaluateErrors` severity/detail domain mismatch**: `serverErrors` +
  `transportFailures` were counted across the full buffer but compared
  against the 5-second peak window. All counts now scoped to the peak window.
- **In-flight responses from previous page leaked into new page**: requests
  started on page A completing after navigating to B were added to the
  buffer. `processRecord()` now drops records whose `startedAt` precedes
  the last `clearRecords()` via `_ignoreBeforeTimestamp`.

## 0.12.2

Post-review hardening — three robustness fixes on the v11 branch.

### Fixed

- **Timeline pipeline exception isolation** (`SleuthController._onTimelineData`):
  `try/finally` around `_isIteratingDetectors` flag + per-detector `try/catch`
  around `processTimelineData` and `evaluateNow`. Matches the structural walk's
  isolation. A throwing custom detector in the VM pipeline used to leave
  `_isIteratingDetectors = true` permanently, deadlocking detector mutations.
- **Encyclopedia placeholder leak** (`IssueEncyclopediaPage`): raw
  `{widgetName}` / `{count}` tokens were visible when browsing without a
  context issue. Now applies `IssueExplanationBuilder.substitute()` to all
  entries with a static sentinel triggering built-in fallbacks (`'the widget'`,
  `'several'`).
- **Cookbook `SlowFrameDetector` staleness**: one slow frame could keep the
  detector reporting indefinitely because the rolling window only tracked
  slow frames (fast frames never evicted). Added `_TimestampedFrame` wrapper
  + 10s age eviction in `finalizeScan()`.

## 0.12.1

Pillar 6 Part 2: Overlay UI, Diagnostics Output & Export — upgrades every
consumer-facing surface (trigger button, floating card, issue card,
encyclopedia, export path).

### Added

- **M1 trigger button alignment**: `triggerButtonAlignment` +
  `triggerButtonOffset` on `SleuthConfig`. Four corners + center.
- **M2 minimize/maximize/restore**: 3-state window mode (`normal`/`minimized`/
  `maximized`) on the floating issues card. Minimized collapses to 54px
  header; maximized fills screen minus safe area; pre-transition geometry
  restored exactly.
- **M3 recurrence badge on IssueCard**: trending direction (escalating/stable/
  improving/new) from `RecurrenceTrend`.
- **M4 context-aware encyclopedia**: `IssueExplanationBuilder.substitute()`
  replaces `{widgetName}`, `{count}`, `{routeName}`, `{severity}`, `{title}`,
  `{stableId}` with triggering issue values. 7 templates enriched.
- **M5 inline confidence reasoning** on expanded IssueCard.
- **M6 dismissible debug-mode banner** on `FloatingIssuesCard` when
  `isDebugMode` is true. `showDebugModeBanner` config opt-out.
- **M7 `Sleuth.exportSummary()`** markdown export — frame stats, top issues,
  causal chains. Sized for Slack/PR paste.
- **M8 copy-conversation button** on AiChatPage — full AI thread + issue
  context to markdown on clipboard.

### Fixed

- **Tooltip crash in overlay** (IssueCard): `Tooltip` in `_confidenceBadge`
  → `Semantics`. Flutter 3.41.4's `Tooltip` uses `OverlayPortal` requiring
  `_RenderTheaterMarker` ancestor — absent in Sleuth's bare `Overlay` stack.
  Confidence reason now shown inline when expanded (M5) + as a11y label.
- **M7/M8 GFM escaping**: `_copyConversation` + `SessionMarkdownExporter._escape`
  now cover all 8 GFM-significant chars (`\`, `*`, `` ` ``, `#`, `[`, `]`,
  `<`, `>`, `|`) vs previous 2. Prevents structure corruption in issue titles,
  confidence reasons, message text.
- **M3 recurrence badge overflow**: `maxLines: 1` + `TextOverflow.ellipsis` +
  `Align(centerLeft)` to avoid overflow on narrow cards.
- **Semantic labels** on AI chat back/copy and floating card window controls
  (minimize/maximize/restore/dismiss-banner).
- **Cookbook `TooltipUsageDetector` false positives**: framework tooltip
  message filter (`Back`, `Close`, `Open navigation menu`, etc.) so AppBar
  back button etc. no longer flagged on every screen.

## 0.12.0

Pillar 6 Part 1: Public API & Authoring Surface — presets, threshold
documentation, debug-mode validation, `Duration`-typed intervals,
`SimpleStructuralDetector` base, key-based gating for custom detectors,
three-file custom-detector cookbook.

### Breaking

- **`SleuthConfig.treeScanInterval` now takes `Duration` instead of `int` ms.**
  Old `treeScanIntervalMs` removed. `int ms` was the most frequent foot-gun
  in user reports because nothing about the call site communicated the unit.

  ```dart
  // Before:  SleuthConfig(treeScanIntervalMs: 1000)
  // After:   SleuthConfig(treeScanInterval: Duration(seconds: 1))
  ```

### Added

- **M1 `SleuthConfig.minimal()` / `.performance()` presets**. `.minimal()`
  enables safe structural + runtime detectors and disables opt-ins (network,
  debug callbacks, deep instrumentation, AI chat). `.performance()` is tuned
  for low-overhead profile runs (structural only, 2s scan interval, capture
  buffer off).
- **M2 threshold documentation**: every `SleuthConfig` + `DetectorThresholds`
  threshold has a doc comment (meaning, default, tuning effect). Copy
  verified against each detector's gating code.
- **M3 debug-mode assert validation**: `SleuthConfig` + `DetectorThresholds`
  constructors fail fast in debug for misbehaving values (negative intervals,
  thresholds above detector cut-offs, frequency windows dividing to zero).
- **M5 `SimpleStructuralDetector`** helper base class — override `inspect(Element)`
  + call `report(...)` instead of implementing 4 lifecycle methods. Handles
  issue list, highlight list, enabled flag, per-scan reset. Exported from
  `package:sleuth/sleuth.dart`.
- **M6 custom detector key gating**: `BaseDetector.key` +
  `SleuthConfig.disabledCustomDetectorKeys: Set<String>`. Stable-keyed
  customs can be disabled via config without being removed from the list.
  Built-ins are gated by `DetectorType` via `enabledDetectors`.
- **M7 custom detector cookbook** — `example/lib/custom_detectors/`:
  `TooltipUsageDetector` (`SimpleStructuralDetector`), `SlowFrameDetector`
  (runtime + `SchedulerBinding.addTimingsCallback`), `RasterHotSpotDetector`
  (hybrid: VM raster timings + structural walk). README index, cookbook demo
  screen wired into `Sleuth.track`, `example/test/cookbook_smoke_test.dart`
  validates each against the public `package:sleuth/sleuth.dart` barrel.

### Fixed

- **Real-device first-launch VM connection**: `Service.getInfo()` →
  `Service.controlWebServer(enable: true)` to proactively start the VM web
  server on cold start. USB/WiFi launches from Android Studio used to leave
  Sleuth stuck in BASIC/FRAME mode the entire session because the web server
  hadn't bound its port.
  - 3s owned-timer timeout (no `Future.timeout` leak in tests)
  - `_connectInFlight` concurrency guard
  - IPv4→localhost rewrite for dual-stack Happy Eyeballs
  - Background reconnect ladder (500ms → 30s, 7 attempts) with mid-session
    VM-death recovery
  - Manual `reconnect()` method for "Tap to reconnect" overlay hook
- **`frameStatsNotifier` self-feedback loop**: notifier throttled to ~5 Hz
  (200ms min). 60 Hz emission made Sleuth's own overlay rebuilds dominate
  VM build-event counts and trip false `rebuild_activity` on idle screens.
- **Unified walk exception isolation**: per-detector try/catch in the visitor.
  One throwing custom detector in `checkElement` used to kill the walk for
  all 16 detectors and skip the entire subtree.
- **Post-dispose guards**: `_disposed` checks after every `await` in
  `VmServiceClient._connectImpl` to prevent leaked VmService instances +
  poll timers when dispose races with connect setup.
- README quick-start shows `SleuthConfig.minimal()` alongside the full config.

### Tests

- 1,825 → 1,869 (+44 across M1–M7, VM connection, throttle coverage).
- 5 cookbook smoke tests in `example/` confirm public-API compilation +
  live tree flagging.

## 0.11.1

Pillar 5 Part 2: Demo Quality Enhancements & Combined Demos — Before/After toggle,
live metrics bars, reproduction instructions, and two multi-detector scenarios
(E-Commerce + Chat). Three review rounds, 18 findings resolved (9
P5P2 + 4 polish + 5 demo↔detector alignment) plus a `KeepAliveDetector`
false-positive fix uncovered during chat demo migration.

### Added (M8–M14)

- **M8 Before/After toggle in DemoScaffold**: upgraded to `StatefulWidget`.
  When a demo supplies `fixedBody`, a `SegmentedButton` swaps the anti-pattern
  for its fix in-place. The ternary fully unmounts the hidden side so timers/
  animations/controllers stop automatically. Optional `onToggle` callback.
- **M9 Fixed-pattern implementations for all 23 demos** — real working fix
  bodies, not text: `ValueNotifier` + `ValueListenableBuilder` for setState
  scope, `ListView.builder` + `itemExtent`, `cacheWidth/Height`, `GlobalKey`
  as final fields, extracted `AnimatedBuilder.child`, `Isolate.run()`, etc.
- **M10 Live metrics bar** — `MetricsBar` + `MetricChip`. Wired into
  `high_level_setstate` (Bad/Fixed rebuilds), `non_lazy_list` (built count),
  `heavy_compute` (ms), `fps_stress_test` (FPS via
  `SchedulerBinding.addTimingsCallback`), `repaint_stress` (paints/sec
  sliding window), `network_stress` (request count), `memory_pressure`
  (retained MB). Resets on toggle.
- **M11 `❌ BAD / ✅ FIX / ▶ <action>` format** on every demo description.
- **M12 Combined E-Commerce demo** — 5 anti-patterns: 6-hero carousel
  full-res (ImageMemory), rotating price `AnimatedBuilder` no child, size
  chip row in `IntrinsicHeight` (LayoutBottleneck), 200-review non-lazy
  `ListView`, 4 `GlobalKey()` per build. Fixed body: all fixes + `Visibility`
  swap for previously `Opacity(0.0)` banner.
- **M13 Combined Chat demo** — tabbed 5-conversation UI using
  `AutomaticKeepAliveClientMixin` (KeepAlive), uncached circular avatars
  (ImageMemory), 40ms simulated-channel typing poll (PlatformChannelTraffic
  at 25 calls/sec > 20/sec threshold), top-level `setState` per message
  (SetStateScope + Rebuild). Fixed body debounces the poll, caps keep-alive
  to 2 tabs, isolates message list in `ValueNotifier`, extracts text input
  into own `StatefulWidget`. `debugProfilePlatformChannels` saved/restored
  on dispose.
- **M14 Home screen wiring**: E-Commerce + Chat in "Combined" category. Demo
  count 23 → 25.

### Review Round (P5P2, 9 findings)

Focused on: (a) does each demo's "fix" actually eliminate the detector vs
merely mask it; (b) do new StatefulWidget demos leak timers/controllers/
client handles.

- **CRITICAL FAB double-action neutralized fix** (3 demos:
  `combined_analytics_dashboard`, `combined_social_feed`, `high_level_setstate`):
  FAB called both counter++ AND unconditional `setState(() {})`. Even with
  fixed body switched on, outer State's top-level setState rebuilt the whole
  subtree, burying `ValueListenableBuilder`'s isolated update. Worst in
  `high_level_setstate` because `_FixedBody`/`_FixedGrid` aren't const —
  top-level rebuild hit every tile. Fix: `_isFixed` field synced via
  `onToggle`; FAB only setStates when `!_isFixed`.
- **CRITICAL E-Commerce hero carousel never reached ImageMemoryDetector
  threshold**: detector fires at `count > 5`, but horizontal `ListView.builder`
  only realized 2–4 hero items due to 250px default `cacheExtent`. Fix:
  `SingleChildScrollView` + `Row` forces all 6 heroes into the tree; fixed
  version keeps `cacheWidth: 520`.
- **HIGH "fixed" reviews ListView wasn't paginated**:
  `ListView.builder(shrinkWrap: true, physics: NeverScrollable)` inside
  `SingleChildScrollView` under infinite main-axis constraints realizes every
  one of 200 items. Fix: `SizedBox(height: 480)` bounds the inner viewport;
  ~8 items realized.
- **HIGH HttpClient leak on mid-request dispose** (`network_stress_demo`):
  `_triggerFrequencySpike` awaited `Future.wait([40 gets])` then early-
  returned on `!mounted` before `client.close`. Fix: moved close into
  `finally`.
- **MEDIUM unbounded log growth** (`network_stress_demo`): `_maxLogLines = 200`
  with trim-on-append.
- **MEDIUM unbounded message list growth** (`combined_chat_demo`): 40ms timer
  did `[...notifier.value, msg]` per tick. `_maxMessagesPerTab = 100` via
  `_appendCapped` helper dropping oldest when full.
- **LOW narrow exception handling in typing poll**
  (`combined_chat_demo._startBadTypingPoll`): only caught
  `MissingPluginException` + `PlatformException`. Added `catch (_)` fallback
  + `mounted` guard.

Second-order checks: `_isFixed` gate is synchronous from `onToggle` (setState
in `_handleToggle` runs before `widget.onToggle?.call`); `try/finally` in
`_triggerFrequencySpike` runs on throw-during-await; 480px review viewport
shows a page but only realizes ~8 items.

### KeepAliveDetector False-Positive Fix

Symptom: chat fixed mode (2 of 6 tabs opting in) reported the same "excessive
keep-alive" as bad mode. Two layered bugs:

1. Detector matched `KeepAlive` widgets by type name, but Flutter's
   `AutomaticKeepAlive.build()` ALWAYS wraps its child in
   `KeepAlive(keepAlive: ...)` — string match counts every page regardless.
2. Fallback to `element.widget.keepAlive` is also wrong: `AutomaticKeepAlive`
   updates the child render object's parent data via
   `ParentDataElement.applyWidgetOutOfTurn()` — it mutates the render object
   but does NOT replace `element.widget`, so `widget.keepAlive` stays stale
   at the initial `false`.

Fix: read `element.renderObject.parentData` and cast to
`KeepAliveParentDataMixin` — the authoritative framework signal. New
`_isActiveKeepAlive()` helper in `keep_alive_detector.dart`. 2 regression
tests (`_OptOutKeepAlivePage`, `_ConfigurableKeepAlivePage`). Test count:
1,823 → 1,825.

### Review Round 5 — Migrated Demo Polish (4 findings)

1. **CRITICAL `non_lazy_list_demo`**: `builtCount.value = 0` at build start.
   On rebuild, `notifyListeners` marked ancestor `ValueListenableBuilder` in
   MetricsBar dirty during build phase, risking "setState during build"
   assert. Fix: reset moved to `_handleToggle`.
2. **TEXT `combined_chat_demo`**: description said "cacheWidth: 48" vs code's
   `64`; comment said "48px for 24×24" vs 32×32 display. Aligned to 64 and
   32×32.
3. **TEXT `combined_ecommerce_demo`**: description "cacheWidth: 400" vs code
   `520`. Aligned.
4. **CONVENTION `fps_stress_test_demo`**: missing `▶ action` marker.

### Review Round 6 — Demo ↔ Detector Alignment (5 findings)

Tightened detectors (Pillars 2a/2b/3a/3b + v11 audit) had silently drifted
demos below trigger threshold.

| # | Demo | Cause | Fix |
|---|------|-------|-----|
| 1 | `global_key_demo` | 15 keys but `threshold = 20`; description mis-stated as 10 | `_itemCount` → 25; corrected description |
| 2 | `non_lazy_list_demo` | 40 children but `childThreshold = 50` (fires on `> 50`) | `_itemCount` → 60 |
| 3 | `animated_builder_demo` | 6 bars built ~14-widget subtree, below `minSubtreeSize = 50` | `_barCount = 12`; richer `Row(SizedBox(label) + Expanded(LinearProgressIndicator) + SizedBox(%))` → ~135 widgets. `_StaticBarColumn` mirrors |
| 4 | `combined_analytics_dashboard_demo` | 25 tiles below ListView threshold; 25 GlobalKeys in `SingleChildScrollView+Column` (wrong scope — excessive branch gated by `_isInListLikeScrollable`); recreation never fired because keys were stable final `_tileKeys` | `_tileCount` → 60; removed `_tileKeys`; in-build `final tileKeys = List.generate(...)`; wrapped `_BadDashboard` in outer `AnimatedBuilder(animation: _controller)` for per-tick rebuilds. Nets: ListviewDetector (60>50) AND GlobalKey **recreation** (`churnCount = 60 ≥ 5`). Mirrors `combined_ecommerce_demo`'s pattern |
| 5 | `nested_scroll_demo` | ONE `SingleChildScrollView` with 30 children — no nesting AND below threshold. `NestedScrollDetector` needs `parentAxis != null && scrollAxis == parentAxis` + `childCount > 50` | `_itemCount` → 60; wrapped in outer `SingleChildScrollView > Column > SizedBox(height: 480) > SingleChildScrollView`. Bounded 480px viewport keeps inner scrollable from crashing on unbounded height |

**Key insight:** `GlobalKeyDetector` has **two modes with different scoping**.
Excessive branch (`global_key_detector.dart:131`) is gated by
`_isInListLikeScrollable` (only counts inside LV/GV/PV). Recreation branch
(`global_key_detector.dart:113-116`) collects `identityHashCode(key)`
**globally** in `checkElement`, NOT gated by scrollable scope. Trigger
recreation by allocating new keys inside any repeatedly-built widget.

**Demos dismissed (already fire):** `custom_painter`, `font_loading`,
`gpu_pressure`, `heavy_compute`, `high_level_setstate`, `intrinsic_height`,
`network_stress`, `opacity_zero`, `platform_channel`, `repaint_boundary`,
`repaint_stress`, `shader_jank`, `shallow_rebuild_risk`, `uncached_image`,
`combined_chat`, `combined_ecommerce`, `combined_social_feed`. Each traced
through `checkElement` against current thresholds.

## 0.11.0

Pillar 5 Part 1: Demo Infrastructure & Missing Detector Demos — DemoScaffold +
5 new demos + categorized home screen. Two review rounds.

### Added (M1–M7)

- **M1 DemoScaffold**: shared layout with collapsible description banner,
  AppBar, Expanded body slot. `BAD:`/`FIX:` annotations.
- **M2 Shader Jank demo**: `BackdropFilter(σ=20)` + `ShaderMask` +
  `ColorFiltered` + combined effects. Impeller caveat (pre-compiled shaders).
- **M3 Platform Channel Traffic demo**: rapid fire (50 concurrent), sustained
  (50/sec via `Timer.periodic`), single-call modes + scrollable log. Timer
  cancelled in `dispose`.
- **M4 Memory Pressure demo**: Dart-heap (+10MB Maps) vs native (+10MB
  `Uint8List`) buttons, GC churn mode (100 batches retain first only), bar
  chart. Per-batch KB tracking.
- **M5 GPU Pressure demo**: 10 cards each stacking
  `ClipPath(antiAliasWithSaveLayer)` → `Opacity(0.85)` →
  `BackdropFilter(σ=15)` → `ColorFiltered`, >5 descendants per node.
- **M6 RepaintBoundary demo**: uses `SingleChildScrollView+Column` (not
  `ListView.builder` which auto-wraps in RepaintBoundary). 14
  `Opacity(0.7)` cards + 1 animated `CustomPaint`. Controller disposed.
- **M7 Home screen categorization**: 8 categories (Build, Paint, GPU &
  Rendering, Layout, Memory, Network & I/O, Keys & Identity, Combined).

### Review Round 1

- **Memory MB overcount**: `_dartMB` multiplied `_dartObjects.length * 10`,
  but GC Churn retained a sentinel batch counted as full 10MB. Fixed with
  per-batch KB tracking (`_dartBatchKB` list).
- **Hardcoded light-theme color**: `Colors.grey.shade100` unreadable in dark
  mode. → `Theme.of(context).colorScheme.surfaceContainerLow`.

### Review Round 2

- **CRITICAL GC rate dilution**: `MemoryPressureDetector._evaluateGcPressure`
  used `gcPerMinute = _gcEventCount / elapsedSec * 60` — denominator grew
  unbounded across a session, so 60s of unrelated demos diluted the count
  below the 30/min threshold even when the last 5s clearly showed pressure.
  Fix: 10s sliding window (`Queue<({DateTime ts, int count})> _gcWindow`)
  with timestamp-based eviction — stable "events per 10s × 6" rate
  responsive to real bursts. 55 tests still pass.
- **HIGH setState-after-dispose in platform channel demo**:
  `_triggerRapidFire` / `_triggerSingle` awaited without `mounted` guard
  before setState. Added `if (!mounted) return;` after each await +
  internal `_addLog` guard.
- **HIGH global `debugProfilePlatformChannels` clobber**: demo hardcoded
  `= false` on dispose, stomping developer's global setting. Now captures
  prior value in `initState`, restores in `dispose`.
- **MEDIUM "Dart Heap" label misleading**: counter tracked only *retained*
  allocations, stayed at 0 during GC Churn. Renamed "Retained (Dart)";
  description explains transient churn.
- **MEDIUM RepaintBoundary demo description inaccurate**: detector checks
  non-trivial opacity values (0.0 < x < 1.0) without RepaintBoundary
  ancestor within 5 levels, not "Opacity(0.7) with 6+ descendants". Rewrote
  to enumerate the 6 flagged classes (Opacity, ClipPath, BackdropFilter,
  ShaderMask, CustomPaint, ColorFiltered).
- **MEDIUM Impeller silent failure in shader jank demo**:
  `ShaderCompilation` timeline events only fire on Skia; Impeller (iOS
  3.16+, Android 3.22+) pre-compiles offline. No public Dart API for
  backend detection — added `_ImpellerWarningBanner` instructing
  `--no-enable-impeller` relaunch.

## 0.10.9

Pillar 4: Issue Documentation Quality — encyclopedia content for all 46 issue
types, cross-references, enriched explanations, and quality guardrail tests.

### Added

- **v11.20 8 missing encyclopedia entries**: `duplicate_request`,
  `wrap_layout_bottleneck`, `sliver_to_box_adapter_large`,
  `sliver_fill_remaining_scrollable`, `sliver_to_box_adapter_shrinkwrap`,
  `global_key_recreation`, `excessive_repaint_boundary`, `runtime_font_loading`.
  Total 38 → 46. Every detector stableId now resolves.
- **v11.21 stale count fix**: removed hard-coded "37 issue types" doc comment;
  added missing `http_error_spike` to test coverage.
- **v11.22 readingTheData on all 46 entries** with real-world analogies,
  threshold interpretation, normal-vs-abnormal guidance.
- **v11.23 Build-phase enrichment**: `heavy_compute` howToFix adds
  `Isolate.run()` vs `compute()`; `setstate_scope` adds
  `ValueListenableBuilder` extraction; `animated_builder_no_child` explains
  `child` reuse.
- **v11.24 Memory/image**: `gc_pressure` adds micro-stutter + const ctor;
  `heap_growing` adds DevTools Memory walkthrough (retained vs shallow);
  `uncached_images` adds `ResizeImage`.
- **v11.25 Paint/layout**: `excessive_repaint` adds RepaintBoundary "island"
  concept; `missing_repaint_boundary` adds when-NOT-to-add; `layout_bottleneck`
  adds `CrossAxisAlignment.stretch`; `opacity_zero` adds `Visibility` flags
  (`maintainSize`/`State`/`Animation`).
- **v11.26 Raster/network/scroll**: `shader_compilation` adds Impeller context;
  `platform_channel_traffic` adds Pigeon + EventChannel patterns;
  `non_lazy_list` adds `ListView.builder` + `itemExtent`; `nested_scroll_same_axis`
  adds `CustomScrollView` migration.
- **v11.27 `relatedIssues`** field on `IssueExplanation`: all 46 entries
  populated with bidirectional cross-references from the causal graph (52
  rules). If A lists B, B lists A.
- **v11.28 Related issues UI**: "Related issues" section with tappable chips
  that expand and scroll to the target entry. AI context includes related
  issues in system prompts. Search matches related-issue display names.
- **v11.29 Guardrail tests**: word counts (whatItIs ≥ 20, whyItMatters ≥ 20,
  howToFix ≥ 30), metric thresholds in readingTheData (≥ 25/46), analogy
  patterns, code examples (≥ 10), DevTools refs (≥ 5), stableId completeness.

### Review Round

- **CRITICAL chip scroll-to bug**: related-chip tap used a single
  `_scrollTargetKey` pointing to the initial `scrollToStableId` only, not the
  tapped chip's entry. Fix: per-entry `Map<String, GlobalKey> _entryKeys`.
- **LOW missing bidirectional relatedIssues**: `repaint_debug` was the only
  runtime entry without cross-refs. Added links to `excessive_repaint`,
  `excessive_repaint_debug`, `missing_repaint_boundary` (+ reverse).
- **LOW content below quality thresholds**: enriched `raster_cache_growing`,
  `gc_pressure`, `heavy_compute`, `expensive_gpu_nodes`, `excessive_repaint_debug`
  with specific numeric thresholds.

## 0.10.8

Pillar 3b: Enrichment — output & presentation.

### Added

- **`confidenceReason` on every issue**: explains *why* confidence is
  confirmed/likely/possible and what would upgrade it. Confirmed: "Measured
  directly from {source}". Likely: "{evidence1} + {evidence2}". Possible:
  "Structural scan only — {upgrade hint}". Correlator appends escalation
  context. Shown as tooltip on the IssueCard confidence badge.
- **Severity auto-escalation**: warning issues persisting 30+ cumulative scan
  cycles auto-escalate to critical. Uses existing `RecurrenceTrend.presentCount`
  — no separate state map.
- **Two new correlator rules**:
  - `EscalateStructuralWithJankRule`: `non_lazy_list`, `layout_bottleneck`,
    `nested_scroll`, etc. possible → likely when `sustained_jank`/
    `jank_detected` co-occurs.
  - `EscalateStructuralWithRebuildRule`: `animated_builder_no_child`,
    `setstate_scope` possible → likely when `rebuild_activity` co-occurs.
- **Code location precision**: `buildAncestorChain()` appends `file:line` for
  every non-framework ancestor (not just leaf). New `lookupStructured()` with
  package-name extraction; new `packageName` field on `PerformanceIssue`.
- **`sessionSummary` export**: pre-computed 5 fields in `SessionSnapshot` —
  `topIssues` (top 5 by rank), `causalEdges`, `frameHistogram` (<16/16–33/
  33–50/50–100/>100ms), `detectorHitRates`, `memoryTrendSummary`. Schema v3,
  backward compatible with v2.

### Review (Pillar 3b)

- **Missing stableId prefix mappings**: `_detectorNameFromStableId()` missed
  `shader_compilation` (shaderJank), `repaint_debug_` (repaint),
  `stateful_density` (rebuild) — fell through to 'custom' in hit rates. Added.

### Full Branch Review (Pillars 1–3)

- **HIGH scan chain exception safety**: adaptive self-rescheduling scan loop
  could die permanently if a detector threw during `_runStructuralScans()` /
  `_aggregateIssues()`, leaving `_isIteratingDetectors` stuck true. Fix:
  `try/finally` in `_scanTree` + `try/catch` in `_scheduleNextScan` callback
  (always reschedules).
- **HIGH unstable duplicate-request stableIds**: `duplicate_request:$dupIndex`
  used a per-scan loop index that jittered as records aged in/out, breaking
  recurrence + duration escalation. Fix: derive stableId from stable
  method+URL hash fingerprint.
- **MEDIUM POST false duplicates**: grouped by method+URL ignoring body. Fix:
  limit duplicate detection to idempotent methods (GET/HEAD/OPTIONS).
- **MEDIUM GlobalKey recreation false positive on route change**: cross-scan
  key identity not scoped to stable route. Fix: track scan root identity and
  reset previous key set on route change.
- **MEDIUM missing sliver stableIds in correlator**:
  `EscalateStructuralWithJankRule` covered only legacy list IDs, missing 5
  Pillar 1 sliver IDs. Added to `_structuralIds`.

## 0.10.7

Pillar 3a: Enrichment — analysis & tracking.

### Added

- **Causal rules expanded 37 → 52**: 15 new entries (8 patterns) — setState →
  rebuild, uncached images → GC pressure, animated builder → repaint, layout
  bottleneck → jank, font loading → jank, platform channel → heavy compute,
  duplicate requests → rebuilds.
- **`RecurrenceTrend`**: ring-buffered (cap 60) per-issue presence tracker
  with `TrendDirection` (worsening/improving/stable/intermittent). Replaces
  flat `_recurrenceCounts`. Stale eviction after 120 absent cycles. Exported
  as summary (trend + counts, not raw ring buffer).
- **Interaction context** gains `typing` and `appLifecycle`. Keyboard via
  `WidgetsBindingObserver.didChangeMetrics()` (debounced); lifecycle via
  `didChangeAppLifecycleState()`. Priority: navigating > typing > scrolling
  > idle > appLifecycle (deprioritized alongside scrolling in ranking).
- **`WidgetHeatMapEntry`**: per-widget issue aggregation for "top offenders",
  filters ~50 framework widget names (layout primitives, scrollables,
  scaffold/chrome, builders, buttons). Sorted by cumulative ranking score.
  Exported.
- **Fix verification**: `FixBaseline` + `FixVerificationResult`, 5-cycle
  cooldown before declaring resolved, 3-cycle hot-reload grace period (resets
  absence counters on reassemble). Status:
  resolved/improved/unchanged/worsened/newIssue. API: `Sleuth.captureBaseline()`,
  `compareToBaseline()`, `hasBaseline`, `clearBaseline()`.

### Review

- **Incomplete framework-widget filter**: `_frameworkPrefixes` missed ListView,
  GridView, Scaffold, AppBar, buttons etc. Heat map surfaced framework widgets
  as top offenders. Added 18 names across scrollables, scaffold/chrome, buttons.
- **Grace period did not reset baseline counters**: `notifyReassemble()` set
  the grace period but not `consecutiveAbsentCycles` — hot reload after 4
  absent + 1 more falsely reported resolved. Now clears on reassemble.

## 0.10.6

Pillar 2b: Resource management — reduce Sleuth's own CPU/memory/GC overhead
when the app is healthy.

### Added

- **M4 adaptive scan frequency**: `Timer.periodic(1s)` → self-rescheduling
  `Timer`. After 3 clean cycles interval doubles (capped 2s); returns to
  normal on next issue. FrameTiming + VM timeline paths remain event-driven.
  Opt out via `SleuthConfig(adaptiveScanEnabled: false)`.
- **M5 `_getAllIssues()` generation-counter cache**: method is called 4+
  times per timeline event — cached list returned when no detector produced
  fresh issues. Generation increments on structural scan, timeline evaluateNow,
  frame stats update.
- **M6 Detector lazy initialization**: factory-map pattern; only detectors
  in `enabledDetectors` constructed. `enableDetector()`/`disableDetector()`
  for runtime toggling. 3 typed (frameTiming/memoryPressure/networkMonitor)
  always constructed (special access patterns). Custom always present.
- **M7 Debug callback `TypeNameCache`** (private Map<Type, String> in
  `DebugInstrumentationCoordinator`): replaces per-callback
  `runtimeType.toString()` (~1,000 string allocs/sec). Separate from the
  global cache (not cleared per scan). Bounded naturally (~50–200).

### Review

- **M4 timer leak after dispose**: `_scheduleNextScan()` could create an
  orphan timer chain if `dispose()` ran mid-callback. Fix: `_disposed` guards
  at method entry, timer callback entry, post-frame callback entry.
- **M4 parallel timer chains**: rapid `startTreeScanning()` (e.g. hot reload
  remount) could create duplicate chains. Fix: `_scanTimerGeneration` counter
  — stale callbacks bail out.
- **M6 concurrent detector modification**: enable/disable could mutate
  `_detectors` during iteration. Fix: `_isIteratingDetectors` guard; mutations
  deferred to `_pendingDetectorMutations`, drained after iteration. Typed
  flag-flips remain immediate.

## 0.10.5

Pillar 2a: Hot-path optimizations.

### Added

- **M1 `TypeNameCache`**: shared `Map<Type, String>` eliminates redundant
  `runtimeType.toString()` during the unified walk. On a 5K-element tree with
  ~50 unique types: ~15,000 → ~50 allocations per scan. Applied across 11
  detectors + `buildAncestorChain`.
- **M2 Highlight dirty-check**: `_collectHighlights()` skips list spread +
  generation increment + notifier update when no highlights exist before or
  after the scan. Eliminates CustomPainter repaint every scan cycle during
  normal operation. Defensive selected-highlight clearing.
- **M3 Timeline parser case-matching**: `toLowerCase()` per-event → direct
  multi-case matching for all known Flutter variants (BUILD/build/Build,
  LAYOUT/layout/Layout, etc.). Eliminates 2 string allocs/event.

### Review

- **M2 stale selected highlight**: traced all paths; zero→zero cannot leave
  `selectedHighlightNotifier` stale (non-empty→empty always triggers full
  collection). Added defensive null-clear.
- **M1 custom detector cache reuse**: verified customs calling `scanTree()`
  after the walk reuse cache entries from the same cycle.
- **M3 timeline case coverage**: verified all v2.x + v3+ variants covered;
  `_isChannelEvent` handles `'Platform Channel send ...'`.

## 0.10.4

v11.19 — Sliver anti-patterns in `ListviewDetector`.

### Added

- **3 new `ListviewDetector` checks** for CustomScrollView misuse:
  - **A** `SliverToBoxAdapter` wrapping `Column`/`Row` with > 50 children
    (warning > 50, critical > 150) — defeats lazy loading.
  - **B** `SliverFillRemaining(hasScrollBody: false)` containing a scrollable
    child (ListView/GridView/CustomScrollView/SingleChildScrollView) — forces
    shrinkWrap + eager building.
  - **C** `SliverToBoxAdapter` wrapping shrinkWrap `ListView`/`GridView` —
    forces eager measurement.
- Dedup prevents double-reporting when non-lazy + shrinkWrap checks overlap.
- 3 new `FixHintBuilder` methods with replacement patterns.

### Review

- **Check B false negative**: SingleChildScrollView inside
  `SliverFillRemaining(hasScrollBody: false)` was caught by the SCSV branch
  first. Fix: record finding before running non-lazy list check; removed dead
  code from later branch.
- **Missing test coverage**: added 2 tests for Check B with SCSV and
  CustomScrollView descendants.

## 0.10.3

v11 detector audit Part 3 (v11.13–v11.18).

### Added

- **v11.13 builder-widget suppression**: `FrameTimingDetector` 3× threshold
  multiplier for `StreamBuilder`/`FutureBuilder`/`ValueListenableBuilder`
  (designed to rebuild often).
- **v11.14 warmup frame suppression**: `FrameTimingDetector` suppresses jank
  during the first 180 frames (~3s @ 60fps). Configurable via
  `SleuthConfig.frameTimingWarmupFrameCount`.
- **v11.15 duplicate request detection**: `NetworkMonitorDetector` flags ≥ 3
  identical requests (method + normalized URL) clustered within 500ms.
  Indexed stableIds (`duplicate_request:0`, `:1`). Critical at ≥ 10.
- **v11.16 GlobalKey recreation**: `GlobalKeyDetector` tracks
  `identityHashCode` across scans; symmetric churn (new ≈ gone) indicates
  keys recreated in `build()` vs stored in `State`. Asymmetric (navigation)
  filtered. Threshold default 5.
- **v11.17 KeepAlive subtree cost**: `KeepAliveDetector` reports avg subtree
  size per scrollable in issue detail (concrete cost beyond page counts).
- **v11.18 thread-attributed jank**: `FrameTimingDetector` classifies jank as
  UI-bound/raster-bound/pipeline stall/mixed from phase timestamps. Title
  includes bottleneck label; detail includes thread timing.

### Review

- **NetworkMonitor maxCluster overwrite**: sliding window count overwrote
  previous larger values. Fix: `if (clusterSize > maxCluster)`.
- **NetworkMonitor non-indexed stableId**: `duplicate_request` shared across
  endpoints → `duplicate_request:$dupIndex`.
- **3 boundary tests**: duplicate cluster at exactly 500ms window, cluster at
  501ms (split), maxCluster regression.

## 0.10.2

v10 roadmap (12 milestones) + v11 detector audit (12 milestones).

### v11 Audit Part 1 — Accuracy & Detection (v11.1–v11.6)

- **v11.1 `SliverChildListDelegate` detection**: `ListviewDetector` catches
  `ListView(children: [...])`, `GridView(children: [...])`, and
  `CustomScrollView > SliverList(delegate: SliverChildListDelegate([...]))`
  — non-builder constructors that build eagerly.
- **v11.2 `NeverScrollableScrollPhysics` suppression** in `NestedScrollDetector`
  when inner uses `NeverScrollableScrollPhysics` or is in `NestedScrollView`.
- **v11.3 Framework `IntrinsicWidth` suppression**: no flag inside
  `DropdownButton`/`AlertDialog`/`ExpansionTile`.
- **v11.4 `Wrap` excessive children**: `LayoutBottleneckDetector` flags
  `Wrap` with > 30 children.
- **v11.5 Const subtree discounting**: `SetStateScopeDetector` tracks
  element identity across scans; discounts const subtrees from rebuild scope
  count when rebuild evidence exists.
- **v11.6 Excessive `RepaintBoundary`**: `RepaintBoundaryDetector` flags > 20
  user-added boundaries in a scrollable (wasted compositing layers).

### v11 Audit Part 2 — Accuracy & Enrichment (v11.7–v11.12)

- **v11.7 `FadeTransition` at opacity 0.0**: `OpacityDetector` catches it
  with dedup vs `AnimatedOpacity`'s internal `FadeTransition`.
- **v11.8 `ColorFiltered` GPU detection** in `GpuPressureDetector` +
  `RepaintBoundaryDetector` with deep subtrees. Widget-level check (private
  `_ColorFilterRenderObject` not `is`-accessible).
- **v11.9 Small image suppression**: `ImageMemoryDetector` skips ≤ 50×50
  logical (cacheWidth/Height savings negligible).
- **v11.10 `TweenAnimationBuilder` child**: `AnimatedBuilderDetector` catches
  it without `child`; skips `isFrameworkOwned` check (always user-placed).
- **v11.11 Runtime font loading**: `FontLoadingDetector` uses
  `fontFamilyFallback` heuristic for google_fonts etc.; new
  `runtime_font_loading` stableId, escalates at ≥ 3 families.
- **v11.12 `BackdropFilter` sigma severity**: `GpuPressureDetector` extracts
  blur sigma. σ ≤ 2.0 suppressed; σ > 10.0 critical. Detail shows `σ=X.X`.

### v10 Accuracy

- **v10.1 ListView/GridView `SliverChildListDelegate`**: new stableIds
  `non_lazy_listview` / `non_lazy_gridview` + causal rules.
- **v10.2 `NeverScrollableScrollPhysics`** suppression in `NestedScrollDetector`.
- **v10.3 `DecorationImage`**: `ImageMemoryDetector` now catches images in
  `BoxDecoration` via `DecoratedBox`.
- **v10.4 `GpuPressureDetector` is-checks**: `runtimeType.toString()` +
  `contains()` → `is` for `RenderOpacity`, `RenderClipPath`,
  `RenderBackdropFilter`, `RenderShaderMask`. Eliminates allocations AND
  fixes false positive on `RenderAnimatedOpacity` (extends `RenderProxyBox`,
  not `RenderOpacity`).
- **v10.5 `LayoutBottleneckDetector` widget-level checks**: render-object
  toString → `is IntrinsicHeight`/`IntrinsicWidth`. 2 toString allocs/element
  eliminated (`checkElement` + `afterElement`).

### v10 Enrichment

- **v10.6 KeepAlive + MemoryPressure**: `EscalateKeepAliveMemoryRule`
  upgrades `excessive_keep_alive:*` possible → likely when
  `heap_growing`/`heap_near_capacity` co-occurs. New causal rules.
- **v10.7 NestedScroll + LayoutBottleneck** causal rules connecting
  `nested_scroll[_same_axis]` to `layout_bottleneck`, `rebuild_activity`.
- **v10.8 HTTP error spike**: `NetworkMonitorDetector` flags ≥ 3 failures
  (status ≥ 400 or transport failure) in 5s. New `http_error_spike`,
  `FixHintBuilder.httpErrorSpike()`, encyclopedia entry, causal rule to
  `request_frequency`.
- **v10.9 Rebuild + RepaintBoundary enrichment**:
  `EnrichRebuildRepaintBoundaryRule` annotates `rebuild_activity`/
  `rebuild_debug_*` when `missing_repaint_boundary` co-occurs
  (informational, no confidence change).

### v10 Performance

- **v10.10 `CustomPainterDetector`**: `runtimeType.toString()` →
  `'CustomPaint'` literal in highlight creation.
- **v10.11 `RepaintDetector` map**: `_hotCounts.clear()` vs `= {}` — reuses
  backing store.
- **v10.12 `NestedScrollDetector` stack**: `_scrollAxisStack.clear()` +
  `.add(null)` vs list re-creation.

## 0.10.1

Rebrand: `widget_watchdog` → `sleuth`. All classes, imports, docs, and tests updated.

## 0.10.0

v9 roadmap complete (v9.1–v9.17): Issue Encyclopedia, contextual AI Chat, and performance/correctness hardening across detectors and overlay.

### Performance

- **v9.9 — `runtimeType.toString()` elimination**: 3 of 7 call sites in scan-root resolution switched to `is` type checks (`_findVisiblePageContext`, `_findActiveRouteScanRoot`, `_containsNestedNavigator`). 4 remain on private framework types (`_OverlayEntryWidget`, `_ModalScope`, `_ModalScopeStatus`).
- **v9.10 — FrameStatsBuffer hot-path**: cached `frames` getter (no per-call `Queue.toList()`), single-pass jank counting, listener-gated `FrameStatsBuffer.from()` copy, lazy dirty-flag `fpsPercentiles()` cache.
- **v9.11 — Inner subtree walk elimination**: AnimatedBuilderDetector, GpuPressureDetector, GlobalKeyDetector, KeepAliveDetector converted from inner recursion to `afterElement` stack accumulation. Restores O(N) for all 16 tree-scanning detectors; GpuPressureDetector now reports accurate descendant counts (was capped at 20).
- **v9.12 — Single-loop `_aggregateIssues()`**: replaces `.map().toList()` + `.where().toList()` chain with one for-loop; eliminates 2 intermediate list allocations per call (7 callers).
- **v9.13 — FIFO eviction O(N) → O(1)**: `NetworkMonitorDetector._records` and `MemoryPressureDetector._heapSamples` switched `List` → `Queue` (`removeAt(0)` → `removeFirst()`). Capacities: 200 records, 60 heap samples.
- **v9.14 — Highlight overlay self-overhead**: `saveLayer` + `BlendMode.clear` dim replaced with `Path.combine(PathOperation.difference)` (no offscreen GPU buffer per frame). Generation-counter `shouldRepaint` via record-typed `highlightsNotifier`. Selected highlight rebinds to fresh rect after scroll/rescan.

### Fixed

- **v9.1 — Opacity value semantics**: `GpuPressureDetector` and `RepaintBoundaryDetector` skip `Opacity` at 1.0 (passthrough) and 0.0 (short-circuit); these don't trigger `saveLayer`. `OpacityDetector` was already correct.
- **v9.4 — Layout bottleneck overclaim**: `LayoutBottleneckDetector` distinguishes nested intrinsics (critical — exponential) vs non-nested (warning — O(N²)). Tracks nesting depth via `afterElement` with abort-safe `prepareScan` reset.
- **v9.6 — Per-scrollable accumulation**: `GlobalKeyDetector` and `KeepAliveDetector` count per-scrollable, not globally. Each emits its own issue with indexed stableIds (`excessive_global_keys:0`, `excessive_keep_alive:0`). Suppression should switch to prefix match for the old unindexed IDs.
- **v9.8 — Timeline parser event name validation**: silent data loss fix — `LAYOUT (root)` / `PAINT (root)` (Flutter 3.13+) were dropped because `.contains()` required exact match (`'layout (root)'` vs set entry `'layout'`). Root PipelineOwner events carry the primary pipeline's durations, so `flushLayoutDurations`/`flushPaintDurations` were missing their most important entries. Also removed 6 phantom entries (`buildscope`, `build_scope`, `flushlayout`/`flush_layout`, `flushpaint`/`flush_paint`) verified absent in Flutter source back to v2.x.
- **v9.15 — Silent exception swallowing**: all 8 `catch (_) {}` blocks now log via `debugPrint` inside `assert(() {}())` (zero profile/release overhead). Files: `sleuth_controller.dart` (2), `base_detector.dart`, `custom_painter_detector.dart`, `debug_instrumentation_coordinator.dart` (2), `widget_location.dart`, `source_location_cache.dart`.
- **v9.16 — Mounted check for ModalRoute.of**: `_currentRouteName()` guards `ModalRoute.of(_lastScanContext)` with a mounted check. The retained context can detach between scans and async callbacks (VM timeline, heap, scroll idle).
- **v9.17 — Source location cache docstring**: no code change — git history confirmed the docstring has always correctly described first-N bounded behavior.

### Added

- **Issue Encyclopedia**: educational "Learn more" deep-dive for every detector type, searchable, reachable from IssueCard.
- **Contextual AI Chat** (`AiChatPage`): per-issue streaming chat with starter questions, thinking indicator, expandable issue context card. Adapter-based backend.
- **Actionable fix hints** (`FixHintBuilder`): code snippets and debugging commands for every detector.

### Changed

- **UI**: shimmer "Ask AI" link in IssueCard (animated purple-blue-pink `ShaderMask`, isolated via `RepaintBoundary` + `AnimatedBuilder` static-child pattern); responsive action links (side-by-side when wide, stacked <240px via `LayoutBuilder`); MediaQuery granular accessors (`sizeOf`/`paddingOf`/`viewInsetsOf`) across `AiChatPage`/`FloatingIssuesCard`/`IssueEncyclopediaPage`; AI chat header respects `MediaQuery.paddingOf(context).top`; expandable real `IssueCard` in AI chat (capped 40% screen height).
- `SleuthThemeData`: added `aiShimmerStart`/`aiShimmerMid`/`aiShimmerEnd` tokens.
- 1,490 tests (up from 1,343), 0 analysis issues.

## 0.9.1

v8 roadmap complete (v8.1–v8.5).

### Fixed

- **v8.1 — SetState subtree counting O(N²) → O(N)**: `SetStateScopeDetector` replaced recursive `_computeSubtreeSize` with stack-based post-order accumulation in `afterElement`. Abort-safety via `notifyWalkCompleted` gate — evidence and child snapshots commit only on success. Transactional `_pendingEvidence` staging prevents partial data from aborted scans.
- **v8.2 — Scaffold scan-root fallback**: `_findVisiblePageContext` three-tier resolution — (1) Material `Scaffold` / `CupertinoPageScaffold`, (2) scaffold-free Navigator path (walks overlay for topmost route-owned onstage entry via `_ModalScope`, identity-hash route-stability gate, TickerMode onstage filter), (3) static app fallback (`NotificationListener`). `ShallowRebuildRiskDetector` + `SetStateScopeDetector` exempted from scaffold-free walk (depth/ratio semantics break). Nested-Navigator guard prevents cross-tab false positives. `refreshHighlights()` uses `_lastScanContext` to avoid route-stability side effects. Previously Cupertino and scaffold-free apps got zero structural detection.
- **v8.3 — HTTP monitor openUrl leak**: `_MonitoringHttpClient.openUrl()` wraps `_inner.openUrl()` in try/catch. On transport failure (DNS/TLS/connection-refused), emits `RequestRecord(statusCode: -1)`, calls `onRequestEnded`, rethrows. Callback isolation — `onRequestEnded` and `onRecord` run in separate try/catches so a throwing callback can't suppress the other or mask the transport exception. Same isolation on `_MonitoringRequest.close()` and `_MonitoringResponse._emitRecord()`. Hardened across multiple review passes.
- **v8.4 — Platform channel false positives**: `TimelineParser` classifier replaced `cat.contains('embedder')` fallback with prefix match for real `debugProfilePlatformChannels` events (`Platform Channel send [channel]#[method]`). The embedder fallback incorrectly captured vsync/compositor/input events. Legacy exact names (`platformchannel`, `methodchannel`) preserved as defensive fallback.

### Changed

- **v8.5 — SetState detector wording accuracy**: user detail no longer claims `setState() was detected` (the evidence — child-identity churn — proves rebuild, not the trigger). Now says "Rebuild activity was detected"; fix hints generalized from "Move setState() calls" to "Scope rebuild triggers". Internal `hasEvidence` → `hasRebuildEvidence`. Docstring describes two-tier confidence.

### Added

- 1,343 tests (up from 1,313), 0 analysis issues.

## 0.9.0

### Changed

- **v7.9 — Unified structural tree walk**: all 16 tree-scanning detectors run in a single `O(N)` pass (was 16 separate walks). Four new `BaseDetector` lifecycle methods (`prepareScan`, `checkElement`, `afterElement`, `finalizeScan`) replace per-detector `scanTree` for built-ins. Custom detectors keep `scanTree` via legacy path. Zero test changes — base-class `scanTree` wrapper calls the 4 methods.

## 0.8.2

### Improved

- **v7.7 — Ring buffer for frame history**: `FrameStatsBuffer` replaced `List<FrameStats>` with fixed-capacity ring buffer. O(1) insert, bounded memory, no GC pressure during long sessions.
- **v7.8 — Correlator sort cache**: `FrameEventCorrelator` caches sorted event lists across rounds; ~40% correlator CPU reduction under sustained load.
- **v7.10 — VM reconnect polling fix**: `_pollTimeline()` error handler cancels the poll timer *before* invoking callbacks, preventing a 500ms error loop if `onConnectionChanged` throws. Timer cancel idempotent vs `reconnect()` cleanup.

## 0.8.1

### Improved

- **v7.1 — HeavyCompute two-tier severity**: 100–500ms → `medium`, >500ms → `high` (was all `high`).
- **v7.2 — NetworkMonitor threshold fix**: frequency comparison `>` → `>=` to match documented behavior; 30 requests in 5s now fires at the configured limit.
- **v7.3 — Threshold tuning pass**: 6 detector thresholds adjusted from real-app profiling data; fewer false positives, same sensitivity for genuine issues.
- **v7.4 — Correlator coverage expansion**: `FrameEventCorrelator` matches 3 additional timeline categories previously ignored; better phase attribution.
- **v7.5 — Rebuild VM fallback**: `RebuildDetector` falls back to structural density analysis when VM build counts are unavailable (was reporting nothing).
- **v7.6 — MemoryPressure warmup guard**: heap-growth detection ignores first 10s after connection to avoid startup-allocation false positives.

## 0.8.0

v6 roadmap complete (22 milestones).

### Improved

- **v6.1 — Controller async safety**: VM calls wrapped with 10s timeouts and disposed-state guards. `dispose()` cancels in-flight futures and timeline subscriptions. Prevents `setState after dispose` and hangs on lost VM connections.
- **v6.2 — AnimatedOpacity detection**: `OpacityDetector` now detects `AnimatedOpacity` at opacity 0 (in addition to static `Opacity`).
- **v6.3 — ShaderMask render detection**: `GpuPressureDetector` includes `RenderShaderMask` in the expensive render-tree check.
- **v6.4 — Nested scroll highlights**: `NestedScrollDetector` provides widget highlight overlays for inner and outer scroll regions.
- **v6.5/v6.6/v6.7/v6.8/v6.9 — UI polish**: 44px min tap target on header icons; `onPanUpdate` clamps card inside screen bounds every frame; floating card repositions when soft keyboard opens; `ValueListenableBuilder` listeners deduplicated; long text protected with `maxLines` + `TextOverflow.ellipsis`.
- **v6.12 — GuidePage back navigation**: hardware/system back returns from GuidePage to the floating card.
- **v6.13 — Model equality**: `PerformanceIssue` implements `==` / `hashCode` on `stableId` for correct Set/Map/dedup.
- **v6.14 — Enrichment error logging**: enrichment-chain failures log structured messages via `debugPrint` (no more silent swallowing).
- **v6.15 — Suppression precompilation**: suppression patterns compiled to `RegExp` once at config time (was per-issue per-scan).
- **v6.19 — ListView threshold tuning**: non-lazy `ListView` child-count threshold adjusted for accuracy.
- **v6.20 — TriggerButton adaptive position**: initial button position adapts to screen size (visible on all device sizes).
- **v6.21 — Spacing theme tokens**: 6 tokens (`spacingXxs`–`spacingXl`) on `SleuthThemeData`; ~67 hardcoded spacing values replaced across 4 UI files; consumers can customize overlay density via theme.
- **v6.22 — Benchmark robustness**: timing budgets use `budgetMultiplier` reading `CI` env var (no more flaky loaded-runner tests).

### Changed

- **v6.10 / v6.11 — Refactors**: `FloatingIssuesCard` and `IssueCard` build methods extracted into focused builders. Zero behavior change.
- **v6.16 — Platform declarations**: `pubspec.yaml` declares `android` + `ios` explicitly for pub.dev scoring.

### Added

- **v6.17 — Controller lifecycle tests**: 20+ tests for dispose guards, timeouts, error resilience.
- **v6.18 — UI widget tests**: widget tests for `FloatingIssuesCard`, `IssueCard`, `TriggerButton`, `GuidePage`.
- 1,294 tests, 0 analysis issues.

## 0.7.0

v4 + v5 roadmap complete.

### Added

- **v4.1 — Issue suppression**: `SleuthConfig.suppressedIssues` filters by `stableId` pattern (exact or trailing `*` wildcard), applied post-correlate / pre-rank. `suppressedCountNotifier` + `SessionSnapshot.suppressedCount`.
- **v4.2 — Custom detector plugin API**: `SleuthConfig.customDetectors: List<BaseDetector>`. Integrates into all 7 controller lifecycle points (init, debug snapshot, structural scans, highlights, timeline data, aggregation, dispose). Always enabled regardless of `enabledDetectors`. Barrel exports `BaseDetector`, `ParsedTimelineData`, `DebugSnapshot`.
- **v5.1 — Overlay theming**: `SleuthThemeData` with 60 color tokens extracted from 6 UI files. `SleuthThemeData.light()`, auto-brightness via `MediaQuery.platformBrightness`, `copyWith()`, `SleuthTheme` InheritedWidget with dark fallback.
- **v5.2 — Export enrichment**: `SessionSnapshot` schema v2 — `PhaseEvent` toJson/fromJson + rolling buffer, `GcEventSummary` + `PlatformChannelSummary` serializable wrappers, `FpsPercentiles` (p50/p95/p99), `rankingScore`/`rankingBreakdown` on `PerformanceIssue`, `recentFrames` (last 60), `schemaVersion`. All new fields nullable.
- **v5.3 — Causal issue graph**: 23 cause-effect rules build a directed graph; issues annotated with `rootCauseId`/`downstreamIds`. Confidence suppression hides `possible` downstream when root is `confirmed`/`likely`. UI: `FloatingIssuesCard` filters downstream; `IssueCard` shows `↳ N` badge + "Related effects" section. New theme token `effectsBadge`.
- **v5.4 — Configurable detector thresholds**: `DetectorThresholds` nested config on `SleuthConfig`, 10 tunable parameters. Defaults match pre-change hardcoded values; secondary severity thresholds scale as `* 2`. Barrel exports `DetectorThresholds`.
- **v5.6 — Network-to-frame correlation**: `NetworkMonitorDetector` adds `startRequest()`/`endRequest()`. `FrameVerdict` gains `pendingRequestCount` + `slowestPendingMs`. `SleuthHttpOverrides` gains `onRequestStarted`/`onRequestEnded`. All 3 verdict paths enriched; 2 new causal rules. Zero overhead when network monitoring disabled.
- **v5.8 — RepaintBoundary coverage detector** (22nd detector, `DetectorType.repaintBoundary`, structural): walks for 5 expensive GPU widget types (`Opacity`, `ClipPath`, `BackdropFilter`, `ShaderMask`, `CustomPaint`), checks for `RenderRepaintBoundary` within 3 ancestor levels. Three-tier confidence: `possible` → `likely` (>10/sec) → `confirmed` (>30/sec). 3 new causal rules.

### Changed

- **v4.4 — `FloatingIssuesCard` sub-widgets extracted**: `_StatusRow`, `_CardFooter`, `_WarningBanners`. State class 659 → 433 lines, zero behavior change.
- **v4.5 — Example app modularized**: 18 demo screens extracted from `example/lib/main.dart` (1,807 → 239 lines) into `example/lib/demos/`.
- **v5.5 — Detector registry**: 21 individual detector fields on `SleuthController` → unified `List<BaseDetector>` registry. 7 dispatch methods use lifecycle-filtered loops. Adding a detector = 1 new file + 1 enum + 1 registry line. ~-90 net lines in controller.

## 0.6.1

### Fixed

- **FPS counter precision**: `averageFps` uses microsecond-precision arithmetic (was ms); eliminates ~8% truncation inflation (6.5ms truncated to 6ms gave 167 FPS instead of 154).
- **FPS counter startup**: `_frameTiming.start()` moved before `await client.connect()` so counter captures frames during slow VM connection (1.5–10.5s) instead of showing 0.
- **FPS display capped at target**: UI clamps displayed FPS at `fpsTarget` (default 60); idle profile-mode screens show 60 instead of 120+.
- **`fpsColor` target-aware**: thresholds relative to `fpsTarget` (green ≥ 83%, amber ≥ 50%); was hardcoded 50/30 FPS.
- **`exportSnapshot` reads live buffer**: uses `_frameTiming.frameBuffer` directly when initialized.

### Added

- `TriggerButton.fpsTarget` wired from `SleuthConfig.fpsTarget`; 9 FPS throughput tests in `frame_stats_buffer_fps_test.dart`; FPS Stress Test demo screen.

## 0.6.0

### Changed

- **Replaced `DashboardSheet` with `FloatingIssuesCard`**: bottom sheet (1,241 lines) → draggable floating card (~830 lines). Removed `FrameChart`, tabs, filter chips. FPS shown on `TriggerButton`.
- **Guide redesigned**: full-screen `GuidePage` with staggered entrance animations + 4 expandable sections (Quick Start, Understanding the Card, Color Legend, Tips & Tricks).
- **Resizable card**: width/height via corner grip handle; double-tap header to maximize/restore.

### Added

- `FloatingIssuesCard`, `_CornerGripPainter` (6-dot grip inside corner radius), `GuidePage` with fade+slide animations, 9 card-resize tests.

### Removed

- `DashboardSheet`, `FrameChart`, `TabBarView` with keep-alive, filter chips, chart `AnimationController`.

## 0.5.0

### Added

- **v3.2 — Context-aware fix hints**: centralized `FixHintBuilder` with 28 static methods (one per issue type). Widget-specific, location-aware hints (reference detected widget name, ancestor chain, interaction context). `FixEffort` enum (`quick`/`medium`/`involved`); `fixEffort` nullable on `PerformanceIssue` for backward compat. UI effort badge reads from model field with keyword fallback for legacy JSON.
- **v3.3 — Issue-to-verdict linking**: amber "Jank detected" banner on Live tab when a verdict has related issues; `JANK` badge on issue cards correlated with current jank verdict; tap banner to flash correlated cards in Issues tab.
- **v3.8 — Overlay UX improvements**: widget name before ancestor chain in expanded cards; "Widget not currently visible" feedback for missing highlight targets; interaction-context filter chips on Issues tab (All/Idle/Scrolling); "About this detection" collapsible (source, confidence, verification); effort indicators (QUICK/MEDIUM/INVOLVED) on fix hint boxes; color legend in Guide tab.

### Changed

- All 21 detectors use `FixHintBuilder` instead of hardcoded strings (detector logic unchanged).
- `PerformanceIssue.fixEffort` nullable, backward compatible.
- Barrel exports `FixHintBuilder`.

## 0.4.0

### Improved

- **v3.1.1 — AnimatedBuilder threshold**: subtree size 5 → 20 (fewer false positives on normal animations). Confidence `possible` by default, `likely` only when `DebugSnapshot` confirms rebuild rate > 30/sec.
- **v3.1.2 — CustomPainter secondary heuristic**: `frequent_repaint_painter` — when no always-true painters exist but `CustomPaint` paint rate > 30/sec, warn to review `shouldRepaint`.
- **v3.1.3 — MemoryPressure warmup exclusion**: heap-trend alerts suppressed first 5s after initial sample (prevents startup-allocation false positives). GC pressure and capacity alerts unaffected. Configurable via `SleuthConfig.memoryWarmupDurationMs`.
- **v3.1.4 — NestedScroll cross-axis suppression**: horizontal ListView inside vertical ScrollView (and other cross-axis combos) no longer fires. Only same-axis nesting is flagged.
- **v3.1.5 — Opacity near-zero detection**: threshold widened from `== 0.0` to `< 0.01`. Detail text includes actual opacity value.
- **v3.1.6 — GpuPressure structural-issue preservation**: on VM disconnect, structural issues (expensive render nodes) preserved at `possible` confidence (was cleared entirely). Only VM-backed raster dominance issue removed.
- **v3.1.7 — PlatformChannel duration tracking**: fires when either frequency exceeds threshold OR cumulative duration > 8ms (`SleuthConfig.platformChannelDurationThresholdMs`). Detail includes top method names.
- **v3.9 — FrameEventCorrelator binary search**: O(E×F) linear → O(E log F) binary using pre-sorted frame lists. Behaviorally identical.

### Added

- `SleuthConfig.memoryWarmupDurationMs` (default 5000ms).
- `SleuthConfig.platformChannelDurationThresholdMs` (default 8ms).

## 0.3.0

### Added

- **v2.2 — Heap trend monitoring**: `MemoryPressureDetector` polls `getMemoryUsage()` alongside VM timeline; tracks 60-sample (30s) rolling window with linear regression. New issues: *Heap Growing* (slope > 500 KB/sec for ≥10s, warning/likely), *Heap Near Capacity* (heap usage > 80% capacity, critical/confirmed). `HeapSample` exported.
- **v2.3 — Jank CPU attribution**: on jank + VM connected, `getCpuSamples()` queried for the frame window. `CpuSampleAggregator` ranks by exclusive ticks, surfaces top 5 in `FrameVerdict.topFunctions`. Two-phase emission: verdict fires immediately, then updates with CPU attribution when samples arrive (or 500ms timeout). `CpuAttribution` exported; dashboard shows "Top: ClassName.method (N%)" on jank.
- **v2.4 — Source file:line in ancestor chains**: `buildAncestorChain()` appends `(lib/path/file.dart:line)` to leaf when `--track-widget-creation` is active (debug default). Uses `InspectorSerializationDelegate`. Cached per widget runtime type (bounded 200 entries). Zero profile-mode overhead. `SourceLocationCache.abbreviatePath()` for `lib/`-relative display.

### Changed

- `MemoryPressureDetector`: `processHeapSample()` replaces `updateHeapStats()`. Rolling-window regression replaces percentage-based growth detection.
- `FrameVerdict` gains `topFunctions: List<CpuAttribution>?` + `withTopFunctions()` copy method.
- `exportSnapshot()` includes `heapSamples` array + CPU attribution when available.
- Barrel exports `CpuAttribution`, `HeapSample`, updated `FrameVerdict`.
- Ancestor-chain framework filter: 17 additional framework widgets excluded (transitions, builders, pointer/render infra).
- IssueCard no longer shows redundant "Widget:" line when detail text already contains ancestor chain.
- README "What DevTools Still Does Better" narrowed to 2 (heap snapshots, full flame chart) — network / memory trends / CPU profiling / widget-exact attribution no longer DevTools-only.

## 0.2.0

### Breaking Changes

- `DetectorType.memoryLeak` → `DetectorType.memoryPressure` (update `enabledDetectors`).
- `DetectorType.mediaQueryRebuild` → `DetectorType.shallowRebuildRisk` (update `enabledDetectors`).
- `DetectorLifecycle.runtime` added — exhaustive switches need a new case.

### Added

- **Per-frame event correlation**: VM timeline events matched to frames by monotonic timestamp overlap (replaces batch attribution).
- **Three-tier verdict degradation**: Correlated > Full > Basic, falls back automatically based on VM connectivity and correlation quality.
- **FrameTiming upgrades**: `totalSpan` (vsyncStart→rasterFinish) as primary jank indicator; pipeline stall detection; scheduler delay detection; build-to-raster gap measurement.
- **Debug attribution hooks** (`enableDebugCallbacks`): opt-in per-widget rebuild/repaint via `debugOnRebuildDirtyWidget` + `debugOnProfilePaint`. Default false to avoid DevTools conflict.
- **Heavy debug instrumentation** (`enableDeepDebugInstrumentation`): per-widget timeline events via 6 Flutter debug globals with save/restore lifecycle. UI shows purple warning banner when active.
- **Two-tier config model**: simple top-level switches + expert `advanced` block (`DebugInstrumentationConfig`).
- **Issue ranking**: weighted composite score (severity + frame impact + confidence + recurrence) drives dashboard order.
- **Route tagging**: automatic `routeName` stamping via `ModalRoute.of()`; shown in expanded cards.
- **Interaction context**: `idle`/`scrolling`/`navigating` stamped on issues ("During: scrolling").
- **Rolling jank capture buffer**: worst-N frame retention (default 50, `captureBufferCapacity`). Evicts mildest frames when full.
- **JSON session export**: `Sleuth.exportSnapshot()` + `exportSnapshotJson()`. Dashboard export button copies to clipboard.
- **Source-location enrichment**: ancestor chain attribution on structural + debug-backed issues ("Widget: Outer > Middle > Inner").
- **Timeline enrichment**: dirty widget names/counts extracted from enriched VM timeline args (build scope, layout, paint phases).
- **Rebuild/repaint widget highlights**: visual overlay rects correlated from `DebugSnapshot` + enriched VM names.
- `stableId` on `PerformanceIssue` (UI state persistence across scans); `ancestorChain` for source-location guidance.
- `ObservationSource` enum (VM timeline / debug callback / structural / combined); UI shows left-border accent (green/purple/gray).
- Confidence badges: Confirmed / Likely / Possible with color-coded chips.
- **20th detector**: Repaint detector (hybrid: VM + debug callback).
- **Self-overhead benchmark suite** (29 tests): per-detector scan overhead, full-scan scaling, timeline processing, buffer bounds, issue/highlight count limits.
- **Validation matrix** (`doc/validation_matrix.md`): per-platform release-readiness grid, degradation verification, detector coverage checklist.
- **Degradation contract integration tests** (9): VM disconnect/reconnect, verdict path switching, detector group isolation.
- **5 new example demos**: Opacity Zero, AnimatedBuilder No Child, Shallow Rebuild Risk, Font Loading Stress, Repaint Stress.

### Changed

- `MemoryLeakDetector` → `MemoryPressureDetector` (honest framing — monitors GC frequency + heap growth, not individual object leaks).
- `MediaQueryRebuildDetector` → `ShallowRebuildRiskDetector` (finds shallow StatefulWidgets during high build activity; does not observe actual `MediaQuery.of()` usage).
- `RebuildDetector` labels widget names as screen context, not proven attribution. Title → "High Rebuild Activity".
- `GpuPressureDetector` confidence corrected (was reversed): `confirmed` for observed raster dominance, `likely` when expensive render nodes also found.
- `OpacityDetector`: no longer claims GPU waste for `Opacity(0.0)` — repurposed as correctness hint (widget still participates in hit testing, layout, semantics). Confidence → `possible`, category → `layout`.
- Removed dead `analyzeBasicMode()` from `RenderPipelineAnalyzer`.
- `fpsTarget` now drives jank thresholds (was hardcoded 16/33ms regardless of target).
- `IssueConfidence` doc comments describe evidence tiers accurately.

### Fixed

- Erroneous `* 1024 * 1024` on `pictureCacheBytes` in `FrameTimingDetector` — `FrameTiming.pictureCacheBytes` already returns bytes.
- Chart budget line + color thresholds use per-frame `frameBudgetMs` (was hardcoded 16/33ms) — correctly supports 120fps mode.

## 0.1.0

- Initial release.
- 19 performance detectors (VM-only, hybrid, structural).
- Dual-mode analysis (Full VM Timeline + Basic SchedulerBinding).
- In-app overlay with live FPS chart, issue dashboard, guide.
- Debug-mode warning banner.
- Configurable thresholds and detector selection.
- Zero release overhead (`kReleaseMode` guard).
