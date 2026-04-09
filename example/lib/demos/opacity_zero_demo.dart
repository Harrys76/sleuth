import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 10: Opacity Zero
// Triggers: Opacity detector
// ─────────────────────────────────────────

/// Demonstrates the cost of `Opacity(opacity: 0.0)` — the subtree still
/// lays out, paints, and hit-tests. The fix uses `Visibility` with
/// `visible: false`, which skips layout, paint, and hit-testing entirely.
class OpacityZeroDemo extends StatelessWidget {
  const OpacityZeroDemo({super.key});

  static const _itemCount = 10;

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Opacity Zero',
      description:
          '❌ BAD: Opacity(opacity: 0.0) makes a subtree invisible but does '
          'not remove it from layout, paint, or hit-testing. The $_itemCount '
          'items below are still constructed and measured on every build.\n'
          '✅ FIX: Use Visibility(visible: false, maintainState: false) or '
          'conditionally omit the subtree entirely.\n\n'
          '▶ Flip to Fixed Pattern — the invisible subtree is gone from the '
          'widget tree, so the Opacity detector goes quiet.',
      body: Column(
        children: [
          const SizedBox(height: 16),
          // ❌ Invisible but still occupying layout + hit testing
          Opacity(
            opacity: 0.0,
            child: Column(
              children: [
                for (var i = 0; i < _itemCount; i++)
                  ListTile(
                    title: Text('Invisible item $i'),
                    subtitle: const Text('Still laid out and painted'),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '⬆ $_itemCount invisible items above (you can\'t see them but '
              'they still exist and are flagged by the detector).',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      fixedBody: Column(
        children: [
          const SizedBox(height: 16),
          // ✅ Subtree is skipped entirely — not laid out, painted, or hit-tested
          const Visibility(
            visible: false,
            maintainState: false,
            child: SizedBox.shrink(),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '⬆ Nothing here. The hidden subtree is skipped by '
              'Visibility(visible: false) so the detector finds no '
              'Opacity(0.0) to flag.',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
