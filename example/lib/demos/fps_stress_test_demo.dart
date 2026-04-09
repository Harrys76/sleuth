import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../demo_scaffold.dart';

// ───────────────────────────────────────────────
// FPS Stress Test — targets ~20 FPS via heavy work every frame
// ───────────────────────────────────────────────

/// Pathologically slow frame pipeline: 50k sort + triple BackdropFilter
/// blur every frame. FPS drops to ~20 or lower. The fix reduces the per
/// frame work and caps FPS at the displayed rate.
class FpsStressTestDemo extends StatefulWidget {
  const FpsStressTestDemo({super.key});

  @override
  State<FpsStressTestDemo> createState() => _FpsStressTestDemoState();
}

class _FpsStressTestDemoState extends State<FpsStressTestDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// Rolling FPS estimate. Updated from a FrameTiming callback.
  final ValueNotifier<int> _fps = ValueNotifier<int>(0);

  /// FrameTiming callback installed for the lifetime of this demo.
  /// Stored so we can remove it in dispose().
  TimingsCallback? _timingsCallback;

  final List<FrameTiming> _recentFrames = [];

  /// Snapshot of the prior FrameTiming observer registration, so we do
  /// not stomp on a developer's global configuration.
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _timingsCallback = _onTimings;
    SchedulerBinding.instance.addTimingsCallback(_timingsCallback!);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!mounted) return;
    // Keep at most the last ~60 frames (≈1s at 60fps).
    _recentFrames.addAll(timings);
    while (_recentFrames.length > 60) {
      _recentFrames.removeAt(0);
    }
    if (_recentFrames.length < 2) return;

    // Estimate FPS from the wall clock between first and last frame.
    final first = _recentFrames.first.timestampInMicroseconds(
      FramePhase.vsyncStart,
    );
    final last = _recentFrames.last.timestampInMicroseconds(
      FramePhase.vsyncStart,
    );
    final spanMicros = last - first;
    if (spanMicros <= 0) return;
    final frames = _recentFrames.length - 1;
    final fps = (frames * 1000000 / spanMicros).round();
    _fps.value = fps.clamp(0, 120);
  }

  @override
  void dispose() {
    if (_timingsCallback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_timingsCallback!);
      _timingsCallback = null;
    }
    _controller.dispose();
    _fps.dispose();
    super.dispose();
  }

  /// Burn ~30-40ms of main-thread time per call.
  List<double> _heavyWork(double seed) {
    final rng = Random(seed.hashCode);
    final data = List.generate(50000, (_) => rng.nextDouble());
    data.sort();
    var sum = 0.0;
    for (var i = 0; i < data.length; i++) {
      sum += sin(data[i] * seed * pi);
    }
    data[0] = sum;
    return data;
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'FPS Stress Test',
      description:
          '❌ BAD: Sorting 50k items + triple BackdropFilter blur every '
          'frame. FPS should drop to ~20 or lower — watch the FPS chip.\n'
          '✅ FIX: Pre-compute once in initState, drop the BackdropFilter '
          'stack, and use const widgets. FPS climbs back to 60.\n\n'
          '▶ Flip to Fixed Pattern and watch the FPS chip climb from '
          '~20 back to 60.',
      metricsBar: MetricsBar(
        chips: [
          ValueListenableBuilder<int>(
            valueListenable: _fps,
            builder: (_, v, _) => MetricChip(label: 'FPS', value: '~$v'),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final data = _heavyWork(_controller.value);

          return Stack(
            children: [
              GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: 200,
                itemBuilder: (context, index) {
                  final value = data[index % data.length];
                  final hue = (value * 360) % 360;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: HSVColor.fromAHSV(1, hue, 0.7, 0.9).toColor(),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 6,
                          offset: Offset(
                            sin(_controller.value * pi * 2 + index) * 3,
                            cos(_controller.value * pi * 2 + index) * 3,
                          ),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        (value * 100).toStringAsFixed(1),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  );
                },
              ),
              for (var i = 0; i < 3; i++)
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: 2.0 + _controller.value * 3,
                      sigmaY: 2.0 + _controller.value * 3,
                    ),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.05),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      fixedBody: const _FixedFpsBody(),
    );
  }
}

/// Fixed body: a static grid, no heavy per-frame work, no BackdropFilter.
/// Target FPS is a smooth 60.
class _FixedFpsBody extends StatelessWidget {
  const _FixedFpsBody();

  static final List<double> _data = List.generate(
    200,
    (i) => (sin(i * 0.3) + 1) / 2,
  );

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: 200,
      itemBuilder: (context, index) {
        final value = _data[index];
        final hue = (value * 360) % 360;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: HSVColor.fromAHSV(1, hue, 0.5, 0.85).toColor(),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              (value * 100).toStringAsFixed(1),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
        );
      },
    );
  }
}
