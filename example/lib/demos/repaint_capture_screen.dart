import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Capture helper for the runtimeVerified tier raise on
/// `RepaintDetector.excessive_repaint.warning` (>30 paints/sec aggregate
/// over a 1 s VM window).
///
/// **Workload diversity is load-bearing.** The detector's evaluation
/// has three priority gates: debug per-widget > VM aggregate > debug
/// aggregate. To force emission through the VM aggregate path
/// (`stableId: 'excessive_repaint'`) and not the debug per-widget path
/// (`stableId: 'repaint_debug_<typeName>'`), each animated widget must
/// stay below the 30 paints/sec per-type threshold. We instantiate 32
/// distinct widget classes (`_PT00` through `_PT31`) so per-widget
/// debug counts stay sub-threshold while the VM aggregate count sums
/// to the targeted in-band magnitude. A single typeName driving all
/// paints would trigger the per-widget gate first and starve the
/// `excessive_repaint` capture.
///
/// **Procedure (USB iPhone, in-app export):**
///
///  1. `cd example && fvm flutter run --profile -d "iPhone 12" \
///        --dart-define=SLEUTH_CAPTURE_MODE=true`. First build attaches
///     DevTools (FRAME mode).
///  2. Quit `flutter run` (`q`). DevTools detaches.
///  3. Re-open the app from the home screen so VM+ mode activates.
///  4. Navigate to "Repaint capture helper" → tap a leg → wait for
///     "tap Export now" → tap **Export last leg** → paste from clipboard.
///
/// Per-leg targets (intervalMs = period between setState calls per
/// widget instance; 32 instances drive aggregate paint count):
///
/// - **Below** (intervalMs=2000): 32 widgets × 0.5 setState/sec = ~16
///   aggregate paints/sec. Sub-threshold; detector emits no issue;
///   `lastObservedPaintCount` populated for export.
/// - **At** (intervalMs=1000): 32 widgets × 1 setState/sec = ~32
///   aggregate paints/sec. In `additionalBrackets[0].atTolerance: 0.10`
///   band [27, 33].
/// - **Above** (intervalMs=500): 32 widgets × 2 setState/sec = ~64
///   aggregate paints/sec. Above ceiling per `aboveCeilingMultiplier:
///   2.0` → ≥60.
///
/// Real-device tick-rate calibration may need 2–3 attempts. The
/// schema's `observedAxisTolerance: 0.15` absorbs ±15% drift around the
/// detector-measured peak.
/// Number of distinct widget runtime types (`_PT00`..`_PT31`) the
/// workload mounts per leg. Pinned to the count of class declarations
/// at the bottom of this file — the per-widget debug gate keys paint
/// counts on `runtimeType`, so reducing this without removing the
/// matching `_PT<NN>` classes (or vice versa) silently breaks the
/// "VM aggregate path forced via type diversity" invariant the
/// validationMetadata bracket assumes.
const int _kTileCount = 32;

class RepaintCaptureScreen extends StatefulWidget {
  const RepaintCaptureScreen({super.key});

  @override
  State<RepaintCaptureScreen> createState() => _RepaintCaptureScreenState();
}

enum _Leg {
  below('below', 2000),
  at('at', 1000),
  above('above', 650);

  const _Leg(this.label, this.intervalMs);
  final String label;
  final int intervalMs;
}

class _RepaintCaptureScreenState extends State<RepaintCaptureScreen> {
  final List<String> _log = [];
  bool _busy = false;
  bool _legActive = false;
  int _intervalMs = 0;
  String? _lastCompletedLeg;
  int? _legObservedPeak;
  String? _inFlightScenarioName;
  // Tracks whether `Sleuth.suspendNonEssentialTimelineStreams()` was
  // awaited successfully. Restored from any exit path (success, catch,
  // dispose) so popping the screen mid-leg does not strand the engine
  // on the narrowed allowlist for the remainder of the app session.
  bool _streamsSuspended = false;

  @override
  void dispose() {
    final scenario = _inFlightScenarioName;
    if (scenario != null) {
      _endScenarioOnce(scenario);
    }
    if (_streamsSuspended) {
      _streamsSuspended = false;
      // Fire-and-forget is acceptable from dispose() — the State is
      // gone and there is no caller to surface failures to. The risk
      // of leaving streams suspended for the rest of the session is
      // strictly worse than a missed-restore log line on shutdown.
      unawaited(Sleuth.resumeAllTimelineStreams());
    }
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
      _legActive = true;
      _intervalMs = leg.intervalMs;
      _log.add(
        '[${leg.label}] warmup → mount 32 widgets, wait 1.5s for mount '
        'cascade to settle BEFORE scenario.begin',
      );
    });

    // Warmup before scenario.begin: let the 32-widget mount cascade,
    // initial layout, and first-frame paint burst all happen OUTSIDE
    // the measured span. Without this, the very first 1s window after
    // scenario.begin captures a paint count inflated by mount overhead
    // and the below leg incorrectly fires excessive_repaint.warning
    // even though steady-state is sub-threshold.
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    // `mounted == false` means dispose() already ran; calling setState
    // would throw. Plain return is the only safe action.
    if (!mounted) return;

    final scenarioName = 'excessive_repaint_${leg.label}';
    final detector = Sleuth.repaintDetector;
    if (detector == null) {
      setState(() {
        _busy = false;
        _legActive = false;
        _log.add(
          '[${leg.label}] FAILED: Sleuth.repaintDetector is null. '
          'Verify Sleuth.init() ran with captureMode=true and '
          '--dart-define=SLEUTH_CAPTURE_MODE=true.',
        );
      });
      return;
    }

    // Reset detector AFTER warmup but BEFORE markScenarioBegin so the
    // 1500 ms mount-cascade paint counts do NOT carry into the
    // measured span. Without this reset the first 1s VM window after
    // scenario.begin reads accumulated mount paints + leg paints,
    // making the below leg fire excessive_repaint.warning even
    // though steady-state aggregate is sub-threshold.
    detector.resetCaptureState();

    setState(() {
      _log.add(
        '[${leg.label}] scenario.begin → 32 widgets × '
        '${(1000 / leg.intervalMs).toStringAsFixed(1)} setState/sec '
        '(target ~${(32 * 1000 / leg.intervalMs).round()} aggregate '
        'paints/sec)',
      );
    });
    final messenger = ScaffoldMessenger.of(context);

    try {
      // Suspend non-essential streams (Embedder, GC, raster) BEFORE
      // markScenarioBegin so 32 widgets animating at 60Hz over the 4s
      // span don't overflow the VM ring buffer and roll the
      // scenario.begin marker off before exportCaptureJson reads it.
      // Awaited so the workload cannot start until the allowlist is
      // installed; tracked via [_streamsSuspended] so every exit path
      // (success, catch, dispose) restores.
      await Sleuth.suspendNonEssentialTimelineStreams();
      _streamsSuspended = true;

      // Set the in-flight name BEFORE markScenarioBegin so a throw
      // inside markScenarioBegin still leaves dispose() with a
      // matching name to emit the closing marker for.
      _inFlightScenarioName = scenarioName;
      Sleuth.markScenarioBegin(scenarioName);

      // Workload window: 4 seconds gives the detector four 1s VM
      // windows to settle on a steady-state peak. The first window
      // may be partial (timer phase) — `'max'` axis reduction picks
      // the steady-state window, not the partial first.
      const workloadDuration = Duration(seconds: 4);
      await Future<void>.delayed(workloadDuration);

      // Stop the workload BEFORE flushing so no new paints land
      // between flush and scenario.end.
      if (mounted) {
        setState(() => _legActive = false);
      }
      // One frame for the unmount to settle.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Drain pending VM trace events into the buffer so any
      // in-flight excessive_repaint emission lands inside the span.
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));
      // Refresh the detector's `lastObservedPaintCount` so a partial
      // in-flight window can also be observed (peak intentionally not
      // updated by the flush — peak is restricted to naturally-closed
      // windows that flow through `_evaluate` and therefore appear as
      // `observedPaintCount` args on emission records).
      detector.flushPaintEvaluation();
      // Read peak — bracket axis reduction is `'max'`, and only the
      // window-close path bumps peak, so the exported magnitude is
      // guaranteed to match an in-span emission's observedPaintCount.
      final observed = detector.peakObservedPaintCount;

      _endScenarioOnce(scenarioName);
      // Post-scenario drain so VM trace buffer settles before
      // exportCaptureJson reads it.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastCompletedLeg = leg.label;
        _legObservedPeak = observed;
        _log.add(
          '[${leg.label}] scenario.end (peak: $observed paints / 1s window) '
          '— tap "Export last leg" to write the wrapped capture.',
        );
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${leg.label} OK (peak $observed paints/window). Tap Export now.',
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
          _legActive = false;
          _log.add('[${leg.label}] FAILED: $e');
        });
      }
    } finally {
      // Restore streams from every exit path. The `_streamsSuspended`
      // guard ensures we do not double-resume when the scenario never
      // narrowed (e.g. the suspend itself threw before completing).
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

    final scenarioName = 'excessive_repaint_$leg';
    // ±2 paints absorbs sub-second wall-clock jitter between detector
    // measurement and exportCaptureJson read; observed is the
    // load-bearing value the audit gate cross-checks via
    // observedPaintCount in the trace record.
    final magnitudeMin = (observed - 2).clamp(0, 1 << 30);
    final magnitudeMax = observed + 2;

    String? json;
    try {
      json = await Sleuth.exportCaptureJson(
        scenario: scenarioName,
        role: leg,
        magnitudeMin: magnitudeMin,
        magnitudeObserved: observed,
        magnitudeMax: magnitudeMax,
        unit: 'paints',
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterVersion: '3.41.4',
        captureCommand:
            'fvm flutter run --profile -d "iPhone 12" '
            '--dart-define=SLEUTH_CAPTURE_MODE=true',
        // Magnitude is per-1s-window paint count read from the
        // detector's getter — no matching named timeline event the
        // schema can derive from. Empty string skips event-derivation.
        magnitudeSourceEventName: '',
        bracketStableId: 'excessive_repaint',
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
          '[$leg] Paste into Notes / Mail / AirDrop note → send to '
          'Mac. Save as $scenarioName.json under '
          'test/validation/captures/repaint/.',
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
      appBar: AppBar(title: const Text('Repaint capture helper')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'excessive_repaint WARNING tier (>30 paints/sec aggregate '
                'over 1 s VM window). 32 distinct widget classes paint '
                'at controlled rates so per-widget debug gate stays '
                'sub-threshold and emission flows through the VM '
                'aggregate path.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              _LegButton(
                label: 'Below (~16 paints/sec) — passes',
                subtitle:
                    'Sub-threshold; lastObservedPaintCount reflects '
                    'measurement',
                enabled: !_busy,
                onTap: () => _runLeg(_Leg.below),
              ),
              const SizedBox(height: 8),
              _LegButton(
                label: 'At (~32 paints/sec) — warning',
                subtitle: 'In [27, 33] at-band (10% tolerance)',
                enabled: !_busy,
                onTap: () => _runLeg(_Leg.at),
              ),
              const SizedBox(height: 8),
              _LegButton(
                label: 'Above (~64 paints/sec) — warning',
                subtitle: 'Above ceiling 60 (2.0× threshold)',
                enabled: !_busy,
                onTap: () => _runLeg(_Leg.above),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _exportLastLeg,
                icon: const Icon(Icons.save_alt),
                label: const Text('Export last leg'),
              ),
              const SizedBox(height: 16),
              // Workload area — 32 distinct widget types animating at
              // _intervalMs cadence. Mounted only during a leg so paints
              // stop the moment the leg completes.
              if (_legActive)
                _Workload(intervalMs: _intervalMs)
              else
                const SizedBox(height: 64),
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

class _Workload extends StatelessWidget {
  const _Workload({required this.intervalMs});
  final int intervalMs;

  @override
  Widget build(BuildContext context) {
    // Stagger phase by tile index so timers don't all fire in the
    // same frame budget and coalesce into one PAINT event. Tiles
    // staggered across one intervalMs cycle distribute paint
    // requests across multiple frames.
    final stagger = intervalMs ~/ _kTileCount;
    return SizedBox(
      height: 64,
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var i = 0; i < _kTileCount; i++)
            _tile(i, intervalMs: intervalMs, startDelayMs: stagger * i),
        ],
      ),
    );
  }

  Widget _tile(
    int index, {
    required int intervalMs,
    required int startDelayMs,
  }) {
    // Switch is the only Dart-friendly way to map an int to a
    // distinct widget runtime type. Each branch returns a different
    // class, which is the load-bearing constraint (debug per-widget
    // gate keys on widget runtimeType).
    switch (index) {
      case 0:
        return _PT00(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 1:
        return _PT01(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 2:
        return _PT02(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 3:
        return _PT03(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 4:
        return _PT04(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 5:
        return _PT05(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 6:
        return _PT06(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 7:
        return _PT07(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 8:
        return _PT08(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 9:
        return _PT09(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 10:
        return _PT10(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 11:
        return _PT11(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 12:
        return _PT12(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 13:
        return _PT13(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 14:
        return _PT14(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 15:
        return _PT15(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 16:
        return _PT16(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 17:
        return _PT17(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 18:
        return _PT18(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 19:
        return _PT19(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 20:
        return _PT20(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 21:
        return _PT21(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 22:
        return _PT22(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 23:
        return _PT23(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 24:
        return _PT24(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 25:
        return _PT25(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 26:
        return _PT26(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 27:
        return _PT27(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 28:
        return _PT28(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 29:
        return _PT29(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 30:
        return _PT30(intervalMs: intervalMs, startDelayMs: startDelayMs);
      case 31:
        return _PT31(intervalMs: intervalMs, startDelayMs: startDelayMs);
      default:
        throw StateError('out-of-range tile index: $index');
    }
  }
}

abstract class _PaintTileBase extends StatefulWidget {
  const _PaintTileBase({required this.intervalMs, required this.startDelayMs});
  final int intervalMs;
  final int startDelayMs;
}

class _PaintTileBaseState<W extends _PaintTileBase> extends State<W> {
  Timer? _startTimer;
  Timer? _tickTimer;
  int _seed = 0;

  @override
  void initState() {
    super.initState();
    // Stagger initial fire so 32 widgets don't all setState in the
    // same frame budget (which would coalesce into one PAINT event).
    _startTimer = Timer(Duration(milliseconds: widget.startDelayMs), () {
      if (!mounted) return;
      _tick();
      _tickTimer = Timer.periodic(
        Duration(milliseconds: widget.intervalMs),
        (_) => _tick(),
      );
    });
  }

  void _tick() {
    if (!mounted) return;
    setState(() => _seed++);
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(size: const Size(20, 20), painter: _SeedPainter(_seed)),
  );
}

class _SeedPainter extends CustomPainter {
  _SeedPainter(this.seed);
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Color(0xFF000000 | ((seed * 0x010203) & 0xFFFFFF));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_SeedPainter old) => old.seed != seed;
}

// 32 distinct widget runtime types. Each subclass exists solely so
// `runtimeType` differs across instances — the debug per-widget gate
// keys paint counts on `typeName` from `DebugCreator`, so a single
// shared type would aggregate all 32 tiles' paints into one entry
// and trip the per-widget threshold (30/sec) before the VM aggregate
// gate fires.
class _PT00 extends _PaintTileBase {
  const _PT00({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT00> createState() => _PaintTileBaseState<_PT00>();
}

class _PT01 extends _PaintTileBase {
  const _PT01({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT01> createState() => _PaintTileBaseState<_PT01>();
}

class _PT02 extends _PaintTileBase {
  const _PT02({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT02> createState() => _PaintTileBaseState<_PT02>();
}

class _PT03 extends _PaintTileBase {
  const _PT03({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT03> createState() => _PaintTileBaseState<_PT03>();
}

class _PT04 extends _PaintTileBase {
  const _PT04({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT04> createState() => _PaintTileBaseState<_PT04>();
}

class _PT05 extends _PaintTileBase {
  const _PT05({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT05> createState() => _PaintTileBaseState<_PT05>();
}

class _PT06 extends _PaintTileBase {
  const _PT06({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT06> createState() => _PaintTileBaseState<_PT06>();
}

class _PT07 extends _PaintTileBase {
  const _PT07({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT07> createState() => _PaintTileBaseState<_PT07>();
}

class _PT08 extends _PaintTileBase {
  const _PT08({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT08> createState() => _PaintTileBaseState<_PT08>();
}

class _PT09 extends _PaintTileBase {
  const _PT09({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT09> createState() => _PaintTileBaseState<_PT09>();
}

class _PT10 extends _PaintTileBase {
  const _PT10({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT10> createState() => _PaintTileBaseState<_PT10>();
}

class _PT11 extends _PaintTileBase {
  const _PT11({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT11> createState() => _PaintTileBaseState<_PT11>();
}

class _PT12 extends _PaintTileBase {
  const _PT12({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT12> createState() => _PaintTileBaseState<_PT12>();
}

class _PT13 extends _PaintTileBase {
  const _PT13({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT13> createState() => _PaintTileBaseState<_PT13>();
}

class _PT14 extends _PaintTileBase {
  const _PT14({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT14> createState() => _PaintTileBaseState<_PT14>();
}

class _PT15 extends _PaintTileBase {
  const _PT15({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT15> createState() => _PaintTileBaseState<_PT15>();
}

class _PT16 extends _PaintTileBase {
  const _PT16({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT16> createState() => _PaintTileBaseState<_PT16>();
}

class _PT17 extends _PaintTileBase {
  const _PT17({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT17> createState() => _PaintTileBaseState<_PT17>();
}

class _PT18 extends _PaintTileBase {
  const _PT18({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT18> createState() => _PaintTileBaseState<_PT18>();
}

class _PT19 extends _PaintTileBase {
  const _PT19({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT19> createState() => _PaintTileBaseState<_PT19>();
}

class _PT20 extends _PaintTileBase {
  const _PT20({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT20> createState() => _PaintTileBaseState<_PT20>();
}

class _PT21 extends _PaintTileBase {
  const _PT21({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT21> createState() => _PaintTileBaseState<_PT21>();
}

class _PT22 extends _PaintTileBase {
  const _PT22({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT22> createState() => _PaintTileBaseState<_PT22>();
}

class _PT23 extends _PaintTileBase {
  const _PT23({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT23> createState() => _PaintTileBaseState<_PT23>();
}

class _PT24 extends _PaintTileBase {
  const _PT24({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT24> createState() => _PaintTileBaseState<_PT24>();
}

class _PT25 extends _PaintTileBase {
  const _PT25({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT25> createState() => _PaintTileBaseState<_PT25>();
}

class _PT26 extends _PaintTileBase {
  const _PT26({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT26> createState() => _PaintTileBaseState<_PT26>();
}

class _PT27 extends _PaintTileBase {
  const _PT27({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT27> createState() => _PaintTileBaseState<_PT27>();
}

class _PT28 extends _PaintTileBase {
  const _PT28({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT28> createState() => _PaintTileBaseState<_PT28>();
}

class _PT29 extends _PaintTileBase {
  const _PT29({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT29> createState() => _PaintTileBaseState<_PT29>();
}

class _PT30 extends _PaintTileBase {
  const _PT30({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT30> createState() => _PaintTileBaseState<_PT30>();
}

class _PT31 extends _PaintTileBase {
  const _PT31({required super.intervalMs, required super.startDelayMs});
  @override
  State<_PT31> createState() => _PaintTileBaseState<_PT31>();
}
