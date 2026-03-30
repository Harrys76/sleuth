import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
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
      margin: const EdgeInsets.only(bottom: 6),
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
                    const SizedBox(width: 4),
                    _categoryBadge(issue.category, theme),
                    const SizedBox(width: 4),
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
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
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
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
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
                      const SizedBox(width: 4),
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
                    padding: const EdgeInsets.only(top: 4),
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
                if (_expanded) ...[
                  const SizedBox(height: 8),
                  Text(
                    issue.detail,
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                  if (issue.routeName != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
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
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'During: ${issue.interactionContext!.displayName}',
                        style: TextStyle(
                          color: theme.textTertiary,
                          fontSize: 10,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  if (issue.widgetName != null &&
                      !issue.title.contains(issue.widgetName!))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
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
                      padding: const EdgeInsets.only(top: 2),
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
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Source: ${issue.observationSource!._displayName}',
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
                    onTap: () =>
                        setState(() => _aboutExpanded = !_aboutExpanded),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          Icon(
                            _aboutExpanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            color: theme.textQuaternary,
                            size: 14,
                          ),
                          const SizedBox(width: 4),
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
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.all(8),
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
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
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
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
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
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.fixHintBackground,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _effortBadge(issue, theme),
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('\u{1F4A1}',
                                style: TextStyle(fontSize: 12)),
                            const SizedBox(width: 6),
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
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _downstreamSection(WatchdogThemeData theme) {
    final downstream = widget.downstreamIssues!;
    final visibleCount = downstream.length > 5 ? 5 : downstream.length;
    final overflow = downstream.length - visibleCount;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.all(8),
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
            const SizedBox(height: 4),
            for (var i = 0; i < visibleCount; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    _severityIcon(downstream[i].severity),
                    const SizedBox(width: 4),
                    _categoryBadge(downstream[i].category, theme),
                    const SizedBox(width: 4),
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
                padding: const EdgeInsets.only(top: 2),
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

  List<(String, String)> _aboutContent(PerformanceIssue issue) {
    final source =
        issue.observationSource?._displayName ?? 'heuristic analysis';
    final confidenceExplanation = switch (issue.confidence) {
      IssueConfidence.confirmed => 'Directly observed at runtime',
      IssueConfidence.likely => 'Runtime signal + structural evidence',
      IssueConfidence.possible =>
        'Structural pattern only \u2014 no runtime confirmation',
    };
    final accuracyNote = kDebugMode
        ? 'Debug mode adds overhead \u2014 verify in profile mode'
        : 'Profile mode \u2014 timing data is production-accurate';
    final verifyWith = switch (issue.category) {
      IssueCategory.build ||
      IssueCategory.layout =>
        'DevTools \u2192 Performance \u2192 Frame Analysis',
      IssueCategory.paint ||
      IssueCategory.raster =>
        'DevTools \u2192 Performance \u2192 Raster Stats',
      IssueCategory.memory =>
        'DevTools \u2192 Memory \u2192 Allocation Tracking',
      IssueCategory.channel =>
        'DevTools \u2192 Network \u2192 Platform Channels',
      IssueCategory.network => 'DevTools \u2192 Network',
      IssueCategory.font =>
        'DevTools \u2192 Performance \u2192 Timeline Events',
    };
    return [
      ('Based on:', source),
      ('Confidence:', '${issue.confidence.name} \u2014 $confidenceExplanation'),
      ('Accuracy:', accuracyNote),
      ('Verify with:', verifyWith),
    ];
  }

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
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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

extension on ObservationSource {
  String get _displayName => switch (this) {
        ObservationSource.structural => 'structural scan',
        ObservationSource.vmTimeline => 'VM timeline',
        ObservationSource.debugCallback => 'debug callback',
        ObservationSource.debugCallbackAndStructural =>
          'debug callback + structural',
      };
}
