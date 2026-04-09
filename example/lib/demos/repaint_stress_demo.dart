import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 14: Repaint Stress
// Triggers: Repaint detector (VM+ or debug callbacks)
// ─────────────────────────────────────────

/// Demonstrates continuous repainting without a `RepaintBoundary`. In the
/// bad path, every frame's repaint propagates up to the ancestor layer,
/// dragging siblings into the repaint. The fix wraps the animated
/// `CustomPaint` in a `RepaintBoundary` so the repaint is isolated to a
/// single layer.
class RepaintStressDemo extends StatefulWidget {
  const RepaintStressDemo({super.key});

  @override
  State<RepaintStressDemo> createState() => _RepaintStressDemoState();
}

class _RepaintStressDemoState extends State<RepaintStressDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// Counts paint calls in the current body via the painter's paint()
  /// method. The chip is reset on toggle so the number reflects only
  /// the currently-visible subtree.
  final ValueNotifier<int> _paintCount = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
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
    return DemoScaffold(
      title: 'Repaint Stress',
      description:
          '❌ BAD: A CustomPaint drawing concentric circles at 60 Hz with no '
          'RepaintBoundary. Every frame\'s repaint propagates up to the root '
          'layer, dragging siblings into the repaint too.\n'
          '✅ FIX: Wrap the CustomPaint in a RepaintBoundary so the repaint '
          'is isolated to a single layer.\n\n'
          '▶ Flip to Fixed Pattern — the painter still animates, but the '
          'repaint cost is contained.',
      metricsBar: MetricsBar(
        chips: [
          ValueListenableBuilder<int>(
            valueListenable: _paintCount,
            builder: (_, v, _) => MetricChip(label: 'Paints', value: '$v'),
          ),
        ],
      ),
      onToggle: _handleToggle,
      body: _BadRepaintBody(controller: _controller, paintCount: _paintCount),
      fixedBody: _FixedRepaintBody(
        controller: _controller,
        paintCount: _paintCount,
      ),
    );
  }
}

class _BadRepaintBody extends StatelessWidget {
  const _BadRepaintBody({required this.controller, required this.paintCount});

  final AnimationController controller;
  final ValueNotifier<int> paintCount;

  @override
  Widget build(BuildContext context) {
    // ❌ No RepaintBoundary — repaints propagate up through the Column.
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Sibling text — repaints every frame because no RepaintBoundary',
            style: TextStyle(fontSize: 13, color: Colors.red),
          ),
        ),
        Expanded(
          child: CustomPaint(
            painter: _WavePainter(controller, paintCount),
            child: Center(
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) => Text(
                  '${(controller.value * 360).toInt()}°',
                  style: Theme.of(context).textTheme.displayMedium,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FixedRepaintBody extends StatelessWidget {
  const _FixedRepaintBody({required this.controller, required this.paintCount});

  final AnimationController controller;
  final ValueNotifier<int> paintCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Sibling text — stable, never repainted',
            style: TextStyle(fontSize: 13, color: Colors.green),
          ),
        ),
        // ✅ RepaintBoundary isolates the painter's repaint to its own layer.
        Expanded(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _WavePainter(controller, paintCount),
              child: Center(
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) => Text(
                    '${(controller.value * 360).toInt()}°',
                    style: Theme.of(context).textTheme.displayMedium,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.animation, this.paintCount) : super(repaint: animation);

  final Animation<double> animation;
  final ValueNotifier<int> paintCount;

  @override
  void paint(Canvas canvas, Size size) {
    // Count paints via a microtask — bumping a ValueNotifier directly
    // during paint would reentrantly schedule a frame.
    Future.microtask(() => paintCount.value += 1);

    final progress = animation.value;
    final paint = Paint()
      ..color =
          Color.lerp(
            const Color(0xFF3B82F6),
            const Color(0xFFEF4444),
            progress,
          ) ??
          const Color(0xFF3B82F6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    for (var i = 0; i < 8; i++) {
      final radius = 30.0 + i * 20 + progress * 40;
      canvas.drawCircle(Offset(size.width / 2, size.height / 2), radius, paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}
