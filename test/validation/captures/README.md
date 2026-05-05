# Capture authoring checklist

This directory holds profile-mode captures that back Sleuth detector and
component tier claims at `runtimeVerified` or stronger. Every capture is
parsed and validated by `ProfileCaptureSchema` (see
`lib/src/validation/profile_capture_schema.dart`); the audit gate rejects
any capture that drifts from the schema.

> **v0.18.0+ procedure**: see `doc/capture_procedure.md` for the
> end-to-end flow that produces a triad accepted by
> `ProfileCaptureSchema.validateBracket(... requireDetectorTraceRecord:
> true)`. That doc walks the new requirements (`schemaVersion: "v1"`,
> scenario markers via `Sleuth.markScenarioBegin/End`, detector trace
> record inside the scenario span) and the `tool/wrap_capture.dart`
> CLI that replaces the hand-wrap step described below.
>
> The rest of this README documents the v0.16.x procedure and remains
> the source of truth for the `sleuthMetadata` schema shape, the
> bracketing rule, and the dormant-gate path
> (`requireDetectorTraceRecord: false`) that the NetworkMonitor orphan
> captures still satisfy.

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

## Scenario markers (AB-1 span pin)

`ProfileCaptureSchema`'s AB-1 cross-check binds the `observed` magnitude
claim to the instant-event pair:

- `sleuth.scenario.begin` — instant marker (`ph:"i"` from a Chrome-
  native DevTools export, or `ph:"n"` from a Perfetto `traceconv`
  export of `Timeline.instantSync`)
- `sleuth.scenario.end`   — same phase rules

Both forms are accepted by `ProfileCaptureSchema._scenarioInstantPhases`.
Which form you land with depends on the DevTools export path: the
Chrome-native JSON exporter emits `ph:"i"`; Perfetto pipelines
(`.pftrace` → `traceconv` → JSON) emit `ph:"n"`. Either is fine.

Without these markers, a capture containing a 50 s cold-start prelude
plus a 3 s request would appear to span 50 s, failing the 100×
trace-vs-observed ratio invariant. The markers delimit the scenario
window so `observed` refers to the span *you claim it refers to*.

Emit them from Dart with `developer.Timeline.instantSync('sleuth.scenario.begin')`
/ `developer.Timeline.instantSync('sleuth.scenario.end')`. The
`NetworkMonitor Capture Helper` screen under `example/lib/demos/` is
a ready-made subject for the planned v0.16.5 `externallyCited` raise on
the `slow_request` WARNING tier (1000 ms) — three preset delay knobs
(800 / 1020 / 1500 ms) already emit the markers and hit a loopback
server for deterministic bracket magnitudes. The `above` preset is
deliberately inside `[1000, 2000)` so the artifact cannot ambiently
bracket the 3000 ms critical tier; a critical-tier protocol is reserved
for a future raise.

## Recording a capture (pinned device)

1. `fvm flutter --version` must print the pinned stable release
   (`ProfileCaptureSchema.approvedFlutterMajorMinor`, currently `3.41.x`).
   If it doesn't, switch with `fvm use <version>` before recording.
2. Plug in a device from `ProfileCaptureSchema.approvedDevicePairs`
   (iPhone 12 / iPhone 12 / iPhone 12 as of v0.16.4). Confirm the
   OS version matches the approved set for that device — pair-matched
   policy rejects mismatches.
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
    "device":          "iPhone 12",                    // required — pinned
    "deviceOsVersion": "iOS 17.5",                        // required — pinned
    "flutterVersion":  "3.41.4",                            // required — pinned major.minor
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
- `flutterVersion` must match `^3\.41\.\d+(?:[-+][0-9A-Za-z.\-]+)?$`
  (mirrors `ProfileCaptureSchema._flutterVersionPattern`) until the
  next annual rotation. Pre-release (`-1.0.pre`) and build-metadata
  (`+channel-stable`) suffixes are accepted; major.minor is strict.
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
