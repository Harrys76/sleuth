import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 3: IntrinsicHeight Abuse
// Triggers: LayoutBottleneck detector
// ─────────────────────────────────────────
class IntrinsicHeightDemo extends StatelessWidget {
  const IntrinsicHeightDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('IntrinsicHeight Abuse')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              '❌ BAD: IntrinsicHeight causes O(n²) layout passes\n'
              '✅ FIX: Use Expanded/Flexible or fixed-height containers',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            // ❌ IntrinsicHeight — slow layout
            ...List.generate(
              8,
              (i) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          color: Colors.blue.withValues(alpha: 0.1 + i * 0.05),
                          padding: const EdgeInsets.all(16),
                          child: Text('Left cell $i\nMulti-line\ncontent'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          color: Colors.red.withValues(alpha: 0.1 + i * 0.05),
                          padding: const EdgeInsets.all(16),
                          child: Text('Right $i\n${"Extra line\n" * i}'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
