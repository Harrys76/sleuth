import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 4: Shrink-wrapped Sections
// Triggers: ListView detector (non_lazy_shrinkwrap, one card per list)
// ─────────────────────────────────────────

/// Two sections of equal length, each a `ListView(shrinkWrap: true)` in a
/// Column inside a SingleChildScrollView. Sleuth reports one card per
/// list; the cards share a title, and each keeps its own AI chat. The fix
/// puts both sections in one CustomScrollView as lazy slivers.
class ShrinkWrappedSectionsDemo extends StatelessWidget {
  const ShrinkWrappedSectionsDemo({super.key});

  static const _sections = ['Inbox', 'Archive'];
  static const _rowsPerSection = 30;

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Shrink-wrapped Sections',
      description:
          'Bad: Two ListView(shrinkWrap: true) sections of '
          '$_rowsPerSection rows sit in a Column inside a '
          'SingleChildScrollView. Each list builds and lays out every row '
          'up front.\n'
          'Fix: Use one CustomScrollView with a SliverList.builder per '
          'section, so only visible rows are built.\n\n'
          'Open Sleuth. It shows two cards with the same title, one per '
          'list. Ask AI on each; the conversations stay separate.',
      body: SingleChildScrollView(
        child: Column(
          children: [
            for (final name in _sections) ...[
              _SectionHeader(name),
              ListView(
                // ❌ shrinkWrap in an unbounded Column builds every row.
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (var i = 0; i < _rowsPerSection; i++)
                    _Row(section: name, index: i),
                ],
              ),
            ],
          ],
        ),
      ),
      fixedBody: CustomScrollView(
        slivers: [
          for (final name in _sections) ...[
            SliverToBoxAdapter(child: _SectionHeader(name)),
            // ✅ Lazy: rows are built as they scroll into view.
            SliverList.builder(
              itemCount: _rowsPerSection,
              itemBuilder: (_, i) => _Row(section: name, index: i),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(name, style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.section, required this.index});

  final String section;
  final int index;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(child: Text('${index + 1}')),
      title: Text('$section message ${index + 1}'),
    );
  }
}
