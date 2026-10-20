import '../models/performance_issue.dart';

/// The Evidence and Check in rows of an expanded issue card.
class IssueMetadataBuilder {
  IssueMetadataBuilder._();

  /// What the detector observed and how sure it is: the detector's
  /// confidence reason, or the data source when it gave none, then the
  /// confidence.
  static String evidence(PerformanceIssue issue) {
    final reason = issue.confidenceReason?.trim();
    final basis = reason != null && reason.isNotEmpty
        ? reason.endsWith('.')
              ? reason.substring(0, reason.length - 1)
              : reason
        : 'From the ${issue.observationSource?.displayName ?? 'overlay heuristics'}';
    final confidence = switch (issue.confidence) {
      IssueConfidence.confirmed => 'confirmed',
      IssueConfidence.likely => 'likely rather than confirmed',
      IssueConfidence.possible => 'possible: no runtime signal confirmed it',
    };
    return '$basis, so $confidence.';
  }

  /// Where in DevTools to confirm the issue.
  static String checkIn(PerformanceIssue issue) => switch (issue.category) {
    IssueCategory.build ||
    IssueCategory.layout => 'DevTools › Performance › Frame Analysis',
    IssueCategory.paint ||
    IssueCategory.raster => 'DevTools › Performance › Raster Stats',
    IssueCategory.memory => 'DevTools › Memory',
    IssueCategory.channel => 'DevTools › Performance › Timeline Events',
    IssueCategory.network => 'DevTools › Network',
    IssueCategory.font => 'DevTools › Performance › Timeline Events',
    IssueCategory.startup => 'DevTools › Performance › Timeline Events',
  };
}
