import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 11: AnimatedBuilder without child
// Triggers: AnimatedBuilder detector
// ─────────────────────────────────────────
class AnimatedBuilderDemo extends StatefulWidget {
  const AnimatedBuilderDemo({super.key});

  @override
  State<AnimatedBuilderDemo> createState() => _AnimatedBuilderDemoState();
}

class _AnimatedBuilderDemoState extends State<AnimatedBuilderDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
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
      appBar: AppBar(title: const Text('AnimatedBuilder No Child')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: AnimatedBuilder without child rebuilds entire subtree every tick.\n'
              '✅ FIX: Pass static subtree as child parameter.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          // ❌ No child parameter — rebuilds 8 children on every animation tick
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return Column(
                children: [
                  Text(
                    'Value: ${_controller.value.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  ...List.generate(
                    6,
                    (i) => Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 4,
                      ),
                      child: LinearProgressIndicator(
                        value: (_controller.value + i * 0.1) % 1.0,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
