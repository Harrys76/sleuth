import 'package:flutter/material.dart';

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
  final _expanded = <int>{0, 1, 2, 3};

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    )..forward();
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onClose();
      },
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
                      GestureDetector(
                        onTap: widget.onClose,
                        behavior: HitTestBehavior.opaque,
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                            child: Icon(Icons.arrow_back,
                                color: theme.textPrimary, size: 22),
                          ),
                        ),
                      ),
                      Text(
                        '\u{1F415} Sleuth Guide',
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: theme.fontXl,
                          fontWeight: FontWeight.bold,
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
                      theme.spacingXl, theme.spacingLg, theme.spacingXl, 24),
                  child: Column(
                    children: [
                      _section(
                        index: 0,
                        icon: Icons.rocket_launch_outlined,
                        title: 'Quick Start',
                        accent: theme.categoryBuild,
                        theme: theme,
                        child: _quickStartContent(),
                      ),
                      const SizedBox(height: 10),
                      _section(
                        index: 1,
                        icon: Icons.dashboard_customize_outlined,
                        title: 'Understanding the Card',
                        accent: theme.categoryMemory,
                        theme: theme,
                        child: _cardExplanation(theme),
                      ),
                      const SizedBox(height: 10),
                      _section(
                        index: 2,
                        icon: Icons.palette_outlined,
                        title: 'Color Legend',
                        accent: theme.severityOk,
                        theme: theme,
                        child: _colorLegend(theme),
                      ),
                      const SizedBox(height: 10),
                      _section(
                        index: 3,
                        icon: Icons.tips_and_updates_outlined,
                        title: 'Tips & Tricks',
                        accent: theme.severityWarning,
                        theme: theme,
                        child: _tipsContent(theme),
                      ),
                      const SizedBox(height: 20),
                      FadeTransition(
                        opacity: _staggered(4),
                        child: Text(
                          'Sleuth',
                          style: TextStyle(
                              color: theme.textSubtle, fontSize: theme.fontSm),
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
              GestureDetector(
                onTap: () => _toggleSection(index),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: 14, vertical: theme.spacingLg),
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
                        duration: const Duration(milliseconds: 200),
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
              // Content — animated height on collapse/expand
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
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
          title: 'Run in Profile Mode',
          detail: 'flutter run --profile \u2014 for accurate timing data',
        ),
        _GuideStep(
          step: '2',
          title: 'Navigate Your App',
          detail: 'Use as normal. Sleuth monitors every frame automatically.',
        ),
        _GuideStep(
          step: '3',
          title: 'Watch the FPS Number',
          detail: 'Green \u2265 50, amber \u2265 30, red < 30 FPS.',
        ),
        _GuideStep(
          step: '4',
          title: 'Review Issues',
          detail:
              'Tap any issue to see detail, fix hint, and confidence level.',
        ),
        _GuideStep(
          step: '5',
          title: 'Apply Fixes & Verify',
          detail:
              'Follow the fix hints. Hot reload to see improvement instantly.',
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
            'FPS Display',
            'The number on the trigger button and card header. Color-coded: '
                'green (\u2265 50), amber (\u2265 30), red (< 30).'),
        _infoTile(
            theme,
            '\u{1F534}',
            'Severity Dot',
            'Red = at least one critical issue. Amber = warnings only. '
                'Green = no issues detected.'),
        _infoTile(
            theme,
            '\u{2705}',
            'Summary Bar',
            'Shows severity counts and evidence quality '
                '(confirmed vs heuristic) below the divider.'),
        _infoTile(
            theme,
            '\u{1F50D}',
            'Highlight Toggle',
            'Check the box on a locatable issue to highlight the widget '
                'on screen with a blue border.'),
        _infoTile(
            theme,
            '\u{2194}\u{FE0F}',
            'Resize',
            'Drag the bottom-right corner to resize width and height. '
                'Double-tap the header to toggle between compact and full-width.'),
        _infoTile(
            theme,
            '\u{1F4CB}',
            'Export',
            'Tap the export button in the footer to copy a JSON snapshot '
                'of the current session to your clipboard.'),
      ],
    );
  }

  static Widget _infoTile(
      SleuthThemeData theme, String emoji, String title, String detail) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(emoji, style: TextStyle(fontSize: theme.fontLg)),
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
                      color: theme.textTertiary, fontSize: theme.fontSm),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Section 2: Color Legend ───────────────────────────────────────────
  // All text strings are preserved for test compatibility.

  Widget _colorLegend(SleuthThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Severity ──────────────────────────────────────────────────
        _legendHeading(theme, 'Severity'),
        _legendSubtext(theme, 'Emoji at the start of each issue card header.'),
        const _LegendRow(
            icon: '\u{1F534}', label: 'Critical \u2014 immediate attention'),
        _legendDetail(theme,
            'Observed impact: dropped frames, high memory, or severe bottleneck.'),
        const _LegendRow(
            icon: '\u{1F7E1}', label: 'Warning \u2014 should investigate'),
        _legendDetail(theme,
            'Pattern detected that could degrade performance under load.'),
        const _LegendRow(icon: '\u{1F7E2}', label: 'OK \u2014 informational'),
        _legendDetail(
            theme, 'Minor observation with no measurable impact yet.'),

        // ── Confidence Badges ─────────────────────────────────────────
        _legendDivider(theme),
        _legendHeading(theme, 'Confidence Badges'),
        _legendSubtext(theme,
            'Shown at the top-right of each issue. Reflects how the issue was detected.'),
        _badgeLegendRow(theme, 'CONFIRMED', theme.confidenceConfirmed,
            'Directly observed \u2014 caught in real-time profiling data'),
        _badgeLegendRow(theme, 'LIKELY', theme.confidenceLikely,
            'Runtime + structural evidence \u2014 two independent signals'),
        _badgeLegendRow(theme, 'POSSIBLE', theme.confidencePossible,
            'Structural pattern only \u2014 code analysis, no runtime confirmation'),

        // ── Source Accent ─────────────────────────────────────────────
        _legendDivider(theme),
        _legendHeading(theme, 'Source Accent (left bar)'),
        _legendSubtext(theme,
            'Colored bar on the left edge of each issue card. Shows where data came from.'),
        _colorBarLegendRow(theme, theme.sourceVmTimeline, 'VM timeline event',
            detail: 'Dart VM performance timeline (most accurate)'),
        _colorBarLegendRow(theme, theme.sourceDebugCallback, 'Debug callback',
            detail: 'Framework debug instrumentation (adds some overhead)'),
        _colorBarLegendRow(theme, theme.sourceStructural, 'Structural scan',
            detail: 'Static widget tree analysis (no runtime cost)'),

        // ── Category Badges ───────────────────────────────────────────
        _legendDivider(theme),
        _legendHeading(theme, 'Category Badges'),
        _legendSubtext(theme,
            'Pipeline stage tag next to severity. Shows which part of rendering is affected.'),
        _categoryLegendRow(theme, 'BUILD', theme.categoryBuild,
            'Widget rebuild overhead \u2014 missing const, broad setState'),
        _categoryLegendRow(theme, 'LAYOUT', theme.categoryLayout,
            'Layout constraint issues \u2014 unconstrained lists, overflow'),
        _categoryLegendRow(theme, 'PAINT', theme.categoryPaint,
            'Paint layer complexity \u2014 heavy CustomPaint, missing RepaintBoundary'),
        _categoryLegendRow(theme, 'RASTER', theme.categoryRaster,
            'GPU rasterization cost \u2014 shader compilation, saveLayer'),
        _categoryLegendRow(theme, 'MEMORY', theme.categoryMemory,
            'Memory allocation patterns \u2014 leaks, unbounded growth'),
        _categoryLegendRow(theme, 'CHANNEL', theme.categoryChannel,
            'Platform channel latency \u2014 slow method channel calls'),
        _categoryLegendRow(theme, 'FONT', theme.categoryFont,
            'Font loading & rendering \u2014 too many custom font families'),
        _categoryLegendRow(theme, 'NETWORK', theme.categoryNetwork,
            'HTTP request performance \u2014 slow responses, large payloads'),

        // ── Effort Badges ─────────────────────────────────────────────
        _legendDivider(theme),
        _legendHeading(theme, 'Effort Badges'),
        _legendSubtext(
            theme, 'Shown in the fix hint box when an issue is expanded.'),
        _badgeLegendRow(theme, 'QUICK FIX', theme.effortQuick,
            'Simple change \u2014 add const, swap a widget, tweak a parameter'),
        _badgeLegendRow(theme, 'MEDIUM FIX', theme.effortMedium,
            'Some refactoring \u2014 restructure widget tree, add caching'),
        _badgeLegendRow(theme, 'INVOLVED FIX', theme.effortInvolved,
            'Architecture change \u2014 isolate work, redesign data flow'),

        // ── Special Indicators ────────────────────────────────────────
        _legendDivider(theme),
        _legendHeading(theme, 'Special Indicators'),
        _legendSubtext(theme,
            'Contextual badges and colors that appear under specific conditions.'),
        _badgeLegendRow(theme, 'JANK', theme.severityCritical,
            'This issue was active during a dropped frame'),
        SizedBox(height: theme.spacingXs),
        _cardStateLegendRow(
          theme,
          theme.cardHighlighted,
          'Highlighted',
          'Widget highlight checkbox is checked \u2014 affected widget is outlined on screen',
        ),
        _cardStateLegendRow(
          theme,
          theme.cardJankFlash,
          'Jank flash',
          'Momentary amber tint when a new jank correlation is detected',
        ),
        _cardStateLegendRow(
          theme,
          theme.cardDefault,
          'Default',
          'Normal issue card background',
        ),
      ],
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
      padding: EdgeInsets.only(left: 22, bottom: theme.spacingSm),
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

  static Widget _badgeLegendRow(
      SleuthThemeData theme, String label, Color color, String description) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingXs),
      child: Row(
        children: [
          Container(
            padding:
                EdgeInsets.symmetric(horizontal: 5, vertical: theme.spacingXxs),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(theme.radiusSm),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: theme.fontXxs,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(width: theme.spacingMd),
          Expanded(
            child: Text(
              description,
              style:
                  TextStyle(color: theme.textTertiary, fontSize: theme.fontSm),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _colorBarLegendRow(
      SleuthThemeData theme, Color color, String description,
      {String? detail}) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: theme.spacingXxs),
            child: Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
          SizedBox(width: theme.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  style: TextStyle(
                      color: theme.textTertiary, fontSize: theme.fontSm),
                ),
                if (detail != null)
                  Text(
                    detail,
                    style: TextStyle(
                        color: theme.textQuaternary, fontSize: theme.fontXs),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _categoryChip(
      SleuthThemeData theme, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(theme.radiusSm),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: theme.fontXxs,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  static Widget _categoryLegendRow(
      SleuthThemeData theme, String label, Color color, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: _categoryChip(theme, label, color),
          ),
          SizedBox(width: theme.spacingMd),
          Expanded(
            child: Text(
              description,
              style:
                  TextStyle(color: theme.textTertiary, fontSize: theme.fontSm),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _cardStateLegendRow(
      SleuthThemeData theme, Color color, String label, String description) {
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
              border: Border.all(
                color: theme.textSubtle,
                width: 0.5,
              ),
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
                      color: theme.textQuaternary, fontSize: theme.fontXs),
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
        _tipRow(theme, Icons.flash_on_outlined,
            'A JANK badge means this issue was active during a dropped frame.'),
        _tipRow(theme, Icons.layers_outlined,
            'The layers icon in the header toggles highlight borders on all detected widgets.'),
        _tipRow(theme, Icons.ios_share,
            'Export a JSON snapshot to share with teammates or attach to bug reports.'),
        _tipRow(theme, Icons.sort,
            'Issues are ranked by severity, confidence, and recurrence count.'),
        _tipRow(theme, Icons.info_outline,
            '"About this detection" inside each issue explains how it was found and how to verify.'),
        _tipRow(theme, Icons.speed,
            'Always profile (not debug) for accurate frame timings. Debug overhead skews results.'),
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
              style:
                  TextStyle(color: theme.textTertiary, fontSize: theme.fontSm),
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
                color: theme.textPrimary,
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
  const _LegendRow({required this.icon, required this.label});

  final String icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Text(icon, style: TextStyle(fontSize: theme.fontSm)),
          SizedBox(width: theme.spacingSm),
          Text(
            label,
            style: TextStyle(color: theme.textTertiary, fontSize: theme.fontSm),
          ),
        ],
      ),
    );
  }
}
