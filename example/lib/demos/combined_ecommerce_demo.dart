import 'dart:math';

import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ───────────────────────────────────────────────
// Combined Demo 3: E-Commerce Product Page
// ───────────────────────────────────────────────
// Triggers: ImageMemory, AnimatedBuilder, LayoutBottleneck, ListView, GlobalKey,
//           Opacity
// Realistic product detail page that stacks 6 anti-patterns commonly
// found in shopping apps.

/// Demonstrates a realistic e-commerce product page that combines 6
/// anti-patterns in one screen. The fixed version applies every fix.
class CombinedEcommerceDemo extends StatefulWidget {
  const CombinedEcommerceDemo({super.key});

  @override
  State<CombinedEcommerceDemo> createState() => _CombinedEcommerceDemoState();
}

class _CombinedEcommerceDemoState extends State<CombinedEcommerceDemo>
    with SingleTickerProviderStateMixin {
  static const _heroCount = 6;
  static const _reviewCount = 200;
  static const _sizes = ['XS', 'S', 'M', 'L', 'XL', 'XXL'];

  late final AnimationController _controller;

  /// ✅ Fixed-path GlobalKeys — stored as final State fields so identity
  /// is stable across rebuilds.
  final GlobalKey _heroKey = GlobalKey();
  final GlobalKey _descKey = GlobalKey();
  final GlobalKey _reviewsKey = GlobalKey();
  final GlobalKey _relatedKey = GlobalKey();

  int _badSelectedSize = 2;
  final ValueNotifier<int> _fixedSelectedSize = ValueNotifier<int>(2);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    _fixedSelectedSize.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'E-Commerce (Combined)',
      description:
          '❌ BAD: $_heroCount hero images decoded at full resolution '
          '(800×800) trigger imageMemory; AnimatedBuilder without `child` '
          'rebuilds the price tag subtree per tick; IntrinsicHeight wraps '
          'the size chip row (two-pass layout); a non-lazy '
          '$_reviewCount-review ListView is built eagerly inside the '
          'scroll view; 6 GlobalKeys are created fresh in build(); and '
          'an Opacity(0.0) loading spinner covers the Add to Cart button.\n'
          '✅ FIX: cacheWidth: 520 on every hero, AnimatedBuilder with a '
          'static child, a fixed-height Row for sizes, ListView.builder '
          '(shrinkWrap + NeverScrollableScrollPhysics), GlobalKey as '
          'final State fields, and Visibility instead of Opacity(0.0).\n\n'
          '▶ Tap a size chip to update. In the bad path the whole page '
          'rebuilds; in the fixed path only the chip row updates.',
      // ❌ The outer AnimatedBuilder listens to the same controller the
      //    inner price-tag AnimatedBuilder listens to, forcing the whole
      //    _BadProductPage to rebuild on every animation tick — which in
      //    turn recreates all 6 in-build GlobalKeys every frame. This is
      //    what lets the GlobalKey recreation detector actually see the
      //    anti-pattern between scans without requiring user interaction.
      body: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) => _BadProductPage(
          controller: _controller,
          selectedSize: _badSelectedSize,
          onSelectSize: (i) {
            setState(() => _badSelectedSize = i);
          },
        ),
      ),
      fixedBody: _FixedProductPage(
        controller: _controller,
        selectedSize: _fixedSelectedSize,
        heroKey: _heroKey,
        descKey: _descKey,
        reviewsKey: _reviewsKey,
        relatedKey: _relatedKey,
      ),
    );
  }
}

// ─── Bad path ────────────────────────────────────────────────

class _BadProductPage extends StatelessWidget {
  const _BadProductPage({
    required this.controller,
    required this.selectedSize,
    required this.onSelectSize,
  });

  final AnimationController controller;
  final int selectedSize;
  final ValueChanged<int> onSelectSize;

  @override
  Widget build(BuildContext context) {
    // ❌ 6 GlobalKeys created fresh in build() — flags the
    //    GlobalKey recreation detector. Must exceed the detector's
    //    recreationThreshold of 5. Keeping the count asymmetric with
    //    the fixed path's 4 stable keys also prevents a spurious
    //    1-scan fire right after toggling Bad ↔ Fixed: the detector
    //    uses min(newKeys, goneKeys), which resolves to 4 < 5 on toggle.
    final heroKey = GlobalKey();
    final descKey = GlobalKey();
    final priceKey = GlobalKey();
    final sizesKey = GlobalKey();
    final reviewsKey = GlobalKey();
    final relatedKey = GlobalKey();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Hero image carousel ─────────────────────────────
          // ❌ 6 network images, no cacheWidth — 800×800 each. Using a
          //    Row (not a horizontal ListView) so every image is in the
          //    element tree at scan time — a horizontal ListView with
          //    the default 250px cacheExtent would only realise 2–4
          //    items on a phone, keeping count below the imageMemory
          //    critical threshold of 6.
          KeyedSubtree(
            key: heroKey,
            child: SizedBox(
              height: 280,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    for (
                      var i = 0;
                      i < _CombinedEcommerceDemoState._heroCount;
                      i++
                    )
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            'https://picsum.photos/seed/hero$i/800/800',
                            width: 260,
                            height: 260,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              width: 260,
                              height: 260,
                              color: Colors.grey.shade300,
                              child: const Icon(Icons.image, size: 60),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // ── Title + rating ──────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              key: descKey,
              children: [
                const Text(
                  'Vintage Crewneck Sweatshirt',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Row(
                  children: [
                    Icon(Icons.star, color: Colors.amber, size: 18),
                    Icon(Icons.star, color: Colors.amber, size: 18),
                    Icon(Icons.star, color: Colors.amber, size: 18),
                    Icon(Icons.star, color: Colors.amber, size: 18),
                    Icon(Icons.star_half, color: Colors.amber, size: 18),
                    SizedBox(width: 6),
                    Text(
                      '4.5 (238 reviews)',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── Animated price tag ──────────────────────────────
          // ❌ AnimatedBuilder without child — the price tag subtree
          //    is rebuilt on every animation tick.
          SizedBox(
            key: priceKey,
            height: 70,
            child: Center(
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) {
                  return Transform.rotate(
                    angle: sin(controller.value * 2 * pi) * 0.06,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.deepOrange.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.deepOrange, width: 2),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '\$49.99',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.deepOrange,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            '\$89.99',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                              decoration: TextDecoration.lineThrough,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // ── Size selector ────────────────────────────────────
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Size',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
          // ❌ IntrinsicHeight forces two-pass layout on the chip row.
          Padding(
            key: sizesKey,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  for (
                    var i = 0;
                    i < _CombinedEcommerceDemoState._sizes.length;
                    i++
                  )
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _SizeChip(
                          label: _CombinedEcommerceDemoState._sizes[i],
                          selected: i == selectedSize,
                          onTap: () => onSelectSize(i),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Add to cart with hidden loading spinner ─────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.shopping_cart),
                    label: const Text('Add to Cart'),
                  ),
                ),
                // ❌ Opacity(0.0) — still laid out and painted.
                const Opacity(
                  opacity: 0.0,
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Reviews',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
          ),

          // ── Non-lazy review list ────────────────────────────
          // ❌ 200 reviews built eagerly via List.generate inside a
          //    ListView(shrinkWrap: true) — all children realize up-front.
          ListView(
            key: reviewsKey,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: List.generate(
              _CombinedEcommerceDemoState._reviewCount,
              (i) => _ReviewTile(index: i),
            ),
          ),

          const SizedBox(height: 12),
          // Related placeholder — just anchors the 6th GlobalKey.
          SizedBox(key: relatedKey, height: 1),
        ],
      ),
    );
  }
}

// ─── Fixed path ──────────────────────────────────────────────

class _FixedProductPage extends StatelessWidget {
  const _FixedProductPage({
    required this.controller,
    required this.selectedSize,
    required this.heroKey,
    required this.descKey,
    required this.reviewsKey,
    required this.relatedKey,
  });

  final AnimationController controller;
  final ValueNotifier<int> selectedSize;
  final GlobalKey heroKey;
  final GlobalKey descKey;
  final GlobalKey reviewsKey;
  final GlobalKey relatedKey;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ✅ Hero carousel — same layout as the bad path, but every
          //    image has cacheWidth: 520 (2× display size). All 6 are
          //    still in the tree; the fix is that each one decodes at
          //    520×520 instead of 800×800, cutting memory per image
          //    by ~60%.
          KeyedSubtree(
            key: heroKey,
            child: SizedBox(
              height: 280,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    for (
                      var i = 0;
                      i < _CombinedEcommerceDemoState._heroCount;
                      i++
                    )
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            'https://picsum.photos/seed/hero$i/800/800',
                            width: 260,
                            height: 260,
                            fit: BoxFit.cover,
                            cacheWidth: 520,
                            cacheHeight: 520,
                            errorBuilder: (_, _, _) => Container(
                              width: 260,
                              height: 260,
                              color: Colors.grey.shade300,
                              child: const Icon(Icons.image, size: 60),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              key: descKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Vintage Crewneck Sweatshirt',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.star, color: Colors.amber, size: 18),
                    Icon(Icons.star, color: Colors.amber, size: 18),
                    Icon(Icons.star, color: Colors.amber, size: 18),
                    Icon(Icons.star, color: Colors.amber, size: 18),
                    Icon(Icons.star_half, color: Colors.amber, size: 18),
                    SizedBox(width: 6),
                    Text(
                      '4.5 (238 reviews)',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ✅ AnimatedBuilder with a static child — the price tag
          //    subtree is built once and reused across ticks.
          SizedBox(
            height: 70,
            child: Center(
              child: AnimatedBuilder(
                animation: controller,
                child: const _StaticPriceTag(),
                builder: (context, child) {
                  return Transform.rotate(
                    angle: sin(controller.value * 2 * pi) * 0.06,
                    child: child,
                  );
                },
              ),
            ),
          ),

          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Size',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
          // ✅ Fixed-height chip row (no IntrinsicHeight). Only the
          //    chip row rebuilds via ValueListenableBuilder.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              height: 44,
              child: ValueListenableBuilder<int>(
                valueListenable: selectedSize,
                builder: (_, current, _) => Row(
                  children: [
                    for (
                      var i = 0;
                      i < _CombinedEcommerceDemoState._sizes.length;
                      i++
                    )
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: _SizeChip(
                            label: _CombinedEcommerceDemoState._sizes[i],
                            selected: i == current,
                            onTap: () => selectedSize.value = i,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ✅ Visibility (visible: false) — the spinner is omitted
          //    from the tree when hidden.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.shopping_cart),
                    label: const Text('Add to Cart'),
                  ),
                ),
                const Visibility(
                  visible: false,
                  maintainState: false,
                  maintainAnimation: false,
                  maintainSize: false,
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Reviews',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
          ),

          // ✅ Bounded-height ListView.builder. shrinkWrap + a parent
          //    SingleChildScrollView would give the list infinite
          //    main-axis constraints and force it to realise every
          //    item — which would silently keep the non-lazy
          //    anti-pattern. Wrapping in a fixed-height SizedBox
          //    bounds the viewport so only the visible tiles are built.
          SizedBox(
            height: 480,
            child: ListView.builder(
              key: reviewsKey,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _CombinedEcommerceDemoState._reviewCount,
              itemBuilder: (_, i) => _ReviewTile(index: i),
            ),
          ),

          const SizedBox(height: 12),
          SizedBox(key: relatedKey, height: 1),
        ],
      ),
    );
  }
}

// ─── Shared pieces ───────────────────────────────────────────

class _StaticPriceTag extends StatelessWidget {
  const _StaticPriceTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.deepOrange.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.deepOrange, width: 2),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '\$49.99',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.deepOrange,
            ),
          ),
          SizedBox(width: 8),
          Text(
            '\$89.99',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey,
              decoration: TextDecoration.lineThrough,
            ),
          ),
        ],
      ),
    );
  }
}

class _SizeChip extends StatelessWidget {
  const _SizeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 44,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final rng = Random(index);
    final stars = 3 + rng.nextInt(3);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          backgroundColor:
              Colors.primaries[index % Colors.primaries.length].shade100,
          child: Text('${index + 1}'),
        ),
        title: Row(
          children: [
            for (var i = 0; i < 5; i++)
              Icon(
                i < stars ? Icons.star : Icons.star_border,
                size: 14,
                color: Colors.amber,
              ),
          ],
        ),
        subtitle: Text(
          'Review #${index + 1} — lorem ipsum dolor sit amet, '
          'consectetur adipiscing elit.',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
