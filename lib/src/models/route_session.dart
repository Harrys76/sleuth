import 'dart:math' as math;

import 'frame_stats.dart';
import 'performance_issue.dart';

/// Per-route statistics accumulated while a route is the active scan target.
///
/// Created when Sleuth detects a route change (via passive element-tree
/// inspection) and closed when the next route becomes active. The
/// [healthScore] provides a 0–100 composite summarising FPS, jank ratio,
/// and issue severity for that route.
class RouteSession {
  RouteSession({
    required this.routeName,
    required this.startedAt,
    this.fpsTarget = 60,
  });

  /// Route name from `ModalRoute.of(context)?.settings.name`, or a synthetic
  /// `<unnamed-N>` when the route has no name (common with go_router shell
  /// routes, dialog routes, etc.).
  final String routeName;

  /// The FPS target from [SleuthConfig.fpsTarget] at session creation time.
  /// Used by [healthScore] to normalise the FPS component.
  final int fpsTarget;

  /// Wall-clock time when this route became the active scan target.
  final DateTime startedAt;

  /// Wall-clock time when navigation away was detected. Null while active.
  DateTime? endedAt;

  /// Per-route frame stats ring buffer (capacity 60, same as global).
  final FrameStatsBuffer frameStats = FrameStatsBuffer(capacity: 60);

  /// Latest snapshot of each issue observed while this route was active,
  /// keyed by `stableId ?? title`. Upserted each scan cycle — only the
  /// most recent observation is retained.
  final Map<String, PerformanceIssue> issueSnapshots = {};

  /// Number of scan cycles completed while this route was active.
  int scanCycleCount = 0;

  /// Whether this route is still the active scan target.
  bool get isActive => endedAt == null;

  /// Time spent on this route (wall-clock).
  Duration get duration => (endedAt ?? DateTime.now()).difference(startedAt);

  /// Composite health score (0–100).
  ///
  /// - **FPS component** (40 pts max): `(averageFps / fpsTarget * 40)`
  /// - **Jank penalty** (30 pts max): `(jankFrames / totalFrames * 30)`
  /// - **Issue penalty** (30 pts max): `criticalCount*10 + warningCount*3`
  ///
  /// 100 = perfect (target FPS, no jank, no issues). 0 = severely degraded.
  /// Returns 100 when no frames have been recorded (no data = no problems).
  int get healthScore {
    final total = frameStats.length;

    // No frames recorded yet — no data to judge, assume healthy.
    if (total == 0 && issueSnapshots.isEmpty) return 100;

    final fps = frameStats.averageFps;
    final jank = frameStats.jankCount;

    // FPS component: 40 points max. When no frames, grant full 40.
    final target = fpsTarget > 0 ? fpsTarget.toDouble() : 60.0;
    final fpsComponent =
        total == 0 ? 40.0 : (fps / target * 40.0).clamp(0.0, 40.0);

    // Jank penalty: 30 points max
    final jankRatio = total > 0 ? jank / total : 0.0;
    final jankPenalty = (jankRatio * 30.0).clamp(0.0, 30.0);

    // Issue penalty: 30 points max
    int criticalCount = 0;
    int warningCount = 0;
    for (final issue in issueSnapshots.values) {
      if (issue.severity == IssueSeverity.critical) {
        criticalCount++;
      } else if (issue.severity == IssueSeverity.warning) {
        warningCount++;
      }
    }
    final issuePenalty =
        math.min(criticalCount * 10 + warningCount * 3, 30).toDouble();

    return (fpsComponent + (30.0 - jankPenalty) + (30.0 - issuePenalty))
        .round()
        .clamp(0, 100);
  }

  /// Serialise for export (SessionSnapshot v4+).
  Map<String, dynamic> toJson() {
    int criticalCount = 0;
    int warningCount = 0;
    for (final issue in issueSnapshots.values) {
      if (issue.severity == IssueSeverity.critical) {
        criticalCount++;
      } else if (issue.severity == IssueSeverity.warning) {
        warningCount++;
      }
    }

    return {
      'routeName': routeName,
      'startedAt': startedAt.toIso8601String(),
      if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
      'healthScore': healthScore,
      'durationSeconds': duration.inSeconds,
      'scanCycles': scanCycleCount,
      'frameStats': {
        'totalFrames': frameStats.length,
        'jankFrames': frameStats.jankCount,
        'averageFps': double.parse(
          frameStats.averageFps
              .clamp(0.0, fpsTarget.toDouble())
              .toStringAsFixed(1),
        ),
        if (frameStats.length >= 2)
          ...() {
            final p = frameStats.fpsPercentiles();
            final cap = fpsTarget.toDouble();
            return {
              'p50': p.p50.clamp(0.0, cap),
              'p95': p.p95.clamp(0.0, cap),
              'p99': p.p99.clamp(0.0, cap),
            };
          }(),
      },
      'issueCount': issueSnapshots.length,
      'criticalCount': criticalCount,
      'warningCount': warningCount,
      'issues': issueSnapshots.keys.toList(),
    };
  }
}
