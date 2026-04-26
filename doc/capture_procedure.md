# Capture procedure (v0.18.0+)

> **v0.18.0 PROCEDURE — NetworkMonitor via USB-with-app-relaunch**
>
> v0.18.0 first runtimeVerified raise is `NetworkMonitor.slow_request`
> (WARNING tier, threshold 1000 ms). HeavyCompute is deferred — see
> "Deferred to v0.18.1+" section below for the architectural reason.
>
> iPhone profile builds over USB are FRAME mode on first launch
> (DevTools attached, VM service routed to DevTools). Sleuth's
> internal `VmServiceClient` cannot compete for the subscription.
> Operator procedure:
>
> 1. `cd example && fvm flutter run --profile -d "iPhone 12" \
>      --dart-define=SLEUTH_CAPTURE_MODE=true`. Installs the app,
>    attaches DevTools (FRAME mode — capture won't work yet).
> 2. **Quit `flutter run`** (`q`). DevTools detaches.
> 3. **Re-open the app from the iPhone home screen.** No DevTools
>    attached → Sleuth's `VmServiceClient` claims the VM service
>    subscription → VM+ mode active → real `NetworkMonitorDetector`
>    observes HTTP completions and emits
>    `sleuth.issue.slow_request.warning` via the real
>    `_recordIssuesForCapture` pipeline.
> 4. In the running app: navigate to **NetworkMonitor capture
>    helper** → tap a leg (Below 800 ms / At 1020 ms / Above
>    1500 ms) → wait for "tap Export now" log line → tap
>    **Export last leg**. The screen calls
>    `Sleuth.exportCaptureJson(...)` which fetches the VM trace
>    buffer, filters to the matching scenario span, wraps with
>    sleuthMetadata, and **copies the JSON to the iOS clipboard**.
> 5. **Paste clipboard** into Notes / Mail / AirDrop note → send to
>    Mac. (One leg at a time — clipboard holds one capture; copy →
>    paste → tap next leg → copy → paste, repeat.)
> 6. Save each pasted JSON as
>    `slow_request_<leg>.json` under
>    `test/validation/captures/network_monitor/`.
> 7. (Optional) Re-wrap via `tool/wrap_capture.dart` only if the
>    metadata needs editing. The exported JSON is already
>    schema-conformant.
>
> Captures from step 1 (DevTools attached, FRAME mode) ARE NOT
> ACCEPTABLE for `runtimeVerified`. The detector pipeline never
> fires in FRAME mode and the resulting capture lacks the required
> trace record — schema audit will reject as "Missing detector
> trace record."
>
> ---
>
> ### vmOnly detectors (HeavyCompute, ShaderJank, MemoryPressure, GpuPressure, PlatformChannel)
>
> v0.18.1 ships `Sleuth.flushTimelineNow()` — the synchronous VM-poll
> + emission flush that NetworkMonitor sidestepped via runtime
> lifecycle + 200 ms dwell. Use this pattern for any vmOnly detector
> raise from v0.18.2 onwards:
>
> ```dart
> Sleuth.markScenarioBegin('heavy_compute_above');
> await runHeavyWorkload();
> await Sleuth.flushTimelineNow(); // forces VM poll + emit before next line
> Sleuth.markScenarioEnd('heavy_compute_above');
> ```
>
> Without `await Sleuth.flushTimelineNow()`, the issue trace record
> would be emitted on the next VM poll tick (~500 ms cadence) which
> typically post-dates `scenario.end` by hundreds of milliseconds. The
> schema audit then rejects the capture as "Missing detector trace
> record."
>
> **One flush is not always enough.** Detectors with cumulative-evidence
> state machines (e.g. an emission that requires N consecutive BUILD
> events crossing threshold) may need multiple `flushTimelineNow`
> calls during the workload OR a longer scenario span. Confirm by
> inspecting the captured trace before claiming `runtimeVerified`:
> the `sleuth.issue.<id>.<severity>` event's `ts` must fall strictly
> inside `[scenario.begin, scenario.end]`. If it consistently lands
> after `scenario.end` despite the flush, the detector emits from
> something other than a single VM poll callback (frame_stats,
> microtask, cumulative N-poll evaluation) — capture the workload
> fragment that triggers emission and adjust the procedure.
>
> **`flushTimelineNow` timeout is cooperative, not preemptive.** The
> `{Duration? timeout}` parameter wraps the await with `Future.timeout`
> but does NOT cancel the underlying VM round-trip. On TimeoutException
> the inner work continues; treat the exception as "capture failed,
> wait for steady state then retry," not "abort and retry immediately."
>
> One additional gotcha specific to HeavyCompute on iPhone:
> per-scenario CPU/thermal variance can be ±25–60 %, defeating
> narrow at/above bands even with `atTolerance: 0.50`. The detector
> author may need to widen the at-band tolerance OR pick a workload
> with deterministic timing. NetworkMonitor's loopback HTTP latency
> is the cleanest reference (deterministic ± 5 ms).
>
> **`detectedAt` MUST be stamped at first detection.** The producer-side
> dedup composite key includes `issue.detectedAt.microsecondsSinceEpoch`
> with `0` as the fallback for null. A detector that emits multiple
> distinct issues per scenario with null `detectedAt` collapses them
> all to one emission, breaking the runtimeVerified evidence
> guarantee. Verify in the detector's reproducer test that every
> emitted `PerformanceIssue` carries a non-null `detectedAt` before
> raising the tier.
>
> **BUILD wire dur ≠ Stopwatch ms.** For HeavyCompute (and any future
> detector observing BUILD durations), the framework's BUILD timeline
> event encloses the entire build callback — workload + setState
> bookkeeping + child widget rebuilds. Stopwatch around the inner
> workload measures less. On iPhone 12 / iOS 17.5 the gap is small
> enough that observed and BUILD wire dur stay on the same severity
> tier (above-leg target 12.5 ms → BUILD ~13-14 ms < 16 ms critical).
> On a slower device, BUILD wire dur could exceed the critical
> threshold (16 ms for HeavyCompute) and the detector emits
> `.critical` instead of `.warning`. Schema audit looking for
> `.warning` then fails. If above-leg hits "Missing detector trace
> record" on a different device, lower the workload target until BUILD
> wire dur stays under the critical threshold.

End-to-end procedure for producing a `runtimeVerified` capture triad
that `ProfileCaptureSchema.validateBracket(... requireDetectorTraceRecord:
true)` accepts. Both Path A and Path B follow the same shape; future
detector raises follow the same shape too.

If you only need to rotate device / OS / Flutter pins, see
`doc/reference_devices.md` and skip ahead to the schema reference at
the bottom of this file.

## VM-service requirement (read first)

`runtimeVerified` evidence is the **real detector pipeline's** trace
record — not a screen-synthesised proxy. The detector pipeline only
runs when `SleuthController.VmServiceClient` is connected (VM+ mode,
not FRAME mode). When it isn't, the `vmOnly` and `hybrid` detectors
never observe their inputs and `_recordIssuesForCapture` emits
nothing. The schema audit then rejects the resulting capture as
"Missing detector trace record" — which is the correct behavior.

VM service is reachable in three configurations:

- **Wireless iPhone debugging** (Path A target). Pair the iPhone with
  Xcode via USB once, enable "Connect via network," then unplug. The
  VM service port routes over WiFi and `VmServiceClient` connects from
  the host. Procedure: detailed in the Path A section below (TBD).
- **iOS Simulator on Mac**. VM service is always reachable. Performance
  characteristics differ from real iPhone hardware though, so simulator
  captures are NOT a substitute for real-device evidence — only useful
  for testing the procedure itself.
- **Android profile mode**. VM service is reachable over `adb` even
  with USB tethering; the iOS USB-no-VM-service constraint is
  iOS-specific.

USB-tethered iPhone profile-mode runs in **FRAME mode**. Captures from
a FRAME-mode run are NOT acceptable for `runtimeVerified` — the trace
record will be missing and the schema audit will reject. Earlier
iterations of this procedure included a `Sleuth.markCaptureIssue`
synthetic-emission fallback that mirrored the detector's threshold
ladder from a Stopwatch around the workload; that path was removed
because it produced evidence indistinguishable from forgery and
certified screen-mirrored logic instead of detector behavior.

## What changes from v0.16.x captures

v0.18.0 introduces three contract requirements on top of the v0.16.4
schema:

1. **Schema version field**. `sleuthMetadata.schemaVersion = "v1"` must
   be present. Captures that omit it are accepted by the dormant
   schema parser (default `requireDetectorTraceRecord: false`) but are
   rejected by every detector audit at `runtimeVerified` or stronger.
2. **Scenario markers via the public API**. Use
   `Sleuth.markScenarioBegin(name)` / `Sleuth.markScenarioEnd(name)`
   instead of raw `Timeline.instantSync('sleuth.scenario.begin')`.
   The public API is triple-gated (release-mode, `captureMode` flag,
   non-null name) so it is safe to leave in app code permanently.
3. **Detector trace record inside the scenario span**. The at + above
   captures must contain a `sleuth.issue.<stableId>.<severity>`
   instant event whose `ts` lies inside the scenario window. The
   `CaptureHelper.recordIssue(...)` hook in `SleuthController` emits
   this automatically when `captureMode: true` AND the detector fires
   during the captured scenario. The below capture must NOT contain
   one (sub-threshold guard).

The `tool/wrap_capture.dart` CLI sets `schemaVersion: "v1"`
automatically, so step 1 is free as long as you wrap via the tool.
Steps 2 and 3 require the app to run with `captureMode` flipped on —
see step **0** below.

## 0. Prerequisites

Confirm the host environment matches the pinned matrix:

```
fvm flutter --version    # major.minor must match approvedFlutterMajorMinor (3.41.x)
```

If it doesn't, `fvm use <pinned-version>` before recording. Mismatches
are rejected at parse time, not at audit time, so a wrong-Flutter
capture will fail `ProfileCaptureSchema.parseFile` with a precise
error message.

Plug in a device from `ProfileCaptureSchema.approvedDevicePairs` (as
of v0.18.0: iPhone 13 mini / iOS 17.6.1, iPhone 12 / iOS 17.5,
Pixel 7 / Android 14). The device + OS pair must match — membership in
each set independently is not enough.

## 1. Launch in profile mode WITH capture mode

```
cd example
fvm flutter run --profile -d "iPhone 12" \
  --dart-define=SLEUTH_CAPTURE_MODE=true
```

The example app reads `bool.fromEnvironment('SLEUTH_CAPTURE_MODE')` in
`main.dart` and forwards it to `SleuthConfig(captureMode: ...)`. With
the flag off, `Sleuth.markScenarioBegin/End` and
`CaptureHelper.recordIssue` are silent — your capture will be missing
both the scenario span and the detector trace record, and
`validateBracket` will reject it with a precise error.

If you're capturing from your own app instead of the example,
plumb the flag through your own `SleuthConfig` the same way:

```dart
const captureMode = bool.fromEnvironment('SLEUTH_CAPTURE_MODE');
runApp(Sleuth.track(
  child: const MyApp(),
  config: SleuthConfig(
    captureMode: captureMode,
    // CRITICAL: deep debug instrumentation flips Flutter's
    // `debugProfileBuildsEnabledUserWidgets`, which switches BUILD
    // events to async `b/e` (no `dur`). HeavyCompute /
    // FrameTiming detectors require sync `X` BUILD events, so
    // capture mode must turn deep instrumentation OFF.
    enableDebugCallbacks: !captureMode,
    enableDeepDebugInstrumentation: !captureMode,
    /* ... */
  ),
));
```

## 2. Open DevTools, clear the timeline

DevTools opens automatically when `flutter run` starts. Switch to the
Performance tab. Let the app reach steady state (route to your
capture screen, dismiss any first-frame jank), then click the trash
icon to clear the timeline buffer.

This is important. Cold-start work emits thousands of trace events;
saving without clearing produces a 50 s capture that hides the
scenario in noise and trips the AB-1 cross-check.

## 3. Run each leg

For each of the three legs (`below`, `at`, `above`), tap the matching
preset button on the capture helper screen. The screen:

- Calls `Sleuth.markScenarioBegin('<detector>_<leg>')`.
- Runs the deterministic workload synchronously (so HeavyCompute /
  similar Build-phase detectors observe it).
- Calls `Sleuth.markScenarioEnd('<detector>_<leg>')`.
- Dwells 1.5 s before logging "safe to Export" so the VM Timeline has
  time to drain the trailing scenario marker + issue trace record
  into DevTools' buffer.

When the log line appears, do **not** tap a different leg's button.
Save the timeline first; then come back for the next leg.

For the **HeavyCompute** capture screen specifically:
- **Below** target = 3 ms. Detector stays silent (threshold is 8 ms).
  Band: ms < 7.9 (any sub-threshold value works).
- **At** target = 10 ms. Band: `[8, 12]` ms.
- **Above** target = 13.5 ms. Band: `[12.1, 15]` ms; stays clear of
  the 16 ms critical threshold.

The at-band is `[8, 12]` (atTolerance = 0.50), not the schema-default
`[8, 8.8]` (atTolerance = 0.10). The default is unreachable on
iPhone 12 — per-scenario variance is ±25–30 % from thermal/JIT/scheduler
noise, so a 10 % band fails on every leg. The `HeavyComputeDetector`
metadata declares `bracketAtTolerance: 0.50` and
`aboveCeilingMultiplier: 1.875` to align the audit gate with this
reality. If you re-tune the ms targets, update the metadata in the
same change — `bracketAtTolerance` and `aboveCeilingMultiplier` are
the source of truth that CI enforces.

The screen calibrates iteration count on open (~500 k iteration
warmup) and runs a 5-pass auto-tune before each leg's scenario span,
recomputing the rate from each prior run's measurement. Watch the
device log for `✓ IN-BAND` per leg before saving the snapshot —
out-of-band runs must NOT be saved (the schema rejects them at audit
time, and the UI says so explicitly).

## 4. Save the raw timeline

In DevTools: **Performance → Save timeline JSON** (or "Save snapshot"
on recent DevTools — see conversion note below). Save to a workspace
directory (NOT `test/validation/captures/` — that's for wrapped
captures only):

```
~/Desktop/sleuth_captures/heavy_compute_below.raw.json
~/Desktop/sleuth_captures/heavy_compute_at.raw.json
~/Desktop/sleuth_captures/heavy_compute_above.raw.json
```

The `.raw.json` suffix is a convention to keep raw exports visually
distinct from wrapped captures — the schema doesn't enforce it.

### DevTools snapshot vs. Chrome Trace JSON

Recent DevTools versions export a **snapshot** — a JSON file with
top-level keys `devToolsSnapshot`, `performance.traceBinary` (a
Perfetto protobuf serialised as a list of bytes). The schema
requires Chrome Trace Event Format (`traceEvents` at the top
level). Convert with Perfetto's `traceconv`:

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

The resulting `leg.raw.json` has `traceEvents` at the top level and
is ready for `tool/wrap_capture.dart`. If your DevTools build still
offers a "Save timeline JSON" option that produces Chrome Trace
Event Format directly, use it and skip this conversion step.

## 5. Wrap each raw export with `tool/wrap_capture.dart`

Don't hand-edit the JSON. Use the CLI:

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
  --flutter-version 3.41.4
```

Repeat for `_at` and `_above`. Use the **measured** ms reported by
the capture screen as `--magnitude-observed`, not the target — your
device may run a few percent fast or slow. Pick `min` / `max` to
straddle observed by ±1 ms (or whatever band you reproducibly hit on
back-to-back captures).

The tool refuses to:

- Write `--output` to the same path as `--input` (would destroy the
  raw export).
- Overwrite an existing wrapped capture without `--force`.
- Re-wrap a capture that already contains `sleuthMetadata` (would
  silently double-wrap).
- Wrap when `--magnitude-observed` disagrees with the BUILD-event
  duration recorded inside the scenario span by more than ±10 %.
  This is the BUILD cross-check — detectors classify on BUILD ms,
  not on Stopwatch-measured inner-loop ms, so the wrapped capture's
  `expectedMagnitude.observed` must match the signal the detector
  would actually see. The error message reports the BUILD ms; pass
  that value as `--magnitude-observed` (and re-derive `min`/`max`
  around it). `--force` overrides this check, but it is NOT
  recommended: a forced mismatch produces a capture whose synthetic
  trace record severity may not match what `validateBracket(...
  severityLabel: ...)` would accept on the same magnitude.

Each refusal exits non-zero with a precise stderr message.

## 6. Update the detector's `DetectorMetadata`

For HeavyCompute, edit `lib/src/detectors/heavy_compute_detector.dart`:

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
      // 1.875 keeps the above-ceiling at 15 ms so the artifact stays
      // 1 ms clear of the 16 ms critical-tier boundary.
      aboveCeilingMultiplier: 1.875,
      coveredStableIds: {'heavy_compute'},
      coveredThresholds: {'heavy_compute.warning'},
    );
```

`bracketStableId` + `bracketSeverityLabel` are required at
`runtimeVerified` since v0.18.0. Without them the audit fails with a
precise error before reaching `validateBracket`.

## 7. Run the audit

```
fvm flutter test test/validation/detector_metadata_audit_test.dart
fvm flutter test
```

The detector audit calls `checkBracketValidation(... requireTraceRecord:
true, bracketStableId: ..., bracketSeverityLabel: ...)`, which routes
through `ProfileCaptureSchema.validateBracket(...
requireDetectorTraceRecord: true)`. Failure messages name the failing
file and the specific contract violation.

Common failure modes:

| Error message | Meaning |
|---|---|
| `Capture missing or stale 'sleuthMetadata.schemaVersion'` | The triad was wrapped with a hand-edit that omitted the field, or with a v0.16.x version of `wrap_capture.dart`. Re-wrap. |
| `Missing detector trace record in at capture` | The detector didn't fire during the captured scenario. Check `--dart-define=SLEUTH_CAPTURE_MODE=true` was set, the at-target ms was actually exceeded (it's strict-greater for HeavyCompute), and the scenario span was long enough to bracket the issue emission. |
| `Unexpected detector trace record in below capture` | The below leg captured a measurement above the threshold. Re-record with a smaller target (the calibration may have been off; recalibrate). |
| `Bracket violation: ms 'above' observed (X) exceeds ceiling (Y)` | The above leg ran longer than `threshold × aboveCeilingMultiplier`. Re-record with a smaller target or widen `aboveCeilingMultiplier` (only if doing so doesn't bracket an adjacent severity tier). |
| `Inflated detector trace records in <leg> capture: expected each event to carry a unique detectedAtMicros arg` | The capture contains N records sharing fewer than N distinct `detectedAtMicros` values inside the scenario span. Producer-side dedup (v0.18.1+) stamps a unique value per emission, so this shape indicates either capture replay/forgery OR a pre-v0.18.1 binary without the dedup guard. Re-record on v0.18.1 or later. |

### Multi-leg recovery (only when needed)

`Sleuth.markScenarioBegin` automatically resets producer-side
capture state (the dedup-emission set AND per-detector record
buffers like `NetworkMonitor.clearRecords`) so a single-screen
multi-leg flow (Below → At → Above on one screen) does not leak
leg N records into leg N+1 emissions. **You should not need to
restart the app between legs.**

The auto-reset only fires when capture mode is enabled (the same
`SleuthConfig.captureMode` gate that controls `markScenarioBegin`
emission). Production app sessions skip the reset because they
also skip the scenario marker emission entirely.

> **`clearRecords` side effects to be aware of.** The auto-reset
> calls `NetworkMonitorDetector.clearRecords()` which (a) stamps
> a sentinel timestamp so any in-flight HTTP request started BEFORE
> `markScenarioBegin` gets dropped on completion, (b) clears the
> in-flight request map, and (c) cancels the frequency-evaluation
> timer (rebuilt by the next request). For the standard capture
> pattern (markScenarioBegin → fire workload → markScenarioEnd)
> this is correct. **If your capture procedure issues a warmup
> probe BEFORE markScenarioBegin and expects the probe's record
> in the capture, the warmup record will be dropped.** Move the
> warmup AFTER `markScenarioBegin` or skip the auto-reset by
> calling the underlying primitives manually.

If a leg shows OUT-OF-BAND or "Missing detector trace record"
*despite* using v0.18.1+ and following the procedure above:

1. Note which leg failed and its observed magnitude.
2. Kill the app from the iOS app switcher (full background swipe-up).
3. Cold-launch from the home screen icon (re-establishes VM+ mode).
4. Re-tap from leg 1 in order.

Cold-launch is a fallback only. It is not a substitute for the
v0.18.1 producer dedup + scenario-begin reset hooks — those handle
the common case. Cold-launch covers cases where the VM service
state itself is wedged (e.g. after a thermal throttle, after a
crashed background isolate, after a dropped USB wireless link).

## Cheat sheet — required sleuthMetadata fields (v0.18.0)

`tool/wrap_capture.dart` produces this shape automatically:

```jsonc
{
  "traceEvents": [ /* Chrome Trace Event Format, from DevTools */ ],
  "sleuthMetadata": {
    "schemaVersion":   "v1",                        // NEW in v0.18.0
    "device":          "iPhone 12",                 // pinned
    "deviceOsVersion": "iOS 17.5",                  // pinned (pair-matched)
    "flutterVersion":  "3.41.4",                    // pinned major.minor
    "captureCommand":  "fvm flutter run --profile -d <device>",
    "scenario":        "human label",
    "expectedMagnitude": {
      "min":      5,
      "observed": 6,
      "max":      7,
      "unit":     "ms"
    },
    "captureDate":     "2026-04-25T...Z"
  }
}
```

The `traceEvents` array must additionally contain (placed there by
the runtime, not by the wrapper):

- An instant event named `sleuth.scenario.begin` (`ph: i`).
- An instant event named `sleuth.scenario.end` (`ph: i`).
- For at + above legs only: an instant event named
  `sleuth.issue.<stableId>.<severity>` (`ph: i`) with a `ts` inside
  the scenario span. The CaptureHelper emits this automatically; you
  don't synthesise it.

## Why hand-wrapping was retired

Pre-v0.18.0 the procedure had a step "wrap the JSON with a
`sleuthMetadata` block at the top level", which meant the recorder
encoded whatever shape they remembered from the schema. That created
a same-author tautology vector for the audit gate: a malformed
wrapper would fail parse, but a *plausibly-wrong* wrapper (right
fields, wrong values) could pass parse and fail bracketing in
confusing ways at audit time. `tool/wrap_capture.dart` produces the
exact shape the schema expects, so wrapper drift is impossible.
