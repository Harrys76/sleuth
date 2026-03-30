import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 6: GlobalKey Overuse
// Triggers: GlobalKey detector (>10 keys)
// ─────────────────────────────────────────
class GlobalKeyDemo extends StatefulWidget {
  const GlobalKeyDemo({super.key});

  @override
  State<GlobalKeyDemo> createState() => _GlobalKeyDemoState();
}

class _GlobalKeyDemoState extends State<GlobalKeyDemo> {
  // ❌ 15 GlobalKeys — way too many
  final _keys = List.generate(15, (_) => GlobalKey());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GlobalKey Overuse')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: 15 GlobalKeys (threshold is 10)\n'
              '✅ FIX: Use ValueKey or UniqueKey instead where possible',
              style: TextStyle(fontSize: 13),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _keys.length,
              itemBuilder: (_, i) => Card(
                key: _keys[i], // ❌ GlobalKey
                child: ListTile(
                  title: Text('Item with GlobalKey #$i'),
                  leading: Icon(Icons.key, color: Colors.blue.shade400),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
