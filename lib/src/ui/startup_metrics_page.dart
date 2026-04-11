import 'package:flutter/material.dart';

import '../../sleuth.dart' show Sleuth;
import '../models/startup_metrics.dart';
import 'sleuth_theme.dart';

/// Full-screen page showing complete startup metrics breakdown and
/// measurement methodology. Opened by tapping the startup banner in
/// the floating card.
///
/// Follows the same [Positioned.fill] overlay pattern as [GuidePage]
/// and [IssueEncyclopediaPage].
class StartupMetricsPage extends StatefulWidget {
  const StartupMetricsPage({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<StartupMetricsPage> createState() => _StartupMetricsPageState();
}

class _StartupMetricsPageState extends State<StartupMetricsPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..forward();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  Animation<double> _staggered(int index) {
    final start = (index * 0.12).clamp(0.0, 0.6);
    final end = (start + 0.4).clamp(0.0, 1.0);
    return CurvedAnimation(
      parent: _entranceController,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final metrics = Sleuth.startupMetrics;

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
                              child: Icon(Icons.arrow_back,
                                  color: theme.textPrimary, size: 22),
                            ),
                          ),
                        ),
                      ),
                      Icon(Icons.rocket_launch_outlined,
                          color: theme.categoryStartup, size: 18),
                      SizedBox(width: theme.spacingXs),
                      Text(
                        'Startup Metrics',
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

              // Content
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                      theme.spacingXl, theme.spacingLg, theme.spacingXl, 24),
                  child: metrics == null
                      ? _noDataMessage(theme)
                      : _buildContent(metrics, theme),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noDataMessage(SleuthThemeData theme) {
    return Padding(
      padding: EdgeInsets.only(top: theme.spacingXl),
      child: FadeTransition(
        opacity: _staggered(1),
        child: Text(
          'No startup metrics available.\n'
          'Call Sleuth.init() before runApp() to capture startup data.',
          style: TextStyle(color: theme.textTertiary, fontSize: theme.fontBase),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildContent(StartupMetrics m, SleuthThemeData theme) {
    final accent = theme.categoryStartup;
    return Column(
      children: [
        // Headline metrics
        _section(
          index: 1,
          icon: Icons.timer_outlined,
          title: 'Headline',
          accent: accent,
          theme: theme,
          child: _headlineSection(m, theme),
        ),
        SizedBox(height: theme.spacingMd),

        // First-frame breakdown
        if (m.firstFrameTotalMs != null) ...[
          _section(
            index: 2,
            icon: Icons.view_timeline_outlined,
            title: 'First Frame Breakdown',
            accent: accent,
            theme: theme,
            child: _firstFrameSection(m, theme),
          ),
          SizedBox(height: theme.spacingMd),
        ],

        // Engine-level phases
        if (_hasEngineMetrics(m)) ...[
          _section(
            index: 3,
            icon: Icons.memory_outlined,
            title: 'Engine Phases',
            accent: accent,
            theme: theme,
            child: _engineSection(m, theme),
          ),
          SizedBox(height: theme.spacingMd),
        ],

        // VM sub-phases
        if (_hasVmMetrics(m)) ...[
          _section(
            index: 4,
            icon: Icons.analytics_outlined,
            title: 'VM Sub-Phases',
            accent: accent,
            theme: theme,
            child: _vmSection(m, theme),
          ),
          SizedBox(height: theme.spacingMd),
        ],

        // Measurement methodology
        _section(
          index: 5,
          icon: Icons.science_outlined,
          title: 'How Sleuth Measures Startup',
          accent: theme.textTertiary,
          theme: theme,
          child: _methodologySection(m, theme),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  // ── Section card ──────────────────────────────────────────────────────

  Widget _section({
    required int index,
    required IconData icon,
    required String title,
    required Color accent,
    required SleuthThemeData theme,
    required Widget child,
  }) {
    final animation = _staggered(index);
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.08),
        end: Offset.zero,
      ).animate(animation),
      child: FadeTransition(
        opacity: animation,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.sectionBackground,
            borderRadius: BorderRadius.circular(theme.radiusXxl),
            border: Border.all(color: theme.border, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
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
                    SizedBox(width: theme.spacingSm),
                    Text(
                      title,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: theme.fontLg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: child,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Headline ──────────────────────────────────────────────────────────

  Widget _headlineSection(StartupMetrics m, SleuthThemeData theme) {
    return Column(
      children: [
        if (m.ttffMs != null)
          _metricRow(
            theme,
            'Time to First Frame (TTFF)',
            '${m.ttffMs!.toStringAsFixed(1)} ms',
          ),
        if (m.ttiMs != null)
          _metricRow(
            theme,
            'Time to Interactive (TTI)',
            '${m.ttiMs!.toStringAsFixed(1)} ms',
          ),
        if (m.engineTtffMs != null)
          _metricRow(
            theme,
            'Engine TTFF',
            '${m.engineTtffMs!.toStringAsFixed(1)} ms',
            subtitle: 'FlutterEngineMainEnter \u2192 first frame rasterized',
          ),
      ],
    );
  }

  // ── First Frame Breakdown ─────────────────────────────────────────────

  Widget _firstFrameSection(StartupMetrics m, SleuthThemeData theme) {
    final total = m.firstFrameTotalMs!;
    return Column(
      children: [
        _metricRow(theme, 'Total', '${total.toStringAsFixed(1)} ms'),
        if (m.firstFrameVsyncOverheadMs != null)
          _metricBarRow(
            theme,
            'Vsync Overhead',
            m.firstFrameVsyncOverheadMs!,
            total,
            theme.textTertiary,
          ),
        if (m.firstFrameBuildMs != null)
          _metricBarRow(
            theme,
            'Build',
            m.firstFrameBuildMs!,
            total,
            theme.categoryBuild,
          ),
        if (m.firstFrameRasterMs != null)
          _metricBarRow(
            theme,
            'Raster',
            m.firstFrameRasterMs!,
            total,
            theme.categoryRaster,
          ),
        SizedBox(height: theme.spacingXs),
        if (m.dominantPhase != 'unknown')
          _infoChip(
            theme,
            m.dominantPhase == 'balanced'
                ? 'Balanced \u2014 no phase exceeds 50%'
                : 'Dominant: ${m.dominantPhase} '
                    '(${m.dominantPhasePercent.round()}% of first frame)',
          ),
      ],
    );
  }

  // ── Engine Phases ─────────────────────────────────────────────────────

  static bool _hasEngineMetrics(StartupMetrics m) =>
      m.frameworkInitMs != null ||
      m.preDartOverheadMs != null ||
      m.engineEnterUs != null;

  Widget _engineSection(StartupMetrics m, SleuthThemeData theme) {
    return Column(
      children: [
        if (m.preDartOverheadMs != null)
          _metricRow(
            theme,
            'Pre-Dart Overhead',
            '${m.preDartOverheadMs!.toStringAsFixed(1)} ms',
            subtitle: 'C++ engine init before Dart entry',
          ),
        if (m.frameworkInitMs != null)
          _metricRow(
            theme,
            'Framework Init',
            '${m.frameworkInitMs!.toStringAsFixed(1)} ms',
            subtitle: 'WidgetsFlutterBinding.ensureInitialized()',
          ),
        if (m.preDartOverheadMs == null && m.engineEnterUs == null)
          _infoChip(theme,
              'Engine timestamps not available \u2014 VM connected too late'),
      ],
    );
  }

  // ── VM Sub-Phases ─────────────────────────────────────────────────────

  static bool _hasVmMetrics(StartupMetrics m) =>
      m.vmFirstBuildScopeMs != null ||
      m.vmFirstFlushLayoutMs != null ||
      m.vmFirstFlushPaintMs != null ||
      m.vmFirstRasterMs != null;

  Widget _vmSection(StartupMetrics m, SleuthThemeData theme) {
    return Column(
      children: [
        if (m.vmFirstBuildScopeMs != null)
          _metricRow(
            theme,
            'buildScope',
            '${m.vmFirstBuildScopeMs!.toStringAsFixed(2)} ms',
          ),
        if (m.vmFirstFlushLayoutMs != null)
          _metricRow(
            theme,
            'flushLayout',
            '${m.vmFirstFlushLayoutMs!.toStringAsFixed(2)} ms',
          ),
        if (m.vmFirstFlushPaintMs != null)
          _metricRow(
            theme,
            'flushPaint',
            '${m.vmFirstFlushPaintMs!.toStringAsFixed(2)} ms',
          ),
        if (m.vmFirstRasterMs != null)
          _metricRow(
            theme,
            'raster',
            '${m.vmFirstRasterMs!.toStringAsFixed(2)} ms',
          ),
        SizedBox(height: theme.spacingXs),
        _infoChip(
          theme,
          'From VM timeline \u2014 first poll after startup. '
          '~95% reliable (ring buffer may evict early events).',
        ),
      ],
    );
  }

  // ── Measurement Methodology ───────────────────────────────────────────

  Widget _methodologySection(StartupMetrics m, SleuthThemeData theme) {
    final labelStyle = TextStyle(
      color: theme.textPrimary,
      fontSize: theme.fontMd,
      fontWeight: FontWeight.w600,
    );
    final bodyStyle =
        TextStyle(color: theme.textTertiary, fontSize: theme.fontSm);
    final dimStyle = TextStyle(
      color: theme.textQuaternary,
      fontSize: theme.fontXs,
      fontStyle: FontStyle.italic,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sleuth does NOT use flutter run --trace-startup.',
            style: labelStyle),
        SizedBox(height: theme.spacingXs),
        Text(
          'Instead, it captures startup data using two independent layers:',
          style: bodyStyle,
        ),
        SizedBox(height: theme.spacingMd),

        // Layer 1
        _methodBlock(
          theme,
          label: 'Layer 1: Direct Capture (100% reliable)',
          items: [
            'TTFF: wall-clock DateTime from Sleuth.init() to first '
                'FrameTiming raster-end callback',
            'TTI: wall-clock DateTime from Sleuth.init() to '
                'Sleuth.markInteractive()',
            'Framework init: Timeline.now delta around '
                'WidgetsFlutterBinding.ensureInitialized()',
            'First-frame phases: FrameTiming API '
                '(vsync, build, raster)',
          ],
        ),
        SizedBox(height: theme.spacingMd),

        // Layer 2
        _methodBlock(
          theme,
          label: 'Layer 2: VM Timeline Extraction (~95% reliable)',
          items: [
            'FlutterEngineMainEnter \u2014 C++ instant event '
                '(engine start timestamp)',
            'Rasterized first useful frame \u2014 instant event '
                '(engine TTFF end)',
            'buildScope / flushLayout / flushPaint / raster \u2014 '
                'duration events from first timeline poll',
            'Pre-Dart overhead = Dart entry \u2212 engine enter '
                '(same monotonic clock)',
          ],
        ),
        SizedBox(height: theme.spacingMd),

        Text(
          'Layer 2 depends on the VM timeline ring buffer. Events may be '
          'evicted if the buffer fills before Sleuth polls. This is why '
          'engine-level fields are nullable.',
          style: dimStyle,
        ),
        SizedBox(height: theme.spacingXs),
        Text(
          'Unlike --trace-startup, Sleuth works at runtime without '
          'restarting the app, and captures data in both debug and '
          'profile mode.',
          style: dimStyle,
        ),
      ],
    );
  }

  Widget _methodBlock(
    SleuthThemeData theme, {
    required String label,
    required List<String> items,
  }) {
    return Column(
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
        SizedBox(height: theme.spacingXs),
        for (final item in items)
          Padding(
            padding: EdgeInsets.only(
                left: theme.spacingMd, bottom: theme.spacingXxs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('\u2022 ',
                    style: TextStyle(
                        color: theme.textQuaternary, fontSize: theme.fontSm)),
                Expanded(
                  child: Text(
                    item,
                    style: TextStyle(
                        color: theme.textTertiary, fontSize: theme.fontSm),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── Shared metric row helpers ─────────────────────────────────────────

  Widget _metricRow(
    SleuthThemeData theme,
    String label,
    String value, {
    String? subtitle,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingSm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: theme.fontMd,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: theme.textQuaternary,
                      fontSize: theme.fontXs,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: theme.fontBase,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricBarRow(
    SleuthThemeData theme,
    String label,
    double value,
    double total,
    Color color,
  ) {
    final fraction = total > 0 ? (value / total).clamp(0.0, 1.0) : 0.0;
    final percent = (fraction * 100).round();
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                      color: theme.textSecondary, fontSize: theme.fontMd),
                ),
              ),
              Text(
                '${value.toStringAsFixed(1)} ms ($percent%)',
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: theme.fontMd,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SizedBox(height: theme.spacingXxs),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: LinearProgressIndicator(
                value: fraction,
                backgroundColor: color.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoChip(SleuthThemeData theme, String text) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(theme.spacingSm),
      decoration: BoxDecoration(
        color: theme.categoryStartup.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(theme.radiusLg),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: theme.categoryStartup,
          fontSize: theme.fontSm,
        ),
      ),
    );
  }
}
