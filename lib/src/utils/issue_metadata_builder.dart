import 'package:flutter/foundation.dart';

import '../models/performance_issue.dart';

/// Builds the "About this detection" metadata entries shown in both the
/// inline card section and the full-screen detail page.
///
/// Extracted to avoid duplicating the confidence/accuracy/verifyWith logic
/// across [IssueCard] and [IssueDetailPage].
class IssueMetadataBuilder {
  IssueMetadataBuilder._();

  /// Returns a list of (label, value) pairs for the given [issue].
  static List<(String, String)> entries(PerformanceIssue issue) {
    final source = issue.observationSource?.displayName ?? 'heuristic analysis';
    final confidenceExplanation = switch (issue.confidence) {
      IssueConfidence.confirmed => 'Directly observed at runtime',
      IssueConfidence.likely => 'Runtime signal and structural evidence',
      IssueConfidence.possible =>
        'Structural pattern only, no runtime confirmation',
    };
    final accuracyNote = kDebugMode
        ? 'Debug mode adds overhead. Verify in profile mode'
        : 'Profile mode, so timing data matches production';
    final verifyWith = switch (issue.category) {
      IssueCategory.build ||
      IssueCategory.layout => 'DevTools > Performance > Frame Analysis',
      IssueCategory.paint ||
      IssueCategory.raster => 'DevTools > Performance > Raster Stats',
      IssueCategory.memory => 'DevTools > Memory > Allocation Tracking',
      IssueCategory.channel => 'DevTools > Network > Platform Channels',
      IssueCategory.network => 'DevTools > Network',
      IssueCategory.font => 'DevTools > Performance > Timeline Events',
      IssueCategory.startup => 'DevTools > Performance > App Startup',
    };
    return [
      ('Based on:', source),
      ('Confidence:', '${issue.confidence.name}. $confidenceExplanation'),
      ('Accuracy:', accuracyNote),
      ('Verify with:', verifyWith),
    ];
  }
}
