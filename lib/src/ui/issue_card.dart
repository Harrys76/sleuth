import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../models/performance_issue.dart';
import '../models/recurrence_trend.dart';
import '../utils/issue_metadata_builder.dart';
import 'motion.dart';
import 'sleuth_listenable_builder.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

/// A card displaying a single performance issue.
///
/// - Tap to expand/collapse detail + fix hint.
/// - Checkbox (when locatable) to highlight the widget on screen.
/// - Long-press the title, or tap Copy when expanded, to copy the details.
/// - Hide (when expanded) removes the card from the overlay.
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
    this.parentIssues,
    this.suppressedParentCount = 0,
    this.recurrenceTrend,
    this.recurrenceTrendOf,
    this.scanTick,
    this.onLearnMore,
    this.onAskAi,
    this.onCopy,
    this.onHide,
    this.collapseEpoch = 0,
    this.isNew = false,
  }) : assert(
         suppressedParentCount >= 0,
         'suppressedParentCount must be >= 0; negative values produce '
         'incorrect "Caused by (N):" header counts',
       );

  final PerformanceIssue issue;

  /// Recurrence trend for this issue, used to render "Seen X/Y" badge.
  /// Null when the issue has no trend data (e.g. first scan).
  ///
  /// Fixed at build time. Prefer [recurrenceTrendOf] when the trend
  /// changes between rebuilds of the parent.
  final RecurrenceTrend? recurrenceTrend;

  /// Live source for the "Seen X/Y" badge. Called on every [scanTick]
  /// notification, so the badge tracks the latest trend without the
  /// parent list rebuilding. Takes precedence over [recurrenceTrend]
  /// when it returns non-null.
  final RecurrenceTrend? Function()? recurrenceTrendOf;

  /// Fires once per completed scan. Only the recurrence badge listens.
  final Listenable? scanTick;

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

  /// Resolved upstream root-cause issues, rendered in a "Caused by" section
  /// when non-empty. Sorted severity desc → stableId asc by the resolver.
  /// Null or empty for issues that are roots themselves or whose parents
  /// are all suppressed by the ranker.
  final List<PerformanceIssue>? parentIssues;

  /// Count of upstream root causes that exist in the issue's
  /// `rootCauseIds` annotation but were NOT resolved into [parentIssues]
  /// (e.g., dropped by the ranker upstream of the overlay). Renders as
  /// "(+N not shown)" in the "Caused by" section so a partial parent list
  /// does not silently look complete. Zero when every parent resolved.
  final int suppressedParentCount;

  /// Called when the user taps "Learn more" — navigates to the full-screen
  /// detail page. Null hides the link (e.g. for custom detector issues).
  final VoidCallback? onLearnMore;

  /// Called when the user taps "Ask AI" — opens contextual AI chat.
  /// Null hides the link (e.g. when no [AiChatAdapter] is configured).
  final VoidCallback? onAskAi;

  /// Copies the issue details. Fired by the Copy action and by a
  /// long-press on the title. Null hides the action and disables the
  /// long-press.
  final VoidCallback? onCopy;

  /// Hides the card from the overlay. The card collapses through
  /// [onExpandedChanged] before this fires. Null hides the action.
  final VoidCallback? onHide;

  /// Host-driven collapse: when this changes while the card is expanded,
  /// the card collapses without calling [onExpandedChanged] (the host has
  /// already dropped its expansion entry).
  final int collapseEpoch;

  /// The card just entered the list: its source accent is painted twice
  /// as wide over the content edge, and the card's semantics carry the
  /// hint "New".
  final bool isNew;

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

  @override
  void didUpdateWidget(covariant IssueCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The host cleared every expansion entry itself; collapse to match
    // without reporting back.
    if (oldWidget.collapseEpoch != widget.collapseEpoch && _expanded) {
      _expanded = false;
      _aboutExpanded = false;
    }
  }

  /// Collapses through [_toggle] (so the host drops its expansion entry
  /// first), then hides.
  void _hide() {
    if (_expanded) _toggle();
    widget.onHide?.call();
  }

  /// Badge text follows the system text size up to the chrome limit.
  TextScaler _badgeScaler(BuildContext context) => clampTextScaler(
    MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
    max: kChromeMaxTextScale,
  );

  void _toggleAbout() => setState(() => _aboutExpanded = !_aboutExpanded);

  /// Narrowest title that keeps the category and confidence badges beside
  /// it.
  static const double _minInlineTitleWidth = 96;

  /// Width the title row takes besides the title when the category and
  /// confidence badges are inline: the measured badges and severity
  /// glyph, the pin (reserved while collapsed so expanding does not move
  /// the badges), the highlight checkbox and the gaps.
  double _inlineBadgesWidth(BuildContext context, SleuthThemeData theme) {
    final scaler = _badgeScaler(context);
    final base = DefaultTextStyle.of(context).style;
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final badgeStyle = TextStyle(
      fontSize: theme.fontXxs,
      fontWeight: FontWeight.bold,
    );
    final issue = widget.issue;
    // Text plus padding and the 1 px border on each side.
    final category =
        measure(_categoryLabel(issue.category), badgeStyle) +
        2 * theme.spacingXs +
        2;
    final confidence =
        measure(_confidenceLabel(issue.confidence), badgeStyle) +
        2 * theme.spacingSm +
        2;
    final glyph = measure('\u{1F534}', TextStyle(fontSize: theme.fontBase));
    const pin = 14.0;
    final checkbox = widget.locatable ? 48 + theme.spacingXs : 0.0;
    return glyph +
        theme.spacingXs +
        category +
        theme.spacingXs +
        theme.spacingXs +
        confidence +
        theme.spacingXs +
        pin +
        checkbox;
  }

  /// Toggle expansion and notify the host.
  ///
  /// **Invariant:** every mutation of [_expanded] must route through this
  /// method. The freeze-above-on-expand contract in [FloatingIssuesCard]
  /// relies on [onExpandedChanged] firing on every state flip — a future
  /// "collapse all" or per-card auto-collapse that sets `_expanded =
  /// false` directly without calling the callback would leak entries in
  /// the host's `_expandedIndices` map. If you add such a feature, route
  /// it through `_toggle` or a sibling that fires the callback. The one
  /// exception is [collapseEpoch]: there the host has already cleared
  /// every entry.
  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (!_expanded) _aboutExpanded = false;
    });
    widget.onExpandedChanged?.call(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final issue = widget.issue;
    // One button node per card, labelled with the title: tap toggles,
    // long press copies. Children (badges, checkbox, actions) keep their
    // own nodes.
    return Semantics(
      container: true,
      button: true,
      expanded: _expanded,
      label: issue.title,
      hint: widget.isNew ? 'New' : null,
      onTap: _toggle,
      onLongPress: widget.onCopy,
      onLongPressHint: widget.onCopy == null ? null : 'Copy details',
      // VoiceOver has no long press; the custom action copies there.
      customSemanticsActions: widget.onCopy == null
          ? null
          : {
              const CustomSemanticsAction(label: 'Copy details'):
                  widget.onCopy!,
            },
      explicitChildNodes: true,
      child: Card(
        color: widget.jankFlash
            ? theme.cardJankFlash
            : widget.highlighted
            ? theme.cardHighlighted
            : theme.cardDefault,
        margin: EdgeInsets.only(bottom: theme.spacingSm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(theme.radiusXl),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _toggle,
          // The card's Semantics node carries the tap.
          excludeFromSemantics: true,
          borderRadius: BorderRadius.circular(theme.radiusXl),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: theme.sourceAccentColor(issue.observationSource),
                  width: theme.sourceAccentWidth,
                ),
              ),
            ),
            // A new card's wider accent paints over the content edge, so
            // the layout does not move when it fades.
            foregroundDecoration: widget.isNew
                ? BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: theme.sourceAccentColor(issue.observationSource),
                        width: theme.sourceAccentWidth * 2,
                      ),
                    ),
                  )
                : null,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: LayoutBuilder(
                builder: (context, constraints) => _buildBody(
                  context,
                  theme,
                  issue,
                  // The category and confidence badges sit beside the title
                  // while the title keeps its minimum width; with large
                  // text or a narrow card they move to the badge line.
                  inlineBadges:
                      textScaleOf(context) <= kChromeMaxTextScale &&
                      constraints.maxWidth -
                              _inlineBadgesWidth(context, theme) >=
                          _minInlineTitleWidth,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    SleuthThemeData theme,
    PerformanceIssue issue, {
    required bool inlineBadges,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title row: severity, category, title, pin, checkbox.
        Row(
          children: [
            _severityIcon(issue.severity, theme),
            SizedBox(width: theme.spacingXs),
            if (inlineBadges) ...[
              _categoryBadge(issue.category, theme),
              SizedBox(width: theme.spacingXs),
            ],
            Expanded(
              child: GestureDetector(
                onLongPress: widget.onCopy,
                excludeFromSemantics: true,
                // The card's label is the title.
                child: ExcludeSemantics(
                  child: Text(
                    issue.title,
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: theme.fontBase,
                      fontWeight: FontWeight.w600,
                    ),
                    // Two lines once the text is large enough that
                    // one line shows only a few words.
                    maxLines: textScaleOf(context) > kChromeMaxTextScale
                        ? 2
                        : 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            if (inlineBadges)
              Padding(
                padding: EdgeInsets.only(left: theme.spacingXs),
                child: _confidenceBadge(
                  issue.confidence,
                  theme,
                  issue.confidenceReason,
                ),
              ),
            // Freeze-above pin indicator (v0.15.5). The icon only
            // renders when the card is expanded, but the Semantics
            // node is unconditional so TalkBack / VoiceOver
            // traversal order and focus don't shift when the user
            // toggles expansion. When collapsed,
            // `excludeSemantics: true` silences the empty-label
            // branch so the node has no audible text.
            Semantics(
              label: _expanded ? 'Pinned while expanded' : '',
              excludeSemantics: !_expanded,
              child: _expanded
                  ? Padding(
                      padding: EdgeInsets.only(left: theme.spacingXs),
                      child: Icon(
                        Icons.push_pin,
                        size: 14,
                        color: theme.textSecondary.withValues(
                          alpha: theme.badgeFillAlpha >= 1 ? 1 : 0.55,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            if (widget.locatable) ...[
              SizedBox(width: theme.spacingXs),
              Semantics(
                container: true,
                child: Semantics(
                  label: 'Highlight widget on screen',
                  child: Checkbox(
                    value: widget.highlighted,
                    onChanged: (v) =>
                        widget.onHighlightChanged?.call(v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    side: BorderSide(color: theme.textQuaternary, width: 1.5),
                    activeColor: theme.checkboxActive,
                    checkColor: SleuthThemeData.onColor(theme.checkboxActive),
                  ),
                ),
              ),
            ],
          ],
        ),

        // Badge line: category and confidence (when not beside the
        // title),
        // JANK, downstream count and the recurrence badge, wrapping
        // when the card is narrow. Only this subtree listens to the
        // scan pulse.
        if (widget.scanTick != null)
          SleuthListenableBuilder(
            listenable: widget.scanTick!,
            builder: (context) =>
                _badgeLine(context, theme, issue, inlineBadges),
          )
        else
          _badgeLine(context, theme, issue, inlineBadges),

        // Debug mode disclaimer
        if (issue.debugModeDisclaimer)
          Padding(
            padding: EdgeInsets.only(top: theme.spacingXs),
            child: Text(
              '[DEBUG MODE — verify in profile]',
              style: TextStyle(
                color: theme.disclaimerText,
                fontSize: theme.fontXs,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),

        // Expanded detail + fix hint. Each block is its own semantics
        // node: plain text would merge into the card's button label and
        // a screen reader would read the whole body as one utterance.
        if (_expanded)
          for (final block in _buildExpandedContent(issue, theme))
            if (block is SizedBox)
              block
            else
              Semantics(container: true, child: block),
      ],
    );
  }

  /// Badges below the title; nothing when there are none.
  Widget _badgeLine(
    BuildContext context,
    SleuthThemeData theme,
    PerformanceIssue issue,
    bool inlineBadges,
  ) {
    final trend = _currentTrend();
    final downstream = widget.downstreamIssues;
    final children = [
      if (!inlineBadges) ...[
        _categoryBadge(issue.category, theme),
        _confidenceBadge(issue.confidence, theme, issue.confidenceReason),
      ],
      if (widget.jankCorrelated)
        _badge(
          theme: theme,
          accent: theme.severityCritical,
          tintedText: theme.severityCriticalText,
          label: 'JANK',
          textScaler: _badgeScaler(context),
        ),
      if (downstream != null && downstream.isNotEmpty)
        _badge(
          theme: theme,
          accent: theme.effectsBadge,
          label: '\u21B3 ${downstream.length}',
          textScaler: _badgeScaler(context),
        ),
      if (trend != null && trend.length >= 2) _recurrenceBadge(trend, theme),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: theme.spacingXs),
      child: Wrap(
        spacing: theme.spacingXs,
        runSpacing: theme.spacingXs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      ),
    );
  }

  List<Widget> _buildExpandedContent(
    PerformanceIssue issue,
    SleuthThemeData theme,
  ) {
    return [
      SizedBox(height: theme.spacingMd),
      Text(
        issue.detail,
        style: TextStyle(color: theme.textSecondary, fontSize: theme.fontMd),
      ),
      if (issue.routeDisplayName != null)
        Padding(
          padding: EdgeInsets.only(top: theme.spacingXs),
          child: Text(
            'Route: ${issue.routeDisplayName}',
            style: TextStyle(
              color: theme.textTertiary,
              fontSize: theme.fontSm,
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
              fontSize: theme.fontSm,
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
              fontSize: theme.fontSm,
              fontStyle: FontStyle.italic,
            ),
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
              fontSize: theme.fontSm,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      if (issue.observationSource != null)
        Padding(
          padding: EdgeInsets.only(top: theme.spacingXxs),
          child: Text(
            'Source: ${issue.observationSource!.displayName}',
            style: TextStyle(
              color: theme.textQuaternary,
              fontSize: theme.fontXs,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      // Confidence reasoning (promoted from tooltip to visible text)
      if (issue.confidenceReason != null)
        Padding(
          padding: EdgeInsets.only(top: theme.spacingXs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _confidenceIcon(issue.confidence),
                size: 12,
                color: theme.textSecondary,
              ),
              SizedBox(width: theme.spacingXs),
              Expanded(
                child: Text(
                  issue.confidenceReason!,
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: theme.fontMd,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
      // Caused by section (multi-parent causal graph). Renders above
      // Related effects so users see "what caused this" before "what this
      // causes" in the chain.
      if ((widget.parentIssues != null && widget.parentIssues!.isNotEmpty) ||
          widget.suppressedParentCount > 0)
        _causedBySection(theme),
      // Downstream effects section (causal graph)
      if (widget.downstreamIssues != null &&
          widget.downstreamIssues!.isNotEmpty)
        _downstreamSection(theme),
      // "About this detection" collapsible section, 48 px tall.
      Semantics(
        container: true,
        button: true,
        expanded: _aboutExpanded,
        label: 'About this detection',
        onTap: _toggleAbout,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: _toggleAbout,
          behavior: HitTestBehavior.opaque,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                Icon(
                  _aboutExpanded ? Icons.expand_less : Icons.expand_more,
                  color: theme.textQuaternary,
                  size: 14,
                ),
                SizedBox(width: theme.spacingXs),
                Flexible(
                  child: Text(
                    'About this detection',
                    style: TextStyle(
                      color: theme.textQuaternary,
                      fontSize: theme.fontXs,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      if (_aboutExpanded)
        Container(
          margin: EdgeInsets.only(top: theme.spacingXs),
          padding: EdgeInsets.all(theme.spacingMd),
          decoration: BoxDecoration(
            color: theme.aboutBackground,
            borderRadius: BorderRadius.circular(theme.radiusMd),
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
                            fontSize: theme.fontXs,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextSpan(
                          text: entry.$2,
                          style: TextStyle(
                            color: theme.textTertiary,
                            fontSize: theme.fontXs,
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
          child: Wrap(
            spacing: theme.spacingXs,
            runSpacing: theme.spacingXxs,
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: theme.spacingXs,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: theme.bannerSuccessBg,
                  borderRadius: BorderRadius.circular(theme.radiusSm),
                ),
                child: Text(
                  'Attribution: high fidelity',
                  style: TextStyle(
                    color: theme.bannerSuccessText,
                    fontSize: theme.fontXs,
                  ),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: theme.spacingXs,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: theme.bannerWarningBg,
                  borderRadius: BorderRadius.circular(theme.radiusSm),
                ),
                child: Text(
                  'Timing: overhead present',
                  style: TextStyle(
                    color: theme.bannerWarningText,
                    fontSize: theme.fontXs,
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
          borderRadius: BorderRadius.circular(theme.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _effortBadge(issue, theme),
            SizedBox(height: theme.spacingXs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Text(
                    '\u{1F4A1}',
                    style: TextStyle(fontSize: theme.fontBase),
                  ),
                ),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    issue.fixHint,
                    style: TextStyle(
                      color: theme.fixHintText,
                      fontSize: theme.fontMd,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      if (widget.onCopy != null ||
          widget.onHide != null ||
          widget.onLearnMore != null ||
          widget.onAskAi != null)
        Padding(
          padding: EdgeInsets.only(top: theme.spacingXs),
          // One row: the links at the start, Copy and Hide at the end. On
          // a narrow card or at large text the icons take a second row,
          // and the links wrap onto their own rows, all starting at the
          // same edge.
          child: SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.onLearnMore != null || widget.onAskAi != null)
                  Wrap(
                    spacing: theme.spacingLg,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (widget.onLearnMore != null)
                        _buildLearnMoreLink(theme),
                      if (widget.onAskAi != null)
                        _AskAiShimmerLink(onTap: widget.onAskAi!),
                    ],
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onCopy != null)
                      _actionIcon(
                        icon: Icons.copy,
                        label: 'Copy issue details',
                        onTap: widget.onCopy!,
                        theme: theme,
                      ),
                    if (widget.onHide != null)
                      _actionIcon(
                        icon: Icons.visibility_off_outlined,
                        label: 'Hide this issue',
                        onTap: _hide,
                        theme: theme,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ];
  }

  /// 48 dp icon action in the expanded card's action row.
  Widget _actionIcon({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required SleuthThemeData theme,
  }) {
    return Semantics(
      label: label,
      button: true,
      onTap: onTap,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(child: Icon(icon, color: theme.textTertiary, size: 16)),
        ),
      ),
    );
  }

  Widget _buildLearnMoreLink(SleuthThemeData theme) {
    return _linkHitBox(
      label: 'Learn more about this issue',
      onTap: widget.onLearnMore!,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined, color: theme.textSecondary, size: 13),
          SizedBox(width: theme.spacingXs),
          Flexible(
            child: Text(
              // The button's semantics label carries the full name.
              'Learn more',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: theme.fontXs,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _causedBySection(SleuthThemeData theme) {
    final parents = widget.parentIssues ?? const <PerformanceIssue>[];
    final suppressed = widget.suppressedParentCount;
    final totalParents = parents.length + suppressed;
    final visibleCount = parents.length > 5 ? 5 : parents.length;
    final overflow = parents.length - visibleCount;

    return Padding(
      padding: EdgeInsets.only(top: theme.spacingSm),
      child: Container(
        padding: EdgeInsets.all(theme.spacingMd),
        decoration: BoxDecoration(
          color: theme.aboutBackground,
          borderRadius: BorderRadius.circular(theme.radiusMd),
        ),
        child: Semantics(
          label:
              '$totalParents '
              '${totalParents == 1 ? "cause" : "causes"} for this issue',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Caused by ($totalParents):',
                style: TextStyle(
                  color: theme.textSecondary,
                  fontSize: theme.fontSm,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: theme.spacingXs),
              for (var i = 0; i < visibleCount; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    children: [
                      _severityIcon(parents[i].severity, theme),
                      SizedBox(width: theme.spacingXs),
                      _categoryBadge(parents[i].category, theme),
                      SizedBox(width: theme.spacingXs),
                      Expanded(
                        child: Text(
                          parents[i].title,
                          style: TextStyle(
                            color: theme.textTertiary,
                            fontSize: theme.fontSm,
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
                      fontSize: theme.fontXs,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              if (suppressed > 0)
                Padding(
                  padding: EdgeInsets.only(top: theme.spacingXxs),
                  child: Text(
                    '(+$suppressed not shown)',
                    style: TextStyle(
                      color: theme.textQuaternary,
                      fontSize: theme.fontXs,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _downstreamSection(SleuthThemeData theme) {
    final downstream = widget.downstreamIssues!;
    final visibleCount = downstream.length > 5 ? 5 : downstream.length;
    final overflow = downstream.length - visibleCount;

    return Padding(
      padding: EdgeInsets.only(top: theme.spacingSm),
      child: Container(
        padding: EdgeInsets.all(theme.spacingMd),
        decoration: BoxDecoration(
          color: theme.aboutBackground,
          borderRadius: BorderRadius.circular(theme.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Related effects (${downstream.length}):',
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: theme.fontSm,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: theme.spacingXs),
            for (var i = 0; i < visibleCount; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    _severityIcon(downstream[i].severity, theme),
                    SizedBox(width: theme.spacingXs),
                    _categoryBadge(downstream[i].category, theme),
                    SizedBox(width: theme.spacingXs),
                    Expanded(
                      child: Text(
                        downstream[i].title,
                        style: TextStyle(
                          color: theme.textTertiary,
                          fontSize: theme.fontSm,
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
                    fontSize: theme.fontXs,
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

  static String _categoryLabel(IssueCategory category) => switch (category) {
    IssueCategory.build => 'BUILD',
    IssueCategory.layout => 'LAYOUT',
    IssueCategory.paint => 'PAINT',
    IssueCategory.raster => 'RASTER',
    IssueCategory.memory => 'MEMORY',
    IssueCategory.channel => 'CHANNEL',
    IssueCategory.font => 'FONT',
    IssueCategory.network => 'NETWORK',
    IssueCategory.startup => 'STARTUP',
  };

  static String _confidenceLabel(IssueConfidence confidence) =>
      switch (confidence) {
        IssueConfidence.confirmed => 'CONFIRMED',
        IssueConfidence.likely => 'LIKELY',
        IssueConfidence.possible => 'POSSIBLE',
      };

  Widget _categoryBadge(IssueCategory category, SleuthThemeData theme) {
    return _badge(
      theme: theme,
      accent: theme.categoryColor(category),
      label: _categoryLabel(category),
      textScaler: _badgeScaler(context),
    );
  }

  /// Severity dot. Announced as the severity name; the emoji is not read.
  Widget _severityIcon(IssueSeverity severity, SleuthThemeData theme) {
    final (glyph, name) = switch (severity) {
      IssueSeverity.critical => ('\u{1F534}', 'critical'),
      IssueSeverity.warning => ('\u{1F7E1}', 'warning'),
      IssueSeverity.ok => ('\u{1F7E2}', 'ok'),
    };
    return Semantics(
      label: name,
      excludeSemantics: true,
      child: Text(
        glyph,
        style: TextStyle(fontSize: theme.fontBase),
        textScaler: _badgeScaler(context),
      ),
    );
  }

  /// Renders the "Seen X/Y · {label}" recurrence badge.
  ///
  /// The badge shows how often an issue has fired across Sleuth's scan cycles
  /// and qualitatively describes the trend. Shown once the trend ring buffer
  /// has at least 2 entries (see the call site's `trend.length >= 2` guard).
  ///
  /// **`Seen X/Y` semantics**
  /// - **X** is [RecurrenceTrend.presentCount] — scan cycles where this
  ///   issue was observed.
  /// - **Y** is [RecurrenceTrend.length] — total scan cycles the ring buffer
  ///   has data for (capacity defaults to 60, oldest evicted).
  ///
  /// **Label mapping** (`TrendDirection` → user-facing label):
  /// - `worsening` → **worsening** (red) — severity is rising over the
  ///   recent window.
  /// - `stable` with `presentCount / length >= 0.9` → **persistent** (amber)
  ///   — sticky issue that fires almost every cycle. Synthesised here, not
  ///   in the enum.
  /// - `stable` otherwise → **stable** (neutral).
  /// - `improving` → **improving** (green) — severity is falling.
  /// - `intermittent` → **flaky** (neutral) — issue toggles present/absent
  ///   `>= 3` times inside the recent window. The enum value says
  ///   `intermittent`; the badge says `flaky` because it reads better.
  ///
  /// See [RecurrenceTrend.computeTrend] for the underlying window (default
  /// 10 entries) and the `± 0.3` severity-delta thresholds.
  RecurrenceTrend? _currentTrend() =>
      widget.recurrenceTrendOf?.call() ?? widget.recurrenceTrend;

  Widget _recurrenceBadge(RecurrenceTrend trend, SleuthThemeData theme) {
    final present = trend.presentCount;
    final total = trend.length;
    final ratio = total == 0 ? 0.0 : present / total;
    // NOTE: The UI labels here are the documented surface — if you rename
    // a label, update the table in `RecurrenceTrend`'s enum dartdoc and the
    // "Recurrence Badge" section of README.md to match.
    final (label, color, text) = switch (trend.trend) {
      TrendDirection.worsening => (
        'worsening',
        theme.severityCritical,
        theme.severityCriticalText,
      ),
      TrendDirection.stable when ratio >= 0.9 => (
        'persistent',
        theme.severityWarning,
        theme.severityWarningText,
      ),
      TrendDirection.stable => (
        'stable',
        theme.textSecondary,
        theme.textSecondary,
      ),
      TrendDirection.improving => (
        'improving',
        theme.severityOk,
        theme.severityOkText,
      ),
      TrendDirection.intermittent => (
        'flaky',
        theme.textSecondary,
        theme.textSecondary,
      ),
    };
    return _badge(
      theme: theme,
      accent: color,
      tintedText: text,
      label: 'Seen $present/$total \u00B7 $label',
      textScaler: _badgeScaler(context),
    );
  }

  Widget _effortBadge(PerformanceIssue issue, SleuthThemeData theme) {
    final (label, color) = _fixEffort(issue, theme);
    return _badge(
      theme: theme,
      accent: color,
      label: label,
      textScaler: _badgeScaler(context),
    );
  }

  IconData _confidenceIcon(IssueConfidence c) => switch (c) {
    IssueConfidence.confirmed => Icons.check_circle_outline,
    IssueConfidence.likely => Icons.help_outline,
    IssueConfidence.possible => Icons.info_outline,
  };

  Widget _confidenceBadge(
    IssueConfidence confidence,
    SleuthThemeData theme,
    String? reason,
  ) {
    final color = theme.confidenceColor(confidence);
    final label = _confidenceLabel(confidence);

    final badge = _badge(
      theme: theme,
      accent: color,
      label: label,
      horizontalPadding: theme.spacingSm,
      verticalPadding: theme.spacingXxs,
      radius: theme.radiusLg,
      textScaler: _badgeScaler(context),
    );

    // Confidence reasoning is shown inline when expanded, so no Tooltip
    // needed. Tooltip also crashes in the Sleuth overlay's bare Overlay widget
    // (no Navigator → no _RenderTheaterMarker for OverlayPortal).
    if (reason == null) return badge;
    return Semantics(
      label: '$label: $reason',
      excludeSemantics: true,
      child: badge,
    );
  }
}

/// Badge with [label] on a [SleuthThemeData.badgeFill] of [accent] and a
/// 1 px [accent] border. Text is [tintedText] (default `textPrimary`) over
/// a translucent fill, black or white over an opaque one.
Widget _badge({
  required SleuthThemeData theme,
  required Color accent,
  required String label,
  Color? tintedText,
  double? horizontalPadding,
  double verticalPadding = 0,
  double? radius,
  TextScaler? textScaler,
}) {
  return DecoratedBox(
    decoration: BoxDecoration(
      color: theme.badgeFill(accent),
      borderRadius: BorderRadius.circular(radius ?? theme.radiusSm),
      border: Border.all(color: accent),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding ?? theme.spacingXs,
        vertical: verticalPadding,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: theme.badgeTextOn(accent, tinted: tintedText),
          fontSize: theme.fontXxs,
          fontWeight: FontWeight.bold,
        ),
        textScaler: textScaler,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

bool _isDebugCallbackSource(ObservationSource? source) =>
    source == ObservationSource.debugCallback ||
    source == ObservationSource.debugCallbackAndStructural;

/// Returns (label, color) for the effort badge.
/// Prefers explicit [FixEffort] from the model; falls back to keyword
/// inference for legacy issues deserialized without the field.
(String, Color) _fixEffort(PerformanceIssue issue, SleuthThemeData theme) {
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
    'sksl',
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

/// A text link with a hit box of at least 48 x 48 and one semantics node
/// labelled [label].
Widget _linkHitBox({
  required String label,
  required VoidCallback onTap,
  required Widget child,
}) {
  return Semantics(
    label: label,
    button: true,
    onTap: onTap,
    container: true,
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          heightFactor: 1,
          child: child,
        ),
      ),
    ),
  );
}

/// "Ask AI" link: [SleuthThemeData.textSecondary] text beside a sparkle
/// icon that a purple-blue-pink gradient sweeps across.
///
/// The text stays a solid token, readable on every card fill; the
/// shimmer is decoration on the icon only. Owns its own
/// [AnimationController] so the shimmer only runs while this widget is
/// in the tree (card expanded + onAskAi configured), and the icon has
/// its own [RepaintBoundary] so a tick repaints the icon alone.
class _AskAiShimmerLink extends StatefulWidget {
  const _AskAiShimmerLink({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_AskAiShimmerLink> createState() => _AskAiShimmerLinkState();
}

class _AskAiShimmerLinkState extends State<_AskAiShimmerLink>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  /// iOS Reduce Motion does not change [MediaQueryData], so a flip of it
  /// arrives here rather than through [didChangeDependencies].
  @override
  void didChangeAccessibilityFeatures() {
    if (mounted) _syncMotion();
  }

  /// `repeat()` is not shortened by the reduce-motion setting, so the
  /// sweep stops and the gradient rests at its midpoint.
  void _syncMotion() {
    if (reducedMotionOf(context)) {
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return _linkHitBox(
      label: 'Ask AI about this issue',
      onTap: widget.onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                // The gradient is one icon wide (2 alignment units) and
                // travels from -3 to +3, so the sweep enters and leaves
                // off the icon.
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
              child: const Icon(Icons.auto_awesome, size: 13),
            ),
          ),
          SizedBox(width: theme.spacingXs),
          Flexible(
            child: Text(
              // The button's semantics label carries the full name.
              'Ask AI',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: theme.fontXs,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
