# Pinned reference devices & rotation policy

Sleuth's `runtimeVerified` and `externallyCited` tier claims are backed
by profile-mode captures recorded on pinned hardware, with pinned OS and
Flutter versions. Pinning the reference environment is the mechanism
that makes the reliability ledger auditable: a future reader can clone
the repo, boot the same hardware and Flutter version, and re-record a
capture that satisfies the same schema. Anything more permissive than
that is aspirational.

## Current matrix (v0.16.4)

| Role | Device | SoC | OS | Flutter stable |
|---|---|---|---|---|
| Primary iOS | iPhone 13 mini | A15 | iOS 17.6.1 | 3.41.x |
| Secondary iOS (ad-hoc, v0.16.4) | iPhone 12 | A14 | iOS 17.5 | 3.41.x |
| Primary Android | Pixel 7 | Tensor G2 | Android 14 | 3.41.x |

Enforced programmatically in
`lib/src/validation/profile_capture_schema.dart`:

```dart
static const Map<String, Set<String>> approvedDevicePairs = {
  'iPhone 13 mini': {'iOS 17.6.1'},
  'iPhone 12':      {'iOS 17.5'},
  'Pixel 7':        {'Android 14'},
};
static const String approvedFlutterMajorMinor = '3.41';
```

### One-time exception: v0.16.4 matrix additions

**This is a one-time exception, not a new policy.** v0.16.4 added
iPhone 12 / iOS 17.5 to `approvedDevicePairs` and rotated
`approvedFlutterMajorMinor` from `3.32` to `3.41` mid-cycle — both
outside the annual rotation window. The next rotation remains annual
(v0.17 or later). Future requests for mid-cycle matrix changes are
rejected per the policy in "Why rotations are deliberate, not silent"
below; this section documents why v0.16.4 bent the rule once, not a
general carve-out.

Context for the one-time exception:

- **iPhone 12 / iOS 17.5**: the reviewer recording v0.16.4's first
  `externallyCited` tier raise did not have access to an iPhone 13
  mini. A14 Bionic (iPhone 12) is an adjacent performance class to A15
  (iPhone 13 mini) for mobile-API latency budgets in the 1 s / 3 s
  range, so a single-device bracket triad on iPhone 12 was accepted as
  partial validation. The claim is explicitly scoped as single-device
  in the detector's rationale — it is NOT a statement that the
  threshold holds across the matrix.
- **Flutter 3.41.x**: the recording environment ships iOS
  `AppDelegate.swift` bindings (`FlutterImplicitEngineDelegate`,
  `FlutterSceneDelegate`) and a `vm_service` patch level the example
  project depends on, and cannot be downgraded to 3.32 without a
  multi-file compat regression. 3.41 is the current stable channel
  minor at v0.16.4 ship and matches the development baseline.

The anchor fixture's `flutterVersion` was bumped in lockstep
(`3.32.5` → `3.41.4`) and its SHA-256 fingerprint in
`test/validation/profile_capture_schema_anchor_test.dart` updated to
the new digest. Subsequent tier raises MUST wait for the annual
rotation rather than repeat this exception.

## Why two devices

One iOS + one Android is the minimum that keeps engine-level
platform differences observable — shader compilation, platform-channel
threading, memory pressure GC cadence, and OS-level frame pacing all
diverge meaningfully between the two. A single-platform pin would make
cross-platform regressions invisible to the ledger.

## Why mini / Pixel 7 specifically

- **iPhone 13 mini (2021, A15)**: small-RAM, mid-tier GPU, still
  widely fielded. Reveals pressure issues that flagships mask. 60 Hz
  display — the bracketing rule's default atTolerance (±10%) is
  calibrated against this refresh rate.
- **Pixel 7 (2022, Tensor G2)**: a recent Android baseline with a
  large active install base. 90 Hz display with dynamic refresh.

Both are common enough to source used, keeping the rotation cost
bounded.

## Why Flutter 3.41.x

The current stable channel's minor version at v0.16.4 ship (rotated
in v0.16.4 from 3.32 — see "One-time exception" above). 3.41 chosen
over 3.40 or earlier because the example app's iOS bootstrap uses
`FlutterImplicitEngineDelegate` / `FlutterSceneDelegate` bindings
introduced in 3.41, and the `vm_service` patch level required by the
validation harness ships on 3.41+. Downgrading to 3.40 would require
reverting those bindings (multi-file compat regression). 3.42+ was
not yet on the stable channel at ship time.

The schema pins the full major.minor to surface a silent channel
bump: a tier raise PR that captures on 3.42 will fail the gate until
the matrix rotates.

## Rotation policy

The matrix rotates **once per calendar year**, in a dedicated release
(Sleuth v0.17 / v0.18 / etc.). Rotation releases update:

1. `ProfileCaptureSchema.approvedDevicePairs`.
2. `ProfileCaptureSchema.approvedFlutterMajorMinor` and the matching
   regex `_flutterVersionPattern`.
3. This document's Current matrix table.
4. `test/validation/captures/README.md` recording instructions if the
   tooling changed (DevTools UI revision, export format migration).

Rotation PRs additionally re-record the anchor fixture
(`test/validation/captures/_fixtures/anchor_devtools_export.json`) on
the new environment, so the schema drift-guard stays grounded in
reality rather than in the prior year's pins.

## Why not allow "any supported device"

Two devices is a small matrix — but the alternative isn't "all
devices," it's "devices we never actually reviewed the capture on."
Unpinned captures read `runtimeVerified` but can't be reproduced. The
audit gate's value is precisely that a captured claim corresponds to a
specific, reboot-able environment; permissive pins would dilute that to
nothing.

## Why rotations are deliberate, not silent

A rotation changes the *meaning* of every prior `runtimeVerified` claim:
"holds on Flutter 3.41.x / iPhone 13 mini iOS 17.6.1" is a specific
statement. If we silently advanced the matrix to 3.34.x mid-year, every
unexpired tier raise would start claiming something it was never
validated against. Rotating in a dedicated release is the only way to
say "we accept the responsibility to re-validate the ledger against the
new pins."

Requests for ad-hoc pair additions (new device, same year) are
rejected in favour of waiting for the next rotation window. If a
detector's behaviour is specific to hardware not currently in the
matrix, that detector's tier raise waits for the matrix to rotate —
not bend the schema to accommodate. The v0.16.4 additions documented
above are a one-time exception, not precedent.
