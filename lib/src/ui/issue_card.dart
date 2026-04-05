import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import '../utils/issue_metadata_builder.dart';
import 'watchdog_theme.dart';

/// A card displaying a single performance issue.
///
/// - Tap to expand/collapse detail + fix hint.
/// - Checkbox (when locatable) to highlight the widget on screen.
///
/// Uses internal expansion state so that list rebuilds from parent
/// ValueListenableBuilders do not reset expansion. The parent passes
/// [initiallyExpanded] for restore-on-recreate (when the card leaves
/// and re-enters the list), but after creation the card owns its state.
/// Must be used with a stable [ValueKey] (e.g. stableId) in the ListView.
class IssueCard extends StatefulWidget {
  const IssueCard({
    super.key,
    required this.issue,
    this.initiallyExpanded = false,
    this.onExpandedChanged,
    this.locatable = false,
    this.highlighted = false,
    this.onHighlightChanged,
    this.deepInstrumentationActive = false,
    this.jankCorrelated = false,
    this.jankFlash = false,
    this.downstreamIssues,
    this.onLearnMore,
    this.onAskAi,
  });

  final PerformanceIssue issue;

  /// Seed value — read once in [initState]. After that, internal state owns it.
  final bool initiallyExpanded;

  /// Notifies parent so it can persist expansion across card destruction.
  final ValueChanged<bool>? onExpandedChanged;

  final bool locatable;
  final bool highlighted;
  final ValueChanged<bool>? onHighlightChanged;

  /// When true and the issue source is debug-callback-based, shows fidelity
  /// annotations distinguishing attribution quality from timing fidelity.
  final bool deepInstrumentationActive;

  /// When true, shows a "JANK" badge in the collapsed header — this issue
  /// appears in the current verdict's relatedIssues.
  final bool jankCorrelated;

  /// When true, applies a temporary amber tint to draw attention to
  /// jank-correlated issues. Takes priority over [highlighted] color.
  final bool jankFlash;

  /// Downstream issues caused by this root issue, collapsed into expanded
  /// detail. Null or empty for non-root and standalone issues.
  final List<PerformanceIssue>? downstreamIssues;

  /// Called when the user taps "Learn more" — navigates to the full-screen
  /// detail page. Null hides the link (e.g. for custom detector issues).
  final VoidCallback? onLearnMore;

  /// Called when the user taps "Ask AI" — opens contextual AI chat.
  /// Null hides the link (e.g. when no [AiChatAdapter] is configured).
  final VoidCallback? onAskAi;

  @override
  State<IssueCard> createState() => _IssueCardState();
}

class _IssueCardState extends State<IssueCard> {
  late bool _expanded;
  bool _aboutExpanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (!_expanded) _aboutExpanded = false;
    });
    widget.onExpandedChanged?.call(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final theme = WatchdogTheme.of(context);
    final issue = widget.issue;
    return Card(
      color: widget.jankFlash
          ? theme.cardJankFlash
          : widget.highlighted
              ? theme.cardHighlighted
              : theme.cardDefault,
      margin: EdgeInsets.only(bottom: theme.spacingSm),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _toggle,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: theme.sourceAccentColor(issue.observationSource),
                width: 3,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row
                Row(
                  children: [
                    _severityIcon(issue.severity),
                    SizedBox(width: theme.spacingXs),
                    _categoryBadge(issue.category, theme),
                    SizedBox(width: theme.spacingXs),
                    Expanded(
                      child: Text(
                        issue.title,
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _confidenceBadge(issue.confidence, theme),
                    if (widget.jankCorrelated) ...[
                      SizedBox(width: theme.spacingXs),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: theme.spacingXs, vertical: 1),
                        decoration: BoxDecoration(
                          color: theme.severityCritical.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'JANK',
                          style: TextStyle(
                            color: theme.severityCritical,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                    if (widget.downstreamIssues != null &&
                        widget.downstreamIssues!.isNotEmpty) ...[
                      SizedBox(width: theme.spacingXs),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: theme.spacingXs, vertical: 1),
                        decoration: BoxDecoration(
                          color: theme.effectsBadge.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '\u21B3 ${widget.downstreamIssues!.length}',
                          style: TextStyle(
                            color: theme.effectsBadge,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                    if (widget.locatable) ...[
                      SizedBox(width: theme.spacingXs),
                      Checkbox(
                        value: widget.highlighted,
                        onChanged: (v) =>
                            widget.onHighlightChanged?.call(v ?? false),
                        side: BorderSide(
                          color: theme.textQuaternary,
                          width: 1.5,
                        ),
                        activeColor: theme.checkboxActive,
                      ),
                    ],
                  ],
                ),

                // Debug mode disclaimer
                if (issue.debugModeDisclaimer)
                  Padding(
                    padding: EdgeInsets.only(top: theme.spacingXs),
                    child: Text(
                      '[DEBUG MODE — verify in profile]',
                      style: TextStyle(
                        color: theme.disclaimerText,
                        fontSize: 9,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),

                // Expanded detail + fix hint
                if (_expanded) ..._buildExpandedContent(issue, theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildExpandedContent(
      PerformanceIssue issue, WatchdogThemeData theme) {
    return [
      SizedBox(height: theme.spacingMd),
      Text(
        issue.detail,
        style: TextStyle(
          color: theme.textSecondary,
          fontSize: 11,
        ),
      ),
      if (issue.routeName != null)
        Padding(
          padding: EdgeInsets.only(top: theme.spacingXs),
          child: Text(
            'Route: ${issue.routeName}',
            style: TextStyle(
              color: theme.textTertiary,
              fontSize: 10,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      if (issue.interactionContext != null &&
          issue.interactionContext != InteractionContext.idle)
        Padding(
          padding: EdgeInsets.only(top: theme.spacingXxs),
          child: Text(
            'During: ${issue.interactionContext!.displayName}',
            style: TextStyle(
              color: theme.textTertiary,
              fontSize: 10,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      if (issue.widgetName != null && !issue.title.contains(issue.widgetName!))
        Padding(
          padding: EdgeInsets.only(top: theme.spacingXxs),
          child: Text(
            'Widget: ${issue.widgetName}',
            style: TextStyle(
              color: theme.textTertiary,
              fontSize: 10,
              fontStyle: FontStyle.italic,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (issue.ancestorChain != null &&
          !issue.detail.contains(issue.ancestorChain!) &&
          issue.ancestorChain != issue.widgetName)
        Padding(
          padding: EdgeInsets.only(top: theme.spacingXxs),
          child: Text(
            'Ancestors: ${issue.ancestorChain}',
            style: TextStyle(
              color: theme.textTertiary,
              fontSize: 10,
              fontStyle: FontStyle.italic,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (issue.observationSource != null)
        Padding(
          padding: EdgeInsets.only(top: theme.spacingXxs),
          child: Text(
            'Source: ${issue.observationSource!.displayName}',
            style: TextStyle(
              color: theme.textQuaternary,
              fontSize: 9,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      // Downstream effects section (causal graph)
      if (widget.downstreamIssues != null &&
          widget.downstreamIssues!.isNotEmpty)
        _downstreamSection(theme),
      // "About this detection" collapsible section
      GestureDetector(
        onTap: () => setState(() => _aboutExpanded = !_aboutExpanded),
        child: Padding(
          padding: EdgeInsets.only(top: theme.spacingSm),
          child: Row(
            children: [
              Icon(
                _aboutExpanded ? Icons.expand_less : Icons.expand_more,
                color: theme.textQuaternary,
                size: 14,
              ),
              SizedBox(width: theme.spacingXs),
              Text(
                'About this detection',
                style: TextStyle(
                  color: theme.textQuaternary,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
      if (_aboutExpanded)
        Container(
          margin: EdgeInsets.only(top: theme.spacingXs),
          padding: EdgeInsets.all(theme.spacingMd),
          decoration: BoxDecoration(
            color: theme.aboutBackground,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in _aboutContent(issue))
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${entry.$1} ',
                          style: TextStyle(
                            color: theme.textTertiary,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextSpan(
                          text: entry.$2,
                          style: TextStyle(
                            color: theme.textTertiary,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      if (widget.deepInstrumentationActive &&
          _isDebugCallbackSource(issue.observationSource))
        Padding(
          padding: EdgeInsets.only(top: theme.spacingXxs),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: theme.spacingXs, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.bannerSuccessBg,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Attribution: high fidelity',
                  style: TextStyle(
                    color: theme.bannerSuccessText,
                    fontSize: 9,
                  ),
                ),
              ),
              SizedBox(width: theme.spacingXs),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: theme.spacingXs, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.bannerWarningBg,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Timing: overhead present',
                  style: TextStyle(
                    color: theme.bannerWarningText,
                    fontSize: 9,
                  ),
                ),
              ),
            ],
          ),
        ),
      SizedBox(height: theme.spacingMd),
      Container(
        padding: EdgeInsets.all(theme.spacingMd),
        decoration: BoxDecoration(
          color: theme.fixHintBackground,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _effortBadge(issue, theme),
            SizedBox(height: theme.spacingXs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('\u{1F4A1}', style: TextStyle(fontSize: 12)),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    issue.fixHint,
                    style: TextStyle(
                      color: theme.fixHintText,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      if (widget.onLearnMore != null || widget.onAskAi != null)
        Padding(
          padding: EdgeInsets.only(top: theme.spacingSm),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final bothPresent =
                  widget.onLearnMore != null && widget.onAskAi != null;
              // Both links at font-size 9 + icons need ~240px side by side.
              final stackVertically = bothPresent && constraints.maxWidth < 240;

              if (stackVertically) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.onLearnMore != null) _buildLearnMoreLink(theme),
                    if (widget.onAskAi != null)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: EdgeInsets.only(top: theme.spacingXs),
                          child: _AskAiShimmerLink(onTap: widget.onAskAi!),
                        ),
                      ),
                  ],
                );
              }
              return Row(
                children: [
                  if (widget.onLearnMore != null)
                    Flexible(child: _buildLearnMoreLink(theme)),
                  if (bothPresent) const Spacer(),
                  if (widget.onAskAi != null)
                    _AskAiShimmerLink(onTap: widget.onAskAi!),
                ],
              );
            },
          ),
        ),
    ];
  }

  Widget _buildLearnMoreLink(WatchdogThemeData theme) {
    return GestureDetector(
      onTap: widget.onLearnMore,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined, color: theme.textTertiary, size: 13),
          SizedBox(width: theme.spacingXs),
          Flexible(
            child: Text(
              'Learn more about this issue',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(
                color: theme.textTertiary,
                fontSize: 9,
                decoration: TextDecoration.underline,
                decorationColor: theme.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _downstreamSection(WatchdogThemeData theme) {
    final downstream = widget.downstreamIssues!;
    final visibleCount = downstream.length > 5 ? 5 : downstream.length;
    final overflow = downstream.length - visibleCount;

    return Padding(
      padding: EdgeInsets.only(top: theme.spacingSm),
      child: Container(
        padding: EdgeInsets.all(theme.spacingMd),
        decoration: BoxDecoration(
          color: theme.aboutBackground,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Related effects (${downstream.length}):',
              style: TextStyle(
                color: theme.effectsBadge,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: theme.spacingXs),
            for (var i = 0; i < visibleCount; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    _severityIcon(downstream[i].severity),
                    SizedBox(width: theme.spacingXs),
                    _categoryBadge(downstream[i].category, theme),
                    SizedBox(width: theme.spacingXs),
                    Expanded(
                      child: Text(
                        downstream[i].title,
                        style: TextStyle(
                          color: theme.textTertiary,
                          fontSize: 10,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            if (overflow > 0)
              Padding(
                padding: EdgeInsets.only(top: theme.spacingXxs),
                child: Text(
                  'and $overflow more...',
                  style: TextStyle(
                    color: theme.textQuaternary,
                    fontSize: 9,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<(String, String)> _aboutContent(PerformanceIssue issue) =>
      IssueMetadataBuilder.entries(issue);

  Widget _categoryBadge(IssueCategory category, WatchdogThemeData theme) {
    final color = theme.categoryColor(category);
    final label = switch (category) {
      IssueCategory.build => 'BUILD',
      IssueCategory.layout => 'LAYOUT',
      IssueCategory.paint => 'PAINT',
      IssueCategory.raster => 'RASTER',
      IssueCategory.memory => 'MEMORY',
      IssueCategory.channel => 'CHANNEL',
      IssueCategory.font => 'FONT',
      IssueCategory.network => 'NETWORK',
    };

    return Container(
      padding: EdgeInsets.symmetric(horizontal: theme.spacingXs, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _severityIcon(IssueSeverity severity) {
    switch (severity) {
      case IssueSeverity.critical:
        return const Text('\u{1F534}', style: TextStyle(fontSize: 12));
      case IssueSeverity.warning:
        return const Text('\u{1F7E1}', style: TextStyle(fontSize: 12));
      case IssueSeverity.ok:
        return const Text('\u{1F7E2}', style: TextStyle(fontSize: 12));
    }
  }

  Widget _effortBadge(PerformanceIssue issue, WatchdogThemeData theme) {
    final (label, color) = _fixEffort(issue, theme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _confidenceBadge(IssueConfidence confidence, WatchdogThemeData theme) {
    final color = theme.confidenceColor(confidence);
    final label = switch (confidence) {
      IssueConfidence.confirmed => 'CONFIRMED',
      IssueConfidence.likely => 'LIKELY',
      IssueConfidence.possible => 'POSSIBLE',
    };

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: theme.spacingSm, vertical: theme.spacingXxs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

bool _isDebugCallbackSource(ObservationSource? source) =>
    source == ObservationSource.debugCallback ||
    source == ObservationSource.debugCallbackAndStructural;

/// Returns (label, color) for the effort badge.
/// Prefers explicit [FixEffort] from the model; falls back to keyword
/// inference for legacy issues deserialized without the field.
(String, Color) _fixEffort(PerformanceIssue issue, WatchdogThemeData theme) {
  final effort = issue.fixEffort;
  if (effort != null) {
    return switch (effort) {
      FixEffort.quick => ('QUICK FIX', theme.effortQuick),
      FixEffort.medium => ('MEDIUM FIX', theme.effortMedium),
      FixEffort.involved => ('INVOLVED FIX', theme.effortInvolved),
    };
  }

  // Legacy fallback: keyword inference for issues without fixEffort
  final hint = issue.fixHint.toLowerCase();

  // Quick: simple config/wrapper changes
  const quickKeywords = [
    'const constructor',
    'cachewidth',
    'cacheheight',
    'listview.builder',
    'listview.separated',
    'shouldrepaint',
    'repaintboundary',
    'visibility',
    'globalkey',
    'valuekey',
    'keepalive',
    'child parameter',
    'limit custom fonts',
    'fontloader',
    'minor jank',
  ];
  for (final kw in quickKeywords) {
    if (hint.contains(kw)) {
      return ('QUICK FIX', theme.effortQuick);
    }
  }

  // Involved: architecture changes
  const involvedKeywords = [
    'isolate.run',
    'compute(',
    'cache-sksl',
    'bundle-sksl',
    'sparse fieldsets',
    'graphql',
    'growing steadily',
    'background isolate',
  ];
  for (final kw in involvedKeywords) {
    if (hint.contains(kw)) {
      return ('INVOLVED FIX', theme.effortInvolved);
    }
  }

  // Default: medium
  return ('MEDIUM FIX', theme.effortMedium);
}

/// Animated shimmer "Ask AI" link with purple-blue-pink gradient.
///
/// Owns its own [AnimationController] so the shimmer only runs while this
/// widget is in the tree (card expanded + onAskAi configured). The gradient
/// area is tiny (single text line + icon) so the [ShaderMask] saveLayer
/// cost is negligible.
class _AskAiShimmerLink extends StatefulWidget {
  const _AskAiShimmerLink({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_AskAiShimmerLink> createState() => _AskAiShimmerLinkState();
}

class _AskAiShimmerLinkState extends State<_AskAiShimmerLink>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = WatchdogTheme.of(context);
    return RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            // Sweep a full-width gradient across the widget. The gradient
            // stretches 2 alignment-units (= full widget width) and travels
            // from off-screen left (-3) to off-screen right (+3), so the
            // shimmer enters at the icon and exits past the last letter.
            final dx = _controller.value * 6.0 - 3.0;
            return ShaderMask(
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment(dx, 0),
                end: Alignment(dx + 2.0, 0),
                colors: [
                  theme.aiShimmerStart,
                  theme.aiShimmerMid,
                  theme.aiShimmerEnd,
                  theme.aiShimmerStart,
                ],
                stops: const [0.0, 0.33, 0.66, 1.0],
              ).createShader(bounds),
              blendMode: BlendMode.srcIn,
              child: child,
            );
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome, size: 13),
              SizedBox(width: theme.spacingXs),
              Flexible(
                child: Text(
                  'Ask AI about this issue',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style:
                      const TextStyle(fontSize: 9, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
