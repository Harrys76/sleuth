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
of v0.23.0: iPhone 12 / iOS 17.5 only — see
`doc/reference_devices.md` for the matrix policy + Android coverage gap).
The device + OS pair must match — membership in each set independently
is not enough.

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

### Multi-axis raises (v0.19.8+)

When a single family needs more than one runtimeVerified-quality axis
(e.g. PlatformChannel `platform_channel_traffic` runs both a frequency
axis in calls/sec AND a cumulative-duration axis in ms/window), declare
the canonical axis via the top-level fields and additional axes via
`additionalBrackets: [BracketSpec(...), ...]`. `BracketSpec` is exported
from the public barrel — import alongside `DetectorMetadata` and
`EvidenceTier`:

```dart
import 'package:sleuth/sleuth.dart';

DetectorMetadata get validationMetadata => const DetectorMetadata(
      tier: EvidenceTier.runtimeVerified,
      rationale: '...',
      reproducerPath: 'test/validation/platform_channel_reproducer_test.dart',
      // Canonical axis — frequency.
      profileCapturePaths: [
        'test/validation/captures/platform_channel/platform_channel_traffic_below.json',
        'test/validation/captures/platform_channel/platform_channel_traffic_at.json',
        'test/validation/captures/platform_channel/platform_channel_traffic_above.json',
      ],
      bracketStableId: 'platform_channel_traffic',
      bracketSeverityLabel: 'warning',
      bracketThreshold: 20,
      bracketUnit: 'events',
      bracketAtTolerance: 0.50,
      aboveCeilingMultiplier: 1.95,
      observedAxisArgKey: 'observedCount',
      coveredStableIds: {'platform_channel_traffic'},
      coveredThresholds: {'platform_channel_traffic.warning'},
      // Second axis — cumulative duration. Same family, distinct argKey.
      additionalBrackets: [
        BracketSpec(
          stableId: 'platform_channel_traffic',
          severityLabel: 'warning',
          threshold: 8,
          unit: 'ms',
          coveredThresholds: {'platform_channel_traffic.warning'},
          profileCapturePaths: [
            'test/validation/captures/platform_channel/'
                'platform_channel_duration_below.json',
            'test/validation/captures/platform_channel/'
                'platform_channel_duration_at.json',
            'test/validation/captures/platform_channel/'
                'platform_channel_duration_above.json',
          ],
          atTolerance: 0.30,
          aboveCeilingMultiplier: 2.0,
          observedAxisArgKey: 'cumulativeDurationUs',
          requireUniqueDetectedAtMicros: true,
          requireDetectorTraceRecord: true,
        ),
      ],
    );
```

Audit invariants enforced:

- Cross-spec uniqueness on `(stableId, observedAxisArgKey)`. The example
  above is accepted because the two specs share a stableId but use
  distinct argKeys (`observedCount` vs `cumulativeDurationUs`). Two
  specs with the same `(stableId, argKey)` would double-count the same
  trace event and are rejected.
- Empty `additionalBrackets: []` is rejected. Encode "no additional
  axes" as `null` (or omit the field).
- Each spec's `profileCapturePaths` must contain exactly 3 entries
  (below / at / above), validated by `validateBracketSpec` independently.
- Every runtimeVerified family declared via `perStableIdTier` must be
  covered by either the canonical bracket OR a `BracketSpec.stableId`
  match — a `perStableIdTier` raise without bracket evidence fails
  audit.

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

## MemoryPressure heap_growing capture (v0.19.3)

`MemoryPressureDetector.heap_growing` differs from HeavyCompute and
NetworkMonitor in two structural ways:

1. **Wall-clock-bound emission.** The detector requires a regression
   slope > 512 KB/s sustained ≥ 10 s across `_heapSamples` (60-entry
   queue × 500 ms heap-poll cadence = 30 s window). `flushTimelineNow`
   cannot collapse the sustained window — wall-clock IS the
   rate-limiting axis.
2. **VM trace ring buffer overflow risk.** 30 s of heavy allocation
   under default Dart + Embedder + GC streams generates tens of
   thousands of paint/raster/frame/GC events and overflows the
   ~50k-event ring buffer mid-leg, rolling scenario markers off
   before `exportCaptureJson` can read them. The capture screen
   **narrows VM timeline streams to `Dart` only** during the scenario
   span via the new `Sleuth.suspendNonEssentialTimelineStreams()`
   API (restored at scenario end).

**Procedure (uses `example/lib/demos/memory_pressure_capture_screen.dart`):**

1. Launch wireless debug:
   ```bash
   cd example && fvm flutter run --profile -d "iPhone 12" \
     --dart-define=SLEUTH_CAPTURE_MODE=true
   ```
   (USB-tethered profile mode does NOT work — VM service port not
   routed. Wireless debug or simulator only.)
2. Wait ≥ 5 s after app launch (lets MemoryPressure detector's 3 s
   warmup elapse).
3. Navigate: Memory & GC → MemoryPressure Capture Helper.
4. Tap **Calibrate** (1 s allocation warmup pins `_bytesPerMs`).
5. Per leg (Below / At / Above):
   - Tap leg button.
   - Allocation runs ~30 s + 600 ms pre-end dwell + 800 ms post-end
     dwell. Total ~31.5 s per attempt.
   - Watch for `[<leg>] capture stashed (~1.2 MB chars)` log line —
     success path; `Sleuth.exportCaptureJson` already composed the
     wrapped JSON immediately after `markScenarioEnd`.
   - Tap **Export last leg** → post-capture validator parses stashed
     JSON, verifies expected `sleuth.issue.heap_growing.warning`
     count inside scenario span (0 for below, 1 for at/above), copies
     to iOS clipboard on pass.
6. Paste clipboard contents into Notes / Mail / AirDrop → send to Mac.
   Save as `heap_growing_${leg}.json` under
   `test/validation/captures/memory_pressure/`.
7. Repeat for 3 legs.

**Common failures + diagnostic:**

`Sleuth.exportCaptureJson(...)` logs the exact null-return path via
`debugPrint`. Check `flutter run` terminal OR Mac Console.app filtered
by `Sleuth.exportCaptureJson`:

| debugPrint message | Cause | Fix |
|---|---|---|
| `VM service client {not initialised\|disconnected}` | VM service dropped (wireless flap, iOS auto-lock backgrounded) | Disable iOS auto-lock; full kill + relaunch |
| `VM service returned 0 timeline events` | VM-service plumbing failure | Restart device; verify wireless debug pairing |
| `scenario markers not found (begin=null, end=null)` | Ring buffer overflow rolled markers off | Stream-narrowing should prevent this; if it persists, lengthen post-end dwell or split allocation phase |

**Validator-rejected exports** (Export REJECTED — expected 1 found 0):

- **Count 0 (detector did not fire):** regression slope diluted below
  512 KB/s threshold by pre-scenario flat samples in `_heapSamples`
  window. **Fix already wired:** `markScenarioBegin` calls
  `_memoryPressure.reset()` so the regression starts fresh on
  scenario allocation. If still 0, calibration drift produced too-low
  rate — recalibrate and retry leg.
- **Count ≥ 2 (sustained window broke):** slope dipped below
  threshold mid-leg then resumed. Each `_sustainedGrowthStart` reset
  emits a new trace record with distinct dedup identity. Retry the
  leg.

**iOS auto-lock during 30 s legs.** Default Settings → Display &
Brightness → Auto-Lock often defaults to 30 s — exactly the leg
duration. Set to **Never** during capture session; restore after.
Without this, the screen auto-locks mid-leg, app may background, VM
service connection drops.

## PlatformChannel platform_channel_traffic capture (v0.19.4)

`PlatformChannelDetector.platform_channel_traffic` differs from both
HeavyCompute and MemoryPressure in three structural ways:

1. **Short scenario span (~3.2 s).** The detector evaluates on a
   1 s window boundary; the capture screen runs ~1.5 s of method
   calls + 1500 ms post-allocation dwell + 200 ms barrier. The
   1500 ms dwell covers three detector poll cycles (500 ms cadence)
   plus emission landing margin so the trace record reliably lands
   inside the scenario span even when the eval boundary falls late
   in the allocation phase. No stream narrowing needed — the span
   stays well inside ring-buffer capacity even with default Dart
   + Embedder + GC streams enabled.
2. **Parallel `Future.wait` batches (NOT sequential awaits).** iOS
   `MethodChannel` round-trip latency is ~12-25 ms over USB and
   30-80 ms over wireless. Sequential awaits would cap the
   effective send rate at ~12-80 calls/sec, making the above-band
   target (35 calls/sec) unreachable on wireless. The capture
   screen fires K parallel `invokeMethod` Futures per 200 ms tick
   so per-tick cost ≈ slowest single round-trip.
3. **`debugProfilePlatformChannels` framework flag.** Real
   `MethodChannel.invokeMethod` calls only emit `Platform Channel
   send …` timeline events when this top-level Flutter flag is
   true. The capture screen sets it per-leg in try/finally so the
   flag does not leak into post-leg live monitoring (which would
   pollute every subsequent unrelated channel call with timeline
   events at full rate).

**Procedure (uses `example/lib/demos/platform_channel_capture_screen.dart`):**

1. Launch wireless debug:
   ```bash
   cd example && fvm flutter run --profile -d "iPhone 12" \
     --dart-define=SLEUTH_CAPTURE_MODE=true
   ```
   (USB-tethered profile mode does NOT work — same VM-service
   constraint as MemoryPressure.)
2. Wait ≥ 3 s after app launch (lets VM service connection settle).
3. Navigate: Network & I/O → PlatformChannel Capture Helper (v0.19.4).
4. Per leg (Below / At / Above) — no calibration phase, the rate is
   set directly by the batch geometry:
   - Tap leg button.
   - Method calls run for 1.5 s + 1500 ms post-allocation dwell +
     200 ms barrier. Total ~3.2 s per attempt.
   - Watch for `[<leg>] capture stashed` log line — success path;
     `Sleuth.exportCaptureJson` already composed the wrapped JSON
     immediately after `markScenarioEnd`.
   - Tap **Export last leg** → post-capture validator parses
     stashed JSON, verifies expected
     `sleuth.issue.platform_channel_traffic.warning` count inside
     scenario span (0 for below, 1 for at/above), copies to iOS
     clipboard on pass.
5. Paste clipboard contents into Notes / Mail / AirDrop → send to
   Mac. Save as `platform_channel_traffic_${leg}.json` under
   `test/validation/captures/platform_channel/`.
6. Repeat for 3 legs.

**Bands (tied to v0.19.4 metadata: threshold=20, atTolerance=0.50,
aboveCeilingMultiplier=1.95):**

- below: 1 ≤ calls/sec ≤ 19 (sub-threshold; detector silent;
  schema requires magnitudeMin > 0 so bpsMin=1, not 0)
- at: 20 ≤ calls/sec ≤ 30 (atTolerance 0.50 → [T, 1.5×T])
- above: 31 ≤ calls/sec ≤ 39 (above-ceiling 39 strictly under 41-
  call critical-escalation boundary so above-leg cannot ambiently
  bracket the critical tier)

**Validator-rejected exports** (Export REJECTED — expected 1 found 0):

- **Count 0 (detector did not fire):** likely cause is parser
  dropped channel events because `debugProfilePlatformChannels`
  was not enabled — verify the framework flag is true at leg
  start (the capture screen sets it in try/finally; manual flips
  during leg run are the only way this can be wrong). Secondary
  cause: iOS coalesced parallel calls and rate stayed below
  20/sec — recheck batch geometry.
- **Count ≥ 2 (cooldown failed):** scenario span extended into a
  second 1 s evaluation cycle and the cooldown counter did not
  suppress. Retry the leg.

**Channel reuse.** The capture screen invokes
`MethodChannel('sleuth_demo_channel').invokeMethod('ping')`. The
channel and handler are registered at app launch in
`example/ios/Runner/AppDelegate.swift:21-25` (handler returns
`result(nil)` for every call). No new native code needed.

**Fixture provenance.** The three checked-in v0.19.4 captures under
`test/validation/captures/platform_channel/` were recorded under
the prior 800 ms dwell (scenario spans ~2.43-2.50 s in the trace
events). Schema validation passes either way — the bracket math
checks magnitude against threshold, not span duration. Future
re-captures under the 1500 ms dwell produce ~3.2 s spans without
breaking the audit gate. The dwell extension was added after the
initial capture set landed because the at-leg's first capture had
only 43 ms scenario-end headroom; re-recording for cosmetic span
alignment is unnecessary as long as schema validation continues
to pass.

**Pre-v0.19.5 captures and the observed-axis cross-check.** v0.19.5
introduces a detector-observed axis cross-check
(`expectedMagnitude.observed` vs trace-event `args.observedCount`,
±25% tolerance). v0.19.4 captures lack the `observedCount` arg and
the cross-check is skipped per-record (backward compatible). Future
re-captures under v0.19.5+ binaries carry the arg and exercise the
check.

## FrameTiming jank_detected capture (v0.19.6 plumbing — staged for v0.19.7)

`FrameTimingDetector` is a `runtime`-lifecycle detector — it ingests
frames via `SchedulerBinding.addTimingsCallback`, NOT VM Timeline events.
Detector emission timing for the audit gate's `requireTraceRecord`
invariant is gated on `_recordIssuesForCapture` running over the
runtime-detector's ephemeral `_issues[]`. Two paths reach that:

* scan loop tick (`scanInterval` cadence) — non-deterministic relative
  to scenario span boundaries.
* `Sleuth.flushTimelineNow()` — deterministic; flush also iterates ALL
  detectors regardless of lifecycle and calls
  `_recordIssuesForCapture(const <BaseDetector>{})`
  (`SleuthController` line 2806, batch path; line 2990, flush path).

The capture screen MUST call `flushTimelineNow()` immediately before
`markScenarioEnd` so the runtime-detector's per-frame emission lands
inside the scenario span deterministically.

### Capture-mode warmup short-circuit

`FrameTimingDetector` defaults to `warmupDuration: Duration(seconds: 3)`
which suppresses jank evaluation during app warmup (shader compilation,
route init, Dart VM JIT). A 4-second bracket scenario inside that gate
would observe the buffer's post-warmup tail only and miss the calibrated
jank window.

v0.19.6 adds `FrameTimingDetector.captureMode` plumbed from
`SleuthConfig.captureMode`. When the config flag is `true`,
`_isPastWarmup()` short-circuits to `true` regardless of
`warmupDuration` / `warmupFrameCount`. Never engaged in production app
sessions — the dart-define gate makes the wiring explicit.

### Per-leg sequence (FrameTimingCaptureScreen)

```
markScenarioBegin(name)                          // resets buffer + warmup
└── injects spin-loop UI-thread workload (Ticker) immediately, no warmup wait
└── 4 s scenario span elapses (240-frame buffer fills to capacity)
└── injector.stop()
└── 200 ms frame-settle barrier
└── Sleuth.flushTimelineNow()                    // drains _issues[] via _recordIssuesForCapture
markScenarioEnd(name)
└── 800 ms post-end barrier (mirrors MemoryPressure proven pattern)
exportCaptureJson(...)                           // compose-then-stash
└── post-leg validator: ≥1 jank_detected.warning
                       AND zero sustained_jank.critical (severe co-fire would invalidate axis)
```

Critical-co-fire suppression: above-leg spin (8 ms) plus baseline
~16 ms = ~24 ms worst-frame, well under the 33 ms severe threshold.
Hard cap on retry-bumped spin (11 ms) keeps the worst-frame budget
from drifting into severe territory.

### 60 Hz pre-flight

The bracket axis (jank-frames in 240-frame buffer) is calibrated against
the iPhone 12 / iPhone SE 60 Hz frame budget (16.67 ms). On 120 Hz
devices (iPhone 12 Pro, iPad Pro, Pixel 8 Pro) the budget is 8.33 ms,
which produces a different jank/percentile distribution at the same
spin-loop calibration. The screen rejects non-60 Hz devices in pre-flight
so the captures stay comparable across runs.

## NetworkMonitor large_response + request_frequency capture (v0.19.9)

Two more families raise to runtimeVerified through `additionalBrackets`,
both recorded via `NetworkMonitorCaptureScreen` with a mode dropdown.

**large_response (bytes axis).** Loopback `HttpServer` dispatches sized
payloads via `?bytes=N`. Threshold 1 MiB; atTolerance 0.10 (deterministic
loopback bytes); aboveCeilingMultiplier 2.0 → ceiling 2 MiB << 5 MiB
critical:

| Leg | Bytes target | Lands in |
|---|---|---|
| Below | ~800 KiB | < 1 MiB (silent) |
| At | ~1.05 MiB | [1 MiB, 1.1 MiB] |
| Above | ~1.5 MiB | (1 MiB, 2 MiB], > at_observed |

Detector exports `extraTraceArgs.observedResponseBytes` =
content-length; audit gate cross-checks against capture magnitude.

**request_frequency (events axis).** `Future.wait` parallel batches
drive the trailing-5 s window count above 30. Threshold 30; atTolerance
0.50 (iOS scheduling jitter; mirrors v0.19.4 PlatformChannel);
aboveCeilingMultiplier 2.0 → ceiling 60:

| Leg | Target rate | Peak count |
|---|---|---|
| Below | ~3 req/s | < 30 (silent) |
| At | ~7 req/s | [30, 45] |
| Above | ~10 req/s | (30, 60], > at_observed |

Detector emits warning severity only (no critical tier today). Schema
filters trace records by event-name match
(`sleuth.issue.<stableId>.<severity>`), so a future critical raise
scopes correctly without metadata change.

5.5 s scenario span + 800 ms post-end barrier overflows timeline ring
buffer under load — wrap the leg with
`Sleuth.suspendNonEssentialTimelineStreams()` /
`resumeAllTimelineStreams()` to narrow streams to `Dart` only.

Both emissions export their observed axis to `extraTraceArgs` and
stamp `dedupIdentityMicros` (matches v0.18.1+ producer-dedup contract
required by `requireUniqueDetectedAtMicros: true`).

**v0.19.10+ producer pattern.** request_frequency below-leg's
`expectedMagnitude.observed` reads from
`Sleuth.networkMonitor.lastObservedPeakCount` after
`flushFrequencyEvaluation()` (peak-only recompute, idempotent — issue
emission stays gated to the controller's `_evaluate` path, so repeat
flushes cannot mint duplicate trace records). Schema's
`_requireNoIssueTraceRecord` leaves the below-leg axis unchecked, so
plan-not-measured was a silent-evidence-quality gap; the producer
now closes it client-side.

Capture screen also calls `Sleuth.flushTimelineNow(timeout: 2s)`
between the peak read and `markScenarioEnd` so pending detector
emissions drain into the VM trace buffer before the scenario closes
(matches the HeavyCompute / FrameTiming barrier pattern). And passes
`bracketStableId` + `bracketSeverityLabel` to
`Sleuth.exportCaptureJson` so a missing or unexpected in-span
emission is refused with a debugPrint diagnostic before JSON hits
the clipboard.

## GpuPressure raster_dominance — runtimeVerified blocked

A `runtimeVerified` raise of `GpuPressureDetector.raster_dominance` is
not viable on the current detector implementation. Three structural
blockers, any of which alone is sufficient to disqualify the ratio
bracket:

1. **Ratio axis unforceable on iOS profile mode.** Steady-state UI cost
   ~3-5 ms/frame vs single-filter raster ~2 ms/frame produces ratio
   ~0.5; clearing `> 2.0` threshold requires a 6+ stacked-filter
   workload, and the above-band would still be flaky under iOS
   scheduling jitter.
2. **No independent schema witness.** `ProfileCaptureSchema._crossCheckTraceVsObserved`
   skips for non-time units (the trace cannot certify a ratio).
   A `'ratio'` bracket compared against detector-emitted
   `observedRasterRatio` is self-certifying.
3. **Detector splices across polls.** `processTimelineData` updates
   `_lastRasterUs` and `_lastUiUs` independently (each only when its
   field is non-empty), so ratios computed in `_evaluate` can pair a
   fresh raster numerator with a stale UI denominator from a prior
   poll.

Future raster-related raises should target an absolute-duration axis
(engages AB-1 cross-check) and require detector logic that evaluates
on a single-poll snapshot rather than last-seen fields.

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
