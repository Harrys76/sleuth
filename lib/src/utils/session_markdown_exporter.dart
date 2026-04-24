import '../models/session_snapshot.dart';

/// Renders a [SessionSnapshot] as GitHub-flavoured markdown suitable for
/// pasting into Slack, a PR description, or a bug report.
///
/// Layout (subject to test-verified line-for-line stability):
///
/// ```
/// # Sleuth Session Summary
///
/// **Captured:** 2026-04-09 14:23:11
///
/// ## Frame Stats
/// - Average FPS: **58**
/// - Worst frame: **34 ms**
/// - Jank frames: **3 / 2,410**
///
/// ## Top Issues (5)
/// 1. **Heavy Build: 23.4ms** — `heavy_compute`
///    > VM timeline long UI-thread event during route `/checkout`.
/// ...
///
/// ## Causal Chains
/// - `excessive_global_keys` → `rebuild_activity`
/// ...
///
/// _Exported by Sleuth v0.12.0_
/// ```
class SessionMarkdownExporter {
  SessionMarkdownExporter._();

  static String render(SessionSnapshot snapshot, {required int topN}) {
    final buf = StringBuffer();
    // Header
    buf.writeln('# Sleuth Session Summary');
    buf.writeln();
    buf.writeln('**Captured:** ${_formatTs(snapshot.exportedAt)}');
    buf.writeln();

    // Frame stats
    final stats = snapshot.frameStatsSummary;
    buf.writeln('## Frame Stats');
    buf.writeln('- Actual FPS: **${stats.actualFps.round()}**');
    buf.writeln('- Throughput FPS: **${stats.throughputFps.round()}**');
    buf.writeln(
        '- Worst frame: **${(stats.worstFrameTimeUs / 1000).round()} ms**');
    buf.writeln(
        '- Jank frames: **${stats.jankFrames} / ${stats.totalFrames}**');
    buf.writeln();

    // Startup metrics
    final startup = snapshot.startupMetrics;
    if (startup != null) {
      buf.writeln('## Startup');
      if (startup.ttffMs != null) {
        buf.writeln('- Time to first frame: **${startup.ttffMs!.round()} ms**');
      }
      if (startup.ttiMs != null) {
        buf.writeln('- Time to interactive: **${startup.ttiMs!.round()} ms**');
      }
      if (startup.dominantPhase != 'unknown') {
        buf.writeln('- Dominant phase: **${startup.dominantPhase}** '
            '(${startup.dominantPhasePercent.round()}%)');
      }
      if (startup.frameworkInitMs != null) {
        buf.writeln('- Framework init: '
            '**${startup.frameworkInitMs!.toStringAsFixed(1)} ms**');
      }
      if (startup.preDartOverheadMs != null) {
        buf.writeln('- Pre-Dart overhead: '
            '**${startup.preDartOverheadMs!.toStringAsFixed(1)} ms**');
      }
      if (startup.engineTtffMs != null) {
        buf.writeln('- Engine TTFF: '
            '**${startup.engineTtffMs!.toStringAsFixed(1)} ms**');
      }
      buf.writeln();
    }

    // Route health
    final routes = snapshot.routeSessions;
    if (routes != null && routes.isNotEmpty) {
      buf.writeln('## Route Health');
      buf.writeln('| Route | Score | FPS | Issues | Time |');
      buf.writeln('|-------|-------|-----|--------|------|');
      for (final r in routes) {
        // Disambiguate multiple visits to the same (routeName, scaffoldHashKey)
        // by suffixing the tab ordinal. Without this, every row in a
        // bottom-nav app that returned to the same tab would render with an
        // identical `routeName` cell and look like duplicate data.
        final rawName = r['routeName'] as String? ?? '?';
        final tabIdx = r['tabVisitIndex'] as int? ?? 1;
        final displayName = tabIdx > 1 ? '$rawName (tab-$tabIdx)' : rawName;
        final name = _escape(displayName);
        final score = r['healthScore'] as int? ?? 0;
        final dot = score >= 80
            ? '\u{1F7E2}'
            : score >= 50
                ? '\u{1F7E1}'
                : '\u{1F534}';
        final fps = r['frameStats'] is Map
            ? (r['frameStats'] as Map)['averageFps'] ?? '-'
            : '-';
        final issueCount = r['issueCount'] as int? ?? 0;
        final criticalCount = r['criticalCount'] as int? ?? 0;
        final issues =
            criticalCount > 0 ? '$issueCount ($criticalCount!)' : '$issueCount';
        final durationSec = r['durationSeconds'] as int? ?? 0;
        final time = _formatDuration(durationSec);
        buf.writeln('| $name | $score $dot | $fps | $issues | $time |');
      }
      buf.writeln();
    }

    // Top issues
    final top = snapshot.currentIssues.take(topN).toList();
    if (top.isNotEmpty) {
      buf.writeln('## Top Issues (${top.length})');
      for (final (i, issue) in top.indexed) {
        buf.writeln('${i + 1}. **${_escape(issue.title)}** — '
            '`${issue.stableId ?? issue.category.name}`');
        if (issue.confidenceReason != null) {
          buf.writeln('   > ${_escape(issue.confidenceReason!)}');
        }
      }
      buf.writeln();
    }

    // Causal chains from sessionSummary
    final causalEdges = snapshot.sessionSummary?['causalEdges'];
    if (causalEdges is List && causalEdges.isNotEmpty) {
      buf.writeln('## Causal Chains');
      for (final edge in causalEdges.take(5)) {
        if (edge is Map) {
          buf.writeln('- `${edge['cause']}` → `${edge['effect']}`');
        }
      }
      buf.writeln();
    }

    buf.write('_Exported by Sleuth v${snapshot.packageVersion}_');
    return buf.toString();
  }

  static String _formatTs(DateTime ts) =>
      '${ts.year.toString().padLeft(4, '0')}-'
      '${ts.month.toString().padLeft(2, '0')}-'
      '${ts.day.toString().padLeft(2, '0')} '
      '${ts.hour.toString().padLeft(2, '0')}:'
      '${ts.minute.toString().padLeft(2, '0')}:'
      '${ts.second.toString().padLeft(2, '0')}';

  static String _formatDuration(int totalSeconds) {
    if (totalSeconds < 60) return '${totalSeconds}s';
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return s > 0 ? '${m}m ${s.toString().padLeft(2, '0')}s' : '${m}m';
  }

  static String _escape(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll('*', r'\*')
      .replaceAll('`', r'\`')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]')
      .replaceAll('<', r'\<')
      .replaceAll('>', r'\>')
      .replaceAll('|', r'\|');
}
