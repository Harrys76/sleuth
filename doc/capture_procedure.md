# Capture procedure (v0.18.0+)

> **In-app export: NetworkMonitor slow_request**
>
> `NetworkMonitor.slow_request` was the first `runtimeVerified` raise
> (v0.18.0, warning tier, threshold 1000 ms). Its capture screen, like
> every tap-driven capture screen in the example app, exports each leg
> from inside the app, so the procedure needs no DevTools step.
>
> Sleuth's own `VmServiceClient` must be connected (VM+ mode). By
> default `flutter run` starts DDS, which takes the VM service as its
> only client and leaves Sleuth in FRAME mode. Launch with `--no-dds`,
> or quit `flutter run` and reopen the app from the home screen:
>
> 1. `cd example && fvm flutter run --profile --no-dds -d "iPhone 12" \
>      --dart-define=SLEUTH_CAPTURE_MODE=true \
>      --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"`. This installs
>    and starts the app. The status row shows VM+ once Sleuth connects.
> 2. If you launched without `--no-dds`, quit `flutter run` (`q`). DDS
>    stops with it.
> 3. In that case, reopen the app from the iPhone home screen. No DDS
>    attaches, so Sleuth's `VmServiceClient` connects (VM+ mode), and
>    the real `NetworkMonitorDetector` observes HTTP completions and
>    emits `sleuth.issue.slow_request.warning` through the
>    `_recordIssuesForCapture` pipeline.
> 4. In the app, open Capture Helpers, then NetworkMonitor. Tap a leg:
>    Below 800 ms, At 1020 ms or Above 1500 ms for the warning tier
>    (2700, 3600 and 5000 ms for the critical tier). Wait for the
>    `scenario.end` log line (the snackbar says "Tap Export now"), then
>    tap **Export last leg**. The screen calls
>    `Sleuth.exportCaptureJson(...)`, which fetches the VM trace buffer,
>    keeps the matching scenario span and wraps it with `sleuthMetadata`
>    and the build's provenance. The screen then copies the JSON to the
>    iOS clipboard.
> 5. Paste the clipboard into Notes, Mail or an AirDrop note and send it
>    to the Mac. The clipboard holds one capture, so copy and paste one
>    leg at a time.
> 6. Save each pasted JSON as `slow_request_<leg>.json` (critical tier:
>    `slow_request_critical_<leg>.json`) under
>    `test/validation/captures/network_monitor/`.
> 7. The exported JSON already conforms to the schema. Do not pass it
>    to `tool/wrap_capture.dart`, which refuses input that already
>    carries a `sleuthMetadata` block.
>
> A capture recorded in FRAME mode cannot back `runtimeVerified`. The
> detector pipeline does not run, the capture has no detector trace
> record, and the schema audit rejects it with "Missing detector trace
> record."
>
> ---
>
> ### vmOnly detectors (HeavyCompute, ShaderJank, MemoryPressure, GpuPressure VM leg, PlatformChannel)
>
> `Sleuth.flushTimelineNow()` (v0.18.1) forces a VM poll and records
> pending detector emissions before it returns. NetworkMonitor did not
> need it, because it is a runtime detector and its screen waits 200 ms
> before it closes the span. Use this pattern for any vmOnly detector
> raise from v0.18.2 on:
>
> ```dart
> Sleuth.markScenarioBegin('heavy_compute_above');
> await runHeavyWorkload();
> await Sleuth.flushTimelineNow(); // forces VM poll + emit before next line
> Sleuth.markScenarioEnd('heavy_compute_above');
> ```
>
> Without `await Sleuth.flushTimelineNow()`, the detector writes its
> trace record on the next VM poll (every 500 ms), usually hundreds of
> milliseconds after `scenario.end`. The schema audit then rejects the
> capture with "Missing detector trace record."
>
> **One flush is not always enough.** A detector that needs evidence
> from several polls (for example, N consecutive BUILD events over the
> threshold) may need several `flushTimelineNow` calls during the
> workload, or a longer scenario span. Check the captured trace before
> you claim `runtimeVerified`. The `ts` of the
> `sleuth.issue.<id>.<severity>` event must fall strictly inside
> `[scenario.begin, scenario.end]`. If it keeps landing after
> `scenario.end` despite the flush, the detector emits from something
> other than a single VM poll callback (frame stats, a microtask, an
> evaluation over several polls). Find the part of the workload that
> triggers the emission and adjust the procedure.
>
> **The `flushTimelineNow` timeout does not cancel the poll.** The
> `{Duration? timeout}` parameter wraps the await in `Future.timeout`,
> but the VM round trip keeps running. On a `TimeoutException` the
> work continues, so read the exception as "capture failed, wait for
> steady state, then retry", not as "abort and retry at once."
>
> HeavyCompute on iPhone has one more catch. Per-scenario CPU and
> thermal variance can reach 25 to 60 %, which defeats narrow at and
> above bands even with `atTolerance: 0.50`. The detector author may
> need a wider at band or a workload with deterministic timing.
> NetworkMonitor's loopback HTTP latency is the cleanest reference. The
> checked-in slow_request legs landed 3 to 74 ms above their delay
> targets.
>
> **Stamp `detectedAt` at first detection.** The producer-side dedup
> key uses the issue's `dedupIdentityMicros` when it is set, else
> `detectedAt.microsecondsSinceEpoch`, else `0`. A detector that emits
> several distinct issues per scenario with neither field set collapses
> them into one emission, which breaks the runtimeVerified evidence.
> Before you raise the tier, check in the detector's reproducer test
> that every emitted `PerformanceIssue` carries a non-null `detectedAt`.
>
> **The BUILD duration on the wire is not the Stopwatch ms.** For
> HeavyCompute, and for any future detector that reads BUILD durations,
> the framework's BUILD timeline event covers the whole build callback:
> the workload, the `setState` bookkeeping and the child rebuilds. A
> Stopwatch around the inner workload measures less. On iPhone 12 /
> iOS 17.5 the gap is small enough that both values stay on the same
> severity tier (above-leg target 12.5 ms, BUILD about 13 to 14 ms,
> under the 16 ms critical threshold). On a slower device the BUILD
> duration can pass the 16 ms critical threshold, and the detector then
> emits `.critical` instead of `.warning`, which fails an audit that
> looks for `.warning`. If the above leg fails with "Missing detector
> trace record" on another device, lower the workload target until the
> BUILD duration stays under the critical threshold.

This file describes how to produce a `runtimeVerified` capture triad
that `ProfileCaptureSchema.validateBracket(... requireDetectorTraceRecord:
true)` accepts. Every detector raise follows the same shape.

To rotate the device, OS or Flutter pins, see
`doc/reference_devices.md` and skip to the schema reference at the
bottom of this file.

## VM-service requirement (read first)

`runtimeVerified` evidence is the trace record that the real detector
pipeline writes, not a proxy that a screen synthesises. The pipeline
runs only while `SleuthController`'s `VmServiceClient` is connected
(VM+ mode, not FRAME mode). Without that connection the `vmOnly` and
`hybrid` detectors never see their inputs, and
`Sleuth.exportCaptureJson` cannot read the trace buffer at all. It
returns null with "VM service client disconnected". A capture made any
other way lacks the detector trace record, and the schema audit
rejects it with "Missing detector trace record", which is the correct
result.

`VmServiceClient` connects from inside the app to the app's own VM
service. Two launch setups allow that:

- **`flutter run --profile --no-dds`.** Without `--no-dds`,
  `flutter run` starts DDS (Dart Development Service), which takes the
  VM service as its only client. Sleuth then stays in FRAME mode for
  the whole session.
- **An app started without the flutter tool.** Quit `flutter run` and
  reopen the app from the home screen. No DDS attaches, so Sleuth
  connects.

The iOS Simulator and Android builds follow the same rule. Simulator
performance differs from iPhone hardware, so a simulator capture is no
substitute for device evidence; use one only to test the procedure.
Android has no approved reference device yet (see
`doc/reference_devices.md`), so Android captures cannot back a tier
raise.

A FRAME-mode capture cannot back `runtimeVerified`. Earlier versions of
this procedure had a `Sleuth.markCaptureIssue` fallback that
synthesised the trace record from a Stopwatch around the workload,
copying the detector's threshold ladder. The project removed it
because nobody could tell its evidence apart from forgery, and because
it certified logic copied into the screen instead of the detector's
behaviour.

## What changes from v0.16.x captures

v0.18.0 added three contract requirements to the v0.16.4 schema:

1. **Schema version field.** `sleuthMetadata.schemaVersion = "v1"` must
   be present. The parser accepts a capture without it while
   `requireDetectorTraceRecord` is false (the default), but every
   detector audit at `runtimeVerified` or stronger rejects it.
2. **Scenario markers through the public API.** Use
   `Sleuth.markScenarioBegin(name)` / `Sleuth.markScenarioEnd(name)`
   instead of a raw `Timeline.instantSync('sleuth.scenario.begin')`.
   The public API does nothing in release builds, before Sleuth has a
   controller, or while the `captureMode` flag is off, so it is safe to
   leave in app code.
3. **Detector trace record inside the scenario span.** The at and above
   captures must contain a `sleuth.issue.<stableId>.<severity>` instant
   event whose `ts` lies inside the scenario window. `SleuthController`
   writes it through `CaptureHelper.recordIssue(...)` when
   `captureMode: true` is set and the detector fires during the
   scenario. The below capture must not contain one (the sub-threshold
   guard).

v0.19.0 added a fourth: `sleuthMetadata.role` is required and must be
`below`, `at` or `above`.

Both `Sleuth.exportCaptureJson` and the `tool/wrap_capture.dart` CLI
set `schemaVersion: "v1"` and `role`, so requirements 1 and 4 cost
nothing. Requirements 2 and 3 need the app to run with `captureMode`
on; see step 1 below.

## 0. Prerequisites

Confirm that the host matches the pinned matrix:

```
fvm flutter --version    # major.minor must be in approvedFlutterMajorMinors (3.41.x or 3.47.x)
```

If it does not, run `fvm use <pinned-version>` before recording. The
parser rejects a mismatch, so a capture from the wrong Flutter fails
`ProfileCaptureSchema.parseFile` with a precise error message before
any audit runs. The example's capture screens check the same lists
first. They refuse to export while the build's device, OS or Flutter
version is unknown or not approved, and the time-share and FrameTiming
screens refuse to start a leg.

Use a device from `ProfileCaptureSchema.approvedDevicePairs` (today
only iPhone 12 / iOS 17.5; see `doc/reference_devices.md` for the
matrix policy and the Android coverage gap). The device and OS must
match as a pair. Membership in each set on its own is not enough.

## 1. Launch in profile mode with capture mode

```
cd example
fvm flutter run --profile --no-dds -d "iPhone 12" \
  --dart-define=SLEUTH_CAPTURE_MODE=true \
  --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"
```

The example app reads `bool.fromEnvironment('SLEUTH_CAPTURE_MODE')` in
`main.dart` and passes it to `SleuthConfig(captureMode: ...)`. With the
flag off, `Sleuth.markScenarioBegin/End` and `CaptureHelper.recordIssue`
do nothing, the capture lacks both the scenario span and the detector
trace record, and `validateBracket` rejects it with a precise error.
`SLEUTH_CAPTURE_DEVICE` names the phone model that exports stamp as
`device` (see Provenance in the time-share section). `--no-dds` keeps
Sleuth in VM+ mode, as the VM-service requirement above explains. If
`flutter run` cannot start the app on the phone, use the build,
install and attach sequence under Launch in the time-share section.

To capture from your own app instead of the example, pass the flag
through your own `SleuthConfig` the same way:

```dart
const captureMode = bool.fromEnvironment('SLEUTH_CAPTURE_MODE');
runApp(Sleuth.track(
  child: const MyApp(),
  config: SleuthConfig(
    captureMode: captureMode,
    // Deep debug instrumentation flips
    // `debugProfileBuildsEnabledUserWidgets`, which records a timeline
    // event for every user-widget build inside the BUILD scopes. That
    // inflates the build-time share rebuild_activity measures and the
    // BUILD durations HeavyCompute reads, and it multiplies the
    // timeline volume a capture exports, so capture mode turns it off.
    enableDebugCallbacks: !captureMode,
    enableDeepDebugInstrumentation: !captureMode,
    /* ... */
  ),
));
```

## 2. Open DevTools, clear the timeline

The example's capture screens export each leg in the app through
`Sleuth.exportCaptureJson`, which keeps only the scenario span, wraps
it and stamps the provenance. With those screens, skip steps 2, 4 and
5. They apply when you record the trace in DevTools yourself.

Open DevTools on the app's VM service and switch to the Performance
tab. Let the app reach steady state (open your capture screen and let
the first-frame jank pass), then click the trash icon to clear the
timeline buffer.

Do not skip the clear. Cold-start work writes thousands of trace
events. A capture saved without clearing runs to about 50 s, hides the
scenario in noise, and can carry scenario markers from earlier legs.
The trace-versus-observed cross-check needs exactly one
`sleuth.scenario.begin` and one `sleuth.scenario.end`.

## 3. Run each leg

For each of the three legs (`below`, `at`, `above`), tap the matching
button on the capture screen. On the HeavyCompute screen a leg:

- calls `Sleuth.markScenarioBegin('<scenario>')` inside `build()`
  (`heavy_compute_<leg>` for the warning tier,
  `heavy_compute_critical_<leg>` for the critical tier);
- runs the sin/cos workload synchronously in the same `build()`, so it
  lands inside one BUILD event that HeavyCompute observes;
- after the frame, awaits `Sleuth.flushTimelineNow()`, waits 200 ms and
  calls `Sleuth.markScenarioEnd('<scenario>')`;
- logs `✓ IN-BAND` or `✗ OUT-OF-BAND` with the measured ms, then waits
  1.5 s, so the VM timeline takes in the trailing scenario marker and
  the issue trace record, before it logs "ready to Export".

Export a leg before you tap the next one, because a new tap clears the
last completed leg.

Targets on the HeavyCompute screen, warning tier (threshold 8 ms):

- Below: target 3 ms, band [0, 7.9] ms. The detector stays silent.
- At: target 10 ms, band [8, 12] ms.
- Above: target 12.5 ms, band [12.1, 15] ms, clear of the 16 ms
  critical threshold.

The critical tier (threshold 16 ms) targets 12 ms for below (band
[8, 15.5] ms, where the warning fires and the critical does not), 20 ms
for at (band [16, 25.6] ms) and 27 ms for above (band [25.7, 30] ms).

The warning at band is `[8, 12]` (`atTolerance` 0.50), not the schema
default `[8, 8.8]` (`atTolerance` 0.10). Runs on iPhone 12 cannot
reach the default band. Thermal, JIT and scheduler noise moves each
scenario by 25 to 30 %, so a 10 % band fails on every leg. The
`HeavyComputeDetector` metadata declares `bracketAtTolerance: 0.50` and
`aboveCeilingMultiplier: 1.875` so the audit gate matches the device;
its critical bracket declares `atTolerance: 0.60` with the same
multiplier. If you change the ms targets, update the metadata in the
same change. CI enforces `bracketAtTolerance` and
`aboveCeilingMultiplier`.

The screen calibrates its iterations-per-ms rate when it opens, with a
500,000-iteration warmup; **Recalibrate** runs the warmup again. Each
tap runs one workload, and the screen then updates the rate from the
measured ms so the next tap lands closer to its target. Expect two or
three taps per leg on a cold device. Watch the screen log for
`✓ IN-BAND` on each leg. The Export button exports only an in-band leg,
because the schema would reject an out-of-band one at audit time.

## 4. Save the raw timeline

In DevTools, choose Save timeline JSON on the Performance tab (or Save
snapshot on recent DevTools; see the conversion note below). Save to a
workspace directory, not `test/validation/captures/`, which holds
wrapped captures only:

```
~/Desktop/sleuth_captures/heavy_compute_below.raw.json
~/Desktop/sleuth_captures/heavy_compute_at.raw.json
~/Desktop/sleuth_captures/heavy_compute_above.raw.json
```

The `.raw.json` suffix keeps raw exports apart from wrapped captures.
The schema does not enforce it.

### DevTools snapshot vs Chrome Trace JSON

Recent DevTools versions export a snapshot, which is a JSON file with
the top-level keys `devToolsSnapshot` and `performance.traceBinary` (a
Perfetto protobuf stored as a list of bytes). The schema requires
Chrome Trace Event Format, with `traceEvents` at the top level.
Convert with Perfetto's `traceconv`:

```bash
# One-time: download traceconv (Python wrapper that fetches the
# native binary on first run).
mkdir -p .local-tools && cd .local-tools
curl -sL -o traceconv https://get.perfetto.dev/traceconv
chmod +x traceconv

# Per capture: extract performance.traceBinary, convert to Chrome JSON.
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
open(sys.argv[2], 'wb').write(bytes(d['performance']['traceBinary']))
" snapshot.json /tmp/leg.pb

./traceconv json /tmp/leg.pb leg.raw.json
```

The resulting `leg.raw.json` has `traceEvents` at the top level and is
ready for `tool/wrap_capture.dart`. If your DevTools build still offers
a Save timeline JSON option that writes Chrome Trace Event Format
directly, use it and skip the conversion.

## 5. Wrap each raw export with `tool/wrap_capture.dart`

Do not edit the JSON by hand. Use the CLI:

```
fvm dart tool/wrap_capture.dart \
  --input  ~/Desktop/sleuth_captures/heavy_compute_below.raw.json \
  --output test/validation/captures/heavy_compute/heavy_compute_below.json \
  --scenario "HeavyCompute below 8 ms warning threshold (iPhone 12)" \
  --magnitude-min      5 \
  --magnitude-observed 6 \
  --magnitude-max      7 \
  --unit ms \
  --device "iPhone 12" \
  --device-os "iOS 17.5" \
  --flutter-version 3.47.6
```

Repeat for `_at` and `_above`. Pass the measured ms that the capture
screen reports as `--magnitude-observed`, not the target, because your
device may run a few percent fast or slow. Set `min` and `max` 1 ms
either side of the observed value, or to the band you reproduce on
back-to-back captures. The tool takes `role` from the output file's
`_below.json`, `_at.json` or `_above.json` suffix; for any other file
name, pass `--role below|at|above`.

The tool refuses to:

- write `--output` to the same path as `--input`, which would destroy
  the raw export;
- overwrite an existing wrapped capture without `--force`;
- wrap a capture that already contains `sleuthMetadata`, which would
  wrap it twice;
- wrap when `--magnitude-observed` differs by more than 10 % from the
  BUILD duration recorded inside the scenario span. This is the BUILD
  cross-check. Detectors classify on the BUILD duration, not on a
  Stopwatch around the inner loop, so the wrapped capture's
  `expectedMagnitude.observed` must match the value the detector sees.
  The error message reports the BUILD ms; pass that value as
  `--magnitude-observed` and derive `min` and `max` from it. `--force`
  overrides the check, but avoid it. A forced mismatch gives a capture
  whose trace record severity may not match what
  `validateBracket(... severityLabel: ...)` accepts at that magnitude;
- wrap when the BUILD duration and `--magnitude-observed` fall on
  opposite sides of a `--severity-boundary` you pass (for HeavyCompute,
  `--severity-boundary 8 --severity-boundary 16`). `--force` overrides
  this check too.

Each refusal exits with code 2 and a precise message on stderr.

## 6. Update the detector's `DetectorMetadata`

For HeavyCompute, `lib/src/detectors/heavy_compute_detector.dart`
declares:

```dart
DetectorMetadata get validationMetadata => const DetectorMetadata(
      tier: EvidenceTier.runtimeVerified,
      rationale: '...',
      reproducerPath: 'test/validation/heavy_compute_reproducer_test.dart',
      profileCapturePaths: [
        'test/validation/captures/heavy_compute/heavy_compute_below.json',
        'test/validation/captures/heavy_compute/heavy_compute_at.json',
        'test/validation/captures/heavy_compute/heavy_compute_above.json',
      ],
      bracketThreshold: 8,
      bracketUnit: 'ms',
      bracketStableId: 'heavy_compute',
      bracketSeverityLabel: 'warning',
      bracketAtTolerance: 0.50,
      // 1.875 keeps the above-ceiling at 15 ms so the artifact stays
      // 1 ms clear of the 16 ms critical-tier boundary.
      aboveCeilingMultiplier: 1.875,
      coveredStableIds: {'heavy_compute'},
      coveredThresholds: {'heavy_compute.warning', 'heavy_compute.critical'},
      bracketRequireUniqueDetectedAtMicros: true,
      observedAxisArgKey: 'observedDurationMs',
      // The critical bracket (threshold 16 ms, atTolerance 0.60,
      // aboveCeilingMultiplier 1.875) is additionalBrackets[0].
      additionalBrackets: [/* BracketSpec(...) */],
    );
```

`bracketStableId` and `bracketSeverityLabel` have been required at
`runtimeVerified` since v0.18.0. Without them the audit fails with a
precise error before it reaches `validateBracket`.

### Multi-axis raises (v0.19.8+)

When a detector needs more than one bracket (another family, another
severity of the same family, or another observed axis), declare the
canonical bracket through the top-level fields and the others through
`additionalBrackets: [BracketSpec(...), ...]`. `BracketSpec` is
exported from the public barrel; import it with `DetectorMetadata` and
`EvidenceTier`. NetworkMonitor declares three additional brackets
(`large_response`, `request_frequency` and the `slow_request` critical
tier):

```dart
import 'package:sleuth/sleuth.dart';

DetectorMetadata get validationMetadata => const DetectorMetadata(
      tier: EvidenceTier.reproducerOnly,
      rationale: '...',
      reproducerPath: 'test/validation/network_monitor_reproducer_test.dart',
      // Canonical bracket: slow_request warning, duration axis.
      profileCapturePaths: [
        'test/validation/captures/network_monitor/slow_request_below.json',
        'test/validation/captures/network_monitor/slow_request_at.json',
        'test/validation/captures/network_monitor/slow_request_above.json',
      ],
      bracketThreshold: 1000,
      bracketUnit: 'ms',
      bracketStableId: 'slow_request',
      bracketSeverityLabel: 'warning',
      aboveCeilingMultiplier: 2.0,
      coveredStableIds: {
        'slow_request',
        'large_response',
        'request_frequency',
        'http_error_spike',
        'high_frequency_same_path',
      },
      perStableIdTier: {
        'slow_request': EvidenceTier.runtimeVerified,
        'large_response': EvidenceTier.runtimeVerified,
        'request_frequency': EvidenceTier.runtimeVerified,
      },
      coveredThresholds: {'slow_request.warning', 'slow_request.critical'},
      bracketRequireUniqueDetectedAtMicros: true,
      observedAxisArgKey: 'observedDurationMs',
      observedAxisTolerance: 0.10,
      additionalBrackets: [
        // Second family, bytes axis.
        BracketSpec(
          stableId: 'large_response',
          severityLabel: 'warning',
          threshold: 1048576,
          unit: 'bytes',
          coveredThresholds: {'large_response.warning'},
          profileCapturePaths: [
            'test/validation/captures/network_monitor/large_response_below.json',
            'test/validation/captures/network_monitor/large_response_at.json',
            'test/validation/captures/network_monitor/large_response_above.json',
          ],
          atTolerance: 0.10,
          aboveCeilingMultiplier: 2.0,
          observedAxisArgKey: 'observedResponseBytes',
          requireUniqueDetectedAtMicros: true,
          requireDetectorTraceRecord: true,
        ),
        // request_frequency (events axis) and the slow_request critical
        // tier (threshold 3000 ms) follow the same shape.
      ],
    );
```

The audit enforces:

- Uniqueness across specs on `(stableId, severityLabel,
  observedAxisArgKey)`, counting the top-level bracket as spec 0. Two
  specs with the same stable id and severity must use different arg
  keys; with the same key they would count the same trace event twice.
  The audit accepts the same stable id and arg key at different
  severities, because the specs read different trace events
  (`.warning` and `.critical`). That is the tier-stack shape
  HeavyCompute and NetworkMonitor use.
- The audit rejects an empty `additionalBrackets: []`. Write "no
  additional brackets" as `null`, or leave the field out.
- Each spec's `profileCapturePaths` must hold exactly 3 entries
  (below, at, above); `validateBracketSpec` checks each spec on its
  own.
- Each `coveredThresholds` entry of a spec must name that spec's own
  stable id and severity, and a spec with severity-scoped
  `coveredThresholds` must set `aboveCeilingMultiplier` explicitly.
- Every family that `perStableIdTier` raises to `runtimeVerified` needs
  a `coveredThresholds` entry of the form `<family>.<severity>`, either
  in the canonical `coveredThresholds` or in a
  `BracketSpec.coveredThresholds`. A matching `stableId` alone does not
  count.

## 7. Run the audit

```
fvm flutter test test/validation/detector_metadata_audit_test.dart
fvm flutter test --exclude-tags benchmark
```

The detector audit calls `checkBracketValidation(... requireTraceRecord:
true, bracketStableId: ..., bracketSeverityLabel: ...)`, which goes
through `ProfileCaptureSchema.validateBracket(...
requireDetectorTraceRecord: true)`. Failure messages name the failing
file and the contract it broke.

Common failures:

| Error message | Meaning |
|---|---|
| `Capture missing or stale 'sleuthMetadata.schemaVersion'` | A hand edit that left the field out, or a v0.16.x version of `wrap_capture.dart`, wrapped the triad. Wrap it again. |
| `Missing detector trace record in at capture` | The detector did not fire during the captured scenario. Check that `--dart-define=SLEUTH_CAPTURE_MODE=true` was set, that the at leg passed the threshold (HeavyCompute fires only above it, not at it), and that the scenario span was long enough to include the issue emission. |
| `Unexpected detector trace record in below capture` | The below leg measured above the threshold. Record it again with a smaller target; the calibration may have been off, so recalibrate. |
| `Bracket violation: ms 'above' observed (X) exceeds ceiling (Y)` | The above leg ran longer than `threshold × aboveCeilingMultiplier`. Record it again with a smaller target, or widen `aboveCeilingMultiplier` only if the wider ceiling does not reach an adjacent severity tier. |
| `Inflated detector trace records in <leg> capture: expected each event to carry a unique detectedAtMicros arg` | The capture has N records inside the scenario span but fewer than N distinct `detectedAtMicros` values. Producer-side dedup (v0.18.1+) stamps a unique value per emission, so this points to a replayed or forged capture, or to a binary older than v0.18.1. Record again on v0.18.1 or later. |

### Multi-leg recovery (only when needed)

`Sleuth.markScenarioBegin` calls `SleuthController.resetCaptureState()`,
which clears the per-detector state that would carry one leg into the
next: `NetworkMonitorDetector.clearRecords()`, the MemoryPressure heap
window, the PlatformChannel cooldown, the FrameTiming frame buffer, and
the rebuild, repaint, stream-resource and tracked-resource capture
state. It does not clear the producer-side dedup set. That set persists
across scenarios, so the next scenario's flush cannot record stale
events from the VM timeline buffer a second time. You do not need to
restart the app between legs on one screen (Below, At, Above).

The reset runs only in capture mode, behind the same
`SleuthConfig.captureMode` gate as the `markScenarioBegin` marker.
Ordinary app sessions skip the reset because they skip the marker too.

> **Side effects of `clearRecords`.** The reset calls
> `NetworkMonitorDetector.clearRecords()`, which (a) stamps a cutoff
> time, so the detector drops an HTTP request started before
> `markScenarioBegin` when it completes, (b) clears the in-flight
> request map, and (c) cancels the frequency-evaluation timer, which
> the next request rebuilds. That is correct for the standard capture
> pattern (`markScenarioBegin`, then the workload, then
> `markScenarioEnd`). If your procedure sends a warmup probe before
> `markScenarioBegin` and expects the probe's record in the capture,
> the reset drops that record. Send the warmup after
> `markScenarioBegin`, or skip the auto-reset by making the calls that
> `markScenarioBegin` wraps yourself.

If a leg shows OUT-OF-BAND or "Missing detector trace record" even on
v0.18.1 or later with the procedure above:

1. Note which leg failed and its observed magnitude.
2. Kill the app from the iOS app switcher (swipe it away).
3. Cold-launch it from the home screen icon. No DDS attaches, so VM+
   mode comes back.
4. Run the legs again in order, starting with the first.

Cold launch is a fallback only. The v0.18.1 producer dedup and the
scenario-begin reset handle the common case. Cold launch covers a VM
service that is stuck, for example after thermal throttling, a crashed
background isolate or a dropped wireless debugging link.

## MemoryPressure heap_growing capture (v0.19.3)

`MemoryPressureDetector.heap_growing` differs from HeavyCompute and
NetworkMonitor in two ways:

1. **Emission waits on wall-clock time.** The detector needs a
   regression slope above 512,000 bytes/s held for at least 10 s
   across `_heapSamples` (a 60-entry queue at the 500 ms heap-poll
   cadence, so a 30 s window). `flushTimelineNow` cannot shorten the
   sustained window; wall-clock time is the limiting axis.
2. **The VM trace ring buffer can overflow.** 30 s of heavy allocation
   under the default `Dart`, `Embedder` and `GC` streams writes tens of
   thousands of paint, raster, frame and GC events and overflows the
   ring buffer (about 50k events) mid-leg. The scenario markers then
   roll off before `exportCaptureJson` can read them. The capture
   screen narrows the VM timeline streams to `Dart` for the scenario
   span with `Sleuth.suspendNonEssentialTimelineStreams()` and restores
   them when the scenario ends.

**Procedure (`example/lib/demos/memory_pressure_capture_screen.dart`):**

1. Launch with `--no-dds` and both dart-defines:
   ```bash
   cd example && fvm flutter run --profile --no-dds -d "iPhone 12" \
     --dart-define=SLEUTH_CAPTURE_MODE=true \
     --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"
   ```
   Without `--no-dds` Sleuth stays in FRAME mode; see the VM-service
   requirement above.
2. Wait at least 5 s after launch so the detector's 3 s warmup passes.
3. Open Capture Helpers, then MemoryPressure.
4. Tap **Calibrate**. A 1 s allocation warmup sets `_bytesPerMs`.
5. For each leg (Below, At, Above):
   - Tap the leg button.
   - Allocation runs for 30 s, followed by a 600 ms dwell before
     `markScenarioEnd` and an 800 ms dwell after it, about 31.5 s per
     attempt.
   - The leg logs `✓ IN-BAND` or `✗ OUT-OF-BAND`. The screen judges the
     at and above legs on the detector's slope. It reads
     `observedSlopeBytesPerSec` from the in-span record and writes it
     into `expectedMagnitude.observed`. It judges the below leg on the
     allocator rate.
   - On success the leg logs `[<leg>] capture stashed (N chars)`.
     `Sleuth.exportCaptureJson` already wrapped the JSON right after
     `markScenarioEnd`.
   - Tap **Export last leg**. The validator parses the stashed JSON,
     checks the number of `sleuth.issue.heap_growing.warning` records
     inside the scenario span (0 for below, exactly 1 for at and
     above), and copies the JSON to the iOS clipboard when it passes.
6. Paste the clipboard into Notes, Mail or AirDrop and send it to the
   Mac. Save it as `heap_growing_${leg}.json` under
   `test/validation/captures/memory_pressure/`.
7. Repeat for all three legs. Each leg allows 5 attempts.

**Common failures and diagnostics:**

`Sleuth.exportCaptureJson(...)` logs the reason for every null return
through `debugPrint`. Check the `flutter run` terminal, or Console.app
on the Mac filtered by `Sleuth.exportCaptureJson`:

| debugPrint message | Cause | Fix |
|---|---|---|
| `VM service client {not initialised\|disconnected}` | The VM service dropped (a wireless drop, or iOS auto-lock sent the app to the background) | Turn off iOS auto-lock; kill and relaunch the app |
| `VM service returned 0 timeline events` | The VM-service plumbing failed | Restart the device; check the wireless debug pairing |
| `Scenario markers not found (begin=null, end=null)` | A ring buffer overflow rolled the markers off | Stream narrowing should prevent this. If it persists, lengthen the post-end dwell or split the allocation phase |

**Rejected legs and exports:**

- **The detector did not fire (count 0).** For the at and above legs
  this shows when the leg ends. The leg logs OUT-OF-BAND and "capture
  has no detector slope arg in any in-span heap_growing.warning event".
  Flat pre-scenario samples in the `_heapSamples` window used to dilute
  the slope below 512,000 bytes/s. `markScenarioBegin` now resets the
  detector (through `resetCaptureState`), so the regression starts on
  scenario allocation. If the count is still 0, calibration drift gave
  too low a rate, so recalibrate and retry the leg.
- **The sustained window broke (count 2 or more).** The slope dipped
  below the threshold mid-leg and then rose again. Each reset of
  `_sustainedGrowthStart` emits a new trace record with its own dedup
  identity, and Export logs "Export REJECTED". Retry the leg.

**iOS auto-lock during 30 s legs.** Auto-Lock (Settings, Display &
Brightness) is often set to 30 s, the length of a leg. Set it to Never
for the capture session and restore it afterwards. Otherwise the screen
locks mid-leg, the app may go to the background, and the VM service
connection drops.

## PlatformChannel platform_channel_traffic capture (v0.19.4)

`PlatformChannelDetector.platform_channel_traffic` differs from both
HeavyCompute and MemoryPressure in three ways:

1. **Short scenario span (about 3.2 s).** The detector evaluates on a
   1 s window boundary. The capture screen sends method calls for about
   1.5 s, waits 1500 ms, closes the span, and waits a 200 ms barrier
   before the export. The 1500 ms dwell covers three detector poll
   cycles (500 ms each) plus a margin, so the trace record lands inside
   the scenario span even when the evaluation boundary falls late in
   the call phase. The screen does not narrow the streams, because the
   span stays well inside the ring buffer with the default `Dart`,
   `Embedder` and `GC` streams on.
2. **Parallel `Future.wait` batches, not sequential awaits.** An iOS
   `MethodChannel` round trip takes about 12 to 25 ms over USB and 30
   to 80 ms over wireless. Sequential awaits would cap the send rate at
   roughly 12 to 80 calls/s and make the above leg's 45 calls/s
   unreachable over wireless. The screen fires K parallel
   `invokeMethod` futures every 200 ms tick (3, 5 and 9 for below, at
   and above, so 15, 25 and 45 calls/s), so a tick costs about one
   round trip. iOS scheduling and channel coalescing put the detector's
   count below the send rate, which is why the above leg sends above
   its band.
3. **The `debugProfilePlatformChannels` framework flag.**
   `MethodChannel.invokeMethod` writes `Platform Channel send …`
   timeline events only while this top-level Flutter flag is true. The
   capture screen sets it for each leg in a try/finally, so the flag
   does not stay on for later live monitoring, where it would add a
   timeline event for every unrelated channel call. Leave
   `SleuthConfig.profilePlatformChannels` off for captures; it holds the
   flag on for the whole session.

**Procedure (`example/lib/demos/platform_channel_capture_screen.dart`):**

1. Launch with `--no-dds` and both dart-defines:
   ```bash
   cd example && fvm flutter run --profile --no-dds -d "iPhone 12" \
     --dart-define=SLEUTH_CAPTURE_MODE=true \
     --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"
   ```
   Without `--no-dds` Sleuth stays in FRAME mode, as for MemoryPressure.
2. Wait at least 3 s after launch so the VM service connection settles.
3. Open Capture Helpers, then PlatformChannel.
4. Run each leg (Below, At, Above). The screen has no calibration
   phase, because the batch size sets the rate.
   - Tap the leg button.
   - Calls run for about 1.5 s, followed by the 1500 ms dwell and the
     200 ms barrier, about 3.2 s per attempt.
   - On success the leg logs `[<leg>] capture stashed (N chars)`.
     `Sleuth.exportCaptureJson` already wrapped the JSON right after
     `markScenarioEnd`. The screen judges the at and above legs on the
     detector's `observedCount` and writes that count into
     `expectedMagnitude.observed`.
   - Tap **Export last leg**. The validator parses the stashed JSON,
     checks the number of `sleuth.issue.platform_channel_traffic.warning`
     records inside the scenario span (0 for below, exactly 1 for at
     and above), and copies the JSON to the iOS clipboard when it
     passes.
5. Paste the clipboard into Notes, Mail or AirDrop and send it to the
   Mac. Save it as `platform_channel_traffic_${leg}.json` under
   `test/validation/captures/platform_channel/`.
6. Repeat for all three legs. Each leg allows 5 attempts.

**Bands (from the v0.19.4 metadata: threshold 20, `atTolerance` 0.50,
`aboveCeilingMultiplier` 1.95):**

- below: 1 to 19 calls/s. The detector stays silent. The schema
  requires `magnitudeMin` above 0, so the minimum is 1, not 0.
- at: 20 to 30 calls/s (`atTolerance` 0.50 gives [T, 1.5 T]).
- above: 31 to 39 calls/s. The ceiling of 39 stays under the 41-call
  critical boundary, so the above leg cannot also bracket the critical
  tier.

**Rejected legs and exports:**

- **The detector did not fire (count 0).** For the at and above legs
  this shows when the leg ends, as OUT-OF-BAND with "capture has no
  detector count arg in any in-span platform_channel_traffic.warning
  event". The likely cause is that the parser dropped the channel
  events because `debugProfilePlatformChannels` was off. The screen
  sets the flag in a try/finally, so only a manual change during the
  leg or `SleuthConfig.profilePlatformChannels` can leave it wrong. A
  second cause is iOS coalescing the parallel calls so the rate stayed
  under 20 calls/s; check the batch geometry.
- **The cooldown failed (count 2 or more).** The scenario span reached
  a second 1 s evaluation cycle and the cooldown counter did not
  suppress it, so Export logs "Export REJECTED". Retry the leg.

After the 3-window cooldown, the detector keeps the emitted issue for
`emissionPersistence` (10 s from the emission) without emitting it
again. The retained issue carries the same `dedupIdentityMicros`, so it
adds no trace record. Only a new overload after the cooldown emits a
second record, which the count check above rejects.

**Channel reuse.** The capture screen calls
`MethodChannel('sleuth_demo_channel').invokeMethod('ping')`. The app
registers the channel and its handler at launch in
`example/ios/Runner/AppDelegate.swift:21-25`; the handler returns
`result(nil)` for every call. No new native code is needed.

**Fixture provenance.** The three checked-in captures under
`test/validation/captures/platform_channel/` were recorded with the
1500 ms dwell; their scenario spans are 3.19 to 3.21 s long. The dwell
went up from 800 ms after an early at-leg capture left only 43 ms
between its trace record and `scenario.end`. The bracket checks the
magnitude against the threshold, not the span length.

**The observed-axis cross-check.** The audit compares
`expectedMagnitude.observed` with the in-span trace arg `observedCount`
and accepts a difference of up to 25 %. `checkCapturesCarryObservedAxisArg`
also fails a `runtimeVerified` bracket whose at or above capture lacks
the arg. The checked-in at and above captures carry it.

## FrameTiming jank_detected capture (v0.19.7)

`FrameTimingDetector` is a `runtime` detector. It reads frames through
`SchedulerBinding.addTimingsCallback`, not from VM timeline events. For
the audit gate's `requireTraceRecord` rule, what matters is when
`_recordIssuesForCapture` runs over the detector's short-lived
`_issues`. Three paths call it:

* the scan loop (`_runStructuralScans`), whose timing does not line up
  with the scenario span boundaries;
* the frame-stats callback (`_onFrameStats`), after each batch of frame
  timings;
* `Sleuth.flushTimelineNow()`, which is deterministic. The flush
  reaches `SleuthController._onTimelineData` through
  `VmServiceClient.pollTimelineSync`, and `_recordIssuesForCapture`
  there records the issues of every detector, whatever its lifecycle.

The capture screen must call `flushTimelineNow()` right before
`markScenarioEnd` so the detector's emission lands inside the scenario
span.

### Capture-mode warmup short-circuit

`FrameTimingDetector` defaults to `warmupDuration: Duration(seconds: 3)`,
which suppresses jank evaluation while the app warms up (shader
compilation, route setup, Dart VM JIT). A 6 s bracket scenario inside
that gate would see only the tail of the buffer after warmup and miss
the calibrated jank window.

v0.19.6 added `FrameTimingDetector.captureMode`, set from
`SleuthConfig.captureMode`. When the config flag is `true`,
`_isPastWarmup()` returns `true` whatever `warmupDuration` and
`warmupFrameCount` say. Production app sessions never turn it on; the
dart-define makes the wiring explicit.

### Per-leg sequence (FrameTimingCaptureScreen)

```
suspendNonEssentialTimelineStreams()             // Dart stream only for the span
markScenarioBegin(name)                          // resets the frame buffer and warmup
└── a Ticker spins the UI thread for 18 ms on every Nth frame,
    N = round(100 / target %): below never, at every 5th, above every 4th
└── 6 s scenario span elapses (240-frame buffer)
└── ticker stops
└── 200 ms frame-settle barrier
└── Sleuth.flushTimelineNow()                    // drains _issues through _recordIssuesForCapture
markScenarioEnd(name)
└── 800 ms post-end barrier (same as MemoryPressure)
resumeAllTimelineStreams()
exportCaptureJson(...)                           // compose, then stash
└── post-leg validator: no jank_detected.warning for below;
                        at least one for at and above, whose last record
                        carries bufferSize >= 180 and observedJankPercent
                        inside the leg's band
```

The screen's bands are below [0, 12] % (target 5 %), at [16, 24] %
(target 20 %) and above [25, 29] % (target 27 %). The bracket threshold
is 16 % because the detector fires only when the rounded jank percent
passes 15; the metadata declares `atTolerance` 0.50,
`aboveCeilingMultiplier` 1.85 and `observedAxisReduction: 'last'`.

The validator does not reject a `sustained_jank.critical` co-fire. Both
stable ids report on the same frames, the bracket axis
(`jank_detected.warning`) is independent of it, and the audit does not
require the two to be exclusive. An injected frame spins 18 ms on top
of a baseline near 16 ms, close to the 33 ms severe threshold, so a
co-fire can happen on a warm device.

Each leg allows 3 attempts. A retry runs the same injection rate,
because band misses come from frame-delivery jitter, not from
calibration.

### 60 Hz pre-flight

The bracket axis (jank percent over the 240-frame buffer) is
calibrated against the 16.67 ms frame budget of 60 Hz devices such as
iPhone 12 and iPhone SE. On 120 Hz devices (iPhone 12 Pro, iPad Pro,
Pixel 8 Pro) the budget is 8.33 ms, which gives a different jank
distribution at the same spin. The screen's pre-flight rejects any
display outside 59 to 61 Hz so the captures stay comparable across
runs.

The screen stamps its exports with the provenance described under
"RebuildActivity and Repaint time-share captures" below (launch with
`--dart-define=SLEUTH_CAPTURE_DEVICE=<model>`), and its leg buttons
stay disabled while that provenance is unknown or not approved.

## NetworkMonitor large_response and request_frequency capture (v0.19.9)

Two more families reach runtimeVerified through `additionalBrackets`,
both recorded on `NetworkMonitorCaptureScreen` through its mode
selector.

**large_response (bytes axis).** A loopback `HttpServer` returns sized
payloads for `?bytes=N`. The threshold is 1 MiB, `atTolerance` is 0.10
because loopback byte counts are deterministic, and
`aboveCeilingMultiplier` 2.0 puts the ceiling at 2 MiB. `large_response`
has no critical tier.

| Leg | Bytes target | Lands in |
|---|---|---|
| Below | ~800 KiB | < 1 MiB (silent) |
| At | ~1.05 MiB | [1 MiB, 1.1 MiB] |
| Above | ~1.5 MiB | (1 MiB, 2 MiB], > at_observed |

The detector stamps `extraTraceArgs.observedResponseBytes` with the
byte count it received for the largest response, and the audit gate
checks it against the capture's magnitude.

**request_frequency (events axis).** Each leg spreads its requests
over 4 s, inside the detector's trailing 5 s window. The threshold is 30,
`atTolerance` is 0.50 for iOS scheduling jitter (the same value as
PlatformChannel in v0.19.4), and `aboveCeilingMultiplier` 2.0 puts the
ceiling at 60:

| Leg | Requests sent over 4 s | Peak count |
|---|---|---|
| Below | 25 (about 6 per second) | < 30 (silent) |
| At | 38 (about 9.5 per second) | [30, 45] |
| Above | 52 (about 13 per second) | (30, 60], > at_observed |

The detector emits `request_frequency` at warning severity only; there
is no critical tier today. The schema filters trace records by event
name (`sleuth.issue.<stableId>.<severity>`), so a future critical raise
scopes correctly without a metadata change.

A 5.5 s scenario span plus the 800 ms post-end barrier overflows the
timeline ring buffer under load, so the screen wraps the leg in
`Sleuth.suspendNonEssentialTimelineStreams()` /
`resumeAllTimelineStreams()`, which narrow the streams to `Dart`.

Both emissions export their observed axis in `extraTraceArgs` and stamp
`dedupIdentityMicros`, which the v0.18.1 producer-dedup contract behind
`requireUniqueDetectedAtMicros: true` requires.

**Producer pattern (v0.19.10+).** The request_frequency below leg reads
`expectedMagnitude.observed` from
`Sleuth.networkMonitor.lastObservedPeakCount` after
`flushFrequencyEvaluation()`. That call only recomputes the peak and is
safe to repeat. Issue emission stays in the detector's `_evaluate`
path, so repeated flushes cannot add trace records. The schema's
`_requireNoIssueTraceRecord` leaves the below leg's axis unchecked, so
a planned rather than measured value would have passed unnoticed;
reading the detector's peak in the app closes that gap.

The capture screen also calls `Sleuth.flushTimelineNow(timeout: 2s)`
between the peak read and `markScenarioEnd`, so pending detector
emissions reach the VM trace buffer before the scenario closes (the
same barrier as HeavyCompute and FrameTiming). It also passes
`bracketStableId` and `bracketSeverityLabel` to
`Sleuth.exportCaptureJson`, which then refuses a missing or unexpected
in-span emission with a `debugPrint` message before any JSON reaches
the clipboard.

## RebuildActivity and Repaint time-share captures (hands-free)

`rebuild_activity` (warning and critical) and `excessive_repaint`
(warning) bracket the share of UI-thread time spent inside BUILD and
PAINT scopes (`unit: 'percent'`, arg keys `observedBuildPercent` and
`observedPaintPercent`). Their capture screens vary the cost per frame,
not the event count, and service extensions drive the legs instead of
taps. Record on a device and SDK the schema approves (today iPhone 12 /
iOS 17.5 with Flutter 3.41.x or 3.47.x). Record the three legs of a
bracket with one build, because the audit requires one exact
`flutterVersion` across a triad.

### Launch

```bash
cd example
fvm flutter run --profile --no-dds -d <udid> \
  --dart-define=SLEUTH_CAPTURE_MODE=true \
  --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"
```

`--no-dds` keeps the VM service open to more than one client, so
Sleuth's own VM client stays connected (VM+ mode). With DDS the service
has a single client and Sleuth drops to Basic. Connect any
`package:vm_service` client to the printed `ws://.../ws` URI. Leave the
phone idle for two minutes before the first leg, because build and
paint durations drift with temperature.

If `flutter run` fails while Xcode starts the app on the phone, build,
install and launch it yourself, then attach without DDS:

```bash
cd example
fvm flutter build ios --profile \
  --dart-define=SLEUTH_CAPTURE_MODE=true \
  --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"
xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <udid> com.example.example
fvm flutter attach --no-dds -d <udid>
```

`flutter attach` prints the VM service URI. The exports still stamp the
`flutter run` launch command as `captureCommand`.

### Provenance

Each export stamps the environment it was recorded in, read from the
build rather than assumed:

- `device`: the `SLEUTH_CAPTURE_DEVICE` dart-define (the example has no
  device-info plugin, so name the model the phone actually is);
- `deviceOsVersion`: `Platform.operatingSystemVersion`, which iOS
  reports as `Version 17.5 (Build 21F79)`, stamped as `iOS 17.5`;
- `flutterVersion`: `FlutterVersion.version`, which the flutter tool
  sets at build time;
- `captureCommand`: the launch command above with that device.

A leg refuses to start while any of these is unknown or not in
`ProfileCaptureSchema.approvedDevicePairs` /
`approvedFlutterMajorMinors`. The check refuses a phone on iOS 17.5.1
instead of stamping it 17.5. The capture screens show the reason in
their pre-flight banner. Every other capture screen in the example
stamps its exports the same way. The FrameTiming screen keeps its leg
buttons disabled without approved provenance, and the other tap-driven
screens refuse at export and print the reason
(`Sleuth capture: not exporting: ...`).

### Per leg

1. Call `ext.sleuthDemo.captureLeg` with `detector=rebuild|repaint`,
   `tier=warning|critical` (repaint: `warning` only) and
   `leg=below|at|above`. It brings the capture screen to the front (it
   pops the routes above a covered one, or opens one when none is
   mounted) and returns `{started: true, leg: ...}` at once, or
   `{error: busy | not_capture_mode | vm_disconnected | bad_args |
   bad_provenance | no_navigator | screen_not_ready | not_in_front}`.
   `bad_provenance` carries the reason in `detail`.
2. Poll `ext.sleuthDemo.captureResult` every 2 s until `state` is
   `done` or `failed`. Both detectors run a 6 s workload per measured
   span. With the 3 s pre-pass and the dwells, a one-span leg takes
   about 12 s, and each further span adds about 9 s (five spans at
   most). The payload carries `state`, `leg`, `observed`, `attempts`
   (measured spans run, 1 to 5), `log` and, on success, the wrapped
   capture in `json`. Pass `consume=true` on the final read to release
   the stash.
3. Write `json` to the capture file (the names are unchanged):
   `rebuild_detector/{below,at,above}.json`,
   `rebuild_detector/critical_{below,at,above}.json`,
   `repaint/excessive_repaint_{below,at,above}.json`. The scenario is
   `rebuild_activity_<basename>` or `excessive_repaint_<role>`.
4. Wait 5 s before the next leg. Order: warning below, at and above,
   then critical, then repaint.

The workloads add cost in the measured phase without growing the
element tree. The rebuild workload has 64 leaves, each running a
`work`-iteration integer loop inside `build()` and passing the result
to a child that renders one const `SizedBox.shrink()`. `work` adds
BUILD time while the element count, layout, paint and Sleuth's own
structural scan stay the same. The repaint workload spreads `ops` text
layouts per frame across the 32 tiles (tile `i` draws `ops ~/ 32`,
plus one when `i < ops % 32`). Each layout uses a fresh
`TextPainter` (default font, size 12) whose text carries the current
tick, so every layout is new PAINT work rather than raster work.

Each leg runs a 3 s calibration pre-pass at a known knob (`work` 4000
for rebuild, `ops` 32 for repaint), reads the detector's peak over the
pre-pass (`peakObserved*Percent`, the best full window of steady
workload), and scales the knob to the leg target. Warning targets are
0.5, 1.25 and 2.1 times the threshold for rebuild and 0.5, 1.25 and 2.0
times for repaint. Rebuild critical targets are 0.8, 1.23 and 2.0 times
the critical threshold, which is 3 times the warning threshold.
It then stops, flushes the timeline, resets the detector, idles 1.5 s
so the idle heartbeat closes an empty window, and records a 6 s
scenario. `observed` is the detector peak over the scenario rounded to
one decimal, the precision of the trace arg. The `expectedMagnitude`
bands are warning below [0.5, t), critical below [0.65 t, t), at
[t, 1.5 t] and above (1.5 t, 2.7 t], the same edges the audit draws.

When the peak lands outside its band, the leg runs another measured
span with the same boundary and scenario name, at the knob scaled by
target / observed and clamped to the workload range, up to four more
spans (five in all). The leg exports an in-band span (the export reads
the latest span of the scenario). For at and above legs, the leg then
checks the in-span `sleuth.issue.<id>.<severity>` records the way the
audit does: every record carries the observed arg, the maximum lies in
the role band and within 25 % of `observed`, and at least the
bracket's `minInBandSamples` records (2 for `rebuild_activity.critical`,
otherwise 1) lie in the role band. A shortfall runs another span within
the same five-span limit, rescaled toward the target when the peak fell
short of it and at the same knob otherwise.

The capture screen has to stay in front for the whole leg. A route
covered by another keeps its state while its tickers are muted, so its
workload would not run. Every 100 ms through the pre-pass, the dwell
and the workload, the leg checks that the screen's route is current
and its tickers are enabled, and fails (closing the scenario and
exporting nothing) when they are not. Do not open another screen or a
dialog over a running leg.

A leg fails, and exports nothing, when the provenance is unknown or not
approved, the live threshold differs from the bracket's, the pre-pass
reads 0 %, the scaled knob falls outside the workload range, a peak
reads 0 %, the export is refused, the screen leaves the front, or five
spans pass without one that clears both checks. Record a failed leg
again on its own. After three failed legs, stop and read `log` instead
of widening tolerances.

`ext.sleuthDemo.vmAxes` (`reset=true|false`) returns `buildLast`,
`buildPeak`, `paintLast`, `paintPeak` and `vmConnected` for calibration
walks on other screens. A reset while a leg runs returns
`{"error": "busy"}` and leaves the leg's peak untouched.

### Validate

```bash
fvm flutter test test/validation/detector_metadata_audit_test.dart \
  test/validation/profile_capture_schema_test.dart \
  test/validation/rebuild_reproducer_test.dart
```

## Why GpuPressure raster_dominance cannot reach runtimeVerified

A `runtimeVerified` raise of `GpuPressureDetector.raster_dominance` is
not viable on the VM leg. Each of three blockers alone rules out the
ratio bracket:

1. **iOS profile mode cannot force the ratio axis.** A steady UI
   cost of about 3 to 5 ms per frame against a single filter's raster
   cost of about 2 ms per frame gives a ratio near 0.5. Passing the
   `> 2.0` threshold needs a workload of 6 or more stacked filters, and
   the above band would still be flaky under iOS scheduling jitter.
2. **No independent schema witness.**
   `ProfileCaptureSchema._crossCheckTraceVsObserved` skips non-time
   units, because a trace cannot certify a ratio. A ratio bracket
   checked against a ratio the detector stamps would certify itself.
3. **The detector mixes values from different polls.**
   `processTimelineData` updates the raster fields (`_lastRasterUs`,
   `_lastMaxFrameRasterUs`) only when a batch has raster durations, and
   `_lastUiUs` only when it has UI time. `_evaluate` can therefore
   divide a fresh worst-frame raster time by a stale UI total from an
   earlier poll.

A future raster raise should target an absolute-duration axis, which
the trace-versus-observed cross-check covers, and needs detector logic
that evaluates one poll's snapshot rather than the last value seen of
each field. The frame leg (per-frame `FrameTiming` raster against UI,
`likely`) evaluates each frame on its own and stamps
`worstFrameRasterUs`, but it has no bracket and no capture screen, so
it stays `reproducerOnly`.

## Required sleuthMetadata fields (v0.18.0)

`Sleuth.exportCaptureJson` and `tool/wrap_capture.dart` both produce
this shape:

```jsonc
{
  "traceEvents": [ /* Chrome Trace Event Format, from the VM timeline or DevTools */ ],
  "sleuthMetadata": {
    "schemaVersion":   "v1",                        // added in v0.18.0
    "device":          "iPhone 12",                 // pinned
    "deviceOsVersion": "iOS 17.5",                  // pinned (pair-matched)
    "flutterVersion":  "3.47.6",                    // major.minor in the approved set
    "captureCommand":  "fvm flutter run --profile --no-dds -d <device> ...",
    "scenario":        "human label",
    "expectedMagnitude": {
      "min":      5,
      "observed": 6,
      "max":      7,
      "unit":     "ms"
    },
    "captureDate":     "2026-04-25T...Z",
    "role":            "below"                      // below | at | above, required since v0.19.0
  }
}
```

The runtime, not the wrapper, puts these events in the `traceEvents`
array:

- An instant event named `sleuth.scenario.begin` (`ph: i`).
- An instant event named `sleuth.scenario.end` (`ph: i`).
- For the at and above legs only: an instant event named
  `sleuth.issue.<stableId>.<severity>` (`ph: i`) with a `ts` inside the
  scenario span. `CaptureHelper` emits it; you do not write it
  yourself.

## Why hand-wrapping was retired

Before v0.18.0 the procedure had a step "wrap the JSON with a
`sleuthMetadata` block at the top level", so the recorder typed in
whatever shape they remembered from the schema. The same person then
wrote both the evidence and its description, which weakened the audit
gate. A malformed wrapper failed to parse, but a wrapper with the right
fields and wrong values could parse and then fail bracketing in
confusing ways at audit time. `Sleuth.exportCaptureJson` and
`tool/wrap_capture.dart` produce the exact shape the schema expects, so
the wrapper cannot drift.
