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
/// Long-lived legs open `sleuth.scenario.begin` 10 s before flush, not
/// at the start of the wait. The ref is registered before the wait so
/// `firstSeenMicros` captures elapsed retention; the wait runs without
/// a span open (no markers to roll off the VM ring buffer); 10 s before
/// flush the span opens; sweep + flush emit inside the span. The 10 s
/// span width keeps the schema's inverse-ratio guard
/// (`expectedMagnitude.observed_micros / span_micros < 100×`) satisfied
/// for the largest claimed observed value (600 s / 10 s = 60×).
///
/// Per-leg targets (register each ref via
/// `Sleuth.trackResource('capture_tracked_resource', obj)`, hold in a
/// strong-ref list):
///
/// Concurrent (axis: `liveInstanceCount`):
/// - **Below** (5): not > threshold, no emission.
/// - **At** (8): in at-band [6, 9] (atTolerance 0.5).
/// - **Above** (16): in above-band (9, 18] (aboveCeilingMultiplier 3.0).
///
/// Long-lived (axis: `oldestInstanceAgeSeconds`; real wait at the
/// production 300 s threshold — total operator session ~20 min):
/// - **Below** (wait 250 s): age 250 s, no emission.
/// - **At** (wait 380 s): age 380 s, in at-band [300, 450].
/// - **Above** (wait 600 s): age 600 s, in above-band (450, 900].
///
/// Detector re-emits each sweep while age > 300 s so the trace contains
/// an ascending-age series; `observedAxisReduction: 'max'` picks the
/// leg-end value.
///
/// Concurrent legs: synchronous allocation is load-bearing — yielding
/// between refs lets the sweep timer fire at a partial count, locking
/// `concurrentFirstCrossMicros` to a value the controller's composite-key
/// dedup uses to collapse later emissions. No `await` between
/// `markScenarioBegin` and `flushConcurrentEvaluation()` for concurrent.
const _kResourceName = 'capture_tracked_resource';

class TrackedResourceCaptureScreen extends StatefulWidget {
  const TrackedResourceCaptureScreen({super.key});

  @override
  State<TrackedResourceCaptureScreen> createState() =>
      _TrackedResourceCaptureScreenState();
}

enum _LegFamily { concurrent, longLived }

enum _Leg {
  // Concurrent legs (axis: `liveInstanceCount`).
  concurrentBelow('below', _LegFamily.concurrent, refCount: 5, ageSeconds: 0),
  concurrentAt('at', _LegFamily.concurrent, refCount: 8, ageSeconds: 0),
  concurrentAbove('above', _LegFamily.concurrent, refCount: 16, ageSeconds: 0),
  // Long-lived legs (axis: `oldestInstanceAgeSeconds`). Single ref kept
  // below `maxConcurrent` so concurrent does not fire ambient. Real wait
  // at the production 300 s threshold; detector re-emits each sweep so
  // the trace contains an ascending-age series ending at leg-end value
  // — `observedAxisReduction: 'max'` picks the leg-end value naturally.
  longLivedBelow('below', _LegFamily.longLived, refCount: 1, ageSeconds: 250),
  longLivedAt('at', _LegFamily.longLived, refCount: 1, ageSeconds: 380),
  longLivedAbove('above', _LegFamily.longLived, refCount: 1, ageSeconds: 600);

  const _Leg(
    this.label,
    this.family, {
    required this.refCount,
    required this.ageSeconds,
  });
  final String label;
  final _LegFamily family;
  final int refCount;
  final int ageSeconds;

  String get scenarioFamily => family == _LegFamily.concurrent
      ? 'tracked_resource_concurrent'
      : 'tracked_resource_long_lived';
  String get bracketUnit =>
      family == _LegFamily.concurrent ? 'instances' : 'seconds';
}

class _TrackedResourceCaptureScreenState
    extends State<TrackedResourceCaptureScreen> {
  final List<String> _log = [];
  bool _busy = false;
  String? _lastCompletedLeg;
  _LegFamily? _lastCompletedLegFamily;
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
    // Drop refs + bucket so the next route entry starts clean. Also
    // clear any per-name threshold override the long-lived legs set —
    // overrides survive `resetCaptureState` by v0.28.0 design and
    // would otherwise persist for the rest of the app session.
    Sleuth.trackedResourceDetector?.untrackAll(_kResourceName);
    Sleuth.setResourceThreshold(_kResourceName);
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
      if (leg.family == _LegFamily.longLived) {
        _log.add(
          '[${leg.label}] long-lived leg: register ref → wait '
          '${leg.ageSeconds - 10} s pre-span → markScenarioBegin → wait '
          '10 s inside span → flush. Span ~10 s keeps schema inverse-'
          'ratio under 100× while ring buffer cannot roll markers off.',
        );
      }
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
    // becomes collectible. Also clear BOTH override axes so a stale
    // `Sleuth.setResourceThreshold(...)` cannot leak `effectiveMaxConcurrent`
    // or `effectiveLongLivedSeconds` into the captured trace event.
    detector.untrackAll(_kResourceName);
    _heldRefs.clear();
    Sleuth.setResourceThreshold(_kResourceName);

    final scenarioName = '${leg.scenarioFamily}_${leg.label}';
    final messenger = ScaffoldMessenger.of(context);
    final unitLabel = leg.bracketUnit;

    try {
      // Narrow VM streams BEFORE markScenarioBegin so Embedder/GC churn
      // cannot roll `sleuth.scenario.begin` off the ring buffer.
      await Sleuth.suspendNonEssentialTimelineStreams();
      _streamsSuspended = true;

      // Long-lived legs: scenario span opens 10 s BEFORE flush so the
      // span width is large enough to satisfy schema AB-1 inverse-ratio
      // (`expectedMagnitude.observed × unit_micros / span_micros < 100×`).
      // For 600 s observed, span ≥ 6 s; we pick 10 s for headroom and
      // to keep span < 600 s so a long real-time wait does not fill the
      // VM ring buffer before markers are emitted. The ref is
      // registered BEFORE the wait so its `firstSeenMicros` captures
      // the elapsed retention. Concurrent legs keep the synchronous
      // workload/markBegin sequence because their workload is
      // instantaneous.
      const longLivedSpanLeadSeconds = 10;
      if (leg.family == _LegFamily.longLived) {
        for (var i = 0; i < leg.refCount; i++) {
          final obj = Object();
          _heldRefs.add(obj);
          Sleuth.trackResource(_kResourceName, obj);
        }
        // Wait most of the leg's target age WITHOUT a span open.
        final preSpanWait = leg.ageSeconds - longLivedSpanLeadSeconds;
        if (preSpanWait > 0) {
          await Future<void>.delayed(Duration(seconds: preSpanWait));
        }
        _inFlightScenarioName = scenarioName;
        Sleuth.markScenarioBegin(scenarioName);
        // Then wait the rest INSIDE the span so the periodic sweep can
        // emit + the JSON observed-vs-span ratio stays under 100×.
        await Future<void>.delayed(Duration(seconds: longLivedSpanLeadSeconds));
      } else {
        _inFlightScenarioName = scenarioName;
        Sleuth.markScenarioBegin(scenarioName);
        // Synchronous allocate + register inside span (concurrent).
        for (var i = 0; i < leg.refCount; i++) {
          final obj = Object();
          _heldRefs.add(obj);
          Sleuth.trackResource(_kResourceName, obj);
        }
      }

      // Bypass the 10 s sweep timer; emit synchronously inside the new
      // (short) scenario span.
      detector.flushConcurrentEvaluation();

      // Read peak IMMEDIATELY after flush — before the post-frame yield
      // gives the periodic sweep timer a window to fire and overwrite.
      // Name-scoped getter avoids contamination from ambient buckets in
      // another part of the app.
      final observed = leg.family == _LegFamily.concurrent
          ? detector.peakObservedLiveCountFor(_kResourceName)
          : detector.peakObservedAgeSecondsFor(_kResourceName);

      // Yield 3 frames so the controller's post-frame scan tick fires +
      // _recordIssuesForCapture stamps the trace event inside the span.
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 32));
      }

      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));

      _endScenarioOnce(scenarioName);
      // Drain so VM trace buffer settles before exportCaptureJson reads.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastCompletedLeg = leg.label;
        _lastCompletedLegFamily = leg.family;
        _legObservedPeak = observed;
        _log.add(
          '[${leg.scenarioFamily}/${leg.label}] scenario.end '
          '(peak: $observed $unitLabel) — tap "Export last leg".',
        );
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${leg.scenarioFamily}/${leg.label} OK '
            '(peak $observed $unitLabel). Tap Export now.',
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
    final family = _lastCompletedLegFamily;
    final observed = _legObservedPeak;
    final messenger = ScaffoldMessenger.of(context);
    if (leg == null || family == null || observed == null) {
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

    final scenarioFamily = family == _LegFamily.concurrent
        ? 'tracked_resource_concurrent'
        : 'tracked_resource_long_lived';
    final scenarioName = '${scenarioFamily}_$leg';
    final unitLabel = family == _LegFamily.concurrent ? 'instances' : 'seconds';
    // ±1 unit absorbs single-step jitter between detector measurement
    // and exportCaptureJson read; observed is load-bearing — bracket
    // gate cross-checks via the family's observedAxisArgKey.
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
        unit: unitLabel,
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterVersion: '3.41.4',
        captureCommand:
            'fvm flutter run --profile -d "iPhone 12" '
            '--dart-define=SLEUTH_CAPTURE_MODE=true',
        // Magnitude is the detector's per-name peak getter value — no
        // matching named timeline event the schema can derive from.
        // Empty string skips event-derivation.
        magnitudeSourceEventName: '',
        bracketStableId: scenarioFamily,
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
          'test/validation/captures/$scenarioFamily/.',
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
              // Scrollable top — six leg buttons + export button overflow
              // shorter viewports otherwise. Log stays fixed-height at the
              // bottom so failure reasons are always visible.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'tracked_resource_concurrent (axis: liveInstanceCount)',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _LegButton(
                        label: 'Below (5 instances) — passes',
                        subtitle: 'Sub-threshold; peakObservedLiveCount = 5',
                        enabled: !_busy,
                        onTap: () => _runLeg(_Leg.concurrentBelow),
                      ),
                      const SizedBox(height: 8),
                      _LegButton(
                        label: 'At (8 instances) — warning',
                        subtitle: 'In at-band [6, 9] (atTolerance 0.5)',
                        enabled: !_busy,
                        onTap: () => _runLeg(_Leg.concurrentAt),
                      ),
                      const SizedBox(height: 8),
                      _LegButton(
                        label: 'Above (16 instances) — warning',
                        subtitle:
                            'In above-band (9, 18] '
                            '(aboveCeilingMultiplier 3.0)',
                        enabled: !_busy,
                        onTap: () => _runLeg(_Leg.concurrentAbove),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'tracked_resource_long_lived (axis: '
                        'oldestInstanceAgeSeconds; real wait at 300 s)',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _LegButton(
                        label: 'Below (wait 250 s ≈ 4 min) — passes',
                        subtitle: 'Sub-threshold; no emission',
                        enabled: !_busy,
                        onTap: () => _runLeg(_Leg.longLivedBelow),
                      ),
                      const SizedBox(height: 8),
                      _LegButton(
                        label: 'At (wait 380 s ≈ 6 min) — warning',
                        subtitle: 'In at-band [300, 450] (atTolerance 0.5)',
                        enabled: !_busy,
                        onTap: () => _runLeg(_Leg.longLivedAt),
                      ),
                      const SizedBox(height: 8),
                      _LegButton(
                        label: 'Above (wait 600 s = 10 min) — warning',
                        subtitle:
                            'In above-band (450, 900] '
                            '(aboveCeilingMultiplier 3.0)',
                        enabled: !_busy,
                        onTap: () => _runLeg(_Leg.longLivedAbove),
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
              const Divider(),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Log',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (_log.isNotEmpty)
                    Builder(
                      builder: (innerContext) {
                        return TextButton.icon(
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(
                              innerContext,
                            );
                            await Clipboard.setData(
                              ClipboardData(text: _log.reversed.join('\n')),
                            );
                            if (!mounted) return;
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('Log copied to clipboard.'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 14),
                          label: const Text(
                            'Copy log',
                            style: TextStyle(fontSize: 12),
                          ),
                        );
                      },
                    ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 180,
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
