import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Capture helper for the planned `runtimeVerified` per-family-tier raise on
/// `MemoryPressureDetector.heap_growing` **WARNING tier** (threshold =
/// 512 000 bytes/sec sustained ≥ 10 s).
///
/// **VM-service connection required.** This screen produces captures that
/// satisfy `ProfileCaptureSchema.validateBracket(...
/// requireDetectorTraceRecord: true, ...)` ONLY when SleuthController's
/// VmServiceClient is connected — i.e. the run is in VM+ mode, not FRAME
/// mode. USB-tethered iPhone profile-mode is FRAME mode (the VM service
/// port is not routed to the host); use **wireless debugging** via Xcode →
/// Window → Devices and Simulators → "Connect via network", or run on the
/// iOS simulator.
///
/// In FRAME mode, the `MemoryPressureDetector` (vmOnly lifecycle) never
/// receives heap samples, so `_recordIssuesForCapture` never emits the
/// required `sleuth.issue.heap_growing.warning` trace record. The schema
/// audit will reject the resulting capture as "Missing detector trace
/// record" — that is the correct behavior.
///
/// **Why the procedure differs from `HeavyComputeCaptureScreen`.**
///
/// HeavyCompute's workload is a synchronous in-build sin/cos loop that
/// completes inside one BUILD timeline event; `Sleuth.flushTimelineNow()`
/// drives detector emission inside the scenario span. heap_growing has
/// no equivalent shortcut: the detector requires ≥ 4 heap samples plus
/// ≥ 10 s of wall-clock with regression slope > 512 000 bytes/sec.
/// Heap samples arrive on a 500 ms VM-poll cadence, so the scenario span
/// MUST elapse real wall-clock time. `flushTimelineNow()` cannot collapse
/// the sustained window — wall-clock is the rate-limiting axis.
///
/// **Procedure per leg:**
///
///   1. `cd example && fvm flutter run --profile -d DEVICE \
///         --dart-define=SLEUTH_CAPTURE_MODE=true`.
///   2. Wait ≥ 5 s after app launch (lets the detector's 3 s heap-trend
///      warmup elapse and the rolling sample window stabilize).
///   3. Tap **Calibrate** — runs a 1-second allocation warmup and pins
///      `_bytesPerMs` for the device's current GC + thermal state.
///   4. Tap a leg (Below / At / Above). Workload runs ≥ 30 s allocation
///      (fills the detector's 30 s regression window with ramp samples)
///      followed by ≥ 600 ms dwell, then `markScenarioEnd`.
///   5. Wait for "ready to Export" log line.
///   6. Tap **Export last leg**. The wrapped capture JSON is parsed to
///      verify EXACTLY ONE `sleuth.issue.heap_growing.warning` trace
///      record exists inside the scenario span (zero or two are both
///      capture-quality failures and abort export). On success, JSON is
///      copied to the iOS clipboard.
///   7. Paste into Notes / Mail / AirDrop, save as
///      `heap_growing_${leg}.json` under
///      `test/validation/captures/memory_pressure/`.
///
/// **Bands enforced by this screen** (tied to the schema settings the
/// `MemoryPressureDetector` metadata declares once `runtimeVerified`):
///
///   below:   0 < bytes/sec < 512 000   (sub-threshold; detector silent)
///   at:      512 000 ≤ bytes/sec ≤ 768 000  (atTolerance 0.50 → [T, 1.5×T])
///   above:   800 000 ≤ bytes/sec ≤ 1 024 000  (above-ceiling 2.0 × T)
///
/// The above-band screen-side floor (800 000) sits one tick above the at-
/// band's schema-allowed upper (768 000) so at and above magnitudes stay
/// disjoint even though the schema's strict-greater-than at-upper formally
/// allows above to start at 512 001.
///
/// **Retention reset between legs.** Each leg's allocation runs into a
/// fresh `_retainedAllocations` list — the prior leg's retained bytes are
/// released so the heap pre-state is consistent across captures. Without
/// this reset, leg N's regression starts on an inflated pre-allocated
/// heap and the detector's slope measurement reflects accumulated
/// allocation, not the current leg's rate.
///
/// **Retry budget**: 5 retries per leg before the screen surfaces an
/// abort-with-diagnostic. iPhone GC variance is wider than the
/// HeavyCompute CPU variance — calibration drift is more aggressive.
class MemoryPressureCaptureScreen extends StatefulWidget {
  const MemoryPressureCaptureScreen({super.key});

  @override
  State<MemoryPressureCaptureScreen> createState() =>
      _MemoryPressureCaptureScreenState();
}

// Detector threshold (warning tier).
const _warningThresholdBytesPerSec = 512000;

// Per-leg target rates (bytes/sec). Mid-band picks absorb iPhone GC
// variance (±20–30 %) and stay disjoint at the at/above boundary.
//
//   below band [0, 511 999]    → target 350 000 (±20 % keeps [280k, 420k]
//                                 well below 512k threshold)
//   at    band [512 000, 768 000] → target 640 000 (±15 % keeps
//                                   [544k, 736k] inside band)
//   above band [800 000, 1 024 000] → target 920 000 (±10 % keeps
//                                     [828k, 1012k] inside band)
const _belowTargetBps = 350000;
const _atTargetBps = 640000;
const _aboveTargetBps = 920000;

// Allocation runs in 50 ms ticks. Per-tick byte count =
// `_bytesPerMs * _allocationTickMs`. Smaller ticks give smoother slope;
// 50 ms is the minimum that does not flood the event loop on iPhone 12.
const _allocationTickMs = 50;

// Wall-clock budget for the allocation phase. The detector's regression
// slope is computed across `_heapSamples` (60 entries × 500 ms cadence
// = 30 s window), NOT across the scenario span alone. Pre-scenario
// flat samples in the window drag the regression slope below the
// allocator rate — at 11 s allocation, ~38 of 60 samples are still
// idle baseline and the regression dilutes the 640 KB/s allocator
// rate to ~200–300 KB/s, never crossing the 512 KB/s threshold.
//
// 30 s of allocation fills the entire regression window with ramp
// samples so detector slope ≈ allocator rate. Detector then sets
// `_sustainedGrowthStart` once enough ramp samples accumulate (slope
// crosses threshold around the 15–20 s mark inside the scenario) and
// the 10 s sustained-window completes by scenario end.
const _allocationDurationSec = 30;

// Dwell after allocation ends. 600 ms is one heap-poll cycle (500 ms) +
// 100 ms emission landing margin. Without this, markScenarioEnd may
// close the scenario span before the post-cross heap sample fires the
// detector and lands the issue trace record inside the span.
const _postAllocationDwellMs = 600;

// Calibration phase warmup. 1 s at the at-target rate gives a stable
// rate estimate without delaying screen open.
const _calibrationDurationMs = 1000;

const _maxRetriesPerLeg = 5;

class _MemoryPressureCaptureScreenState
    extends State<MemoryPressureCaptureScreen> {
  final List<String> _log = [];
  bool _busy = false;

  // Bytes-per-millisecond rate determined by the calibration warmup.
  // Until set, capture buttons are disabled. Refined after every leg
  // run so subsequent legs adapt to current device state.
  double? _bytesPerMs;

  // Active retain buffer. Cleared at the start of every leg so prior
  // retained allocations do not contaminate the new leg's slope.
  final List<List<int>> _retainedAllocations = [];

  // Retry counter per leg (resets when the leg lands in-band or the
  // operator switches to a different leg).
  _MemoryLeg? _activeRetryLeg;
  int _retryCount = 0;

  // Last completed scenario, captured at the end of the leg run so the
  // Export button knows what scenario name + measured magnitude to pass
  // to `Sleuth.exportCaptureJson`. Cleared when the user re-taps a leg.
  _MemoryLeg? _lastCompletedLeg;
  double? _lastMeasuredBps;

  // Wrapped capture JSON composed immediately after markScenarioEnd
  // and stashed here so the user's tap on Export does not race the VM
  // trace ring buffer rolling the scenario.begin marker out — by the
  // time the operator reads "ready to Export" and presses the button,
  // tens of seconds may have elapsed and the buffer has churned past
  // the scenario span. Compose-then-stash captures the wrapped JSON
  // while the markers are still present.
  String? _stashedCaptureJson;

  bool get _captureModeOn {
    return const bool.fromEnvironment('SLEUTH_CAPTURE_MODE');
  }

  @override
  void initState() {
    super.initState();
    if (!_captureModeOn) {
      _log.add(
        '⚠ captureMode OFF — restart with --dart-define='
        'SLEUTH_CAPTURE_MODE=true to emit scenario markers.',
      );
    }
    if (kReleaseMode) {
      _log.add(
        '⚠ Release-mode build detected. Capture procedure '
        'requires --profile.',
      );
    }
    _log.add(
      'Wait ≥ 5 s after app launch before calibrating — '
      'detector warmup needs to elapse.',
    );
  }

  @override
  void dispose() {
    _retainedAllocations.clear();
    super.dispose();
  }

  Future<void> _calibrate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _log.add('Calibrating allocation rate (1 s)…');
    });
    final calibrationBuffer = <List<int>>[];
    final sw = Stopwatch()..start();
    var totalBytes = 0;
    // Allocate at a generous reference rate (1 MB/s) so the warmup
    // captures GC interleave realistically. Real workload rates derive
    // by scaling `_bytesPerMs`.
    const referenceBytesPerMs = 1000;
    while (sw.elapsedMilliseconds < _calibrationDurationMs) {
      final tickBytes = referenceBytesPerMs * _allocationTickMs;
      calibrationBuffer.add(List<int>.filled(tickBytes ~/ 8, 0xCAFEBABE));
      totalBytes += tickBytes;
      await Future<void>.delayed(
        const Duration(milliseconds: _allocationTickMs),
      );
    }
    sw.stop();
    final actualBps = totalBytes / (sw.elapsedMilliseconds / 1000.0);
    final actualBytesPerMs = totalBytes / sw.elapsedMilliseconds;
    calibrationBuffer.clear();
    if (!mounted) return;
    setState(() {
      _bytesPerMs = actualBytesPerMs;
      _busy = false;
      _log.add(
        'Calibrated: ${actualBytesPerMs.toStringAsFixed(0)} '
        'bytes/ms (≈${(actualBps / 1024).toStringAsFixed(0)} KB/s '
        'over ${sw.elapsedMilliseconds} ms)',
      );
    });
  }

  void _resetRetryIfLegChanged(_MemoryLeg leg) {
    if (_activeRetryLeg != leg) {
      _activeRetryLeg = leg;
      _retryCount = 0;
    }
  }

  Future<void> _runLeg(_MemoryLeg leg) async {
    if (_busy || _bytesPerMs == null) return;
    if (!_captureModeOn) {
      setState(() {
        _log.add(
          '[${leg.label}] ABORT — captureMode is OFF. Restart the app '
          'with `--dart-define=SLEUTH_CAPTURE_MODE=true`. Without it '
          'markScenarioBegin/End are no-ops, no scenario markers reach '
          'the VM trace buffer, and Export will fail with no markers '
          'found. Running the leg now would waste 30 s and emit '
          'nothing.',
        );
      });
      return;
    }
    _resetRetryIfLegChanged(leg);
    if (_retryCount >= _maxRetriesPerLeg) {
      setState(() {
        _log.add(
          '[${leg.label}] retry budget exhausted ($_maxRetriesPerLeg). '
          'Recalibrate or switch leg.',
        );
      });
      return;
    }
    _retryCount++;
    setState(() {
      _busy = true;
      _lastCompletedLeg = null;
      _lastMeasuredBps = null;
      _stashedCaptureJson = null;
      _log.add(
        '[${leg.label}] attempt $_retryCount/$_maxRetriesPerLeg — '
        'target ${(leg.targetBps / 1024).toStringAsFixed(0)} KB/s, '
        'band [${(leg.bpsMin / 1024).toStringAsFixed(0)}, '
        '${(leg.bpsMax / 1024).toStringAsFixed(0)}] KB/s',
      );
    });

    // Reset retention buffer so this leg's slope reflects current
    // allocation only — not residue from prior leg attempts.
    _retainedAllocations.clear();

    // Narrow VM timeline streams to `Dart` only for the scenario span.
    // 30 s of heavy allocation under default streams (Dart + Embedder +
    // GC) generates tens of thousands of paint/raster/frame/GC events
    // and overflows the ~50k-event ring buffer mid-leg, rolling the
    // scenario.begin marker off before exportCaptureJson can read it.
    // Restored on every exit path via the try/finally below.
    await Sleuth.suspendNonEssentialTimelineStreams();
    var streamsSuspended = true;
    try {
      if (!mounted) return;

      Sleuth.markScenarioBegin('memory_pressure_heap_growing_${leg.label}');

      final scaledTickBytes = (leg.targetBps * _allocationTickMs / 1000)
          .round();

      final sw = Stopwatch()..start();
      var totalAllocated = 0;
      while (sw.elapsedMilliseconds < _allocationDurationSec * 1000) {
        _retainedAllocations.add(
          List<int>.filled(scaledTickBytes ~/ 8, 0xDEADBEEF),
        );
        totalAllocated += scaledTickBytes;
        await Future<void>.delayed(
          const Duration(milliseconds: _allocationTickMs),
        );
        if (!mounted) {
          sw.stop();
          return;
        }
      }
      sw.stop();
      final allocationElapsedMs = sw.elapsedMilliseconds;

      // Dwell so the heap-poll cycle that observes the post-threshold
      // sample fires the detector AND `_recordIssuesForCapture` lands
      // the issue trace event BEFORE markScenarioEnd closes the span.
      await Future<void>.delayed(
        const Duration(milliseconds: _postAllocationDwellMs),
      );
      if (!mounted) return;

      Sleuth.markScenarioEnd('memory_pressure_heap_growing_${leg.label}');

      // Post-end barrier before exportCaptureJson: VM service buffer
      // needs to flush the just-emitted scenario.end marker before
      // service.getVMTimeline can return it. Over wireless debug the
      // RPC can otherwise observe a snapshot that pre-dates the end
      // marker, making the controller's pair-finder return null on
      // endTs == null. Mirrors NetworkMonitor's proven 800 ms post-end
      // pattern.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      // Resume streams BEFORE the compose-then-stash + setState block
      // so subsequent live-monitoring (and exportCaptureJson's own VM
      // RPCs) sees default coverage. Cleared flag prevents the finally
      // block from issuing a redundant resume RPC.
      await Sleuth.resumeAllTimelineStreams();
      streamsSuspended = false;
      if (!mounted) return;

      final measuredBps = totalAllocated / (allocationElapsedMs / 1000.0);
      final inBand = leg.isBpsInBand(measuredBps);

      // Adaptive learning: refine `_bytesPerMs` from this leg's actual
      // throughput so the next attempt converges faster.
      if (allocationElapsedMs > 0) {
        _bytesPerMs = totalAllocated / allocationElapsedMs;
      }

      // Compose-then-stash: snapshot the wrapped capture JSON
      // immediately while scenario markers are still present in the VM
      // trace buffer. If we deferred this to the operator's Export tap,
      // tens of seconds of subsequent buffer churn could roll the
      // scenario.begin marker off the ring buffer and exportCaptureJson
      // would return null.
      String? stashed;
      if (inBand) {
        try {
          stashed = await Sleuth.exportCaptureJson(
            scenario: 'memory_pressure_heap_growing_${leg.label}',
            role: leg.label,
            // Schema requires magnitudeMin > 0. Below leg's bpsMin is
            // 0, so clamp to a small positive epsilon (1 byte/sec) —
            // still strictly under the 512 KB/s threshold for the
            // bracket semantics, but satisfies the schema's "strictly
            // positive" invariant.
            magnitudeMin: leg.bpsMin == 0 ? 1.0 : leg.bpsMin.toDouble(),
            magnitudeObserved: measuredBps,
            magnitudeMax: leg.bpsMax.toDouble(),
            unit: 'bytes/sec',
            device: 'iPhone 12',
            deviceOsVersion: 'iOS 17.5',
            flutterVersion: '3.41.4',
            captureCommand:
                'fvm flutter run --profile -d "iPhone 12" '
                '--dart-define=SLEUTH_CAPTURE_MODE=true',
            // heap_growing's source event is the VM heap sample, not a
            // BUILD timeline event — skip BUILD-derivation. Empty
            // string → operator's measured rate is the authoritative
            // observed magnitude.
            magnitudeSourceEventName: '',
          );
        } catch (_) {
          stashed = null;
        }
      }

      if (!mounted) return;
      final marker = inBand ? '✓ IN-BAND' : '✗ OUT-OF-BAND';
      setState(() {
        _busy = false;
        _lastCompletedLeg = inBand ? leg : null;
        _lastMeasuredBps = inBand ? measuredBps : null;
        _stashedCaptureJson = stashed;
        _log.add(
          '[${leg.label}] $marker — '
          'measured ${(measuredBps / 1024).toStringAsFixed(0)} KB/s '
          '(allocated ${(totalAllocated / 1024).toStringAsFixed(0)} KB '
          'over ${(allocationElapsedMs / 1000).toStringAsFixed(1)} s)',
        );
        if (inBand) {
          _activeRetryLeg = null;
          if (stashed != null) {
            _log.add(
              '[${leg.label}] capture stashed (${stashed.length} chars) — '
              'tap "Export last leg" to copy to clipboard.',
            );
          } else {
            _log.add(
              '[${leg.label}] capture FAILED to compose. Check the '
              'flutter run terminal / Xcode device console — '
              'Sleuth.exportCaptureJson now logs the exact reason via '
              'debugPrint (VM client null, VM client disconnected, '
              'empty trace buffer, or scenario markers not found). The '
              'most common cause when --dart-define=SLEUTH_CAPTURE_MODE'
              '=true was passed: scenario markers rolled off the VM '
              'trace ring buffer during the 30 s allocation, OR the '
              'app was backgrounded during the leg (iOS auto-lock kills '
              'the VM service connection). Keep the screen on and '
              'foreground while the leg runs; re-tap after fixing.',
            );
          }
        } else {
          _log.add(
            '[${leg.label}] retry: tap ${leg.label} again — rate refined '
            'to ${_bytesPerMs!.toStringAsFixed(0)} bytes/ms; next attempt '
            'should land closer to band. Do NOT export an out-of-band run.',
          );
        }
      });
    } finally {
      // Streams stay narrowed only on the early-exit branches that did
      // not reach the explicit resume. Idempotent restore here is the
      // single sink for every exit path (mounted=false at any await,
      // unhandled exception in the allocation loop, etc.).
      if (streamsSuspended) {
        await Sleuth.resumeAllTimelineStreams();
      }
      // Safety net for `_busy`: the happy-path setState already cleared
      // it. Early-exit paths never reach that setState, so reset here
      // so the next leg tap is not silently blocked.
      if (mounted && _busy) {
        setState(() => _busy = false);
      }
    }
  }

  /// Reads the wrapped capture JSON stashed by `_runLeg` immediately
  /// after `markScenarioEnd`, parses it to verify the expected
  /// `sleuth.issue.heap_growing.warning` trace-record count inside the
  /// scenario span (zero for below; exactly one for at / above), and
  /// copies it to the iOS clipboard.
  Future<void> _exportLastLeg() async {
    final leg = _lastCompletedLeg;
    final json = _stashedCaptureJson;
    final messenger = ScaffoldMessenger.of(context);
    if (leg == null || _lastMeasuredBps == null) {
      setState(() {
        _log.add(
          'Export: no in-band leg recorded yet. Tap a leg button and '
          'wait for "capture stashed" before exporting.',
        );
      });
      return;
    }
    if (json == null) {
      setState(() {
        _log.add(
          '[${leg.label}] Export FAILED: no stashed capture. The leg '
          "completed but Sleuth.exportCaptureJson returned null at "
          'compose-time. Common causes: (1) captureMode OFF — restart '
          'the app with `--dart-define=SLEUTH_CAPTURE_MODE=true`. '
          'Without it, markScenarioBegin/End emit nothing and the '
          'export has no markers to wrap. (2) VM service disconnected '
          '(FRAME mode) — kill the app from Xcode and re-open from the '
          'home screen so VM+ mode activates. Re-tap the leg after '
          'fixing.',
        );
      });
      return;
    }

    setState(() {
      _busy = true;
      _log.add('[${leg.label}] Export: validating stashed capture…');
    });

    // Post-capture validator: parse the wrapped JSON and count
    // `sleuth.issue.heap_growing.warning` events inside the scenario
    // span. The below-leg requires zero (sub-threshold detector
    // silence); at and above legs require exactly one. Two or more
    // means the sustained window broke and re-engaged mid-leg —
    // capture quality failure, abort export.
    final validation = _validateTraceRecords(json, leg);
    if (validation != null) {
      setState(() {
        _busy = false;
        _log.add('[${leg.label}] Export REJECTED — $validation');
      });
      return;
    }

    final jsonText = json;
    try {
      await Clipboard.setData(ClipboardData(text: jsonText));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _log.add(
          '[${leg.label}] Export OK — wrapped capture '
          '(${jsonText.length} chars) copied to iOS clipboard.',
        );
        _log.add(
          '[${leg.label}] Paste into Notes / Mail / AirDrop note → '
          'send to Mac. Save the pasted JSON as '
          'heap_growing_${leg.label}.json under '
          'test/validation/captures/memory_pressure/.',
        );
      });
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Capture copied to clipboard. Paste anywhere to share.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _log.add('[${leg.label}] Clipboard copy FAILED: $e');
      });
    }
  }

  /// Validates that the exported capture JSON contains the expected
  /// number of `sleuth.issue.heap_growing.warning` trace events:
  /// zero for `below`, exactly one for `at` / `above`. Returns null on
  /// success or a human-readable failure reason.
  String? _validateTraceRecords(String json, _MemoryLeg leg) {
    Map<String, dynamic> wrapped;
    try {
      wrapped = jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      return 'capture JSON is not valid JSON: $e';
    }
    final traceEvents = wrapped['traceEvents'];
    if (traceEvents is! List) {
      return 'capture has no traceEvents array; check that '
          'retainTimeline is enabled and scenario markers landed.';
    }

    // Sleuth.markScenarioBegin/End emits `Timeline.instantSync(
    // 'sleuth.scenario.begin', arguments: {'name': scenarioName})` —
    // event NAME is plain `sleuth.scenario.begin`, the leg-specific
    // scenario name lives in `args.name`. Some VM service exports nest
    // the args under `Dart Arguments` so check both shapes.
    int? scenarioBeginTs;
    int? scenarioEndTs;
    final scenarioName = 'memory_pressure_heap_growing_${leg.label}';
    for (final raw in traceEvents) {
      if (raw is! Map<String, dynamic>) continue;
      final name = raw['name'];
      final ts = raw['ts'];
      if (ts is! num) continue;
      if (name != 'sleuth.scenario.begin' && name != 'sleuth.scenario.end') {
        continue;
      }
      String? markerName;
      final args = raw['args'];
      if (args is Map) {
        final direct = args['name'];
        if (direct is String) markerName = direct;
        final dartArgs = args['Dart Arguments'];
        if (markerName == null && dartArgs is Map) {
          final inner = dartArgs['name'];
          if (inner is String) markerName = inner;
        }
      }
      if (markerName != scenarioName) continue;
      if (name == 'sleuth.scenario.begin') scenarioBeginTs = ts.toInt();
      if (name == 'sleuth.scenario.end') scenarioEndTs = ts.toInt();
    }
    if (scenarioBeginTs == null || scenarioEndTs == null) {
      return 'scenario markers missing from trace (begin=$scenarioBeginTs, '
          'end=$scenarioEndTs). Re-tap the leg.';
    }

    var heapGrowingCount = 0;
    const heapGrowingEventName = 'sleuth.issue.heap_growing.warning';
    for (final raw in traceEvents) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['name'] != heapGrowingEventName) continue;
      final ts = raw['ts'];
      if (ts is! num) continue;
      if (ts.toInt() < scenarioBeginTs) continue;
      if (ts.toInt() > scenarioEndTs) continue;
      heapGrowingCount++;
    }

    final expected = leg == _MemoryLeg.below ? 0 : 1;
    if (heapGrowingCount != expected) {
      final cause = heapGrowingCount == 0
          ? 'Detector did not fire. Likely cause: (1) regression slope '
                'never crossed 512 KB/s threshold — pre-scenario flat '
                'heap samples in the 30 s regression window dampened '
                'the slope below the allocator rate. Allocate longer '
                '(30 s minimum) so the entire regression window fills '
                'with ramp samples. (2) detector warmup not elapsed — '
                'wait ≥ 5 s after app launch before tapping leg. '
                '(3) allocator rate too low for this leg. Recalibrate.'
          : 'Sustained window broke and re-engaged mid-leg — slope '
                'dipped below threshold then resumed. Retry the leg.';
      return 'expected $expected `$heapGrowingEventName` events inside '
          'scenario span, found $heapGrowingCount. $cause';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ready = _bytesPerMs != null && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('MemoryPressure capture helper')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Records profile-mode captures for heap_growing WARNING-tier '
              'bracketing (512 KB/s threshold, sustained ≥ 10 s). Above '
              'preset stays well under any critical-tier collision because '
              'heap_growing has only a warning severity. See class docstring '
              '+ doc/capture_procedure.md for the full recording protocol.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            _CaptureButton(
              label: 'Below (${_belowTargetBps ~/ 1024} KB/s) — passes',
              subtitle:
                  'Under ${_warningThresholdBytesPerSec ~/ 1024} KB/s '
                  'threshold; detector stays silent',
              enabled: ready,
              onTap: () => _runLeg(_MemoryLeg.below),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'At (${_atTargetBps ~/ 1024} KB/s) — warning',
              subtitle: 'In [512, 768] KB/s at-band (±50% tolerance)',
              enabled: ready,
              onTap: () => _runLeg(_MemoryLeg.at),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'Above (${_aboveTargetBps ~/ 1024} KB/s) — warning',
              subtitle: 'In [800, 1024] KB/s above-band',
              enabled: ready,
              onTap: () => _runLeg(_MemoryLeg.above),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: ready || _bytesPerMs == null
                        ? (_busy ? null : _calibrate)
                        : null,
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      _bytesPerMs == null ? 'Calibrate' : 'Recalibrate',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : () => _exportLastLeg(),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Export last leg'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            const Text('Log', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Expanded(
              child: ListView.builder(
                reverse: true,
                itemCount: _log.length,
                itemBuilder: (context, i) {
                  final line = _log[_log.length - 1 - i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      line,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _MemoryLeg {
  // Bands match what ProfileCaptureSchema.validateBracket accepts when
  // the detector's metadata declares `bracketAtTolerance: 0.50` and
  // `aboveCeilingMultiplier: 2.0`:
  //   below: bytes/sec < 512 000 (sub-threshold; detector stays silent).
  //   at:    512 000 ≤ bytes/sec ≤ 768 000  (atTolerance 0.50).
  //   above: 800 000 ≤ bytes/sec ≤ 1 024 000  (screen-side floor 800 000
  //                                            keeps at and above
  //                                            magnitudes disjoint).
  below(label: 'below', targetBps: _belowTargetBps, bpsMin: 0, bpsMax: 511_999),
  at(label: 'at', targetBps: _atTargetBps, bpsMin: 512_000, bpsMax: 768_000),
  above(
    label: 'above',
    targetBps: _aboveTargetBps,
    bpsMin: 800_000,
    bpsMax: 1_024_000,
  );

  const _MemoryLeg({
    required this.label,
    required this.targetBps,
    required this.bpsMin,
    required this.bpsMax,
  });
  final String label;
  final int targetBps;
  final int bpsMin;
  final int bpsMax;

  bool isBpsInBand(double bps) => bps >= bpsMin && bps <= bpsMax;
}

class _CaptureButton extends StatelessWidget {
  const _CaptureButton({
    required this.label,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: enabled ? onTap : null,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        alignment: Alignment.centerLeft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
          ),
        ],
      ),
    );
  }
}
