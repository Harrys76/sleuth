import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Capture helper for the planned v0.18.0 `runtimeVerified` tier raise on
/// `HeavyComputeDetector.heavy_compute` **WARNING tier only**
/// (threshold = 8 ms; strict-greater critical at 16 ms).
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
/// observes BUILD events, so `_recordIssuesForCapture` never emits the
/// required `sleuth.issue.heavy_compute.<severity>` trace record. The
/// schema audit will reject the resulting capture as "Missing detector
/// trace record" — that is the correct behavior. Earlier iterations of
/// this screen synthesised the trace record from a Stopwatch around
/// the inner loop; that path was removed because it produced evidence
/// indistinguishable from forgery and certified screen-mirrored
/// threshold logic instead of detector behavior.
///
/// Produces three deterministic profile-mode timeline captures —
/// below / at / above — that `validateBracket(... atTolerance: 0.50,
/// aboveCeilingMultiplier: 1.875)` will accept. The schema requires:
///
///  1. A `sleuth.scenario.begin` / `sleuth.scenario.end` instant-event
///     pair pinning the work window.
///  2. A `sleuth.issue.heavy_compute.warning` instant event inside that
///     window for the AT and ABOVE captures (emitted by the real
///     `HeavyComputeDetector`, NOT this screen).
///  3. The captured magnitude bracketing 8 ms per below/at/above bands.
///
/// **Bands enforced by this screen** (tied to the schema settings the
/// `HeavyComputeDetector` metadata must declare when it flips to
/// `runtimeVerified`):
///   below: ms < 8.0   (sub-threshold; detector stays silent).
///   at:    8.0 ≤ ms ≤ 12.0  (atTolerance=0.50 → [8, 8 × 1.50]).
///   above: 12.1 ≤ ms ≤ 15.0 (gap above the at-upper preserves
///                            "above ≠ at" semantics; aboveCeiling
///                            = 8 × 1.875 = 15 stays clear of the
///                            16 ms critical threshold).
///
/// The default schema `atTolerance` of 0.10 produces a [8, 8.8] ms
/// at-band, which is unreachable on iPhone 12 (per-scenario variance
/// ±25–30 % from thermal/JIT/scheduler noise). Widening to 0.50 is the
/// smallest tolerance that lets the procedure converge while staying
/// strictly below the above-ceiling. The detector's `validationMetadata`
/// must set `bracketAtTolerance: 0.50` and `aboveCeilingMultiplier:
/// 1.875` for the audit gate to accept these captures — the wider band
/// is a per-detector declaration, not the schema-wide default.
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
///  2. Open DevTools Performance tab, clear timeline.
///  3. Tap **Below**, wait for "safe to Export" log line.
///  4. DevTools → Performance → Save timeline JSON →
///     `<repo>/captures/raw/heavy_compute_below.raw.json`.
///  5. Repeat for **At** and **Above**.
///  6. Wrap each raw export via `tool/wrap_capture.dart` (see
///     `doc/capture_procedure.md`) and drop the wrapped files under
///     `test/validation/captures/heavy_compute/`.
///
/// **Auto-calibration**: sin/cos iteration counts are calibrated on
/// screen open by running a short warmup loop and dividing measured
/// duration into the target ms for each preset. Recalibrate via the
/// "Recalibrate" button if device thermal throttling or background
/// load skews the first-pass measurement.
class HeavyComputeCaptureScreen extends StatefulWidget {
  const HeavyComputeCaptureScreen({super.key});

  @override
  State<HeavyComputeCaptureScreen> createState() =>
      _HeavyComputeCaptureScreenState();
}

// Warning threshold for HeavyComputeDetector (lagThresholdMs).
// Critical fires strict-greater at 2× = 16 ms.
const _warningThresholdMs = 8;

// Per-leg target compute durations (ms). Below sits well under the
// threshold so the detector stays silent. At sits inside the at-band
// `[8, 8 × 1.1] = [8, 8.8]`. Above sits inside `(8, aboveCeiling]`
// with aboveCeiling = 8 × 1.875 = 15 ms — leaves a 1 ms guard against
// the critical threshold (>16 ms). Pick targets in the middle of each
// band so device jitter cannot push a single recording out-of-band.
// Targets sit deliberately FAR from each band's nearest threshold to
// absorb iPhone's ±25–30 % per-scenario variance:
//   below band [0, 7.9]    → target 3.0 ms  (≥ 2.6× drift still safe)
//   at    band [8, 12]     → target 10.0 ms (mid-band — ±20 % stays in band)
//   above band [12.1, 15]  → target 13.5 ms (mid-band — ±10 % stays in band)
//
// The above-band lower bound is set to 12.1 (one tick past the at-band
// upper) so at/above captures cannot land on the same magnitude. With
// the default schema atTolerance + aboveCeilingMultiplier, the schema
// allows above-band to start at 8 (just-above-threshold), which means
// at/above could overlap and become semantically indistinguishable.
// Keeping the screen-side floors disjoint preserves the bracket's
// "below < at < above" intuition.
//
// Below is the most dangerous: any measured ms > 8 triggers
// `markCaptureIssue` with `.warning`, and the schema then rejects the
// below capture as "Unexpected detector trace record". Aim well under.
const _belowTargetMs = 3.0;
const _atTargetMs = 10.0;
const _aboveTargetMs = 13.5;

// Calibration warmup. Big enough that the resulting iterations-per-ms
// rate is stable, small enough that the screen open delay is invisible.
// Empirically the cold warmup runs much faster than the in-build hot
// loop on iPhone 12 (≈1.6× rate divergence on first capture), so we
// also re-run a quick calibration pass *immediately before* every leg
// (`_recalibratePerLeg`). This adapts iteration count to current
// thermal state and keeps each leg inside its target band.
const _calibrationIterations = 500000;

class _HeavyComputeCaptureScreenState extends State<HeavyComputeCaptureScreen> {
  final List<String> _log = [];
  bool _busy = false;
  // Iterations-per-ms determined by the calibration warmup. Until set,
  // capture buttons are disabled.
  double? _iterationsPerMs;
  // Pending leg requested by a button tap; consumed inside `build` so
  // the sin/cos loop runs synchronously *inside* the build scope and
  // shows up in the VM timeline as a long Widget.build event (the
  // shape `HeavyComputeDetector` filters on). Same indirection as the
  // existing HeavyCompute demo.
  _Leg? _pendingLeg;

  // Last completed scenario, captured at the end of build() so the
  // Export button knows what scenario name + measured magnitude to
  // pass to `Sleuth.exportCaptureJson`. Cleared when the user
  // re-taps a leg.
  _Leg? _lastCompletedLeg;
  double? _lastMeasuredMs;

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
    setState(() {
      _busy = true;
      _pendingLeg = leg;
      _lastCompletedLeg = null;
      _lastMeasuredMs = null;
      _log.add(
        '[${leg.label}] scenario.begin '
        '(target ${leg.targetMs.toStringAsFixed(1)} ms)',
      );
    });
  }

  /// Composes the wrapped capture JSON for the most recent in-band
  /// leg via `Sleuth.exportCaptureJson`, writes it to the app's
  /// documents directory, and shows the resulting file path so the
  /// operator can pull it off-device (Xcode → Devices and Simulators
  /// → app container → download container, or share-sheet via Files).
  ///
  /// Refuses when:
  /// - No leg has completed in-band since screen open (or since the
  ///   last leg tap).
  /// - VM service is not connected — the procedure requires VM+
  ///   mode (re-opened iOS profile build, or wireless debugging).
  Future<void> _exportLastLeg() async {
    final leg = _lastCompletedLeg;
    final measured = _lastMeasuredMs;
    final messenger = ScaffoldMessenger.of(context);
    if (leg == null || measured == null) {
      setState(() {
        _log.add(
          'Export: no in-band leg recorded yet. Tap a leg button and '
          'wait for "ready to Export" before exporting.',
        );
      });
      return;
    }
    setState(() {
      _busy = true;
      _log.add('[${leg.label}] Export: composing wrapped capture JSON…');
    });
    String? json;
    try {
      json = await Sleuth.exportCaptureJson(
        scenario: 'heavy_compute_${leg.label}',
        magnitudeMin: (measured - 1.0).clamp(0.0, double.infinity),
        magnitudeObserved: measured,
        magnitudeMax: measured + 1.0,
        unit: 'ms',
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterVersion: '3.41.4',
        captureCommand:
            'fvm flutter run --profile -d "iPhone 12" '
            '--dart-define=SLEUTH_CAPTURE_MODE=true',
      );
    } catch (e) {
      json = null;
      if (mounted) {
        setState(() {
          _log.add('[${leg.label}] Export FAILED: $e');
        });
      }
    }
    if (!mounted) return;
    if (json == null) {
      setState(() {
        _busy = false;
        _log.add(
          '[${leg.label}] Export FAILED: returned null. Common causes: '
          'VM service disconnected (FRAME mode — kill the app from '
          'Xcode and re-open from the home screen so VM+ mode '
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
          '[${leg.label}] Export OK — wrapped capture '
          '(${jsonText.length} chars) copied to iOS clipboard.',
        );
        _log.add(
          '[${leg.label}] Paste into Notes / Mail / AirDrop note → '
          'send to Mac. Save the pasted JSON as '
          'heavy_compute_${leg.label}.json under '
          'test/validation/captures/heavy_compute/.',
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

  @override
  Widget build(BuildContext context) {
    // Same in-build trigger pattern as HeavyComputeDemo: the sin/cos
    // loop must run synchronously inside the enclosing BUILD timeline
    // event, otherwise HeavyComputeDetector's
    // `TimelinePhase.build`-filter never sees it.
    final pending = _pendingLeg;
    if (pending != null) {
      _pendingLeg = null;
      // Auto-tune iteration count BEFORE entering the scenario span.
      // Single-shot calibration is unreliable on iPhone (JIT phase +
      // thermal scaling produce ±60% drift between calibration and
      // scenario runs). Iterate up to 5 times with rate updated from
      // the prior run's measurement; converges within 2-3 retries.
      // Auto-tune passes happen OUTSIDE the scenario span, so the
      // captured span encloses only the final converged run.
      var rate = _iterationsPerMs ?? _calibrationIterations.toDouble();
      var iterations = (rate * pending.targetMs).round();
      var preMeasuredMs = 0.0;
      final lower = pending.targetMs * 0.92;
      final upper = pending.targetMs * 1.08;
      for (var retry = 0; retry < 5; retry++) {
        final tuneSw = Stopwatch()..start();
        _heavyCompute(iterations);
        tuneSw.stop();
        preMeasuredMs = tuneSw.elapsedMicroseconds / 1000.0;
        if (preMeasuredMs >= lower && preMeasuredMs <= upper) break;
        // Update rate from observed throughput, recompute iterations.
        if (preMeasuredMs > 0) {
          rate = iterations / preMeasuredMs;
          iterations = (rate * pending.targetMs).round();
        }
      }
      _iterationsPerMs = rate;
      Sleuth.markScenarioBegin('heavy_compute_${pending.label}');
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
      Sleuth.markScenarioEnd('heavy_compute_${pending.label}');
      // Post-frame: report + dwell so the VM Timeline drains the
      // scenario-end marker before DevTools export.
      // Capture the messenger BEFORE any async gaps so the lint
      // (use_build_context_synchronously) is satisfied — and so a
      // build that disposes the screen mid-dwell doesn't leak a stale
      // context into ScaffoldMessenger.of.
      final messenger = ScaffoldMessenger.of(context);
      // Validate measured ms against the leg's hard bracket band
      // (NOT the auto-tune ±8% target band — those are the ranges
      // that actually satisfy `ProfileCaptureSchema.validateBracket`):
      //   below:  ms < 8 (sub-threshold guard)
      //   at:     8 <= ms <= 8.8 (default at-band, atTolerance=0.10)
      //   above:  8 < ms <= 15 (warning band; aboveCeilingMultiplier=1.875)
      final inBand = pending.isMsInBand(measuredMs);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final marker = inBand ? '✓ IN-BAND' : '✗ OUT-OF-BAND';
        setState(() {
          _lastCompletedLeg = inBand ? pending : null;
          _lastMeasuredMs = inBand ? measuredMs : null;
          _log.add(
            '[${pending.label}] $marker — '
            'measured ${measuredMs.toStringAsFixed(2)} ms '
            '(must be ${pending.bandLabel}; '
            'iterations $iterations)',
          );
          if (!inBand) {
            _log.add(
              '[${pending.label}] retry: tap ${pending.label} again '
              'until measured ms lands in ${pending.bandLabel}. '
              'Do NOT export an out-of-band run.',
            );
          }
        });
        // Dwell so the VM Timeline drains the trailing scenario.end
        // marker + the detector's `sleuth.issue.heavy_compute.*`
        // emission before the operator taps Export.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
        setState(() {
          _busy = false;
          if (inBand) {
            _log.add(
              '[${pending.label}] ready to Export — tap "Export last '
              'leg" to write the wrapped capture to the app sandbox.',
            );
          }
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '[${pending.label}] OK '
              '(${measuredMs.toStringAsFixed(2)} ms). '
              'Tap Export now.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      });
    }

    final ready = _iterationsPerMs != null && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('HeavyCompute capture helper')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Records profile-mode captures for heavy_compute WARNING-tier '
              'bracketing (8 ms threshold). Above preset stays well under '
              '16 ms so the artifact cannot ambiently bracket the critical '
              'tier. See class docstring + doc/capture_procedure.md for '
              'the full recording protocol.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            _CaptureButton(
              label: 'Below ($_belowTargetMs ms) — passes',
              subtitle:
                  'Under $_warningThresholdMs ms threshold; '
                  'detector stays silent',
              enabled: ready,
              onTap: () => _requestCapture(_Leg.below),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'At ($_atTargetMs ms) — warning',
              subtitle: 'In [8, 12] at-band (±50% tolerance)',
              enabled: ready,
              onTap: () => _requestCapture(_Leg.at),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'Above ($_aboveTargetMs ms) — warning',
              subtitle:
                  'In [12.1, 15] above-band; '
                  'stays clear of 16 ms critical',
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
    );
  }
}

enum _Leg {
  // Bands match what ProfileCaptureSchema.validateBracket accepts when
  // the detector's metadata declares `bracketAtTolerance: 0.50` and
  // `aboveCeilingMultiplier: 1.875`:
  //   below: ms < 8.0   (sub-threshold; detector must NOT fire).
  //   at:    8.0 ≤ ms ≤ 12.0 (atTolerance=0.50 → [8, 8 × 1.50]).
  //   above: 12.1 ≤ ms ≤ 15.0 (screen-side floor 12.1 keeps at and
  //                            above magnitudes disjoint; the schema
  //                            itself only requires above > 8 and
  //                            ≤ aboveCeiling).
  // The 10 % default at-band [8, 8.8] and 30 % band [8, 10.4] are both
  // unreachable on iPhone 12 — per-scenario variance is ±25–30 %
  // regardless of pre-warmup or auto-tuning. 50 % is the lowest at-
  // tolerance that lets the procedure converge in 1–2 retries while
  // still proving "at threshold" semantics. Tolerances >0.875 would
  // push the at-upper-bound past the above-ceiling and cause schema-
  // side band collapse.
  below(label: 'below', targetMs: _belowTargetMs, msMin: 0.0, msMax: 7.9),
  at(label: 'at', targetMs: _atTargetMs, msMin: 8.0, msMax: 12.0),
  above(label: 'above', targetMs: _aboveTargetMs, msMin: 12.1, msMax: 15.0);

  const _Leg({
    required this.label,
    required this.targetMs,
    required this.msMin,
    required this.msMax,
  });
  final String label;
  final double targetMs;
  final double msMin;
  final double msMax;

  bool isMsInBand(double ms) => ms >= msMin && ms <= msMax;
  String get bandLabel =>
      '[${msMin.toStringAsFixed(1)}, '
      '${msMax.toStringAsFixed(1)}] ms';
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
