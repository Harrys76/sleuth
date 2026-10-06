# Pinned reference devices and rotation policy

Sleuth's `runtimeVerified` and `externallyCited` tier claims rest on
profile-mode captures recorded on pinned hardware, with pinned OS and
Flutter versions. The pins make the reliability ledger auditable. A
later reader can clone the repo, boot the same hardware and Flutter
version, and record a capture that passes the same schema. A looser
policy would let a claim stand that nobody can reproduce.

## Current matrix (v0.37.0)

| Role | Device | SoC | OS | Flutter stable |
|---|---|---|---|---|
| Primary iOS | iPhone 12 | A14 | iOS 17.5 | 3.41.x or 3.47.x |

`lib/src/validation/profile_capture_schema.dart` enforces the matrix:

```dart
static const Map<String, Set<String>> approvedDevicePairs = {
  'iPhone 12': {'iOS 17.5'},
};
static const String approvedFlutterMajorMinor = '3.41';
static const Set<String> approvedFlutterMajorMinors = {
  approvedFlutterMajorMinor,
  '3.47',
};
```

A capture may use any member of `approvedFlutterMajorMinors`. The three
legs of one bracket must share one exact `flutterVersion` (the bracket
provenance check enforces this), so triads recorded on 3.41 stay valid
next to triads recorded on 3.47. The `rebuild_activity` and
`excessive_repaint` triads were recorded on 3.47.6, the others on
3.41.4.

## Android coverage gap

The current matrix covers iOS only. Sleuth needs a real Android
reference device to validate `runtimeVerified` raises that depend on
Android-specific signal sources:

- Shader compilation timing (Skia warmup behaviour differs from iOS Metal)
- Platform-channel threading + main-isolate scheduling
- Memory pressure GC cadence under Dalvik-derived heap policies
- 90 Hz / 120 Hz dynamic refresh frame pacing
- Zygote + ContentProvider startup overhead

A detector whose behaviour differs between platforms at these sources
cannot reach `runtimeVerified` until an Android reference device is
pinned. Android-sensitive detectors stay at `reproducerOnly` until the
matrix grows.

When an Android reference device is available, add a row to the table
above and add the device pair to `approvedDevicePairs` in the schema.

## Why pin a single device today

Reference hardware has a real cost. Devices age out, OS versions drift,
and Flutter ships new minors every quarter. The matrix stays small
enough that one operator can record every capture again in an
afternoon when a rotation lands. Adding devices the operator does not
maintain would pin tier raises to hardware nobody can reach, which is
worse than a smaller matrix.

The single-device matrix states its coverage limits. A tier raise that
passes on iPhone 12 / iOS 17.5 / Flutter 3.41.x or 3.47.x is valid for
that environment. Detectors with iOS-only signal sources (e.g. Skia
shader warmup on Metal) can raise without Android coverage. Detectors
with behaviour that diverges on Android must wait.

## Why Flutter 3.41 and 3.47

3.41 was the stable minor when most triads were recorded. The example
app's iOS bootstrap uses the `FlutterImplicitEngineDelegate` /
`FlutterSceneDelegate` bindings introduced in 3.41, and the
`vm_service` patch level the validation tooling requires ships on
3.41+. 3.47 is the development pin, and the `rebuild_activity` and
`excessive_repaint` triads were recorded on 3.47.6. A triad must use
one exact version. Both minors stay accepted until every triad has been
recorded again on the newer one.

The schema pins the full major.minor so a silent channel bump shows up.
A tier raise PR that captures on 3.42 fails the gate until the matrix
rotates.

## Rotation policy

The matrix rotates once per calendar year, in a dedicated release. A
rotation release updates:

1. `ProfileCaptureSchema.approvedDevicePairs`.
2. `ProfileCaptureSchema.approvedFlutterMajorMinors`, and the
   `approvedFlutterMajorMinor` baseline member when the oldest pin
   retires. The version validator checks set membership, so no regex
   edit is needed.
3. The current matrix table in this document.
4. The recording instructions in `test/validation/captures/README.md`,
   if the tooling changed (a DevTools UI revision, an export format
   migration).
5. `_fixtures/anchor_devtools_export.json`, recorded again on the new
   environment, and its SHA-256 fingerprint in
   `test/validation/profile_capture_schema_anchor_test.dart`. This keeps
   the schema drift guard tied to the current pins rather than last
   year's.

Adding the Android reference device is also rotation work.

## Why not allow "any supported device"

A single device is a small matrix. The alternative is not "all
devices" but "devices nobody reviewed a capture on." An unpinned
capture reads as `runtimeVerified` but cannot be reproduced. The audit
gate is useful because each captured claim maps to one specific
environment that someone can boot again. Loose pins would remove that.

## Why rotations are deliberate, not silent

A rotation changes what every earlier `runtimeVerified` claim means.
"Holds on Flutter 3.41.x or 3.47.x / iPhone 12 iOS 17.5" is a specific
statement. If the matrix moved to a newer Flutter minor mid-year
without notice, every standing tier raise would claim something it was
never validated against. A dedicated rotation release is how the
project commits to validating the ledger again against the new pins.

The project turns down requests for ad-hoc pair additions (a new
device in the same year) and waits for the next rotation window
instead. If a detector's behaviour depends on hardware outside the
matrix, its tier raise waits for the matrix to rotate; the schema does
not bend to fit it.
