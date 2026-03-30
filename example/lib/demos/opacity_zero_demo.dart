import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 10: Opacity Zero
// Triggers: Opacity detector
// ─────────────────────────────────────────
class OpacityZeroDemo extends StatelessWidget {
  const OpacityZeroDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Opacity Zero')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: Opacity(opacity: 0.0) still lays out, paints, and hit-tests.\n'
              '✅ FIX: Use Visibility or conditional rendering to skip the subtree.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          // ❌ Invisible but still occupying layout + hit testing
          Opacity(
            opacity: 0.0,
            child: Column(
              children: List.generate(
                10,
                (i) => ListTile(
                  title: Text('Invisible item $i'),
                  subtitle: const Text('Still laid out and painted!'),
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '⬆ 10 invisible items above (you can\'t see them but they exist)',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
