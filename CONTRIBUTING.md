# Contributing to Sleuth

Thanks for your interest. The rules below keep the contribution loop fast.

## Development loop

- Use `fvm` for every Flutter and Dart command. `.fvmrc` pins Flutter
  3.47.6; running `dart test` against a different system SDK produces
  analyzer churn.
- `fvm flutter analyze` must report zero issues before you open a PR.
- `fvm flutter test --exclude-tags benchmark` must pass. The default run
  has about 4,270 tests and takes about 1.5 minutes on an M1 Pro. Run the
  wall-clock benchmarks serially with
  `fvm flutter test --tags benchmark --concurrency=1`.
- CI also checks formatting with `dart format --output=none
  --set-exit-if-changed` (see `.github/workflows/flutter-ci.yml` for the
  directories), and it runs analyze and tests on the Flutter 3.32.8
  floor as well as on 3.47.6.
- The example app in `example/` is for manual smoke testing.
  `cd example && fvm flutter run --profile` is the usual local dev
  command, and `cd example && fvm flutter test` runs its tests.

## Adding a new detector

See `example/lib/custom_detectors/README.md` for the three-file
cookbook. New detectors must:

1. Extend `BaseDetector` (or the helper `SimpleStructuralDetector`) and
   implement the four scan-loop stages (`prepareScan`, `checkElement`,
   `afterElement`, `finalizeScan`).
2. Add their `DetectorType` value to the enum and register the detector
   in `SleuthController`.
3. Mix in `DetectorMetadataProvider` and return a
   `const DetectorMetadata(...)` at the right `EvidenceTier`. New
   detectors start at `EvidenceTier.unvalidated`. That tier is the
   starting point, not a claim.

## Raising a detector's EvidenceTier

Raise one detector, or one stableId family, per change. Every tier raise
ships with supporting artefacts that the audit gate enforces:

| Tier | Required artefacts |
|---|---|
| `reproducerOnly` | A hermetic test at `reproducerPath` that names the detector's runtimeType, plus a `coveredStableIds` set (or `parametricFamilies` for ids such as `repaint_debug_<typeName>`) naming the issue families the test exercises. |
| `runtimeVerified` | Everything in `reproducerOnly`, plus a non-empty `profileCapturePaths` list: three captures that bracket the threshold (below, at and above) as described in `test/validation/captures/README.md`. |
| `externallyCited` | Everything in `runtimeVerified`, plus a `citationUrl` that points at the framework source, published benchmark or dart-lang issue the threshold comes from. |

The audit gate (`test/validation/detector_metadata_audit_test.dart`)
runs every capture through `ProfileCaptureSchema.parseFile`, so a
malformed capture fails the gate instead of reaching production.

**Reference device policy.** Record captures on a pinned device, OS
and Flutter stable combination. `doc/reference_devices.md`
documents the current matrix and the rotation policy. The matrix
rotates once per calendar year in a dedicated release, so do not widen
it inside a tier-raise PR.

## Raising a non-detector component's tier

A component that makes a per-test reliability claim without being a
detector (for example `IssueRanker`, `CausalGraphRule`, or a const
registry such as `_frameworkWidgetDenyList`) registers through the
parallel `ComponentMetadata` framework.
`test/validation/component_metadata_audit_test.dart` enforces the same
five invariants. No component is registered yet, so the audit test's
list is empty and the gate runs against synthetic metadata. The
differences from detectors are:

- A component publishes its metadata with
  `ValidatedComponentRegistry.instance.register(metadata)` from a
  `static void registerMetadata()` entry point.
- The audit test's `_expectedRegisteredComponents` list names every
  component whose `registerMetadata()` it calls. Registering a
  component without adding it to that list (or the reverse) fails the
  test.

## Pull request checklist

- `fvm flutter analyze` is clean.
- `fvm flutter test --exclude-tags benchmark` passes.
- If you touched detector metadata, the audit gate still passes. Run
  that test file locally before you push.
- If you added a device capture, it follows the checklist in
  `test/validation/captures/README.md`: the file lives under
  `test/validation/captures/<detector>/` and its `sleuthMetadata`
  wrapper is complete. If you added a parser fixture, its row is
  appended to `test/validation/captures/_fixtures/README.md`.
- `CHANGELOG.md` has an entry under `## Unreleased`.
- Commit messages follow the style in `git log`: a `feat`, `fix`,
  `docs`, `chore` or `example` prefix, with an optional scope such as
  `fix(debug):`.

## What we don't ship

- Mocked detectors that bypass real widget behaviour. Integration tests
  use real `Element` trees or real `HttpServer`s, and unit tests
  exercise the detector's public API, not a copy of its logic.
- Tier raises without committed reproducers. A written promise to
  "validate later" is easy to forget, so the audit gate checks for the
  evidence instead.
- Hand-written fixtures that mirror a parser's own assumptions in that
  parser's unit tests. See `test/validation/captures/_fixtures/` and
  its anchor fixture for the policy that keeps such tests from passing
  by construction.
