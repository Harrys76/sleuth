import '../models/frame_verdict.dart';
import '../models/performance_issue.dart';

/// Environmental signals used by [IssueRanker] to score issues.
class IssueRankingContext {
  const IssueRankingContext({
    this.jankActive = false,
    this.suspectedPhase,
    this.recurrenceCounts = const {},
  });

  /// Whether sustained jank is currently detected (FrameTimingDetector has issues).
  final bool jankActive;

  /// The suspected pipeline phase bottleneck, derived from the latest janky frame.
  /// Null when no jank or when the latest frame is not janky.
  final PipelinePhase? suspectedPhase;

  /// Consecutive scan-cycle count per stableId. Updated only from the scan path
  /// to prevent VM-backed issues from inflating faster than structural ones.
  final Map<String, int> recurrenceCounts;
}

/// Sorts [PerformanceIssue]s by a weighted composite score so that the most
/// impactful issues appear first in the dashboard.
///
/// Score formula: `(severity * 100) + (frameImpact * 8) + (confidence * 5) + (recurrence * 2)`
///
/// Severity weight 100 creates non-overlapping tiers (critical: 300-349,
/// warning: 200-249, ok: 100-149), guaranteeing every critical outranks every
/// warning regardless of other signals.
class IssueRanker {
  const IssueRanker();

  /// Returns a new list sorted descending by composite score.
  /// Equal-score issues preserve their input order (explicit index tiebreaker).
  List<PerformanceIssue> rank(
    List<PerformanceIssue> issues,
    IssueRankingContext context,
  ) {
    if (issues.length <= 1) return issues;
    final scored = <({PerformanceIssue issue, int score, int index})>[];
    for (var i = 0; i < issues.length; i++) {
      scored.add((
        issue: issues[i],
        score: _score(issues[i], context),
        index: i,
      ));
    }
    scored.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      return a.index.compareTo(b.index);
    });
    return scored.map((s) => s.issue).toList();
  }

  /// Returns a new list sorted by score with [PerformanceIssue.rankingScore]
  /// and [PerformanceIssue.rankingBreakdown] attached via copyWith.
  ///
  /// More expensive than [rank] due to copyWith allocations — intended for
  /// the export path only, not the per-scan hot path.
  List<PerformanceIssue> rankWithScores(
    List<PerformanceIssue> issues,
    IssueRankingContext context,
  ) {
    if (issues.isEmpty) return issues;
    final scored = <({PerformanceIssue issue, int score, int index})>[];
    for (var i = 0; i < issues.length; i++) {
      scored.add((
        issue: issues[i],
        score: _score(issues[i], context),
        index: i,
      ));
    }
    scored.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      return a.index.compareTo(b.index);
    });
    return scored
        .map((s) => s.issue.copyWith(
              rankingScore: s.score,
              rankingBreakdown: _breakdown(s.issue, context),
            ))
        .toList();
  }

  /// Visible for testing.
  int scoreOf(PerformanceIssue issue, IssueRankingContext context) =>
      _score(issue, context);

  int _score(PerformanceIssue issue, IssueRankingContext context) {
    var recurrence = _recurrenceScore(
        issue.stableId ?? issue.title, context.recurrenceCounts);
    // Deprioritize scrolling-context issues — they're usually transient
    if (issue.interactionContext == InteractionContext.scrolling) {
      recurrence = (recurrence * 0.7).round();
    }
    return (_severityScore(issue.severity) * 100) +
        (_frameImpactScore(issue.category, context) * 8) +
        (_confidenceScore(issue.confidence) * 5) +
        (recurrence * 2);
  }

  int _severityScore(IssueSeverity s) => switch (s) {
        IssueSeverity.critical => 3,
        IssueSeverity.warning => 2,
        IssueSeverity.ok => 1,
      };

  int _confidenceScore(IssueConfidence c) => switch (c) {
        IssueConfidence.confirmed => 3,
        IssueConfidence.likely => 2,
        IssueConfidence.possible => 1,
      };

  int _frameImpactScore(IssueCategory category, IssueRankingContext ctx) {
    if (!ctx.jankActive) return 0;
    final phase = ctx.suspectedPhase;
    if (phase == null || phase == PipelinePhase.unknown) return 1;
    final isUiThread = phase == PipelinePhase.build ||
        phase == PipelinePhase.layout ||
        phase == PipelinePhase.paint;
    final isRasterThread = phase == PipelinePhase.raster;
    final matches = (isUiThread &&
            (category == IssueCategory.build ||
                category == IssueCategory.layout ||
                category == IssueCategory.paint)) ||
        (isRasterThread && category == IssueCategory.raster);
    return matches ? 3 : 1;
  }

  int _recurrenceScore(String id, Map<String, int> counts) {
    final count = counts[id] ?? 0;
    return count.clamp(0, 5);
  }

  Map<String, int> _breakdown(
      PerformanceIssue issue, IssueRankingContext context) {
    var recurrence = _recurrenceScore(
        issue.stableId ?? issue.title, context.recurrenceCounts);
    if (issue.interactionContext == InteractionContext.scrolling) {
      recurrence = (recurrence * 0.7).round();
    }
    return {
      'severity': _severityScore(issue.severity) * 100,
      'frameImpact': _frameImpactScore(issue.category, context) * 8,
      'confidence': _confidenceScore(issue.confidence) * 5,
      'recurrence': recurrence * 2,
    };
  }
}
