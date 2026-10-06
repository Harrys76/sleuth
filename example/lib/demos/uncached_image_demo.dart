import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 13: Uncached Images
// Triggers: ImageMemory detector
// ─────────────────────────────────────────

/// Demonstrates decoding network images at full resolution instead of at
/// display size. A 800×800 JPEG decoded into a 120×120 grid tile wastes
/// ~2 MB per image. The fix uses `cacheWidth` / `cacheHeight` to decode
/// the image at its display size.
class UncachedImageDemo extends StatelessWidget {
  const UncachedImageDemo({super.key});

  static const _itemCount = 12;

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Uncached Images',
      description:
          'Bad: Image.network has no cacheWidth or cacheHeight. Flutter '
          'decodes each of the $_itemCount 800×800 JPEGs at full '
          'resolution, although each displays at about 120×120. That '
          'wastes about 2 MB of memory per tile.\n'
          'Fix: Pass cacheWidth: 240 (or match the display size) so '
          'Flutter downscales during decode.\n\n'
          'Flip to Fixed Pattern, and the ImageMemory detector should go '
          'quiet. The grid looks the same and uses about 95% less memory.',
      body: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: _itemCount,
        itemBuilder: (_, i) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          // ❌ No cacheWidth — full 800×800 decoded into memory
          child: Image.network(
            'https://picsum.photos/seed/$i/800/800',
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const ColoredBox(
              color: Color(0xFFE0E0E0),
              child: Center(child: Icon(Icons.broken_image)),
            ),
          ),
        ),
      ),
      fixedBody: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: _itemCount,
        itemBuilder: (_, i) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          // ✅ cacheWidth matches display size (2x for high-DPI screens)
          child: Image.network(
            'https://picsum.photos/seed/$i/800/800',
            fit: BoxFit.cover,
            cacheWidth: 240,
            cacheHeight: 240,
            errorBuilder: (_, _, _) => const ColoredBox(
              color: Color(0xFFE0E0E0),
              child: Center(child: Icon(Icons.broken_image)),
            ),
          ),
        ),
      ),
    );
  }
}
