# Capture fixtures — provenance ledger

Test fixtures consumed by `test/validation/profile_capture_schema_test.dart`
and `test/validation/profile_capture_schema_anchor_test.dart`. Keep this
file honest — any schema change that silently rejects real DevTools
exports will first break `anchor_devtools_export.json`, so the anchor is
the last line of defence against fixture-vs-reality drift.

| Fixture | Origin | Annotation date | Captured by | Purpose |
|---|---|---|---|---|
| `anchor_devtools_export.json` | Shape-faithful synthetic mirroring a DevTools Performance "Export timeline" output. `traceEvents` follow the Chrome Trace Event Format (`B`/`E`/`X`/`b`/`e`/`i` phases per `dart:developer` source of truth). Replaced with a real device capture at the first v0.16.4 `runtimeVerified` tier raise. | 2026-04-18 | harryslala | Grounds `ProfileCaptureSchema.parse()` against a realistic export shape; any regression that silently rejects real exports will first break this file |
| `missing_device.json` | Synthetic | 2026-04-18 | harryslala | Negative — asserts `parse()` rejects a capture that omits `sleuthMetadata.device` |
| `bad_iso_date.json` | Synthetic | 2026-04-18 | harryslala | Negative — asserts `parse()` rejects non-ISO-8601 `captureDate` strings |
| `min_gt_observed.json` | Synthetic | 2026-04-18 | harryslala | Negative — asserts `parse()` rejects `expectedMagnitude` where `min > observed` |
| `dormant_bracket_below.json` | Synthetic | 2026-04-18 | harryslala | Dormant-gate — `observed=900` ms below a synthetic 1000 ms threshold; exercises `validateBracket` below leg until v0.16.4 ships a real bracket |
| `dormant_bracket_at.json` | Synthetic | 2026-04-18 | harryslala | Dormant-gate — `observed=1050` ms inside the `[1000, 1100]` at-band; exercises `validateBracket` at leg |
| `dormant_bracket_above.json` | Synthetic | 2026-04-18 | harryslala | Dormant-gate — `observed=1200` ms above the synthetic 1000 ms threshold; exercises `validateBracket` above leg |

## Adding a new fixture

Append a row to the table above before landing the fixture. Rows missing
provenance fail review. Valid fixtures (happy-path or anchor) must name
the capture command used so the fixture is reproducible.

## Replacing the anchor with a real export

When the first v0.16.4 `runtimeVerified` capture lands, replace the
anchor in-place with a real DevTools export from the pinned iPhone 13
mini (iOS 17.5) and update this file's row with the actual capture
date and the detector scenario it was recorded for. Keep the anchor's
`sleuthMetadata` wrapper shape intact — only the `traceEvents`, the
`scenario`, and the `expectedMagnitude.observed` should change.

## Why an anchor at all

Hand-written fixtures that mirror a validator's assumptions are a
confirmation-bias machine: the test passes because the fixture author
encoded the validator's expectation, not because the validator handles
real-world input. A single committed export from the real producer (or
a shape-faithful approximation locked against schema drift) proves the
schema accepts real-world input, not just inputs the schema author
designed around.
