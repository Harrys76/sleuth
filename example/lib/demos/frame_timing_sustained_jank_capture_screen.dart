// Operator capture-helper for FrameTimingDetector.sustained_jank.critical
// runtimeVerified raise. Mirrors the warning-tier capture screen but
// targets severeCount-band instead of jankPercent-band:
//
//   below: severeCount = 1 (warning fires; critical does NOT — schema's
//                          name-scoped no-record check accepts the absence
//                          of `sleuth.issue.sustained_jank.critical`).
//   at:    severeCount = 3 (gate exactly; critical fires).
//   above: severeCount = 5 (critical fires with higher count; stays under
//                          aboveCeilingMultiplier=2.5 → 7.5 ceiling).
//
// Injection differs from warning-tier capture: instead of rate-based
// 18 ms spin (every Nth frame), this screen does FIXED-COUNT 35 ms spin
// (push K specific frames past the 33 ms severe gate). Constant per-frame
// spin amount; what varies per leg is the COUNT of severe frames injected.
//
// Run procedure (60 Hz device, profile mode):
//   1. `cd example && fvm flutter run --profile -d "iPhone 12" \
//        --dart-define=SLEUTH_CAPTURE_MODE=true`.
//   2. Open "FrameTiming Sustained-Jank Capture" demo.
//   3. Tap each leg button (Below / At / Above) in sequence.
//   4. Each leg: 6 s scenario span → flushTimelineNow → markScenarioEnd.
//      Validator runs on stashed JSON; out-of-band runs are rejected
//      before clipboard copy.
//   5. Tap "Export last leg" after a successful run; paste the clipboard
//      JSON into `sustained_jank_${leg}.json` under
//      `test/validation/captures/frame_timing/`.
//
// Refresh-rate gate: 60 Hz only. 120 Hz devices reject — different frame
// budget produces a different severe-jank distribution.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

class FrameTimingSustainedJankCaptureScreen extends StatefulWidget {
  const FrameTimingSustainedJankCaptureScreen({super.key});

  @override
  State<FrameTimingSustainedJankCaptureScreen> createState() =>
      _FrameTimingSustainedJankCaptureScreenState();
}

// Detector fires sustained_jank at severeCount >= 3. Bracket spec:
// threshold=3, atTolerance=0.40 → at-band [3, 4.2], aboveCeilingMultiplier=2.5
// → above-band (4.2, 7.5]. Below leg is severeCount=1 (warning fires;
// critical doesn't).
const _bracketThresholdSevere = 3;

// Below leg = pure idle scenario, NO spin injection. Targeting 1 severe
// frame + ambient iOS profile-mode jank can push severeCount to ≥3 and
// fire critical, which fails the server-side bracket check
// (role='below' requires ZERO sustained_jank.critical events in span).
// Idle scenario keeps severeCount at 0 reliably.
const _belowTargetSevereCount = 0;
const _atTargetSevereCount = 3;
const _aboveTargetSevereCount = 5;

// Spin per severe frame: pushes that frame's totalSpan past the 33 ms
// severe gate. Baseline ~16 ms + 35 ms spin = ~51 ms total. Well over
// the gate; well under any realistic observation noise.
const _severeSpinPerFrameMs = 35;

// At/above legs need 6 s for the buffer to fill enough that the
// detector's K=`targetSevereCount` injected severe frames hit the
// `severeCount >= 3` gate without ambient jank diluting them out of
// the rolling 240-frame window.
const _scenarioDurationSec = 6;

// Below leg uses the same 6 s scenario length as at/above. Earlier
// 50 ms / 100 ms shortened-scenario optimizations were based on a
// false premise: `markScenarioBegin/End` wrap the 200 ms post-
// barrier + `flushTimelineNow`, so the on-wire scenario span is
// ~250 ms+ regardless of `_belowScenarioDurationMs` and the
// detector's 5-frame `_evaluateJank` gate is reached inside the span
// either way. Below-leg correctness instead relies on the absence-
// of-event check: the leg is idle (no severe-frame injection) and
// the role='below' validation rejects only on presence of in-span
// `sleuth.issue.sustained_jank.critical` events. Captured below.json
// recorded under the prior 100 ms constant remains valid because
// the absence check is span-content-based, not span-duration-based.
const _belowScenarioDurationMs = _scenarioDurationSec * 1000;
const _postScenarioBarrierMs = 200;
const _maxRetriesPerLeg = 3;
const _expected60HzMin = 59.0;
const _expected60HzMax = 61.0;

// Spacing between consecutive injected severe frames. With 60 Hz delivery
// the buffer holds 240 frames over 4 s; spacing severe frames by 60
// frames (1 s) gives the detector's _evaluateJank loop time to observe
// each fire point against a fresh window.
const _severeFrameSpacingFrames = 60;

class _FrameTimingSustainedJankCaptureScreenState
    extends State<FrameTimingSustainedJankCaptureScreen>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  bool _busy = false;
  double? _detectedRefreshRate;
  bool _refreshRateOk = false;

  _SevereLeg? _activeRetryLeg;
  int _retryCount = 0;

  _SevereLeg? _lastCompletedLeg;
  String? _stashedCaptureJson;

  final List<String> _log = [];

  // Saved original `debugPrint` so dispose() can restore it. While the
  // screen is alive, debugPrint output matching Sleuth.exportCaptureJson
  // null-return reasons gets piped into the on-screen log so the
  // operator can see WHY a capture was rejected without needing
  // Console.app or `flutter run` terminal access.
  DebugPrintCallback? _originalDebugPrint;

  bool get _captureModeOn => const bool.fromEnvironment('SLEUTH_CAPTURE_MODE');

  @override
  void initState() {
    super.initState();
    _detectRefreshRate();
    _installDebugPrintCapture();
  }

  @override
  void dispose() {
    _restoreDebugPrint();
    _ticker?.dispose();
    super.dispose();
  }

  void _installDebugPrintCapture() {
    _originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      _originalDebugPrint?.call(message, wrapWidth: wrapWidth);
      if (message == null) return;
      // Filter to Sleuth's capture-mode messages so the on-screen log
      // doesn't fill with framework noise. The exportCaptureJson +
      // markScenarioBegin/End diagnostic messages all start with
      // "Sleuth.".
      if (!message.startsWith('Sleuth.')) return;
      if (!mounted) return;
      setState(() {
        _log.add('[debugPrint] $message');
      });
    };
  }

  void _restoreDebugPrint() {
    if (_originalDebugPrint != null) {
      debugPrint = _originalDebugPrint!;
      _originalDebugPrint = null;
    }
  }

  void _detectRefreshRate() {
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
            'Bracket calibrated for 60 Hz. 120 Hz frame budget (8.33 ms) '
            'produces a different severe-jank distribution at the same '
            'spin-loop calibration. Run on iPhone 12 / iPhone SE.',
          );
        }
      });
    });
  }

  void _resetRetryIfLegChanged(_SevereLeg leg) {
    if (_activeRetryLeg != leg) {
      _activeRetryLeg = leg;
      _retryCount = 0;
    }
  }

  Future<void> _runLeg(_SevereLeg leg) async {
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
        'fixed-count severe injection, target ${leg.targetSevereCount} '
        'severe frames, band [${leg.severeCountMin}, ${leg.severeCountMax}]',
      );
    });

    await Sleuth.suspendNonEssentialTimelineStreams();
    var streamsSuspended = true;
    try {
      Sleuth.markScenarioBegin('frame_timing_sustained_jank_${leg.label}');

      // Fixed-count severe injector. Ticker fires every animation frame.
      // Spin 35 ms ONLY on the K specific frames where K =
      // leg.targetSevereCount. Spacing = 60 frames so each severe frame
      // lands on a fresh _evaluateJank window.
      final targetSevere = leg.targetSevereCount;
      var tickerFrameCount = 0;
      var severeFiredCount = 0;
      _ticker = createTicker((_) {
        tickerFrameCount++;
        if (severeFiredCount >= targetSevere) return;
        final firePoint = (severeFiredCount + 1) * _severeFrameSpacingFrames;
        if (tickerFrameCount < firePoint) return;
        // Busy-wait pushes frame total past 33 ms severe gate.
        final sw = Stopwatch()..start();
        const targetUs = _severeSpinPerFrameMs * 1000;
        while (sw.elapsedMicroseconds < targetUs) {
          // Pure busy-wait — no Future yields, no await.
        }
        severeFiredCount++;
      })..start();

      final scenarioDuration = leg == _SevereLeg.below
          ? const Duration(milliseconds: _belowScenarioDurationMs)
          : const Duration(seconds: _scenarioDurationSec);
      await Future<void>.delayed(scenarioDuration);
      _ticker?.stop();
      _ticker?.dispose();
      _ticker = null;

      await Future<void>.delayed(
        const Duration(milliseconds: _postScenarioBarrierMs),
      );
      if (!mounted) return;

      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));
      if (!mounted) return;

      Sleuth.markScenarioEnd('frame_timing_sustained_jank_${leg.label}');

      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      await Sleuth.resumeAllTimelineStreams();
      streamsSuspended = false;
      if (!mounted) return;

      // Injection-completeness guard. The ticker may exit with
      // severeFiredCount < targetSevere if the screen lifecycle
      // interrupts it (mount/unmount, scheduling pressure, async
      // delay variance). Without this check, server-side bracket
      // validation could pass on ambient-only severeCount that
      // crossed the gate without operator-injected K severe frames
      // landing — confounded evidence. Below leg targets 0, so
      // skip the check there.
      if (leg != _SevereLeg.below && severeFiredCount < leg.targetSevereCount) {
        setState(() {
          _busy = false;
          _lastCompletedLeg = null;
          _stashedCaptureJson = null;
          _log.add(
            '[${leg.label}] capture REJECTED — ticker delivered '
            '$severeFiredCount/${leg.targetSevereCount} severe frames. '
            'Re-run the leg; common causes: app backgrounded mid-leg, '
            'scheduling pressure delayed firePoint reach, or scenario '
            'duration too short.',
          );
          _logRetryHint(leg);
        });
        return;
      }

      String? stashed;
      try {
        stashed = await Sleuth.exportCaptureJson(
          scenario: 'frame_timing_sustained_jank_${leg.label}',
          role: leg.label,
          // Schema requires magnitudeMin > 0 AND
          // min <= observed <= max. Below leg targets 0 severe frames
          // (idle scenario) but the schema cannot encode that — clamp
          // both min and observed to a 1-frame epsilon. The bracket's
          // role='below' check ignores the observed value; only the
          // ABSENCE of in-span sustained_jank.critical events matters.
          magnitudeMin: leg.severeCountMin == 0 ? 1.0 : leg.severeCountMin,
          magnitudeObserved: leg.targetSevereCount == 0
              ? 1.0
              : leg.targetSevereCount.toDouble(),
          magnitudeMax: leg.severeCountMax.toDouble(),
          unit: 'frames',
          device: 'iPhone 12',
          deviceOsVersion: 'iOS 17.5',
          flutterVersion: '3.41.4',
          captureCommand:
              'fvm flutter run --profile -d "iPhone 12" '
              '--dart-define=SLEUTH_CAPTURE_MODE=true',
          // sustained_jank source event is the FrameTiming pipeline, not
          // a VM Timeline BUILD/PAINT event. Skip BUILD-derivation;
          // operator's measured severe count is authoritative.
          magnitudeSourceEventName: '',
          bracketStableId: 'sustained_jank',
          bracketSeverityLabel: 'critical',
        );
      } catch (e) {
        stashed = null;
        if (kDebugMode) debugPrint('exportCaptureJson threw: $e');
      }

      if (!mounted) return;
      // exportCaptureJson does its own bracket cross-check via the
      // bracketStableId+bracketSeverityLabel params: returns null when
      // role='below' has any in-span sustained_jank.critical events,
      // returns null when role='at'/'above' has zero. No client-side
      // re-validation needed; non-null = in-band.
      final inBand = stashed != null;
      setState(() {
        _busy = false;
        _lastCompletedLeg = inBand ? leg : null;
        _stashedCaptureJson = inBand ? stashed : null;
        if (stashed == null) {
          _log.add(
            '[${leg.label}] capture FAILED to compose. Common causes: '
            '(1) VM service disconnected (FRAME mode — kill the app '
            'from Xcode and re-open from the home screen so VM+ mode '
            'activates); (2) scenario markers rolled off the VM ring '
            'buffer (re-tap leg within 30 s); (3) for at/above: '
            'detector did not fire (spin amount under 33 ms severe '
            'gate); (4) for below: detector fired critical when it '
            'should not have (lower spin or fewer scheduled frames).',
          );
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
      if (streamsSuspended) {
        await Sleuth.resumeAllTimelineStreams();
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  void _logRetryHint(_SevereLeg leg) {
    _log.add(
      '[${leg.label}] retry: ensure 60 Hz, foreground, no thermal '
      'throttling. Spin amount per severe frame = '
      '${_severeSpinPerFrameMs}ms; targetCount=${leg.targetSevereCount}.',
    );
  }

  Future<void> _exportLastLeg() async {
    final leg = _lastCompletedLeg;
    final stashed = _stashedCaptureJson;
    if (leg == null || stashed == null) {
      setState(() {
        _log.add(
          'Export skipped — no in-band leg completed. Tap a leg button first.',
        );
      });
      return;
    }
    final fileName = 'sustained_jank_${leg.label}.json';
    setState(() => _busy = true);
    try {
      // exportCaptureJson returns the capture body directly
      // (`{traceEvents, sleuthMetadata}`) already pretty-printed. Copy
      // verbatim — no wrapper to unwrap.
      await Clipboard.setData(ClipboardData(text: stashed));
      if (!mounted) return;
      setState(() {
        _log.add(
          'Capture copied to clipboard. Save as $fileName under '
          'test/validation/captures/frame_timing/.',
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            'Capture copied. Save as $fileName under '
            'test/validation/captures/frame_timing/.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('FrameTiming Sustained-Jank Capture')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Records profile-mode captures for sustained_jank '
                'CRITICAL-tier runtimeVerified raise. 60 Hz only. '
                'severeCount targets: below=1 (warning fires; critical '
                'silent), at=3 (critical fires), above=5.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              _PreflightStrip(
                refreshRate: _detectedRefreshRate,
                refreshRateOk: _refreshRateOk,
                captureModeOn: _captureModeOn,
              ),
              const SizedBox(height: 16),
              for (final leg in _SevereLeg.values) ...[
                ElevatedButton(
                  onPressed: _busy ? null : () => _runLeg(leg),
                  child: Text(
                    '${leg.label.toUpperCase()} leg — target '
                    '${leg.targetSevereCount} severe frames',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _busy || _stashedCaptureJson == null
                    ? null
                    : _exportLastLeg,
                icon: const Icon(Icons.copy),
                label: Text(
                  _lastCompletedLeg == null
                      ? 'Export last leg (no in-band leg yet)'
                      : 'Export last leg → '
                            'sustained_jank_${_lastCompletedLeg!.label}.json',
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  itemCount: _log.length,
                  itemBuilder: (_, idx) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      _log[_log.length - 1 - idx],
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreflightStrip extends StatelessWidget {
  final double? refreshRate;
  final bool refreshRateOk;
  final bool captureModeOn;
  const _PreflightStrip({
    required this.refreshRate,
    required this.refreshRateOk,
    required this.captureModeOn,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        Chip(
          label: Text(
            refreshRate == null
                ? 'Refresh: detecting…'
                : 'Refresh: ${refreshRate!.toStringAsFixed(1)} Hz '
                      '${refreshRateOk ? "✓" : "✗"}',
          ),
          backgroundColor: refreshRateOk
              ? Colors.green.shade100
              : Colors.red.shade100,
        ),
        Chip(
          label: Text(
            captureModeOn ? 'captureMode: ON' : 'captureMode: OFF (rebuild)',
          ),
          backgroundColor: captureModeOn
              ? Colors.green.shade100
              : Colors.red.shade100,
        ),
      ],
    );
  }
}

enum _SevereLeg {
  below(
    label: 'below',
    targetSevereCount: _belowTargetSevereCount,
    severeCountMin: 0,
    severeCountMax: 2,
  ),
  at(
    label: 'at',
    targetSevereCount: _atTargetSevereCount,
    severeCountMin: _bracketThresholdSevere,
    severeCountMax: 4,
  ),
  above(
    label: 'above',
    targetSevereCount: _aboveTargetSevereCount,
    severeCountMin: 5,
    severeCountMax: 7,
  );

  final String label;
  final int targetSevereCount;
  final int severeCountMin;
  final int severeCountMax;
  const _SevereLeg({
    required this.label,
    required this.targetSevereCount,
    required this.severeCountMin,
    required this.severeCountMax,
  });
}
