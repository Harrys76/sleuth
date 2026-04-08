import 'performance_issue.dart';

/// Categorization of an issue's change between baseline and current state.
enum FixVerificationStatus {
  /// Issue was present in baseline, absent for [cooldownCycles]+ cycles.
  resolved,

  /// Issue is still present but with lower severity or ranking score.
  improved,

  /// Issue is still present and unchanged.
  unchanged,

  /// Issue is still present with higher severity or ranking score.
  worsened,

  /// Issue was not in baseline — appeared after the fix.
  newIssue,
}

/// An individual issue's change between baseline and current state.
class IssueVerificationEntry {
  const IssueVerificationEntry({
    required this.stableId,
    required this.status,
    this.baselineSeverity,
    this.currentSeverity,
    this.baselineScore,
    this.currentScore,
  });

  /// The issue's stableId for tracking.
  final String stableId;

  /// How this issue changed.
  final FixVerificationStatus status;

  /// Severity at baseline capture. Null for [newIssue].
  final IssueSeverity? baselineSeverity;

  /// Current severity. Null for [resolved].
  final IssueSeverity? currentSeverity;

  /// Ranking score at baseline capture. Null for [newIssue].
  final int? baselineScore;

  /// Current ranking score. Null for [resolved].
  final int? currentScore;

  Map<String, dynamic> toJson() => {
        'stableId': stableId,
        'status': status.name,
        if (baselineSeverity != null)
          'baselineSeverity': baselineSeverity!.name,
        if (currentSeverity != null) 'currentSeverity': currentSeverity!.name,
        if (baselineScore != null) 'baselineScore': baselineScore,
        if (currentScore != null) 'currentScore': currentScore,
      };
}

/// Result of comparing current issues against a captured baseline.
class FixVerificationResult {
  const FixVerificationResult({
    required this.baselineCapturedAt,
    required this.comparedAt,
    required this.entries,
  });

  /// When the baseline was captured.
  final DateTime baselineCapturedAt;

  /// When the comparison was performed.
  final DateTime comparedAt;

  /// Per-issue verification entries.
  final List<IssueVerificationEntry> entries;

  /// Issues that were resolved (absent for cooldown period).
  List<IssueVerificationEntry> get resolved =>
      entries.where((e) => e.status == FixVerificationStatus.resolved).toList();

  /// Issues that improved (lower severity or score).
  List<IssueVerificationEntry> get improved =>
      entries.where((e) => e.status == FixVerificationStatus.improved).toList();

  /// Issues that worsened (higher severity or score).
  List<IssueVerificationEntry> get worsened =>
      entries.where((e) => e.status == FixVerificationStatus.worsened).toList();

  /// Issues that are unchanged.
  List<IssueVerificationEntry> get unchanged => entries
      .where((e) => e.status == FixVerificationStatus.unchanged)
      .toList();

  /// New issues not present in baseline.
  List<IssueVerificationEntry> get newIssues =>
      entries.where((e) => e.status == FixVerificationStatus.newIssue).toList();

  Map<String, dynamic> toJson() => {
        'baselineCapturedAt': baselineCapturedAt.toIso8601String(),
        'comparedAt': comparedAt.toIso8601String(),
        'summary': {
          'resolved': resolved.length,
          'improved': improved.length,
          'unchanged': unchanged.length,
          'worsened': worsened.length,
          'newIssues': newIssues.length,
        },
        'entries': entries.map((e) => e.toJson()).toList(),
      };
}

/// A captured baseline snapshot for fix verification.
///
/// Stores the minimal data needed for comparison: stableId, severity,
/// and ranking score. NOT a full PerformanceIssue — we don't need
/// titles, details, or fix hints for comparison.
class FixBaseline {
  FixBaseline({
    required this.capturedAt,
    required this.issueSnapshots,
  });

  /// When the baseline was captured.
  final DateTime capturedAt;

  /// Per-stableId snapshot of severity and ranking score.
  final Map<String, BaselineIssueSnapshot> issueSnapshots;

  /// Number of consecutive absent cycles per stableId since baseline.
  /// Used for cooldown-based resolution detection.
  final Map<String, int> consecutiveAbsentCycles = {};

  /// Record that an issue was absent for one cycle.
  void recordAbsence(String stableId) {
    consecutiveAbsentCycles[stableId] =
        (consecutiveAbsentCycles[stableId] ?? 0) + 1;
  }

  /// Reset absence counter when an issue reappears.
  void recordPresence(String stableId) {
    consecutiveAbsentCycles.remove(stableId);
  }

  /// Check if an issue has been absent for [cooldownCycles] or more.
  bool isResolved(String stableId, {int cooldownCycles = 5}) {
    return (consecutiveAbsentCycles[stableId] ?? 0) >= cooldownCycles;
  }

  /// Compare current issues against this baseline.
  FixVerificationResult compare(
    List<PerformanceIssue> currentIssues, {
    int cooldownCycles = 5,
  }) {
    final currentById = <String, PerformanceIssue>{};
    for (final issue in currentIssues) {
      final id = issue.stableId ?? issue.title;
      currentById[id] = issue;
    }

    final entries = <IssueVerificationEntry>[];

    // Check each baseline issue
    for (final entry in issueSnapshots.entries) {
      final id = entry.key;
      final baseline = entry.value;
      final current = currentById.remove(id);

      if (current == null) {
        // Issue is absent — check cooldown
        if (isResolved(id, cooldownCycles: cooldownCycles)) {
          entries.add(IssueVerificationEntry(
            stableId: id,
            status: FixVerificationStatus.resolved,
            baselineSeverity: baseline.severity,
            baselineScore: baseline.rankingScore,
          ));
        } else {
          // Not enough absent cycles yet — treat as unchanged (in progress)
          entries.add(IssueVerificationEntry(
            stableId: id,
            status: FixVerificationStatus.unchanged,
            baselineSeverity: baseline.severity,
            baselineScore: baseline.rankingScore,
          ));
        }
      } else {
        // Issue still present — compare severity and score
        final severityDelta = current.severity.index - baseline.severity.index;
        final scoreDelta =
            (current.rankingScore ?? 0) - (baseline.rankingScore ?? 0);

        FixVerificationStatus status;
        if (severityDelta < 0 || scoreDelta < -10) {
          status = FixVerificationStatus.improved;
        } else if (severityDelta > 0 || scoreDelta > 10) {
          status = FixVerificationStatus.worsened;
        } else {
          status = FixVerificationStatus.unchanged;
        }

        entries.add(IssueVerificationEntry(
          stableId: id,
          status: status,
          baselineSeverity: baseline.severity,
          currentSeverity: current.severity,
          baselineScore: baseline.rankingScore,
          currentScore: current.rankingScore,
        ));
      }
    }

    // New issues not in baseline
    for (final entry in currentById.entries) {
      entries.add(IssueVerificationEntry(
        stableId: entry.key,
        status: FixVerificationStatus.newIssue,
        currentSeverity: entry.value.severity,
        currentScore: entry.value.rankingScore,
      ));
    }

    return FixVerificationResult(
      baselineCapturedAt: capturedAt,
      comparedAt: DateTime.now(),
      entries: entries,
    );
  }
}

class BaselineIssueSnapshot {
  const BaselineIssueSnapshot({required this.severity, this.rankingScore});

  final IssueSeverity severity;
  final int? rankingScore;
}

/// Create a [FixBaseline] from the current issue list.
FixBaseline captureFixBaseline(List<PerformanceIssue> currentIssues) {
  final snapshots = <String, BaselineIssueSnapshot>{};
  for (final issue in currentIssues) {
    final id = issue.stableId ?? issue.title;
    snapshots[id] = BaselineIssueSnapshot(
      severity: issue.severity,
      rankingScore: issue.rankingScore,
    );
  }
  return FixBaseline(
    capturedAt: DateTime.now(),
    issueSnapshots: snapshots,
  );
}
