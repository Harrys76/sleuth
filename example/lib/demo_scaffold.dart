import 'package:flutter/material.dart';

/// Shared scaffold for all demo screens.
///
/// Provides a consistent layout: AppBar, collapsible instruction banner,
/// and a body slot. The body controls its own scrolling — DemoScaffold
/// never wraps it in a scroll view.
class DemoScaffold extends StatelessWidget {
  const DemoScaffold({
    required this.title,
    required this.description,
    required this.body,
    this.floatingActionButton,
    super.key,
  });

  /// AppBar title text.
  final String title;

  /// Instruction text shown in the collapsible banner.
  /// Typically includes ❌ BAD / ✅ FIX markers and a ▶ action line.
  final String description;

  /// Main content area — controls its own scrolling.
  final Widget body;

  /// Optional FAB.
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      floatingActionButton: floatingActionButton,
      body: Column(
        children: [
          _CollapsibleBanner(
            description: description,
            backgroundColor: colorScheme.surfaceContainerLow,
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Collapsible instruction banner that starts expanded.
class _CollapsibleBanner extends StatefulWidget {
  const _CollapsibleBanner({
    required this.description,
    required this.backgroundColor,
  });

  final String description;
  final Color backgroundColor;

  @override
  State<_CollapsibleBanner> createState() => _CollapsibleBannerState();
}

class _CollapsibleBannerState extends State<_CollapsibleBanner> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: widget.backgroundColor),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Instructions',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  widget.description,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
            secondChild: const SizedBox(width: double.infinity),
            crossFadeState: _expanded
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}
