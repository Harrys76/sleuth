import 'package:flutter/material.dart';

// ───────────────────────────────────────────────
// Combined Demo 1: Social Feed
// ───────────────────────────────────────────────
// Triggers: ImageMemory, Opacity, LayoutBottleneck, Rebuild/SetStateScope
// Correlation: Rule 2 (merge rebuild+setState), Rule 4 (escalate image+memory)

class CombinedSocialFeedDemo extends StatefulWidget {
  const CombinedSocialFeedDemo({super.key});

  @override
  State<CombinedSocialFeedDemo> createState() => _CombinedSocialFeedDemoState();
}

class _CombinedSocialFeedDemoState extends State<CombinedSocialFeedDemo> {
  int _likeCount = 0;

  @override
  Widget build(BuildContext context) {
    // ❌ setState at top level rebuilds entire feed
    return Scaffold(
      appBar: AppBar(title: const Text('Social Feed (Combined)')),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.deepPurple.withValues(alpha: 0.05),
            child: const Text(
              'This screen combines 4+ anti-patterns you\'d find in a '
              'real social media feed. Open the Watchdog overlay to see '
              'how issues are correlated, merged, and ranked.',
              style: TextStyle(fontSize: 12),
            ),
          ),

          // ❌ Opacity(0.0) hides a "load more" banner — invisible but
          //    still laid out, hit-tested, and painted.
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

          // ❌ Feed items
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: List.generate(8, (i) => _buildFeedCard(i)),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // ❌ Top-level setState rebuilds all 8 cards + images
        onPressed: () => setState(() => _likeCount++),
        icon: const Icon(Icons.favorite),
        label: Text('Like ($_likeCount)'),
      ),
    );
  }

  Widget _buildFeedCard(int index) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ❌ IntrinsicHeight forces two-pass layout for the header row
          IntrinsicHeight(
            child: Row(
              children: [
                const SizedBox(width: 12),
                // ❌ Avatar — no cacheWidth
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

          // Caption and like count
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$_likeCount likes',
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
