import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

import 'capture_driver.dart';

/// Capture helper for `MemoryPressureDetector.heap_growing.warning`
/// (threshold = 512 000 bytes/sec sustained ≥ 10 s; runtimeVerified via
/// `perStableIdTier`).
///
/// **VM-service connection required.** This screen produces captures that
/// satisfy `ProfileCaptureSchema.validateBracket(...
/// requireDetectorTraceRecord: true, ...)` ONLY when SleuthController's
/// VmServiceClient is connected — i.e. the run is in VM+ mode, not FRAME
/// mode. Sleuth connects to the app's own VM service from inside the app,
/// so USB and wireless both work. What blocks it is DDS: `flutter run`
/// starts DDS by default and DDS keeps the VM service as its only client,
/// which leaves Sleuth in FRAME mode. Launch with `--no-dds` (step 1), or
/// start the installed app from the home screen.
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
///   1. `cd example && fvm flutter run --profile --no-dds -d DEVICE \
///         --dart-define=SLEUTH_CAPTURE_MODE=true \
///         --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"`.
///   2. Wait ≥ 5 s after app launch (lets the detector's 3 s heap-trend
///      warmup elapse and the rolling sample window stabilize).
///   3. Tap **Calibrate** — runs a 1-second allocation warmup and pins
///      `_bytesPerMs` for the device's current GC + thermal state.
///   4. Tap a leg (Below / At / Above). The screen switches
///      StreamResourceDetector off, holds Sleuth's allocation-profile
///      reads and waits up to 10 s for one in flight (the leg aborts if
///      it does not finish). After a 2.5 s settle the workload runs 45 s
///      of allocation (fills the detector's 30 s regression window with
///      ramp samples and leaves room for the 10 s sustained check),
///      followed by ≥ 600 ms dwell, then `markScenarioEnd`. An
///      out-of-band attempt rescales the next attempt's rate; the at and
///      above legs never drop to 512 000 B/s or below.
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
///   above:   768 001 ≤ bytes/sec ≤ 1 024 000  (above-ceiling 2.0 × T)
///
/// The above-band floor (768 001) sits one above the at-band's upper
/// (768 000), so at and above magnitudes stay disjoint.
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

// Per-leg target *operator-allocator* rates (bytes/sec), the rate at
// which the workload retains buffers. The at and above legs are judged
// on the DETECTOR-stamped slope (parsed back out of the wrapped capture
// and re-injected into the JSON's `expectedMagnitude.observed`); the
// below leg is judged on the operator rate.
//
// The detector's slope is a regression over every heap sample, so it
// also counts allocation that the next collection frees. On Flutter
// 3.41.x that added about 25 to 55 % to the operator rate. On Flutter
// 3.47.6 the first stretch without a collection after the scenario
// begins has run at about 1.16 MB/s for a 400 KB/s workload, and the
// detector decides there, so the stamped slope can sit well above the
// operator rate. The at and above targets therefore start inside
// their bands and above the threshold: a retained rate at or below
// 512 000 B/s cannot produce an in-band at leg once that extra
// allocation is gone.
//
//   below: operator 350 000 B/s (detector silent).
//   at:    operator 600 000 B/s, inside [512 000, 768 000].
//   above: operator 820 000 B/s, inside (768 000, 1 024 000].
const _belowTargetBps = 350000;
const _atTargetBps = 600000;
const _aboveTargetBps = 820000;

// Lowest target a rescale may give the at and above legs. Strictly
// above the threshold because the detector's comparison is strict.
const _minDetectedLegTargetBps = 520000;

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
// 45 s of allocation fills the regression window with ramp samples and
// leaves room for the 10 s sustained check after a late crossing. Each
// old-generation GC inside the window drops heapUsage and can pull the
// regression slope back under the threshold, which restarts the
// sustained clock. On an iPhone 12 with Flutter 3.47.6 the lasting
// crossing landed about 23 s into the scenario, so a 30 s phase ended
// with 8.5 s sustained and no emission.
const _allocationDurationSec = 45;
// Pause between clearing the previous attempt's buffers and
// `markScenarioBegin`. The idle GC reclaims those buffers here instead
// of inside the detector's window, where the drop would drag the
// regression slope negative for the first samples.
const _preScenarioSettleMs = 2500;
// Longest wait for Sleuth's in-flight allocation-profile reads to finish
// before a leg starts. A leg that cannot drain is aborted.
const _profileDrainTimeoutSec = 10;
// Retry rescaling. A silent detector raises the next attempt's rate by
// this factor; a slope outside the band rescales the rate toward the
// band middle, by at most these factors per attempt and overall.
const _silentRetryScale = 1.25;
const _minStepScale = 0.6;
const _maxStepScale = 1.6;
const _minTargetScale = 0.5;
const _maxTargetScale = 2.5;

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

  // Multiplier on each leg's starting target, adjusted after every
  // out-of-band attempt so the next one aims for the band.
  final Map<_MemoryLeg, double> _targetScale = {};

  double _targetBpsFor(_MemoryLeg leg) =>
      leg.targetBps * (_targetScale[leg] ?? 1.0);

  /// Sets [leg]'s next target from this attempt's result and returns
  /// the new target in bytes per second. The at and above legs never go
  /// below [_minDetectedLegTargetBps].
  double _rescaleTarget(_MemoryLeg leg, double? detectorBps) {
    final current = _targetScale[leg] ?? 1.0;
    final step = detectorBps == null
        ? _silentRetryScale
        : ((leg.bpsMin + leg.bpsMax) / 2 / detectorBps).clamp(
            _minStepScale,
            _maxStepScale,
          );
    var scale = (current * step).clamp(_minTargetScale, _maxTargetScale);
    if (leg != _MemoryLeg.below &&
        leg.targetBps * scale < _minDetectedLegTargetBps) {
      scale = _minDetectedLegTargetBps / leg.targetBps;
    }
    _targetScale[leg] = scale;
    return _targetBpsFor(leg);
  }

  // Cross-leg gate. Set when any leg's catch-block sees a persistent
  // post-process `rewriteError` (i.e. `_replaceExpectedObserved` shape
  // drift). Same shape-drift bug breaks every leg, so once one leg has
  // exhausted its retry budget on it, the other legs short-circuit
  // instead of burning their own budgets on identical failures.
  // Restart-screen is the only recovery path: clear-log button does
  // NOT reset this flag, because operator must re-prove the wrapped
  // capture shape after fixing `_replaceExpectedObserved`.
  bool _persistentRewriteError = false;

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
        '⚠ captureMode OFF. Restart with --dart-define='
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
      'Wait at least 5 s after app launch before calibrating, so '
      'the detector warmup can elapse.',
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
    if (_persistentRewriteError) {
      setState(() {
        _log.add(
          '[${leg.label}] persistent rewriteError on a prior leg. '
          'Restart the screen to retry. The same shape-drift bug breaks '
          'every leg, so another scenario would waste 30 s.',
        );
      });
      return;
    }
    // Capture mode and provenance are properties of the build, so a leg
    // that could never be exported is refused before its 30 s workload.
    // Both are reported so one relaunch can fix both.
    final provenanceProblem = provenanceRefusal(leg.label);
    if (!_captureModeOn || provenanceProblem != null) {
      setState(() {
        if (!_captureModeOn) {
          _log.add(
            '[${leg.label}] ABORT: captureMode is OFF. Restart the app '
            'with `--dart-define=SLEUTH_CAPTURE_MODE=true`. Without it '
            'markScenarioBegin/End do nothing, no scenario markers reach '
            'the VM trace buffer, and Export fails with no markers '
            'found. Running the leg now would waste 30 s and emit '
            'nothing.',
          );
        }
        if (provenanceProblem != null) _log.add(provenanceProblem);
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
        '[${leg.label}] attempt $_retryCount/$_maxRetriesPerLeg: '
        'target ${(_targetBpsFor(leg) / 1024).toStringAsFixed(0)} KB/s, '
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
    // Sleuth's own allocation-profile reads stay out of the leg. Each
    // response is decoded on the UI isolate; on an iPhone 12 every
    // StreamResourceDetector poll (every 10 s) was followed by a burst of
    // collections and a heap jump of several MB, which swings the
    // regression slope. The detector is switched off for the leg, the
    // hold blocks the controller's enrichment read, and the drain waits
    // for a read already in flight, whose caller may have timed out
    // while the VM still answers. Both are restored in `finally`.
    final streamDetector = Sleuth.streamResourceDetector;
    final streamDetectorWasEnabled = streamDetector?.isEnabled ?? false;
    streamDetector?.isEnabled = false;
    try {
      final drained = await Sleuth.holdAllocationProfileReads(
        timeout: const Duration(seconds: _profileDrainTimeoutSec),
      );
      if (!mounted) return;
      if (!drained) {
        setState(() {
          _log.add(
            '[${leg.label}] ABORT: Sleuth could not hold its '
            'allocation-profile reads. The VM service is not connected '
            '(FRAME mode: relaunch with --no-dds), its session changed, or '
            'a read was still in flight after $_profileDrainTimeoutSec s. '
            'Re-tap the leg.',
          );
        });
        return;
      }
      await Future<void>.delayed(
        const Duration(milliseconds: _preScenarioSettleMs),
      );
      if (!mounted) return;

      Sleuth.markScenarioBegin('memory_pressure_heap_growing_${leg.label}');

      final scaledTickBytes = (_targetBpsFor(leg) * _allocationTickMs / 1000)
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
      // service.getVMTimeline can return it. Without the wait the
      // RPC can observe a snapshot that pre-dates the end
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

      final operatorBps = totalAllocated / (allocationElapsedMs / 1000.0);

      // Adaptive learning: refine `_bytesPerMs` from this leg's actual
      // throughput so the next attempt converges faster.
      if (allocationElapsedMs > 0) {
        _bytesPerMs = totalAllocated / allocationElapsedMs;
      }

      // Compose first against the operator-measured rate so the wrapped
      // JSON shape is valid. The post-process step below replaces
      // `expectedMagnitude.observed` with the detector-stamped slope so
      // the bracket-band check, the schema's per-record cross-check, and
      // the audit's `checkDetectorAxisInRoleBand` invariant all reduce
      // to the same authoritative number — the value the detector
      // itself observed at firing time. Operator rate is the wheel the
      // operator turns; detector slope is the value the role band is
      // judged against.
      String? stashed;
      // Why the capture did not compose: the export's own reason when it
      // returned null, or the text of a failure before or inside the call.
      String? composeFailure;
      try {
        // Checked when the leg started; this is a safety net.
        final provenance = requireCaptureProvenance();
        stashed = await Sleuth.exportCaptureJson(
          scenario: 'memory_pressure_heap_growing_${leg.label}',
          role: leg.label,
          // Schema requires magnitudeMin > 0. Below leg's bpsMin is
          // 0, so clamp to a small positive epsilon (1 byte/sec) —
          // still strictly under the 512 KB/s threshold for the
          // bracket semantics, but satisfies the schema's "strictly
          // positive" invariant.
          magnitudeMin: leg.bpsMin == 0 ? 1.0 : leg.bpsMin.toDouble(),
          magnitudeObserved: operatorBps,
          magnitudeMax: leg.bpsMax.toDouble(),
          unit: 'bytes/sec',
          device: provenance.device,
          deviceOsVersion: provenance.deviceOsVersion,
          flutterVersion: provenance.flutterVersion,
          captureCommand: provenance.captureCommand,
          // heap_growing's source event is the VM heap sample, not a
          // BUILD timeline event — skip BUILD-derivation. The
          // post-process step replaces the placeholder with detector
          // slope.
          magnitudeSourceEventName: '',
          // `expectedMagnitude.observed` becomes the detector's slope
          // below, so the measured operator rate is kept here.
          captureNotes:
              'StreamResourceDetector off and Sleuth allocation-profile '
              'reads held for the leg, none in flight at scenario begin. '
              'Operator retained rate ${operatorBps.round()} bytes/sec.',
        );
        if (stashed == null) {
          final reason =
              Sleuth.lastCaptureExportFailure ??
              'exportCaptureJson gave no reason';
          composeFailure =
              '$reason. Keep the screen on and in the foreground while '
              'the leg runs; iOS auto-lock drops the VM service connection';
        }
      } catch (e) {
        stashed = null;
        composeFailure = '$e';
      }

      double? detectorBps;
      String? rewrittenJson;
      String? rewriteError;
      if (stashed != null) {
        detectorBps = _extractDetectorSlopeFromCapture(stashed, leg);
        if (detectorBps != null) {
          try {
            rewrittenJson = _replaceExpectedObserved(stashed, detectorBps);
          } on StateError catch (e) {
            rewriteError = e.message;
          }
        } else if (leg == _MemoryLeg.below) {
          // Below leg: detector is silent by design (no in-span issue
          // event). Authoritative value is the operator-measured
          // sub-threshold rate.
          rewrittenJson = stashed;
        }
      }

      // For at + above: in-band uses detector slope (the value the role
      // band is enforced against). For below: operator rate (detector
      // silent). When the detector value is missing from at/above the
      // run is unusable — surface as out-of-band and keep nothing.
      bool inBand;
      if (leg == _MemoryLeg.below) {
        // The below leg also needs a silent detector: an emission inside
        // the span makes the capture unusable whatever the operator rate.
        inBand = leg.isBpsInBand(operatorBps) && detectorBps == null;
      } else {
        inBand = detectorBps != null && leg.isBpsInBand(detectorBps);
      }

      if (!mounted) return;
      final marker = inBand ? '✓ IN-BAND' : '✗ OUT-OF-BAND';
      final reportedBps = (leg == _MemoryLeg.below
          ? operatorBps
          : (detectorBps ?? operatorBps));
      // A leg is offered for export only with an in-band value and a
      // composed capture. An in-band leg whose export or rewrite failed
      // logs the failure after its band verdict.
      final stashedJson = inBand ? rewrittenJson : null;
      setState(() {
        _busy = false;
        _lastCompletedLeg = stashedJson != null ? leg : null;
        _lastMeasuredBps = stashedJson != null ? reportedBps : null;
        _stashedCaptureJson = stashedJson;
        final ratio = (detectorBps != null && operatorBps > 0)
            ? (detectorBps / operatorBps).toStringAsFixed(2)
            : null;
        _log.add(
          '[${leg.label}] $marker: '
          'operator ${(operatorBps / 1024).toStringAsFixed(0)} KB/s, '
          'detector ${detectorBps == null ? '(silent)' : '${(detectorBps / 1024).toStringAsFixed(0)} KB/s'}'
          '${ratio == null ? '' : ' (det/op ratio $ratio)'} '
          '(role-band uses ${leg == _MemoryLeg.below ? 'operator' : 'detector'}: '
          '[${(leg.bpsMin / 1024).toStringAsFixed(0)}, '
          '${(leg.bpsMax / 1024).toStringAsFixed(0)}] KB/s)',
        );
        if (stashedJson != null) {
          _activeRetryLeg = null;
          _log.add(
            '[${leg.label}] capture stashed (${stashedJson.length} chars). '
            'Tap "Export last leg" to copy it to the clipboard.',
          );
        } else {
          if (stashed == null) {
            _log.add(
              '[${leg.label}] capture FAILED to compose: $composeFailure. '
              'Re-tap after fixing.',
            );
          } else if (rewriteError != null) {
            // Persistent shape change: every retry on this leg AND
            // every other leg will throw the same StateError. Exhaust
            // this leg's budget AND set the cross-leg gate so the next
            // tap on any leg short-circuits at the top of _runLeg.
            _retryCount = _maxRetriesPerLeg;
            _persistentRewriteError = true;
            _log.add(
              '[${leg.label}] post-process FAILED: $rewriteError. '
              'The wrapped capture shape changed; update '
              '_replaceExpectedObserved before retrying. The screen used '
              'up the retry budget so the same failure does not repeat. '
              'Restart the screen after fixing.',
            );
          } else if (leg != _MemoryLeg.below && detectorBps == null) {
            final next = _rescaleTarget(leg, null);
            _log.add(
              '[${leg.label}] no in-span heap_growing.warning: the '
              'detector slope did not stay above 500 KB/s for 10 s '
              'inside the scenario. Next attempt targets '
              '${(next / 1024).toStringAsFixed(0)} KB/s. Re-tap.',
            );
          } else {
            final next = leg == _MemoryLeg.below
                ? _targetBpsFor(leg)
                : _rescaleTarget(leg, detectorBps);
            _log.add(
              '[${leg.label}] retry: detector slope '
              '${detectorBps == null ? '?' : (detectorBps / 1024).toStringAsFixed(0)} '
              'KB/s missed band '
              '[${(leg.bpsMin / 1024).toStringAsFixed(0)}, '
              '${(leg.bpsMax / 1024).toStringAsFixed(0)}] KB/s. Next '
              'attempt targets ${(next / 1024).toStringAsFixed(0)} KB/s. '
              'Do NOT export an out-of-band run.',
            );
          }
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
      Sleuth.releaseAllocationProfileReads();
      if (streamDetectorWasEnabled) streamDetector?.isEnabled = true;
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
          'compose-time. Common causes: (1) captureMode is OFF. Restart '
          'the app with `--dart-define=SLEUTH_CAPTURE_MODE=true`. '
          'Without it, markScenarioBegin/End emit nothing and the '
          'export has no markers to wrap. (2) The VM service '
          'disconnected (FRAME mode). Kill the app from Xcode and '
          're-open it from the home screen so VM+ mode activates. '
          'Re-tap the leg after fixing.',
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
        _log.add('[${leg.label}] Export REJECTED: $validation');
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
          '[${leg.label}] Export OK. Copied the wrapped capture '
          '(${jsonText.length} chars) to the iOS clipboard.',
        );
        _log.add(
          '[${leg.label}] Paste it into Notes, Mail or an AirDrop note '
          'and send it to the Mac. Save the pasted JSON as '
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
          ? 'Detector did not fire. Likely causes: (1) The regression '
                'slope did not stay above the 512 KB/s threshold for 10 s '
                'inside the scenario. An old-generation GC inside the 30 s '
                'regression window drops the heap and can restart the '
                'sustained clock. Re-tap: the next attempt runs at a '
                'higher rate. (2) The detector warmup had not elapsed. Wait at '
                'least 5 s after app launch before tapping a leg. '
                '(3) The allocator rate is too low for this leg. '
                'Recalibrate.'
          : leg == _MemoryLeg.below
          ? 'The detector fired on a leg whose retained rate is below '
                'the threshold, so allocation the next collection frees '
                'pushed the slope over it. Retry the leg.'
          : 'The sustained window broke and re-engaged mid-leg: the '
                'slope dipped below the threshold, then rose again. '
                'Retry the leg.';
      return 'expected $expected `$heapGrowingEventName` events inside '
          'scenario span, found $heapGrowingCount. $cause';
    }
    return null;
  }

  /// Walks the wrapped capture's `traceEvents` for in-span
  /// `sleuth.issue.heap_growing.warning` events and returns the maximum
  /// `args.observedSlopeBytesPerSec` value the detector stamped during
  /// the scenario. Returns null when the detector did not fire (below
  /// leg) or the arg is missing/unparseable. Reduction strategy `'max'`
  /// matches the schema's per-record cross-check on this stableId.
  double? _extractDetectorSlopeFromCapture(String json, _MemoryLeg leg) {
    Map<String, dynamic> wrapped;
    try {
      wrapped = jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final traceEvents = wrapped['traceEvents'];
    if (traceEvents is! List) return null;
    final scenarioName = 'memory_pressure_heap_growing_${leg.label}';
    int? beginTs;
    int? endTs;
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
      if (name == 'sleuth.scenario.begin') beginTs = ts.toInt();
      if (name == 'sleuth.scenario.end') endTs = ts.toInt();
    }
    if (beginTs == null || endTs == null) return null;
    const eventName = 'sleuth.issue.heap_growing.warning';
    double? max;
    for (final raw in traceEvents) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['name'] != eventName) continue;
      final ts = raw['ts'];
      if (ts is! num) continue;
      final tsInt = ts.toInt();
      if (tsInt < beginTs || tsInt > endTs) continue;
      final args = raw['args'];
      if (args is! Map) continue;
      // Some VM service exports nest user-supplied trace args under
      // a top-level `Dart Arguments` map. Mirror the scenario-marker
      // name lookup so detector slope extraction stays active under
      // either shape.
      Object? axis = args['observedSlopeBytesPerSec'];
      if (axis == null) {
        final dartArgs = args['Dart Arguments'];
        if (dartArgs is Map) axis = dartArgs['observedSlopeBytesPerSec'];
      }
      double? parsed;
      if (axis is String && axis.isNotEmpty) {
        parsed = double.tryParse(axis);
      } else if (axis is num) {
        parsed = axis.toDouble();
      }
      if (parsed == null) continue;
      if (max == null || parsed > max) max = parsed;
    }
    return max;
  }

  /// Returns a copy of [json] with `sleuthMetadata.expectedMagnitude.observed`
  /// rewritten to [observed]. Eliminates the operator-vs-detector
  /// divergence by construction so the schema bracket-band check, the
  /// per-record cross-check, and `checkDetectorAxisInRoleBand` all
  /// reduce to the same authoritative number.
  ///
  /// Throws [StateError] when the target field is missing — a silent
  /// no-op would let an exported capture keep the operator-value
  /// placeholder in `expectedMagnitude.observed`, regressing the
  /// schema bracket-band check on a future schema-shape change.
  String _replaceExpectedObserved(String json, double observed) {
    final root = jsonDecode(json) as Map<String, dynamic>;
    final meta = root['sleuthMetadata'];
    if (meta is! Map<String, dynamic>) {
      throw StateError(
        'sleuthMetadata is missing or not a Map in stashed capture; '
        'wrapped capture shape may have changed in a Sleuth release. '
        'Update _replaceExpectedObserved before exporting captures.',
      );
    }
    final expected = meta['expectedMagnitude'];
    if (expected is! Map<String, dynamic>) {
      throw StateError(
        'sleuthMetadata.expectedMagnitude is missing or not a Map in '
        'stashed capture; wrapped capture shape may have changed.',
      );
    }
    if (!expected.containsKey('observed')) {
      throw StateError(
        'sleuthMetadata.expectedMagnitude.observed is missing in stashed '
        'capture; wrapped capture shape may have changed.',
      );
    }
    expected['observed'] = observed;
    return const JsonEncoder.withIndent('  ').convert(root);
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
              'bracketing (512 KB/s threshold, sustained for at least '
              '10 s). The above preset stays well under any critical-tier '
              'collision because '
              'heap_growing has only a warning severity. See the class doc '
              'comment and doc/capture_procedure.md for the full recording '
              'protocol.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            _CaptureButton(
              label: 'Below (${_belowTargetBps ~/ 1024} KB/s), passes',
              subtitle:
                  'Under ${_warningThresholdBytesPerSec ~/ 1024} KB/s '
                  'threshold; detector stays silent',
              enabled: ready,
              onTap: () => _runLeg(_MemoryLeg.below),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'At (op ${_atTargetBps ~/ 1024} KB/s), warning',
              subtitle:
                  'Detector slope must land in [512, 768] KB/s '
                  '(operator rate adjusted for ~+50% allocator drift)',
              enabled: ready,
              onTap: () => _runLeg(_MemoryLeg.at),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'Above (op ${_aboveTargetBps ~/ 1024} KB/s), warning',
              subtitle:
                  'Detector slope must land in [769, 1024] KB/s '
                  '(operator rate adjusted for ~+12% allocator drift)',
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
  // Role bands match what `checkDetectorAxisInRoleBand` enforces (and,
  // for at, what `ProfileCaptureSchema.validateBracket` enforces) so
  // an in-band capture passes the audit and an out-of-band capture is
  // rejected client-side before export rather than failing CI later:
  //   below: bytes/sec < 512 000 (operator rate; detector silent).
  //   at:    512 000 ≤ detector slope ≤ 768 000 (atTolerance 0.50 →
  //          [threshold, threshold × 1.5]).
  //   above: 768 001 ≤ detector slope ≤ 1 024 000 (strictly above
  //          at-band upper, ≤ threshold × aboveCeilingMultiplier=2.0).
  below(label: 'below', targetBps: _belowTargetBps, bpsMin: 0, bpsMax: 511_999),
  at(label: 'at', targetBps: _atTargetBps, bpsMin: 512_000, bpsMax: 768_000),
  above(
    label: 'above',
    targetBps: _aboveTargetBps,
    bpsMin: 768_001,
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
