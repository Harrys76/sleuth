import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// Live audio-style waveform visualizer. A 60 Hz CustomPaint scrolls a
// 256-sample sine + noise trace, while header labels (BPM, Peak)
// rebuild every frame. Without a `RepaintBoundary` the painter's
// repaints propagate up through the Column and drag the labels and
// sibling chrome into the same repaint, tripping `excessive_repaint*`
// and `repaint_debug_<TypeName>` families. Wrapping the painter in a
// `RepaintBoundary` quiets all paths.

class RepaintStressDemo extends StatefulWidget {
  const RepaintStressDemo({super.key});

  @override
  State<RepaintStressDemo> createState() => _RepaintStressDemoState();
}

class _RepaintStressDemoState extends State<RepaintStressDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final ValueNotifier<int> _paintCount = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pause the ticker entirely when Reduce Motion is on. Without this
    // the controller keeps spinning at 60 Hz even though no listener
    // pulls from it — wasted CPU in the very demo measuring repaint
    // cost.
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _paintCount.dispose();
    super.dispose();
  }

  void _handleToggle(bool isFixed) {
    _paintCount.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return DemoScaffold(
      title: 'Live Waveform',
      description:
          '❌ BAD: A 60 Hz CustomPaint scrolling oscilloscope plus per-frame '
          'header labels (BPM, Peak) — no RepaintBoundary. Every frame\'s '
          'repaint propagates through the Column and drags the labels into '
          'the repaint. Repaint detector flags `excessive_repaint*` and '
          'per-widget `repaint_debug_<TypeName>` families.\n'
          '✅ FIX: Wrap the painter in a RepaintBoundary so the repaint '
          'isolates to its own layer.\n\n'
          '▶ Open Bad path → wait 1–2 s for the issue cards. Toggle Fixed '
          '→ cards disappear within 2–3 s.',
      metricsBar: MetricsBar(
        chips: [
          // The Paints notifier ticks once per frame. Without an own
          // boundary, this rebuild propagates outward and contributes
          // to the very repaint metric the demo is measuring — even on
          // the Fixed path, which would otherwise be quiet.
          RepaintBoundary(
            child: ValueListenableBuilder<int>(
              valueListenable: _paintCount,
              builder: (_, v, _) => MetricChip(label: 'Paints', value: '$v'),
            ),
          ),
          MetricChip(label: 'Mode', value: reduceMotion ? 'Static' : '60 Hz'),
        ],
      ),
      onToggle: _handleToggle,
      body: _WaveformBody(
        controller: _controller,
        paintCount: _paintCount,
        wrapInBoundary: false,
        reduceMotion: reduceMotion,
      ),
      fixedBody: _WaveformBody(
        controller: _controller,
        paintCount: _paintCount,
        wrapInBoundary: true,
        reduceMotion: reduceMotion,
      ),
    );
  }
}

class _WaveformBody extends StatelessWidget {
  const _WaveformBody({
    required this.controller,
    required this.paintCount,
    required this.wrapInBoundary,
    required this.reduceMotion,
  });

  final AnimationController controller;
  final ValueNotifier<int> paintCount;
  final bool wrapInBoundary;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final waveform = CustomPaint(
      painter: _WaveformPainter(
        animation: controller,
        paintCount: paintCount,
        animate: !reduceMotion,
      ),
    );
    return Column(
      children: [
        if (reduceMotion)
          const _ReduceMotionBanner()
        else
          _HeaderLabels(controller: controller),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Semantics(
              label: 'Audio waveform visualizer',
              container: true,
              liveRegion: true,
              child: wrapInBoundary
                  ? RepaintBoundary(child: waveform)
                  : waveform,
            ),
          ),
        ),
      ],
    );
  }
}

class _HeaderLabels extends StatelessWidget {
  const _HeaderLabels({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final t = controller.value;
          final bpm = 110 + (math.sin(t * 2 * math.pi) * 14).round();
          final peak = (0.5 + math.sin(t * 4 * math.pi) * 0.5).abs();
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _StatColumn(label: 'BPM', value: '$bpm', color: scheme.primary),
              _StatColumn(
                label: 'Peak',
                value: peak.toStringAsFixed(2),
                color: scheme.tertiary,
              ),
              _StatColumn(
                label: 'Phase',
                value: '${(t * 360).toInt()}°',
                color: scheme.secondary,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  const _StatColumn({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _ReduceMotionBanner extends StatelessWidget {
  const _ReduceMotionBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.accessibility_new, size: 18, color: scheme.onSurface),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Animation paused (Reduce Motion enabled). '
                  'Repaint detector will not fire while paused.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.animation,
    required this.paintCount,
    required this.animate,
  }) : super(repaint: animate ? animation : null);

  final Animation<double> animation;
  final ValueNotifier<int> paintCount;
  final bool animate;

  // 256-point scrolling buffer of sine + noise. The noise term keeps the
  // line visually live even after the sine wraps.
  static const _samples = 256;
  static final _noise = List<double>.generate(
    _samples,
    (i) => (math.Random(i).nextDouble() - 0.5) * 0.1,
  );

  @override
  void paint(Canvas canvas, Size size) {
    Future.microtask(() => paintCount.value += 1);

    final phase = animation.value * 2 * math.pi;
    final paint = Paint()
      ..color = const Color(0xFF3B82F6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final mid = size.height / 2;
    final amp = size.height * 0.35;
    final dx = size.width / (_samples - 1);

    final path = Path()..moveTo(0, mid);
    for (var i = 0; i < _samples; i++) {
      final t = i / _samples;
      final y = mid + math.sin(t * 4 * math.pi + phase) * amp + _noise[i] * amp;
      path.lineTo(i * dx, y);
    }
    canvas.drawPath(path, paint);

    final centerline = Paint()
      ..color = const Color(0x33888888)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), centerline);
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => old.animate != animate;
}
