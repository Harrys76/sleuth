import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../models/issue_measurement.dart';
import '../models/performance_issue.dart';
import '../models/recurrence_trend.dart';
import '../utils/issue_metadata_builder.dart';
import 'focus_ink_well.dart';
import 'motion.dart';
import 'severity_icon.dart';
import 'sleuth_listenable_builder.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

/// A card displaying a single performance issue.
///
/// - Tap to expand/collapse detail + fix hint.
/// - The crosshair (when the issue names a widget) outlines the widget on
///   screen.
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

  /// When true, shows a "JANK" badge in the collapsed header: this issue
  /// can explain the latest jank frame's phase, and jank is still
  /// reported.
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
                    '($suppressed more not shown)',
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

  Widget _categoryBadge(IssueCategory category, SleuthThemeData theme) {
    return _badge(
      theme: theme,
      accent: theme.categoryColor(category),
      label: _categoryLabel(category),
      textScaler: _badgeScaler(context),
    );
  }

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
