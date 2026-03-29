import 'package:flutter/material.dart';

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
    return Material(
      color: const Color(0xFF1E1E2E),
      child: SafeArea(
        child: Column(
          children: [
            // Header
            FadeTransition(
              opacity: _staggered(0),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.arrow_back,
                          color: Colors.white, size: 22),
                    ),
                    const Text(
                      '\u{1F415} Watchdog Guide',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(color: Color(0xFF374151), height: 1),

            // Scrollable sections
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  children: [
                    _section(
                      index: 0,
                      icon: Icons.rocket_launch_outlined,
                      title: 'Quick Start',
                      accent: const Color(0xFF3B82F6),
                      child: _quickStartContent(),
                    ),
                    const SizedBox(height: 10),
                    _section(
                      index: 1,
                      icon: Icons.dashboard_customize_outlined,
                      title: 'Understanding the Card',
                      accent: const Color(0xFF8B5CF6),
                      child: _cardExplanation(),
                    ),
                    const SizedBox(height: 10),
                    _section(
                      index: 2,
                      icon: Icons.palette_outlined,
                      title: 'Color Legend',
                      accent: const Color(0xFF10B981),
                      child: _colorLegend(),
                    ),
                    const SizedBox(height: 10),
                    _section(
                      index: 3,
                      icon: Icons.tips_and_updates_outlined,
                      title: 'Tips & Tricks',
                      accent: const Color(0xFFF59E0B),
                      child: _tipsContent(),
                    ),
                    const SizedBox(height: 20),
                    FadeTransition(
                      opacity: _staggered(4),
                      child: const Text(
                        'Widget Watchdog',
                        style:
                            TextStyle(color: Color(0xFF4B5563), fontSize: 10),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
            color: const Color(0xFF252536),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF374151), width: 0.5),
          ),
          child: Column(
            children: [
              // Header — tappable to expand/collapse
              GestureDetector(
                onTap: () => _toggleSection(index),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(icon, color: accent, size: 16),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      AnimatedRotation(
                        turns: isExpanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(
                          Icons.expand_more,
                          color: Color(0xFF6B7280),
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
          detail: 'Use as normal. Watchdog monitors every frame automatically.',
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

  Widget _cardExplanation() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoTile(
            '\u{1F4CA}',
            'FPS Display',
            'The number on the trigger button and card header. Color-coded: '
                'green (\u2265 50), amber (\u2265 30), red (< 30).'),
        _infoTile(
            '\u{1F534}',
            'Severity Dot',
            'Red = at least one critical issue. Amber = warnings only. '
                'Green = no issues detected.'),
        _infoTile(
            '\u{2705}',
            'Summary Bar',
            'Shows severity counts and evidence quality '
                '(confirmed vs heuristic) below the divider.'),
        _infoTile(
            '\u{1F50D}',
            'Highlight Toggle',
            'Check the box on a locatable issue to highlight the widget '
                'on screen with a blue border.'),
        _infoTile(
            '\u{2194}\u{FE0F}',
            'Resize',
            'Drag the bottom-right corner to resize width and height. '
                'Double-tap the header to toggle between compact and full-width.'),
        _infoTile(
            '\u{1F4CB}',
            'Export',
            'Tap the export button in the footer to copy a JSON snapshot '
                'of the current session to your clipboard.'),
      ],
    );
  }

  static Widget _infoTile(String emoji, String title, String detail) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(emoji, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style:
                      const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
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

  Widget _colorLegend() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Severity ──────────────────────────────────────────────────
        _legendHeading('Severity'),
        _legendSubtext('Emoji at the start of each issue card header.'),
        const _LegendRow(
            icon: '\u{1F534}', label: 'Critical \u2014 immediate attention'),
        _legendDetail(
            'Observed impact: dropped frames, high memory, or severe bottleneck.'),
        const _LegendRow(
            icon: '\u{1F7E1}', label: 'Warning \u2014 should investigate'),
        _legendDetail(
            'Pattern detected that could degrade performance under load.'),
        const _LegendRow(icon: '\u{1F7E2}', label: 'OK \u2014 informational'),
        _legendDetail('Minor observation with no measurable impact yet.'),

        // ── Confidence Badges ─────────────────────────────────────────
        _legendDivider(),
        _legendHeading('Confidence Badges'),
        _legendSubtext(
            'Shown at the top-right of each issue. Reflects how the issue was detected.'),
        _badgeLegendRow('CONFIRMED', const Color(0xFF10B981),
            'Directly observed \u2014 caught in real-time profiling data'),
        _badgeLegendRow('LIKELY', const Color(0xFFF59E0B),
            'Runtime + structural evidence \u2014 two independent signals'),
        _badgeLegendRow('POSSIBLE', const Color(0xFF6B7280),
            'Structural pattern only \u2014 code analysis, no runtime confirmation'),

        // ── Source Accent ─────────────────────────────────────────────
        _legendDivider(),
        _legendHeading('Source Accent (left bar)'),
        _legendSubtext(
            'Colored bar on the left edge of each issue card. Shows where data came from.'),
        _colorBarLegendRow(const Color(0xFF10B981), 'VM timeline event',
            detail: 'Dart VM performance timeline (most accurate)'),
        _colorBarLegendRow(const Color(0xFF8B5CF6), 'Debug callback',
            detail: 'Framework debug instrumentation (adds some overhead)'),
        _colorBarLegendRow(const Color(0xFF6B7280), 'Structural scan',
            detail: 'Static widget tree analysis (no runtime cost)'),

        // ── Category Badges ───────────────────────────────────────────
        _legendDivider(),
        _legendHeading('Category Badges'),
        _legendSubtext(
            'Pipeline stage tag next to severity. Shows which part of rendering is affected.'),
        _categoryLegendRow('BUILD', const Color(0xFF3B82F6),
            'Widget rebuild overhead \u2014 missing const, broad setState'),
        _categoryLegendRow('LAYOUT', const Color(0xFFF59E0B),
            'Layout constraint issues \u2014 unconstrained lists, overflow'),
        _categoryLegendRow('PAINT', const Color(0xFF10B981),
            'Paint layer complexity \u2014 heavy CustomPaint, missing RepaintBoundary'),
        _categoryLegendRow('RASTER', const Color(0xFFEF4444),
            'GPU rasterization cost \u2014 shader compilation, saveLayer'),
        _categoryLegendRow('MEMORY', const Color(0xFF8B5CF6),
            'Memory allocation patterns \u2014 leaks, unbounded growth'),
        _categoryLegendRow('CHANNEL', const Color(0xFF06B6D4),
            'Platform channel latency \u2014 slow method channel calls'),
        _categoryLegendRow('FONT', const Color(0xFF6B7280),
            'Font loading & rendering \u2014 too many custom font families'),
        _categoryLegendRow('NETWORK', const Color(0xFFF97316),
            'HTTP request performance \u2014 slow responses, large payloads'),

        // ── Effort Badges ─────────────────────────────────────────────
        _legendDivider(),
        _legendHeading('Effort Badges'),
        _legendSubtext('Shown in the fix hint box when an issue is expanded.'),
        _badgeLegendRow('QUICK FIX', const Color(0xFF10B981),
            'Simple change \u2014 add const, swap a widget, tweak a parameter'),
        _badgeLegendRow('MEDIUM FIX', const Color(0xFFF59E0B),
            'Some refactoring \u2014 restructure widget tree, add caching'),
        _badgeLegendRow('INVOLVED FIX', const Color(0xFFEF4444),
            'Architecture change \u2014 isolate work, redesign data flow'),

        // ── Special Indicators ────────────────────────────────────────
        _legendDivider(),
        _legendHeading('Special Indicators'),
        _legendSubtext(
            'Contextual badges and colors that appear under specific conditions.'),
        _badgeLegendRow('JANK', const Color(0xFFEF4444),
            'This issue was active during a dropped frame'),
        const SizedBox(height: 4),
        _cardStateLegendRow(
          const Color(0xFF1E3A5F),
          'Highlighted',
          'Widget highlight checkbox is checked \u2014 affected widget is outlined on screen',
        ),
        _cardStateLegendRow(
          const Color(0xFF5F2D1E),
          'Jank flash',
          'Momentary amber tint when a new jank correlation is detected',
        ),
        _cardStateLegendRow(
          const Color(0xFF374151),
          'Default',
          'Normal issue card background',
        ),
      ],
    );
  }

  static Widget _legendHeading(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF9CA3AF),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  static Widget _legendSubtext(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(color: Color(0xFF6B7280), fontSize: 9),
      ),
    );
  }

  static Widget _legendDetail(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 22, bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF6B7280),
          fontSize: 9,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  static Widget _legendDivider() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Divider(color: Color(0xFF374151), height: 1),
    );
  }

  static Widget _badgeLegendRow(String label, Color color, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
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
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              description,
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _colorBarLegendRow(Color color, String description,
      {String? detail}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  style:
                      const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
                ),
                if (detail != null)
                  Text(
                    detail,
                    style:
                        const TextStyle(color: Color(0xFF6B7280), fontSize: 9),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _categoryChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
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

  static Widget _categoryLegendRow(
      String label, Color color, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: _categoryChip(label, color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              description,
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _cardStateLegendRow(
      Color color, String label, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 16,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: const Color(0xFF4B5563),
                width: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFFD1D5DB),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  description,
                  style: const TextStyle(color: Color(0xFF6B7280), fontSize: 9),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Section 3: Tips & Tricks ─────────────────────────────────────────

  Widget _tipsContent() {
    return Column(
      children: [
        _tipRow(Icons.flash_on_outlined,
            'A JANK badge means this issue was active during a dropped frame.'),
        _tipRow(Icons.layers_outlined,
            'The layers icon in the header toggles highlight borders on all detected widgets.'),
        _tipRow(Icons.ios_share,
            'Export a JSON snapshot to share with teammates or attach to bug reports.'),
        _tipRow(Icons.sort,
            'Issues are ranked by severity, confidence, and recurrence count.'),
        _tipRow(Icons.info_outline,
            '"About this detection" inside each issue explains how it was found and how to verify.'),
        _tipRow(Icons.speed,
            'Always profile (not debug) for accurate frame timings. Debug overhead skews results.'),
      ],
    );
  }

  static Widget _tipRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFFF59E0B), size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              color: Color(0xFF3B82F6),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              step,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
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
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: const TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontSize: 10,
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 10)),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
          ),
        ],
      ),
    );
  }
}
