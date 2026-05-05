# Pinned reference devices & rotation policy

Sleuth's `runtimeVerified` and `externallyCited` tier claims are backed
by profile-mode captures recorded on pinned hardware, with pinned OS and
Flutter versions. Pinning the reference environment is the mechanism
that makes the reliability ledger auditable: a future reader can clone
the repo, boot the same hardware and Flutter version, and re-record a
capture that satisfies the same schema. Anything more permissive than
that is aspirational.

## Current matrix (v0.23.0)

| Role | Device | SoC | OS | Flutter stable |
|---|---|---|---|---|
| Primary iOS | iPhone 12 | A14 | iOS 17.5 | 3.41.x |

Enforced programmatically in
`lib/src/validation/profile_capture_schema.dart`:

```dart
static const Map<String, Set<String>> approvedDevicePairs = {
  'iPhone 12': {'iOS 17.5'},
};
static const String approvedFlutterMajorMinor = '3.41';
```

## Android coverage gap

**The current matrix is iOS-only.** Sleuth requires a real Android
reference device to validate `runtimeVerified` tier raises that depend
on Android-specific signal sources:

- Shader compilation timing (Skia warmup behaviour differs from iOS Metal)
- Platform-channel threading + main-isolate scheduling
- Memory pressure GC cadence under Dalvik-derived heap policies
- 90 Hz / 120 Hz dynamic refresh frame pacing
- Zygote + ContentProvider startup overhead

Detectors with platform-divergent behaviour at these signal sources
**cannot raise to `runtimeVerified` until an Android reference device is
pinned**. The reproducerOnly tier on Android-sensitive detectors stays
in place until the matrix expands.

Tracking: when an Android reference device is sourced, add a row above
plus the device pair to `approvedDevicePairs` in the schema.

## Why pin a single device today

Sourcing reference hardware has a real cost — devices age out, OS
versions drift, Flutter ships new minors quarterly. The matrix
deliberately stays small enough that one operator can re-record every
capture in an afternoon when a rotation lands. Adding devices the
operator does not personally maintain risks tier raises pinned to
hardware nobody can reach, which is worse than a smaller matrix.

The single-device matrix is honest about coverage limits. Tier raises
that pass on iPhone 12 / iOS 17.5 / Flutter 3.41.x are valid for that
environment. Detectors with iOS-only signal sources (e.g. Skia shader
warmup on Metal) raise without requiring Android coverage. Detectors
with Android-divergent behaviour must wait.

## Why Flutter 3.41.x

3.41 is the current stable channel minor. Chosen over earlier minors
because the example app's iOS bootstrap uses
`FlutterImplicitEngineDelegate` / `FlutterSceneDelegate` bindings
introduced in 3.41, and the `vm_service` patch level required by the
validation harness ships on 3.41+. Downgrading to 3.40 would require
reverting those bindings (multi-file compat regression).

The schema pins the full major.minor to surface a silent channel
bump: a tier raise PR that captures on 3.42 will fail the gate until
the matrix rotates.

## Rotation policy

The matrix rotates **once per calendar year**, in a dedicated release.
Rotation releases update:

1. `ProfileCaptureSchema.approvedDevicePairs`.
2. `ProfileCaptureSchema.approvedFlutterMajorMinor` and the matching
   regex `_flutterVersionPattern`.
3. This document's Current matrix table.
4. `test/validation/captures/README.md` recording instructions if the
   tooling changed (DevTools UI revision, export format migration).
5. `_fixtures/anchor_devtools_export.json` re-recorded on the new
   environment plus its SHA-256 fingerprint in
   `test/validation/profile_capture_schema_anchor_test.dart`. The schema
   drift-guard stays grounded in reality rather than the prior year's
   pins.

Adding the Android reference device is also rotation-class work.

## Why not allow "any supported device"

A single device is a small matrix — but the alternative isn't "all
devices," it's "devices we never actually reviewed the capture on."
Unpinned captures read `runtimeVerified` but can't be reproduced. The
audit gate's value is precisely that a captured claim corresponds to a
specific, reboot-able environment; permissive pins would dilute that to
nothing.

## Why rotations are deliberate, not silent

A rotation changes the *meaning* of every prior `runtimeVerified` claim:
"holds on Flutter 3.41.x / iPhone 12 iOS 17.5" is a specific statement.
If we silently advanced the matrix to 3.34.x mid-year, every unexpired
tier raise would start claiming something it was never validated
against. Rotating in a dedicated release is the only way to say "we
accept the responsibility to re-validate the ledger against the new
pins."

Requests for ad-hoc pair additions (new device, same year) are
rejected in favour of waiting for the next rotation window. If a
detector's behaviour is specific to hardware not currently in the
matrix, that detector's tier raise waits for the matrix to rotate —
not bend the schema to accommodate.
