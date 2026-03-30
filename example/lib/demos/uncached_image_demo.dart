import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 5: Uncached Images
// Triggers: ImageMemory detector
// ─────────────────────────────────────────
class UncachedImageDemo extends StatelessWidget {
  const UncachedImageDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Uncached Images')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: Network images without cacheWidth/cacheHeight\n'
              '✅ FIX: Add cacheWidth: 300 to decode at display size',
              style: TextStyle(fontSize: 13),
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: 12,
              itemBuilder: (_, i) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                // ❌ No cacheWidth — full resolution decoded into memory
                child: Image.network(
                  'https://picsum.photos/seed/$i/800/800',
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    color: Colors.grey.shade200,
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
