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
      IssueConfidence.likely => 'Runtime signal + structural evidence',
      IssueConfidence.possible =>
        'Structural pattern only \u2014 no runtime confirmation',
    };
    final accuracyNote = kDebugMode
        ? 'Debug mode adds overhead \u2014 verify in profile mode'
        : 'Profile mode \u2014 timing data is production-accurate';
    final verifyWith = switch (issue.category) {
      IssueCategory.build ||
      IssueCategory.layout =>
        'DevTools \u2192 Performance \u2192 Frame Analysis',
      IssueCategory.paint ||
      IssueCategory.raster =>
        'DevTools \u2192 Performance \u2192 Raster Stats',
      IssueCategory.memory =>
        'DevTools \u2192 Memory \u2192 Allocation Tracking',
      IssueCategory.channel =>
        'DevTools \u2192 Network \u2192 Platform Channels',
      IssueCategory.network => 'DevTools \u2192 Network',
      IssueCategory.font =>
        'DevTools \u2192 Performance \u2192 Timeline Events',
    };
    return [
      ('Based on:', source),
      ('Confidence:', '${issue.confidence.name} \u2014 $confidenceExplanation'),
      ('Accuracy:', accuracyNote),
      ('Verify with:', verifyWith),
    ];
  }
}
