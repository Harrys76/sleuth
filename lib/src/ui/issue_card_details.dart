import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import '../models/recurrence_trend.dart';
import '../utils/fix_hint_split.dart';
import '../utils/issue_metadata_builder.dart';
import '../utils/measurement_text.dart';
import '../utils/widget_location.dart' show leafSourceLocation;
import 'focus_ink_well.dart';
import 'measurement_gauge.dart';
import 'severity_icon.dart';
import 'sleuth_listenable_builder.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

/// What the Why it rebuilds row shows for a widget type over `seconds`:
/// rebuilds the widget started itself (`own`: a setState, a changed
/// dependency or a listenable), those its parents forced (`forced`, from
/// `parents` parent types), and the parent that forced the most with its
/// share (`parent`, `parentForced`). `capped` means the debug counters
/// left some widget types out, so the counts can be low. `otherScreen`
/// means the latest counts are from a screen other than the card's, so
/// the row shows none.
typedef RebuildCause = ({
  int own,
  int forced,
  int parents,
  String? parent,
  int parentForced,
  int seconds,
  bool capped,
  bool otherScreen,
});

/// How a Caused by or Effects row opens the related card.
enum RelatedLink {
  /// The host opens the card: it expands and scrolls to a visible one, or
  /// says why it cannot (hidden, filtered out).
  open,

  /// The related issue is collapsed into this card; its details open
  /// under the row.
  inline,

  /// The related issue is no longer reported.
  plain,
}

/// The expanded part of an issue card, below its divider.
class IssueCardDetails extends StatefulWidget {
  const IssueCardDetails({
    super.key,
    required this.issue,
    required this.width,
    this.scanTick,
    this.trendOf,
    this.lastSeenOf,
    this.parentIssues,
    this.suppressedParentCount = 0,
    this.downstreamIssues,
    this.relatedLinkOf,
    this.onOpenRelated,
    this.onSeeRebuildStats,
    this.rebuildStatsTotal,
    this.onSeeStartup,
    this.whyItRebuilds = false,
    this.rebuildCauseOf,
    this.onCopyText,
    this.highlighted = false,
    this.onShowOnScreen,
    this.onLearnMore,
    this.onAskAi,
    this.onCopy,
    this.onHide,
    this.notUseful = false,
    this.onNotUsefulChanged,
    this.openInline,
  });

  final PerformanceIssue issue;

  /// The width the details lay out in, which decides when the label
  /// column stacks.
  final double width;

  final Listenable? scanTick;
  final RecurrenceTrend? Function()? trendOf;
  final DateTime? Function()? lastSeenOf;
  final List<PerformanceIssue>? parentIssues;
  final int suppressedParentCount;
  final List<PerformanceIssue>? downstreamIssues;
  final RelatedLink Function(PerformanceIssue)? relatedLinkOf;
  final ValueChanged<PerformanceIssue>? onOpenRelated;
  final VoidCallback? onSeeRebuildStats;
  final int? rebuildStatsTotal;
  final VoidCallback? onSeeStartup;

  /// Whether the card shows the Why it rebuilds row (debug runs, rebuild
  /// and setState cards).
  final bool whyItRebuilds;

  /// The latest rebuild split, read on every scan. Null when debug
  /// callbacks are off, which the row says.
  final RebuildCause? Function()? rebuildCauseOf;

  /// Copies text and confirms with the given toast.
  final void Function(String text, String confirmation)? onCopyText;

  final bool highlighted;
  final ValueChanged<bool>? onShowOnScreen;
  final VoidCallback? onLearnMore;
  final VoidCallback? onAskAi;
  final VoidCallback? onCopy;
  final VoidCallback? onHide;
  final bool notUseful;
  final ValueChanged<bool>? onNotUsefulChanged;

  /// A folded related issue to open under its row, as a related row of
  /// another card asked.
  final PerformanceIssue? openInline;

  @override
  State<IssueCardDetails> createState() => _IssueCardDetailsState();
}

class _IssueCardDetailsState extends State<IssueCardDetails> {
  /// Related rows opened inline, by their card identity.
  final Set<(String, int?)> _inlineOpen = {};

  static (String, int?) _idOf(PerformanceIssue i) =>
      (i.stableId ?? i.title, i.occurrenceId);

  /// Related issues this card has shown, by stable id, and the ids each
  /// section showed, so one that stops being reported stays as a plain
  /// row instead of vanishing. The causal graph drops a gone effect from
  /// its root's ids, so the card keeps its own list.
  final Map<String, PerformanceIssue> _seenRelated = {};
  final Set<String> _shownParentIds = {};
  final Set<String> _shownEffectIds = {};

  @override
  void initState() {
    super.initState();
    final open = widget.openInline;
    if (open != null) _inlineOpen.add(_idOf(open));
  }

  @override
  void didUpdateWidget(covariant IssueCardDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    final open = widget.openInline;
    if (open != null && !identical(open, oldWidget.openInline)) {
      _inlineOpen.add(_idOf(open));
    }
  }

  /// [live] plus the issues this section showed before that are no longer
  /// reported, which [shownIds] remembers.
  List<PerformanceIssue> _withGone(
    List<PerformanceIssue>? live,
    Set<String> shownIds,
  ) {
    final current = live ?? const <PerformanceIssue>[];
    final present = <String>{};
    for (final i in current) {
      final id = i.stableId ?? i.title;
      _seenRelated[id] = i;
      present.add(id);
    }
    final gone = [
      for (final id in shownIds)
        if (!present.contains(id))
          if (_seenRelated[id] case final issue?)
            if ((widget.relatedLinkOf?.call(issue) ?? RelatedLink.plain) ==
                RelatedLink.plain)
              issue,
    ];
    shownIds
      ..clear()
      ..addAll(present)
      ..addAll([for (final i in gone) i.stableId ?? i.title]);
    return [...current, ...gone];
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final issue = widget.issue;
    final parents = _withGone(widget.parentIssues, _shownParentIds);
    final effects = _withGone(widget.downstreamIssues, _shownEffectIds);
    // A parent no longer reported was counted among those not shown.
    final suppressed = math.max(
      0,
      widget.suppressedParentCount -
          (parents.length - (widget.parentIssues?.length ?? 0)),
    );
    final blocks = <Widget>[
      if (measuredLine(issue) != null)
        _measured(theme, issue)
      else
        Text(
          issue.detail,
          style: TextStyle(color: theme.textSecondary, fontSize: theme.fontMd),
        ),
      _KeyValueRows(rows: _rows(theme, issue), width: widget.width),
      if (widget.whyItRebuilds) _whyItRebuilds(theme, issue),
      if (parents.isNotEmpty || suppressed > 0)
        _related(theme, 'Caused by', parents, suppressed: suppressed),
      if (effects.isNotEmpty) _related(theme, 'Effects', effects),
      if (widget.onSeeRebuildStats != null)
        _linkRow(
          theme,
          icon: Icons.autorenew,
          label: widget.rebuildStatsTotal == null
              ? 'See rebuild stats for this screen'
              : 'See rebuild stats for this screen · '
                    '${_grouped(widget.rebuildStatsTotal!)} rebuilds',
          onTap: widget.onSeeRebuildStats!,
        ),
      if (widget.onSeeStartup != null)
        _linkRow(
          theme,
          icon: Icons.rocket_launch_outlined,
          label: 'See startup details',
          onTap: widget.onSeeStartup!,
        ),
      _fix(theme, issue),
      _buttons(theme),
    ];
    // A tap on the details does not collapse the card, so reading or
    // copying text there keeps it open; the header toggles it.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: () {},
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, block) in blocks.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? theme.spacingMd : 10),
              // Each block is its own node, so a screen reader does not read
              // the whole body as one utterance.
              child: Semantics(container: true, child: block),
            ),
        ],
      ),
    );
  }

  // ─── Measured ────────────────────────────────────────────────────────

  Widget _measured(SleuthThemeData theme, PerformanceIssue issue) {
    final m = issue.measurement!;
    final (before, value, after) = measuredLine(issue)!;
    final note = measuredSeverityNote(issue);
    return Semantics(
      label: measuredSemanticsLabel(issue),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel(theme, 'Measured'),
          SizedBox(height: theme.spacingXs),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.sectionBackground,
              borderRadius: BorderRadius.circular(theme.radiusLg),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: before),
                        TextSpan(
                          text: value,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: after),
                      ],
                    ),
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: theme.fontBase,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (m.warningAt != null || m.criticalAt != null) ...[
                    SizedBox(height: theme.spacingMd),
                    SleuthMeasurementGauge(
                      measurement: m,
                      color: gaugeFillColor(theme, issue.severity),
                    ),
                  ],
                  if (note != null)
                    Padding(
                      padding: EdgeInsets.only(top: theme.spacingXs),
                      child: Text(
                        note,
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: theme.fontMd,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Where, Route, When, Evidence, Check in ─────────────────────────

  List<(String, Widget)> _rows(SleuthThemeData theme, PerformanceIssue issue) {
    final valueStyle = TextStyle(
      color: theme.textPrimary,
      fontSize: theme.fontMd,
    );
    final location = leafSourceLocation(issue.ancestorChain);
    final widgetName = issue.widgetName;
    return [
      if (widgetName != null || location != null)
        (
          'Where',
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widgetName != null) Text(widgetName, style: valueStyle),
                    if (location != null)
                      Text(
                        location,
                        style: valueStyle.copyWith(
                          fontSize: theme.fontSm,
                          fontFamily: 'monospace',
                          fontFamilyFallback: const ['Menlo', 'Courier'],
                        ),
                      ),
                  ],
                ),
              ),
              if (location != null && widget.onCopyText != null)
                _miniButton(
                  theme,
                  label: 'Copy',
                  semanticsLabel: 'Copy location',
                  onTap: () => widget.onCopyText!(location, 'Location copied'),
                ),
            ],
          ),
        ),
      if (issue.routeDisplayName != null)
        ('Route', Text(issue.routeDisplayName!, style: valueStyle)),
      if (_whenText(issue) != null)
        (
          'When',
          widget.scanTick == null
              ? Text(_whenText(issue)!, style: valueStyle)
              : SleuthListenableBuilder(
                  listenable: widget.scanTick!,
                  builder: (_) =>
                      Text(_whenText(issue) ?? '', style: valueStyle),
                ),
        ),
      (
        'Evidence',
        Text(IssueMetadataBuilder.evidence(issue), style: valueStyle),
      ),
      (
        'Check in',
        Text(IssueMetadataBuilder.checkIn(issue), style: valueStyle),
      ),
    ];
  }

  /// "Last seen 2 s ago · in 5 of the last 8 scans · during scrolling".
  String? _whenText(PerformanceIssue issue) {
    final seen = widget.lastSeenOf?.call();
    final trend = widget.trendOf?.call();
    final context = issue.interactionContext;
    final parts = [
      if (seen != null) 'Last seen ${agoText(DateTime.now().difference(seen))}',
      if (trend != null && trend.length >= 2)
        'in ${trend.presentCount} of the last ${trend.length} scans',
      if (context != null && context != InteractionContext.idle)
        'during ${context.displayName}',
    ];
    if (parts.isEmpty) return null;
    final text = parts.join(' · ');
    return text[0].toUpperCase() + text.substring(1);
  }

  // ─── Why it rebuilds ─────────────────────────────────────────────────

  Widget _whyItRebuilds(SleuthThemeData theme, PerformanceIssue issue) {
    Widget body() {
      final read = widget.rebuildCauseOf;
      final cause = read?.call();
      final style = TextStyle(
        color: theme.textPrimary,
        fontSize: theme.fontBase,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      const bold = TextStyle(fontWeight: FontWeight.w700);
      final Widget content;
      String? hint;
      if (read == null) {
        content = Text(
          'Turn on SleuthConfig.enableDebugCallbacks to split these '
          'rebuilds by cause.',
          style: style.copyWith(color: theme.textSecondary),
        );
      } else if (cause != null && cause.otherScreen) {
        content = Text(
          "Open this issue's screen to count its rebuilds",
          style: style.copyWith(color: theme.textSecondary),
        );
      } else if (cause == null || cause.own + cause.forced == 0) {
        content = Text(
          cause == null
              ? 'No rebuild counts yet'
              : cause.capped
              ? 'No rebuilds counted in the last ${cause.seconds} s; some '
                    'widget types went untracked'
              : 'No rebuilds in the last ${cause.seconds} s',
          style: style.copyWith(color: theme.textSecondary),
        );
      } else {
        final parent = cause.parent;
        content = Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '${cause.own}', style: bold),
              const TextSpan(text: ' started by the widget itself · '),
              TextSpan(text: '${cause.forced}', style: bold),
              if (parent == null)
                const TextSpan(text: ' forced by its parents')
              else if (cause.parents == 1) ...[
                const TextSpan(text: ' forced by its parent '),
                TextSpan(text: parent, style: bold),
              ] else ...[
                TextSpan(text: ' forced by ${cause.parents} parents, '),
                TextSpan(text: '${cause.parentForced}', style: bold),
                const TextSpan(text: ' of them by '),
                TextSpan(text: parent, style: bold),
              ],
            ],
          ),
          style: style,
        );
        if (cause.capped) {
          // Missing types make the counts low and the comparison unsafe.
          hint =
              'Some widget types went untracked, so these counts can be '
              'low.';
        } else if (parent != null && cause.parentForced > cause.own) {
          hint = 'Most of these rebuilds come from $parent, so start there.';
        }
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel(
            theme,
            cause == null || cause.otherScreen
                ? 'Why it rebuilds'
                : 'Why it rebuilds · last ${cause.seconds} s',
          ),
          SizedBox(height: theme.spacingXs),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.sectionBackground,
              borderRadius: BorderRadius.circular(theme.radiusLg),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  content,
                  if (hint != null)
                    Padding(
                      padding: EdgeInsets.only(top: theme.spacingXs),
                      child: Text(
                        hint,
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: theme.fontMd,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return widget.scanTick == null
        ? body()
        : SleuthListenableBuilder(
            listenable: widget.scanTick!,
            builder: (_) => body(),
          );
  }

  // ─── Caused by, Effects and stats links ─────────────────────────────

  Widget _related(
    SleuthThemeData theme,
    String name,
    List<PerformanceIssue> issues, {
    int suppressed = 0,
  }) {
    const cap = 5;
    final shown = issues.take(cap).toList();
    final more = issues.length - shown.length;
    final total = issues.length + suppressed;
    final quiet = TextStyle(color: theme.textTertiary, fontSize: theme.fontMd);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionLabel(theme, '$name ($total)'),
        for (final related in shown) ...[
          SizedBox(height: theme.spacingXs),
          _relatedRow(theme, related),
        ],
        if (more > 0)
          Padding(
            padding: EdgeInsets.only(top: theme.spacingXs),
            child: Text('and $more more', style: quiet),
          ),
        if (suppressed > 0)
          Padding(
            padding: EdgeInsets.only(top: theme.spacingXs),
            child: Text('$suppressed more not shown', style: quiet),
          ),
      ],
    );
  }

  Widget _relatedRow(SleuthThemeData theme, PerformanceIssue related) {
    final link = widget.relatedLinkOf?.call(related) ?? RelatedLink.plain;
    final id = _idOf(related);
    final open = _inlineOpen.contains(id);
    final severity = switch (related.severity) {
      IssueSeverity.critical => 'Critical',
      IssueSeverity.warning => 'Warning',
      IssueSeverity.ok => 'OK',
    };
    final icon = SleuthSeverityIcon(
      severity: related.severity,
      size: _iconSize(context, 14),
    );
    final face = _rowFace(
      theme,
      leading: icon,
      label: related.title,
      trailing: link == RelatedLink.open
          ? Icons.chevron_right
          : open
          ? Icons.expand_less
          : Icons.expand_more,
    );
    final row = switch (link) {
      // No longer reported: plain text, not a row that looks like a link.
      RelatedLink.plain => Semantics(
        container: true,
        label: '$severity: ${related.title}',
        excludeSemantics: true,
        child: Row(
          children: [
            icon,
            SizedBox(width: theme.spacingSm),
            Expanded(
              child: Text(
                related.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.textSecondary,
                  fontSize: theme.fontMd,
                ),
              ),
            ),
          ],
        ),
      ),
      RelatedLink.open => _tappable(
        theme,
        label: '$severity: ${related.title}',
        hint: 'Opens its card',
        onTap: () => widget.onOpenRelated?.call(related),
        child: face,
      ),
      RelatedLink.inline => _tappable(
        theme,
        label: '$severity: ${related.title}',
        expanded: open,
        onTap: () => setState(() {
          if (!_inlineOpen.remove(id)) _inlineOpen.add(id);
        }),
        child: face,
      ),
    };
    if (!open || link != RelatedLink.inline) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Padding(
          padding: EdgeInsets.fromLTRB(
            theme.spacingLg,
            theme.spacingSm,
            0,
            theme.spacingXs,
          ),
          child: Semantics(container: true, child: _inline(theme, related)),
        ),
      ],
    );
  }

  /// A related issue's details under its row: what was measured (or its
  /// detail) and its fix.
  Widget _inline(SleuthThemeData theme, PerformanceIssue related) {
    final line = measuredLine(related);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          line == null ? related.detail : '${line.$1}${line.$2}${line.$3}',
          style: TextStyle(color: theme.textSecondary, fontSize: theme.fontMd),
        ),
        SizedBox(height: theme.spacingSm),
        ..._fixParts(theme, related.fixHint),
      ],
    );
  }

  Widget _linkRow(
    SleuthThemeData theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => _tappable(
    theme,
    label: label,
    onTap: onTap,
    child: _rowFace(
      theme,
      leading: Icon(
        icon,
        size: _iconSize(context, 14),
        color: theme.textSecondary,
      ),
      label: label,
      trailing: Icons.chevron_right,
    ),
  );

  /// The content of a 48 px row: a leading mark, two lines of text and a
  /// trailing chevron. [_tappable] gives it the section fill.
  Widget _rowFace(
    SleuthThemeData theme, {
    required Widget leading,
    required String label,
    required IconData trailing,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: theme.spacingMd,
        vertical: theme.spacingSm,
      ),
      child: Row(
        children: [
          leading,
          SizedBox(width: theme.spacingSm),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: theme.fontMd,
              ),
            ),
          ),
          Icon(
            trailing,
            size: _iconSize(context, 16),
            color: theme.textTertiary,
          ),
        ],
      ),
    ),
  );

  /// [base] growing with the text up to the chrome limit, as the card's
  /// severity icon does.
  static double _iconSize(BuildContext context, double base) =>
      base * textScaleOf(context).clamp(1.0, kChromeMaxTextScale);

  // ─── Fix ─────────────────────────────────────────────────────────────

  Widget _fix(SleuthThemeData theme, PerformanceIssue issue) {
    final effort = switch (issue.fixEffort) {
      FixEffort.quick => 'Fix · quick',
      FixEffort.medium => 'Fix · medium effort',
      FixEffort.involved => 'Fix · involved',
      null => 'Fix',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionLabel(theme, effort),
        ..._fixParts(theme, issue.fixHint),
      ],
    );
  }

  List<Widget> _fixParts(SleuthThemeData theme, String fixHint) => [
    for (final part in splitFixHint(fixHint))
      Padding(
        padding: EdgeInsets.only(top: theme.spacingXs),
        child: part.code
            ? _codeBox(theme, part.text)
            : Text(
                part.text,
                style: TextStyle(
                  color: theme.textSecondary,
                  fontSize: theme.fontMd,
                  height: 1.45,
                ),
              ),
      ),
  ];

  Widget _codeBox(SleuthThemeData theme, String code) {
    final first = code.trimLeft();
    final terminal = first.startsWith('flutter ') || first.startsWith('dart ');
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.fixHintBackground,
        borderRadius: BorderRadius.circular(theme.radiusMd),
        border: Border.all(color: theme.cardDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              10,
              theme.spacingXxs + 1,
              theme.spacingSm,
              theme.spacingXxs + 1,
            ),
            child: Text(
              terminal ? 'Terminal' : 'Dart',
              style: TextStyle(
                color: theme.textTertiary,
                fontSize: theme.fontXxs,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: theme.cardDivider)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Text(
                code,
                softWrap: true,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: theme.fontSm,
                  height: 1.5,
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['Menlo', 'Courier'],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (widget.onCopyText == null) return box;
    // Copy code sits in the header bar; its 48 px hit box reaches into the
    // code's padding instead of making the bar 48 px tall.
    return Stack(
      children: [
        box,
        Positioned(
          top: 0,
          right: 0,
          child: _miniButton(
            theme,
            label: 'Copy code',
            semanticsLabel: 'Copy code',
            alignment: Alignment.topRight,
            onTap: () => widget.onCopyText!(code, 'Code copied'),
          ),
        ),
      ],
    );
  }

  // ─── Buttons ─────────────────────────────────────────────────────────

  Widget _buttons(SleuthThemeData theme) {
    final notUseful = widget.notUseful;
    return Wrap(
      spacing: 5,
      children: [
        if (widget.onShowOnScreen != null)
          _ActionButton(
            icon: Icons.my_location,
            label: 'Show on screen',
            toggled: widget.highlighted,
            onTap: () => widget.onShowOnScreen!(!widget.highlighted),
          ),
        if (widget.onLearnMore != null)
          _ActionButton(
            icon: Icons.menu_book_outlined,
            label: 'Learn more',
            onTap: widget.onLearnMore!,
          ),
        if (widget.onAskAi != null)
          _ActionButton(
            icon: Icons.auto_awesome_outlined,
            label: 'Ask AI',
            onTap: widget.onAskAi!,
          ),
        if (widget.onCopy != null)
          _ActionButton(
            icon: Icons.content_copy_outlined,
            label: 'Copy details',
            onTap: widget.onCopy!,
          ),
        if (widget.onHide != null)
          _ActionButton(
            icon: Icons.visibility_off_outlined,
            label: 'Hide',
            onTap: widget.onHide!,
          ),
        if (widget.onNotUsefulChanged != null)
          _ActionButton(
            icon: notUseful ? Icons.thumb_down : Icons.thumb_down_outlined,
            label: 'Not useful',
            toggled: notUseful,
            onTap: () => widget.onNotUsefulChanged!(!notUseful),
          ),
      ],
    );
  }

  /// A small Copy action: its label sits at [alignment] in a 48 px hit
  /// box.
  Widget _miniButton(
    SleuthThemeData theme, {
    required String label,
    required String semanticsLabel,
    required VoidCallback onTap,
    Alignment alignment = Alignment.center,
  }) {
    final radius = BorderRadius.circular(theme.radiusSm);
    return Semantics(
      container: true,
      button: true,
      label: semanticsLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: SleuthFocusInkWell(
        onTap: onTap,
        excludeFromSemantics: true,
        borderRadius: radius,
        builder: (context, showFocus) => ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Align(
            alignment: alignment,
            widthFactor: 1,
            heightFactor: 1,
            child: SleuthFocusOutline(
              show: showFocus,
              color: theme.checkboxActive,
              borderRadius: radius,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: theme.spacingSm,
                  vertical: theme.spacingXxs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.content_copy_outlined,
                      size: _iconSize(context, 12),
                      color: theme.textSecondary,
                    ),
                    SizedBox(width: theme.spacingXxs),
                    Text(
                      label,
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: theme.fontSm,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A tappable row on the section fill. The fill is a [Material], so the
  /// press highlight paints above it.
  Widget _tappable(
    SleuthThemeData theme, {
    required String label,
    String? hint,
    bool? expanded,
    required VoidCallback onTap,
    required Widget child,
  }) {
    final radius = BorderRadius.circular(theme.radiusMd);
    return Semantics(
      container: true,
      button: true,
      label: label,
      hint: hint,
      expanded: expanded,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: theme.sectionBackground,
        borderRadius: radius,
        child: SleuthFocusInkWell(
          onTap: onTap,
          excludeFromSemantics: true,
          borderRadius: radius,
          builder: (context, showFocus) => SleuthFocusOutline(
            show: showFocus,
            color: theme.checkboxActive,
            borderRadius: radius,
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(SleuthThemeData theme, String text) => Text(
    text.toUpperCase(),
    semanticsLabel: text,
    style: TextStyle(
      color: theme.textTertiary,
      fontSize: theme.fontXxs,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
    ),
  );
}

/// "2 s ago", "just now", "3 min ago", "1 h ago".
String agoText(Duration elapsed) {
  final s = elapsed.inSeconds;
  if (s < 1) return 'just now';
  if (s < 60) return '$s s ago';
  if (s < 3600) return '${s ~/ 60} min ago';
  return '${s ~/ 3600} h ago';
}

String _grouped(int value) {
  final digits = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// Labelled rows whose labels share a column sized to the widest label;
/// once that column passes a third of the row, each label sits above its
/// value.
class _KeyValueRows extends StatelessWidget {
  const _KeyValueRows({required this.rows, required this.width});

  final List<(String, Widget)> rows;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final labelStyle = DefaultTextStyle.of(
      context,
    ).style.merge(TextStyle(color: theme.textTertiary, fontSize: theme.fontMd));
    final scaler = MediaQuery.textScalerOf(context);
    var column = 0.0;
    for (final (label, _) in rows) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      column = math.max(column, painter.width);
      painter.dispose();
    }
    column = column.ceilToDouble();
    final gap = theme.spacingMd;
    final stacked = column + gap > width / 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, (label, value)) in rows.indexed)
          Padding(
            padding: EdgeInsets.only(
              top: i == 0
                  ? 0
                  : stacked
                  ? theme.spacingMd
                  : theme.spacingXs,
            ),
            child: Semantics(
              container: true,
              child: stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: labelStyle),
                        value,
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: column,
                          child: Text(label, style: labelStyle),
                        ),
                        SizedBox(width: gap),
                        Expanded(child: value),
                      ],
                    ),
            ),
          ),
      ],
    );
  }
}

/// A labelled button: a pill at least 32 px tall in a 48 px hit box.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.toggled,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Non-null for a toggle, read as on or off.
  final bool? toggled;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final radius = BorderRadius.circular(theme.radiusLg);
    final on = toggled ?? false;
    return Semantics(
      container: true,
      button: true,
      toggled: toggled,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: SleuthFocusInkWell(
        onTap: onTap,
        excludeFromSemantics: true,
        borderRadius: radius,
        builder: (context, showFocus) => ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            widthFactor: 1,
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
                  border: Border.all(
                    color: on ? theme.checkboxActive : theme.cardDivider,
                  ),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: theme.spacingMd),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          icon,
                          size:
                              14 *
                              textScaleOf(
                                context,
                              ).clamp(1.0, kChromeMaxTextScale),
                          color: theme.textPrimary,
                        ),
                        SizedBox(width: theme.spacingXs + 1),
                        Flexible(
                          child: Text(
                            label,
                            style: TextStyle(
                              color: theme.textPrimary,
                              fontSize: theme.fontMd,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
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
}
