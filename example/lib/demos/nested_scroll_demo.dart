import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 7: Nested Scroll
// Triggers: NestedScroll detector
// ─────────────────────────────────────────
class NestedScrollDemo extends StatelessWidget {
  const NestedScrollDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nested Scroll')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: SingleChildScrollView > Column with 30 children\n'
              '   inside another ScrollView\n'
              '✅ FIX: Use CustomScrollView with slivers',
              style: TextStyle(fontSize: 13),
            ),
          ),
          // ❌ Nested scrolling
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  30,
                  (i) => Container(
                    height: 60,
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.indigo.withValues(alpha: 0.05 + i * 0.02),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text('Nested scroll item $i'),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
