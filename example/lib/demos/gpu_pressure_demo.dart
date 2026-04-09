import 'dart:ui';

import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 22: GPU Pressure
// Triggers: GpuPressure detector (hybrid: structural + VM raster timing)
// ─────────────────────────────────────────

/// Demonstrates GPU pressure from stacking expensive rendering operations
/// (BackdropFilter, ClipPath, ColorFiltered, Opacity) on deep subtrees.
class GpuPressureDemo extends StatelessWidget {
  const GpuPressureDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'GPU Pressure',
      description:
          '❌ BAD: Stacking expensive GPU operations (blur, clip, color filter, '
          'opacity) on deep subtrees overwhelms the rasterizer.\n'
          '✅ FIX: Reduce blur radius, simplify clipping, avoid stacking '
          'multiple GPU-heavy layers, prefer Clip.hardEdge over antiAliasWithSaveLayer.\n\n'
          '▶ Scroll through the cards — each one stacks BackdropFilter (σ=15), '
          'ClipPath, ColorFiltered, and Opacity on a subtree with >5 descendants. '
          'Sleuth flags expensive render nodes and raster dominance.',
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 10,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _HeavyGpuCard(index: index),
        ),
      ),
    );
  }
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
