// Capture screen for `stream_resource_growth.warning` bracket triad.
// Drives a controlled StreamSubscription leak across two watchlist
// classes while byte pressure pushes heap slope past
// `growthThresholdBytesPerSec` so the detector's heap_growing co-fire
// gate latches. Without the gate, the detector emits zero issues.
//
// K=4 window = 4 polls × 10 s = 40 s minimum sustained workload per
// leg; the screen enforces 50 s and refuses to advance until the
// detector reports `lastObservedSamplesInWindow == 4`. Heap-growing
// readiness wait runs INSIDE the scenario span — `markScenarioBegin →
// resetCaptureState` wipes the prior latch, so a pre-scenario warmup
// alone is insufficient.
//
// Educational Timer.periodic + StreamController leak demos live in
// `stream_resource_demo.dart` — kept separate so mixed workloads
// can't destabilise the `topGrowthClass` axis on bracket captures.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

class _Leg {
  const _Leg({
    required this.label,
    required this.totalSubsPerClass,
    required this.topDeltaMin,
    required this.topDeltaMax,
  });

  final String label;
  final int totalSubsPerClass;
  final int topDeltaMin;
  final int topDeltaMax;
}

// Bands describe `topGrowthDelta` (single-class delta over K=4) — the
// same axis the detector gates on AND the BracketSpec validates. Must
// stay in lockstep with the BracketSpec in
// `lib/src/detectors/stream_resource_detector.dart`: threshold 50,
// atTolerance 0.6 (at-band [50, 80]), aboveCeilingMultiplier 3.0
// (above-band (50, 150]). `totalSubsPerClass` is tuned for the
// iPhone-12 first-emission ratio (~0.44); above=230 lands ~101.
const _legs = <_Leg>[
  _Leg(label: 'below', totalSubsPerClass: 20, topDeltaMin: 1, topDeltaMax: 49),
  _Leg(label: 'at', totalSubsPerClass: 100, topDeltaMin: 50, topDeltaMax: 80),
  _Leg(
    label: 'above',
    totalSubsPerClass: 230,
    topDeltaMin: 51,
    topDeltaMax: 150,
  ),
];

const _legDurationSec = 50;
const _heapWarmupSec = 10;

// 256 KB × 4 Hz = 1024 KB/sec sustained, 2× over the 512 KB/sec
// `growthThresholdBytesPerSec`. Below threshold the heap_growing
// latch never re-arms after `resetCaptureState`.
const _bytePressurePerTickKb = 256;
const _bytePressureTickIntervalMs = 250;

// 1024 entries × 256 KB = 256 MB peak. At 4 Hz the cap is hit at
// T=256 s, well past the 85 s worst-case scenario.
const _bytePressureMaxEntries = 1024;

const _allocPollIntervalSec = 10; // K=4 window → 5 polls × 10 s = 50 s scenario

// Detector needs ~3 s warmup + 10 s sustained slope = ~13 s minimum.
// 25 s gives margin for thermal throttling.
const _scenarioHeapGrowingTimeoutSec = 25;

class StreamResourceCaptureScreen extends StatefulWidget {
  const StreamResourceCaptureScreen({super.key});

  @override
  State<StreamResourceCaptureScreen> createState() =>
      _StreamResourceCaptureScreenState();
}

class _StreamResourceCaptureScreenState
    extends State<StreamResourceCaptureScreen> {
  // Subscriptions held for monotonic growth across the K=4 window;
  // cleared between legs by `_releaseSubscriptions`.
  final List<StreamSubscription<void>> _broadcastSubs = [];
  final List<StreamSubscription<void>> _bufferingSubs = [];
  // Byte allocations drive heap slope into the heap_growing band so
  // the stream detector's co-fire gate opens.
  final List<Uint8List> _retainedBytes = [];

  // StreamControllers retained alongside their subscriptions — closing
  // a controller auto-cancels the subscription.
  final List<StreamController<void>> _retainedControllers = [];

  Timer? _bytePressureTimer;

  final ValueNotifier<bool> _busy = ValueNotifier<bool>(false);
  final ValueNotifier<String> _phaseStatus = ValueNotifier<String>('idle');
  final ValueNotifier<int> _samplesInWindow = ValueNotifier<int>(0);
  final ValueNotifier<bool> _heapGrowingActive = ValueNotifier<bool>(false);
  final ValueNotifier<int> _elapsedSec = ValueNotifier<int>(0);
  final ValueNotifier<int?> _lastObservedDelta = ValueNotifier<int?>(null);
  String? _lastCompletedLeg;
  String? _stashedCaptureJson;
  final ValueNotifier<List<String>> _log = ValueNotifier<List<String>>(
    const [],
  );

  void _appendLog(String line) {
    _log.value = List<String>.unmodifiable([..._log.value, line]);
    developer.log(line, name: 'sleuth.capture');
  }

  @override
  void dispose() {
    _bytePressureTimer?.cancel();
    _releaseSubscriptions();
    _releaseControllers();
    _busy.dispose();
    _phaseStatus.dispose();
    _samplesInWindow.dispose();
    _heapGrowingActive.dispose();
    _elapsedSec.dispose();
    _lastObservedDelta.dispose();
    _log.dispose();
    super.dispose();
  }

  void _releaseSubscriptions() {
    for (final s in _broadcastSubs) {
      s.cancel();
    }
    for (final s in _bufferingSubs) {
      s.cancel();
    }
    _broadcastSubs.clear();
    _bufferingSubs.clear();
    _retainedBytes.clear();
  }

  void _releaseControllers() {
    for (final c in _retainedControllers) {
      // ignore: discarded_futures  (best-effort cleanup)
      c.close();
    }
    _retainedControllers.clear();
  }

  Future<void> _runLeg(_Leg leg) async {
    if (_busy.value) return;
    final monitor = Sleuth.streamResourceDetector;
    if (monitor == null) {
      _appendLog(
        'FAIL: StreamResourceDetector not available — verify '
        'kReleaseMode=false AND DetectorType.streamResource enabled.',
      );
      return;
    }
    _busy.value = true;
    _stashedCaptureJson = null;
    _lastCompletedLeg = null;
    _lastObservedDelta.value = null;
    _samplesInWindow.value = 0;

    final scenarioName = 'stream_resource_growth_${leg.label}';
    _appendLog('=== $scenarioName start ===');

    final messenger = ScaffoldMessenger.of(context);

    try {
      // Pre-scenario warmup primes the heap so MemoryPressureDetector
      // has fresh slope samples post-reset. Any heap_growing latch
      // established here is wiped by `markScenarioBegin →
      // resetCaptureState`, so the readiness wait must run after
      // scenario begin.
      _releaseSubscriptions();
      monitor.resetCaptureState();

      _phaseStatus.value = 'warmup (heap pressure)';
      _startBytePressure();
      final warmupStart = DateTime.now();
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        final elapsed = DateTime.now().difference(warmupStart).inSeconds;
        _elapsedSec.value = elapsed;
        if (elapsed >= _heapWarmupSec) break;
      }

      _appendLog('byte-pressure warmup complete — entering scenario');

      // Narrow VM timeline to `Dart` stream only so the 50 s scenario
      // doesn't overflow the ring buffer and roll markScenarioBegin
      // off before export. Detector polls allocation profile
      // explicitly so the K=4 window is unaffected.
      await Sleuth.suspendNonEssentialTimelineStreams();

      Sleuth.markScenarioBegin(scenarioName);

      _phaseStatus.value = 'awaiting heap_growing in scenario';
      final scenarioStart = DateTime.now();
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        final mp = Sleuth.memoryPressureDetector;
        final active = mp != null && mp.isHeapGrowingActive();
        _heapGrowingActive.value = active;
        final elapsedInScenario = DateTime.now()
            .difference(scenarioStart)
            .inSeconds;
        _elapsedSec.value = elapsedInScenario;
        if (active) break;
        if (elapsedInScenario > _scenarioHeapGrowingTimeoutSec) {
          throw StateError(
            'heap_growing did not re-activate within '
            '$_scenarioHeapGrowingTimeoutSec s post-scenario-begin — '
            'abort. Verify byte pressure exceeds the detector\'s '
            'growthThresholdBytesPerSec (default 512 KB/s).',
          );
        }
      }
      _appendLog('heap_growing re-armed inside scenario — starting workload');

      // Drive polls explicitly so the K=4 window populates even when
      // the timeline buffer is idle. Inline allocation pacing keeps
      // allocation lock-stepped with polls — a separate Timer.periodic
      // could drift under iOS thermal throttling and produce identical
      // samples (e.g. `[86, 86, 107, 109]`) that fail the 3-of-3
      // ascending gate.
      _phaseStatus.value = 'leg workload';
      final subsPerSecPerClass = leg.totalSubsPerClass / _legDurationSec;
      var allocatedTarget = 0.0;
      final workloadStart = DateTime.now();
      var nextPollAtSec = _allocPollIntervalSec;
      var pollCount = 0;
      var matchedAtLeastOnce = false;
      while (true) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        // Top up before the poll-time check so the next poll observes
        // growth on the first qualifying iteration.
        allocatedTarget += subsPerSecPerClass;
        _topUpSubscriptions(allocatedTarget.floor());
        final mp = Sleuth.memoryPressureDetector;
        _heapGrowingActive.value = mp != null && mp.isHeapGrowingActive();
        final elapsed = DateTime.now().difference(workloadStart).inSeconds;
        _elapsedSec.value = elapsed;
        if (elapsed >= nextPollAtSec) {
          pollCount++;
          final result = await Sleuth.pollStreamResourceAllocationProfileNow();
          if (result.matchedCount != null && result.matchedCount! > 0) {
            matchedAtLeastOnce = true;
          }
          _appendLog('Poll $pollCount: $result');
          nextPollAtSec += _allocPollIntervalSec;
        }
        _samplesInWindow.value = monitor.lastObservedSamplesInWindow;
        _lastObservedDelta.value = monitor.lastObservedTopGrowthDelta;
        if (elapsed >= _legDurationSec) break;
      }
      // Top up before the final poll so the last K=4 sample is
      // strictly greater than its predecessor. Without this the
      // loop's last iteration and the final poll observe identical
      // counts, breaking the 3-of-3 ascending gate.
      allocatedTarget += subsPerSecPerClass * 1.5;
      _topUpSubscriptions(allocatedTarget.floor());
      pollCount++;
      final finalResult = await Sleuth.pollStreamResourceAllocationProfileNow();
      if (finalResult.matchedCount != null && finalResult.matchedCount! > 0) {
        matchedAtLeastOnce = true;
      }
      _appendLog('Poll $pollCount (final): $finalResult');
      // Drain dart-timeline events so the wrapped poll's emission
      // trace lands before scenarioEnd. Do NOT call
      // `monitor.flushStreamResourceEvaluation()` directly — it
      // bypasses `_recordIssuesForCapture` and emissions never get a
      // trace event.
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 1));
      Sleuth.markScenarioEnd(scenarioName);

      // Let the ring buffer absorb post-flush records before export.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;

      await Sleuth.resumeAllTimelineStreams();

      final observedDelta = monitor.lastObservedTopGrowthDelta;
      final samples = monitor.lastObservedSamplesInWindow;
      _appendLog(
        'final state: top-class Δ = ${observedDelta ?? "<null>"}, '
        'samples=$samples/4, matched_polls=$matchedAtLeastOnce',
      );

      // Refuse export when window never filled OR no poll matched.
      // Without this, a broken poll path (RPC timeout, libUri null,
      // watchlist drift) would produce a valid-looking below-leg JSON
      // with `samples=0, Δ=0`.
      if (samples < 4 || !matchedAtLeastOnce) {
        _appendLog(
          'REFUSE EXPORT: samples=$samples/4 (need 4) AND/OR '
          'matched_polls=$matchedAtLeastOnce (need true). Workload '
          'did not produce verifiable measurement. Re-run leg.',
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text('${leg.label} REFUSED — see log'),
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      String? stashed;
      String? rewriteError;
      try {
        stashed = await Sleuth.exportCaptureJson(
          scenario: scenarioName,
          role: leg.label,
          magnitudeMin: leg.topDeltaMin,
          magnitudeObserved: observedDelta ?? 0,
          magnitudeMax: leg.topDeltaMax,
          unit: 'instances',
          device: 'iPhone 12',
          deviceOsVersion: 'iOS 17.5',
          flutterVersion: '3.41.4',
          captureCommand:
              'fvm flutter run --profile -d "iPhone 12" '
              '--dart-define=SLEUTH_CAPTURE_MODE=true',
          magnitudeSourceEventName: '',
          bracketStableId: 'stream_resource_growth',
          bracketSeverityLabel: 'warning',
        );
        if (stashed != null) {
          // Align operator-claimed observed to the detector-stamped
          // `topGrowthDelta` so bracket-band check + per-record
          // cross-check + axis-in-role-band all reduce to one value.
          try {
            final detectorObserved = _extractTopGrowthDeltaMax(stashed);
            if (detectorObserved != null) {
              stashed = _replaceExpectedObserved(stashed, detectorObserved);
            } else if (leg.label != 'below') {
              rewriteError =
                  'no `sleuth.issue.stream_resource_growth.warning` event '
                  'in scenario span — cannot rewrite expectedMagnitude.observed';
            }
          } catch (e) {
            rewriteError = '$e';
          }
        }
      } catch (e, st) {
        developer.log(
          '[sleuth.capture] exportCaptureJson threw: $e',
          name: 'sleuth.capture',
          error: e,
          stackTrace: st,
        );
        stashed = null;
      }
      if (rewriteError != null) {
        _appendLog('[${leg.label}] post-process WARNING: $rewriteError');
      }

      if (!mounted) return;
      _lastCompletedLeg = stashed != null ? leg.label : null;
      _stashedCaptureJson = stashed;
      if (stashed == null) {
        final reason = Sleuth.lastCaptureExportFailure ?? '<unknown>';
        _appendLog('[${leg.label}] export FAILED: $reason');
      } else {
        _appendLog('[${leg.label}] export OK');
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            stashed != null
                ? '${leg.label} OK (Δ=${observedDelta ?? 0}). Tap Export.'
                : '${leg.label} FAILED — see log',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e, st) {
      developer.log(
        '[sleuth.capture] FAILED ${leg.label}: $e',
        name: 'sleuth.capture',
        error: e,
        stackTrace: st,
      );
      _appendLog('FAIL ${leg.label}: $e');
    } finally {
      _stopBytePressure();
      // Idempotent resume covers the throw path where the success
      // branch never ran.
      try {
        await Sleuth.resumeAllTimelineStreams();
      } catch (_) {}
      _phaseStatus.value = 'idle';
      _busy.value = false;
    }
  }

  void _startBytePressure() {
    _bytePressureTimer?.cancel();
    _bytePressureTimer = Timer.periodic(
      const Duration(milliseconds: _bytePressureTickIntervalMs),
      (_) {
        _retainedBytes.add(Uint8List(_bytePressurePerTickKb * 1024));
        // Cap bounds peak memory; slope is sustained by allocation
        // rate, not retained size.
        if (_retainedBytes.length > _bytePressureMaxEntries) {
          _retainedBytes.removeAt(0);
        }
      },
    );
  }

  void _stopBytePressure() {
    _bytePressureTimer?.cancel();
    _bytePressureTimer = null;
  }

  // Caller-driven top-up; lock-stepped with the poll loop's 1 s tick
  // so iOS thermal throttling can't desync allocation from polling.
  // Two distinct dart:async classes (`_BroadcastSubscription` from a
  // broadcast controller, `_ControllerSubscription` from
  // `Stream.periodic`) satisfy the ≥2-classes-growing precondition.
  void _topUpSubscriptions(int target) {
    while (_broadcastSubs.length < target) {
      final controller = StreamController<void>.broadcast();
      _broadcastSubs.add(controller.stream.listen((_) {}));
      // Retain the controller — closing it would auto-cancel.
      _retainedControllers.add(controller);
    }
    while (_bufferingSubs.length < target) {
      final stream = Stream<void>.periodic(const Duration(seconds: 60), (_) {});
      _bufferingSubs.add(stream.listen((_) {}));
    }
  }

  /// Returns max `topGrowthDelta` across detector emissions in the
  /// span (mirrors schema default `observedAxisReduction: 'max'`), or
  /// null when no emission landed (sub-threshold workload).
  num? _extractTopGrowthDeltaMax(String json) {
    final root = jsonDecode(json) as Map<String, dynamic>;
    final events = root['traceEvents'];
    if (events is! List) return null;
    num? max;
    for (final ev in events) {
      if (ev is! Map) continue;
      if (ev['name'] != 'sleuth.issue.stream_resource_growth.warning') continue;
      final args = ev['args'];
      if (args is! Map) continue;
      Object? raw = args['topGrowthDelta'];
      if (raw == null) {
        final dartArgs = args['Dart Arguments'];
        if (dartArgs is Map) raw = dartArgs['topGrowthDelta'];
      }
      num? parsed;
      if (raw is String && raw.isNotEmpty) {
        parsed = num.tryParse(raw);
      } else if (raw is num) {
        parsed = raw;
      }
      if (parsed == null) continue;
      if (max == null || parsed > max) max = parsed;
    }
    return max;
  }

  /// Returns a copy of [json] with `expectedMagnitude.observed`
  /// rewritten to [observed]. Throws [StateError] on missing fields
  /// so a wrapped-capture shape change cannot silently degrade to a
  /// no-op rewrite.
  String _replaceExpectedObserved(String json, num observed) {
    final root = jsonDecode(json) as Map<String, dynamic>;
    final meta = root['sleuthMetadata'];
    if (meta is! Map<String, dynamic>) {
      throw StateError('sleuthMetadata missing or not a Map.');
    }
    final expected = meta['expectedMagnitude'];
    if (expected is! Map<String, dynamic>) {
      throw StateError(
        'sleuthMetadata.expectedMagnitude missing or not a Map.',
      );
    }
    if (!expected.containsKey('observed')) {
      throw StateError('sleuthMetadata.expectedMagnitude.observed missing.');
    }
    expected['observed'] = observed;
    return const JsonEncoder.withIndent('  ').convert(root);
  }

  Future<void> _exportLast() async {
    if (_stashedCaptureJson == null || _lastCompletedLeg == null) return;
    await Clipboard.setData(ClipboardData(text: _stashedCaptureJson!));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${_lastCompletedLeg!} JSON to clipboard'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stream Resource Capture')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Bracket triad — StreamSubscription pattern only.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<bool>(
              valueListenable: _busy,
              builder: (_, busy, _) => Row(
                children: _legs
                    .map(
                      (leg) => Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: ElevatedButton(
                            onPressed: busy ? null : () => _runLeg(leg),
                            child: Text(
                              '${leg.label}\n'
                              'Δ ${leg.topDeltaMin}-${leg.topDeltaMax}',
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<String>(
              valueListenable: _phaseStatus,
              builder: (_, phase, _) => Text('Phase: $phase'),
            ),
            ValueListenableBuilder<int>(
              valueListenable: _elapsedSec,
              builder: (_, sec, _) => Text('Elapsed: ${sec}s'),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _heapGrowingActive,
              builder: (_, active, _) => Text(
                'heap_growing: ${active ? "ACTIVE" : "—"}',
                style: TextStyle(color: active ? Colors.green : Colors.grey),
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: _samplesInWindow,
              builder: (_, n, _) => Text('Samples in window: $n / 4'),
            ),
            ValueListenableBuilder<int?>(
              valueListenable: _lastObservedDelta,
              builder: (_, delta, _) => Text('Top-class Δ: ${delta ?? "—"}'),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<bool>(
              valueListenable: _busy,
              builder: (_, busy, _) => ElevatedButton(
                onPressed: busy || _stashedCaptureJson == null
                    ? null
                    : _exportLast,
                child: Text(
                  _stashedCaptureJson == null
                      ? 'Export (no leg yet)'
                      : 'Export ${_lastCompletedLeg!} JSON to clipboard',
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Log:', style: TextStyle(fontWeight: FontWeight.bold)),
            Expanded(
              child: ValueListenableBuilder<List<String>>(
                valueListenable: _log,
                builder: (_, lines, _) => ListView.builder(
                  itemCount: lines.length,
                  itemBuilder: (_, i) => Text(
                    lines[i],
                    style: const TextStyle(fontFamily: 'Courier', fontSize: 11),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
