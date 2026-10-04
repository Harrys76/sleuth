import 'package:flutter/widgets.dart';

/// Rebuilds [builder] whenever [listenable] notifies.
///
/// The overlay uses this instead of `ListenableBuilder`: the profile-mode
/// rebuild filter drops Sleuth's own widget classes by name, and a
/// Sleuth-named class keeps app-owned `ListenableBuilder` rebuilds in the
/// counts.
class SleuthListenableBuilder extends StatefulWidget {
  /// Creates a builder that listens to [listenable].
  const SleuthListenableBuilder({
    super.key,
    required this.listenable,
    required this.builder,
  });

  /// Source of rebuilds. Replacing it with a different object moves the
  /// subscription.
  final Listenable listenable;

  /// Builds the subtree; called on every notification.
  final WidgetBuilder builder;

  @override
  State<SleuthListenableBuilder> createState() =>
      _SleuthListenableBuilderState();
}

class _SleuthListenableBuilderState extends State<SleuthListenableBuilder> {
  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(SleuthListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
