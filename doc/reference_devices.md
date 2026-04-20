# Pinned reference devices & rotation policy

Sleuth's `runtimeVerified` and `externallyCited` tier claims are backed
by profile-mode captures recorded on pinned hardware, with pinned OS and
Flutter versions. Pinning the reference environment is the mechanism
that makes the reliability ledger auditable: a future reader can clone
the repo, boot the same hardware and Flutter version, and re-record a
capture that satisfies the same schema. Anything more permissive than
that is aspirational.

## Current matrix (v0.16.2)

| Role | Device | OS | Flutter stable |
|---|---|---|---|
| Primary iOS | iPhone 13 mini | iOS 17.6.1 | 3.32.x |
| Primary Android | Pixel 7 | Android 14 | 3.32.x |

Enforced programmatically in
`lib/src/validation/profile_capture_schema.dart`:

```dart
static const Map<String, Set<String>> approvedDevicePairs = {
  'iPhone 13 mini': {'iOS 17.6.1'},
  'Pixel 7':        {'Android 14'},
};
static const String approvedFlutterMajorMinor = '3.32';
```

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

## Why Flutter 3.32.x

The current stable channel's minor version at v0.16.2 ship. The schema
pins the full major.minor to surface a silent channel bump: a tier raise
PR that captures on 3.33 will fail the gate until the matrix rotates.

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
"holds on Flutter 3.32.x / iPhone 13 mini iOS 17.6.1" is a specific
statement. If we silently advanced the matrix to 3.34.x mid-year, every
unexpired tier raise would start claiming something it was never
validated against. Rotating in a dedicated release is the only way to
say "we accept the responsibility to re-validate the ledger against the
new pins."

Requests for ad-hoc pair additions (new device, same year) should be
rejected in favour of waiting for the next rotation window. If a
detector's behaviour is specific to hardware not currently in the
matrix, that detector's tier raise should wait for the matrix to
rotate — not bend the schema to accommodate.
