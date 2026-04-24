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

### Post-implementation Codex review (3 fixes)

A Codex review of the working-tree v0.16.0 diff returned a
`needs-attention` verdict with three findings. All three landed in this
release before tag/push:

- **Warmup gate reads monotonic vsync, not per-callback wall clock (Codex
  finding 1, high).** The initial C1 fix used `DateTime.now()` stamped once
  per `addTimingsCallback` batch. Flutter can deliver many frames in a single
  callback — e.g. a cold start with 60+ buffered frames collapsed to one
  `DateTime.now()` tick — which kept the 3 s gate closed far past the
  intended warmup window. `FrameTimingDetector` now tracks
  `_firstFrameVsyncUs` (engine microseconds from
  `FrameTiming.vsyncStart`) and measures elapsed warmup against
  `frames.last.vsyncStartUs - _firstFrameVsyncUs`. Falls back to wall-clock
  only when `vsyncStartUs` is null (synthetic test frames). New
  `@visibleForTesting handleTimingsForTest(List<FrameTiming>)` bridge exists
  to drive the real `_onTimings` pipeline from unit tests. Regression test
  feeds 200 `FrameTiming`s via the public factory spanning only 500 ms of
  monotonic time and asserts the gate stays closed.
- **`PerformanceIssue.fromJson` per-entry allocator hardening (Codex finding
  2, medium).** The initial C4 guard only checked the outer `topAllocators`
  List shape; a payload like `{'topAllocators': [{'className': 42}]}` still
  crashed inside `AllocationEntry.fromJson`'s strict casts. Added
  `_tryParseAllocationEntries` helper that wraps each entry parse in
  try/catch — malformed entries drop silently, valid entries survive
  alongside them. Regression tests cover the JS-string-coercion case,
  mixed valid/invalid siblings, stringified `rankingScore`, and
  mixed-type `downstreamIds`.
- **Validation API exported from `lib/sleuth.dart` (Codex finding 3,
  medium).** `EvidenceTier` and `DetectorMetadataProvider` were reachable
  only via `package:sleuth/src/validation/...` — the headline v0.16.0
  contract was not importable through the public barrel. Added two
  `export` lines and a `test/validation/validation_public_api_test.dart`
  smoke test that imports ONLY `package:sleuth/sleuth.dart` and
  exercises the enum + mixin so future regressions fail a test instead
  of shipping a broken barrel.

### Post-Codex meta-review hardening (3 fixes)

A second Codex pass — reviewing the prior review's findings
themselves (the meta-review) — returned another `needs-attention` verdict
with three medium/low findings. All three landed in this release:

- **`PerformanceIssue.fromJson` guarded enum parsing (meta-review C3,
  medium).** Required enum fields (`severity`, `category`, `confidence`)
  and optional enum fields (`observationSource`, `interactionContext`,
  `fixEffort`) were still doing raw `IssueSeverity.values.byName(json[…]
  as String)`. A payload with `severity: 42` (JS coercion) or
  `severity: 'warn'` (typo / version skew) still aborted the whole
  snapshot deserialization — the same cross-version failure mode C4 +
  Codex finding 2 exist to survive, just on different fields. Added a
  top-level `_tryParseEnum<T>` helper and routed all six enum fields
  through it. Required fields fall back to neutral defaults
  (`IssueSeverity.warning`, `IssueCategory.build`,
  `IssueConfidence.possible`); optional fields drop to null. Six new
  regression tests cover numeric coercion, renamed/typo values, missing
  required field, optional rename/coercion.
- **`_tryParseAllocationEntries` narrowed catch (meta-review C2,
  medium).** The initial helper used bare `catch (_)`, which swallowed
  `StackOverflowError`, `OutOfMemoryError`, `StateError`, and other
  `Error` subclasses that signal VM instability or programmer bugs, not
  schema drift. Narrowed to `on TypeError catch (_)` + `on Exception
  catch (_)` — catches the realistic shapes (cast failures on
  JS-coerced fields, `FormatException` from date/number parsing,
  `ArgumentError` from byName / range drift) while letting
  resource-exhaustion and state errors propagate so regressions surface
  with a stack trace instead of as silent missing allocator data.
- **`EvidenceTier` ordering fully pinned (meta-review C4, low).** The
  Codex-3 smoke test asserted only 2 of 4 ordinals (`unvalidated.index ==
  0` + `externallyCited.index == 3`). A future reorder swapping the two
  middle values would have passed the test while breaking the
  docstring's "lowest → highest" contract. Strengthened the test to
  pin the full name sequence *and* the full ordinal sequence so any
  rename or reorder of the stable-contract enum fails a test.

### Post-meta triangulated review hardening (2 fixes)

A final dual-reviewer pass (Claude + Codex triangulation, converged in
4 substantive rounds) agreed on two residual blockers over
the post-meta tree. Both landed in this release:

- **`DetectorMetadataProvider` API contract clarified (F1, high).**
  The mixin docstring claimed detectors would "implement this via a
  static `metadata` field … so the audit test can reflect on types
  without constructing instances." Dart does not treat static members
  as part of a class interface — a static field on a mixin subtype is
  not reachable polymorphically, so the audit-without-construction path
  is not implementable. Replaced the docstring with the honest contract:
  `validationMetadata` is an instance getter backed by a `const`
  literal, the audit walks the `SleuthController`'s registered detector
  instances (the same construction path the runtime already exercises),
  and detector constructors must be side-effect-free so the audit can
  construct them in isolation if needed. No code change — this was a
  docstring-only fix, but the contract change blocks the audit test's
  design so it's in this release rather than in v0.16.1.
- **Stage wrappers profile-safe + detector quarantine (F3, medium).**
  Prior to this fix, every per-detector try/catch in
  `_runStructuralScans` used `assert(() { debugPrint(…); return true;
  }())`. `assert()` is stripped in profile mode — and Sleuth's primary
  runtime target is profile mode — so a misbehaving detector failed
  silently with no runtime signal. Additionally, a detector that threw
  in `prepareScan` (leaving internal state partially initialised) was
  still called in every subsequent stage
  (`checkElement`/`afterElement`/`notifyWalkCompleted`/`finalizeScan`),
  potentially throwing `LateInitializationError` on uninitialised fields
  or amplifying noise across thousands of visitor invocations in the
  unified walk. Combined fix in one pass: (1) replaced all seven
  assert+debugPrint blocks with `FlutterError.reportError(FlutterErrorDetails(…))`
  which survives profile-mode compilation and integrates with the app's
  crash reporter and `FlutterError.onError`, and (2) added a per-scan
  `Set<BaseDetector> failedDetectors` that is populated on any throw
  and consulted at the top of every subsequent per-detector stage
  (including inside the visitor closure that runs on every element).
  Eight new regression tests verify both contracts — five parameterised
  tests assert `FlutterError.reportError` fires under `library: 'sleuth'`
  for each stage (`prepareScan`, `checkElement`, `afterElement`,
  `notifyWalkCompleted`, `finalizeScan`), and three quarantine-behaviour
  tests verify a detector that throws in `prepareScan` is skipped in all
  four subsequent stages, a detector that throws in `checkElement` is
  skipped on every later element, and sibling detectors continue to run
  in the same scan.

### Post-triangulation round 2-3 hardening (3 fixes)

A second triangulation pass (Codex ↔ Claude) converged in Round 3 on
three additional blockers that the prior F1 + F3 pass left behind. All
three landed in this release:

- **Failed detectors still published partial issues/highlights into
  aggregation (Round 2-3, blocker 1, medium).** The F3 quarantine only
  suppressed *later* stage callbacks for detectors that threw. Aggregation
  — `_getAllIssues()` and `_collectHighlights()` — was still spreading
  `...d.issues` and `...d.highlights` for every detector, including the
  ones marked failed mid-scan. A detector that committed 49 findings via
  `SimpleStructuralDetector.report(...)` before throwing on element 50
  still leaked those partial findings into `issuesNotifier`. Promoted the
  per-scan `Set<BaseDetector> failedDetectors` local in `_runStructuralScans`
  to a controller-owned `_lastScanFailedDetectors` field, cleared at the
  top of each scan, added to on every stage failure (prepareScan,
  checkElement closure, afterElement closure, notifyWalkCompleted,
  finalizeScan, legacy scanTree), and consulted at both aggregation
  sites to filter those detectors' contributions. Two new regression
  tests: one where a failing detector emits an issue + highlight before
  throwing mid-walk and asserts neither reaches `issuesNotifier`, and
  one pairing a failing detector beside a healthy one to guard against
  an over-aggressive filter that would suppress sibling output.
- **`PerformanceIssue.fromJson.detectedAt` used unguarded `DateTime.parse`
  (Round 2-3, blocker 2, low-medium).** Malformed ISO strings or
  non-string payloads on `detectedAt` threw `FormatException` /
  `TypeError` and aborted the whole factory — the same single-field
  snapshot-abort pattern that Meta-C3 + Codex finding 2 hardened the six
  enum fields and `topAllocators` entries against. Replaced
  `DateTime.parse(json['detectedAt'] as String)` with
  `json['detectedAt'] is String ? DateTime.tryParse(...) : null` so a
  malformed timestamp degrades a single field to null instead of
  poisoning the whole snapshot. Three regression tests cover an
  unparseable string, a non-string value, and a valid round-trip.
- **F3 tests were tautological and masked duplicate-fire regressions
  (Round 2-3, blocker 3, medium).** `_ScopedErrorCapture` did not
  forward to `_previous?.call(details)`, which swallowed
  TestWidgetsFlutterBinding's layout-error reporting and hid any
  framework errors the test bindings rely on for teardown assertions.
  The per-stage matchers also used `expect(matching, isNotEmpty)`,
  which happily passed if a stage accidentally emitted its error two or
  three times. Fixed both: (1) capture handler now forwards to
  `_previous?.call(details)` so framework errors still propagate, (2)
  each per-stage test asserts `matching.length == 1` (catches
  duplicate-fire) AND `nonMatching` is empty (catches unrelated
  regressions), and (3) every test that expected a thrown detector
  error now drains it with `tester.takeException()` so the test binding
  teardown does not flag it as an unhandled error.

### Notes

- Test count: 2,220 → 2,225 (+2 aggregation-filter regression tests +
  3 `detectedAt` regression tests; F3 stage-loop tests were rewritten in
  place rather than added, so their count is unchanged).
- `fvm flutter analyze` → 0 issues. `fvm flutter test` → all pass.
- One pre-impl plan review (10 C-findings + 10 F-fixes; C1-C4 + F5 were
  prerequisite M0 code; C5-C10, F1-F4, F6-F10 shaped the methodology
  contract in the spec) **plus** one Codex post-impl review that
  surfaced the first three fixes **plus** one meta-review loop that
  surfaced the three meta-review hardening fixes **plus** two
  triangulated (Claude ↔ Codex) passes — the first converged on F1 +
  F3, the second converged in Round 3 on the aggregation-filter,
  `detectedAt`, and F3-test-tautology blockers listed above.
- F2 (`PerformanceIssue.fromJson` enum-drift cascade) was held as a
  user decision between "ship Path B skip-on-drift now" and "ship
  Path C docstring + defer cascade fix to v0.17 MCP milestone"; the
  user chose Path C and the factory now carries an explicit lossy-
  import scope note pointing v0.17 as the first-class import milestone.

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

Post-Codex review hardening — three robustness fixes on the v11 branch.

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
- **v8.3 — HTTP monitor openUrl leak**: `_MonitoringHttpClient.openUrl()` wraps `_inner.openUrl()` in try/catch. On transport failure (DNS/TLS/connection-refused), emits `RequestRecord(statusCode: -1)`, calls `onRequestEnded`, rethrows. Callback isolation — `onRequestEnded` and `onRecord` run in separate try/catches so a throwing callback can't suppress the other or mask the transport exception. Same isolation on `_MonitoringRequest.close()` and `_MonitoringResponse._emitRecord()`. Survived 4 Codex reviews.
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
