import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 12: Shallow Rebuild Risk
// Triggers: ShallowRebuildRisk detector
// ─────────────────────────────────────────
class ShallowRebuildRiskDemo extends StatefulWidget {
  const ShallowRebuildRiskDemo({super.key});

  @override
  State<ShallowRebuildRiskDemo> createState() => _ShallowRebuildRiskDemoState();
}

class _ShallowRebuildRiskDemoState extends State<ShallowRebuildRiskDemo> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    // ❌ This StatefulWidget is at depth ≤3 and rebuilds frequently
    return Scaffold(
      appBar: AppBar(title: const Text('Shallow Rebuild Risk')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: StatefulWidget near root with frequent setState.\n'
              '✅ FIX: Push setState down to a small child widget.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Counter: $_counter',
              style: Theme.of(context).textTheme.displaySmall,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: 30,
              itemBuilder: (_, i) => ListTile(
                title: Text('Row $i — rebuild #$_counter'),
                leading: Icon(
                  Icons.circle,
                  color: Colors.primaries[i % Colors.primaries.length],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter++),
        child: const Icon(Icons.add),
      ),
    );
  }
}
