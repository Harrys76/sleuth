import 'package:flutter/material.dart';

import '../models/performance_issue.dart';

import 'motion.dart';
import 'severity_icon.dart';
import 'sleuth_theme.dart';

/// Full-screen guide page with staggered entrance animations and expandable
/// sections. Opened from the floating card's [?] button.
///
/// Extracted from the old DashboardSheet Guide tab, redesigned with:
/// - Staggered fade+slide entrance per section
/// - Expandable card-style sections with animated chevrons
/// - New "Understanding the Card" and "Tips & Tricks" sections
/// - All original legend content preserved for test compatibility
class GuidePage extends StatefulWidget {
  const GuidePage({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<GuidePage> createState() => _GuidePageState();
}

class _GuidePageState extends State<GuidePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;

  /// All sections start expanded so content is immediately discoverable.
  final _expanded = <int>{0, 1, 2, 3, 4};

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    startEntrance(context, _entranceController);
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  /// Staggered animation for section at [index]. Each section starts 120ms
  /// after the previous, with a 400ms fade+slide duration.
  Animation<double> _staggered(int index) {
    final start = (index * 0.12).clamp(0.0, 0.6);
    final end = (start + 0.4).clamp(0.0, 1.0);
    return CurvedAnimation(
      parent: _entranceController,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
  }

  void _toggleSection(int index) {
    setState(() {
      if (_expanded.contains(index)) {
        _expanded.remove(index);
      } else {
        _expanded.add(index);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);

    // Route semantics: screen readers announce the page name. While a
    // page is open, `SleuthOverlay` drops the app's nodes below it.
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Sleuth Guide',
      child: Material(
        color: theme.pageBackground,
        child: SafeArea(
          child: Column(
            children: [
              // Header
              FadeTransition(
                opacity: _staggered(0),
                child: Padding(
                  padding: EdgeInsets.all(theme.spacingMd),
                  child: Row(
                    children: [
                      Semantics(
                        label: 'Back',
                        button: true,
                        child: GestureDetector(
                          onTap: widget.onClose,
                          behavior: HitTestBehavior.opaque,
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: Center(
                              child: Icon(
                                Icons.arrow_back,
                                color: theme.textPrimary,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Icon(
                        Icons.pets,
                        size: theme.fontXl,
                        color: theme.textPrimary,
                      ),
                      SizedBox(width: theme.spacingXs),
                      Expanded(
                        child: Text(
                          'Sleuth Guide',
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontSize: theme.fontXl,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(color: theme.border, height: 1),

              // Scrollable sections
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    theme.spacingXl,
                    theme.spacingLg,
                    theme.spacingXl,
                    24,
                  ),
                  child: Column(
                    children: [
                      _section(
                        index: 0,
                        icon: Icons.rocket_launch_outlined,
                        title: 'Quick start',
                        accent: theme.categoryBuild,
                        theme: theme,
                        child: _quickStartContent(),
                      ),
                      const SizedBox(height: 10),
                      _section(
                        index: 1,
                        icon: Icons.dashboard_customize_outlined,
                        title: 'Understanding the card',
                        accent: theme.categoryMemory,
                        theme: theme,
                        child: _cardExplanation(theme),
                      ),
                      const SizedBox(height: 10),
                      _section(
                        index: 2,
                        icon: Icons.palette_outlined,
                        title: 'Color legend',
                        accent: theme.severityOk,
                        theme: theme,
                        child: _colorLegend(theme),
                      ),
                      const SizedBox(height: 10),
                      _section(
                        index: 3,
                        icon: Icons.tips_and_updates_outlined,
                        title: 'Tips and tricks',
                        accent: theme.severityWarning,
                        theme: theme,
                        child: _tipsContent(theme),
                      ),
                      const SizedBox(height: 10),
                      _section(
                        index: 4,
                        icon: Icons.accessibility_new,
                        title: 'Accessibility',
                        accent: theme.categoryChannel,
                        theme: theme,
                        child: _accessibilityContent(theme),
                      ),
                      const SizedBox(height: 20),
                      FadeTransition(
                        opacity: _staggered(5),
                        child: Text(
                          'Sleuth',
                          style: TextStyle(
                            color: theme.textQuaternary,
                            fontSize: theme.fontSm,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Section card with entrance animation ─────────────────────────────

  Widget _section({
    required int index,
    required IconData icon,
    required String title,
    required Color accent,
    required SleuthThemeData theme,
    required Widget child,
  }) {
    final animation = _staggered(index);
    final isExpanded = _expanded.contains(index);

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.08),
        end: Offset.zero,
      ).animate(animation),
      child: FadeTransition(
        opacity: animation,
        child: Container(
          decoration: BoxDecoration(
            color: theme.sectionBackground,
            borderRadius: BorderRadius.circular(theme.radiusXxl),
            border: Border.all(color: theme.border, width: 0.5),
          ),
          child: Column(
            children: [
              // Header — tappable to expand/collapse
              Semantics(
                container: true,
                button: true,
                expanded: isExpanded,
                label: title,
                onTap: () => _toggleSection(index),
                excludeSemantics: true,
                child: GestureDetector(
                  onTap: () => _toggleSection(index),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: theme.spacingLg,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(theme.radiusLg),
                          ),
                          child: Icon(icon, color: accent, size: 16),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: theme.textPrimary,
                              fontSize: theme.fontLg,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        AnimatedRotation(
                          turns: isExpanded ? 0.5 : 0,
                          duration: motionDuration(
                            context,
                            const Duration(milliseconds: 200),
                          ),
                          child: Icon(
                            Icons.expand_more,
                            color: theme.textQuaternary,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Content — animated height on collapse/expand
              AnimatedSize(
                duration: motionDuration(
                  context,
                  const Duration(milliseconds: 250),
                ),
                curve: Curves.easeInOut,
                child: isExpanded
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                        child: child,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Section 0: Quick Start ───────────────────────────────────────────

  Widget _quickStartContent() {
    return const Column(
      children: [
        _GuideStep(
          step: '1',
          title: 'Run in profile mode',
          detail:
              'Use flutter run --profile --no-dds. Profile mode gives '
              'accurate timings, and --no-dds lets Sleuth reach the VM '
              'service for the checks that need it.',
        ),
        _GuideStep(
          step: '2',
          title: 'Use your app',
          detail: 'Use it as normal. Sleuth monitors every frame.',
        ),
        _GuideStep(
          step: '3',
          title: 'Watch the FPS number',
          detail:
              'It is green at or above about 83% of your target frame rate, '
              'amber at or above 50% and red below that.',
        ),
        _GuideStep(
          step: '4',
          title: 'Review issues',
          detail:
              'Tap an issue to see what was measured against its warning and '
              'critical lines, where and when it was seen, the evidence and '
              'the fix.',
        ),
        _GuideStep(
          step: '5',
          title: 'Apply fixes and verify',
          detail: 'Follow the fix hints, then hot reload to see the change.',
        ),
      ],
    );
  }

  // ─── Section 1: Understanding the Card ────────────────────────────────

  Widget _cardExplanation(SleuthThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoTile(
          theme,
          '\u{1F4CA}',
          'FPS display',
          'The number on the trigger button, colored by your target frame '
              'rate: green at or above about 83%, amber at or above 50% and '
              'red below that. The status row repeats it at its end.',
        ),
        _infoTile(
          theme,
          '\u{1F7E2}',
          'Run label',
          'The header names the build mode and whether Sleuth reached the '
              'VM service, for example "Debug · VM" or "Profile · no VM". '
              'Without the VM, the checks that need it are off and some run '
              'in part. The dot is filled green with the VM and an amber '
              'ring without it. '
              'A narrow card shortens the text, down to the dot alone.',
        ),
        _infoTile(
          theme,
          '\u{1F534}',
          'Severity dot',
          'Red means at least one critical issue. Amber means warnings only. '
              'Green means no issues. Hidden cards and severities turned off '
              'in the status row do not count.',
        ),
        _infoTile(
          theme,
          '\u{2705}',
          'Severity chips',
          'The chips under the header count the cards of each severity and '
              'filter the list. Tap one to show or hide that severity. One '
              'always stays on. While one is off, "Showing X of Y" sits '
              'above the list, with Show all.',
        ),
        _infoTile(
          theme,
          '\u{1F50D}',
          'Show on screen',
          'Tap the crosshair on an issue that names or lists widgets to '
              'outline its widget on screen, in the issue\'s severity color. '
              'The card shrinks to a bar until you tap Back to issues. On an '
              'issue that lists several widgets, such as Missing '
              'RepaintBoundary, Next in the bar moves the outline to the '
              'next one. When no widget is on screen, a toast says so.',
        ),
        _infoTile(
          theme,
          '\u{1F501}',
          'Rebuild stats',
          'In profile mode with enableDeepDebugInstrumentation, the More '
              'menu shows the rebuilds counted on this route. Tap Rebuild '
              'stats for every widget type, sorted by count, as they were '
              'when you tapped. Counts include initial widget inflations.',
        ),
        _infoTile(
          theme,
          '\u{1F4DD}',
          'Copy and hide',
          'Expand an issue and tap Copy details to copy it as plain text, '
              'or long-press the title. Hide removes the card, with Undo. '
              'Hidden issues in the More menu counts them and opens the list '
              'where you restore them. Hiding affects only the overlay. '
              'Exports, snapshots and MCP still include the issue.',
        ),
        _infoTile(
          theme,
          '\u{1F44E}',
          'Not useful',
          'Mark an issue Not useful when Sleuth got it wrong. The mark lasts '
              'for the session and goes into exports, snapshots and MCP '
              'output, so a detector\'s false positives can be counted. Tap '
              'it again to remove the mark.',
        ),
        _infoTile(
          theme,
          '\u{2194}\u{FE0F}',
          'Resize and move',
          'Drag the bottom-right corner to resize width and height. Drag '
              'the trigger button to move it. It settles on the nearest side. '
              'Like the card, it keeps its place when you close and reopen.',
        ),
        _infoTile(
          theme,
          '\u{2B05}\u{FE0F}',
          'Back',
          'The system back gesture or button closes the open page, the '
              'More menu or the highlight bar, then the card, before your '
              'app\'s navigation sees it.',
        ),
        _infoTile(
          theme,
          '\u{1F4CB}',
          'Copy snapshot',
          'Copy snapshot in the More menu copies a JSON snapshot of the '
              'current session to your clipboard.',
        ),
      ],
    );
  }

  static Widget _infoTile(
    SleuthThemeData theme,
    String emoji,
    String title,
    String detail,
  ) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: ExcludeSemantics(
              child: Text(emoji, style: TextStyle(fontSize: theme.fontLg)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: theme.fontMd,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: theme.spacingXxs),
                Text(
                  detail,
                  style: TextStyle(
                    color: theme.textTertiary,
                    fontSize: theme.fontSm,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Section 2: Color Legend ───────────────────────────────────────────

  Widget _colorLegend(SleuthThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Severity ──────────────────────────────────────────────────
        _legendHeading(theme, 'Severity'),
        _legendSubtext(theme, 'Icon at the start of each issue card.'),
        const _LegendRow(
          severity: IssueSeverity.critical,
          label: 'Critical, needs immediate attention',
        ),
        _legendDetail(
          theme,
          'Sleuth observed an impact, such as dropped frames, high memory or a severe bottleneck.',
        ),
        const _LegendRow(
          severity: IssueSeverity.warning,
          label: 'Warning, worth investigating',
        ),
        _legendDetail(
          theme,
          'Sleuth found a pattern that could slow the app under load.',
        ),
        const _LegendRow(
          severity: IssueSeverity.ok,
          label: 'OK, informational',
        ),
        _legendDetail(
          theme,
          'A minor observation with no measurable impact yet.',
        ),

        // ── Meta line ─────────────────────────────────────────────────
        _legendDivider(theme),
        _legendHeading(theme, 'Meta line'),
        _legendSubtext(
          theme,
          'One line under each title: its tags, then the category, the confidence, how often the issue recurs and how many effects it has. The effects are the issues it causes, listed when the card is expanded.',
        ),
        _tagLegendRow(
          theme,
          'Jank',
          theme.badgeFill(theme.severityCritical),
          theme.badgeTextOn(
            theme.severityCritical,
            tinted: theme.severityCriticalText,
          ),
          'The issue can explain a slow frame from the last 10 seconds on this '
              'screen, while jank is still reported',
        ),
        _tagLegendRow(
          theme,
          'Debug timing',
          theme.badgeDbgBg,
          theme.badgeDbgText,
          'A time measured in a debug run, which runs slower than release. It takes the place of the confidence',
        ),
        _tagLegendRow(
          theme,
          'New',
          theme.badgeFill(theme.checkboxActive),
          theme.badgeTextOn(theme.checkboxActive),
          'The issue just appeared. The tag shows for 2 seconds',
        ),

        // ── Confidence ────────────────────────────────────────────────
        SizedBox(height: theme.spacingMd),
        _legendHeading(theme, 'Confidence'),
        _termLegendRow(
          theme,
          'Confirmed',
          'Observed directly in real-time profiling data',
        ),
        _termLegendRow(
          theme,
          'Likely',
          'Two independent signals, runtime and structural evidence',
        ),
        _termLegendRow(
          theme,
          'Possible',
          'Structural pattern only, from code analysis with no runtime confirmation',
        ),

        // ── Recurrence ────────────────────────────────────────────────
        SizedBox(height: theme.spacingMd),
        _legendHeading(theme, 'Recurrence'),
        _legendSubtext(
          theme,
          'Shown as "seen X of Y scans, label": X is the number of recent scan cycles that fired the issue and Y the cycles observed, up to 60.',
        ),
        _termLegendRow(
          theme,
          'worsening',
          'Severity rising. The average cost is increasing across recent cycles',
        ),
        _termLegendRow(
          theme,
          'persistent',
          'Sticky. The issue fires in at least 90% of recent scan cycles',
        ),
        _termLegendRow(
          theme,
          'stable',
          'Present at a consistent severity, not trending up or down',
        ),
        _termLegendRow(
          theme,
          'improving',
          'Severity falling. It is getting better across recent cycles',
        ),
        _termLegendRow(
          theme,
          'flaky',
          'Appears and disappears irregularly, with at least 3 transitions in the window',
        ),

        // ── Category ──────────────────────────────────────────────────
        SizedBox(height: theme.spacingMd),
        _legendHeading(theme, 'Category'),
        _legendSubtext(theme, 'The part of the app the issue affects.'),
        _termLegendRow(
          theme,
          'Build',
          'Widget rebuild overhead, such as missing const or broad setState',
        ),
        _termLegendRow(
          theme,
          'Layout',
          'Layout constraint issues, such as unconstrained lists or overflow',
        ),
        _termLegendRow(
          theme,
          'Paint',
          'Paint layer complexity, such as heavy CustomPaint or a missing RepaintBoundary',
        ),
        _termLegendRow(
          theme,
          'Raster',
          'GPU rasterization cost, such as shader compilation or saveLayer',
        ),
        _termLegendRow(
          theme,
          'Memory',
          'Memory allocation patterns, such as leaks or unbounded growth',
        ),
        _termLegendRow(
          theme,
          'Channel',
          'Platform channel traffic, such as many method channel calls',
        ),
        _termLegendRow(
          theme,
          'Font',
          'Font loading and rendering, such as too many custom font families',
        ),
        _termLegendRow(
          theme,
          'Network',
          'HTTP request performance, such as slow responses or large payloads',
        ),
        _termLegendRow(
          theme,
          'Startup',
          'Time to the first frame after launch',
        ),

        // ── Fix effort ────────────────────────────────────────────────
        _legendDivider(theme),
        _legendHeading(theme, 'Fix effort'),
        _legendSubtext(
          theme,
          'The Fix label in an expanded issue says how much work the fix takes.',
        ),
        _termLegendRow(
          theme,
          'Quick',
          'A simple change, such as adding const, swapping a widget or tweaking a parameter',
        ),
        _termLegendRow(
          theme,
          'Medium effort',
          'Some refactoring, such as restructuring the widget tree or adding caching',
        ),
        _termLegendRow(
          theme,
          'Involved',
          'An architecture change, such as moving work to an isolate or redesigning data flow',
        ),

        // ── Card colors ───────────────────────────────────────────────
        _legendDivider(theme),
        _legendHeading(theme, 'Card colors'),
        _legendSubtext(
          theme,
          'The issue card background under specific conditions.',
        ),
        _cardStateLegendRow(
          theme,
          theme.cardHighlighted,
          'Finding',
          'The crosshair was tapped before the first scan; the widget is '
              'looked up when the scan ends',
        ),
        _cardStateLegendRow(
          theme,
          theme.cardDefault,
          'Default',
          'The normal issue card background',
        ),
      ],
    );
  }

  /// A meta line tag as the card draws it, with its meaning.
  static Widget _tagLegendRow(
    SleuthThemeData theme,
    String label,
    Color fill,
    Color text,
    String description,
  ) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
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
                style: TextStyle(
                  color: text,
                  fontSize: theme.fontXs,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          SizedBox(width: theme.spacingMd),
          Expanded(
            child: Text(
              description,
              style: TextStyle(
                color: theme.textTertiary,
                fontSize: theme.fontSm,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A meta line word with its meaning.
  static Widget _termLegendRow(
    SleuthThemeData theme,
    String term,
    String description,
  ) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingXs),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: term,
              style: TextStyle(
                color: theme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(text: '  $description'),
          ],
        ),
        style: TextStyle(color: theme.textTertiary, fontSize: theme.fontSm),
      ),
    );
  }

  static Widget _legendHeading(SleuthThemeData theme, String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingXs),
      child: Text(
        text,
        style: TextStyle(
          color: theme.textTertiary,
          fontSize: theme.fontMd,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  static Widget _legendSubtext(SleuthThemeData theme, String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingMd),
      child: Text(
        text,
        style: TextStyle(color: theme.textQuaternary, fontSize: theme.fontXs),
      ),
    );
  }

  static Widget _legendDetail(SleuthThemeData theme, String text) {
    return Padding(
      // Under the label: the 14 px icon and the gap before it.
      padding: EdgeInsets.only(
        left: 14 + theme.spacingSm,
        bottom: theme.spacingSm,
      ),
      child: Text(
        text,
        style: TextStyle(
          color: theme.textQuaternary,
          fontSize: theme.fontXs,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  static Widget _legendDivider(SleuthThemeData theme) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: theme.spacingMd),
      child: Divider(color: theme.border, height: 1),
    );
  }

  static Widget _cardStateLegendRow(
    SleuthThemeData theme,
    Color color,
    String label,
    String description,
  ) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 16,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(theme.radiusSm),
              border: Border.all(color: theme.textSubtle, width: 0.5),
            ),
          ),
          SizedBox(width: theme.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: theme.fontSm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(
                    color: theme.textQuaternary,
                    fontSize: theme.fontXs,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Section 3: Tips & Tricks ─────────────────────────────────────────

  Widget _tipsContent(SleuthThemeData theme) {
    return Column(
      children: [
        _tipRow(
          theme,
          Icons.flash_on_outlined,
          'A Jank tag marks an issue that can explain a slow frame from the last '
          '10 seconds on this screen, while jank is still reported.',
        ),
        _tipRow(
          theme,
          Icons.layers_outlined,
          'Mark flagged widgets (the layers icon in the header) puts a corner marker on every flagged widget on screen, and hides them again at once.',
        ),
        _tipRow(
          theme,
          Icons.content_copy,
          'Copy a JSON snapshot from the More menu to share with teammates or attach to bug reports.',
        ),
        _tipRow(
          theme,
          Icons.sort,
          'Issues are ranked by severity, confidence, and recurrence count.',
        ),
        _tipRow(
          theme,
          Icons.info_outline,
          'Evidence in an expanded issue says how Sleuth found it; Check in names the DevTools view to confirm it.',
        ),
        _tipRow(
          theme,
          Icons.speed,
          'Use profile mode, not debug, for accurate frame timings. Debug overhead skews the results.',
        ),
      ],
    );
  }

  // ─── Section 4: Accessibility ─────────────────────────────────────────

  Widget _accessibilityContent(SleuthThemeData theme) {
    return Column(
      children: [
        _tipRow(
          theme,
          Icons.record_voice_over_outlined,
          'Screen reader users can move the card header, resize grip and '
          'trigger through their actions menu (Move up, Taller, Move to left '
          'edge and so on).',
        ),
        _tipRow(
          theme,
          Icons.format_size,
          'Text follows the system size up to 2 times. The header, status '
          'row and summary chips stop at 1.3 times so the issue list keeps '
          'its room.',
        ),
        _tipRow(
          theme,
          Icons.contrast,
          'Theme in the More menu picks Auto, Light or Dark. Increase '
          'Contrast picks the high-contrast theme.',
        ),
        _tipRow(
          theme,
          Icons.keyboard_outlined,
          'Escape first leaves a focused Sleuth text field, then closes '
          'the open page, the More menu or the highlight bar, then the '
          'card. A dialog in your app keeps its Escape, and so does a text '
          'field unless the highlight bar is up.',
        ),
      ],
    );
  }

  static Widget _tipRow(SleuthThemeData theme, IconData icon, String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.guideTipIcon, size: 14),
          SizedBox(width: theme.spacingMd),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: theme.textTertiary,
                fontSize: theme.fontSm,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Reusable helper widgets ────────────────────────────────────────────

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.step,
    required this.title,
    required this.detail,
  });

  final String step;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: theme.guideStepAccent,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              step,
              style: TextStyle(
                color: SleuthThemeData.onColor(theme.guideStepAccent),
                fontSize: theme.fontMd,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: theme.fontMd,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: theme.spacingXxs),
                Text(
                  detail,
                  style: TextStyle(
                    color: theme.textTertiary,
                    fontSize: theme.fontSm,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.severity, required this.label});

  final IssueSeverity severity;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          ExcludeSemantics(
            child: SleuthSeverityIcon(severity: severity, size: 14),
          ),
          SizedBox(width: theme.spacingSm),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: theme.textTertiary,
                fontSize: theme.fontSm,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
