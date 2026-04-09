import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ───────────────────────────────────────────────
// Combined Demo 1: Social Feed
// ───────────────────────────────────────────────
// Triggers: ImageMemory, Opacity, LayoutBottleneck, Rebuild/SetStateScope
// Correlation: Rule 2 (merge rebuild+setState), Rule 4 (escalate image+memory)

/// Demonstrates a realistic social feed with 4+ anti-patterns stacked in
/// one screen. The fixed version applies every corresponding fix.
class CombinedSocialFeedDemo extends StatefulWidget {
  const CombinedSocialFeedDemo({super.key});

  @override
  State<CombinedSocialFeedDemo> createState() => _CombinedSocialFeedDemoState();
}

class _CombinedSocialFeedDemoState extends State<CombinedSocialFeedDemo> {
  static const _cardCount = 8;

  int _likeCount = 0;

  /// Fixed-path like counter isolated into a ValueNotifier so only the
  /// badge rebuilds when tapped — not the whole feed.
  final ValueNotifier<int> _fixedLikeCount = ValueNotifier<int>(0);

  /// Tracks which path DemoScaffold is showing so the Like FAB can
  /// call setState only in the bad path. Without this, the shared
  /// handler would trigger a whole-screen rebuild even while the fixed
  /// path is mounted, hiding the isolation that the fix demonstrates.
  bool _isFixed = false;

  void _handleToggle(bool isFixed) => _isFixed = isFixed;

  @override
  void dispose() {
    _fixedLikeCount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Social Feed (Combined)',
      description:
          '❌ BAD: Top-level setState rebuilds all $_cardCount cards on every '
          'like. Post images are fetched at full 800×600 resolution with '
          'no cacheWidth, IntrinsicHeight forces two-pass layout per row, '
          'and an Opacity(0.0) "load more" banner is still laid out and '
          'painted.\n'
          '✅ FIX: Move the like counter into a ValueNotifier, add cacheWidth '
          'on every network image, drop the IntrinsicHeight, and omit the '
          'invisible banner entirely.\n\n'
          '▶ Tap the Like FAB. In the bad path every card rebuilds; in the '
          'fixed path only the badge updates.',
      onToggle: _handleToggle,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          // Keep both counters in sync so toggling between paths
          // doesn't reset the visible count, but only fire setState
          // in the bad path — otherwise the outer State's wide
          // rebuild would mask the fixed path's isolated update.
          _likeCount++;
          _fixedLikeCount.value++;
          if (!_isFixed) {
            setState(() {});
          }
        },
        icon: const Icon(Icons.favorite),
        label: const Text('Like'),
      ),
      body: _BadFeed(cardCount: _cardCount, likeCount: _likeCount),
      fixedBody: _FixedFeed(cardCount: _cardCount, likeCount: _fixedLikeCount),
    );
  }
}

// ─── Bad path ──────────────────────────────────────────────────

class _BadFeed extends StatelessWidget {
  const _BadFeed({required this.cardCount, required this.likeCount});

  final int cardCount;
  final int likeCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ❌ Opacity(0.0) — still laid out, painted, and hit-tested
        Opacity(
          opacity: 0.0,
          child: Container(
            height: 48,
            alignment: Alignment.center,
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Loading more posts…'),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                for (var i = 0; i < cardCount; i++)
                  _BadFeedCard(index: i, likeCount: likeCount),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BadFeedCard extends StatelessWidget {
  const _BadFeedCard({required this.index, required this.likeCount});

  final int index;
  final int likeCount;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ❌ IntrinsicHeight forces two-pass layout on the header row
          IntrinsicHeight(
            child: Row(
              children: [
                const SizedBox(width: 12),
                // ❌ Avatar decoded at full resolution (no cacheWidth)
                ClipOval(
                  child: Image.network(
                    'https://picsum.photos/seed/avatar$index/200/200',
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 40,
                      height: 40,
                      color: Colors.grey.shade300,
                      child: const Icon(Icons.person, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'User ${index + 1}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${index + 1}h ago',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 3,
                  color: Colors.deepPurple.withValues(alpha: 0.3),
                ),
              ],
            ),
          ),
          // ❌ Post image — no cacheWidth, full 800×600 decoded
          Image.network(
            'https://picsum.photos/seed/post$index/800/600',
            height: 200,
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              height: 200,
              color: Colors.grey.shade200,
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image, size: 40),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$likeCount likes',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Post #${index + 1} — a beautiful scene captured on '
                  'a sunny afternoon. #photography #nature',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Fixed path ────────────────────────────────────────────────

class _FixedFeed extends StatelessWidget {
  const _FixedFeed({required this.cardCount, required this.likeCount});

  final int cardCount;
  final ValueNotifier<int> likeCount;

  @override
  Widget build(BuildContext context) {
    // ✅ No Opacity(0.0) banner — subtree omitted entirely.
    // ✅ ListView.builder — lazy, recyclable.
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: cardCount,
      itemBuilder: (_, i) => _FixedFeedCard(index: i, likeCount: likeCount),
    );
  }
}

class _FixedFeedCard extends StatelessWidget {
  const _FixedFeedCard({required this.index, required this.likeCount});

  final int index;
  final ValueNotifier<int> likeCount;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ✅ Plain Row, no IntrinsicHeight
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // ✅ Avatar with cacheWidth at 2× display size
                ClipOval(
                  child: Image.network(
                    'https://picsum.photos/seed/avatar$index/200/200',
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    cacheWidth: 80,
                    cacheHeight: 80,
                    errorBuilder: (_, _, _) => Container(
                      width: 40,
                      height: 40,
                      color: Colors.grey.shade300,
                      child: const Icon(Icons.person, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'User ${index + 1}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${index + 1}h ago',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // ✅ Post image with cacheWidth at display size.
          Image.network(
            'https://picsum.photos/seed/post$index/800/600',
            height: 200,
            width: double.infinity,
            fit: BoxFit.cover,
            cacheWidth: 800,
            cacheHeight: 400,
            errorBuilder: (_, _, _) => Container(
              height: 200,
              color: Colors.grey.shade200,
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image, size: 40),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ✅ Only the badge rebuilds on like — not the whole card.
                ValueListenableBuilder<int>(
                  valueListenable: likeCount,
                  builder: (_, value, _) => Text(
                    '$value likes',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Post #${index + 1} — a beautiful scene captured on '
                  'a sunny afternoon. #photography #nature',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
