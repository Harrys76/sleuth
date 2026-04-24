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
    this.scaffoldHashKey,
    this.tabVisitIndex = 1,
    this.hotReloadGeneration = 0,
  });

  /// Route name from `ModalRoute.of(context)?.settings.name`, or a synthetic
  /// `<unnamed-N>` when the route has no name (common with go_router shell
  /// routes, dialog routes, etc.).
  final String routeName;

  /// `identityHashCode` of the innermost visible [Scaffold] Element when this
  /// session was created, or `null` for a scaffold-free scan (overlay path).
  ///
  /// Paired with [routeName] to form the session's compound key. Under shared
  /// `ModalRoute` shells (e.g. `IndexedStack`, `StatefulShellRoute.indexedStack`,
  /// `CupertinoTabScaffold`) every tab owns a distinct Scaffold Element — so
  /// keying by `(routeName, scaffoldHashKey)` gives each tab its own session
  /// even though they all report the same route name.
  final int? scaffoldHashKey;

  /// 1-indexed ordinal of this visit to the same `(routeName, scaffoldHashKey)`
  /// pair within the controller's current route history window.
  ///
  /// Computed by the controller at session creation time. A value of `1` means
  /// this is the first recorded visit to the tab; `3` means the user has
  /// landed on this tab three times during the current debug session.
  ///
  /// Note: eviction from `_routeHistory` (governed by
  /// [SleuthConfig.routeHistoryCapacity]) can cause the index to reset to `1`
  /// once all prior sessions for the same pair have been evicted. The index is
  /// monotonic only while history retains at least one matching predecessor.
  final int tabVisitIndex;

  /// Debug-only hot-reload generation stamped at session creation. `0` in
  /// release/profile mode (no hot reload) and for the initial session before
  /// any reload has occurred. Incremented by the controller's `reassemble`
  /// hook on every Flutter hot reload so consumers can group pre/post-reload
  /// sessions — Element identity hashes rotate on reload and would otherwise
  /// orphan the prior sessions.
  final int hotReloadGeneration;

  /// The FPS target from [SleuthConfig.fpsTarget] at session creation time.
  /// Used by [healthScore] to normalise the FPS component.
  final int fpsTarget;

  /// Wall-clock time when this route became the active scan target.
  final DateTime startedAt;

  /// Wall-clock time when navigation away was detected. Null while active.
  DateTime? endedAt;

  /// Per-route frame stats ring buffer, capacity derived from [fpsTarget]
  /// so 120 Hz devices retain a full 1 s window.
  late final FrameStatsBuffer frameStats =
      FrameStatsBuffer(fpsTarget: fpsTarget);

  /// Latest snapshot of each issue observed while this route was active,
  /// keyed by `stableId ?? title`. Upserted each scan cycle — only the
  /// most recent observation is retained.
  final Map<String, PerformanceIssue> issueSnapshots = {};

  /// Number of scan cycles completed while this route was active.
  int scanCycleCount = 0;

  /// Per-widget-type rebuild counts accumulated during this session
  /// (spec v15, M6). Populated only in profile mode when
  /// [SleuthConfig.enableDeepDebugInstrumentation] is `true` — otherwise
  /// stays empty. The controller additively merges
  /// [DebugSnapshot.rebuildCounts] into this map on every scan where
  /// `DebugSnapshot.source == RebuildCountSource.flutterTimeline` (M7).
  ///
  /// KDD-5 divergence note: counts include initial widget inflations as
  /// well as actual rebuilds, because the framework emits the same
  /// `FlutterTimeline.startSync('${runtimeType}')` from `_tryRebuild`,
  /// `updateChild`, and `inflateWidget`. Route entry therefore shows a
  /// transient spike that decays as the tree stabilises. The inline
  /// `_RebuildStatsBanner` panel and the `RebuildStatsPage` drilldown
  /// disclose this caveat.
  final Map<String, int> rebuildCountsByType = {};

  /// Total profile-mode rebuilds observed during this session, summed
  /// across every widget type in [rebuildCountsByType]. Surfaced by the
  /// always-on `_RebuildStatsBanner` panel header on the floating
  /// issues card.
  int get totalRebuilds =>
      rebuildCountsByType.values.fold<int>(0, (a, b) => a + b);

  /// Whether this route is still the active scan target.
  bool get isActive => endedAt == null;

  /// Time spent on this route (wall-clock).
  Duration get duration => (endedAt ?? DateTime.now()).difference(startedAt);

  /// Composite health score (0–100).
  ///
  /// - **FPS component** (40 pts max): `(throughputFps / fpsTarget * 40)`
  /// - **Jank penalty** (30 pts max): `(jankFrames / totalFrames * 30)`
  /// - **Issue penalty** (30 pts max): `criticalCount*10 + warningCount*3`
  ///
  /// 100 = perfect (target FPS, no jank, no issues). 0 = severely degraded.
  /// Returns 100 when no frames have been recorded (no data = no problems).
  ///
  /// Uses [FrameStatsBuffer.throughputFps] (latency-derived) not
  /// [FrameStatsBuffer.actualFps] (count-based) because health scoring
  /// needs to be robust to low sample counts (startup, idle, navigation)
  /// where `actualFps` collapses toward the frame count while
  /// `throughputFps` remains representative per-frame.
  int get healthScore {
    final total = frameStats.length;

    // No frames recorded yet — no data to judge, assume healthy.
    if (total == 0 && issueSnapshots.isEmpty) return 100;

    final fps = frameStats.throughputFps;
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
      if (scaffoldHashKey != null) 'scaffoldHashKey': scaffoldHashKey,
      'tabVisitIndex': tabVisitIndex,
      if (hotReloadGeneration > 0) 'hotReloadGeneration': hotReloadGeneration,
      'startedAt': startedAt.toIso8601String(),
      if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
      'healthScore': healthScore,
      'durationSeconds': duration.inSeconds,
      'scanCycles': scanCycleCount,
      'frameStats': {
        'totalFrames': frameStats.length,
        'jankFrames': frameStats.jankCount,
        'averageFps': double.parse(
          frameStats.throughputFps
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
      // M6 / KDD-7: purely additive optional field. Emitted only when
      // non-empty so debug-mode exports (which never populate this map)
      // stay byte-identical to v0.14.1 and the schema stays at v4.
      if (rebuildCountsByType.isNotEmpty)
        'rebuildCountsByType': Map<String, int>.of(rebuildCountsByType),
      if (rebuildCountsByType.isNotEmpty) 'totalRebuilds': totalRebuilds,
    };
  }
}
