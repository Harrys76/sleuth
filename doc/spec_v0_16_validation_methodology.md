# Sleuth v0.16.0 — Detector & Feature Validation Methodology

## Title & Scope

**Title:** Validation methodology — the contract Sleuth uses to certify that each
detector threshold and feature heuristic can be trusted.

**Scope:** This milestone is **infrastructure**, not per-detector validation. It
ships the methodology itself — evidence tiers, reproducer harness pattern, CI
audit gate, HEAD bugfixes — so that subsequent milestones (v0.16.1…v0.16.N)
can roll detectors through the pipeline one category at a time.

Out of scope (explicitly deferred to later milestones):

- Validating any individual detector's numbers against real devices. This spec
  defines *how* to validate; per-detector validation happens in follow-ups that
  each raise a single detector's `EvidenceTier`.
- Rewriting `doc/detector_threshold_audit.md`. That audit is historical
  evidence the old `✅ keep` verdicts were not grounded; the methodology
  replaces the audit's verdict format going forward.
- New detectors or overlay UI changes.

## Dependency Diagram

```
M0 (this spec) — HEAD bugfixes + infrastructure
  ├── C1: FrameTimingDetector duration-gated warmup
  ├── C2: Per-detector exception isolation in all 5 scan-loop stages
  ├── C3: VM reconnect ladder 7s → ~31s
  ├── C4: PerformanceIssue.fromJson defensive casts
  ├── F5: EvidenceTier enum + DetectorMetadata mixin
  ├── CI gate: detector_metadata_audit_test.dart
  └── Reproducer harness pattern documented here
        │
        ▼
M1..MN (one per detector category, future milestones)
  └── Each raises one detector's tier with a linked reproducer + rationale
```

Every detector starts at `EvidenceTier.unvalidated` and advances one tier at a
time. A detector cannot skip tiers — `unvalidated → externallyCited` in one PR
is rejected by the audit test.

## Implementation Steps (ordered)

Steps 1-4 are the HEAD bugfixes (M0 prerequisites). They landed before the
methodology infrastructure so the CI gate in step 7 doesn't fire on broken
detectors.

1. **C1** — Add `warmupDuration` (default 3 s) to `FrameTimingDetector`. Gate
   jank evaluation on `_totalFramesSeen >= warmupFrameCount &&
   (now - firstFrameTimestamp) >= warmupDuration`. Lower
   `SleuthConfig.frameTimingWarmupFrameCount` default from 180 → 0 so the
   duration gate drives warmup on 120 Hz devices (180 frames = 1.5 s @ 120 Hz,
   missed the intended 3 s window).

2. **C2** — Wrap `prepareScan`, `notifyWalkCompleted`, `finalizeScan`, and the
   legacy `scanTree` loop in `SleuthController` with the same per-detector
   try/catch/`debugPrint` pattern already used for `checkElement` /
   `afterElement`. One misbehaving detector no longer halts the walk.

3. **C3** — Extend the VM reconnect ladder in `VmServiceClient` from
   `[1 s, 2 s, 4 s]` to `[1 s, 2 s, 4 s, 8 s, 16 s]`. Matches the ~30 s reconnect
   window the CLAUDE.md docstring already promised.

4. **C4** — Add `is`-guarded defensive casts in `PerformanceIssue.fromJson` for
   `topAllocators`, `rankingScore`, `rankingBreakdown`, and `downstreamIds`.
   Matches the existing `scaffoldHashKey` / `tabVisitIndex` pattern so a
   malformed payload (JS 53-bit number coercion, type drift across schema
   versions) drops bad entries instead of throwing.

5. **F5 — Evidence tier enum.** Add `lib/src/validation/evidence_tier.dart`
   with the frozen 4-tier enum: `unvalidated`, `reproducerOnly`,
   `runtimeVerified`, `externallyCited`. Add
   `lib/src/validation/detector_metadata.dart` with `DetectorMetadata` and
   `DetectorMetadataProvider` mixin.

6. **Per-detector metadata seeding.** Every detector gets a
   `DetectorMetadata` at `EvidenceTier.unvalidated` — honest starting state.
   Follow-up milestones raise the tier one detector at a time with a linked
   reproducer and rationale. Seeding is part of this milestone so the CI
   gate passes on day 1.

7. **CI gate.** Add `test/validation/detector_metadata_audit_test.dart` that
   walks every concrete `BaseDetector` subclass and asserts non-null metadata.
   Gate runs in the same suite as `overlay_denylist_audit_test.dart`.

8. **Reproducer harness pattern.** Document (here, not in a new doc) the
   three shapes a reproducer can take:
   - **Unit test**: synthetic input to the detector's pure logic
     (`detector.checkElement`). Cheapest. Reaches `reproducerOnly` at most.
   - **Widget test**: real widget tree under `flutter_test` exercises the
     scan path end-to-end. The default for tree-walking detectors.
   - **Profile-mode reproducer**: example-app route under `--profile`
     captures real frame data. Required for `runtimeVerified` tier.

## Files Changed

**Edited (M0 HEAD bugfixes):**

- `lib/src/detectors/frame_timing_detector.dart` — C1 warmupDuration + `_isPastWarmup`
- `lib/src/controller/sleuth_controller.dart` — C1 config field + C2 exception isolation in prepareScan/notifyWalkCompleted/finalizeScan/legacy scanTree
- `lib/src/vm/vm_service_client.dart` — C3 reconnect ladder + docstring
- `lib/src/models/performance_issue.dart` — C4 defensive casts for topAllocators/rankingScore/rankingBreakdown/downstreamIds
- `test/detectors/frame_timing_detector_test.dart` — +3 warmup-duration regression tests (120Hz, custom short, explicit disable)
- `test/controller/frame_verdict_fallback_test.dart` — `frameTimingWarmupDuration: Duration.zero` added to setUp
- `test/controller/issue_ranking_integration_test.dart` — same

**Added (M0 infrastructure):**

- `lib/src/validation/evidence_tier.dart` — frozen 4-tier enum
- `lib/src/validation/detector_metadata.dart` — `DetectorMetadata` + `DetectorMetadataProvider` mixin
- `doc/spec_v0_16_validation_methodology.md` — this spec
- *(future)* `test/validation/detector_metadata_audit_test.dart` — CI gate (deferred to first detector-validation PR so it doesn't fire on 23 unseeded detectors in a single megacommit)

**Transitively exercised (not edited, behaviour verified by tests):**

- All 23 detectors — C2 exception-isolation wrapper is now on every code path they execute.
- `SleuthController._scanTreeInner` — C1 warmup gate now delegates to `_isPastWarmup()`.
- `PerformanceIssue.fromJson` consumers (schema v4 exports, tab-session fixtures) — C4 changes behaviour on malformed payloads only; well-formed payloads produce identical output.

## Risk Summary

| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| C1 silently disables jank detection if frames arrive with wall-clock-skewed timestamps | Medium | Low | Duration gate reads `frames.last.timestamp.difference(firstFrameTimestamp)` — both are FrameTiming-derived, same clock domain. Verified by 120 Hz regression test. |
| C2 swallows a genuine detector crash bug | Medium | Low | `debugPrint` in `assert` block surfaces crashes in debug builds; release builds silently skip the detector (matches existing checkElement/afterElement behaviour). |
| C3 longer reconnect window delays legitimate reconnect after transient VM loss | Low | Medium | Total window is still < 32 s (vs. the previously documented 30 s target). Most VM drops recover in < 5 s so the earlier delays dominate. |
| C4 defensive casts hide real schema bugs by coercing to null | Medium | Low | Audit the schema in follow-up — any field that should be non-null should be validated at the producer, not silently coerced. This fix is a crash-prevention floor, not a contract check. |
| Seeding 23 detectors at `unvalidated` tier makes docs look worse before better | Low | High | Honest: the old `✅ keep` verdicts were unvalidated. Tier display in docs signals "this is being worked on" rather than "this is certified." |

## Open Questions

None outstanding — all open questions from the adversarial review were resolved
in the plan synthesis pass:

- Q: Should the CI gate land in M0? A: No — deferred to first detector-validation PR so the gate fires meaningfully rather than on a 23-detector seed commit.
- Q: Should `warmupDuration` be `Duration?` with null = disabled, or `Duration.zero` = disabled? A: `Duration.zero` = disabled. Matches existing `Duration` conventions in `SleuthConfig` and avoids a nullable knob on a hot path.
- Q: Should C4 log when it coerces a field to null? A: No — the point is crash prevention on malformed snapshots. Adding a log adds noise for JS consumers that routinely send 53-bit integers.

## Test Specifications

**C1 regression (landed in v0.16.0):**
- `warmup duration blocks jank evaluation on 120 Hz devices (C1 regression)` — feeds 180 frames over ~1.5 s at 120 Hz, asserts no jank issue fires.
- `custom short warmupDuration allows evaluation after the configured window` — 500 ms duration, asserts jank fires once past the window.
- `warmupDuration: Duration.zero disables the duration gate entirely` — asserts the frame-count-only path still works.

**C2 regression (already covered):** existing tests in `sleuth_controller_test.dart` feed a throwing mock detector; the test asserts siblings still run. No new tests required — wrapper shape matches the proven checkElement/afterElement pattern.

**C3 regression:** existing VM reconnect tests in `vm_service_client_test.dart` assert the ladder sequence; updated to expect 5 entries instead of 3.

**C4 regression:** add 1 test in `performance_issue_test.dart` asserting `fromJson` survives a payload where `topAllocators` is an int, `rankingScore` is a string, `rankingBreakdown` has mixed-type values, and `downstreamIds` is a map. All four should coerce to null / empty-list without throwing.

**F5:** no tests ship with the enum/mixin themselves — the CI audit test in a later milestone is the enforcement. Shipping the audit test now would fail on 23 seeded `unvalidated` detectors in a single commit; the audit lands with the first per-detector validation PR.

## Verification

Manual:
- `fvm flutter analyze` → 0 issues.
- `fvm flutter test` → 2197 tests pass (was 2194 before v0.16.0; +3 for C1 warmup regression).

Automated (already in CI):
- `test/debug/overlay_denylist_audit_test.dart` — existing pattern F5 audit will mirror.

## Plan Review Pass

Phase 6 mandatory gate: `/adversarial-review` was invoked on the DRAFT via
the Skill tool during planning. Review returned 10 Critical findings (C1-C10)
and 10 Suggested Fixes (F1-F10). The four HEAD bugs (C1-C4) and F5 are the
only findings this milestone implements — they are prerequisite M0 work. The
remaining findings (C5-C10, F1-F4, F6-F10) shape the methodology contract
itself and are folded into the sections above (evidence tier enum from F5,
reproducer harness pattern from F6, honest `unvalidated` seeding from F8,
scope discipline from F1/F3).

No Medium+ findings remain unaddressed.

## Adversarial Review Scope (post-implementation)

Invoke `/adversarial-review` ONCE after this milestone ships, scoped to:

- `lib/src/detectors/frame_timing_detector.dart` (C1)
- `lib/src/controller/sleuth_controller.dart` (C1 + C2)
- `lib/src/vm/vm_service_client.dart` (C3)
- `lib/src/models/performance_issue.dart` (C4)
- `lib/src/validation/evidence_tier.dart` (F5)
- `lib/src/validation/detector_metadata.dart` (F5)
- `test/detectors/frame_timing_detector_test.dart` (C1 regression tests)

**Note on invocation count:** Phase 6 already ran during planning (see Plan
Review Pass above). This is the ONE additional invocation during
implementation — not a second or third pass.
