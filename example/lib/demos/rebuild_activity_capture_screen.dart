// Capture screen for `RebuildDetector.rebuild_activity.warning` runtime-
// verified raise (v0.19.11). Drives a controlled rebuilds-per-second
// rate via Ticker-gated setState on a plain StatefulWidget (NOT a
// builder widget — RebuildDetector applies a 3× threshold multiplier
// to StreamBuilder/AnimatedBuilder/FutureBuilder/TweenAnimationBuilder
// which would push warning to >30/sec, colliding with critical).
//
// Three legs bracket the threshold (default 10/sec). Targets chosen so
// `(60 / target).floor()` produces clean ticker modulus values without
// label drift between intent and achievable rate at 60 Hz vsync:
//   Below 5/sec  — modulus 12 → exact 5/sec (silent, sub-threshold).
//   At    15/sec — modulus 4  → exact 15/sec (fires warning).
//   Above 20/sec — modulus 3  → exact 20/sec (fires warning, under 30/sec critical).
//
// Below-leg producer pattern: detector exposes lastObservedRebuildRate
// unconditionally. The schema's per-leg invariants leave below-leg's
// axis unchecked (silent leg has no warning event to cross-check
// against), so plan-not-measured was a silent-evidence-quality gap;
// reading detector-measured rate closes it client-side.

import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// One bracket leg target. Below leg is sub-threshold (no emission);
/// at + above legs both fire `rebuild_activity.warning` with rate in
/// the bracket band.
class _Leg {
  const _Leg({
    required this.label,
    required this.targetRebuildRate,
    required this.rateMin,
    required this.rateMax,
  });

  final String label;
  final int targetRebuildRate;
  final int rateMin;
  final int rateMax;
}

const _legs = <_Leg>[
  _Leg(label: 'below', targetRebuildRate: 5, rateMin: 3, rateMax: 7),
  _Leg(label: 'at', targetRebuildRate: 15, rateMin: 11, rateMax: 17),
  _Leg(label: 'above', targetRebuildRate: 20, rateMin: 18, rateMax: 27),
];

const _scenarioDurationSec = 6;
const _postCompletionDwellMs = 200;
const _postScenarioEndDwellMs = 800;

class RebuildActivityCaptureScreen extends StatefulWidget {
  const RebuildActivityCaptureScreen({super.key});

  @override
  State<RebuildActivityCaptureScreen> createState() =>
      _RebuildActivityCaptureScreenState();
}

class _RebuildActivityCaptureScreenState
    extends State<RebuildActivityCaptureScreen>
    with TickerProviderStateMixin {
  Ticker? _ticker;
  bool _busy = false;
  String? _lastCompletedLeg;
  int? _lastObservedRate;
  String? _stashedCaptureJson;
  final List<String> _log = [];

  // Counter that drives the rebuild — incremented inside Ticker callbacks
  // every Nth frame to hit the target rate. setState rebuilds this widget
  // and produces a BUILD event the VM timeline reports.
  int _counter = 0;

  @override
  void dispose() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }

  Future<void> _runLeg(_Leg leg) async {
    if (_busy) return;
    final monitor = Sleuth.rebuildDetector;
    if (monitor == null) {
      setState(() {
        _log.add(
          '[${leg.label}] FAILED: Sleuth.rebuildDetector is null. Verify '
          'Sleuth.init() ran with captureMode=true and '
          '--dart-define=SLEUTH_CAPTURE_MODE=true.',
        );
      });
      return;
    }
    setState(() {
      _busy = true;
      _lastCompletedLeg = null;
      _lastObservedRate = null;
      _stashedCaptureJson = null;
      _log.add(
        '[${leg.label}] scenario.begin — target ~${leg.targetRebuildRate}/sec',
      );
    });

    final scenarioName = 'rebuild_activity_${leg.label}';
    final messenger = ScaffoldMessenger.of(context);

    // Narrow VM timeline streams to Dart only — long scenarios under
    // default streams overflow the ring buffer and roll scenario.begin
    // off before exportCaptureJson can read it.
    await Sleuth.suspendNonEssentialTimelineStreams();
    var streamsSuspended = true;
    try {
      // markScenarioBegin auto-resets the detector's per-session counters
      // + last-observed rate via SleuthController.resetCaptureState.
      Sleuth.markScenarioBegin(scenarioName);

      // Time-based throttling: gate setState on elapsed wall-clock
      // ms since the last fire. Refresh-rate-independent — works on
      // 60 Hz / 90 Hz / 120 Hz devices identically because the
      // interval is in real time, not vsync frames. (A frame-modulus
      // approach scales with vsync and produces 2× target rate on a
      // 120 Hz device, pushing the above-leg into critical territory.)
      final intervalMs = (1000 / leg.targetRebuildRate).round();
      final stopwatch = Stopwatch()..start();
      var lastFireMs = 0;
      _ticker = createTicker((_) {
        final now = stopwatch.elapsedMilliseconds;
        if (now - lastFireMs < intervalMs) return;
        lastFireMs = now;
        if (!mounted) return;
        setState(() => _counter++);
      })..start();

      await Future<void>.delayed(const Duration(seconds: _scenarioDurationSec));
      _ticker?.stop();
      _ticker?.dispose();
      _ticker = null;

      await Future<void>.delayed(
        const Duration(milliseconds: _postCompletionDwellMs),
      );
      if (!mounted) return;

      // Drain detector emissions into the VM trace buffer before the
      // scenario closes. flushTimelineNow drives the VM-poll →
      // processTimelineData → _evaluateVmData chain that updates
      // _lastObservedRebuildRate AND records issue trace events.
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));
      if (!mounted) return;

      final observedRate = monitor.lastObservedRebuildRate;
      Sleuth.markScenarioEnd(scenarioName);
      await Future<void>.delayed(
        const Duration(milliseconds: _postScenarioEndDwellMs),
      );
      if (!mounted) return;

      await Sleuth.resumeAllTimelineStreams();
      streamsSuspended = false;
      if (!mounted) return;

      String? stashed;
      try {
        stashed = await Sleuth.exportCaptureJson(
          scenario: scenarioName,
          role: leg.label,
          magnitudeMin: leg.rateMin,
          magnitudeObserved: observedRate,
          magnitudeMax: leg.rateMax,
          unit: 'rebuilds',
          device: 'iPhone 12',
          deviceOsVersion: 'iOS 17.5',
          flutterVersion: '3.41.4',
          captureCommand:
              'fvm flutter run --profile -d "iPhone 12" '
              '--dart-define=SLEUTH_CAPTURE_MODE=true',
          // Detector-measured magnitude — no BUILD-derivation.
          magnitudeSourceEventName: '',
          // Client-side mirror of the schema's per-leg trace-record
          // contract: at/above must contain matching issue event in
          // span; below must contain none. Operator sees refusal
          // before JSON hits the clipboard.
          bracketStableId: 'rebuild_activity',
          bracketSeverityLabel: 'warning',
        );
      } catch (e, st) {
        developer.log(
          '[sleuth.capture] exportCaptureJson threw: $e',
          name: 'sleuth.capture',
          error: e,
          stackTrace: st,
        );
        stashed = null;
      }

      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastCompletedLeg = stashed != null ? leg.label : null;
        _lastObservedRate = observedRate;
        _stashedCaptureJson = stashed;
        _log.add(
          '[${leg.label}] scenario.end — observed=$observedRate/sec; '
          'export ${stashed != null ? "OK" : "FAILED"}',
        );
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            stashed != null
                ? '${leg.label} OK (observed=$observedRate/sec). '
                      'Tap Export now.'
                : '${leg.label} FAILED — see log',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e, st) {
      Sleuth.markScenarioEnd(scenarioName);
      developer.log(
        '[sleuth.capture] FAILED ${leg.label}: $e',
        name: 'sleuth.capture',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _log.add('[${leg.label}] FAILED: $e');
      });
    } finally {
      if (streamsSuspended) {
        await Sleuth.resumeAllTimelineStreams();
      }
    }
  }

  Future<void> _exportLastLeg() async {
    final json = _stashedCaptureJson;
    if (json == null) {
      setState(() => _log.add('Export: no stashed capture. Run a leg first.'));
      return;
    }
    await Clipboard.setData(ClipboardData(text: json));
    setState(() {
      _log.add(
        'Export: ${json.length} bytes copied to clipboard '
        '(leg=$_lastCompletedLeg).',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RebuildActivity Capture (v0.19.11)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Drives Ticker-gated setState on a plain StatefulWidget at a '
              'controlled rebuilds-per-second rate. Three legs bracket the '
              '`rebuild_activity.warning` threshold (>10/sec).',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            Text(
              'Counter (rebuilds inside this widget): $_counter',
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 16),
            for (final leg in _legs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ElevatedButton(
                  onPressed: _busy ? null : () => _runLeg(leg),
                  child: Text(
                    'Run ${leg.label} (~${leg.targetRebuildRate}/sec)',
                  ),
                ),
              ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.content_copy),
              label: const Text('Export last leg → clipboard'),
              onPressed: _busy || _stashedCaptureJson == null
                  ? null
                  : _exportLastLeg,
            ),
            const SizedBox(height: 8),
            if (_lastObservedRate != null)
              Text(
                'Last observed rebuild rate: $_lastObservedRate/sec',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  for (final line in _log.reversed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        line,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
