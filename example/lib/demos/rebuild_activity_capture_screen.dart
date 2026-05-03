// Capture screen for `RebuildDetector.rebuild_activity` runtime-verified
// raises. Drives a controlled rebuilds-per-second rate via Stopwatch-
// throttled Ticker setState on a plain StatefulWidget (NOT a builder
// widget — RebuildDetector applies a 3× threshold multiplier to
// StreamBuilder/AnimatedBuilder/FutureBuilder/TweenAnimationBuilder
// which would push warning to >30/sec, colliding with critical).
//
// Two tiers selectable via dropdown:
//
//   Warning (`> 10/sec` fires .warning). Schema at-band [11, 16.5].
//   Above-band ceiling 27.5 < critical threshold 30.
//     below  5/sec  — sub-threshold, no emission
//     at    13/sec  — inside [11, 16.5]
//     above 20/sec  — inside (16.5, 27.5], strict under critical
//
//   Critical (`> 30/sec` fires .critical). Schema at-band [31, 51.15].
//   Above-band ceiling 83.7. Below leg may still emit warning (>10/sec)
//   but must emit no critical events.
//     below 25/sec  — under critical threshold 31; warning may fire
//     at    40/sec  — inside [31, 51], comfortable margin
//     above 70/sec  — inside (51.15, 83.7], headroom under ceiling
//                     to absorb iOS thermal throttling on a 6 s
//                     sustained leg without dropping below 52/sec
//
// Below-leg producer pattern: detector exposes lastObservedRebuildRate
// unconditionally. Reading detector-measured rate at scenario.end keeps
// below-leg evidence quality on par with at/above legs.

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

/// Bracket tier the operator is targeting. Drives leg targets,
/// scenario name, capture-file basename, and the
/// `bracketSeverityLabel` parameter passed to
/// `Sleuth.exportCaptureJson` so the wrapped JSON's
/// `metadata.bracket.severityLabel` matches the bracket the audit gate
/// will cross-check against.
enum _Tier {
  warning('warning'),
  critical('critical');

  const _Tier(this.label);
  final String label;
}

const _warningLegs = <_Leg>[
  _Leg(label: 'below', targetRebuildRate: 5, rateMin: 1, rateMax: 10),
  _Leg(label: 'at', targetRebuildRate: 13, rateMin: 11, rateMax: 19),
  _Leg(label: 'above', targetRebuildRate: 20, rateMin: 19, rateMax: 27),
];

const _criticalLegs = <_Leg>[
  _Leg(label: 'below', targetRebuildRate: 25, rateMin: 20, rateMax: 30),
  _Leg(label: 'at', targetRebuildRate: 40, rateMin: 31, rateMax: 51),
  _Leg(label: 'above', targetRebuildRate: 70, rateMin: 52, rateMax: 83),
];

List<_Leg> _legsForTier(_Tier tier) =>
    tier == _Tier.warning ? _warningLegs : _criticalLegs;

const _scenarioDurationSec = 6;
const _postCompletionDwellMs = 500;
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
  String? _lastCompletedLeg;
  String? _stashedCaptureJson;
  // ignore: prefer_final_fields  (mutated from Ticker callback for diagnostics)
  int _pulseCount = 0;

  // All mutable UI state is driven through ValueNotifiers so per-leg state
  // changes do not call setState on this State. A plain setState rebuilds
  // the whole Scaffold subtree (~25 BUILD events). Each notifier is
  // consumed by a ValueListenableBuilder that rebuilds only its leaf
  // Text/Button. Per-tick rebuilds go through `_pulseKey` (see _Pulse)
  // which produces exactly 1 BUILD event per Ticker fire — a
  // ValueListenableBuilder consumer would emit 2 (the listener State plus
  // its child Text), pushing below-leg over the 10/sec threshold.
  final ValueNotifier<bool> _busy = ValueNotifier<bool>(false);
  final ValueNotifier<int?> _lastObservedRate = ValueNotifier<int?>(null);
  final ValueNotifier<int?> _baselineRate = ValueNotifier<int?>(null);
  final ValueNotifier<_Tier> _tier = ValueNotifier<_Tier>(_Tier.warning);
  final ValueNotifier<List<String>> _log = ValueNotifier<List<String>>(
    const [],
  );
  final GlobalKey<_PulseState> _pulseKey = GlobalKey<_PulseState>();

  void _appendLog(String line) {
    _log.value = List<String>.unmodifiable([..._log.value, line]);
  }

  @override
  void dispose() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    // Release any baseline this screen configured. Without this, the
    // detector instance attached to the live SleuthController retains
    // the capture-mode subtraction floor after the user navigates back
    // to their app, silently suppressing real rebuild storms in the
    // (threshold, threshold + baseline] band during normal monitoring.
    Sleuth.rebuildDetector?.setBaseline(0);
    _busy.dispose();
    _lastObservedRate.dispose();
    _baselineRate.dispose();
    _tier.dispose();
    _log.dispose();
    super.dispose();
  }

  Future<void> _runLeg(_Leg leg) async {
    if (_busy.value) return;
    final monitor = Sleuth.rebuildDetector;
    if (monitor == null) {
      _appendLog(
        '[${leg.label}] FAILED: Sleuth.rebuildDetector is null. Verify '
        'Sleuth.init() ran with captureMode=true and '
        '--dart-define=SLEUTH_CAPTURE_MODE=true.',
      );
      return;
    }
    _busy.value = true;
    _lastCompletedLeg = null;
    _lastObservedRate.value = null;
    _stashedCaptureJson = null;
    final tier = _tier.value;
    _appendLog(
      '[${tier.label}/${leg.label}] scenario.begin — '
      'target ~${leg.targetRebuildRate}/sec',
    );

    // Suffix-shape capture file name (e.g. `critical_below.json`,
    // basename `critical_below`); scenario string also follows the
    // suffix-shape `rebuild_activity_<basename>` so
    // checkCapturePathPerDirectoryNamingUniformity sees a single
    // common prefix `rebuild_activity` across both tiers' captures
    // even though they live in the same directory.
    final basename = tier == _Tier.warning
        ? leg.label
        : 'critical_${leg.label}';
    final scenarioName = 'rebuild_activity_$basename';
    final messenger = ScaffoldMessenger.of(context);

    // ValueNotifier writes above mark their consumers dirty but BUILD
    // timeline events only emit when the next frame actually runs. A
    // synchronous flushTimelineNow on this microtask would poll VM
    // before that frame fires → cursor advances past nothing → pre-leg
    // BUILDs land in the NEXT poll, which is the first poll after
    // markScenarioBegin, contaminating window 1. The dwell is sized to
    // span ≥3 vsync intervals on 60 Hz so the dirty subtrees flush.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;

    // Narrow VM timeline streams to Dart only — long scenarios under
    // default streams overflow the ring buffer and roll scenario.begin
    // off before exportCaptureJson can read it.
    await Sleuth.suspendNonEssentialTimelineStreams();
    var streamsSuspended = true;
    try {
      // Inline baseline measurement.
      //
      // Ambient framework BUILDs/sec drifts with screen state — the
      // Sleuth overlay (TriggerButton, FloatingIssuesCard) rebuilds
      // when issues fire, so a baseline measured before any leg is
      // numerically valid only at that moment. After a few legs run
      // the overlay's badge count and issue list inflate the ambient
      // floor. A stale baseline produces under-subtraction → adjusted
      // count exceeds threshold → below-leg false-fires.
      //
      // Re-measuring inline (right before each pulse phase) keeps the
      // subtraction current with whatever overlay state exists at run
      // time. The baseline scenario stays inside the same suspend/
      // resume window so VM streams are narrow throughout.
      monitor.setBaseline(0);
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 1));
      if (!mounted) return;
      Sleuth.markScenarioBegin('${scenarioName}_baseline');
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted) return;
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));
      if (!mounted) return;
      final ambient = monitor.peakObservedRebuildRate;
      Sleuth.markScenarioEnd('${scenarioName}_baseline');
      await Future<void>.delayed(
        const Duration(milliseconds: _postScenarioEndDwellMs),
      );
      if (!mounted) return;
      monitor.setBaseline(ambient);
      _baselineRate.value = ambient;
      _appendLog('[${leg.label}] baseline=$ambient/sec — running workload');

      // Drain pre-leg BUILD events past the VM cursor before the
      // detector window anchors. The cursor is owned by VmServiceClient
      // (independent of resetCaptureState) so without this drain the
      // events sit in the VM ring buffer and the next poll feeds them
      // into window 1.
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 1));
      if (!mounted) return;

      // markScenarioBegin auto-resets the detector's per-session counters
      // + last-observed rate via SleuthController.resetCaptureState.
      // Baseline survives reset (ambient is stable across legs in the
      // same screen state).
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
        _pulseCount++;
        _pulseKey.currentState?.pulse();
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

      // Peak (max across staged windows) rather than last-window so the
      // capture's reported observed magnitude agrees with the schema's
      // `observedAxisReduction: 'max'` reduction over in-span trace
      // events. Reading last-window underreports when the workload
      // tails off in the final window.
      final observedRate = monitor.peakObservedRebuildRate;
      Sleuth.markScenarioEnd(scenarioName);
      await Future<void>.delayed(
        const Duration(milliseconds: _postScenarioEndDwellMs),
      );
      if (!mounted) return;

      await Sleuth.resumeAllTimelineStreams();
      streamsSuspended = false;
      if (!mounted) return;

      // Detector-stamped value reaches the schema directly via the
      // `magnitudeObserved` parameter — no `_replaceExpectedObserved`
      // post-process step is needed (the wrapped JSON's
      // `expectedMagnitude.observed` is set from this argument inside
      // `Sleuth.exportCaptureJson`). Other capture screens that compute
      // observed magnitude from raw VM data after the fact (memory,
      // platform_channel) DO need the post-process; this one does not.
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
          bracketSeverityLabel: tier.label,
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
      _lastCompletedLeg = stashed != null ? leg.label : null;
      _stashedCaptureJson = stashed;
      _lastObservedRate.value = observedRate;
      _appendLog(
        '[${tier.label}/${leg.label}] scenario.end — observed=$observedRate/sec; '
        'pulses=$_pulseCount; '
        'export ${stashed != null ? "OK" : "FAILED"}',
      );
      _pulseCount = 0;
      _busy.value = false;
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
      _appendLog('[${leg.label}] FAILED: $e');
      _busy.value = false;
    } finally {
      if (streamsSuspended) {
        await Sleuth.resumeAllTimelineStreams();
      }
    }
  }

  Future<void> _exportLastLeg() async {
    final json = _stashedCaptureJson;
    if (json == null) {
      _appendLog('Export: no stashed capture. Run a leg first.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: json));
    _appendLog(
      'Export: ${json.length} bytes copied to clipboard '
      '(leg=$_lastCompletedLeg).',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RebuildActivity Capture')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Drives Ticker-gated setState on a plain StatefulWidget at a '
              'controlled rebuilds-per-second rate. Pick tier from dropdown; '
              'three legs bracket the `rebuild_activity.<tier>` threshold '
              '(warning >10/sec, critical >30/sec).',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            _Pulse(key: _pulseKey),
            const SizedBox(height: 16),
            ValueListenableBuilder<_Tier>(
              valueListenable: _tier,
              builder: (_, tier, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Text('Tier: '),
                    const SizedBox(width: 8),
                    DropdownButton<_Tier>(
                      value: tier,
                      // Re-read `_busy.value` at fire time. The parent
                      // ValueListenableBuilder listens to `_tier`, not
                      // `_busy`, so a build-time read here would let the
                      // operator switch tier mid-leg-run.
                      onChanged: (next) {
                        if (_busy.value) return;
                        if (next == null || next == tier) return;
                        final hadStash = _stashedCaptureJson != null;
                        setState(() {
                          _tier.value = next;
                          _lastCompletedLeg = null;
                          _stashedCaptureJson = null;
                        });
                        _appendLog(
                          hadStash
                              ? 'Switched to ${next.label} tier — '
                                    'previous stashed capture cleared.'
                              : 'Switched to ${next.label} tier.',
                        );
                      },
                      items: const [
                        DropdownMenuItem(
                          value: _Tier.warning,
                          child: Text('warning (>10/sec)'),
                        ),
                        DropdownMenuItem(
                          value: _Tier.critical,
                          child: Text('critical (>30/sec)'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _busy,
              builder: (_, busy, _) => ValueListenableBuilder<int?>(
                valueListenable: _baselineRate,
                builder: (_, baseline, _) => ValueListenableBuilder<_Tier>(
                  valueListenable: _tier,
                  builder: (_, tier, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final leg in _legsForTier(tier))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: ElevatedButton(
                            onPressed: busy ? null : () => _runLeg(leg),
                            child: Text(
                              'Run ${tier.label}/${leg.label} '
                              '(~${leg.targetRebuildRate}/sec)',
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.content_copy),
                        label: const Text('Export last leg → clipboard'),
                        onPressed: busy || _stashedCaptureJson == null
                            ? null
                            : _exportLastLeg,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<int?>(
              valueListenable: _lastObservedRate,
              builder: (_, rate, _) => Text(
                rate == null
                    ? 'Last observed (baseline-adjusted): —'
                    : 'Last observed (baseline-adjusted): $rate/sec',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            const Divider(),
            Expanded(
              child: ValueListenableBuilder<List<String>>(
                valueListenable: _log,
                builder: (_, lines, _) => ListView.builder(
                  itemCount: lines.length,
                  itemBuilder: (_, i) {
                    final line = lines[lines.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        line,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Per-tick rebuild pulse with a 1-BUILD footprint.
///
/// `setState(() {})` marks this Element dirty; the next frame rebuilds it
/// and emits one BUILD timeline event. The build method returns a const
/// `SizedBox.shrink()` so the child Element diff short-circuits — no
/// extra BUILD event for the leaf. A ValueListenableBuilder consumer
/// would emit two (the listener State plus its child Text).
class _Pulse extends StatefulWidget {
  const _Pulse({super.key});

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> {
  void pulse() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
