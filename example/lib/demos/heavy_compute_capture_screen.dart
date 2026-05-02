import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Capture helper for the `runtimeVerified` tier raises on
/// `HeavyComputeDetector.heavy_compute`.
///
/// Two tier-stack brackets are recorded from this screen:
///
///  - **Warning** (threshold = 8 ms, shipped v0.18.2). Below/at/above
///    captures bracket the 8 ms strict-greater warning fire.
///  - **Critical** (threshold = 16 ms = 2× warning, planned v0.19.13).
///    Below/at/above captures bracket the 16 ms strict-greater critical
///    fire. Below leg sits between 8 ms and 16 ms so the detector emits
///    `.warning` (which the schema's `_requireNoIssueTraceRecord(critical)`
///    accepts via its name-scoped filter) but not `.critical`.
///
/// Pick the active tier via the dropdown at the top of the screen. The
/// scenario name, capture file naming, and per-leg target ms switch
/// together — the wrapped capture JSON for each leg is exported to the
/// iOS clipboard with the file name the operator should save it under.
///
/// **VM-service connection required.** This screen produces captures
/// that satisfy `ProfileCaptureSchema.validateBracket(...
/// requireDetectorTraceRecord: true, ...)` ONLY when SleuthController's
/// VmServiceClient is connected — i.e. the run is in VM+ mode, not
/// FRAME mode. USB-tethered iPhone profile-mode is FRAME mode (the
/// VM service port is not routed to the host); use **wireless
/// debugging** via Xcode → Window → Devices and Simulators →
/// "Connect via network", or run on the iOS simulator.
///
/// In FRAME mode, the `HeavyComputeDetector` (vmOnly lifecycle) never
/// observes BUILD events, so the detector never emits the required
/// `sleuth.issue.heavy_compute.<severity>` trace record. The schema
/// audit will reject the resulting capture as "Missing detector trace
/// record" — that is the correct behavior. Earlier iterations of this
/// screen synthesised the trace record from a Stopwatch around the
/// inner loop; that path was removed because it produced evidence
/// indistinguishable from forgery and certified screen-mirrored
/// threshold logic instead of detector behavior.
///
/// **Bands enforced by this screen** (tied to the schema settings the
/// `HeavyComputeDetector` metadata declares for each tier):
///
/// Warning tier (threshold=8, atTolerance=0.50, aboveCeilingMultiplier=1.875):
///   below: ms < 8.0
///   at:    8.0 ≤ ms ≤ 12.0  (atTolerance=0.50 → [8, 8 × 1.50])
///   above: 12.1 ≤ ms ≤ 15.0 (above-ceiling 8 × 1.875 = 15;
///                            stays clear of 16 ms critical)
///
/// Critical tier (threshold=16, atTolerance=0.50, aboveCeilingMultiplier=1.875):
///   below: 8.0 ≤ ms ≤ 15.5  (warning fires; critical does NOT — the
///                            schema's name-scoped no-record check
///                            ignores warning events when validating
///                            the critical below leg)
///   at:    16.0 ≤ ms ≤ 24.0 (atTolerance=0.50 → [16, 16 × 1.50])
///   above: 24.1 ≤ ms ≤ 30.0 (above-ceiling 16 × 1.875 = 30;
///                            no super-critical tier above)
///
/// **Required runtime gate**: this screen relies on
/// `Sleuth.markScenarioBegin/End` which are silently no-ops unless the
/// app is run with `SleuthConfig(captureMode: true)`. The example app
/// flips that flag on when launched with
/// `--dart-define=SLEUTH_CAPTURE_MODE=true` (see `main.dart`). If you
/// see "captureMode OFF" in the log below, restart the app with that
/// dart-define.
///
/// Protocol per leg:
///
///  1. `cd example && fvm flutter run --profile -d DEVICE \
///       --dart-define=SLEUTH_CAPTURE_MODE=true`.
///  2. Pick the active tier (Warning / Critical) from the dropdown.
///  3. Tap **Below**, wait for "ready to Export" log line.
///  4. Tap **Export last leg** — wrapped JSON is copied to clipboard
///     with the correct file name (e.g. `heavy_compute_critical_at.json`).
///  5. Repeat for **At** and **Above**.
///  6. Save each clipboard payload under
///     `test/validation/captures/heavy_compute/`.
///
/// **Auto-calibration**: sin/cos iteration counts are calibrated on
/// screen open by running a short warmup loop and dividing measured
/// duration into the target ms for each preset. Recalibrate via the
/// "Recalibrate" button if device thermal throttling or background
/// load skews the first-pass measurement. Each in-band capture also
/// refines the rate, so subsequent taps land closer to the target band.
class HeavyComputeCaptureScreen extends StatefulWidget {
  const HeavyComputeCaptureScreen({super.key});

  @override
  State<HeavyComputeCaptureScreen> createState() =>
      _HeavyComputeCaptureScreenState();
}

// Warning threshold for HeavyComputeDetector (lagThresholdMs).
// Critical fires strict-greater at 2× = 16 ms.
const _warningThresholdMs = 8;
const _criticalThresholdMs = 16;

// Calibration warmup. Big enough that the resulting iterations-per-ms
// rate is stable, small enough that the screen open delay is invisible.
// Empirically the cold warmup runs much faster than the in-build hot
// loop on iPhone 12 (≈1.6× rate divergence on first capture), so we
// also re-run a quick calibration pass *immediately before* every leg
// (`_recalibratePerLeg`). This adapts iteration count to current
// thermal state and keeps each leg inside its target band.
const _calibrationIterations = 500000;

/// Active tier-stack bracket the screen is recording.
enum _Tier {
  warning(label: 'warning', thresholdMs: _warningThresholdMs),
  critical(label: 'critical', thresholdMs: _criticalThresholdMs);

  const _Tier({required this.label, required this.thresholdMs});

  final String label;
  final int thresholdMs;
}

/// Per-leg band specs resolved against the active [_Tier].
///
/// Targets sit deliberately FAR from each band's nearest threshold to
/// absorb iPhone's ±15-25 % per-scenario variance. Below targets aim
/// well under the active threshold; at + above targets sit mid-band so
/// that ±20 % drift stays inside the schema-accepted band.
({double targetMs, double msMin, double msMax}) _legSpec(_Tier tier, _Leg leg) {
  switch (tier) {
    case _Tier.warning:
      switch (leg) {
        // Below band [0, 7.9] → target 3.0 ms (≥ 2.6× drift still safe).
        case _Leg.below:
          return (targetMs: 3.0, msMin: 0.0, msMax: 7.9);
        // At band [8, 12] → target 10.0 ms (mid-band, ±20 % stays in band).
        case _Leg.at:
          return (targetMs: 10.0, msMin: 8.0, msMax: 12.0);
        // Above band [12.1, 15] → target 12.5 ms (lower half so ±20 %
        // drift does not push past the 15 ms above-ceiling).
        case _Leg.above:
          return (targetMs: 12.5, msMin: 12.1, msMax: 15.0);
      }
    case _Tier.critical:
      switch (leg) {
        // Below band [8, 15.5] (warning fires; critical does not).
        // Target 12 ms is mid-band; the schema's name-scoped
        // _requireNoIssueTraceRecord('critical') ignores in-span
        // `.warning` events.
        case _Leg.below:
          return (targetMs: 12.0, msMin: 8.0, msMax: 15.5);
        // At band [16, 25.6] (atTolerance=0.60). Target 20 ms sits
        // mid-band. The 0.60 tolerance is forward-compat re-record
        // headroom relative to warning's 0.50 — the wider window is
        // operator convergence margin, not a claim about device
        // physics at higher magnitudes.
        case _Leg.at:
          return (targetMs: 20.0, msMin: 16.0, msMax: 25.6);
        // Above band (25.7, 30] → target 27.0 ms. msMin bumped one tick
        // past at-upper (25.6) so at + above magnitudes stay disjoint
        // even when the operator over-shoots the at target.
        case _Leg.above:
          return (targetMs: 27.0, msMin: 25.7, msMax: 30.0);
      }
  }
}

class _HeavyComputeCaptureScreenState extends State<HeavyComputeCaptureScreen> {
  final List<String> _log = [];
  bool _busy = false;
  // Iterations-per-ms determined by the calibration warmup. Until set,
  // capture buttons are disabled.
  double? _iterationsPerMs;
  // Active tier-stack bracket the operator is recording. Defaults to
  // warning (the v0.18.2 raise) for backward compat with the original
  // capture procedure.
  _Tier _activeTier = _Tier.warning;
  // Pending leg requested by a button tap; consumed inside `build` so
  // the sin/cos loop runs synchronously *inside* the build scope and
  // shows up in the VM timeline as a long Widget.build event (the
  // shape `HeavyComputeDetector` filters on). Same indirection as the
  // existing HeavyCompute demo.
  _Leg? _pendingLeg;
  _Tier? _pendingTier;

  // Last completed scenario, captured at the end of build() so the
  // Export button knows what scenario name + measured magnitude to
  // pass to `Sleuth.exportCaptureJson`. Cleared when the user
  // re-taps a leg.
  _Leg? _lastCompletedLeg;
  _Tier? _lastCompletedTier;
  double? _lastMeasuredMs;

  // In-flight scenario name. Stamped at markScenarioBegin (inside
  // build()), cleared at markScenarioEnd (in postFrameCallback). When
  // non-null at dispose() the operator backgrounded or popped the
  // screen mid-scenario; we emit a synthetic markScenarioEnd so the
  // begin marker doesn't outlive the screen and pair with whatever
  // scenario the next session opens (orphan scenario.begin would make
  // ProfileCaptureSchema's `_scenarioSpan` see two begins or attribute
  // a wider span than intended).
  String? _inFlightScenarioName;

  bool get _captureModeOn {
    // SleuthConfig is only readable through Sleuth.controllerOf; the
    // example app sets this via dart-define so we can simply check the
    // compile-time constant.
    return const bool.fromEnvironment('SLEUTH_CAPTURE_MODE');
  }

  @override
  void initState() {
    super.initState();
    // Run calibration after first frame so the scaffold paints before
    // the warmup blocks the UI thread.
    WidgetsBinding.instance.addPostFrameCallback((_) => _calibrate());
  }

  @override
  void dispose() {
    final scenario = _inFlightScenarioName;
    if (scenario != null) {
      // Operator popped or backgrounded mid-scenario. Emit the matching
      // scenario.end so the in-buffer begin marker pairs and the next
      // session's recorded span can't accidentally absorb it.
      Sleuth.markScenarioEnd(scenario);
      _inFlightScenarioName = null;
    }
    super.dispose();
  }

  void _calibrate() {
    final sw = Stopwatch()..start();
    _heavyCompute(_calibrationIterations);
    sw.stop();
    final ms = sw.elapsedMicroseconds / 1000.0;
    if (!mounted) return;
    setState(() {
      _iterationsPerMs = _calibrationIterations / ms;
      _log.add(
        'Calibrated: ${_iterationsPerMs!.toStringAsFixed(0)} '
        'iterations/ms (warmup ${ms.toStringAsFixed(2)} ms)',
      );
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
    });
  }

  void _requestCapture(_Leg leg) {
    if (_busy || _iterationsPerMs == null) return;
    final tier = _activeTier;
    final spec = _legSpec(tier, leg);
    setState(() {
      _busy = true;
      _pendingLeg = leg;
      _pendingTier = tier;
      _lastCompletedLeg = null;
      _lastCompletedTier = null;
      _lastMeasuredMs = null;
      _log.add(
        '[${tier.label}/${leg.label}] scenario.begin '
        '(target ${spec.targetMs.toStringAsFixed(1)} ms, '
        'band [${spec.msMin.toStringAsFixed(1)}, '
        '${spec.msMax.toStringAsFixed(1)}] ms)',
      );
    });
  }

  /// Composes the wrapped capture JSON for the most recent in-band
  /// leg via `Sleuth.exportCaptureJson`, copies it to the iOS
  /// clipboard, and surfaces the target file name so the operator can
  /// save the payload under `test/validation/captures/heavy_compute/`.
  ///
  /// Refuses when:
  /// - No leg has completed in-band since screen open (or since the
  ///   last leg tap).
  /// - VM service is not connected — the procedure requires VM+
  ///   mode (re-opened iOS profile build, or wireless debugging).
  Future<void> _exportLastLeg() async {
    final leg = _lastCompletedLeg;
    final tier = _lastCompletedTier;
    final measured = _lastMeasuredMs;
    final messenger = ScaffoldMessenger.of(context);
    if (leg == null || tier == null || measured == null) {
      setState(() {
        _log.add(
          'Export: no in-band leg recorded yet. Tap a leg button and '
          'wait for "ready to Export" before exporting.',
        );
      });
      return;
    }
    final scenarioName = _scenarioName(tier, leg);
    final fileName = _captureFileName(tier, leg);
    setState(() {
      _busy = true;
      _log.add(
        '[${tier.label}/${leg.label}] Export: composing wrapped capture JSON…',
      );
    });
    String? json;
    try {
      json = await Sleuth.exportCaptureJson(
        scenario: scenarioName,
        role: leg.label, // 'below' | 'at' | 'above'
        // Schema requires expectedMagnitude.min strictly positive
        // (rejects 0.0). Clamp to a small positive epsilon for any
        // sub-1-ms below leg.
        magnitudeMin: (measured - 1.0).clamp(0.001, double.infinity),
        magnitudeObserved: measured,
        magnitudeMax: measured + 1.0,
        unit: 'ms',
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterVersion: '3.41.4',
        captureCommand:
            'fvm flutter run --profile -d "iPhone 12" '
            '--dart-define=SLEUTH_CAPTURE_MODE=true',
        // Skip BUILD-derivation. The workload BUILD's `ph: 'B'` event
        // fires at frame-start (BEFORE markScenarioBegin emits inside
        // build()), so it gets filtered out of the wrapped capture
        // span — leaving an orphan `ph: 'E'` whose paired B isn't in
        // the JSON. exportCaptureJson's reconstruction would then
        // pick up some tiny system-BUILD (~200 µs) and override the
        // operator's Stopwatch measurement with a wrong value. Pass
        // empty string so derivation is bypassed and `measured`
        // (Stopwatch around _heavyCompute) is the authoritative
        // observed magnitude — same workaround NetworkMonitor uses.
        magnitudeSourceEventName: '',
        // Pre-export trace-record cross-check. Forces exportCaptureJson
        // to refuse (return null) when the leg's scenario span fails
        // its severity-name match: at + above must contain at least one
        // `sleuth.issue.heavy_compute.<active-tier>` event; below must
        // contain ZERO of them. Catches "VM service disconnected" and
        // "operator forgot to switch tier" failures at clipboard-copy
        // time instead of CI time. Below leg's role-aware inverse check
        // accepts cross-severity events (e.g. critical-below recordings
        // emit `.warning` and that is intentionally allowed because the
        // bracket only forbids `.critical` in span).
        bracketStableId: 'heavy_compute',
        bracketSeverityLabel: tier.label,
      );
    } catch (e) {
      json = null;
      if (mounted) {
        setState(() {
          _log.add('[${tier.label}/${leg.label}] Export FAILED: $e');
        });
      }
    }
    if (!mounted) return;
    if (json == null) {
      setState(() {
        _busy = false;
        _log.add(
          '[${tier.label}/${leg.label}] Export FAILED: returned null. '
          'Common causes: VM service disconnected (FRAME mode — kill the '
          'app from Xcode and re-open from the home screen so VM+ mode '
          'activates), or scenario markers missing from the trace '
          'buffer (re-tap the leg and Export within 30 s).',
        );
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
          '[${tier.label}/${leg.label}] Export OK — wrapped capture '
          '(${jsonText.length} chars) copied to iOS clipboard.',
        );
        _log.add(
          '[${tier.label}/${leg.label}] Paste into Notes / Mail / AirDrop '
          '→ send to Mac. Save the pasted JSON as $fileName under '
          'test/validation/captures/heavy_compute/.',
        );
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('Capture copied. Save as $fileName.'),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _log.add('[${tier.label}/${leg.label}] Clipboard copy FAILED: $e');
      });
    }
  }

  /// Wire-format scenario name. Warning tier keeps the v0.18.2 prefix
  /// (`heavy_compute_below`) for backward compat with the original
  /// capture files. Critical tier injects `_critical_` so the captures
  /// land at distinct file names + scenario IDs.
  String _scenarioName(_Tier tier, _Leg leg) {
    switch (tier) {
      case _Tier.warning:
        return 'heavy_compute_${leg.label}';
      case _Tier.critical:
        return 'heavy_compute_critical_${leg.label}';
    }
  }

  /// Disk file name the operator should save the wrapped capture under.
  /// Mirrors `_scenarioName` so the file/path matches the in-trace
  /// scenario marker — anyone tracing a capture back to its on-device
  /// source can read the scenario name and find the file directly.
  String _captureFileName(_Tier tier, _Leg leg) {
    switch (tier) {
      case _Tier.warning:
        return 'heavy_compute_${leg.label}.json';
      case _Tier.critical:
        return 'heavy_compute_critical_${leg.label}.json';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Same in-build trigger pattern as HeavyComputeDemo: the sin/cos
    // loop must run synchronously inside the enclosing BUILD timeline
    // event, otherwise HeavyComputeDetector's
    // `TimelinePhase.build`-filter never sees it.
    final pending = _pendingLeg;
    final pendingTier = _pendingTier;
    if (pending != null && pendingTier != null) {
      _pendingLeg = null;
      _pendingTier = null;
      final spec = _legSpec(pendingTier, pending);
      // ONE workload per build callback. Earlier versions ran a 5-retry
      // auto-tune loop INSIDE this build, but that polluted the BUILD
      // timeline event with ~50 ms of cumulative warmup work and the
      // captured run consistently drifted past the target band on
      // iPhone 12 (thermal accumulation pushed observed ms +20-40 %
      // above the auto-tune's last sampled rate).
      //
      // Adaptive learning happens ACROSS taps instead: each captured
      // run's measured ms updates `_iterationsPerMs` (in the postFrame
      // callback below) so the NEXT tap uses a refined rate. Operator
      // typically retries 2-3 times per leg before landing in-band on
      // a cold CPU; once warm, the rate stabilises.
      final rate = _iterationsPerMs ?? _calibrationIterations.toDouble();
      final iterations = (rate * spec.targetMs).round();
      final scenarioName = _scenarioName(pendingTier, pending);
      // markScenarioBegin emits the scenario.begin trace marker AND
      // (since v0.18.1) auto-resets the producer-side dedup set. Must
      // happen before the workload so the BUILD event the detector
      // observes lands inside the scenario span.
      Sleuth.markScenarioBegin(scenarioName);
      _inFlightScenarioName = scenarioName;
      final sw = Stopwatch()..start();
      _heavyCompute(iterations);
      sw.stop();
      final measuredMs = sw.elapsedMicroseconds / 1000.0;
      // Detector trace-record emission relies on the real
      // `HeavyComputeDetector` observing the BUILD event via VM
      // Timeline → SleuthController → `_recordIssuesForCapture` →
      // `CaptureHelper.recordIssue`. That pipeline only runs when
      // VM service is connected (wireless debugging or simulator).
      // USB-tethered FRAME-mode runs WILL NOT produce a
      // `sleuth.issue.heavy_compute.*` trace record, and the
      // resulting capture is NOT acceptable for `runtimeVerified`
      // — the schema audit will reject it as "Missing detector
      // trace record." That is the correct behavior; there is no
      // longer a synthetic-emission fallback.
      //
      // Sequencing note (v0.18.2): markScenarioEnd is deferred to the
      // postFrame callback below so it lands AFTER the BUILD event
      // finalizes AND after `await Sleuth.flushTimelineNow()` drives
      // the synchronous detector emission. Calling markScenarioEnd
      // here (inside build) would close the scenario span before the
      // BUILD event ends, putting the issue trace event outside the
      // span and failing the audit gate.
      // Capture the messenger BEFORE any async gaps so the lint
      // (use_build_context_synchronously) is satisfied — and so a
      // build that disposes the screen mid-dwell doesn't leak a stale
      // context into ScaffoldMessenger.of.
      final messenger = ScaffoldMessenger.of(context);
      // Validate measured ms against the leg's hard bracket band
      // (NOT the auto-tune ±8 % target band — those are the ranges
      // that satisfy `ProfileCaptureSchema.validateBracket` for the
      // active tier).
      final inBand = measuredMs >= spec.msMin && measuredMs <= spec.msMax;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // Drive the synchronous VM-poll + detector emission so the
        // `sleuth.issue.heavy_compute.<severity>` trace event lands
        // BEFORE markScenarioEnd closes the scenario span. Without
        // this await, the detector would emit on the next periodic
        // poll (~500 ms cadence) AFTER the scenario span closes and
        // the schema audit would reject the capture as "Missing
        // detector trace record".
        await Sleuth.flushTimelineNow();
        // Periodic VM poll could be in-flight when flushTimelineNow
        // returns; the v0.18.1 `_pollInFlight` guard short-circuits
        // its second poll, but the first poll's emission could land
        // microtask-after the await returns. 200 ms dwell absorbs
        // that race so any pending emission lands inside the span.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (!mounted) return;
        // Close the scenario span AFTER the flush + dwell so the
        // emitted issue trace event's timestamp falls strictly inside
        // [scenario.begin, scenario.end].
        Sleuth.markScenarioEnd(scenarioName);
        _inFlightScenarioName = null;
        // Adaptive learning: refine the rate from THIS run's actual
        // throughput so the next tap lands closer to its target. iPhone
        // CPU thermal state drifts across taps; updating the rate here
        // (after the captured run, OUTSIDE build) keeps subsequent
        // build()s clean while the screen converges to the right
        // iteration count for current device conditions.
        if (measuredMs > 0) {
          _iterationsPerMs = iterations / measuredMs;
        }
        final marker = inBand ? '✓ IN-BAND' : '✗ OUT-OF-BAND';
        setState(() {
          _lastCompletedLeg = inBand ? pending : null;
          _lastCompletedTier = inBand ? pendingTier : null;
          _lastMeasuredMs = inBand ? measuredMs : null;
          _log.add(
            '[${pendingTier.label}/${pending.label}] $marker — '
            'measured ${measuredMs.toStringAsFixed(2)} ms '
            '(must be [${spec.msMin.toStringAsFixed(1)}, '
            '${spec.msMax.toStringAsFixed(1)}] ms; '
            'iterations $iterations, '
            'rate ${_iterationsPerMs!.toStringAsFixed(0)}/ms)',
          );
          if (!inBand) {
            _log.add(
              '[${pendingTier.label}/${pending.label}] retry: tap '
              '${pending.label} again — rate refined; next tap should '
              'land closer to band. Do NOT export an out-of-band run.',
            );
          }
        });
        // Dwell so the VM Timeline drains the trailing scenario.end
        // marker before the operator taps Export.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
        setState(() {
          _busy = false;
          if (inBand) {
            _log.add(
              '[${pendingTier.label}/${pending.label}] ready to Export — '
              'tap "Export last leg" to copy the wrapped capture to '
              'clipboard.',
            );
          }
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '[${pendingTier.label}/${pending.label}] OK '
              '(${measuredMs.toStringAsFixed(2)} ms). '
              'Tap Export now.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      });
    }

    final ready = _iterationsPerMs != null && !_busy;
    final activeSpecs = {
      for (final leg in _Leg.values) leg: _legSpec(_activeTier, leg),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('HeavyCompute capture helper')),
      // SafeArea(bottom: true) prevents the scrolling log from rendering
      // under the iPhone home-indicator strip on devices without a
      // physical home button.
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Records profile-mode captures bracketing the heavy_compute '
                'thresholds. Pick the active tier — Warning (8 ms) or '
                'Critical (16 ms = 2× warning) — and the screen tunes its '
                'leg targets, scenario name, and capture file name to match. '
                'See class docstring + doc/capture_procedure.md for the '
                'full recording protocol.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text(
                    'Active tier:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<_Tier>(
                    value: _activeTier,
                    onChanged: _busy
                        ? null
                        : (next) {
                            if (next == null || next == _activeTier) return;
                            setState(() {
                              _activeTier = next;
                              _lastCompletedLeg = null;
                              _lastCompletedTier = null;
                              _lastMeasuredMs = null;
                              _log.add(
                                'Switched active tier → ${next.label} '
                                '(threshold ${next.thresholdMs} ms). '
                                'Leg targets retuned.',
                              );
                            });
                          },
                    items: const [
                      DropdownMenuItem(
                        value: _Tier.warning,
                        child: Text('Warning (8 ms)'),
                      ),
                      DropdownMenuItem(
                        value: _Tier.critical,
                        child: Text('Critical (16 ms)'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _CaptureButton(
                label:
                    'Below '
                    '(${activeSpecs[_Leg.below]!.targetMs.toStringAsFixed(1)} '
                    'ms) — '
                    '${_activeTier == _Tier.warning ? "silent" : "warning fires"}',
                subtitle: _activeTier == _Tier.warning
                    ? 'Under $_warningThresholdMs ms threshold; detector silent'
                    : 'Between $_warningThresholdMs ms and $_criticalThresholdMs '
                          'ms — fires .warning, NOT .critical',
                enabled: ready,
                onTap: () => _requestCapture(_Leg.below),
              ),
              const SizedBox(height: 8),
              _CaptureButton(
                label:
                    'At '
                    '(${activeSpecs[_Leg.at]!.targetMs.toStringAsFixed(1)} '
                    'ms) — ${_activeTier.label}',
                subtitle:
                    'In [${activeSpecs[_Leg.at]!.msMin.toStringAsFixed(1)}, '
                    '${activeSpecs[_Leg.at]!.msMax.toStringAsFixed(1)}] '
                    'at-band (±50% tolerance)',
                enabled: ready,
                onTap: () => _requestCapture(_Leg.at),
              ),
              const SizedBox(height: 8),
              _CaptureButton(
                label:
                    'Above '
                    '(${activeSpecs[_Leg.above]!.targetMs.toStringAsFixed(1)} '
                    'ms) — ${_activeTier.label}',
                subtitle:
                    'In [${activeSpecs[_Leg.above]!.msMin.toStringAsFixed(1)}, '
                    '${activeSpecs[_Leg.above]!.msMax.toStringAsFixed(1)}] '
                    'above-band',
                enabled: ready,
                onTap: () => _requestCapture(_Leg.above),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: ready ? _calibrate : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Recalibrate'),
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
      ),
    );
  }
}

/// Below / at / above leg of a single bracket. Bands resolved against
/// the active [_Tier] via [_legSpec].
enum _Leg {
  below(label: 'below'),
  at(label: 'at'),
  above(label: 'above');

  const _Leg({required this.label});

  final String label;
}

double _heavyCompute(int iterations) {
  // Same sin/cos shape as HeavyComputeDemo so calibrations transfer.
  // `Random(42)` keeps the loop deterministic per iteration count;
  // sin/cos prevents the JIT from constant-folding the body.
  final random = Random(42);
  var sum = 0.0;
  for (var i = 0; i < iterations; i++) {
    sum += sin(random.nextDouble()) * cos(random.nextDouble());
  }
  return sum;
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
