import 'dart:math';

import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 8: Heavy Compute on Main Thread
// Triggers: HeavyCompute, FrameTiming
// ─────────────────────────────────────────
class HeavyComputeDemo extends StatefulWidget {
  const HeavyComputeDemo({super.key});

  @override
  State<HeavyComputeDemo> createState() => _HeavyComputeDemoState();
}

class _HeavyComputeDemoState extends State<HeavyComputeDemo> {
  String _result = 'Tap the button to compute on main thread';
  bool _computing = false;

  void _heavyCompute() {
    setState(() {
      _computing = true;
      _result = 'Computing...';
    });

    // ❌ BAD: heavy compute blocks the main isolate
    final random = Random();
    var sum = 0.0;
    for (var i = 0; i < 5000000; i++) {
      sum += random.nextDouble() * random.nextDouble();
    }

    setState(() {
      _computing = false;
      _result =
          'Result: ${sum.toStringAsFixed(2)}\n(UI was frozen during this!)';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Heavy Compute')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                '❌ BAD: 5M iterations on the main isolate\n'
                '✅ FIX: Use Isolate.run() or compute()',
                style: TextStyle(fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Text(
                _result,
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              // Animated spinner to show UI freeze
              if (_computing) const CircularProgressIndicator(),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _computing ? null : _heavyCompute,
                icon: const Icon(Icons.speed),
                label: const Text('Run Heavy Compute'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
