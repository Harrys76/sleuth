import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 23: Missing RepaintBoundary
// Triggers: RepaintBoundary detector (structural)
// ─────────────────────────────────────────

/// Demonstrates expensive GPU widgets (Opacity, CustomPaint) without
/// RepaintBoundary ancestors, causing repaints to propagate up the tree.
///
/// Uses SingleChildScrollView + Column (NOT ListView.builder) because
/// ListView wraps each child in RepaintBoundary by default, which would
/// defeat the purpose of this demo.
class RepaintBoundaryDemo extends StatefulWidget {
  const RepaintBoundaryDemo({super.key});

  @override
  State<RepaintBoundaryDemo> createState() => _RepaintBoundaryDemoState();
}

class _RepaintBoundaryDemoState extends State<RepaintBoundaryDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Missing RepaintBoundary',
      description:
          '❌ BAD: Opacity and CustomPaint widgets without a RepaintBoundary '
          'ancestor — repaints propagate up the entire tree.\n'
          '✅ FIX: Wrap expensive widgets in RepaintBoundary to isolate repaints.\n\n'
          '▶ Scroll through the list — each card uses Opacity(0.7) (a value '
          'the detector considers non-trivial, unlike 0.0 or 1.0). The animated '
          'card continuously repaints, dragging the whole tree with it.\n\n'
          'The detector flags Opacity, ClipPath, BackdropFilter, ShaderMask, '
          'CustomPaint, and ColorFiltered widgets that do not have a '
          'RepaintBoundary ancestor within 5 levels.',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ❌ Animated card — CustomPaint repaints every frame,
            // propagating up without RepaintBoundary
            _AnimatedPulseCard(animation: _controller),
            const SizedBox(height: 12),
            // ❌ 14 static cards with Opacity(0.7) and no RepaintBoundary
            for (var i = 0; i < 14; i++) ...[
              _OpacityCard(index: i),
              if (i < 13) const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

/// Card using Opacity(0.7) without RepaintBoundary ancestor.
/// The detector checks for Opacity between 0.0 exclusive and 1.0 exclusive.
class _OpacityCard extends StatelessWidget {
  const _OpacityCard({required this.index});

  final int index;

  static const _icons = [
    Icons.image,
    Icons.music_note,
    Icons.videocam,
    Icons.article,
    Icons.map,
    Icons.calendar_month,
    Icons.settings,
    Icons.notifications,
    Icons.bookmark,
    Icons.star,
    Icons.cloud,
    Icons.phone,
    Icons.mail,
    Icons.home,
  ];

  @override
  Widget build(BuildContext context) {
    // ❌ Opacity at 0.7 triggers saveLayer — no RepaintBoundary above
    // Fix: RepaintBoundary(child: Opacity(...))
    return Opacity(
      opacity: 0.7,
      // 6+ descendants to satisfy the detector's subtree check
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(_icons[index % _icons.length], size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Unprotected Card #${index + 1}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Opacity(0.7) with no RepaintBoundary ancestor',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.warning_amber, color: Colors.orange, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated card with CustomPaint that repaints every frame.
/// Without RepaintBoundary, this causes the parent scroll view to repaint.
class _AnimatedPulseCard extends StatelessWidget {
  const _AnimatedPulseCard({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    // ❌ CustomPaint repaints every frame — no RepaintBoundary
    // Fix: RepaintBoundary(child: CustomPaint(...))
    return CustomPaint(
      painter: _PulsePainter(animation),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.animation, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Animated Card (repaints every frame)',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'CustomPaint without RepaintBoundary — '
                      'drags entire scroll view into repaint',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.error, color: Colors.red, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red.withValues(alpha: 0.15 + animation.value * 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final center = Offset(size.width / 2, size.height / 2);
    for (var i = 0; i < 3; i++) {
      final radius = 20.0 + i * 15 + animation.value * 10;
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_PulsePainter old) => true; // ❌ Always repaints
}
