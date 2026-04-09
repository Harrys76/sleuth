import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 8: Heavy Compute on Main Thread
// Triggers: HeavyCompute, FrameTiming
// ─────────────────────────────────────────

/// Demonstrates running a long CPU-bound loop on the main isolate versus
/// offloading it to a background isolate via `Isolate.run`. The bad path
/// freezes the UI — the spinner stutters and taps are dropped. The fix
/// keeps the UI responsive throughout.
class HeavyComputeDemo extends StatefulWidget {
  const HeavyComputeDemo({super.key});

  @override
  State<HeavyComputeDemo> createState() => _HeavyComputeDemoState();
}

class _HeavyComputeDemoState extends State<HeavyComputeDemo> {
  static const _iterations = 5000000;

  String _result = 'Tap the button to compute';
  bool _computing = false;

  /// Flag set by the bad-path button tap handler and consumed on the
  /// next [build]. When true, the heavy sin/cos loop runs synchronously
  /// *inside* the build scope so it lands in the VM timeline as a long
  /// Widget.build event — which is what [HeavyComputeDetector] observes.
  ///
  /// Without this indirection, running the compute directly in the tap
  /// handler (the "obvious" implementation) would only trip
  /// FrameTimingDetector via severe frame jank. HeavyComputeDetector
  /// would stay silent because it filters on `TimelinePhase.build`
  /// events — the `BuildOwner.buildScope` wrapper in Flutter's
  /// `drawFrame`. Gesture-handler work runs in the pointer dispatch
  /// phase, not inside buildScope, so it never reaches the detector.
  bool _pendingMainIsolateCompute = false;

  /// Wall-clock duration of the last compute, in milliseconds.
  /// Displayed in the metrics bar.
  final ValueNotifier<int> _lastComputeMs = ValueNotifier<int>(0);

  void _requestMainIsolateCompute() {
    setState(() {
      _computing = true;
      _pendingMainIsolateCompute = true;
      _result = 'Computing on main isolate…';
    });
  }

  Future<void> _runOnBackgroundIsolate() async {
    setState(() {
      _computing = true;
      _result = 'Computing on background isolate…';
    });
    final stopwatch = Stopwatch()..start();

    // ✅ FIX: Isolate.run offloads to a worker isolate, main stays responsive.
    final sum = await Isolate.run(() => _heavyCompute(_iterations));

    stopwatch.stop();
    if (!mounted) return;
    _lastComputeMs.value = stopwatch.elapsedMilliseconds;
    setState(() {
      _computing = false;
      _result =
          'Background-isolate result: ${sum.toStringAsFixed(2)}\n'
          '(UI stayed at 60 FPS throughout.)';
    });
  }

  @override
  void dispose() {
    _lastComputeMs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ❌ BAD path: if the user tapped "Run on Main Isolate", execute the
    //    sin/cos loop synchronously *inside* this build() call so the
    //    enclosing BUILD timeline event (emitted by Flutter's
    //    `BuildOwner.buildScope`) captures the multi-second duration.
    //    HeavyComputeDetector filters on TimelinePhase.build events, so
    //    this is the only way for the detector to see the work.
    //
    //    The flag is reset BEFORE running the compute so the post-frame
    //    setState below doesn't re-enter the hot path on the next build.
    if (_pendingMainIsolateCompute) {
      _pendingMainIsolateCompute = false;
      final stopwatch = Stopwatch()..start();
      final sum = _heavyCompute(_iterations);
      stopwatch.stop();
      final elapsedMs = stopwatch.elapsedMilliseconds;
      final resultText =
          'Main-isolate result: ${sum.toStringAsFixed(2)}\n'
          '(UI was frozen for ${elapsedMs}ms during build!)';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _lastComputeMs.value = elapsedMs;
        setState(() {
          _computing = false;
          _result = resultText;
        });
      });
    }

    return DemoScaffold(
      title: 'Heavy Compute',
      description:
          '❌ BAD: $_iterations iterations of sin/cos math run inside '
          'build() on the main isolate. The enclosing BUILD timeline '
          'event blocks for seconds — the UI freezes and the spinner '
          'stops mid-animation.\n'
          '✅ FIX: Use Isolate.run (or compute()) to offload the work to '
          'a background isolate. The main thread stays free to render.\n\n'
          '▶ Tap "Run Compute". Watch the spinner above the button: in '
          'the bad path it stops mid-animation; in the fixed path it '
          'spins smoothly through the computation.',
      metricsBar: MetricsBar(
        chips: [
          ValueListenableBuilder<int>(
            valueListenable: _lastComputeMs,
            builder: (_, ms, _) =>
                MetricChip(label: 'Last compute', value: '$ms', unit: ' ms'),
          ),
          const MetricChip(label: 'Iterations', value: '5M'),
        ],
      ),
      body: _ComputeControls(
        label: 'Bad: main-isolate compute inside build()',
        buttonLabel: 'Run on Main Isolate',
        computing: _computing,
        result: _result,
        onPressed: _computing ? null : _requestMainIsolateCompute,
      ),
      fixedBody: _ComputeControls(
        label: 'Fixed: background isolate via Isolate.run()',
        buttonLabel: 'Run on Background Isolate',
        computing: _computing,
        result: _result,
        onPressed: _computing ? null : _runOnBackgroundIsolate,
      ),
    );
  }
}

double _heavyCompute(int iterations) {
  final random = Random(42);
  var sum = 0.0;
  for (var i = 0; i < iterations; i++) {
    sum += random.nextDouble() * random.nextDouble();
  }
  return sum;
}

class _ComputeControls extends StatelessWidget {
  const _ComputeControls({
    required this.label,
    required this.buttonLabel,
    required this.computing,
    required this.result,
    required this.onPressed,
  });

  final String label;
  final String buttonLabel;
  final bool computing;
  final String result;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // The spinner is a truth-teller: if the UI thread stalls, it
            // stops spinning. Users can see the freeze in real time.
            SizedBox(
              height: 48,
              child: computing
                  ? const CircularProgressIndicator()
                  : const Icon(Icons.check_circle_outline, size: 40),
            ),
            const SizedBox(height: 16),
            Text(
              result,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onPressed,
              icon: const Icon(Icons.speed),
              label: Text(buttonLabel),
            ),
          ],
        ),
      ),
    );
  }
}
