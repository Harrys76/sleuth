// An app widget that reuses a framework class name without being the
// framework widget. Import with a prefix.
import 'package:flutter/widgets.dart';

/// The app's own `Scaffold`: same name as Material's, but its state is not
/// `ScaffoldState`.
class Scaffold extends StatefulWidget {
  const Scaffold({super.key, required this.body});

  final Widget body;

  @override
  State<Scaffold> createState() => _AppScaffoldState();
}

class _AppScaffoldState extends State<Scaffold> {
  @override
  Widget build(BuildContext context) => widget.body;
}
