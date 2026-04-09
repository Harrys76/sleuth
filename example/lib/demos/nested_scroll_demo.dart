import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 7: Nested Scroll
// Triggers: NestedScroll detector
// ─────────────────────────────────────────

/// Demonstrates a `ScrollView` inside another `ScrollView` — a common
/// anti-pattern that breaks flings, physics, and item recycling. The
/// fix uses a non-scrollable inner list via `shrinkWrap: true` and
/// `NeverScrollableScrollPhysics`, letting the outer scroll view handle
/// the gesture.
class NestedScrollDemo extends StatelessWidget {
  const NestedScrollDemo({super.key});

  // 60 children — must exceed NestedScrollDetector's default
  // `childThreshold` of 50 (it fires on `childCount > childThreshold`),
  // otherwise the detector treats the inner list as cheap and stays
  // silent even when the nested-scroll pattern is real.
  static const _itemCount = 60;

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Nested Scroll',
      description:
          '❌ BAD: SingleChildScrollView > Column with $_itemCount children '
          'nested inside an outer SingleChildScrollView. Flings feel wrong, '
          'physics fight each other, and item recycling is disabled.\n'
          '✅ FIX: Use shrinkWrap + NeverScrollableScrollPhysics on the inner '
          'list so the outer scroll view owns the gesture, or (better) use '
          'CustomScrollView + slivers.\n\n'
          '▶ Flip to Fixed Pattern — the scroll physics match and the '
          'NestedScroll detector goes quiet.',
      // ❌ Outer SingleChildScrollView wraps an inner SingleChildScrollView
      //    on the same axis. NestedScrollDetector requires *both* a parent
      //    scrollable on the stack and a child with > childThreshold direct
      //    children — without the outer wrapper, the demo would only show
      //    the inner list and the detector would never fire.
      body: SingleChildScrollView(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Outer scroll header — drags here scroll the outer view',
                textAlign: TextAlign.center,
              ),
            ),
            // Bound the inner scrollable so it doesn't crash on unbounded
            // height. The fixed-height viewport is precisely what makes
            // nesting an inner SingleChildScrollView legal but also
            // pathological — the inner area needs its own gesture even
            // though the outer view is also scrollable on the same axis.
            SizedBox(
              height: 480,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < _itemCount; i++)
                      Container(
                        height: 60,
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.indigo.withValues(
                            alpha: 0.05 + (i % 10) * 0.02,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: Text('Nested scroll item $i'),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      fixedBody: SingleChildScrollView(
        // ✅ Single outer scroll owns the gesture. Inner list is
        //    non-scrollable: shrinkWrap + NeverScrollableScrollPhysics.
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Outer scroll header — only one scroll view in the tree',
                textAlign: TextAlign.center,
              ),
            ),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _itemCount,
              itemBuilder: (_, i) => Container(
                height: 60,
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.05 + (i % 10) * 0.02),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text('Single scroll item $i'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
