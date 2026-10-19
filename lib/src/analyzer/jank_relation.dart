import '../models/frame_verdict.dart';
import '../models/performance_issue.dart';

/// Whether [issue] reports late frames themselves rather than a cause.
bool isJankSymptom(PerformanceIssue issue) =>
    issue.stableId == 'jank_detected' || issue.stableId == 'sustained_jank';

/// The issues in [issues] that can explain a frame that missed its
/// deadline in [phase].
///
/// A build, layout, paint or raster phase takes the issues of the same
/// category. A start delay is explained only by `event_loop_stall`.
/// `pipelineStall` and `unknown` name no phase work, so they take none.
/// Jank symptoms are never a cause.
List<PerformanceIssue> relatedToPhase(
  PipelinePhase phase,
  List<PerformanceIssue> issues,
) {
  final category = switch (phase) {
    PipelinePhase.build => IssueCategory.build,
    PipelinePhase.layout => IssueCategory.layout,
    PipelinePhase.paint => IssueCategory.paint,
    PipelinePhase.raster => IssueCategory.raster,
    PipelinePhase.schedulerDelay ||
    PipelinePhase.pipelineStall ||
    PipelinePhase.unknown => null,
  };
  if (phase == PipelinePhase.schedulerDelay) {
    return [
      for (final i in issues)
        if (i.stableId == 'event_loop_stall') i,
    ];
  }
  if (category == null) return const [];
  return [
    for (final i in issues)
      if (i.category == category && !isJankSymptom(i)) i,
  ];
}
