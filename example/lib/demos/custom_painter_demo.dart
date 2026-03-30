import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 4: Always-Repaint CustomPainter
// Triggers: CustomPainter detector
// ─────────────────────────────────────────
class CustomPainterDemo extends StatefulWidget {
  const CustomPainterDemo({super.key});

  @override
  State<CustomPainterDemo> createState() => _CustomPainterDemoState();
}

class _CustomPainterDemoState extends State<CustomPainterDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Always-Repaint Painter')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: shouldRepaint always returns true\n'
              '✅ FIX: Compare old vs new painter properties',
              style: TextStyle(fontSize: 13),
            ),
          ),
          // ❌ Animating with always-true shouldRepaint
          Expanded(
            child: AnimatedBuilder(
              animation: _anim,
              builder: (_, _) => CustomPaint(
                painter: _BadCirclePainter(_anim.value),
                size: Size.infinite,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BadCirclePainter extends CustomPainter {
  _BadCirclePainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Color.lerp(Colors.blue, Colors.purple, progress)!
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      50 + progress * 80,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true; // ❌ Always
}
