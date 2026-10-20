import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart'
    show CustomSemanticsAction, FocusSemanticEvent;

import '../models/issue_measurement.dart';
import '../models/performance_issue.dart';
import '../models/recurrence_trend.dart';
import 'focus_ink_well.dart';
import 'issue_card_details.dart';
import 'motion.dart';
import 'severity_icon.dart';
import 'sleuth_listenable_builder.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

/// A card displaying a single performance issue.
///
/// - Tap to expand or collapse. Expanded, it shows [IssueCardDetails]:
///   the measured value, where and when the issue was seen, the evidence,
///   related cards, the fix and labelled buttons.
/// - The crosshair (when the issue names a widget) outlines the widget on
///   screen.
/// - Long-press the title, or tap Copy details when expanded, to copy the
///   details.
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
    this.jankCorrelated = false,
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
    this.stale = false,
    this.lastSeenOf,
    this.relatedLinkOf,
    this.onOpenRelated,
    this.onSeeRebuildStats,
    this.rebuildStatsTotal,
    this.onSeeStartup,
    this.whyItRebuilds = false,
    this.rebuildCauseOf,
    this.onCopyText,
    this.notUseful = false,
    this.onNotUsefulChanged,
    this.revealEpoch = 0,
    this.revealInline,
    this.onRevealed,
    this.focusEpoch = 0,
    this.onFocused,
  }) : assert(
         suppressedParentCount >= 0,
         'suppressedParentCount must be at least 0. A negative value '
         'produces an incorrect "Caused by (N):" header count.',
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

  /// Fires once per completed scan. The meta line and, while expanded,
  /// the When and Why it rebuilds rows listen.
  final Listenable? scanTick;

  /// Seed value — read once in [initState]. After that, internal state owns it.
  final bool initiallyExpanded;

  /// Notifies parent so it can persist expansion across card destruction.
  final ValueChanged<bool>? onExpandedChanged;

  final bool locatable;
  final bool highlighted;
  final ValueChanged<bool>? onHighlightChanged;

  /// When true, shows a "JANK" badge in the collapsed header: this issue
  /// can explain the phase of a jank frame from the last 10 s, and jank
  /// is still reported.
  final bool jankCorrelated;

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

  /// The card just entered the list: the meta line leads with a New tag
  /// and the card's semantics carry the hint "New".
  final bool isNew;

  /// The issue is no longer reported. The host keeps an expanded card
  /// until it is collapsed; its meta line leads with "Not detected right
  /// now".
  final bool stale;

  /// When the issue was last in a scan's results, for the When row.
  final DateTime? Function()? lastSeenOf;

  /// How each Caused by and Effects row opens; null shows them as text.
  final RelatedLink Function(PerformanceIssue)? relatedLinkOf;

  /// Opens a related card that [relatedLinkOf] marks [RelatedLink.open].
  final ValueChanged<PerformanceIssue>? onOpenRelated;

  /// Opens Rebuild stats; null leaves out the link.
  final VoidCallback? onSeeRebuildStats;

  /// The screen's rebuild count shown in the Rebuild stats link.
  final int? rebuildStatsTotal;

  /// Opens Startup metrics; null leaves out the link.
  final VoidCallback? onSeeStartup;

  /// Shows the Why it rebuilds row (debug runs, rebuild and setState
  /// cards).
  final bool whyItRebuilds;

  /// The latest rebuild split for the row; null when debug callbacks are
  /// off.
  final RebuildCause? Function()? rebuildCauseOf;

  /// Copies text from the card (a location, a code block) and confirms.
  final void Function(String text, String confirmation)? onCopyText;

  /// The user marked the issue not useful.
  final bool notUseful;

  /// Marks or unmarks the issue; null leaves out the Not useful button.
  final ValueChanged<bool>? onNotUsefulChanged;

  /// Bumped by the host to open this card from a related row: the card
  /// expands (the host has already recorded it), scrolls into view and
  /// takes focus, then calls [onRevealed].
  final int revealEpoch;

  /// A related issue folded under this card that the reveal opens inline.
  final PerformanceIssue? revealInline;

  /// Tells the host the reveal started, with the scroll's future: the host
  /// keeps the list built until it completes, and a rebuilt card does not
  /// repeat the reveal.
  final ValueChanged<Future<void>>? onRevealed;

  /// Bumped by the host to move focus to this card without expanding it,
  /// as after the card above it was hidden. [onFocused] follows.
  final int focusEpoch;
  final ValueChanged<Future<void>>? onFocused;

  @override
  State<IssueCard> createState() => _IssueCardState();
}

class _IssueCardState extends State<IssueCard> {
  late bool _expanded;
  final FocusNode _focus = FocusNode(debugLabel: 'IssueCard');

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
    if (widget.revealEpoch > 0) _reveal();
    if (widget.focusEpoch > 0) _takeFocus();
  }

  @override
  void didUpdateWidget(covariant IssueCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The host cleared every expansion entry itself; collapse to match
    // without reporting back.
    if (oldWidget.collapseEpoch != widget.collapseEpoch && _expanded) {
      _expanded = false;
    }
    if (widget.revealEpoch != oldWidget.revealEpoch && widget.revealEpoch > 0) {
      _expanded = true;
      _reveal();
    }
    if (widget.focusEpoch != oldWidget.focusEpoch && widget.focusEpoch > 0) {
      _takeFocus();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _reveal() => _bringIntoView(widget.onRevealed);

  void _takeFocus() => _bringIntoView(widget.onFocused);

  /// After the next frame: scrolls the card into view, focuses it and
  /// moves the screen reader to it. [started] gets the scroll's future, so
  /// the host keeps the list built until the card is in view.
  void _bringIntoView(ValueChanged<Future<void>>? started) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scrolled = ensureVisibleWithMotion(
        context,
        context,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
      _focus.requestFocus();
      context.findRenderObject()?.sendSemanticsEvent(
        const FocusSemanticEvent(),
      );
      started?.call(scrolled);
    });
  }

  /// Collapses through [_toggle] (so the host drops its expansion entry
  /// first), then hides.
  void _hide() {
    if (_expanded) _toggle();
    widget.onHide?.call();
  }

  /// Toggle expansion and notify the host.
  ///
  /// **Invariant:** every mutation of [_expanded] must route through this
  /// method. The freeze-above-on-expand contract in [FloatingIssuesCard]
  /// relies on [onExpandedChanged] firing on every state flip — a future
  /// "collapse all" or per-card auto-collapse that sets `_expanded =
  /// false` directly without calling the callback would leave the card
  /// expanded in the host's frozen zone. If you add such a feature, route
  /// it through `_toggle` or a sibling that fires the callback. The one
  /// exception is [collapseEpoch]: there the host has already cleared
  /// every entry.
  void _toggle() {
    setState(() => _expanded = !_expanded);
    widget.onExpandedChanged?.call(_expanded);
  }

  /// Width the crosshair's hit box takes from the title row: 48 px less
  /// the card's 10 px padding, which the box reaches into.
  static const double _crosshairReserve = 38;

  /// The crosshair shows for an issue that names a widget.
  bool get _showsCrosshair =>
      widget.locatable &&
      widget.issue.widgetName != null &&
      widget.onHighlightChanged != null;

  /// Title lines while collapsed: 2, or 3 once the text is large enough
  /// that two lines hold only a few words. An expanded card shows it all.
  int? _titleLines(BuildContext context) => _expanded
      ? null
      : textScaleOf(context) > kChromeMaxTextScale
      ? 3
      : 2;

  /// Height of one title line at the current text scale, which places the
  /// severity icon and the crosshair on the first line.
  double _titleLineHeight(BuildContext context, SleuthThemeData theme) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'M',
        style: DefaultTextStyle.of(context).style.merge(_titleStyle(theme)),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  TextStyle _titleStyle(SleuthThemeData theme) => TextStyle(
    color: theme.textPrimary,
    fontSize: theme.fontLg,
    fontWeight: FontWeight.w600,
  );

  /// The severity icon's size: 16 px, growing with the text up to the
  /// chrome limit.
  double _iconSize(BuildContext context) =>
      16 * textScaleOf(context).clamp(1.0, kChromeMaxTextScale);

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final issue = widget.issue;
    final firstLine = _titleLineHeight(context, theme);
    final hints = [
      if (widget.isNew) 'New',
      // The pin icon is gone; the freeze-above order is still announced.
      if (_expanded) 'Pinned while expanded',
    ];
    // One button node per card, labelled with the title: tap toggles,
    // long press copies. Children (meta line, crosshair, actions) keep
    // their own nodes.
    return Semantics(
      container: true,
      button: true,
      expanded: _expanded,
      label: issue.title,
      hint: hints.isEmpty ? null : hints.join(', '),
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
        elevation: 0,
        color: widget.highlighted ? theme.cardHighlighted : theme.cardDefault,
        margin: EdgeInsets.only(bottom: theme.spacingSm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(theme.radiusXl),
        ),
        clipBehavior: Clip.antiAlias,
        // The crosshair sits in the card's Stack: a box inside the title
        // row could not take taps outside its own size.
        child: Stack(
          children: [
            SleuthFocusInkWell(
              onTap: _toggle,
              focusNode: _focus,
              // The card's Semantics node carries the tap.
              excludeFromSemantics: true,
              borderRadius: BorderRadius.circular(theme.radiusXl),
              builder: (context, showFocus) => SleuthFocusOutline(
                show: showFocus,
                color: theme.checkboxActive,
                borderRadius: BorderRadius.circular(theme.radiusXl),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: LayoutBuilder(
                      builder: (context, constraints) => _buildBody(
                        context,
                        theme,
                        issue,
                        constraints.maxWidth,
                        firstLine,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_showsCrosshair)
              Positioned(top: 0, right: 0, child: _crosshair(theme, firstLine)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    SleuthThemeData theme,
    PerformanceIssue issue,
    double width,
    double firstLine,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final titleStyle = DefaultTextStyle.of(
      context,
    ).style.merge(_titleStyle(theme));
    final iconSize = _iconSize(context);
    final iconColumn = math.max(18.0, iconSize + 2);
    final indent = iconColumn + theme.spacingMd;
    final reserve = _showsCrosshair ? _crosshairReserve : 0.0;
    final maxLines = _titleLines(context);
    // The line count decides whether the meta line passes under the
    // crosshair's hit box.
    final painter = TextPainter(
      text: TextSpan(text: issue.title, style: titleStyle),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0.0, width - indent - reserve));
    final oneLine = painter.computeLineMetrics().length <= 1;
    painter.dispose();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(right: reserve),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: iconColumn,
                height: firstLine,
                child: Center(
                  child: _severityIcon(issue.severity, theme, size: iconSize),
                ),
              ),
              SizedBox(width: theme.spacingMd),
              Expanded(
                child: GestureDetector(
                  onLongPress: widget.onCopy,
                  excludeFromSemantics: true,
                  // The card's label is the title.
                  child: ExcludeSemantics(
                    child: Text(
                      issue.title,
                      style: _titleStyle(theme),
                      maxLines: maxLines,
                      overflow: maxLines == null ? null : TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Meta line: tags, category, confidence, recurrence and effects.
        // Only this subtree listens to the scan pulse.
        Padding(
          padding: EdgeInsets.only(left: indent, right: oneLine ? reserve : 0),
          child: widget.scanTick != null
              ? SleuthListenableBuilder(
                  listenable: widget.scanTick!,
                  builder: (context) => _metaLine(theme, issue),
                )
              : _metaLine(theme, issue),
        ),

        // The details use the full card width below a divider; only the
        // header keeps the indent.
        if (_expanded) ...[
          SizedBox(height: theme.spacingMd),
          ExcludeSemantics(
            child: SizedBox(
              height: 1,
              width: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(color: theme.cardDivider),
              ),
            ),
          ),
          IssueCardDetails(
            issue: issue,
            width: width,
            scanTick: widget.scanTick,
            trendOf: _currentTrend,
            lastSeenOf: widget.lastSeenOf,
            parentIssues: widget.parentIssues,
            suppressedParentCount: widget.suppressedParentCount,
            downstreamIssues: widget.downstreamIssues,
            relatedLinkOf: widget.relatedLinkOf,
            onOpenRelated: widget.onOpenRelated,
            onSeeRebuildStats: widget.onSeeRebuildStats,
            rebuildStatsTotal: widget.rebuildStatsTotal,
            onSeeStartup: widget.onSeeStartup,
            whyItRebuilds: widget.whyItRebuilds,
            rebuildCauseOf: widget.rebuildCauseOf,
            onCopyText: widget.onCopyText,
            highlighted: widget.highlighted,
            onShowOnScreen: _showsCrosshair ? widget.onHighlightChanged : null,
            onLearnMore: widget.onLearnMore,
            onAskAi: widget.onAskAi,
            onCopy: widget.onCopy,
            onHide: widget.onHide == null ? null : _hide,
            notUseful: widget.notUseful,
            onNotUsefulChanged: widget.onNotUsefulChanged,
            openInline: widget.revealInline,
          ),
        ],
      ],
    );
  }

  /// The 48 px crosshair that outlines the issue's widget on screen. Its
  /// 32 px face is centred on the title's first line, [firstLine] high,
  /// below the card's 10 px padding.
  Widget _crosshair(SleuthThemeData theme, double firstLine) {
    final on = widget.highlighted;
    final faceTop = (10 + firstLine / 2 - 16).clamp(0.0, 16.0);
    final radius = BorderRadius.circular(theme.radiusLg);
    void toggle() => widget.onHighlightChanged?.call(!on);
    return Semantics(
      container: true,
      button: true,
      // Read as on or off, as the checkbox it replaced was, until the
      // crosshair becomes a one-shot action.
      toggled: on,
      label: 'Show ${widget.issue.widgetName} on screen',
      onTap: toggle,
      excludeSemantics: true,
      child: SleuthFocusInkWell(
        onTap: toggle,
        borderRadius: radius,
        builder: (context, showFocus) => SizedBox(
          width: 48,
          height: 48,
          child: Padding(
            padding: EdgeInsets.only(top: faceTop),
            child: Align(
              alignment: Alignment.topCenter,
              child: SleuthFocusOutline(
                show: showFocus,
                color: theme.checkboxActive,
                borderRadius: radius,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: on
                        ? theme.checkboxActive.withValues(alpha: 0.22)
                        : null,
                    borderRadius: radius,
                  ),
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: Icon(
                      Icons.my_location,
                      size: 18,
                      color: on ? theme.checkboxActive : theme.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One quiet line under the title: the New and Jank tags, then
  /// category, confidence (or the Debug timing tag in its place),
  /// recurrence and effects. It is one paragraph, so it wraps like text:
  /// each separator stays at the end of the part before it.
  Widget _metaLine(SleuthThemeData theme, PerformanceIssue issue) {
    final trend = _currentTrend();
    final downstream = widget.downstreamIssues?.length ?? 0;
    final debugTiming = _isDebugTiming(issue);
    final debugTag = _tag(
      theme,
      'Debug timing',
      fill: theme.badgeDbgBg,
      text: theme.badgeDbgText,
    );
    final recurrence = trend != null && trend.length >= 2
        ? 'seen ${trend.presentCount} of ${trend.length} scans, '
              '${_trendLabel(trend)}'
        : null;
    final effects = downstream > 0
        ? '$downstream ${downstream == 1 ? 'effect' : 'effects'}'
        : null;
    final parts = <Object>[
      _categoryName(issue.category),
      if (debugTiming) debugTag else _confidenceName(issue.confidence),
      ?recurrence,
      ?effects,
    ];
    InlineSpan inline(Widget child) =>
        WidgetSpan(alignment: PlaceholderAlignment.middle, child: child);
    final spans = <InlineSpan>[
      if (widget.stale)
        inline(
          Padding(
            padding: EdgeInsets.only(right: theme.spacingSm),
            child: _tag(
              theme,
              'Not detected right now',
              fill: theme.badgeFill(theme.textSecondary),
              text: theme.badgeTextOn(theme.textSecondary),
            ),
          ),
        ),
      if (widget.isNew)
        inline(
          Padding(
            padding: EdgeInsets.only(right: theme.spacingSm),
            child: _tag(
              theme,
              'New',
              fill: theme.badgeFill(theme.checkboxActive),
              text: theme.badgeTextOn(theme.checkboxActive),
            ),
          ),
        ),
      if (widget.jankCorrelated)
        inline(
          Padding(
            padding: EdgeInsets.only(right: theme.spacingSm),
            child: _tag(
              theme,
              'Jank',
              fill: theme.badgeFill(theme.severityCritical),
              text: theme.badgeTextOn(
                theme.severityCritical,
                tinted: theme.severityCriticalText,
              ),
            ),
          ),
        ),
      for (final (i, part) in parts.indexed) ...[
        if (i > 0) ...[
          // A no-break space keeps the dot with the part before it.
          TextSpan(
            text: '\u00A0\u00B7',
            style: TextStyle(color: theme.textTertiary.withValues(alpha: 0.6)),
          ),
          const TextSpan(text: ' '),
        ],
        if (part is Widget) inline(part) else TextSpan(text: part as String),
      ],
    ];
    // Read as one phrase; the separators and the New tag (in the card's
    // hint) are left out.
    final spoken = [
      if (widget.stale) 'Not detected right now',
      if (widget.jankCorrelated) 'Jank',
      _categoryName(issue.category),
      if (debugTiming) 'Debug timing' else _confidenceName(issue.confidence),
      ?recurrence,
      ?effects,
    ].join(', ');
    return Padding(
      padding: EdgeInsets.only(top: theme.spacingXs),
      child: Semantics(
        container: true,
        label: spoken,
        excludeSemantics: true,
        child: Text.rich(
          TextSpan(children: spans),
          style: TextStyle(
            color: theme.textTertiary,
            fontSize: theme.fontMd,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  /// A small filled tag in the meta line. The paragraph scales a widget
  /// span by the text scale, so the label itself is not scaled again.
  Widget _tag(
    SleuthThemeData theme,
    String label, {
    required Color fill,
    required Color text,
  }) => DecoratedBox(
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(theme.radiusSm),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: theme.spacingXs,
        vertical: theme.spacingXxs,
      ),
      child: Text(
        label,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          color: text,
          fontSize: theme.fontXs,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  /// A timing issue in a debug run: debug builds run slower than release,
  /// so a time-based measurement from the VM timeline or from
  /// `FrameTiming` overstates the cost. Counts, rates and sizes are left
  /// untagged.
  static bool _isDebugTiming(PerformanceIssue issue) {
    if (!issue.debugModeDisclaimer) return false;
    final source = issue.observationSource;
    if (source != ObservationSource.vmTimeline &&
        source != ObservationSource.frameTiming) {
      return false;
    }
    final unit = issue.measurement?.unit;
    return unit == MeasurementUnit.milliseconds ||
        unit == MeasurementUnit.seconds ||
        unit == MeasurementUnit.percent ||
        unit == MeasurementUnit.frames;
  }

  static String _categoryName(IssueCategory category) => switch (category) {
    IssueCategory.build => 'Build',
    IssueCategory.layout => 'Layout',
    IssueCategory.paint => 'Paint',
    IssueCategory.raster => 'Raster',
    IssueCategory.memory => 'Memory',
    IssueCategory.channel => 'Channel',
    IssueCategory.font => 'Font',
    IssueCategory.network => 'Network',
    IssueCategory.startup => 'Startup',
  };

  static String _confidenceName(IssueConfidence confidence) =>
      switch (confidence) {
        IssueConfidence.confirmed => 'Confirmed',
        IssueConfidence.likely => 'Likely',
        IssueConfidence.possible => 'Possible',
      };

  /// The severity mark, announced as the severity name.
  Widget _severityIcon(
    IssueSeverity severity,
    SleuthThemeData theme, {
    double size = 14,
  }) {
    final name = switch (severity) {
      IssueSeverity.critical => 'critical',
      IssueSeverity.warning => 'warning',
      IssueSeverity.ok => 'ok',
    };
    return Semantics(
      label: name,
      excludeSemantics: true,
      child: SleuthSeverityIcon(severity: severity, size: size),
    );
  }

  RecurrenceTrend? _currentTrend() =>
      widget.recurrenceTrendOf?.call() ?? widget.recurrenceTrend;

  /// The trend word in the meta line's "seen X of Y scans, {label}",
  /// shown once the trend ring buffer has at least 2 entries. X is
  /// [RecurrenceTrend.presentCount], the scan cycles where the issue was
  /// observed; Y is [RecurrenceTrend.length], the cycles the buffer holds
  /// (capacity 60, oldest evicted).
  ///
  /// - `worsening`: severity is rising over the recent window.
  /// - `persistent`: `stable` with `presentCount / length >= 0.9`, an issue
  ///   that fires almost every cycle. Synthesised here, not in the enum.
  /// - `stable`: `stable` otherwise.
  /// - `improving`: severity is falling.
  /// - `flaky`: `intermittent`, toggling present and absent at least 3
  ///   times inside the recent window.
  ///
  /// See [RecurrenceTrend.computeTrend] for the window (default 10
  /// entries) and the ±0.3 severity-delta thresholds.
  // NOTE: These labels are documented. If you rename one, update the
  // table in `RecurrenceTrend`'s enum dartdoc, the "Recurrence badge"
  // section of doc/internals.md and the label list in README.md.
  static String _trendLabel(RecurrenceTrend trend) {
    final total = trend.length;
    final ratio = total == 0 ? 0.0 : trend.presentCount / total;
    return switch (trend.trend) {
      TrendDirection.worsening => 'worsening',
      TrendDirection.stable when ratio >= 0.9 => 'persistent',
      TrendDirection.stable => 'stable',
      TrendDirection.improving => 'improving',
      TrendDirection.intermittent => 'flaky',
    };
  }
}
