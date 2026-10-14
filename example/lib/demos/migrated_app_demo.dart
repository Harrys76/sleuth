import 'package:material_ui/material_ui.dart';

// ─────────────────────────────────────────
// Demo: Migrated App (material_ui)
// Checks: Sleuth recognises framework widgets from the material_ui package
// by name, and a user painter still reports
// ─────────────────────────────────────────

/// A small app built on the `material_ui` package instead of
/// `package:flutter/material.dart`, as an app looks after
/// `dart fix --apply --code=migrate_design_widgets`.
///
/// Its `Scaffold`, `AppBar`, `TabBar`, text field and progress indicators
/// are distinct Dart types from the SDK ones, so Sleuth recognises them by
/// name. Expected: the scan finds this `Scaffold`, and no card names the
/// tab indicator, the text field border or the progress indicators. The
/// always-repaint painter on the Paint tab is the app's own and still
/// reports.
///
/// `material_ui` widgets read `material_ui`'s own `Theme` and
/// localizations, so the demo runs as a nested `MaterialApp` from that
/// package; the close button pops the outer route.
class MigratedAppDemo extends StatelessWidget {
  const MigratedAppDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DefaultTabController(
        length: 2,
        child: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).pop(),
              ),
              title: const Text('Migrated App (material_ui)'),
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Controls'),
                  Tab(text: 'Paint'),
                ],
              ),
            ),
            body: const TabBarView(children: [_ControlsTab(), _PaintTab()]),
          ),
        ),
      ),
    );
  }
}

void _noop() {}

class _ControlsTab extends StatelessWidget {
  const _ControlsTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        Text(
          'Framework widgets from material_ui. None of these should '
          'produce a painter or setState card.',
        ),
        SizedBox(height: 16),
        TextField(decoration: InputDecoration(labelText: 'Name')),
        SizedBox(height: 24),
        OutlinedButton(onPressed: _noop, child: Text('Outlined')),
        SizedBox(height: 24),
        LinearProgressIndicator(),
        SizedBox(height: 24),
        Center(child: CircularProgressIndicator()),
      ],
    );
  }
}

class _PaintTab extends StatelessWidget {
  const _PaintTab();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The app\'s own painter returns true from shouldRepaint, so '
            'Sleuth reports it.',
          ),
          SizedBox(height: 16),
          SizedBox(
            height: 120,
            width: double.infinity,
            child: CustomPaint(painter: _AlwaysRepaintPainter()),
          ),
        ],
      ),
    );
  }
}

class _AlwaysRepaintPainter extends CustomPainter {
  const _AlwaysRepaintPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF3F51B5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
