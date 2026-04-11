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
  // 40 items with a compact 24pt itemExtent ensures that >20 keys are
  // actually *realized* by ListView.builder on every viewport — even a
  // small phone with the DemoScaffold banner fully expanded.
  //
  // The detector counts only realized children of the scrollable, so
  // item height, cacheExtent, AND DemoScaffold chrome height all affect
  // the count. DemoScaffold chrome (toggle + expanded banner) consumes
  // ~220-300dp depending on description length. On the smallest phone
  // (~481dp body after AppBar) that leaves ~180-260dp for the ListView.
  // At scroll position 0 only trailing cache (250dp) contributes, so:
  //   realized ≈ (viewport + 250) / itemExtent
  //   worst case: (180 + 250) / 24 = 17.9 → 17 items (below threshold)
  //   typical:    (260 + 250) / 24 = 21.3 → 21 items (above threshold)
  // With 2×cache (mid-scroll): (260 + 500) / 24 = 31.7 → capped at 40.
  // 24dp is the sweet spot: fires reliably on all phones ≥ iPhone SE
  // with the banner expanded, and always fires with banner collapsed.
  static const _itemCount = 40;
  static const double _itemExtent = 24.0;

  // ❌ 40 GlobalKeys allocated once in state — exceeds the >20 threshold
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
          '❌ BAD: $_itemCount GlobalKeys on list items (threshold: 20). '
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

/// Compact row widget sized to a 24pt itemExtent so >20 items can be
/// realized inside the default ListView cacheExtent window on any phone,
/// even with the DemoScaffold banner fully expanded.
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
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
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
