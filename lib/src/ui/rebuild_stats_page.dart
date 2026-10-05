import 'package:flutter/material.dart';

import 'motion.dart';
import 'sleuth_theme.dart';

/// Full-screen drilldown page showing every widget type rebuilt during the
/// active [RouteSession]'s lifetime, sorted descending by count.
///
/// Opened by tapping the "See all N →" drilldown link inside the expanded
/// `_RebuildStatsBanner` panel on the floating issues card. Mirrors the
/// [Positioned.fill] overlay chrome used by
/// [StartupMetricsPage] / [GuidePage] so it composes identically inside the
/// floating card's overlay stack.
///
/// **Snapshot semantics (spec v15 M10):** the counts map passed into the
/// constructor is copied at open time and never live-updates. If the user
/// navigates to another route (or the underlying session is cleared) while
/// the page is open, the displayed data reflects the moment of the tap.
/// This is deliberate — live-updating a drilldown while the user reads it
/// would shuffle rows underneath them, and profile-mode inflations (KDD-5)
/// make per-scan churn noisy.
class RebuildStatsPage extends StatefulWidget {
  RebuildStatsPage({
    super.key,
    required this.routeDisplayName,
    required Map<String, int> countsByType,
    required this.onClose,
  }) : // Defensive copy + stable sort at construction time. Callers pass a
       // live reference into [RouteSession.rebuildCountsByType]; mutating the
       // session after open must not reorder rows or change totals.
       _sortedEntries = _sortDescending(countsByType),
       _totalRebuilds = countsByType.values.fold<int>(0, (sum, v) => sum + v);

  /// Human-facing route label shown in the header subtitle. May be null when
  /// the rollup fired for a route without a display name — rare but possible
  /// for bare overlay paths.
  final String? routeDisplayName;

  /// Called when the user dismisses the page (back button or header chevron).
  final VoidCallback onClose;

  final List<MapEntry<String, int>> _sortedEntries;
  final int _totalRebuilds;

  static List<MapEntry<String, int>> _sortDescending(Map<String, int> counts) {
    final entries = counts.entries.toList(growable: false);
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  @override
  State<RebuildStatsPage> createState() => _RebuildStatsPageState();
}

class _RebuildStatsPageState extends State<RebuildStatsPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      duration: const Duration(milliseconds: 450),
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

  /// The summary chips and the inflation disclaimer, first item of the
  /// list.
  ///
  /// The disclaimer (KDD-5 + KDD-10) sits immediately below the summary
  /// chips so a user sees the caveat BEFORE forming a mental model from
  /// the row labels. It is set in `fontSm` + `textSecondary` with an info
  /// icon so it doesn't read like a footnote, and notes that Sleuth's own
  /// overlay widgets are excluded, so the drilldown reflects the app only.
  Widget _buildListLead(SleuthThemeData theme, int total, int types) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FadeTransition(
            opacity: _entranceController,
            // The chips wrap onto a second line at large text.
            child: Wrap(
              spacing: theme.spacingSm,
              runSpacing: theme.spacingSm,
              children: [
                _SummaryChip(
                  theme: theme,
                  label: 'Total',
                  value: total.toString(),
                ),
                _SummaryChip(
                  theme: theme,
                  label: 'Types',
                  value: types.toString(),
                ),
              ],
            ),
          ),
          SizedBox(height: theme.spacingSm + theme.spacingXs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: theme.spacingXxs),
                child: Icon(
                  Icons.info_outline,
                  size: 14,
                  color: theme.textSecondary,
                ),
              ),
              SizedBox(width: theme.spacingXs),
              Expanded(
                child: Text(
                  'Profile-mode counts include initial widget '
                  'inflations as well as rebuilds — route entry '
                  'shows transient elevated counts that decay as '
                  'the tree stabilises. Sleuth\u2019s own overlay '
                  'widgets are excluded from the drain.',
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: theme.fontSm,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final entries = widget._sortedEntries;
    final total = widget._totalRebuilds;
    final topCount = entries.isEmpty ? 0 : entries.first.value;

    // Route semantics: screen readers announce the page name. While a
    // page is open, `SleuthOverlay` drops the app's nodes below it.
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Rebuild stats',
      child: Material(
        color: theme.pageBackground,
        child: SafeArea(
          child: Column(
            children: [
              // Header
              FadeTransition(
                opacity: _entranceController,
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
                        Icons.loop_outlined,
                        color: theme.categoryBuild,
                        size: 18,
                      ),
                      SizedBox(width: theme.spacingXs),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Title and route wrap at large text.
                            Text(
                              'Rebuild Stats',
                              softWrap: true,
                              style: TextStyle(
                                color: theme.textPrimary,
                                fontSize: theme.fontXl,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (widget.routeDisplayName != null)
                              Text(
                                widget.routeDisplayName!,
                                style: TextStyle(
                                  color: theme.textTertiary,
                                  fontSize: theme.fontSm,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(color: theme.border, height: 1),

              // Content. The summary chips and the disclaimer lead the
              // list and scroll with it, so large text on a short screen
              // never pushes the rows off the page.
              Expanded(
                child: entries.isEmpty
                    ? _EmptyState(theme: theme)
                    : ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          theme.spacingXl,
                          theme.spacingLg,
                          theme.spacingXl,
                          24,
                        ),
                        itemCount: entries.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return _buildListLead(theme, total, entries.length);
                          }
                          final i = index - 1;
                          final entry = entries[i];
                          final fraction = topCount == 0
                              ? 0.0
                              : entry.value / topCount;
                          return _RebuildRow(
                            theme: theme,
                            rank: i + 1,
                            typeName: entry.key,
                            count: entry.value,
                            barFraction: fraction,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.theme});

  final SleuthThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(theme.spacingXl),
      child: Center(
        child: Text(
          'No rebuilds recorded for this session.',
          style: TextStyle(color: theme.textTertiary, fontSize: theme.fontBase),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.theme,
    required this.label,
    required this.value,
  });

  final SleuthThemeData theme;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.categoryBuild.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(theme.radiusLg),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: theme.spacingMd,
          vertical: theme.spacingXs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: theme.textTertiary,
                fontSize: theme.fontXs,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: theme.spacingXs),
            Text(
              value,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: theme.fontMd,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RebuildRow extends StatelessWidget {
  const _RebuildRow({
    required this.theme,
    required this.rank,
    required this.typeName,
    required this.count,
    required this.barFraction,
  });

  final SleuthThemeData theme;
  final int rank;
  final String typeName;
  final int count;
  final double barFraction;

  @override
  Widget build(BuildContext context) {
    // The rank column grows with the text, so `10.` keeps one line.
    final rankWidth = MediaQuery.textScalerOf(context).scale(28);
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacingSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: rankWidth,
                child: Text(
                  '$rank.',
                  style: TextStyle(
                    color: theme.textQuaternary,
                    fontSize: theme.fontSm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  typeName,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: theme.fontMd,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: theme.spacingSm),
              Text(
                '×$count',
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: theme.fontMd,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          SizedBox(height: theme.spacingXxs),
          Padding(
            padding: EdgeInsets.only(left: rankWidth),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  value: barFraction.clamp(0.0, 1.0),
                  backgroundColor: theme.categoryBuild.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    theme.categoryBuild,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
