import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 2: Non-Lazy ListView
// Triggers: ListView detector (>20 children)
// ─────────────────────────────────────────
class NonLazyListDemo extends StatelessWidget {
  const NonLazyListDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Non-Lazy ListView')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: SingleChildScrollView + Column with 40 children\n'
              '✅ FIX: Use ListView.builder for lazy rendering',
              style: TextStyle(fontSize: 13),
            ),
          ),
          // ❌ Non-lazy: all 40 items built immediately
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  40,
                  (i) => ListTile(
                    leading: CircleAvatar(child: Text('$i')),
                    title: Text('Non-lazy item $i'),
                    subtitle: const Text('This was built eagerly at startup'),
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
