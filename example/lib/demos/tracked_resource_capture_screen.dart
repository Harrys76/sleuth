import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Capture helper for `tracked_resource_concurrent.warning` (bracket
/// threshold 6; live count > default `maxConcurrent` 5). The detector
/// emits a parametric `tracked_resource_concurrent:<name>` stableId for
/// UI but routes the capture trace event through
/// `PerformanceIssue.captureTraceStableId = 'tracked_resource_concurrent'`
/// so the bracket validator's byte-exact filter matches.
///
/// **Procedure (USB iPhone, in-app export):**
///
///  1. `cd example && fvm flutter run --profile -d "iPhone 12" \
///        --dart-define=SLEUTH_CAPTURE_MODE=true`. First build attaches
///     DevTools (FRAME mode).
///  2. Quit `flutter run` (`q`). DevTools detaches.
///  3. Re-open the app from the home screen so VM+ mode activates.
///  4. Navigate to "Tracked resource capture helper" → tap a leg →
///     wait for "tap Export now" → tap **Export last leg** → paste
///     from clipboard.
///
/// Per-leg targets (allocate N `Object()`s, register each via
/// `Sleuth.trackResource('capture_tracked_resource', obj)`, hold in a
/// strong-ref list):
///
/// - **Below** (5): not > threshold, no emission.
/// - **At** (8): in at-band [6, 9] (atTolerance 0.5).
/// - **Above** (16): in above-band (9, 18] (aboveCeilingMultiplier 3.0).
///
/// Synchronous allocation is load-bearing — yielding between refs lets
/// the sweep timer fire at a partial count, locking
/// `concurrentFirstCrossMicros` to a value the controller's composite-key
/// dedup then uses to collapse later emissions. No `await` between
/// `markScenarioBegin` and `flushConcurrentEvaluation()`.
const _kResourceName = 'capture_tracked_resource';

class TrackedResourceCaptureScreen extends StatefulWidget {
  const TrackedResourceCaptureScreen({super.key});

  @override
  State<TrackedResourceCaptureScreen> createState() =>
      _TrackedResourceCaptureScreenState();
}

enum _Leg {
  below('below', 5),
  at('at', 8),
  above('above', 16);

  const _Leg(this.label, this.refCount);
  final String label;
  final int refCount;
}

class _TrackedResourceCaptureScreenState
    extends State<TrackedResourceCaptureScreen> {
  final List<String> _log = [];
  bool _busy = false;
  String? _lastCompletedLeg;
  int? _legObservedPeak;
  String? _inFlightScenarioName;
  // Strong-ref list so GC cannot reclaim the workload mid-scenario.
  // Cleared on dispose, between legs, and after each export.
  final List<Object> _heldRefs = [];
  // Tracks whether `Sleuth.suspendNonEssentialTimelineStreams()` was
  // awaited successfully. Restored from every exit path (success,
  // catch, dispose) so popping the screen mid-leg does not strand the
  // engine on the narrowed allowlist for the rest of the app session.
  // ignore: prefer_final_fields
  bool _streamsSuspended = false;

  @override
  void dispose() {
    final scenario = _inFlightScenarioName;
    if (scenario != null) {
      _endScenarioOnce(scenario);
    }
    if (_streamsSuspended) {
      _streamsSuspended = false;
      // Fire-and-forget from dispose() is acceptable — leaving streams
      // narrowed for the rest of the session is strictly worse than a
      // missed-restore log line on shutdown.
      unawaited(Sleuth.resumeAllTimelineStreams());
    }
    // Drop refs + bucket so the next route entry starts clean.
    Sleuth.trackedResourceDetector?.untrackAll(_kResourceName);
    _heldRefs.clear();
    super.dispose();
  }

  void _endScenarioOnce(String scenarioName) {
    if (_inFlightScenarioName != scenarioName) return;
    _inFlightScenarioName = null;
    Sleuth.markScenarioEnd(scenarioName);
  }

  Future<void> _runLeg(_Leg leg) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _lastCompletedLeg = null;
      _legObservedPeak = null;
      _log.add(
        '[${leg.label}] pre-leg → untrackAll($_kResourceName), '
        'clear heldRefs (${_heldRefs.length})',
      );
    });

    final detector = Sleuth.trackedResourceDetector;
    if (detector == null) {
      setState(() {
        _busy = false;
        _log.add(
          '[${leg.label}] FAILED: Sleuth.trackedResourceDetector is null. '
          'Verify Sleuth.init() ran with captureMode=true and '
          '--dart-define=SLEUTH_CAPTURE_MODE=true.',
        );
      });
      return;
    }

    // Drop prior-leg refs + bucket so this leg's first-cross identity
    // is unambiguously this leg's; clear strong refs so prior workload
    // becomes collectible.
    detector.untrackAll(_kResourceName);
    _heldRefs.clear();

    final scenarioName = 'tracked_resource_concurrent_${leg.label}';
    final messenger = ScaffoldMessenger.of(context);

    try {
      // Narrow VM streams BEFORE markScenarioBegin so Embedder/GC churn
      // cannot roll `sleuth.scenario.begin` off the ring buffer.
      await Sleuth.suspendNonEssentialTimelineStreams();
      _streamsSuspended = true;

      _inFlightScenarioName = scenarioName;
      // markScenarioBegin propagates resetCaptureState across detectors.
      Sleuth.markScenarioBegin(scenarioName);

      // Synchronous allocate + register. Strong-refs keep the detector's
      // WeakReference targets alive for the scenario span.
      for (var i = 0; i < leg.refCount; i++) {
        final obj = Object();
        _heldRefs.add(obj);
        Sleuth.trackResource(_kResourceName, obj);
      }

      // Bypass the 10 s sweep timer; emit synchronously so the in-span
      // trace record carries the full workload count.
      detector.flushConcurrentEvaluation();

      // Yield 3 frames so the controller's post-frame scan tick fires +
      // _recordIssuesForCapture stamps the trace event inside the span.
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 32));
      }

      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));

      // Name-scoped peak — aggregate `peakObservedLiveCount` would track
      // an unrelated bucket if another `Sleuth.trackResource(...)`
      // registration is active in the app session.
      final observed = detector.peakObservedLiveCountFor(_kResourceName);

      _endScenarioOnce(scenarioName);
      // Drain so VM trace buffer settles before exportCaptureJson reads.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastCompletedLeg = leg.label;
        _legObservedPeak = observed;
        _log.add(
          '[${leg.label}] scenario.end (peak: $observed live instances) '
          '— tap "Export last leg" to write the wrapped capture.',
        );
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${leg.label} OK (peak $observed instances). Tap Export now.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e, st) {
      _endScenarioOnce(scenarioName);
      developer.log(
        '[sleuth.capture] FAILED ${leg.label}: $e',
        name: 'sleuth.capture',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _log.add('[${leg.label}] FAILED: $e');
        });
      }
    } finally {
      // Restore streams from every exit path; guard against double-resume
      // when suspend itself threw.
      if (_streamsSuspended) {
        _streamsSuspended = false;
        await Sleuth.resumeAllTimelineStreams();
      }
    }
  }

  Future<void> _exportLastLeg() async {
    final leg = _lastCompletedLeg;
    final observed = _legObservedPeak;
    final messenger = ScaffoldMessenger.of(context);
    if (leg == null || observed == null) {
      setState(() {
        _log.add(
          'Export: no completed leg yet. Tap a leg button and wait '
          'for "tap Export" before exporting.',
        );
      });
      return;
    }

    setState(() {
      _busy = true;
      _log.add('[$leg] Export: composing wrapped capture JSON…');
    });

    final scenarioName = 'tracked_resource_concurrent_$leg';
    // ±1 absorbs any single-instance jitter between detector
    // measurement and exportCaptureJson read; observed is the
    // load-bearing value the audit gate cross-checks via
    // `extraTraceArgs.liveInstanceCount`.
    final magnitudeMin = (observed - 1).clamp(0, 1 << 30);
    final magnitudeMax = observed + 1;

    String? json;
    try {
      json = await Sleuth.exportCaptureJson(
        scenario: scenarioName,
        role: leg,
        magnitudeMin: magnitudeMin,
        magnitudeObserved: observed,
        magnitudeMax: magnitudeMax,
        unit: 'instances',
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterVersion: '3.41.4',
        captureCommand:
            'fvm flutter run --profile -d "iPhone 12" '
            '--dart-define=SLEUTH_CAPTURE_MODE=true',
        // Magnitude is the detector's peakObservedLiveCount getter
        // value — no matching named timeline event the schema can
        // derive from. Empty string skips event-derivation.
        magnitudeSourceEventName: '',
        bracketStableId: 'tracked_resource_concurrent',
        bracketSeverityLabel: 'warning',
      );
    } catch (e) {
      json = null;
      if (mounted) {
        setState(() => _log.add('[$leg] Export FAILED: $e'));
      }
    }
    if (!mounted) return;
    if (json == null) {
      final state = Sleuth.diagnoseCaptureState();
      final reason = Sleuth.lastCaptureExportFailure ?? '(no reason captured)';
      setState(() {
        _busy = false;
        _log.add(
          '[$leg] Export FAILED. '
          'initialized=${state.initialized} '
          'captureMode=${state.captureMode} '
          'vmConnected=${state.vmConnected}. '
          'Reason: $reason',
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
          '[$leg] Export OK — wrapped capture '
          '(${jsonText.length} chars) copied to iOS clipboard.',
        );
        _log.add(
          '[$leg] Paste into Notes / Mail / AirDrop → send to Mac. '
          'Save as $leg.json under '
          'test/validation/captures/tracked_resource_concurrent/.',
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
        _log.add('[$leg] Clipboard copy FAILED: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tracked resource capture helper')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'tracked_resource_concurrent WARNING tier (live count > '
                'maxConcurrent=5). Each leg synchronously allocates + '
                'registers N Object() instances and holds them in a '
                'strong-ref list. The bracket trace event uses the bare '
                'family stableId (`tracked_resource_concurrent`); UI '
                'cards retain the parametric `:<name>` suffix.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              _LegButton(
                label: 'Below (5 instances) — passes',
                subtitle: 'Sub-threshold; peakObservedLiveCount = 5',
                enabled: !_busy,
                onTap: () => _runLeg(_Leg.below),
              ),
              const SizedBox(height: 8),
              _LegButton(
                label: 'At (8 instances) — warning',
                subtitle: 'In at-band [6, 9] (atTolerance 0.5)',
                enabled: !_busy,
                onTap: () => _runLeg(_Leg.at),
              ),
              const SizedBox(height: 8),
              _LegButton(
                label: 'Above (16 instances) — warning',
                subtitle:
                    'In above-band (9, 18] '
                    '(aboveCeilingMultiplier 3.0)',
                enabled: !_busy,
                onTap: () => _runLeg(_Leg.above),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _exportLastLeg,
                icon: const Icon(Icons.save_alt),
                label: const Text('Export last leg'),
              ),
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

class _LegButton extends StatelessWidget {
  const _LegButton({
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
    return OutlinedButton(
      onPressed: enabled ? onTap : null,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
