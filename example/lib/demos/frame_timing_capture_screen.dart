import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

import 'capture_driver.dart';

/// Capture helper for the `runtimeVerified` bracket on
/// `FrameTimingDetector.jank_detected.warning`, which fires when more than
/// 15 % of the judged frames miss their deadline, with at least 3 of them.
///
/// A ticker spins the UI thread for 18 ms inside its callback on every Nth
/// frame, N = round(100 / target), for targets of 5, 20 and 27 % (below,
/// at, above), over a 6 s span. The callback runs in the frame's build, so
/// a chosen frame builds for about 20 ms, over the 16.7 ms budget and under
/// the 33.3 ms severe line. The bracket reads the last record's
/// `observedJankPercent`. The screen also refuses a leg whose last record
/// saw fewer than 180 frames or whose percentage lies outside the leg's
/// band (below [0, 12], at [16, 24], above [25, 29]). A
/// `sustained_jank.critical` record in the same span does not refuse a
/// leg, because the two stable ids report on the same frames
/// independently.
///
/// Capture mode makes `FrameTimingDetector` skip its 3 s warmup and keeps
/// its budget at 16,667 µs. The screen accepts only a 59 to 61 Hz
/// display. The detector reads frames through FrameTiming, so the screen
/// calls `flushTimelineNow` before `markScenarioEnd` to record the last
/// issue inside the span.
///
/// **Procedure per leg:**
///
///   1. `cd example && fvm flutter run --profile --no-dds -d "iPhone 12" \
///         --dart-define=SLEUTH_CAPTURE_MODE=true \
///         --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"`. The VM
///      service must be connected (VM+), because the export reads the
///      detector's records from the VM timeline.
///   2. Check that the pre-flight banner shows 60 Hz, capture mode on and
///      the provenance the export stamps.
///   3. Tap Below, At or Above and wait for "capture stashed" in the log.
///      A leg allows 3 attempts, and a retry runs the same injection rate.
///   4. Tap **Export last leg** and save the clipboard text as
///      `jank_detected_<role>.json` under
///      `test/validation/captures/frame_timing/`.
class FrameTimingCaptureScreen extends StatefulWidget {
  const FrameTimingCaptureScreen({
    super.key,
    this.captureModeOverride,
    this.provenanceCheck = currentCaptureProvenance,
    this.vmConnected = _sleuthVmConnected,
    this.calls = const CaptureLegCalls(),
  });

  /// Capture mode for tests. Null reads the build's
  /// `SLEUTH_CAPTURE_MODE` dart-define.
  @visibleForTesting
  final bool? captureModeOverride;

  /// Where the screen reads the provenance its exports stamp.
  @visibleForTesting
  final CaptureProvenanceCheck Function() provenanceCheck;

  /// Whether Sleuth's VM service client is connected, which the export
  /// needs to read the detector's records.
  @visibleForTesting
  final bool Function() vmConnected;

  /// The stream, scenario and flush calls a leg makes.
  @visibleForTesting
  final CaptureLegCalls calls;

  @override
  State<FrameTimingCaptureScreen> createState() =>
      _FrameTimingCaptureScreenState();
}

bool _sleuthVmConnected() => Sleuth.diagnoseCaptureState().vmConnected;

// Detector emits at rounded jankPercent > 15 (strict). First reachable
// observed value is 16 (37/240 rounds to 15 → no fire; 38/240 rounds to
// 16 → fires). bracketThreshold = 16 aligns audit contract with detector
// reality.
const _bracketThresholdPercent = 16;

// Leg targets and the screen's bands on the percent axis, which does not
// depend on how many frames the span delivered. The bracket's at band is
// [16, 24] (atTolerance 0.50) and its above band (24, 29.6] (ceiling
// 1.85).
//   below band [0, 12]   target 5 %, the detector stays silent
//   at    band [16, 24]  target 20 %
//   above band [25, 29]  target 27 %
const _belowTargetJankPercent = 5;
const _atTargetJankPercent = 20;
const _aboveTargetJankPercent = 27;

// Spin per chosen frame. With a 1 to 3 ms baseline build a chosen frame
// builds for about 20 ms, over the 16.7 ms budget and under the 33.3 ms
// severe line. Legs differ in how often they spin, not how long.
const _spinPerFrameMs = 18;

// A spin frame takes about two vsync intervals, so a 4 s span delivered
// only about 167 frames. A 6 s span fills the 240-frame buffer past the
// 180-frame freshness check at every leg's rate.
const _scenarioDurationSec = 6;

// Wait after the ticker stops, so the last frames' timings reach Sleuth
// before the flush.
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
  // One ticker for the State, started and stopped per leg, because the
  // mixin allows only one `createTicker` call.
  late final Ticker _ticker;
  bool _busy = false;
  double? _detectedRefreshRate;
  bool _refreshRateOk = false;

  _JankLeg? _activeRetryLeg;
  int _retryCount = 0;

  _JankLeg? _lastCompletedLeg;
  String? _stashedCaptureJson;

  final List<String> _log = [];

  /// Device, OS and Flutter version stamped on exports, or why they
  /// cannot be stamped.
  late final CaptureProvenanceCheck _provenance;

  // Per-leg injection state, read by the ticker.
  int _tickerFrameCount = 0;
  int _injectModulus = 0;
  Completer<void>? _legDone;

  // The scenario and stream state a leg owns. They are fields, not
  // locals, so dispose can end the scenario and restore the streams
  // while the leg still awaits its span, a delay or the flush.
  String? _openScenario;
  bool _streamsSuspended = false;

  bool get _captureModeOn =>
      widget.captureModeOverride ??
      const bool.fromEnvironment('SLEUTH_CAPTURE_MODE');

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _provenance = widget.provenanceCheck();
    _detectRefreshRate();
  }

  @override
  void dispose() {
    // A running leg may be awaiting its span, a delay or the flush. End
    // its scenario and restore the streams now, so neither lands inside
    // another capture's span, and release the span wait so the leg
    // reaches its `mounted` check.
    final done = _legDone;
    if (done != null && !done.isCompleted) done.complete();
    _endScenario(log: false);
    unawaited(_resumeStreams(log: false));
    _ticker.dispose();
    super.dispose();
  }

  void _say(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
  }

  /// Ends the leg's open scenario once. A throw is logged, not rethrown,
  /// so it cannot replace the leg's outcome.
  void _endScenario({String label = '', bool log = true}) {
    final scenario = _openScenario;
    if (scenario == null) return;
    _openScenario = null;
    try {
      widget.calls.markScenarioEnd(scenario);
    } catch (e) {
      if (log) _say('[$label] markScenarioEnd: $e');
    }
  }

  /// Restores the timeline streams once, bounded so an unanswered VM call
  /// cannot keep the screen busy.
  Future<void> _resumeStreams({String label = '', bool log = true}) async {
    if (!_streamsSuspended) return;
    _streamsSuspended = false;
    try {
      await withCallTimeout(
        widget.calls.resumeStreams(),
        'resumeAllTimelineStreams',
      );
    } catch (e) {
      if (log) _say('[$label] resumeAllTimelineStreams: $e');
    }
  }

  /// Rate-based injector. Spinning every frame would make every frame
  /// janky, so the ticker spins only every [_injectModulus]-th frame. The
  /// ticker runs in the frame's build, so the spin adds to its build time.
  void _onTick(Duration _) {
    _tickerFrameCount++;
    if (_injectModulus == 0) return;
    if (_tickerFrameCount % _injectModulus != 0) return;
    final sw = Stopwatch()..start();
    const targetUs = _spinPerFrameMs * 1000;
    while (sw.elapsedMicroseconds < targetUs) {
      // Busy-wait with no await, so the frame's build holds the UI thread.
    }
  }

  void _detectRefreshRate() {
    // PlatformDispatcher views may not be ready in initState on iOS; defer
    // to first frame so the display info is populated.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final view = View.maybeOf(context);
      if (view == null) {
        setState(() {
          _detectedRefreshRate = null;
          _refreshRateOk = false;
          _log.add(
            'Pre-flight: no platform view is available, so refresh rate '
            'detection failed. Re-open the screen.',
          );
        });
        return;
      }
      final rate = view.display.refreshRate;
      final ok = rate >= _expected60HzMin && rate <= _expected60HzMax;
      setState(() {
        _detectedRefreshRate = rate;
        _refreshRateOk = ok;
        _log.add(
          'Pre-flight: detected refresh rate ${rate.toStringAsFixed(1)} Hz, '
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
          '[${leg.label}] ABORT: refresh rate is not 60 Hz '
          '(${_detectedRefreshRate?.toStringAsFixed(1) ?? "unknown"} Hz).',
        );
      });
      return;
    }
    if (!_captureModeOn) {
      setState(() {
        _log.add(
          '[${leg.label}] ABORT: captureMode is OFF. Restart the app '
          'with `--dart-define=SLEUTH_CAPTURE_MODE=true`. Without it, '
          'markScenarioBegin/End do nothing, and '
          'FrameTimingDetector.captureMode stays false, so the 3 s warmup '
          'gate suppresses every leg.',
        );
      });
      return;
    }
    if (!widget.vmConnected()) {
      _say(
        '[${leg.label}] ABORT: VM service not connected. Run a profile '
        'build with --no-dds so Sleuth can attach.',
      );
      return;
    }
    final provenance = _provenance.provenance;
    if (provenance == null) {
      setState(() {
        _log.add(
          '[${leg.label}] ABORT: capture provenance: '
          '${_provenance.problem}.',
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
        '[${leg.label}] attempt $_retryCount/$_maxRetriesPerLeg: '
        'rate-based injection, target ${leg.targetJankPercent}%, '
        'band [${leg.jankPercentMin}, ${leg.jankPercentMax}]',
      );
    });

    final scenario = 'frame_timing_jank_detected_${leg.label}';
    try {
      // Narrow the VM timeline streams to `Dart` for the scenario span.
      // 6 s of rendering under the default streams (Dart, Embedder, GC)
      // can overflow the VM's event ring buffer and roll the begin marker
      // off before the export reads it. The flag is set before the call,
      // because a suspension that times out may still land later.
      _streamsSuspended = true;
      await withCallTimeout(
        widget.calls.suspendStreams(),
        'suspendNonEssentialTimelineStreams',
      );
      if (!mounted) return;

      // markScenarioBegin resets FrameTimingDetector through
      // SleuthController.resetCaptureState (buffer, issues, warmup
      // anchors). `_emissionSeq` survives, so identities stay unique
      // across legs.
      widget.calls.markScenarioBegin(scenario);
      _openScenario = scenario;

      // Spin every Nth frame so about the target share of frames is
      // janky: 20 % is every 5th frame, 27 % about every 4th, 0 % never.
      final targetPct = leg.targetJankPercent;
      _injectModulus = targetPct == 0 ? 0 : (100 / targetPct).round();
      _tickerFrameCount = 0;
      final done = _legDone = Completer<void>();
      final span = Timer(const Duration(seconds: _scenarioDurationSec), () {
        if (!done.isCompleted) done.complete();
      });
      _ticker.start();
      await done.future;
      span.cancel();
      if (_ticker.isActive) _ticker.stop();
      if (!mounted) return;

      await Future<void>.delayed(
        const Duration(milliseconds: _postScenarioBarrierMs),
      );
      if (!mounted) return;

      // The flush records the detector's current issues through
      // `_recordIssuesForCapture` now, so the last emission lands inside
      // the span whatever the scan loop's timing.
      await widget.calls.flushTimeline();
      if (!mounted) return;
      _endScenario(label: leg.label);

      // The end marker must reach the VM buffer before the export reads
      // it.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      // Restore the streams before the export, so its own VM calls and
      // the live monitoring after the leg see every stream.
      await _resumeStreams(label: leg.label);
      if (!mounted) return;

      // Compose-then-stash: snapshot wrapped JSON immediately while
      // scenario markers are still present in the VM trace buffer.
      String? stashed;
      // Why the capture did not compose: the export's own reason when it
      // returned null, or the text of a failure inside the call.
      String? composeFailure;
      try {
        stashed = await withCallTimeout(
          Sleuth.exportCaptureJson(
            scenario: scenario,
            role: leg.label,
            // The schema needs a magnitudeMin above 0 and the below band
            // starts at 0, so the below leg exports 1 %, still under the
            // 16 % threshold.
            magnitudeMin: leg.jankPercentMin == 0 ? 1.0 : leg.jankPercentMin,
            // The leg's target jank percent. The audit compares it with the
            // detector's observedJankPercent and allows a 25 % difference.
            magnitudeObserved: leg.targetJankPercent.toDouble(),
            magnitudeMax: leg.jankPercentMax.toDouble(),
            unit: 'percent',
            device: provenance.device,
            deviceOsVersion: provenance.deviceOsVersion,
            flutterVersion: provenance.flutterVersion,
            captureCommand: provenance.captureCommand,
            // The jank percent comes from FrameTiming, not from a VM
            // timeline event, so the export derives nothing from BUILD
            // events.
            magnitudeSourceEventName: '',
          ),
          'exportCaptureJson',
        );
        if (stashed == null) {
          composeFailure =
              Sleuth.lastCaptureExportFailure ??
              'exportCaptureJson gave no reason';
        }
      } catch (e) {
        stashed = null;
        composeFailure = '$e';
      }

      if (!mounted) return;
      // The validator checks the stashed JSON before the operator can
      // export it, so an out-of-band leg never reaches the clipboard.
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
            '[${leg.label}] capture FAILED to compose: $composeFailure. '
            'Re-tap leg after fixing.',
          );
        } else if (validationFailure != null) {
          _log.add('[${leg.label}] Validation REJECTED: $validationFailure');
          _logRetryHint(leg);
        } else {
          _activeRetryLeg = null;
          _log.add(
            '[${leg.label}] capture stashed (${stashed.length} chars). '
            'Tap "Export last leg" to copy it to the clipboard.',
          );
        }
      });
    } catch (e) {
      // A flush past its 2 s limit, a VM call past its limit, or any other
      // failure still ends the leg with an outcome line.
      _say('[${leg.label}] FAILED: $e. Tap the leg again.');
    } finally {
      if (_ticker.isActive) _ticker.stop();
      final pending = _legDone;
      if (pending != null && !pending.isCompleted) pending.complete();
      _legDone = null;
      // Both are no-ops when the leg or dispose already did them.
      _endScenario(label: leg.label);
      await _resumeStreams(label: leg.label);
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

  /// Checks the in-span `sleuth.issue.jank_detected.warning` records of
  /// the exported capture. A below leg must hold none. An at or above leg
  /// must hold at least one, and its last record must have seen 180
  /// frames or more and carry an `observedJankPercent` inside the leg's
  /// band. A `sustained_jank.critical` record does not fail the check.
  /// Returns null on success or the reason the leg is refused.
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

    // Walk the in-span jank_detected.warning records and keep the latest.
    // The percentage over a growing buffer is not monotone. Early ratios
    // over few frames can spike, settle as the buffer fills, then drift
    // on eviction, so the largest value would pick the early spike and
    // the latest picks the settled value, as the schema's
    // `observedAxisReduction: 'last'` does. The latest record's
    // bufferSize feeds the freshness check.
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
            // The detector stamps the int percentage with
            // `toStringAsFixed(2)`; parse it and round it back to an int
            // for the band check.
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

    // A sustained_jank.critical record in the span does not refuse the
    // leg. Both stable ids report on the same frames, the bracket reads
    // only jank_detected.warning, and the audit does not require the two
    // to be exclusive.

    if (leg == _JankLeg.below) {
      if (jankWarningCount > 0) {
        return 'expected 0 `$jankEventName` events for below leg, found '
            '$jankWarningCount. Below leg is the sub-threshold baseline; '
            'detector should be silent.';
      }
    } else {
      if (jankWarningCount < 1) {
        return 'expected at least 1 `$jankEventName` event inside the '
            'scenario span, found 0. Detector did not fire. Likely causes: (1) jankPercent '
            'never crossed the 15 % gate, so the spin is too low for this '
            'device. (2) The FrameTimingDetector captureMode flag is not '
            'plumbed; check that SleuthConfig.captureMode is true. (3) The '
            'buffer did not reach steady state, so extend the scenario '
            'beyond $_scenarioDurationSec s.';
      }
      // Freshness check. The latest in-span emission must reflect a
      // near-full buffer, because the percentage over a partial buffer is
      // not reliable.
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
            'Retry the leg.';
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
          '[${leg.label}] Export OK. Copied the wrapped capture '
          '(${json.length} chars) to the iOS clipboard.',
        );
        _log.add(
          '[${leg.label}] Paste it into Notes, Mail or an AirDrop note and '
          'send it to the Mac. Save the pasted JSON as '
          'jank_detected_${leg.label}.json under '
          'test/validation/captures/frame_timing/.',
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
    final ready =
        _refreshRateOk &&
        _captureModeOn &&
        _provenance.provenance != null &&
        !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('FrameTiming capture helper')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Takes its natural height up to three quarters of the body
              // and scrolls past that, so a long pre-flight reason or a
              // large text scale cannot overflow the screen.
              Flexible(
                flex: 3,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _PreFlightBanner(
                        refreshRate: _detectedRefreshRate,
                        refreshRateOk: _refreshRateOk,
                        captureModeOn: _captureModeOn,
                        provenance: _provenance,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Records profile-mode captures for jank_detected '
                        'WARNING-tier bracketing on the '
                        'denominator-independent jankPercent axis (detector '
                        'emits at rounded jankPercent > 15; first reachable '
                        'observed value is 16). Bracket bands: at [16, 24], '
                        'above (24, 29.6]. sustained_jank.critical may '
                        'co-fire on noisy devices. That does not affect this '
                        'bracket axis, because the two ids emit in parallel. '
                        'See the class doc comment and '
                        'doc/capture_procedure.md for the full protocol.',
                        style: TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      _CaptureButton(
                        label:
                            'Below ($_belowTargetJankPercent% target), silent',
                        subtitle:
                            'No spin; baseline frames; detector stays silent',
                        enabled: ready,
                        onTap: () => _runLeg(_JankLeg.below),
                      ),
                      const SizedBox(height: 8),
                      _CaptureButton(
                        label: 'At ($_atTargetJankPercent% target), warning',
                        subtitle:
                            '$_spinPerFrameMs ms spin every ~5th frame; '
                            'in [16, 24] at-band',
                        enabled: ready,
                        onTap: () => _runLeg(_JankLeg.at),
                      ),
                      const SizedBox(height: 8),
                      _CaptureButton(
                        label:
                            'Above ($_aboveTargetJankPercent% target), '
                            'warning',
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
                    ],
                  ),
                ),
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
      ),
    );
  }
}

class _PreFlightBanner extends StatelessWidget {
  const _PreFlightBanner({
    required this.refreshRate,
    required this.refreshRateOk,
    required this.captureModeOn,
    required this.provenance,
  });

  final double? refreshRate;
  final bool refreshRateOk;
  final bool captureModeOn;
  final CaptureProvenanceCheck provenance;

  @override
  Widget build(BuildContext context) {
    final stamp = provenance.provenance;
    final allOk = refreshRateOk && captureModeOn && stamp != null;
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
              Expanded(
                child: Text(
                  'Refresh rate: '
                  '${refreshRate?.toStringAsFixed(1) ?? "detecting..."} Hz '
                  '${refreshRateOk ? "(60 Hz OK)" : "(REQUIRES 60 Hz)"}',
                  style: const TextStyle(fontSize: 12),
                ),
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
              Expanded(
                child: Text(
                  'captureMode: ${captureModeOn ? "ON" : "OFF"}'
                  '${captureModeOn ? "" : " (restart with --dart-define="
                            "SLEUTH_CAPTURE_MODE=true)"}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                stamp != null ? Icons.check : Icons.close,
                size: 16,
                color: stamp != null ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  stamp != null
                      ? 'Provenance: ${stamp.device} / '
                            '${stamp.deviceOsVersion} / '
                            'Flutter ${stamp.flutterVersion}'
                      : 'Provenance: ${provenance.problem}',
                  style: const TextStyle(fontSize: 12),
                ),
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
