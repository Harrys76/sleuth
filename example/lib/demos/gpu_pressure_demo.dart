import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 22: GPU Pressure
// Triggers: GpuPressure detector (structural nodes + per-frame raster
// timing; the VM timeline confirms when connected)
// ─────────────────────────────────────────

/// Demonstrates GPU pressure from stacking expensive rendering operations
/// (BackdropFilter, ClipPath, ColorFiltered, Opacity) on deep subtrees,
/// plus an animated blur layer that keeps the raster thread busy every
/// frame while the UI thread stays nearly idle.
class GpuPressureDemo extends StatefulWidget {
  const GpuPressureDemo({super.key});

  @override
  State<GpuPressureDemo> createState() => _GpuPressureDemoState();
}

class _GpuPressureDemoState extends State<GpuPressureDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  bool _animating = true;
  bool _showingFixed = false;

  @override
  void initState() {
    super.initState();
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (_animating && !_showingFixed) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  void _setAnimating(bool value) {
    setState(() => _animating = value);
    _syncAnimation();
  }

  void _handleToggle(bool isFixed) {
    _showingFixed = isFixed;
    _syncAnimation();
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'GPU Pressure',
      description:
          '❌ BAD: Stacking expensive GPU operations (blur, clip, color filter, '
          'opacity) on deep subtrees overwhelms the rasterizer.\n'
          '✅ FIX: Reduce blur radius, simplify clipping, avoid stacking '
          'multiple GPU-heavy layers, prefer Clip.hardEdge over antiAliasWithSaveLayer.\n\n'
          '▶ The animated blur at the top repaints every frame without '
          'rebuilding any widget: raster time climbs while UI time stays '
          'low, so `raster_dominance` appears within a few seconds. Use the '
          'switch to pause it.\n'
          '▶ Scroll through the cards — each one stacks BackdropFilter (σ=15), '
          'ClipPath, ColorFiltered, and Opacity on a subtree with >5 '
          'descendants. They raise the structural `expensive_gpu_nodes` '
          'card. The per-frame repaint can also show on the repaint '
          'counters.\n'
          '▶ Flip to Fixed Pattern — the animation stops and the cards '
          'render with a single hard-edge clip and no stacked filters. '
          'Detector should go quiet.',
      onToggle: _handleToggle,
      body: Column(
        children: [
          SwitchListTile(
            title: const Text('Animated blur'),
            subtitle: Text(_animating ? 'Running' : 'Paused'),
            value: _animating,
            onChanged: _setAnimating,
          ),
          // Flex split instead of a fixed height so the page fits short
          // screens while the blur keeps a large share of the frame.
          Expanded(
            flex: 2,
            child: SizedBox(
              width: double.infinity,
              child: RepaintBoundary(
                child: CustomPaint(painter: _BlurOrbsPainter(_controller)),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: 10,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _HeavyGpuCard(index: index),
              ),
            ),
          ),
        ],
      ),
      fixedBody: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 10,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _LightGpuCard(index: index),
        ),
      ),
    );
  }
}

/// Six large circles under `MaskFilter.blur(normal, 40)`, moved by
/// [animation]. The painter repaints through its `repaint` listenable, so
/// no widget rebuilds per frame (`rebuild_activity` stays quiet) while
/// every frame pays for six large blurs on the raster thread.
///
/// Six circles at sigma 40 is the starting point. The cost is tuned on a
/// device so that at least 3 frames per second rasterize for over 8 ms
/// at more than twice their UI time, which is what `raster_dominance`
/// needs; on a faster GPU raise [_orbCount] or [_sigma].
class _BlurOrbsPainter extends CustomPainter {
  _BlurOrbsPainter(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  static const int _orbCount = 6;
  static const double _sigma = 40;

  static const _colors = [
    Color(0xFFE53935),
    Color(0xFF8E24AA),
    Color(0xFF1E88E5),
    Color(0xFF00ACC1),
    Color(0xFF43A047),
    Color(0xFFFDD835),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value * 2 * math.pi;
    final radius = size.shortestSide * 0.45;
    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _sigma);
    for (var i = 0; i < _orbCount; i++) {
      final phase = t + i * 2 * math.pi / _orbCount;
      final center = Offset(
        size.width / 2 + math.cos(phase) * size.width * 0.35,
        size.height / 2 + math.sin(phase * 2) * size.height * 0.3,
      );
      paint.color = _colors[i % _colors.length].withValues(alpha: 0.7);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BlurOrbsPainter oldDelegate) => false;
}

class _HeavyGpuCard extends StatelessWidget {
  const _HeavyGpuCard({required this.index});

  final int index;

  static const _cardColors = [
    Colors.blue,
    Colors.purple,
    Colors.teal,
    Colors.indigo,
    Colors.pink,
    Colors.orange,
    Colors.cyan,
    Colors.deepPurple,
    Colors.green,
    Colors.red,
  ];

  @override
  Widget build(BuildContext context) {
    final baseColor = _cardColors[index % _cardColors.length];

    // ❌ Layer 1: ClipPath with antiAliasWithSaveLayer (expensive)
    return ClipPath(
      clipper: _DiagonalClipper(),
      clipBehavior: Clip.antiAliasWithSaveLayer,
      // ❌ Layer 2: Opacity at fractional value (triggers saveLayer)
      child: Opacity(
        opacity: 0.85,
        child: SizedBox(
          height: 180,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Gradient background for BackdropFilter to blur
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [baseColor.shade300, baseColor.shade700],
                  ),
                ),
                child: const SizedBox.expand(),
              ),
              // ❌ Layer 3: BackdropFilter with σ=15 (offscreen buffer)
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                // ❌ Layer 4: ColorFiltered (color matrix computation)
                child: ColorFiltered(
                  colorFilter: ColorFilter.mode(
                    baseColor.shade900.withValues(alpha: 0.3),
                    BlendMode.overlay,
                  ),
                  // 6+ descendants to exceed subtreeSize > 5 threshold
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.layers,
                              color: Colors.white.withValues(alpha: 0.9),
                              size: 28,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Heavy Card #${index + 1}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '4 GPU layers stacked: ClipPath + Opacity + '
                          'BackdropFilter + ColorFiltered',
                          style: TextStyle(fontSize: 13, color: Colors.white70),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            _EffectChip(label: 'Clip', color: baseColor),
                            const SizedBox(width: 6),
                            _EffectChip(label: 'Blur σ15', color: baseColor),
                            const SizedBox(width: 6),
                            _EffectChip(label: 'Filter', color: baseColor),
                            const SizedBox(width: 6),
                            _EffectChip(label: 'Opacity', color: baseColor),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fixed-pattern card: same visual structure, single hard-edge clip, no
/// BackdropFilter, no fractional Opacity, no ColorFiltered. The GPU
/// pressure detector should not flag this subtree.
class _LightGpuCard extends StatelessWidget {
  const _LightGpuCard({required this.index});

  final int index;

  static const _cardColors = [
    Colors.blue,
    Colors.purple,
    Colors.teal,
    Colors.indigo,
    Colors.pink,
    Colors.orange,
    Colors.cyan,
    Colors.deepPurple,
    Colors.green,
    Colors.red,
  ];

  @override
  Widget build(BuildContext context) {
    final baseColor = _cardColors[index % _cardColors.length];

    // ✅ Single hard-edge clip (no antiAliasWithSaveLayer)
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.hardEdge,
      child: DecoratedBox(
        // ✅ Solid-color gradient background — no blur layer
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [baseColor.shade600, baseColor.shade800],
          ),
        ),
        child: SizedBox(
          height: 180,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    const Icon(Icons.layers, color: Colors.white, size: 28),
                    const SizedBox(width: 12),
                    Text(
                      'Light Card #${index + 1}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Single clip, solid gradient, no stacked filters.',
                  style: TextStyle(fontSize: 13, color: Colors.white70),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _EffectChip(label: 'HardEdge', color: baseColor),
                    const SizedBox(width: 6),
                    _EffectChip(label: 'Solid BG', color: baseColor),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EffectChip extends StatelessWidget {
  const _EffectChip({required this.label, required this.color});

  final String label;
  final MaterialColor color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.shade100.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// Diagonal clip that cuts the top-right corner.
class _DiagonalClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path()
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height - 24)
      ..lineTo(size.width - 48, size.height)
      ..lineTo(0, size.height)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
