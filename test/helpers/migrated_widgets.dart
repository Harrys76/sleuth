// Stand-ins for the `material_ui` / `cupertino_ui` copies of SDK widgets:
// the same class names as the SDK widgets, but distinct Dart types, which is
// what an app sees after `dart fix --apply --code=migrate_design_widgets`.
// The package itself needs Flutter 3.35 or later, so package tests (which
// also run on the 3.32 floor) use these; the example app tests the real
// package on the 3.47 lane.
//
// Import with a prefix: the names collide with package:flutter/material.dart.
import 'package:flutter/widgets.dart';

class Scaffold extends StatefulWidget {
  const Scaffold({super.key, required this.body});

  final Widget body;

  @override
  State<Scaffold> createState() => ScaffoldState();
}

class ScaffoldState extends State<Scaffold> {
  @override
  Widget build(BuildContext context) => widget.body;
}

class CupertinoPageScaffold extends StatefulWidget {
  const CupertinoPageScaffold({super.key, required this.child});

  final Widget child;

  @override
  State<CupertinoPageScaffold> createState() => _CupertinoPageScaffoldState();
}

class _CupertinoPageScaffoldState extends State<CupertinoPageScaffold> {
  @override
  Widget build(BuildContext context) => widget.child;
}

class TabBarView extends StatefulWidget {
  const TabBarView({super.key, required this.children});

  final List<Widget> children;

  @override
  State<TabBarView> createState() => _TabBarViewState();
}

class _TabBarViewState extends State<TabBarView> {
  @override
  Widget build(BuildContext context) => widget.children.first;
}

class Material extends StatefulWidget {
  const Material({super.key, required this.child});

  final Widget child;

  @override
  State<Material> createState() => _MaterialState();
}

class _MaterialState extends State<Material> {
  @override
  Widget build(BuildContext context) => widget.child;
}

class AppBar extends StatelessWidget {
  const AppBar({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 56);
}

class TabBar extends StatelessWidget {
  const TabBar({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 48);
}

/// Builds the private input-border painter a few levels below itself, as
/// the real `InputDecorator` does.
class InputDecorator extends StatelessWidget {
  const InputDecorator({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 100,
    height: 40,
    child: CustomPaint(painter: InputBorderPainter()),
  );
}

class LinearProgressIndicator extends StatelessWidget {
  const LinearProgressIndicator({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 4);
}

/// A painter named like the framework's private `_InputBorderPainter`.
/// Exposed through [InputBorderPainter] so tests can place it outside an
/// [InputDecorator] too.
class _InputBorderPainter extends CustomPainter {
  const _InputBorderPainter();

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

typedef InputBorderPainter = _InputBorderPainter;
