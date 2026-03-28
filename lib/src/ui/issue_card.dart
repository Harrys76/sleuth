import 'package:flutter/material.dart';

import '../models/performance_issue.dart';

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

  @override
  State<IssueCard> createState() => _IssueCardState();
}

class _IssueCardState extends State<IssueCard> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    widget.onExpandedChanged?.call(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final issue = widget.issue;
    return Card(
      color: widget.highlighted
          ? const Color(0xFF1E3A5F)
          : const Color(0xFF374151),
      margin: const EdgeInsets.only(bottom: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          children: [
            Container(
              width: 3,
              color: _sourceAccentColor(issue.observationSource),
            ),
            Expanded(
              child: InkWell(
                onTap: _toggle,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(10),
                  bottomRight: Radius.circular(10),
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
                          _categoryBadge(issue.category),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              issue.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          _confidenceBadge(issue.confidence),
                          if (widget.locatable) ...[
                            const SizedBox(width: 4),
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: Checkbox(
                                value: widget.highlighted,
                                onChanged: (v) =>
                                    widget.onHighlightChanged?.call(v ?? false),
                                side: const BorderSide(
                                  color: Color(0xFF6B7280),
                                  width: 1.5,
                                ),
                                activeColor: const Color(0xFF3B82F6),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ],
                        ],
                      ),

                      // Debug mode disclaimer
                      if (issue.debugModeDisclaimer)
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            '[DEBUG MODE — verify in profile]',
                            style: TextStyle(
                              color: Color(0xFFFCD34D),
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
                          style: const TextStyle(
                            color: Color(0xFFD1D5DB),
                            fontSize: 11,
                          ),
                        ),
                        if (issue.routeName != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Route: ${issue.routeName}',
                              style: const TextStyle(
                                color: Color(0xFF9CA3AF),
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
                              style: const TextStyle(
                                color: Color(0xFF9CA3AF),
                                fontSize: 10,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        if (issue.ancestorChain != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'Widget: ${issue.ancestorChain}',
                              style: const TextStyle(
                                color: Color(0xFF9CA3AF),
                                fontSize: 10,
                                fontStyle: FontStyle.italic,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        if (issue.ancestorChain == null &&
                            issue.widgetName != null &&
                            !issue.title.contains(issue.widgetName!))
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'Widget: ${issue.widgetName}',
                              style: const TextStyle(
                                color: Color(0xFF9CA3AF),
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
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontSize: 9,
                                fontStyle: FontStyle.italic,
                              ),
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
                                    color: const Color(0xFF065F46),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'Attribution: high fidelity',
                                    style: TextStyle(
                                      color: Color(0xFF6EE7B7),
                                      fontSize: 9,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF78350F),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'Timing: overhead present',
                                    style: TextStyle(
                                      color: Color(0xFFFCD34D),
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
                            color: const Color(0xFF1F2937),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('\u{1F4A1}',
                                  style: TextStyle(fontSize: 12)),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  issue.fixHint,
                                  style: const TextStyle(
                                    color: Color(0xFF93C5FD),
                                    fontSize: 11,
                                  ),
                                ),
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
          ],
        ),
      ),
    );
  }

  Color _sourceAccentColor(ObservationSource? source) {
    return switch (source) {
      ObservationSource.vmTimeline => const Color(0xFF10B981),
      ObservationSource.debugCallback => const Color(0xFF8B5CF6),
      ObservationSource.debugCallbackAndStructural => const Color(0xFF8B5CF6),
      ObservationSource.structural => const Color(0xFF6B7280),
      null => const Color(0xFF4B5563),
    };
  }

  Widget _categoryBadge(IssueCategory category) {
    final (label, color) = switch (category) {
      IssueCategory.build => ('BUILD', const Color(0xFF3B82F6)),
      IssueCategory.layout => ('LAYOUT', const Color(0xFFF59E0B)),
      IssueCategory.paint => ('PAINT', const Color(0xFF10B981)),
      IssueCategory.raster => ('RASTER', const Color(0xFFEF4444)),
      IssueCategory.memory => ('MEMORY', const Color(0xFF8B5CF6)),
      IssueCategory.channel => ('CHANNEL', const Color(0xFF06B6D4)),
      IssueCategory.font => ('FONT', const Color(0xFF6B7280)),
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

  Widget _confidenceBadge(IssueConfidence confidence) {
    final (label, color) = switch (confidence) {
      IssueConfidence.confirmed => ('CONFIRMED', const Color(0xFF10B981)),
      IssueConfidence.likely => ('LIKELY', const Color(0xFFF59E0B)),
      IssueConfidence.possible => ('POSSIBLE', const Color(0xFF6B7280)),
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

extension on ObservationSource {
  String get _displayName => switch (this) {
        ObservationSource.structural => 'structural scan',
        ObservationSource.vmTimeline => 'VM timeline',
        ObservationSource.debugCallback => 'debug callback',
        ObservationSource.debugCallbackAndStructural =>
          'debug callback + structural',
      };
}
