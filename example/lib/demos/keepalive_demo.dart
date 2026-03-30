import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 9: KeepAlive Overuse
// Triggers: KeepAlive detector (>5)
// ─────────────────────────────────────────
class KeepAliveDemo extends StatelessWidget {
  const KeepAliveDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('KeepAlive Overuse'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Tab 1'),
              Tab(text: 'Tab 2'),
              Tab(text: 'Tab 3'),
            ],
          ),
        ),
        body: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '❌ BAD: All tabs use AutomaticKeepAlive\n'
                '✅ FIX: Only keep alive tabs with expensive state',
                style: TextStyle(fontSize: 13),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: List.generate(
                  3,
                  (tab) => ListView.builder(
                    itemCount: 20,
                    itemBuilder: (_, i) =>
                        _KeepAliveItem(label: 'Tab $tab — Item $i'),
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

class _KeepAliveItem extends StatefulWidget {
  const _KeepAliveItem({required this.label});
  final String label;

  @override
  State<_KeepAliveItem> createState() => _KeepAliveItemState();
}

class _KeepAliveItemState extends State<_KeepAliveItem>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // ❌ Every item stays alive

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListTile(
      leading: const Icon(Icons.all_inclusive),
      title: Text(widget.label),
      subtitle: const Text('wantKeepAlive: true (never GC\'d)'),
    );
  }
}
