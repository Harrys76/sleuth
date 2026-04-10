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
  // 30 items with a compact 40pt itemExtent ensures that >20 keys are
  // actually *realized* by ListView.builder on every viewport — even a
  // small phone. The detector counts only realized children of the
  // scrollable, so item height and cacheExtent interact with the count:
  // with default 72pt Card+ListTile items and a ~481pt phone body, only
  // ~13 items realize (viewport + 2×250pt cacheExtent) which is below
  // the strict >20 threshold. 40pt tall items at 30 count realize ~24
  // items on the smallest phone — safely above threshold.
  static const _itemCount = 30;
  static const double _itemExtent = 40.0;

  // ❌ 30 GlobalKeys allocated once in state — exceeds the >20 threshold
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
        padding: const EdgeInsets.all(4),
        itemExtent: _itemExtent,
        itemCount: _itemCount,
        itemBuilder: (_, i) => CompactRow(
          // ❌ GlobalKey per item — the whole point of this demo
          key: _badKeys[i],
          label: 'Item with GlobalKey #$i',
          icon: Icons.key,
          color: Colors.blue.shade400,
        ),
      ),
      fixedBody: ListView.builder(
        padding: const EdgeInsets.all(4),
        itemExtent: _itemExtent,
        itemCount: _itemCount,
        itemBuilder: (_, i) => CompactRow(
          // ✅ ValueKey — cheap, unique enough for list identity
          key: ValueKey<int>(i),
          label: 'Item with ValueKey #$i',
          icon: Icons.check_circle_outline,
          color: Colors.green.shade400,
        ),
      ),
    );
  }
}

/// Compact row widget sized to a 40pt itemExtent so >20 items can be
/// realized inside the default ListView cacheExtent window on any phone.
///
/// The class intentionally has a public (non-underscore) name because
/// [GlobalKeyDetector] filters out widget types whose name starts with
/// `_`, assuming they are framework or anonymous helpers. An underscore
/// name here would cause the detector to silently skip every key in the
/// bad path and the demo would never fire.
class CompactRow extends StatelessWidget {
  const CompactRow({
    required this.label,
    required this.icon,
    required this.color,
    super.key,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
