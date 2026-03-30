import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 14: Repaint Stress
// Triggers: Repaint detector (VM+ or debug callbacks)
// ─────────────────────────────────────────
class RepaintStressDemo extends StatefulWidget {
  const RepaintStressDemo({super.key});

  @override
  State<RepaintStressDemo> createState() => _RepaintStressDemoState();
}

class _RepaintStressDemoState extends State<RepaintStressDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Repaint Stress')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: Continuous repainting without RepaintBoundary.\n'
              '✅ FIX: Wrap animated content in RepaintBoundary.\n'
              '(Detected in VM+ or debug callback mode)',
              style: TextStyle(fontSize: 13),
            ),
          ),
          // ❌ No RepaintBoundary — repaints propagate up the tree
          Expanded(
            child: AnimatedBuilder(
              animation: _controller,
              child: null, // intentionally no child
              builder: (context, _) {
                return CustomPaint(
                  painter: _WavePainter(_controller.value),
                  child: Center(
                    child: Text(
                      '${(_controller.value * 360).toInt()}°',
                      style: Theme.of(context).textTheme.displayMedium,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
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

    for (int i = 0; i < 8; i++) {
      final radius = 30.0 + i * 20 + progress * 40;
      canvas.drawCircle(Offset(size.width / 2, size.height / 2), radius, paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => true; // ❌ Always repaints
}
