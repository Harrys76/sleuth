# Capture authoring checklist

This directory holds profile-mode captures that back Sleuth detector and
component tier claims at `runtimeVerified` or stronger. Every capture is
parsed and validated by `ProfileCaptureSchema` (see
`lib/src/validation/profile_capture_schema.dart`); the audit gate rejects
any capture that drifts from the schema.

> Hand-written fixtures for `ProfileCaptureSchema` unit tests live under
> `_fixtures/` with their own provenance README. That directory is not a
> place to drop real captures — those live here, at the directory root
> or in subdirectories named after the detector / component.

## The bracketing rule

Every `runtimeVerified` claim ships **three** captures per threshold
being validated:

| Capture | Required relationship to threshold |
|---|---|
| `<scenario>_below.json` | `expectedMagnitude.observed < threshold` |
| `<scenario>_at.json`    | `threshold <= observed <= threshold × 1.10` |
| `<scenario>_above.json` | `expectedMagnitude.observed > threshold` |

Where `expectedMagnitude` is the hand-annotated `{min, observed, max}`
in the `sleuthMetadata` wrapper, with `min <= observed <= max`.

Two single captures at "fast" and "slow" prove nothing about the
threshold itself — it's the *spanning* that makes the bracketing rule a
falsifiable claim.

## Recording a capture (iPhone 13 mini, pinned)

1. `fvm flutter --version` must print the pinned stable release
   (`ProfileCaptureSchema.approvedFlutterMajorMinor`, currently `3.32.x`).
   If it doesn't, switch with `fvm use <version>` before recording.
2. Plug the iPhone 13 mini in. Confirm iOS version matches
   `ProfileCaptureSchema.approvedDevicePairs['iPhone 13 mini']`.
3. From the `example/` directory, run:
   ```
   cd example
   fvm flutter run --profile
   ```
4. In DevTools (opens automatically), go to the Performance tab. Let the
   app reach steady state, then exercise the scenario you want to
   capture (trigger a slow network request, jank a long frame, etc.).
5. Click **Export timeline**. DevTools saves a JSON file.
6. Wrap the JSON with a `sleuthMetadata` block at the top level (see
   schema below). DevTools does *not* emit device / OS / Flutter /
   scenario metadata — the wrapper is the hand-annotated provenance that
   makes the capture auditable.

## sleuthMetadata schema

```jsonc
{
  "traceEvents": [ /* Chrome Trace Event Format, unchanged from DevTools */ ],
  "sleuthMetadata": {
    "device":          "iPhone 13 mini",                    // required — pinned
    "deviceOsVersion": "iOS 17.6.1",                        // required — pinned
    "flutterVersion":  "3.32.5",                            // required — pinned major.minor
    "captureCommand":  "fvm flutter run --profile",         // required — reproducer
    "scenario":        "NetworkMonitor slow_request at 3s", // required — human label
    "expectedMagnitude": {
      "min":      2800,                                     // required — lower bound
      "observed": 3050,                                     // required — what you saw
      "max":      3300,                                     // required — upper bound
      "unit":     "ms"                                      // optional — display only
    },
    "captureDate":     "2026-04-18T14:40:00Z"               // required — ISO-8601
  }
}
```

Required keys enforced by `ProfileCaptureSchema`:

- `device` must be in `ProfileCaptureSchema.approvedDevicePairs`.
- `deviceOsVersion` must be in the approved OS set for the chosen
  device (pair-matched, not just membership).
- `flutterVersion` must match `^3\.32\.\d+$` until the next annual
  rotation.
- `expectedMagnitude.{min, observed, max}` must be numbers satisfying
  `min <= observed <= max`.
- `captureDate` must parse as ISO-8601.

Anything else in `sleuthMetadata` is ignored by the schema. Extra keys
like `captureNotes`, `gitSha`, `builder`, `temperature` are welcome
provenance and do not fail the gate.

## Committing

1. Add your capture(s) under `test/validation/captures/<detector_or_component>/`.
2. Update the detector's `DetectorMetadata` (or component's
   `ComponentMetadata`) so `profileCapturePaths` points at the three
   files.
3. Run `fvm flutter test test/validation/detector_metadata_audit_test.dart`
   (or `component_metadata_audit_test.dart`). The audit walks each
   capture through `ProfileCaptureSchema.parseFile` — a malformed
   capture fails the gate.
4. If your tier raise is `runtimeVerified`, add a bracket test that
   calls `ProfileCaptureSchema.validateBracket(belowFile, atFile,
   aboveFile, threshold, unit)` with the detector's threshold. This is
   the spanning check; the audit gate enforces schema, the bracket test
   enforces the rule.

## Rotating the pinned reference matrix

Device, OS, and Flutter version pins rotate **once per calendar year**,
in a dedicated release. See `doc/reference_devices.md` for the current
matrix and rotation policy. Rotating silently inside an individual tier
raise PR makes the ledger less auditable, not more — don't do it.
