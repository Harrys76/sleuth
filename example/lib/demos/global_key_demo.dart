import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 6: GlobalKey Overuse
// Triggers: GlobalKey detector (>10 keys)
// ─────────────────────────────────────────

/// Demonstrates excessive `GlobalKey` usage on list items where a `ValueKey`
/// or no key at all would suffice. GlobalKeys force the framework to
/// maintain an app-wide registry and make element tree reparenting expensive.
class GlobalKeyDemo extends StatefulWidget {
  const GlobalKeyDemo({super.key});

  @override
  State<GlobalKeyDemo> createState() => _GlobalKeyDemoState();
}

class _GlobalKeyDemoState extends State<GlobalKeyDemo> {
  static const _itemCount = 25;

  // ❌ 25 GlobalKeys allocated once in state — exceeds the >20 threshold
  // (GlobalKeyDetector default). They live on the State object (not
  // rebuilt on every build), which is already the recommended pattern
  // even when GlobalKeys *are* justified. The detector counts keys
  // attached to children of a ListView/GridView/PageView, so the
  // ListView.builder below is essential — moving these into a plain
  // Column would silence the detector.
  final List<GlobalKey> _badKeys = List.generate(
    _itemCount,
    (_) => GlobalKey(),
  );

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'GlobalKey Overuse',
      description:
          '❌ BAD: $_itemCount GlobalKeys on list items (threshold is 20). '
          'GlobalKeys maintain an app-wide registry and make tree reparenting '
          'expensive. They also block common optimisations like list item '
          'recycling.\n'
          '✅ FIX: Use ValueKey(id) for identity, or omit the key entirely '
          'when the framework\'s default identity logic is enough.\n\n'
          '▶ Flip to Fixed Pattern — the list now uses ValueKey(i), the '
          'detector goes quiet, and list reordering/recycling is free.',
      body: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _itemCount,
        itemBuilder: (_, i) => Card(
          // ❌ GlobalKey per item
          key: _badKeys[i],
          child: ListTile(
            title: Text('Item with GlobalKey #$i'),
            leading: Icon(Icons.key, color: Colors.blue.shade400),
          ),
        ),
      ),
      fixedBody: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _itemCount,
        itemBuilder: (_, i) => Card(
          // ✅ ValueKey — cheap, unique enough for list identity
          key: ValueKey<int>(i),
          child: ListTile(
            title: Text('Item with ValueKey #$i'),
            leading: Icon(
              Icons.check_circle_outline,
              color: Colors.green.shade400,
            ),
          ),
        ),
      ),
    );
  }
}
