import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 12: Shallow Rebuild Risk
// Triggers: ShallowRebuildRisk detector
// ─────────────────────────────────────────

/// Demonstrates a `StatefulWidget` that sits high in the tree and calls
/// `setState` to update a small piece of state. Because the setState is
/// at the top, every descendant rebuilds. The fix pushes the state down
/// into a tiny child widget.
class ShallowRebuildRiskDemo extends StatefulWidget {
  const ShallowRebuildRiskDemo({super.key});

  @override
  State<ShallowRebuildRiskDemo> createState() => _ShallowRebuildRiskDemoState();
}

class _ShallowRebuildRiskDemoState extends State<ShallowRebuildRiskDemo> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Shallow Rebuild Risk',
      description:
          '❌ BAD: A StatefulWidget near the root uses setState to update a '
          'counter. Because the State is shallow, every descendant in the '
          'list rebuilds on each tick.\n'
          '✅ FIX: Extract the counter into a small leaf widget (_CounterChip) '
          'so only that widget rebuilds. The list stays constant.\n\n'
          '▶ Tap the + FAB. In the fixed pattern, only the chip at the top '
          'rebuilds — the list is const and skipped.',
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter++),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
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
      fixedBody: Column(
        children: [
          // ✅ The chip is the only thing that rebuilds.
          Padding(
            padding: const EdgeInsets.all(24),
            child: _CounterChip(counter: _counter),
          ),
          // ✅ Extracted into its own constant subtree — no rebuild on setState.
          const Expanded(child: _StaticRowList()),
        ],
      ),
    );
  }
}

class _CounterChip extends StatelessWidget {
  const _CounterChip({required this.counter});
  final int counter;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Counter: $counter',
      style: Theme.of(context).textTheme.displaySmall,
    );
  }
}

/// A constant list — not rebuilt when the parent calls setState because
/// it is referenced via `const` from the parent's build method.
class _StaticRowList extends StatelessWidget {
  const _StaticRowList();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: 30,
      itemBuilder: (_, i) => ListTile(
        title: Text('Row $i'),
        leading: Icon(
          Icons.circle_outlined,
          color: Colors.primaries[i % Colors.primaries.length],
        ),
      ),
    );
  }
}
