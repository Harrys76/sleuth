import '../models/performance_issue.dart';
import 'causal_graph.dart';

/// A single correlation rule applied to the combined issue list.
///
/// Rules may remove, modify, or replace issues. They return a new list
/// (never mutate in place). Applied in sequence by [DetectorCorrelator].
abstract class CorrelationRule {
  const CorrelationRule();

  /// Human-readable name for logging/debugging.
  String get name;

  /// Apply this rule to [issues] and return the (possibly modified) list.
  List<PerformanceIssue> apply(List<PerformanceIssue> issues);
}

/// Post-processes the combined issue list from all detectors,
/// merging, suppressing, or escalating issues based on cross-detector
/// evidence.
///
/// Pure function class — no state, const constructor.
/// Rules are applied in a fixed order:
///   suppress → merge → escalate → deduplicate → causal graph.
class DetectorCorrelator {
  const DetectorCorrelator();

  static const List<CorrelationRule> _rules = [
    SuppressAnimatedBuilderRule(), // suppress first
    MergeRebuildSetStateRule(), // merge second
    EscalateGpuCustomPainterRule(), // escalate third
    EscalateMemoryImageRule(), // escalate fourth
    DeduplicateRebuildRepaintRule(), // deduplicate fifth
    CausalGraphRule(), // causal graph last
  ];

  /// Apply all correlation rules in sequence and return the modified list.
  List<PerformanceIssue> correlate(List<PerformanceIssue> issues) {
    if (issues.isEmpty) return issues;
    var result = issues;
    for (final rule in _rules) {
      result = rule.apply(result);
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Rule 1: Suppress AnimatedBuilder without paint pressure (applied first)
// ---------------------------------------------------------------------------

/// Suppresses `animated_builder_no_child` when confidence is [possible]
/// AND no paint-category issues exist from other detectors.
///
/// AnimatedBuilder without child is category `build`. It only matters if
/// it causes paint overhead. If no paint issues exist, the structural
/// finding is likely a false positive. If confidence is already `likely`
/// (debug paint evidence), the detector itself confirmed it — don't suppress.
class SuppressAnimatedBuilderRule extends CorrelationRule {
  const SuppressAnimatedBuilderRule();

  @override
  String get name => 'SuppressAnimatedBuilder';

  @override
  List<PerformanceIssue> apply(List<PerformanceIssue> issues) {
    final animBuilderIdx = issues.indexWhere(
      (i) => i.stableId == 'animated_builder_no_child',
    );
    if (animBuilderIdx == -1) return issues;

    final animBuilder = issues[animBuilderIdx];

    // Only suppress structural-only findings.
    if (animBuilder.confidence != IssueConfidence.possible) return issues;

    // If any paint-category issues exist, AnimatedBuilder could be
    // contributing — don't suppress.
    final hasPaintIssues = issues.any(
      (i) => i.category == IssueCategory.paint,
    );
    if (hasPaintIssues) return issues;

    return [...issues]..removeAt(animBuilderIdx);
  }
}

// ---------------------------------------------------------------------------
// Rule 2: Merge Rebuild + SetState Scope (applied second)
// ---------------------------------------------------------------------------

/// Merges rebuild issues with setState scope issues when they share a
/// root cause.
///
/// Strong match: `rebuild_debug_$TYPE` where TYPE matches setState scope's
/// `widgetName`. Weak fallback: `rebuild_activity` co-occurrence.
///
/// Keeps the setState scope issue (preserves stableId `setstate_scope`
/// for recurrence tracking), enhances detail with rebuild evidence,
/// removes the matched rebuild issue. Upgrades confidence to `likely`
/// minimum.
class MergeRebuildSetStateRule extends CorrelationRule {
  const MergeRebuildSetStateRule();

  static const _rebuildDebugPrefix = 'rebuild_debug_';

  @override
  String get name => 'MergeRebuildSetState';

  @override
  List<PerformanceIssue> apply(List<PerformanceIssue> issues) {
    final setStateIdx = issues.indexWhere(
      (i) => i.stableId == 'setstate_scope',
    );
    if (setStateIdx == -1) return issues;

    final setState = issues[setStateIdx];
    final setStateWidget = setState.widgetName;

    // Try strong match: rebuild_debug_$TYPE where TYPE == widgetName.
    var matchedRebuildIdx = -1;
    if (setStateWidget != null) {
      matchedRebuildIdx = issues.indexWhere(
        (i) => i.stableId == '$_rebuildDebugPrefix$setStateWidget',
      );
    }

    // Fallback: weak match — rebuild_activity co-occurrence.
    if (matchedRebuildIdx == -1) {
      matchedRebuildIdx = issues.indexWhere(
        (i) => i.stableId == 'rebuild_activity',
      );
    }

    if (matchedRebuildIdx == -1) return issues;

    final matchedRebuild = issues[matchedRebuildIdx];

    // Upgrade confidence to at least `likely` (cross-detector evidence).
    final mergedConfidence = setState.confidence == IssueConfidence.possible
        ? IssueConfidence.likely
        : setState.confidence;

    final merged = setState.copyWith(
      confidence: mergedConfidence,
      detail: '${setState.detail}\n\n'
          '[Correlated] Rebuild evidence: ${matchedRebuild.title}',
    );

    final result = <PerformanceIssue>[];
    for (var i = 0; i < issues.length; i++) {
      if (i == matchedRebuildIdx) continue; // remove rebuild
      if (i == setStateIdx) {
        result.add(merged); // replace setState with merged
      } else {
        result.add(issues[i]);
      }
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Rule 3: Escalate CustomPainter with GPU Pressure (applied third)
// ---------------------------------------------------------------------------

/// When `raster_dominance` and `always_repaint_painter` co-occur,
/// escalates CustomPainter confidence from `possible` to `likely`.
///
/// Does NOT escalate if already `likely` or `confirmed`.
class EscalateGpuCustomPainterRule extends CorrelationRule {
  const EscalateGpuCustomPainterRule();

  @override
  String get name => 'EscalateGpuCustomPainter';

  @override
  List<PerformanceIssue> apply(List<PerformanceIssue> issues) {
    final hasGpu = issues.any((i) => i.stableId == 'raster_dominance');
    if (!hasGpu) return issues;

    final painterIdx = issues.indexWhere(
      (i) => i.stableId == 'always_repaint_painter',
    );
    if (painterIdx == -1) return issues;

    final painter = issues[painterIdx];
    if (painter.confidence != IssueConfidence.possible) return issues;

    final escalated = painter.copyWith(
      confidence: IssueConfidence.likely,
      detail: '${painter.detail}\n\n'
          '[Correlated] GPU raster pressure detected — '
          'this painter is likely contributing to raster overhead.',
    );

    return [
      for (var i = 0; i < issues.length; i++)
        if (i == painterIdx) escalated else issues[i],
    ];
  }
}

// ---------------------------------------------------------------------------
// Rule 4: Escalate ImageMemory with Heap Growth (applied fourth)
// ---------------------------------------------------------------------------

/// When `heap_growing` and `uncached_images` co-occur, escalates
/// ImageMemory confidence from `possible` to `likely`.
///
/// Does NOT escalate if already `likely` or `confirmed`.
class EscalateMemoryImageRule extends CorrelationRule {
  const EscalateMemoryImageRule();

  @override
  String get name => 'EscalateMemoryImage';

  @override
  List<PerformanceIssue> apply(List<PerformanceIssue> issues) {
    final hasHeapGrowing = issues.any((i) => i.stableId == 'heap_growing');
    if (!hasHeapGrowing) return issues;

    final imageIdx = issues.indexWhere(
      (i) => i.stableId == 'uncached_images',
    );
    if (imageIdx == -1) return issues;

    final image = issues[imageIdx];
    if (image.confidence != IssueConfidence.possible) return issues;

    final escalated = image.copyWith(
      confidence: IssueConfidence.likely,
      detail: '${image.detail}\n\n'
          '[Correlated] Heap growth detected — '
          'uncached images are likely contributing to memory pressure.',
    );

    return [
      for (var i = 0; i < issues.length; i++)
        if (i == imageIdx) escalated else issues[i],
    ];
  }
}

// ---------------------------------------------------------------------------
// Rule 5: Deduplicate Rebuild + Repaint on same widget (applied last)
// ---------------------------------------------------------------------------

/// Deduplicates when the same widget has both `rebuild_debug_$TYPE` and
/// `repaint_debug_$TYPE` issues.
///
/// Keeps the higher-confidence issue. If equal confidence, keeps the
/// rebuild issue (build issues are more actionable for developers).
class DeduplicateRebuildRepaintRule extends CorrelationRule {
  const DeduplicateRebuildRepaintRule();

  static const _rebuildPrefix = 'rebuild_debug_';
  static const _repaintPrefix = 'repaint_debug_';

  @override
  String get name => 'DeduplicateRebuildRepaint';

  @override
  List<PerformanceIssue> apply(List<PerformanceIssue> issues) {
    // Build maps: typeName → index for both prefixes.
    final rebuildByType = <String, int>{};
    final repaintByType = <String, int>{};

    for (var i = 0; i < issues.length; i++) {
      final id = issues[i].stableId;
      if (id == null) continue;
      if (id.startsWith(_rebuildPrefix)) {
        rebuildByType[id.substring(_rebuildPrefix.length)] = i;
      } else if (id.startsWith(_repaintPrefix)) {
        repaintByType[id.substring(_repaintPrefix.length)] = i;
      }
    }

    // Find overlapping type names and pick which to remove.
    final indicesToRemove = <int>{};
    for (final typeName in rebuildByType.keys) {
      if (!repaintByType.containsKey(typeName)) continue;

      final rebuildIdx = rebuildByType[typeName]!;
      final repaintIdx = repaintByType[typeName]!;
      final rebuild = issues[rebuildIdx];
      final repaint = issues[repaintIdx];

      final rebuildRank = _confidenceRank(rebuild.confidence);
      final repaintRank = _confidenceRank(repaint.confidence);

      if (repaintRank > rebuildRank) {
        indicesToRemove.add(rebuildIdx); // repaint wins
      } else {
        indicesToRemove.add(repaintIdx); // rebuild wins (higher or equal)
      }
    }

    if (indicesToRemove.isEmpty) return issues;

    return [
      for (var i = 0; i < issues.length; i++)
        if (!indicesToRemove.contains(i)) issues[i],
    ];
  }

  static int _confidenceRank(IssueConfidence c) => switch (c) {
        IssueConfidence.confirmed => 3,
        IssueConfidence.likely => 2,
        IssueConfidence.possible => 1,
      };
}
