# Contributing to Sleuth

Thanks for your interest. A few rules make the contribution loop fast:

## Development loop

- Use `fvm` for every Flutter / Dart command. The repo pins Flutter
  stable via `.fvm/`; running `dart test` against a mismatched system
  SDK produces analyzer churn.
- `fvm flutter analyze` must report zero issues before you open a PR.
- `fvm flutter test` must pass. The suite runs in ~25 s on a M-series
  Mac.
- The example app lives in `example/`; it's used for manual smoke
  testing. `cd example && fvm flutter run --profile` is the canonical
  local dev command.

## Adding a new detector

See `example/lib/demos/writing_custom_detectors/README.md` for the
three-file cookbook. New detectors must:

1. Extend `BaseDetector` (or the helper `SimpleStructuralDetector`) and
   implement the four scan-loop stages (`prepareScan`, `checkElement`,
   `afterElement`, `finalizeScan`).
2. Register their `DetectorType` in the enum and wire the detector into
   `SleuthController`.
3. Mix in `DetectorMetadataProvider` and return a
   `const DetectorMetadata(...)` at the appropriate `EvidenceTier`. New
   detectors start at `EvidenceTier.unvalidated` — that's the lazy
   starting line, not a claim.

## Raising a detector's EvidenceTier

The v0.16 validation arc raises one detector at a time. Every tier
raise ships with supporting artefacts that the audit gate enforces:

| Tier | Required artefacts |
|---|---|
| `reproducerOnly` | Hermetic test at `reproducerPath` referencing the detector's runtimeType by name, plus a `coveredStableIds` set naming the issue families the test exercises. |
| `runtimeVerified` | Everything in `reproducerOnly`, plus a non-empty `profileCapturePaths` list — three captures bracketing the threshold (below / at / above) per `test/validation/captures/README.md`. |
| `externallyCited` | Everything in `runtimeVerified`, plus a `citationUrl` pointing at the framework source, published benchmark, or dart-lang issue the threshold traces back to. |

The audit gate (`test/validation/detector_metadata_audit_test.dart`)
runs every capture through `ProfileCaptureSchema.parseFile` — malformed
captures fail the gate, not production runtime.

**Reference device policy**: captures must be recorded on a pinned
device / OS / Flutter stable combination. The current matrix and
rotation policy are documented in `doc/reference_devices.md`. Rotations
happen once per calendar year in a dedicated release — do not widen the
matrix inside an individual tier-raise PR.

## Raising a non-detector component's tier

Components that make per-test reliability claims without being detectors
(e.g. `IssueRanker`, `CausalGraphRule`, const registries like
`_frameworkWidgetDenyList`) use the parallel
`ComponentMetadata` framework. Same five invariants enforced by
`test/validation/component_metadata_audit_test.dart`; the only
differences are:

- Metadata is published via
  `ValidatedComponentRegistry.instance.register(metadata)` from a
  `static void registerMetadata()` entry point the component exposes.
- The audit test's `_expectedRegisteredComponents` list names every
  component whose `registerMetadata()` it dispatches. Registering
  without updating that list (or vice versa) fails the test.

## Pull request checklist

- `fvm flutter analyze` is clean.
- `fvm flutter test` is green.
- If you touched detector metadata, the audit gate still passes (run
  the specific test file to verify locally before pushing).
- If you added a capture, its `sleuthMetadata` wrapper is complete and
  its row is appended to `test/validation/captures/_fixtures/README.md`
  (for fixtures) or the scenario-specific capture directory README.
- CHANGELOG.md carries a one-line entry under the current milestone.
- Commit messages follow the repo's conventional-ish style visible in
  `git log` — feat / fix / docs / chore prefixes.

## What we don't ship

- Mocked detectors that bypass real-widget behaviour. Integration tests
  hit real `Element` trees or real `HttpServer`s; unit tests exercise
  the detector's public surface, not a shadow implementation.
- Tier raises without committed reproducers. Prose commitments to
  "validate later" rot silently; the audit gate exists to make the
  commitment mechanical.
- Hand-written fixtures that mirror a parser's own assumptions for
  that parser's unit tests. See `test/validation/captures/_fixtures/`
  and the anchor-fixture pattern for the tautology-prevention policy.
