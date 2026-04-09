import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 11: AnimatedBuilder without child
// Triggers: AnimatedBuilder detector
// ─────────────────────────────────────────

/// Demonstrates an `AnimatedBuilder` whose builder constructs the entire
/// subtree on every animation tick. The fix passes the static subtree as
/// the `child` parameter so Flutter can reuse it across frames.
class AnimatedBuilderDemo extends StatefulWidget {
  const AnimatedBuilderDemo({super.key});

  @override
  State<AnimatedBuilderDemo> createState() => _AnimatedBuilderDemoState();
}

class _AnimatedBuilderDemoState extends State<AnimatedBuilderDemo>
    with SingleTickerProviderStateMixin {
  /// How many progress rows live in the dashboard. The bad-path subtree
  /// must contain more than `AnimatedBuilderDetector.minSubtreeSize`
  /// (default 50) descendant widgets — otherwise the detector treats
  /// the no-`child` AnimatedBuilder as cheap and stays silent. 12 rows
  /// × ~6 widgets per row + the surrounding Column/Text/SizedBox is
  /// well above the threshold.
  static const _barCount = 12;

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
    return DemoScaffold(
      title: 'AnimatedBuilder No Child',
      description:
          '❌ BAD: AnimatedBuilder without a child parameter. The builder '
          'rebuilds all $_barCount progress rows on every animation tick, '
          'even though only the numeric value at the top changes. The '
          'detector flags this because the rebuilt subtree exceeds 50 '
          'descendants — the threshold above which a missing `child` is '
          'considered expensive.\n'
          '✅ FIX: Extract the static subtree (the bars) and pass it as the '
          'child parameter. The builder only reads the value and the static '
          'child is reused across frames.\n\n'
          '▶ Flip to Fixed Pattern — the AnimatedBuilder detector should go '
          'quiet because the subtree is no longer rebuilt per tick.',
      body: SingleChildScrollView(
        // ❌ No child parameter — every tick rebuilds the entire
        //    $_barCount-row dashboard subtree (label + bar + percentage),
        //    not just the numbers that actually change.
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Value: ${_controller.value.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < _barCount; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 60,
                          child: Text(
                            'Metric ${i + 1}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LinearProgressIndicator(
                            value: (_controller.value + i * 0.1) % 1.0,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 40,
                          child: Text(
                            '${(((_controller.value + i * 0.1) % 1.0) * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      fixedBody: Center(
        // ✅ Static scaffolding passed as `child` — reused across frames.
        child: AnimatedBuilder(
          animation: _controller,
          child: const _StaticBarColumn(),
          builder: (context, child) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Value: ${_controller.value.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                child!,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Static subtree extracted into `AnimatedBuilder.child` so it is not
/// rebuilt on every tick. Note: these bars are intentionally *static* in
/// the fixed version — the point is that they do not need to rebuild on
/// every animation frame.
class _StaticBarColumn extends StatelessWidget {
  const _StaticBarColumn();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _AnimatedBuilderDemoState._barCount; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text(
                    'Metric ${i + 1}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: LinearProgressIndicator(value: (i + 1) / 12)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 40,
                  child: Text(
                    '${(((i + 1) / 12) * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 12),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
