import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 21: Tabbed Shell
// Triggers: ListView, ImageMemory and LayoutBottleneck detectors, one per
// tab, scoped to the visible tab of an IndexedStack
// ─────────────────────────────────────────

/// A bottom-navigation shell whose tabs live in an [IndexedStack], the
/// layout most production apps use. Each tab is its own [Scaffold] with
/// exactly one structural anti-pattern:
///
/// * **List** — a 60-child `Column` in a `SingleChildScrollView`
///   (`non_lazy_list`).
/// * **Images** — a grid of 800 px network images shown at 80 dp without
///   `cacheWidth` (`uncached_images`).
/// * **Layout** — eight rows wrapped in `IntrinsicHeight`
///   (`layout_bottleneck`).
///
/// `IndexedStack` keeps every tab built and laid out, but only the selected
/// one is painted. Sleuth's structural scan follows the selected tab, so
/// only that tab's pattern is reported. VM-side detectors (rebuild,
/// repaint) still see work done by the hidden tabs.
class TabbedShellDemo extends StatefulWidget {
  const TabbedShellDemo({super.key});

  @override
  State<TabbedShellDemo> createState() => _TabbedShellDemoState();
}

class _TabbedShellDemoState extends State<TabbedShellDemo> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tabbed Shell')),
      body: IndexedStack(
        index: _index,
        children: const [_ListTab(), _ImagesTab(), _LayoutTab()],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.list), label: 'List'),
          BottomNavigationBarItem(icon: Icon(Icons.image), label: 'Images'),
          BottomNavigationBarItem(icon: Icon(Icons.height), label: 'Layout'),
        ],
      ),
    );
  }
}

/// Explains what the selected tab should report.
class _TabNote extends StatelessWidget {
  const _TabNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // On a short screen (a phone in landscape, large text) the note takes
    // at most a quarter of the screen and scrolls, so the tab's content
    // stays on screen.
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: ConstrainedBox(
        // Marked like DemoScaffold's header, so remote scrolls move the
        // tab's content, not this note.
        key: DemoScaffold.headerKey,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height / 4,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Text(
            '$text\nSleuth reports only this tab\'s pattern, although '
            'IndexedStack keeps every tab built.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}

/// ❌ 60 eagerly built rows: `non_lazy_list`.
class _ListTab extends StatelessWidget {
  const _ListTab();

  static const _itemCount = 60;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _TabNote(
            'This tab should raise `non_lazy_list`, because a '
            'SingleChildScrollView with a Column builds all $_itemCount '
            'rows up front.',
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < _itemCount; i++)
                    ListTile(title: Text('Row $i')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ❌ 800 px images decoded at full size for 80 dp tiles: `uncached_images`.
class _ImagesTab extends StatelessWidget {
  const _ImagesTab();

  static const _itemCount = 24;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _TabNote(
            'This tab should raise `uncached_images`, because it shows '
            '800 px images at 80 dp without cacheWidth or cacheHeight.',
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 80,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: _itemCount,
              itemBuilder: (_, i) => Image.network(
                'https://picsum.photos/seed/tab$i/800/800',
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: Color(0xFFE0E0E0),
                  child: Center(child: Icon(Icons.broken_image)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ❌ Eight IntrinsicHeight rows: `layout_bottleneck`.
class _LayoutTab extends StatelessWidget {
  const _LayoutTab();

  static const _rowCount = 8;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _TabNote(
            'This tab should raise `layout_bottleneck`, because each row '
            'sits in an IntrinsicHeight, which lays its children out twice.',
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (var i = 0; i < _rowCount; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: ColoredBox(
                                color: Colors.blue.withValues(alpha: 0.15),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text('Left $i\nTwo lines'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ColoredBox(
                                color: Colors.red.withValues(alpha: 0.15),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text('Right $i${'\nMore' * (i % 3)}'),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
