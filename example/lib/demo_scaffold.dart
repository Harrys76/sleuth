import 'package:flutter/material.dart';

/// Shared scaffold for all demo screens.
///
/// Provides a consistent layout: AppBar, Before/After toggle (optional),
/// collapsible instruction banner, optional live metrics bar, and a body
/// slot. The body controls its own scrolling — DemoScaffold never wraps
/// it in a scroll view.
///
/// When [fixedBody] is provided, a SegmentedButton appears just below the
/// AppBar that lets the user switch between the anti-pattern ([body]) and
/// the corrected version ([fixedBody]). The switch uses a ternary in the
/// build tree, so the hidden subtree is fully unmounted — animations,
/// timers, and controllers in the hidden side stop automatically.
///
/// Demos that need to react to the toggle (e.g., to reset a metric counter
/// or pause a global callback) can supply an [onToggle] callback. It is
/// invoked with the new `isFixed` value AFTER the state has updated.
class DemoScaffold extends StatefulWidget {
  const DemoScaffold({
    required this.title,
    required this.description,
    required this.body,
    this.fixedBody,
    this.onToggle,
    this.metricsBar,
    this.floatingActionButton,
    super.key,
  });

  /// AppBar title text.
  final String title;

  /// Instruction text shown in the collapsible banner.
  /// Typically includes ❌ BAD / ✅ FIX markers and a ▶ action line.
  final String description;

  /// Main content area (the anti-pattern). Controls its own scrolling.
  final Widget body;

  /// Optional corrected version. When non-null, a Before/After toggle
  /// appears between the AppBar and the instruction banner.
  final Widget? fixedBody;

  /// Called when the user toggles between bad ([body]) and fixed
  /// ([fixedBody]). `true` means the fixed body is now visible.
  final ValueChanged<bool>? onToggle;

  /// Optional live metrics bar displayed below the instruction banner.
  /// Typically a [MetricsBar] containing [MetricChip] children.
  final Widget? metricsBar;

  /// Optional FAB.
  final Widget? floatingActionButton;

  @override
  State<DemoScaffold> createState() => _DemoScaffoldState();
}

class _DemoScaffoldState extends State<DemoScaffold> {
  bool _isFixed = false;

  void _handleToggle(Set<bool> selected) {
    final isFixed = selected.first;
    if (isFixed == _isFixed) return;
    setState(() => _isFixed = isFixed);
    widget.onToggle?.call(isFixed);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasToggle = widget.fixedBody != null;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      floatingActionButton: widget.floatingActionButton,
      body: Column(
        children: [
          if (hasToggle)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Center(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      label: Text('Bad Pattern'),
                      icon: Icon(Icons.warning_amber, size: 16),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      label: Text('Fixed Pattern'),
                      icon: Icon(Icons.check_circle_outline, size: 16),
                    ),
                  ],
                  selected: {_isFixed},
                  onSelectionChanged: _handleToggle,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle: WidgetStateProperty.all(
                      const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          _CollapsibleBanner(
            description: widget.description,
            backgroundColor: colorScheme.surfaceContainerLow,
          ),
          if (widget.metricsBar != null) widget.metricsBar!,
          // Key design decision: ternary (not Stack/IndexedStack/AnimatedCrossFade).
          // The hidden subtree is fully unmounted so timers/controllers stop firing.
          Expanded(child: _isFixed ? widget.fixedBody! : widget.body),
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

// ───────────────────────────────────────────────
// Metrics bar primitives
// ───────────────────────────────────────────────

/// A thin horizontal strip hosting [MetricChip]s below the instruction
/// banner. Demos pass one of these as [DemoScaffold.metricsBar] when they
/// want to surface live numeric feedback (rebuild count, FPS, MB retained,
/// etc.).
class MetricsBar extends StatelessWidget {
  const MetricsBar({required this.chips, super.key});

  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
          bottom: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Wrap(spacing: 8, runSpacing: 4, children: chips),
      ),
    );
  }
}

/// Compact pill showing a single metric: `Label: value unit`.
///
/// Use inside a [MetricsBar]. Keep values short — long strings wrap.
class MetricChip extends StatelessWidget {
  const MetricChip({
    required this.label,
    required this.value,
    this.unit,
    super.key,
  });

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            children: [
              TextSpan(
                text: '$label: ',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              TextSpan(text: value),
              if (unit != null) TextSpan(text: unit),
            ],
          ),
        ),
      ),
    );
  }
}
