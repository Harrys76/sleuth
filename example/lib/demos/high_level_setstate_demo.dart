import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 1: High-Level setState
// Triggers: Rebuild, SetStateScope
// ─────────────────────────────────────────
class HighLevelSetStateDemo extends StatefulWidget {
  const HighLevelSetStateDemo({super.key});

  @override
  State<HighLevelSetStateDemo> createState() => _HighLevelSetStateDemoState();
}

class _HighLevelSetStateDemoState extends State<HighLevelSetStateDemo> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('High-Level setState')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Counter: $_counter',
              style: Theme.of(context).textTheme.displaySmall,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '❌ BAD: setState at top level rebuilds 50+ widgets below.\n'
              '✅ FIX: Move counter into a small sub-widget.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          // ❌ 50 widgets that all rebuild on setState
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: 50,
              itemBuilder: (_, i) => Container(
                decoration: BoxDecoration(
                  color: Colors.primaries[i % Colors.primaries.length]
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text('${_counter + i}'),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => setState(() => _counter++),
        icon: const Icon(Icons.add),
        label: const Text('setState (top)'),
      ),
    );
  }
}
