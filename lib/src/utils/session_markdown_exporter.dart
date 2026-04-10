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
    buf.writeln('- Average FPS: **${stats.averageFps.round()}**');
    buf.writeln(
        '- Worst frame: **${(stats.worstFrameTimeUs / 1000).round()} ms**');
    buf.writeln(
        '- Jank frames: **${stats.jankFrames} / ${stats.totalFrames}**');
    buf.writeln();

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
