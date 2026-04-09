import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 2: Non-Lazy ListView
// Triggers: ListView detector (>20 children)
// ─────────────────────────────────────────

/// Demonstrates the cost of building an entire list up-front versus using
/// `ListView.builder`, which lazy-builds only what's on screen.
class NonLazyListDemo extends StatefulWidget {
  const NonLazyListDemo({super.key});

  @override
  State<NonLazyListDemo> createState() => _NonLazyListDemoState();
}

class _NonLazyListDemoState extends State<NonLazyListDemo> {
  // 60 children — must exceed ListviewDetector's default `childThreshold`
  // of 50 (the detector fires on `childCount > childThreshold`, i.e.
  // ≥ 51). 40 children would be silently below the threshold even though
  // the pattern is still bad in spirit.
  static const _itemCount = 60;

  /// How many item widgets were constructed during the current build.
  /// Reset to 0 at the start of each build and incremented in every
  /// itemBuilder / List.generate callback.
  final ValueNotifier<int> _builtCount = ValueNotifier<int>(0);

  @override
  void dispose() {
    _builtCount.dispose();
    super.dispose();
  }

  /// Reset the counter whenever the user toggles between bad/fixed.
  /// Toggle is dispatched from a button press, so we're already outside
  /// the build phase and can write to the notifier directly.
  void _handleToggle(bool isFixed) {
    _builtCount.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Non-Lazy ListView',
      description:
          '❌ BAD: SingleChildScrollView + Column with $_itemCount children — '
          'every ListTile is constructed up front.\n'
          '✅ FIX: Use ListView.builder + itemExtent so only visible items are '
          'built, and the framework can short-circuit layout.\n\n'
          '▶ Scroll the list and watch the "Built" counter. The bad path '
          'builds all $_itemCount items immediately; the fixed path builds '
          'only what fits on screen (usually ~10–15).',
      metricsBar: MetricsBar(
        chips: [
          ValueListenableBuilder<int>(
            valueListenable: _builtCount,
            builder: (_, count, _) =>
                MetricChip(label: 'Built', value: '$count', unit: ' widgets'),
          ),
          const MetricChip(label: 'Total', value: '$_itemCount'),
        ],
      ),
      onToggle: _handleToggle,
      body: _BadBody(itemCount: _itemCount, builtCount: _builtCount),
      fixedBody: _FixedBody(itemCount: _itemCount, builtCount: _builtCount),
    );
  }
}

/// ❌ Non-lazy: all items built eagerly in a single pass.
class _BadBody extends StatelessWidget {
  const _BadBody({required this.itemCount, required this.builtCount});

  final int itemCount;
  final ValueNotifier<int> builtCount;

  @override
  Widget build(BuildContext context) {
    // Count every ListTile constructed during this build. The reset is
    // published via a post-frame callback so we never mutate the
    // notifier during the current build phase — doing so would mark an
    // ancestor ValueListenableBuilder dirty mid-frame.
    var running = 0;
    final children = List.generate(itemCount, (i) {
      running++;
      return ListTile(
        leading: CircleAvatar(child: Text('$i')),
        title: Text('Non-lazy item $i'),
        subtitle: const Text('Built eagerly at startup'),
      );
    });
    SchedulerBinding.instance.addPostFrameCallback((_) {
      builtCount.value = running;
    });
    return SingleChildScrollView(child: Column(children: children));
  }
}

/// ✅ Lazy: ListView.builder with itemExtent — only visible items built,
/// and each one reports into the shared `builtCount` notifier.
class _FixedBody extends StatelessWidget {
  const _FixedBody({required this.itemCount, required this.builtCount});

  final int itemCount;
  final ValueNotifier<int> builtCount;

  @override
  Widget build(BuildContext context) {
    // Every itemBuilder call below bumps `running`; we publish the final
    // count after the frame commits so we never touch the notifier
    // during the build phase.
    var running = 0;
    return ListView.builder(
      itemExtent: 72,
      itemCount: itemCount,
      itemBuilder: (_, i) {
        running++;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          builtCount.value = running;
        });
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.green.shade100,
            child: Text('$i'),
          ),
          title: Text('Lazy item $i'),
          subtitle: const Text('Built only when visible'),
        );
      },
    );
  }
}
