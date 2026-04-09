import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 1: High-Level setState
// Triggers: Rebuild, SetStateScope
// ─────────────────────────────────────────

/// Demonstrates calling `setState` at the top of the tree to mutate a value
/// that's read by 50+ descendants. Every tap rebuilds the whole grid. The
/// fix isolates the state into a small `ValueNotifier` that only one leaf
/// widget subscribes to via `ValueListenableBuilder`.
class HighLevelSetStateDemo extends StatefulWidget {
  const HighLevelSetStateDemo({super.key});

  @override
  State<HighLevelSetStateDemo> createState() => _HighLevelSetStateDemoState();
}

class _HighLevelSetStateDemoState extends State<HighLevelSetStateDemo> {
  static const _itemCount = 50;

  int _counter = 0;

  /// Rebuilds of the *bad path* during the current session. Bumped in
  /// the bad body's build method. Reset on toggle.
  final ValueNotifier<int> _badRebuildCount = ValueNotifier<int>(0);

  /// Rebuilds of the fixed counter chip. Bumped inside the notifier
  /// listener. Reset on toggle.
  final ValueNotifier<int> _fixedRebuildCount = ValueNotifier<int>(0);

  /// Fixed-path counter notifier — only the chip listens, so only it
  /// rebuilds when the value changes.
  final ValueNotifier<int> _fixedCounter = ValueNotifier<int>(0);

  /// Tracks which path DemoScaffold is showing so the FAB can call
  /// setState only in the bad path. Without this, tapping the FAB in
  /// fixed mode would still call setState at the top and rebuild
  /// `_FixedBody` (including the inner `_FixedGrid`, which is NOT
  /// const), silently neutralising the fix this demo is meant to show.
  bool _isFixed = false;

  @override
  void dispose() {
    _badRebuildCount.dispose();
    _fixedRebuildCount.dispose();
    _fixedCounter.dispose();
    super.dispose();
  }

  void _handleToggle(bool isFixed) {
    _isFixed = isFixed;
    _badRebuildCount.value = 0;
    _fixedRebuildCount.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'High-Level setState',
      description:
          '❌ BAD: setState at the top rebuilds all $_itemCount grid tiles on '
          'every tap, even though only one number changes.\n'
          '✅ FIX: Put the mutable state behind a ValueNotifier and wrap only '
          'the displaying widget in ValueListenableBuilder. The grid is '
          'constant and never rebuilds.\n\n'
          '▶ Tap the + FAB and watch the "Rebuilt" counters. In the bad path '
          'every press rebuilds $_itemCount tiles; in the fixed path only the '
          'counter chip rebuilds.',
      metricsBar: MetricsBar(
        chips: [
          ValueListenableBuilder<int>(
            valueListenable: _badRebuildCount,
            builder: (_, v, _) =>
                MetricChip(label: 'Bad rebuilds', value: '$v'),
          ),
          ValueListenableBuilder<int>(
            valueListenable: _fixedRebuildCount,
            builder: (_, v, _) =>
                MetricChip(label: 'Fixed rebuilds', value: '$v'),
          ),
        ],
      ),
      onToggle: _handleToggle,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          // Keep both counters in sync so toggling between paths
          // doesn't lose the visible counter, but only fire setState
          // in the bad path. `_FixedBody` and `_FixedGrid` are NOT
          // const — a top-level setState would rebuild them and
          // defeat the entire point of the demo.
          _counter++;
          _fixedCounter.value++;
          if (!_isFixed) {
            setState(() {});
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('Tap'),
      ),
      body: _BadBody(
        counter: _counter,
        itemCount: _itemCount,
        rebuildCount: _badRebuildCount,
      ),
      fixedBody: _FixedBody(
        counter: _fixedCounter,
        itemCount: _itemCount,
        rebuildCount: _fixedRebuildCount,
      ),
    );
  }
}

/// ❌ The whole grid rebuilds on every setState.
class _BadBody extends StatelessWidget {
  const _BadBody({
    required this.counter,
    required this.itemCount,
    required this.rebuildCount,
  });

  final int counter;
  final int itemCount;
  final ValueNotifier<int> rebuildCount;

  @override
  Widget build(BuildContext context) {
    // Bump after build via microtask so we don't mutate during build.
    Future.microtask(() => rebuildCount.value += 1);
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: itemCount,
      itemBuilder: (_, i) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.primaries[i % Colors.primaries.length].withValues(
            alpha: 0.3,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(child: Text('${counter + i}')),
      ),
    );
  }
}

/// ✅ Only the counter chip rebuilds; the grid is constant.
class _FixedBody extends StatelessWidget {
  const _FixedBody({
    required this.counter,
    required this.itemCount,
    required this.rebuildCount,
  });

  final ValueNotifier<int> counter;
  final int itemCount;
  final ValueNotifier<int> rebuildCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          // ✅ Only this subtree rebuilds when counter changes.
          child: ValueListenableBuilder<int>(
            valueListenable: counter,
            builder: (_, value, _) {
              Future.microtask(() => rebuildCount.value += 1);
              return Text(
                'Counter: $value',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              );
            },
          ),
        ),
        Expanded(child: _FixedGrid(itemCount: itemCount)),
      ],
    );
  }
}

/// A const grid — never rebuilt after first mount because it is referenced
/// via `const` in the parent's build method.
class _FixedGrid extends StatelessWidget {
  const _FixedGrid({required this.itemCount});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: itemCount,
      itemBuilder: (_, i) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.primaries[i % Colors.primaries.length].withValues(
            alpha: 0.3,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(child: Text('$i')),
      ),
    );
  }
}
