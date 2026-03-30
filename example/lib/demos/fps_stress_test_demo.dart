import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

// ───────────────────────────────────────────────
// FPS Stress Test — targets ~20 FPS via heavy work every frame
// ───────────────────────────────────────────────
class FpsStressTestDemo extends StatefulWidget {
  const FpsStressTestDemo({super.key});

  @override
  State<FpsStressTestDemo> createState() => _FpsStressTestDemoState();
}

class _FpsStressTestDemoState extends State<FpsStressTestDemo>
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

  /// Burn ~30-40ms of main-thread time per call.
  List<double> _heavyWork(double seed) {
    final rng = Random(seed.hashCode);
    final data = List.generate(50000, (_) => rng.nextDouble());
    data.sort();
    var sum = 0.0;
    for (var i = 0; i < data.length; i++) {
      sum += sin(data[i] * seed * pi);
    }
    data[0] = sum; // prevent dead-code elimination
    return data;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FPS Stress Test')),
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
                  return Container(
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
                    alignment: Alignment.center,
                    child: Text(
                      (value * 100).toStringAsFixed(1),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
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
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.05),
                    ),
                  ),
                ),
              Positioned(
                bottom: 32,
                left: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Sorting 50k items + triple BackdropFilter blur every frame.\n'
                    'FPS should drop to ~20 or lower.',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
