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

  /// Scan cycles, within the recurrence window (the last 60), in which each
  /// stableId was present, for ids present in the latest cycle; the
  /// controller caps it at 5. Updated only from the scan path to prevent
  /// VM-backed issues from inflating faster than structural ones.
  final Map<String, int> recurrenceCounts;
}

/// Sorts [PerformanceIssue]s by a weighted composite score so that the most
/// impactful issues appear first in the dashboard.
///
/// Score formula: `(tier * 100) + (frameImpact * 8) + (recurrence * 2)`
///
/// The tier combines severity and confidence:
///
/// | severity | confirmed | likely | possible |
/// |----------|-----------|--------|----------|
/// | critical | 6         | 5      | 3        |
/// | warning  | 4         | 2      | 1        |
/// | ok       | 0         | 0      | 0        |
///
/// Resulting order: confirmed critical > likely critical > confirmed
/// warning > possible critical > likely warning > possible warning > ok.
/// A structural-only guess (possible) ranks below a warning that was
/// observed at runtime (confirmed). The maximum bonus (frameImpact 24 +
/// recurrence 10 = 34) stays below the 100-point tier gap, so bonuses
/// order issues within a tier and never across tiers.
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
        .map(
          (s) => s.issue.copyWith(
            rankingScore: s.score,
            rankingBreakdown: _breakdown(s.issue, context),
          ),
        )
        .toList();
  }

  /// Visible for testing.
  int scoreOf(PerformanceIssue issue, IssueRankingContext context) =>
      _score(issue, context);

  int _score(PerformanceIssue issue, IssueRankingContext context) {
    var recurrence = _recurrenceScore(
      issue.stableId ?? issue.title,
      context.recurrenceCounts,
    );
    // Deprioritize transient-context issues
    if (_isTransientContext(issue.interactionContext)) {
      recurrence = (recurrence * 0.7).round();
    }
    return (_tier(issue.severity, issue.confidence) * 100) +
        (_frameImpactScore(issue.category, context) * 8) +
        (recurrence * 2);
  }

  /// Evidence tier from severity and confidence. See the class doc.
  int _tier(IssueSeverity s, IssueConfidence c) => switch (s) {
    IssueSeverity.critical => switch (c) {
      IssueConfidence.confirmed => 6,
      IssueConfidence.likely => 5,
      IssueConfidence.possible => 3,
    },
    IssueSeverity.warning => switch (c) {
      IssueConfidence.confirmed => 4,
      IssueConfidence.likely => 2,
      IssueConfidence.possible => 1,
    },
    IssueSeverity.ok => 0,
  };

  /// Severity share of the tier score, reported as the `severity`
  /// breakdown entry. The remainder is reported as `confidence`.
  int _severityBase(IssueSeverity s) => switch (s) {
    IssueSeverity.critical => 400,
    IssueSeverity.warning => 200,
    IssueSeverity.ok => 0,
  };

  int _frameImpactScore(IssueCategory category, IssueRankingContext ctx) {
    if (!ctx.jankActive) return 0;
    final phase = ctx.suspectedPhase;
    if (phase == null || phase == PipelinePhase.unknown) return 1;
    final isUiThread =
        phase == PipelinePhase.build ||
        phase == PipelinePhase.layout ||
        phase == PipelinePhase.paint;
    final isRasterThread = phase == PipelinePhase.raster;
    final matches =
        (isUiThread &&
            (category == IssueCategory.build ||
                category == IssueCategory.layout ||
                category == IssueCategory.paint)) ||
        (isRasterThread && category == IssueCategory.raster);
    return matches ? 3 : 1;
  }

  /// Scrolling, navigating, and app-lifecycle transitions produce
  /// transient work; their recurrence counts for 70 %.
  static bool _isTransientContext(InteractionContext? c) =>
      c == InteractionContext.scrolling ||
      c == InteractionContext.navigating ||
      c == InteractionContext.appLifecycle;

  int _recurrenceScore(String id, Map<String, int> counts) {
    final count = counts[id] ?? 0;
    return count.clamp(0, 5);
  }

  Map<String, int> _breakdown(
    PerformanceIssue issue,
    IssueRankingContext context,
  ) {
    var recurrence = _recurrenceScore(
      issue.stableId ?? issue.title,
      context.recurrenceCounts,
    );
    if (_isTransientContext(issue.interactionContext)) {
      recurrence = (recurrence * 0.7).round();
    }
    final base = _severityBase(issue.severity);
    return {
      'severity': base,
      'frameImpact': _frameImpactScore(issue.category, context) * 8,
      'confidence': _tier(issue.severity, issue.confidence) * 100 - base,
      'recurrence': recurrence * 2,
    };
  }
}
