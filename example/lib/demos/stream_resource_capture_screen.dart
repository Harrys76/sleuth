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

import 'capture_driver.dart';

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

// `topDeltaMin` and `topDeltaMax` are only the `expectedMagnitude.min`
// and `max` the export writes, in `topGrowthDelta` units (single-class
// delta over K=4). The schema needs min <= observed <= max. They are
// not the acceptance bands: the screen judges each leg against the
// detector's bracket (threshold 50, atTolerance 0.6, ceiling 3.0) with
// `CaptureBracket`, which draws below as under 50, at as [50, 80] and
// above as (80, 150], the band the audit requires of the above leg's
// detector value. The above leg's min of 51 is therefore looser than
// what the screen accepts. `totalSubsPerClass` is tuned for the
// iPhone 12 first-emission ratio (about 0.44); above=230 lands near 101.
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

/// The bracket every stream leg is judged against, read from [metadata]
/// (the detector's `validationMetadata`).
CaptureBracket? streamResourceBracket(DetectorMetadata metadata) =>
    CaptureBracket.fromMetadata(
      metadata,
      stableId: 'stream_resource_growth',
      severityLabel: 'warning',
    );

/// Why a below leg cannot be exported given the detector's last
/// top-class growth [delta], or null when [delta] lies in
/// `[1, threshold)`. A null delta means no watched class rose at every
/// poll of the window, which is no measurement at all, so the leg is
/// `UNMEASURED` rather than exported with an observed value of 0.
LegRefusal? streamBelowRefusal(int? delta, CaptureBracket bracket) =>
    measurementRefusal(
      delta,
      role: 'below',
      bracket: bracket,
      what: 'top-class growth',
      unit: 'instances',
    );

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
    // Provenance is a property of the build, so a leg that could never
    // be exported is refused before the warmup and the 50 s workload.
    final refusal = provenanceRefusal(leg.label);
    if (refusal != null) {
      _appendLog(refusal);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${leg.label} refused: capture provenance (see log)'),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    final monitor = Sleuth.streamResourceDetector;
    if (monitor == null) {
      _appendLog(
        'FAIL: StreamResourceDetector not available — verify '
        'kReleaseMode=false AND DetectorType.streamResource enabled.',
      );
      return;
    }
    final bracket = streamResourceBracket(monitor.validationMetadata);
    if (bracket == null) {
      _appendLog(
        'FAIL: StreamResourceDetector declares no '
        'stream_resource_growth.warning bracket.',
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
      if (!mounted) return;

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

      // A below leg exports the detector's own top-class growth, so it
      // needs one in [1, threshold). A null growth is no measurement and
      // the schema rejects an observed value of 0.
      if (leg.label == 'below') {
        final belowRefusal = streamBelowRefusal(observedDelta, bracket);
        if (belowRefusal != null) {
          _refuseLeg(leg, belowRefusal, messenger);
          return;
        }
      }

      String? exported;
      String? exportFailure;
      try {
        // Checked when the leg started; this is a safety net.
        final provenance = requireCaptureProvenance();
        exported = await Sleuth.exportCaptureJson(
          scenario: scenarioName,
          role: leg.label,
          magnitudeMin: leg.topDeltaMin,
          // The at and above values are placeholders; the post-process
          // after the export replaces them with the in-span detector
          // value.
          magnitudeObserved: observedDelta ?? leg.topDeltaMin,
          magnitudeMax: leg.topDeltaMax,
          unit: 'instances',
          device: provenance.device,
          deviceOsVersion: provenance.deviceOsVersion,
          flutterVersion: provenance.flutterVersion,
          captureCommand: provenance.captureCommand,
          magnitudeSourceEventName: '',
          bracketStableId: 'stream_resource_growth',
          bracketSeverityLabel: 'warning',
        );
        if (exported == null) {
          exportFailure =
              Sleuth.lastCaptureExportFailure ??
              'exportCaptureJson returned null without a reason';
        }
      } catch (e, st) {
        developer.log(
          '[sleuth.capture] export threw: $e',
          name: 'sleuth.capture',
          error: e,
          stackTrace: st,
        );
        exportFailure = '$e';
      }
      if (!mounted) return;
      if (exported == null) {
        _appendLog('[${leg.label}] export FAILED: $exportFailure');
        messenger.showSnackBar(
          SnackBar(
            content: Text('${leg.label} export failed (see log)'),
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      // The at and above legs take `expectedMagnitude.observed` from
      // the in-span detector records, reduced the way the audit reduces
      // them, so the bracket check, the per-record cross-check and the
      // role-band check all judge one value. Any failure here stops the
      // stash.
      var json = exported;
      final CaptureRecordCount records;
      final num observed;
      try {
        records = countCaptureRecords(json, bracket: bracket, role: leg.label);
        if (leg.label == 'below') {
          observed = observedDelta!;
        } else {
          final reduced = records.reduced;
          if (reduced == null) {
            throw StateError(
              'no stamped in-span ${bracket.eventName} record to set '
              'expectedMagnitude.observed from',
            );
          }
          json = _replaceExpectedObserved(json, reduced);
          observed = reduced;
        }
      } catch (e) {
        _appendLog(
          '[${leg.label}] post-process FAILED: $e. Nothing stashed; re-run '
          'the leg.',
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text('${leg.label} post-process failed (see log)'),
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      final recordsRefusal = recordRefusal(
        checkCaptureRecords(
          records,
          bracket: bracket,
          role: leg.label,
          observed: leg.label == 'below' ? null : observed,
          unit: 'instances',
        ),
        role: leg.label,
        bracket: bracket,
      );
      if (recordsRefusal != null) {
        _refuseLeg(leg, recordsRefusal, messenger);
        return;
      }

      _lastCompletedLeg = leg.label;
      _stashedCaptureJson = json;
      _appendLog('[${leg.label}] export OK (observed Δ $observed)');
      messenger.showSnackBar(
        SnackBar(
          content: Text('${leg.label} OK (Δ=$observed). Tap Export.'),
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
      // The notifiers are disposed with the screen.
      if (mounted) {
        _phaseStatus.value = 'idle';
        _busy.value = false;
      }
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

  /// Logs why [leg] stashes nothing (`[<leg>] UNMEASURED: ...` or
  /// `[<leg>] OUT-OF-BAND: ...`) and says so in a snackbar.
  void _refuseLeg(
    _Leg leg,
    LegRefusal refusal,
    ScaffoldMessengerState messenger,
  ) {
    _appendLog(
      '[${leg.label}] ${refusal.verdict}: ${refusal.reason}. Nothing '
      'stashed; re-run the leg.',
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text('${leg.label} ${refusal.verdict} (see log)'),
        duration: const Duration(seconds: 4),
      ),
    );
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
