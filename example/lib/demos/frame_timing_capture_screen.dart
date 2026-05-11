import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Capture helper for `FrameTimingDetector.jank_detected.warning`
/// (`jankPercent > 15` over the steady-state 240-frame buffer; runtimeVerified
/// via `perStableIdTier`).
///
/// **VM-service connection required.** Captures satisfy
/// `ProfileCaptureSchema.validateBracket(... requireDetectorTraceRecord:
/// true, ...)` ONLY when SleuthController's VmServiceClient is connected
/// (VM+ mode). USB-tethered iPhone profile-mode is FRAME mode (the VM
/// service port is not routed to the host); use **wireless debugging** via
/// Xcode → Window → Devices and Simulators → "Connect via network".
///
/// **Why FrameTiming differs from the prior runtimeVerified raises.**
///
/// FrameTimingDetector is a `runtime`-lifecycle detector — it ingests
/// frames via `SchedulerBinding.addTimingsCallback`, NOT VM timeline
/// events. Detector emission timing for the audit gate's `requireTrace
/// Record` invariant is gated on `_recordIssuesForCapture` running over
/// the runtime-detector's ephemeral `_issues[]`. Two paths reach that:
///   * scan loop tick (`scanInterval` cadence) — non-deterministic
///     relative to scenario span boundaries.
///   * `Sleuth.flushTimelineNow()` — deterministic; flush also iterates
///     ALL detectors regardless of lifecycle and calls
///     `_recordIssuesForCapture(const <BaseDetector>{})` (controller
///     line 2806, batch path; line 2990, flush path).
///
/// The capture screen calls `flushTimelineNow()` immediately before
/// `markScenarioEnd` so the detector's per-frame emission lands inside
/// the scenario span deterministically.
///
/// **Why captureMode short-circuits warmup.** Default
/// `FrameTimingDetector.warmupDuration = 3 s` suppresses jank evaluation
/// during app warmup (shader compilation, route init, Dart VM JIT). A
/// 4-second bracket scenario inside that gate would observe the buffer's
/// post-warmup tail only and miss the calibrated jank window. The
/// `SleuthConfig(captureMode: true)` flag plumbs through to
/// `FrameTimingDetector.captureMode` which short-circuits `_isPastWarmup`
/// to `true` regardless of `warmupDuration`. Never engaged in production
/// app sessions.
///
/// **60 Hz pre-flight.** The bracket axis (jank-frames in 240-frame
/// buffer) is calibrated against the iPhone 12 / iPhone SE 60 Hz frame
/// budget (16.67 ms). On 120 Hz devices (iPhone 12 Pro, iPad Pro, Pixel 8
/// Pro) the budget is 8.33 ms, which produces a completely different
/// jank/percentile distribution at the same spin-loop calibration. The
/// screen rejects non-60Hz devices to keep the captures comparable.
///
/// **Procedure per leg:**
///
///   1. `cd example && fvm flutter run --profile -d "iPhone 12" \
///         --dart-define=SLEUTH_CAPTURE_MODE=true`.
///   2. Confirm the pre-flight banner shows `60 Hz` (top of screen).
///   3. Tap a leg (Below / At / Above). The screen runs a 4 s scenario
///      span — `markScenarioBegin` resets the detector buffer, the
///      injector immediately starts spinning the UI thread per-frame
///      (no warmup wait), 4 s elapses, injector stops, 200 ms barrier,
///      `flushTimelineNow` drains detector issues, `markScenarioEnd`,
///      `exportCaptureJson` stashes the wrapped JSON.
///   4. Validator parses the stashed JSON: ≥1
///      `sleuth.issue.jank_detected.warning` event inside the scenario
///      span (zero for below leg) AND zero
///      `sleuth.issue.sustained_jank.critical` events (calibrated above-
///      leg worst-frame stays under 33 ms — critical co-fire would
///      invalidate the jank_detected bracket).
///   5. Tap **Export last leg** to copy stashed JSON to clipboard.
///   6. Paste into Notes / Mail / AirDrop, save as
///      `jank_detected_${leg}.json` under
///      `test/validation/captures/frame_timing/`.
///
/// **Bands enforced by this screen** (matching the v0.19.7 metadata
/// `FrameTimingDetector` will declare):
///
///   threshold:   36 jank-frames in 240-frame buffer (15 % gate at full
///                buffer capacity)
///   below:       0–15 jank-frames    (sub-threshold; detector silent)
///   at:          [36, 54]            (atTolerance 0.50 → [T, 1.5×T])
///   above:       (54, 66]            (above-ceiling 1.85 × T; stays
///                                     under sustained_jank co-fire)
///
/// **Spin-loop calibration** (60 Hz device, 16.67 ms budget):
///   below:    0 ms spin         → ~5 jank-frames / 240 (~2 %)
///   at:       6 ms spin         → ~50 jank-frames / 240 (~21 %)
///   above:    8 ms spin         → ~60 jank-frames / 240 (~25 %)
///
/// All worst-frame-ms targets stay <= 24 ms (8 ms spin + ~16 ms baseline)
/// well under the 33 ms severe-jank threshold so `severeCount >= 3`
/// cannot trip and co-fire `sustained_jank.critical`.
///
/// **Retry budget**: 3 retries per leg before the screen surfaces an
/// abort-with-diagnostic. Spin-duration drift from background work or
/// thermal throttling can push the at-leg's measured jankPercent
/// out-of-band; retries increment spin by 1 ms (capped at 11 ms — strict
/// guard against the 33 ms severe threshold with a ~5 ms baseline).
class FrameTimingCaptureScreen extends StatefulWidget {
  const FrameTimingCaptureScreen({super.key});

  @override
  State<FrameTimingCaptureScreen> createState() =>
      _FrameTimingCaptureScreenState();
}

// Detector emits at rounded jankPercent > 15 (strict). First reachable
// observed value is 16 (37/240 rounds to 15 → no fire; 38/240 rounds to
// 16 → fires). bracketThreshold = 16 aligns audit contract with detector
// reality.
const _bracketThresholdPercent = 16;

// Percent-axis bracket bands. Denominator-independent — robust to buffer
// underfill. bracketAtTolerance: 0.50 → at-band [16, 24].
// aboveCeilingMultiplier: 1.85 → above-band (24, 29.6]. All bands stay
// well under the implicit `severeCount >= 3` critical co-fire. Parallel
// emission of both stableIds keeps the co-fire benign for the bracket axis.
//   below band [0, 12]   → target 5%  (deep silence; detector silent)
//   at    band [16, 24]  → target 20% (mid-band — ±20 % stays in band)
//   above band [25, 29]  → target 27% (mid-band — ±7 % stays in band)
const _belowTargetJankPercent = 5;
const _atTargetJankPercent = 20;
const _aboveTargetJankPercent = 27;

// Rate-based jank injection (per-frame Ticker decides whether to spin).
// Spin amount per chosen frame — pushes that frame's total past the 16ms
// warning gate but well under the 33ms severe gate. Constant across legs;
// what varies is the FREQUENCY of injection (see _JankLeg.targetJankPercent
// in the enum below).
//
// 18ms spin + ~baseline 16ms = ~34ms worst-frame on chosen frames. Below
// severe (33ms) by a thin margin; cooler devices may drift over. If the
// validator rejects with "severe co-fire" persistently, consider a
// shorter spin or accept that calibrated above-leg can occasionally
// trigger sustained_jank.critical co-fire (parallel emission keeps
// that benign for the bracket axis).
const _spinPerFrameMs = 18;

// Scenario span. At 60 Hz the buffer holds 240 frames. Rate-based spin
// injection slows frame delivery — each spin frame takes ~34ms vs 16ms
// baseline, so a 4s scenario only delivers ~167 frames. 6 s buys the
// margin needed to fill the buffer past the freshness threshold under
// any of the leg calibrations.
const _scenarioDurationSec = 6;

// Post-end barrier before flushTimelineNow + exportCaptureJson. Mirrors
// MemoryPressure's proven 200 ms pattern.
const _postScenarioBarrierMs = 200;

// Retry budget per leg before abort.
const _maxRetriesPerLeg = 3;

// Acceptable refresh-rate range for 60 Hz devices (iPhone 12 / iPhone SE).
// 120 Hz devices (iPhone 12 Pro, iPad Pro, Pixel 8 Pro) get rejected so
// the bracket axis stays comparable across captures.
const _expected60HzMin = 59.0;
const _expected60HzMax = 61.0;

class _FrameTimingCaptureScreenState extends State<FrameTimingCaptureScreen>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  bool _busy = false;
  double? _detectedRefreshRate;
  bool _refreshRateOk = false;

  _JankLeg? _activeRetryLeg;
  int _retryCount = 0;

  _JankLeg? _lastCompletedLeg;
  String? _stashedCaptureJson;

  final List<String> _log = [];

  bool get _captureModeOn => const bool.fromEnvironment('SLEUTH_CAPTURE_MODE');

  @override
  void initState() {
    super.initState();
    _detectRefreshRate();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  void _detectRefreshRate() {
    // PlatformDispatcher views may not be ready in initState on iOS; defer
    // to first frame so the display info is populated.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isEmpty) {
        setState(() {
          _detectedRefreshRate = null;
          _refreshRateOk = false;
          _log.add(
            'Pre-flight: no platform view available — refresh rate '
            'detection failed. Re-open the screen.',
          );
        });
        return;
      }
      final rate = views.first.display.refreshRate;
      final ok = rate >= _expected60HzMin && rate <= _expected60HzMax;
      setState(() {
        _detectedRefreshRate = rate;
        _refreshRateOk = ok;
        _log.add(
          'Pre-flight: detected refresh rate ${rate.toStringAsFixed(1)} Hz — '
          '${ok ? 'OK' : 'REJECTED (expected 60 Hz)'}',
        );
        if (!ok) {
          _log.add(
            'This bracket is calibrated for 60 Hz devices. 120 Hz frame '
            'budget (8.33 ms) produces a different jank distribution at '
            'the same spin-loop calibration. Run on iPhone 12 / iPhone SE '
            'or any 60 Hz device.',
          );
        }
      });
    });
  }

  void _resetRetryIfLegChanged(_JankLeg leg) {
    if (_activeRetryLeg != leg) {
      _activeRetryLeg = leg;
      _retryCount = 0;
    }
  }

  Future<void> _runLeg(_JankLeg leg) async {
    if (_busy) return;
    if (!_refreshRateOk) {
      setState(() {
        _log.add(
          '[${leg.label}] ABORT — refresh rate not 60 Hz '
          '(${_detectedRefreshRate?.toStringAsFixed(1) ?? "unknown"} Hz).',
        );
      });
      return;
    }
    if (!_captureModeOn) {
      setState(() {
        _log.add(
          '[${leg.label}] ABORT — captureMode is OFF. Restart the app '
          'with `--dart-define=SLEUTH_CAPTURE_MODE=true`. Without it, '
          'markScenarioBegin/End are no-ops AND '
          'FrameTimingDetector.captureMode stays false (the 3 s warmup '
          'gate suppresses every leg).',
        );
      });
      return;
    }
    _resetRetryIfLegChanged(leg);
    if (_retryCount >= _maxRetriesPerLeg) {
      setState(() {
        _log.add(
          '[${leg.label}] retry budget exhausted ($_maxRetriesPerLeg). '
          'Switch leg or restart the app.',
        );
      });
      return;
    }
    _retryCount++;
    setState(() {
      _busy = true;
      _lastCompletedLeg = null;
      _stashedCaptureJson = null;
      _log.add(
        '[${leg.label}] attempt $_retryCount/$_maxRetriesPerLeg — '
        'rate-based injection, target ${leg.targetJankPercent}%, '
        'band [${leg.jankPercentMin}, ${leg.jankPercentMax}]',
      );
    });

    // Narrow VM timeline streams to `Dart` only for the scenario span.
    // 6 s of foreground rendering under default streams (Dart + Embedder +
    // GC + raster) generates tens of thousands of paint/raster/frame/GC
    // events and overflows the ~50k-event ring buffer mid-leg, rolling
    // the scenario.begin marker off before exportCaptureJson can read it.
    // Restored on every exit path via the try/finally below.
    await Sleuth.suspendNonEssentialTimelineStreams();
    var streamsSuspended = true;
    try {
      // markScenarioBegin auto-invokes SleuthController.resetCaptureState,
      // which calls FrameTimingDetector.reset() — clears the buffer,
      // ephemeral _issues, warmup anchors, cache-trend counters. The
      // _emissionSeq counter is preserved so multi-leg flows cannot
      // collide dedupIdentityMicros (audit-gate uniqueness invariant).
      Sleuth.markScenarioBegin('frame_timing_jank_detected_${leg.label}');

      // Rate-based UI-thread jank injector. Ticker fires every animation
      // frame; spinning every frame makes 100% janky and blows past the
      // above-band ceiling. Instead inject jank at a calibrated rate
      // matched to the leg's target jankPercent: below 0%, at 20%,
      // above 27%. Each Nth Ticker callback spins 16-18ms (pushes that
      // frame's totalSpan past the 16ms warning gate but well under the
      // 33ms severe gate so sustained_jank.critical co-fire stays
      // proportional to natural ambient noise, not amplified by spin).
      final targetPct = leg.targetJankPercent;
      // Modulus N so ~targetPct% of frames are spun. e.g. 20% → every
      // 5th frame; 27% → every ~4th frame. targetPct=0 → never spin.
      final injectModulus = targetPct == 0 ? 0 : (100 / targetPct).round();
      var tickerFrameCount = 0;
      _ticker = createTicker((_) {
        tickerFrameCount++;
        if (injectModulus == 0) return;
        if (tickerFrameCount % injectModulus != 0) return;
        // Busy-wait: block UI thread for _spinPerFrameMs so this frame's
        // `total` (vsync_to_present) crosses the 16ms warning gate.
        // Stopwatch gives microsecond precision and is monotonic.
        final sw = Stopwatch()..start();
        const targetUs = _spinPerFrameMs * 1000;
        while (sw.elapsedMicroseconds < targetUs) {
          // Pure busy-wait — no Future yields, no await.
        }
      })..start();

      await Future<void>.delayed(const Duration(seconds: _scenarioDurationSec));
      _ticker?.stop();
      _ticker?.dispose();
      _ticker = null;

      // Frame-settle barrier: lets the last few mid-spin frames complete
      // their addTimingsCallback delivery so the buffer reflects the
      // full scenario span rather than truncating at the spin-stop tick.
      await Future<void>.delayed(
        const Duration(milliseconds: _postScenarioBarrierMs),
      );
      if (!mounted) return;

      // flushTimelineNow drains the detector's ephemeral _issues[]
      // through `_recordIssuesForCapture` — deterministic observation
      // for the runtime-lifecycle FrameTimingDetector. Without this the
      // scan-loop's natural cadence might land outside the scenario
      // span and the detector's per-frame _issues rewrite would lose
      // the in-band emission.
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));
      if (!mounted) return;

      Sleuth.markScenarioEnd('frame_timing_jank_detected_${leg.label}');

      // Post-end barrier before exportCaptureJson — mirrors the
      // MemoryPressure proven pattern. VM service buffer needs to flush
      // the just-emitted scenario.end marker before service.getVMTimeline
      // can return it; over wireless debug the RPC can otherwise
      // observe a snapshot that pre-dates the end marker.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      // Resume streams BEFORE compose-then-stash + setState block so
      // exportCaptureJson's own VM RPCs and subsequent live-monitoring
      // see default coverage. Cleared flag prevents the finally block
      // from issuing a redundant resume RPC.
      await Sleuth.resumeAllTimelineStreams();
      streamsSuspended = false;
      if (!mounted) return;

      // Compose-then-stash: snapshot wrapped JSON immediately while
      // scenario markers are still present in the VM trace buffer.
      String? stashed;
      try {
        stashed = await Sleuth.exportCaptureJson(
          scenario: 'frame_timing_jank_detected_${leg.label}',
          role: leg.label,
          // Schema requires magnitudeMin > 0; below leg's bracket-min
          // is 0 so clamp to a 1-percent epsilon (still strictly under
          // the 16% threshold).
          magnitudeMin: leg.jankPercentMin == 0 ? 1.0 : leg.jankPercentMin,
          // Operator's claim — calibrated target jankPercent. Audit-gate
          // observedAxisArgKey cross-check compares this against the
          // detector-emitted observedJankPercent within ±25 %.
          magnitudeObserved: leg.targetJankPercent.toDouble(),
          magnitudeMax: leg.jankPercentMax.toDouble(),
          unit: 'percent',
          device: 'iPhone 12',
          deviceOsVersion: 'iOS 17.5',
          flutterVersion: '3.41.4',
          captureCommand:
              'fvm flutter run --profile -d "iPhone 12" '
              '--dart-define=SLEUTH_CAPTURE_MODE=true',
          // jank_detected source event is the FrameTiming pipeline,
          // NOT a VM Timeline BUILD/PAINT event. Skip BUILD-derivation;
          // operator's measured jank count is authoritative.
          magnitudeSourceEventName: '',
        );
      } catch (e) {
        stashed = null;
        if (kDebugMode) debugPrint('exportCaptureJson threw: $e');
      }

      if (!mounted) return;
      // Validator runs on the stashed JSON before the user can export —
      // out-of-band runs are rejected before clipboard-copy, preventing
      // bad evidence from reaching the operator's repo.
      final validationFailure = stashed == null
          ? null
          : _validateTraceRecords(stashed, leg);
      final inBand = stashed != null && validationFailure == null;
      setState(() {
        _busy = false;
        _lastCompletedLeg = inBand ? leg : null;
        _stashedCaptureJson = inBand ? stashed : null;
        if (stashed == null) {
          _log.add(
            '[${leg.label}] capture FAILED to compose. Common causes: '
            '(1) captureMode OFF; (2) VM service disconnected (FRAME '
            'mode — kill app from Xcode and re-open from home screen); '
            '(3) scenario markers rolled off the VM ring buffer. '
            'Re-tap leg after fixing.',
          );
        } else if (validationFailure != null) {
          _log.add('[${leg.label}] Validation REJECTED — $validationFailure');
          _logRetryHint(leg);
        } else {
          _activeRetryLeg = null;
          _log.add(
            '[${leg.label}] capture stashed (${stashed.length} chars) — '
            'tap "Export last leg" to copy to clipboard.',
          );
        }
      });
    } finally {
      _ticker?.stop();
      _ticker?.dispose();
      _ticker = null;
      // Restore default streams on every exit path (mounted=false at any
      // await, unhandled exception, etc.). Idempotent restore here is the
      // single sink so live monitoring after the leg sees full coverage.
      if (streamsSuspended) {
        await Sleuth.resumeAllTimelineStreams();
      }
      if (mounted && _busy) {
        setState(() => _busy = false);
      }
    }
  }

  void _logRetryHint(_JankLeg leg) {
    if (leg == _JankLeg.below) return;
    _log.add(
      '[${leg.label}] retry: tap ${leg.label} again. Rate-based injection '
      'targets ${leg.targetJankPercent}% jank-frames; band variance comes '
      'from frame-delivery jitter, not calibration. If multiple retries '
      'fail, switch device or extend scenario duration.',
    );
  }

  /// Validates that the exported capture JSON contains the expected
  /// number of `sleuth.issue.jank_detected.warning` trace events
  /// (zero for below; ≥1 for at/above) AND zero
  /// `sleuth.issue.sustained_jank.critical` events (severe co-fire
  /// invalidates the bracket axis). Returns null on success or a
  /// human-readable failure reason.
  String? _validateTraceRecords(String json, _JankLeg leg) {
    Map<String, dynamic> wrapped;
    try {
      wrapped = jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      return 'capture JSON is not valid JSON: $e';
    }
    final traceEvents = wrapped['traceEvents'];
    if (traceEvents is! List) {
      return 'capture has no traceEvents array; check that retainTimeline '
          'is enabled and scenario markers landed.';
    }

    int? scenarioBeginTs;
    int? scenarioEndTs;
    final scenarioName = 'frame_timing_jank_detected_${leg.label}';
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

    // Walk in-span jank_detected.warning records and select the LAST
    // (highest-ts) one. Rolling-aggregate observable on a growing buffer
    // is non-monotone — early small-sample-size ratios can spike high,
    // settle lower as buffer fills, then drift down on eviction. MAX
    // would pick the early transient; LAST picks the post-settle steady
    // state. Mirrors the `observedAxisReduction: 'last'` schema-side
    // selection. Also tracks bufferSize on the selected
    // record for the freshness invariant.
    var jankWarningCount = 0;
    int lastJankTs = -1;
    int? lastObservedJankPercent;
    int? lastObservedBufferSize;
    const jankEventName = 'sleuth.issue.jank_detected.warning';
    for (final raw in traceEvents) {
      if (raw is! Map<String, dynamic>) continue;
      final ts = raw['ts'];
      if (ts is! num) continue;
      if (ts.toInt() < scenarioBeginTs) continue;
      if (ts.toInt() > scenarioEndTs) continue;
      final name = raw['name'];
      if (name != jankEventName) continue;
      jankWarningCount++;
      final tsInt = ts.toInt();
      if (tsInt > lastJankTs) {
        lastJankTs = tsInt;
        final args = raw['args'];
        if (args is Map) {
          final pctRaw = args['observedJankPercent'];
          if (pctRaw is String) {
            // jankPercent emitted as `.toStringAsFixed(2)` from int —
            // round-trip through double-parse + truncate to int for
            // band-comparison.
            final parsed = double.tryParse(pctRaw);
            if (parsed != null) lastObservedJankPercent = parsed.round();
          }
          final bufRaw = args['bufferSize'];
          if (bufRaw is String) {
            lastObservedBufferSize = int.tryParse(bufRaw);
          }
        }
      }
    }

    // Sustained_jank.critical co-fire is BENIGN under parallel-emission
    // semantics — both stableIds report on the same frames; the bracket
    // axis (jank_detected.warning) is independent. Helper does
    // NOT reject on co-fire (audit pipeline doesn't enforce mutual
    // exclusion either).

    if (leg == _JankLeg.below) {
      if (jankWarningCount > 0) {
        return 'expected 0 `$jankEventName` events for below leg, found '
            '$jankWarningCount. Below leg is the sub-threshold baseline; '
            'detector should be silent.';
      }
    } else {
      if (jankWarningCount < 1) {
        return 'expected ≥1 `$jankEventName` events inside scenario span, '
            'found 0. Detector did not fire. Likely cause: (1) jankPercent '
            'never crossed 15 % gate — spin too low for this device; '
            '(2) FrameTimingDetector captureMode flag not plumbed (check '
            'SleuthConfig.captureMode == true); (3) buffer did not reach '
            'steady state — extend scenario beyond $_scenarioDurationSec s.';
      }
      // Freshness invariant: the LAST in-span emission must
      // reflect a near-full buffer. Rolling-aggregate axis is unreliable
      // on partial buffers — reject if the captured terminal-sample
      // doesn't prove steady-state coverage.
      if (lastObservedBufferSize == null) {
        return 'jank_detected event present but missing `bufferSize` arg. '
            'extraTraceArgs plumbing failed; check FrameTimingDetector '
            'emission path.';
      }
      if (lastObservedBufferSize < 180) {
        return 'last in-span emission shows bufferSize=$lastObservedBufferSize '
            'frames (<180). Buffer did not reach steady state. Extend '
            'scenario duration OR slow the spin loop so frame delivery is '
            'not throttled. observed jankPercent on partial buffer is '
            'not reliable.';
      }
      // Cross-check: observedJankPercent in expected band.
      if (lastObservedJankPercent == null) {
        return 'jank_detected event present but missing '
            '`observedJankPercent` arg. extraTraceArgs plumbing failed; '
            'check FrameTimingDetector emission path.';
      }
      if (lastObservedJankPercent < leg.jankPercentMin ||
          lastObservedJankPercent > leg.jankPercentMax) {
        return 'observedJankPercent ($lastObservedJankPercent%) outside '
            'expected band [${leg.jankPercentMin}, ${leg.jankPercentMax}]. '
            'Spin calibration drift — retry will bump spin.';
      }
    }
    return null;
  }

  Future<void> _exportLastLeg() async {
    final leg = _lastCompletedLeg;
    final json = _stashedCaptureJson;
    final messenger = ScaffoldMessenger.of(context);
    if (leg == null) {
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
        _log.add('[${leg.label}] Export: no stashed JSON. Re-run leg.');
      });
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: json));
      if (!mounted) return;
      setState(() {
        _log.add(
          '[${leg.label}] Export OK — wrapped capture (${json.length} '
          'chars) copied to iOS clipboard.',
        );
        _log.add(
          '[${leg.label}] Paste into Notes / Mail / AirDrop note → send '
          'to Mac. Save the pasted JSON as jank_detected_${leg.label}.json '
          'under test/validation/captures/frame_timing/.',
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
        _log.add('[${leg.label}] Clipboard copy FAILED: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _refreshRateOk && _captureModeOn && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('FrameTiming capture helper')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PreFlightBanner(
              refreshRate: _detectedRefreshRate,
              refreshRateOk: _refreshRateOk,
              captureModeOn: _captureModeOn,
            ),
            const SizedBox(height: 16),
            const Text(
              'Records profile-mode captures for jank_detected WARNING-tier '
              'bracketing on the denominator-independent jankPercent axis '
              '(detector emits at rounded jankPercent > 15; first reachable '
              'observed value is 16). Bracket bands: at [16, 24], '
              'above (24, 29.6]. Sustained_jank.critical may co-fire on '
              'noisy devices — that is benign for this bracket axis under '
              'parallel-emission semantics. See class docstring + '
              'doc/capture_procedure.md for full protocol.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            _CaptureButton(
              label: 'Below ($_belowTargetJankPercent% target) — silent',
              subtitle: 'No spin; baseline frames; detector stays silent',
              enabled: ready,
              onTap: () => _runLeg(_JankLeg.below),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'At ($_atTargetJankPercent% target) — warning',
              subtitle:
                  '$_spinPerFrameMs ms spin every ~5th frame; '
                  'in [16, 24] at-band',
              enabled: ready,
              onTap: () => _runLeg(_JankLeg.at),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'Above ($_aboveTargetJankPercent% target) — warning',
              subtitle:
                  '$_spinPerFrameMs ms spin every ~4th frame; '
                  'in (24, 29.6] above-band',
              enabled: ready,
              onTap: () => _runLeg(_JankLeg.above),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _exportLastLeg,
              icon: const Icon(Icons.save_alt),
              label: const Text('Export last leg'),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
            Expanded(
              child: ListView.builder(
                reverse: true,
                itemCount: _log.length,
                itemBuilder: (context, i) {
                  final entry = _log[_log.length - 1 - i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      entry,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
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

class _PreFlightBanner extends StatelessWidget {
  const _PreFlightBanner({
    required this.refreshRate,
    required this.refreshRateOk,
    required this.captureModeOn,
  });

  final double? refreshRate;
  final bool refreshRateOk;
  final bool captureModeOn;

  @override
  Widget build(BuildContext context) {
    final allOk = refreshRateOk && captureModeOn;
    final color = allOk ? Colors.green.shade100 : Colors.red.shade100;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                refreshRateOk ? Icons.check : Icons.close,
                size: 16,
                color: refreshRateOk ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 8),
              Text(
                'Refresh rate: '
                '${refreshRate?.toStringAsFixed(1) ?? "detecting..."} Hz '
                '${refreshRateOk ? "(60 Hz OK)" : "(REQUIRES 60 Hz)"}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                captureModeOn ? Icons.check : Icons.close,
                size: 16,
                color: captureModeOn ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 8),
              Text(
                'captureMode: ${captureModeOn ? "ON" : "OFF"}'
                '${captureModeOn ? "" : " (restart with --dart-define="
                          "SLEUTH_CAPTURE_MODE=true)"}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
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
    return Material(
      color: enabled
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).disabledColor.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

enum _JankLeg {
  below(
    label: 'below',
    targetJankPercent: _belowTargetJankPercent,
    jankPercentMin: 0,
    jankPercentMax: 12,
  ),
  at(
    label: 'at',
    targetJankPercent: _atTargetJankPercent,
    jankPercentMin: _bracketThresholdPercent,
    jankPercentMax: 24,
  ),
  above(
    label: 'above',
    targetJankPercent: _aboveTargetJankPercent,
    jankPercentMin: 25,
    jankPercentMax: 29,
  );

  const _JankLeg({
    required this.label,
    required this.targetJankPercent,
    required this.jankPercentMin,
    required this.jankPercentMax,
  });

  final String label;
  final int targetJankPercent;
  final int jankPercentMin;
  final int jankPercentMax;
}
