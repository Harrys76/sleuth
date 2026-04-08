import 'performance_issue.dart';

/// Aggregated performance cost for a single widget across all detectors.
///
/// Used by the "top offenders" heat map to rank widgets by cumulative
/// impact. Computed lazily on demand — never in the scan loop hot path.
class WidgetHeatMapEntry implements Comparable<WidgetHeatMapEntry> {
  const WidgetHeatMapEntry({
    required this.widgetName,
    required this.issueCount,
    required this.totalRankingScore,
    required this.detectorStableIds,
    required this.worstSeverity,
  });

  /// Widget name (from [PerformanceIssue.widgetName]).
  final String widgetName;

  /// Number of distinct issues attributed to this widget.
  final int issueCount;

  /// Sum of [PerformanceIssue.rankingScore] across all issues for this widget.
  /// Zero when ranking scores haven't been computed (pre-export path).
  final int totalRankingScore;

  /// Distinct stableIds of issues attributed to this widget.
  final List<String> detectorStableIds;

  /// Highest severity observed across all issues for this widget.
  final IssueSeverity worstSeverity;

  /// Sort by totalRankingScore descending (highest first).
  @override
  int compareTo(WidgetHeatMapEntry other) =>
      other.totalRankingScore.compareTo(totalRankingScore);

  Map<String, dynamic> toJson() => {
        'widgetName': widgetName,
        'issueCount': issueCount,
        'totalRankingScore': totalRankingScore,
        'detectorStableIds': detectorStableIds,
        'worstSeverity': worstSeverity.name,
      };

  factory WidgetHeatMapEntry.fromJson(Map<String, dynamic> json) =>
      WidgetHeatMapEntry(
        widgetName: json['widgetName'] as String,
        issueCount: json['issueCount'] as int,
        totalRankingScore: json['totalRankingScore'] as int,
        detectorStableIds:
            (json['detectorStableIds'] as List<dynamic>).cast<String>(),
        worstSeverity:
            IssueSeverity.values.byName(json['worstSeverity'] as String),
      );
}

/// Framework widget names to exclude from the heat map.
/// These are too generic to be actionable — the developer needs to know
/// which of *their* widgets is the hottest, not that "Column" has issues.
const _frameworkPrefixes = <String>[
  // Layout primitives
  'Column',
  'Row',
  'Flex',
  'Padding',
  'SizedBox',
  'Container',
  'Center',
  'Align',
  'Expanded',
  'Flexible',
  'Stack',
  'Positioned',
  'Wrap',
  'Spacer',
  'Divider',
  // Scrollables
  'ListView',
  'GridView',
  'SingleChildScrollView',
  'CustomScrollView',
  'NestedScrollView',
  // Scaffold & chrome
  'Scaffold',
  'Material',
  'AppBar',
  'BottomNavigationBar',
  'NavigationBar',
  'FloatingActionButton',
  'Drawer',
  'BottomSheet',
  'Dialog',
  'Card',
  'Chip',
  // Buttons
  'ElevatedButton',
  'TextButton',
  'OutlinedButton',
  'IconButton',
  // Builders
  'Builder',
  'LayoutBuilder',
  'StreamBuilder',
  'FutureBuilder',
  'ValueListenableBuilder',
  'AnimatedBuilder',
  // Painting & clipping
  'RepaintBoundary',
  'Offstage',
  'Opacity',
  'Transform',
  'ClipRect',
  'ClipRRect',
  'ClipOval',
  'DecoratedBox',
  // Sizing constraints
  'ConstrainedBox',
  'UnconstrainedBox',
  'FractionallySizedBox',
  'IntrinsicHeight',
  'IntrinsicWidth',
  // Text
  'RichText',
  'Text',
];

/// Build a heat map from a list of issues, filtering out framework widgets
/// and returning the top [maxEntries] by total ranking score.
List<WidgetHeatMapEntry> buildWidgetHeatMap(
  List<PerformanceIssue> issues, {
  int maxEntries = 10,
}) {
  final byWidget = <String, _Accumulator>{};

  for (final issue in issues) {
    final name = issue.widgetName;
    if (name == null || name.isEmpty) continue;
    if (_frameworkPrefixes.contains(name)) continue;

    final acc = byWidget.putIfAbsent(name, () => _Accumulator(name));
    acc.issueCount++;
    acc.totalScore += issue.rankingScore ?? 0;
    if (issue.stableId != null && !acc.stableIds.contains(issue.stableId)) {
      acc.stableIds.add(issue.stableId!);
    }
    if (issue.severity.index > acc.worstSeverityIndex) {
      acc.worstSeverityIndex = issue.severity.index;
    }
  }

  final entries = byWidget.values.map((a) => a.toEntry()).toList()..sort();
  if (entries.length <= maxEntries) return entries;
  return entries.sublist(0, maxEntries);
}

class _Accumulator {
  _Accumulator(this.widgetName);

  final String widgetName;
  int issueCount = 0;
  int totalScore = 0;
  final List<String> stableIds = [];
  int worstSeverityIndex = 0;

  WidgetHeatMapEntry toEntry() => WidgetHeatMapEntry(
        widgetName: widgetName,
        issueCount: issueCount,
        totalRankingScore: totalScore,
        detectorStableIds: List.unmodifiable(stableIds),
        worstSeverity: IssueSeverity.values[worstSeverityIndex],
      );
}
