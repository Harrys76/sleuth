import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Capture helper for the v0.19.4 `runtimeVerified` raise on
/// `PlatformChannelDetector.platform_channel_traffic` **WARNING tier**
/// (frequency axis only — `> 20` calls per 1 s evaluation window).
///
/// **VM-service connection required.** Same constraint as the other
/// runtimeVerified capture screens: SleuthController's VmServiceClient
/// must be connected (VM+ overlay) so `_recordIssuesForCapture` lands
/// the `sleuth.issue.platform_channel_traffic.warning` trace event
/// inside the scenario span. USB-tethered iPhone profile-mode is FRAME
/// mode and does not work; use **wireless debugging** via Xcode →
/// Window → Devices and Simulators → "Connect via network" or the iOS
/// simulator.
///
/// **Why the procedure differs from `MemoryPressureCaptureScreen`.**
///
/// PlatformChannel's workload is short (~1.5 s of method calls) and
/// has no slow-onset detector axis like heap_growing's 10 s sustained
/// regression. Three differences from the heap_growing screen:
///
///   - **No calibration phase.** The send rate is set directly by the
///     batch size and tick interval — no GC / thermal variance to
///     calibrate around. The loop fires K parallel `invokeMethod`
///     calls per 200 ms tick, so the per-second rate is `K * 5`.
///   - **No stream narrowing.** The 30 s heap_growing scenario
///     overflows the VM ring buffer under default streams, so its
///     screen narrows to `Dart` only. The 3.2 s platform-channel
///     scenario stays well inside buffer capacity even with
///     `Dart + Embedder + GC` enabled, so leaving streams at default
///     keeps live monitoring uncompromised.
///   - **`debugProfilePlatformChannels` flag scope.** Real
///     `MethodChannel.invokeMethod` calls only emit timeline events
///     when this Flutter-framework flag is true. Set it in `_runLeg`
///     before `markScenarioBegin` and restored in `finally` so
///     subsequent unrelated channel traffic does NOT pollute live
///     monitoring with `Platform Channel send …` events at full
///     rate. Per-leg lifecycle, not initState/dispose.
///
/// **Procedure per leg:**
///
///   1. `cd example && fvm flutter run --profile -d DEVICE \
///         --dart-define=SLEUTH_CAPTURE_MODE=true`.
///   2. Wait ≥ 3 s after app launch (lets VM service connection settle
///      and the parser's per-tid cursor map initialize).
///   3. Tap a leg (Below / At / Above). Workload runs ≥ 1.5 s of
///      `MethodChannel.invokeMethod('ping')` calls in parallel batches
///      followed by ≥ 1500 ms dwell, then `markScenarioEnd`.
///   4. Wait for "ready to Export" log line.
///   5. Tap **Export last leg**. The wrapped capture JSON is parsed
///      to verify EXACTLY ONE
///      `sleuth.issue.platform_channel_traffic.warning` trace record
///      exists inside the scenario span (zero for below, exactly one
///      for at / above; two means the cooldown failed and is a
///      capture-quality failure that aborts export). On success, JSON
///      is copied to the iOS clipboard.
///   6. Paste into Notes / Mail / AirDrop, save as
///      `platform_channel_traffic_${leg}.json` under
///      `test/validation/captures/platform_channel/`.
///
/// **Bands enforced by this screen** (tied to the schema settings the
/// `PlatformChannelDetector` metadata declares as of v0.19.4):
///
///   below: 1 ≤ calls/sec ≤ 19   (sub-threshold; detector silent.
///                                schema requires magnitudeMin > 0,
///                                so zero is not allowed.)
///   at:    20 ≤ calls/sec ≤ 30  (atTolerance 0.50 → [T, 1.5×T])
///   above: 31 ≤ calls/sec ≤ 39  (above-ceiling 1.95 × T = 39, kept
///                                strictly under the 41-call critical
///                                escalation boundary so the
///                                above-leg cannot ambiently bracket
///                                the critical tier)
///
/// Per-leg send-rate targets are picked mid-band so iOS scheduling
/// jitter stays inside the band without retries:
///
///   below:  3 calls / 200 ms tick = 15/sec
///   at:     5 calls / 200 ms tick = 25/sec
///   above:  7 calls / 200 ms tick = 35/sec
///
/// **Parallel send.** Each tick fires K parallel `invokeMethod` Futures
/// via `Future.wait` rather than sequential awaits. iOS round-trip
/// latency on `MethodChannel` averages ~12–25 ms over a USB cable and
/// 30–80 ms over wireless debug — sequential awaits would cap the
/// effective send rate at ~12–80/sec depending on link, making the
/// `above` band unreachable on wireless. Parallel batches let the
/// per-tick cost be the slowest single round-trip, not the sum.
///
/// **Cooldown.** The detector emits ONCE per fire then suppresses for
/// the next 3 evaluation cycles. With a 1.5 s scenario span and 1 s
/// evaluation windows, exactly one emission lands per leg — the
/// cooldown only matters as a guard against the second second
/// firing again, which it does not under the chosen budget.
///
/// **Retry budget**: 5 retries per leg before the screen surfaces
/// abort-with-diagnostic. Send-rate variance is tighter than GC
/// variance but iOS may still drop or coalesce events under
/// thermal pressure.
class PlatformChannelCaptureScreen extends StatefulWidget {
  const PlatformChannelCaptureScreen({super.key});

  @override
  State<PlatformChannelCaptureScreen> createState() =>
      _PlatformChannelCaptureScreenState();
}

// Detector threshold (warning tier).
const _warningThresholdCallsPerSec = 20;

// Per-leg target *operator-send* rates (calls/sec) and batch geometry.
// In-band gating uses the DETECTOR-stamped count (parsed from the
// capture's in-span `args.observedCount` and re-injected into the
// JSON's `expectedMagnitude.observed`), not the operator send rate.
// iOS scheduling and `MethodChannel` coalescing skew detector count
// vs. operator send count by ±10–20 % depending on thermal state.
// Operator targets pick rates that LAND THE DETECTOR mid-band on a
// typical iPhone 12; retries refine.
//
//   below band (operator < 20/sec, detector silent) →
//                                     3 calls / 200 ms = 15/sec
//   at    band (detector ∈ [20, 30]) → 5 calls / 200 ms = 25/sec
//   above band (detector ∈ [31, 39]) → 9 calls / 200 ms = 45/sec
//                                     (operator overshoots ~+30 %
//                                     above-band so coalescing leaves
//                                     detector count in band; previous
//                                     7/200ms produced detector ~28 in
//                                     at-band, mislabeling above-leg)
const _belowCallsPerBatch = 3;
const _atCallsPerBatch = 5;
const _aboveCallsPerBatch = 9;
const _batchTickMs = 200;

const _belowTargetCps = _belowCallsPerBatch * 1000 ~/ _batchTickMs;
const _atTargetCps = _atCallsPerBatch * 1000 ~/ _batchTickMs;
const _aboveTargetCps = _aboveCallsPerBatch * 1000 ~/ _batchTickMs;

// Wall-clock budget for the call-emission phase. The detector evaluates
// on a 1 s window boundary; 1500 ms covers exactly one evaluation
// crossing plus a partial second of margin so the firing window's count
// is fully accumulated before the next evaluation triggers.
const _callPhaseDurationMs = 1500;

// Dwell after call phase ends. The detector evaluates on a wall-clock
// 1 s window boundary, NOT aligned to scenario start — depending on
// boundary phase, the firing window's emission can land anywhere up
// to ~1 s after allocation ends. 1500 ms covers three detector poll
// cycles (500 ms cadence) plus emission landing margin so the trace
// record lands inside the scenario span even when the eval boundary
// falls at the unfortunate end of the allocation phase. Recorded
// captures with 800 ms had only 43 ms scenario-end headroom on the
// at-leg — bumped here so future re-captures on warmer/throttled
// devices stay inside the span without retry churn.
const _postCallDwellMs = 1500;

// Extra barrier after markScenarioEnd before exportCaptureJson reads
// the VM trace buffer. Over wireless debug the RPC may otherwise
// observe a snapshot that pre-dates the end marker.
const _postEndBarrierMs = 200;

const _maxRetriesPerLeg = 5;

// Reused channel set up by `example/ios/Runner/AppDelegate.swift:21-25`
// (`channel.setMethodCallHandler { _, result in result(nil) }`). The
// `'ping'` method name is arbitrary — the handler returns nil for
// every call. The channel + handler are registered at app launch via
// `didInitializeImplicitFlutterEngine`, so they are available the
// instant this screen is opened.
const _channelName = 'sleuth_demo_channel';
const _channelMethod = 'ping';

class _PlatformChannelCaptureScreenState
    extends State<PlatformChannelCaptureScreen> {
  final List<String> _log = [];
  final MethodChannel _channel = const MethodChannel(_channelName);
  bool _busy = false;

  // Retry counter per leg (resets when the leg lands in-band or the
  // operator switches to a different leg).
  _ChannelLeg? _activeRetryLeg;
  int _retryCount = 0;

  // Last completed scenario, captured at the end of the leg run so the
  // Export button knows what scenario name + measured magnitude to
  // pass to `Sleuth.exportCaptureJson`. Cleared when the user re-taps
  // a leg.
  _ChannelLeg? _lastCompletedLeg;
  double? _lastMeasuredCps;

  // Wrapped capture JSON composed immediately after markScenarioEnd
  // and stashed here so the operator's tap on Export does not race
  // the VM trace ring buffer. (Same compose-then-stash pattern as
  // `MemoryPressureCaptureScreen`.)
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
      'Wait ≥ 3 s after app launch before tapping a leg — '
      'VM service connection needs to settle.',
    );
  }

  void _resetRetryIfLegChanged(_ChannelLeg leg) {
    if (_activeRetryLeg != leg) {
      _activeRetryLeg = leg;
      _retryCount = 0;
    }
  }

  Future<void> _runLeg(_ChannelLeg leg) async {
    if (_busy) return;
    if (!_captureModeOn) {
      setState(() {
        _log.add(
          '[${leg.label}] ABORT — captureMode is OFF. Restart the app '
          'with `--dart-define=SLEUTH_CAPTURE_MODE=true`. Without it '
          'markScenarioBegin/End are no-ops, no scenario markers reach '
          'the VM trace buffer, and Export will fail with no markers '
          'found.',
        );
      });
      return;
    }
    _resetRetryIfLegChanged(leg);
    if (_retryCount >= _maxRetriesPerLeg) {
      setState(() {
        _log.add(
          '[${leg.label}] retry budget exhausted ($_maxRetriesPerLeg). '
          'Switch leg or hot-restart the app.',
        );
      });
      return;
    }
    _retryCount++;
    setState(() {
      _busy = true;
      _lastCompletedLeg = null;
      _lastMeasuredCps = null;
      _stashedCaptureJson = null;
      _log.add(
        '[${leg.label}] attempt $_retryCount/$_maxRetriesPerLeg — '
        'target ${leg.targetCps} calls/sec '
        '(${leg.callsPerBatch} per ${_batchTickMs}ms tick), '
        'band [${leg.cpsMin}, ${leg.cpsMax}] calls/sec',
      );
    });

    // Enable real platform-channel timeline events for the duration
    // of this leg only. `debugProfilePlatformChannels` is a
    // top-level Flutter-framework flag — leaving it true after the
    // leg completes would pollute live monitoring with
    // `Platform Channel send …` events from every subsequent
    // unrelated channel call (image cache, plugin platform views,
    // etc.). Restore in `finally` so this scope is the single
    // source of truth.
    final priorFlag = debugProfilePlatformChannels;
    debugProfilePlatformChannels = true;
    try {
      if (!mounted) return;

      Sleuth.markScenarioBegin('platform_channel_traffic_${leg.label}');

      final sw = Stopwatch()..start();
      var totalCallsSent = 0;
      var batchFailures = 0;
      while (sw.elapsedMilliseconds < _callPhaseDurationMs) {
        // Parallel send: K invokeMethod Futures fire concurrently per
        // tick. Sequential awaits would serialize the round-trips and
        // cap the effective send rate at ~12–80/sec on wireless,
        // making the above band unreachable. Future.wait completes
        // when the slowest single round-trip completes, so per-tick
        // cost ≈ slowest RT not sum-of-RTs.
        final batch = <Future<void>>[];
        for (var i = 0; i < leg.callsPerBatch; i++) {
          batch.add(
            _channel.invokeMethod<void>(_channelMethod).catchError((Object _) {
              batchFailures++;
            }),
          );
        }
        try {
          await Future.wait(batch);
        } catch (_) {
          // Defense-in-depth — individual call failures are absorbed
          // by per-call .catchError above; this catch handles the
          // unexpected case where Future.wait itself rejects.
          batchFailures += leg.callsPerBatch;
        }
        totalCallsSent += leg.callsPerBatch;
        await Future<void>.delayed(const Duration(milliseconds: _batchTickMs));
        if (!mounted) {
          sw.stop();
          return;
        }
      }
      sw.stop();
      final callPhaseElapsedMs = sw.elapsedMilliseconds;

      // Dwell so the detector poll cycle that observes the
      // post-threshold window emits the issue AND
      // `_recordIssuesForCapture` lands the trace event BEFORE
      // markScenarioEnd closes the span.
      await Future<void>.delayed(
        const Duration(milliseconds: _postCallDwellMs),
      );
      if (!mounted) return;

      Sleuth.markScenarioEnd('platform_channel_traffic_${leg.label}');

      // Post-end barrier before exportCaptureJson: VM service buffer
      // needs to flush the just-emitted scenario.end marker before
      // service.getVMTimeline can return it. Mirrors NetworkMonitor's
      // proven 800 ms post-end pattern (using 200 ms here because
      // the prior 800 ms dwell already absorbed most of the
      // VM-service round-trip; total end-to-export gap is 1 s).
      await Future<void>.delayed(
        const Duration(milliseconds: _postEndBarrierMs),
      );
      if (!mounted) return;

      // `operatorCps` is the SEND rate (per-iteration counter / wall
      // clock), NOT the rate the detector observed at parser entry.
      // iOS coalescing, missed `b` events under thermal pressure, or
      // a `debugProfilePlatformChannels` flag race produces a gap
      // between sent and observed counts. Detector-stamped
      // `observedCount` (parsed back out of the wrapped capture and
      // re-injected into `expectedMagnitude.observed`) is the
      // authoritative number the role band is judged against. Operator
      // rate is the wheel the operator turns.
      final operatorCps = totalCallsSent / (callPhaseElapsedMs / 1000.0);

      String? stashed;
      try {
        stashed = await Sleuth.exportCaptureJson(
          scenario: 'platform_channel_traffic_${leg.label}',
          role: leg.label,
          // Schema requires magnitudeMin > 0. Below leg's cpsMin is
          // 1 (not 0) by construction so no clamp needed.
          magnitudeMin: leg.cpsMin.toDouble(),
          magnitudeObserved: operatorCps,
          magnitudeMax: leg.cpsMax.toDouble(),
          unit: 'events',
          device: 'iPhone 12',
          deviceOsVersion: 'iOS 17.5',
          flutterVersion: '3.41.4',
          captureCommand:
              'fvm flutter run --profile -d "iPhone 12" '
              '--dart-define=SLEUTH_CAPTURE_MODE=true',
          // platform_channel_traffic's source events are
          // per-call `Platform Channel send …` async TimelineTask
          // events, not BUILDs — skip BUILD-derivation. The
          // post-process step replaces the placeholder with detector
          // count.
          magnitudeSourceEventName: '',
        );
      } catch (_) {
        stashed = null;
      }

      double? detectorCps;
      String? rewrittenJson;
      String? rewriteError;
      if (stashed != null) {
        detectorCps = _extractDetectorCountFromCapture(stashed, leg);
        if (detectorCps != null) {
          try {
            rewrittenJson = _replaceExpectedObserved(stashed, detectorCps);
          } on StateError catch (e) {
            rewriteError = e.message;
          }
        } else if (leg == _ChannelLeg.below) {
          rewrittenJson = stashed;
        }
      }

      bool inBand;
      if (leg == _ChannelLeg.below) {
        inBand = leg.isCpsInBand(operatorCps);
      } else {
        inBand = detectorCps != null && leg.isCpsInBand(detectorCps);
      }

      if (!mounted) return;
      final marker = inBand ? '✓ IN-BAND' : '✗ OUT-OF-BAND';
      final reportedCps = leg == _ChannelLeg.below
          ? operatorCps
          : (detectorCps ?? operatorCps);
      setState(() {
        _busy = false;
        _lastCompletedLeg = inBand ? leg : null;
        _lastMeasuredCps = inBand ? reportedCps : null;
        _stashedCaptureJson = inBand ? rewrittenJson : null;
        final ratio = (detectorCps != null && operatorCps > 0)
            ? (detectorCps / operatorCps).toStringAsFixed(2)
            : null;
        _log.add(
          '[${leg.label}] $marker — '
          'operator ${operatorCps.toStringAsFixed(1)} calls/sec, '
          'detector ${detectorCps == null ? '(silent)' : '${detectorCps.toStringAsFixed(1)} calls/sec'}'
          '${ratio == null ? '' : ' (det/op ratio $ratio)'} '
          '($totalCallsSent sent over '
          '${(callPhaseElapsedMs / 1000).toStringAsFixed(2)} s, '
          '$batchFailures failures; role-band uses '
          '${leg == _ChannelLeg.below ? 'operator' : 'detector'}: '
          '[${leg.cpsMin}, ${leg.cpsMax}] calls/sec)',
        );
        if (inBand) {
          _activeRetryLeg = null;
          if (rewrittenJson != null) {
            _log.add(
              '[${leg.label}] capture stashed (${rewrittenJson.length} chars) '
              '— tap "Export last leg" to copy to clipboard.',
            );
          }
        } else {
          if (stashed == null) {
            _log.add(
              '[${leg.label}] capture FAILED to compose. Check the '
              'flutter run terminal — Sleuth.exportCaptureJson logs the '
              'exact reason via debugPrint (VM client null, VM client '
              'disconnected, empty trace buffer, or scenario markers '
              'not found). Most common cause when '
              '--dart-define=SLEUTH_CAPTURE_MODE=true was passed: '
              'iOS auto-locked the screen during the leg and the VM '
              'service connection dropped. Keep the screen on and '
              'foreground; re-tap after fixing.',
            );
          } else if (rewriteError != null) {
            // Persistent shape change: every retry will throw the same
            // StateError. Short-circuit by exhausting the budget so the
            // operator restarts the screen instead of burning 5 retries
            // on identical failures.
            _retryCount = _maxRetriesPerLeg;
            _log.add(
              '[${leg.label}] post-process FAILED — $rewriteError. '
              'Wrapped capture shape changed; update '
              '_replaceExpectedObserved before retrying. Retry budget '
              'exhausted to prevent burning through identical failures '
              '— restart the screen after fixing.',
            );
          } else if (leg != _ChannelLeg.below && detectorCps == null) {
            _log.add(
              '[${leg.label}] capture has no detector count arg in any '
              'in-span platform_channel_traffic.warning event. Detector '
              'did not fire in scenario span. Likely cause: parser '
              'dropped channel events because '
              'debugProfilePlatformChannels was not enabled, or iOS '
              'coalesced parallel calls. Re-tap.',
            );
          } else {
            _log.add(
              '[${leg.label}] retry: detector count '
              '${detectorCps?.toStringAsFixed(1) ?? '?'} calls/sec '
              'missed band. Adjust batch size so detector lands in '
              '[${leg.cpsMin}, ${leg.cpsMax}] calls/sec. Do NOT export '
              'an out-of-band run.',
            );
          }
        }
      });
    } finally {
      // Always restore the framework flag — leaving it true would
      // pollute live monitoring with channel-send timeline events
      // from every subsequent unrelated invokeMethod call.
      debugProfilePlatformChannels = priorFlag;
      // Safety net for `_busy`: the happy-path setState already
      // cleared it. Early-exit paths never reach that setState, so
      // reset here so the next leg tap is not silently blocked.
      if (mounted && _busy) {
        setState(() => _busy = false);
      }
    }
  }

  /// Reads the wrapped capture JSON stashed by `_runLeg` immediately
  /// after `markScenarioEnd`, parses it to verify the expected
  /// `sleuth.issue.platform_channel_traffic.warning` trace-record
  /// count inside the scenario span (zero for below; exactly one for
  /// at / above), and copies it to the iOS clipboard.
  Future<void> _exportLastLeg() async {
    final leg = _lastCompletedLeg;
    final json = _stashedCaptureJson;
    final messenger = ScaffoldMessenger.of(context);
    if (leg == null || _lastMeasuredCps == null) {
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
          'compose-time. Common causes: (1) captureMode OFF — '
          'restart with --dart-define=SLEUTH_CAPTURE_MODE=true. '
          '(2) VM service disconnected (FRAME mode) — re-launch from '
          'home screen so VM+ mode activates. Re-tap after fixing.',
        );
      });
      return;
    }

    setState(() {
      _busy = true;
      _log.add('[${leg.label}] Export: validating stashed capture…');
    });

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
          'platform_channel_traffic_${leg.label}.json under '
          'test/validation/captures/platform_channel/.',
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
  /// number of `sleuth.issue.platform_channel_traffic.warning` trace
  /// events: zero for `below`, exactly one for `at` / `above`.
  /// Returns null on success or a human-readable failure reason.
  String? _validateTraceRecords(String json, _ChannelLeg leg) {
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

    int? scenarioBeginTs;
    int? scenarioEndTs;
    final scenarioName = 'platform_channel_traffic_${leg.label}';
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
      return 'scenario markers missing from trace '
          '(begin=$scenarioBeginTs, end=$scenarioEndTs). Re-tap the leg.';
    }

    var trafficCount = 0;
    const trafficEventName = 'sleuth.issue.platform_channel_traffic.warning';
    final inSpanRecords = <Map<String, dynamic>>[];
    for (final raw in traceEvents) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['name'] != trafficEventName) continue;
      final ts = raw['ts'];
      if (ts is! num) continue;
      if (ts.toInt() < scenarioBeginTs) continue;
      if (ts.toInt() > scenarioEndTs) continue;
      trafficCount++;
      inSpanRecords.add(raw);
    }

    final expected = leg == _ChannelLeg.below ? 0 : 1;
    if (trafficCount != expected) {
      final cause = trafficCount == 0
          ? 'Detector did not fire. Likely cause: (1) parser '
                'dropped channel events because '
                'debugProfilePlatformChannels was not enabled — '
                'check the framework flag is true at leg start. '
                '(2) iOS coalesced parallel calls and rate stayed '
                'below 20/sec. Recheck batch geometry.'
          : 'Detector fired more than once inside scenario span — '
                'cooldown failed. Likely cause: scenario span '
                'extended into a second 1 s evaluation cycle '
                'and the cooldown counter did not suppress. Retry.';
      return 'expected $expected `$trafficEventName` events inside '
          'scenario span, found $trafficCount. $cause';
    }

    // Producer-side dedup invariant parity with the audit gate
    // (`bracketRequireUniqueDetectedAtMicros: true`). Without this
    // mirroring, the screen reports "Export OK" for a capture that
    // CI later rejects: trace records with missing or duplicated
    // `detectedAtMicros` violate the schema's strong invariant.
    // Two prongs guard against forgery: every in-span record must
    // carry a parseable `detectedAtMicros`, AND the unique-value
    // count must equal the record count.
    final uniqueDetectedAtMicros = <String>{};
    var missingDetectedAtMicros = 0;
    for (final record in inSpanRecords) {
      final args = record['args'];
      String? micros;
      if (args is Map) {
        final direct = args['detectedAtMicros'];
        if (direct is String && direct.isNotEmpty) {
          micros = direct;
        } else if (direct is num) {
          micros = direct.toString();
        } else {
          // Mirror schema: also handle nested `Dart Arguments` wrapper
          // some VM service exports use.
          final dartArgs = args['Dart Arguments'];
          if (dartArgs is Map) {
            final inner = dartArgs['detectedAtMicros'];
            if (inner is String && inner.isNotEmpty) {
              micros = inner;
            } else if (inner is num) {
              micros = inner.toString();
            }
          }
        }
      }
      if (micros == null) {
        missingDetectedAtMicros++;
      } else {
        uniqueDetectedAtMicros.add(micros);
      }
    }
    if (missingDetectedAtMicros > 0) {
      return 'trace record missing `detectedAtMicros` arg '
          '($missingDetectedAtMicros of $trafficCount). Either pre-v0.18.1 '
          'binary without producer dedup, or the arg was stripped during '
          'capture. Re-record under v0.18.1+ build.';
    }
    if (uniqueDetectedAtMicros.length != trafficCount) {
      return 'expected each `$trafficEventName` to carry a unique '
          '`detectedAtMicros` (producer-side dedup invariant). Found '
          '$trafficCount records but only ${uniqueDetectedAtMicros.length} '
          'distinct values inside scenario span — capture replay or '
          'forgery. Re-record the leg.';
    }

    return null;
  }

  /// Walks the wrapped capture's `traceEvents` for in-span
  /// `sleuth.issue.platform_channel_traffic.warning` events and returns
  /// the maximum `args.observedCount` value the detector stamped during
  /// the scenario. Returns null when the detector did not fire (below
  /// leg) or the arg is missing/unparseable. Reduction `'max'` matches
  /// the schema's per-record cross-check on this stableId.
  double? _extractDetectorCountFromCapture(String json, _ChannelLeg leg) {
    Map<String, dynamic> wrapped;
    try {
      wrapped = jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final traceEvents = wrapped['traceEvents'];
    if (traceEvents is! List) return null;
    final scenarioName = 'platform_channel_traffic_${leg.label}';
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
    const eventName = 'sleuth.issue.platform_channel_traffic.warning';
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
      // name lookup so detector count extraction stays active under
      // either shape.
      Object? axis = args['observedCount'];
      if (axis == null) {
        final dartArgs = args['Dart Arguments'];
        if (dartArgs is Map) axis = dartArgs['observedCount'];
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
  /// rewritten to [observed]. Eliminates operator-vs-detector divergence
  /// by construction so the schema bracket-band check, the per-record
  /// cross-check, and `checkDetectorAxisInRoleBand` all reduce to the
  /// same authoritative number.
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
    final ready = !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('PlatformChannel capture helper')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Records profile-mode captures for '
              'platform_channel_traffic WARNING-tier bracketing '
              '(20 calls/sec threshold, frequency axis only). '
              'Above preset stays under any critical-tier collision '
              '(critical = 41 calls/sec; above-band ceiling = 39). '
              'See class docstring + doc/capture_procedure.md for '
              'the full recording protocol.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            _CaptureButton(
              label: 'Below ($_belowTargetCps calls/sec) — passes',
              subtitle:
                  'Under $_warningThresholdCallsPerSec calls/sec '
                  'threshold; detector stays silent',
              enabled: ready,
              onTap: () => _runLeg(_ChannelLeg.below),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'At (op $_atTargetCps calls/sec) — warning',
              subtitle:
                  'Detector count must land in [20, 30] '
                  '(operator ≈ detector on this leg)',
              enabled: ready,
              onTap: () => _runLeg(_ChannelLeg.at),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'Above (op $_aboveTargetCps calls/sec) — warning',
              subtitle:
                  'Detector count must land in [31, 39] '
                  '(operator overshoots; iOS coalescing reduces detector '
                  'count by ~20%; under critical=41)',
              enabled: ready,
              onTap: () => _runLeg(_ChannelLeg.above),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : () => _exportLastLeg(),
              icon: const Icon(Icons.save_alt),
              label: const Text('Export last leg'),
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

enum _ChannelLeg {
  // Bands match what ProfileCaptureSchema.validateBracket accepts when
  // the detector's metadata declares `bracketAtTolerance: 0.50` and
  // `aboveCeilingMultiplier: 1.95`:
  //   below:  1 ≤ calls/sec ≤ 19   (sub-threshold; detector silent.
  //                                  cpsMin = 1 because the schema
  //                                  requires magnitudeMin > 0).
  //   at:    20 ≤ calls/sec ≤ 30   (atTolerance 0.50).
  //   above: 31 ≤ calls/sec ≤ 39   (above-ceiling 1.95×T = 39, kept
  //                                  strictly under the 41-call
  //                                  critical-escalation boundary).
  below(
    label: 'below',
    targetCps: _belowTargetCps,
    callsPerBatch: _belowCallsPerBatch,
    cpsMin: 1,
    cpsMax: 19,
  ),
  at(
    label: 'at',
    targetCps: _atTargetCps,
    callsPerBatch: _atCallsPerBatch,
    cpsMin: 20,
    cpsMax: 30,
  ),
  above(
    label: 'above',
    targetCps: _aboveTargetCps,
    callsPerBatch: _aboveCallsPerBatch,
    cpsMin: 31,
    cpsMax: 39,
  );

  const _ChannelLeg({
    required this.label,
    required this.targetCps,
    required this.callsPerBatch,
    required this.cpsMin,
    required this.cpsMax,
  });
  final String label;
  final int targetCps;
  final int callsPerBatch;
  final int cpsMin;
  final int cpsMax;

  bool isCpsInBand(double cps) => cps >= cpsMin && cps <= cpsMax;
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
