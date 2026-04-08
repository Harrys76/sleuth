import '../models/performance_issue.dart';
import 'detector_correlator.dart';

/// A directed cause → effect relationship between two stableId patterns.
///
/// Patterns support trailing `*` for prefix matching (same convention as
/// [SleuthConfig.suppressedIssues]):
/// - `'setstate_scope'` — exact match
/// - `'rebuild_debug_*'` — prefix match (matches `rebuild_debug_MyWidget`, etc.)
class CausalRule {
  const CausalRule(this.causePattern, this.effectPattern);

  final String causePattern;
  final String effectPattern;
}

// ---------------------------------------------------------------------------
// Rule 6: Causal Issue Graph (applied last)
// ---------------------------------------------------------------------------

/// Builds a directed graph of issue relationships, identifies root causes,
/// and annotates issues with [rootCauseId] / [downstreamIds].
///
/// Runs after the 5 existing correlation rules, operating on the
/// merged/escalated/deduplicated issue set. Does NOT remove issues — only
/// adds metadata. The UI uses this metadata to collapse downstream issues
/// under their root cause.
///
/// **Confidence suppression:** When a root is `confirmed` or `likely`,
/// downstream issues with `possible` confidence are excluded from
/// [downstreamIds] (they still receive [rootCauseId] so the UI hides them
/// from the main list, but they don't appear as sub-items under the root).
class CausalGraphRule extends CorrelationRule {
  const CausalGraphRule();

  @override
  String get name => 'CausalGraph';

  // 52 causal rules. Order doesn't matter — all are evaluated, and the
  // graph is built from the full edge set.
  static const _causalRules = <CausalRule>[
    // setState-triggered chains (rebuild intermediate absorbed by Rule 2)
    CausalRule('setstate_scope', 'heavy_compute'),
    CausalRule('setstate_scope', 'layout_bottleneck'),

    // Image → memory chains
    CausalRule('uncached_images', 'heap_growing'),
    CausalRule('uncached_images', 'heap_near_capacity'),

    // CustomPainter → paint/raster chains
    CausalRule('always_repaint_painter', 'raster_dominance'),
    CausalRule('always_repaint_painter', 'excessive_repaint'),
    CausalRule('always_repaint_painter', 'excessive_repaint_debug'),

    // Missing RepaintBoundary → paint/raster chains
    CausalRule('missing_repaint_boundary', 'excessive_repaint'),
    CausalRule('missing_repaint_boundary', 'excessive_repaint_debug'),
    CausalRule('missing_repaint_boundary', 'raster_dominance'),

    // AnimatedBuilder → rebuild chains (only fires if not suppressed)
    CausalRule('animated_builder_no_child', 'rebuild_activity'),
    CausalRule('animated_builder_no_child', 'rebuild_debug_*'),

    // Non-lazy list chains
    CausalRule('non_lazy_list', 'rebuild_activity'),
    CausalRule('non_lazy_list', 'rebuild_debug_*'),
    CausalRule('non_lazy_list', 'heavy_compute'),
    CausalRule('non_lazy_list', 'layout_bottleneck'),

    // Non-lazy ListView/GridView chains (v10.1)
    CausalRule('non_lazy_listview', 'rebuild_activity'),
    CausalRule('non_lazy_listview', 'rebuild_debug_*'),
    CausalRule('non_lazy_listview', 'heavy_compute'),
    CausalRule('non_lazy_listview', 'layout_bottleneck'),
    CausalRule('non_lazy_gridview', 'rebuild_activity'),
    CausalRule('non_lazy_gridview', 'rebuild_debug_*'),
    CausalRule('non_lazy_gridview', 'heavy_compute'),
    CausalRule('non_lazy_gridview', 'layout_bottleneck'),

    // Rebuild cascade chains (fire when rebuild NOT merged into setstate_scope)
    CausalRule('rebuild_activity', 'heavy_compute'),
    CausalRule('rebuild_activity', 'layout_bottleneck'),
    CausalRule('rebuild_debug_*', 'heavy_compute'),
    CausalRule('rebuild_debug_*', 'layout_bottleneck'),

    // KeepAlive → memory chains (v10.6)
    CausalRule('excessive_keep_alive:*', 'heap_growing'),
    CausalRule('excessive_keep_alive:*', 'heap_near_capacity'),

    // Nested scroll → layout/rebuild chains (v10.7)
    CausalRule('nested_scroll', 'layout_bottleneck'),
    CausalRule('nested_scroll_same_axis', 'layout_bottleneck'),
    CausalRule('nested_scroll', 'rebuild_activity'),
    CausalRule('nested_scroll_same_axis', 'rebuild_activity'),

    // Network → downstream chains
    CausalRule('slow_request', 'heavy_compute'),
    CausalRule('request_frequency', 'rebuild_activity'),
    CausalRule('http_error_spike', 'request_frequency'),

    // --- Pillar 3a: 8 new causal patterns (v0.10.7) ---

    // setState scope → excessive rebuilds (complements merge rule —
    // catches rebuild_debug_* variants NOT consumed by MergeRebuildSetStateRule)
    CausalRule('setstate_scope', 'rebuild_debug_*'),

    // Uncached images → GC pressure (complements existing → heap_growing/heap_near_capacity)
    CausalRule('uncached_images', 'gc_pressure'),

    // Keep-alive → GC pressure (complements existing → heap_growing/heap_near_capacity)
    CausalRule('excessive_keep_alive:*', 'gc_pressure'),

    // AnimatedBuilder without child → excessive repaints
    CausalRule('animated_builder_no_child', 'excessive_repaint'),
    CausalRule('animated_builder_no_child', 'excessive_repaint_debug'),

    // Layout bottleneck → frame jank
    CausalRule('layout_bottleneck', 'sustained_jank'),
    CausalRule('layout_bottleneck', 'jank_detected'),

    // Font loading → frame jank
    CausalRule('runtime_font_loading', 'sustained_jank'),
    CausalRule('runtime_font_loading', 'jank_detected'),
    CausalRule('multiple_custom_fonts', 'sustained_jank'),
    CausalRule('multiple_custom_fonts', 'jank_detected'),

    // Platform channel traffic → compute pressure
    CausalRule('platform_channel_traffic', 'heavy_compute'),

    // Duplicate requests → rebuilds
    CausalRule('duplicate_request:*', 'rebuild_activity'),
    CausalRule('duplicate_request:*', 'rebuild_debug_*'),
  ];

  @override
  List<PerformanceIssue> apply(List<PerformanceIssue> issues) {
    if (issues.length < 2) return issues;

    // 1. Index issues by stableId.
    final idToIndices = <String, List<int>>{};
    for (var i = 0; i < issues.length; i++) {
      final id = issues[i].stableId;
      if (id != null) {
        (idToIndices[id] ??= []).add(i);
      }
    }
    if (idToIndices.isEmpty) return issues;

    // 2. Build edge set from causal rules.
    final outgoing = <int, Set<int>>{}; // cause index → effect indices
    final incoming = <int, Set<int>>{}; // effect index → cause indices

    for (final rule in _causalRules) {
      final causeIndices = _findMatching(idToIndices, rule.causePattern);
      final effectIndices = _findMatching(idToIndices, rule.effectPattern);

      for (final ci in causeIndices) {
        for (final ei in effectIndices) {
          if (ci == ei) continue; // self-loop guard
          (outgoing[ci] ??= {}).add(ei);
          (incoming[ei] ??= {}).add(ci);
        }
      }
    }

    if (outgoing.isEmpty) return issues;

    // 3. Find roots: indices with outgoing edges but no incoming edges.
    final roots = <int>[];
    for (final idx in outgoing.keys) {
      if (!incoming.containsKey(idx)) {
        roots.add(idx);
      }
    }

    if (roots.isEmpty) {
      // All nodes have incoming edges — cycle or no clear root.
      // Fall through without annotation.
      return issues;
    }

    // Sort roots by severity (critical first) for deterministic assignment.
    roots.sort((a, b) {
      final sa = _severityRank(issues[a].severity);
      final sb = _severityRank(issues[b].severity);
      if (sa != sb) return sb.compareTo(sa); // higher rank first
      return a.compareTo(b); // stable: earlier in list wins
    });

    // 4. BFS from each root to collect downstream, with cycle-safe visited set.
    // Track which root claims each downstream (first root wins — highest severity).
    final downstreamOwner = <int, int>{}; // downstream index → root index

    for (final rootIdx in roots) {
      final visited = <int>{rootIdx};
      final queue = <int>[...?outgoing[rootIdx]];

      while (queue.isNotEmpty) {
        final current = queue.removeAt(0);
        if (!visited.add(current)) continue; // cycle safety

        // Only claim if not already claimed by a higher-severity root.
        downstreamOwner.putIfAbsent(current, () => rootIdx);

        // Continue BFS through this node's outgoing edges.
        final children = outgoing[current];
        if (children != null) {
          queue.addAll(children);
        }
      }
    }

    if (downstreamOwner.isEmpty) return issues;

    // 5. Build root → downstream mapping with confidence suppression.
    final rootDownstream =
        <int, List<String>>{}; // root index → downstream stableIds

    for (final entry in downstreamOwner.entries) {
      final downIdx = entry.key;
      final rootIdx = entry.value;
      final root = issues[rootIdx];
      final downstream = issues[downIdx];
      final downId = downstream.stableId ?? downstream.title;

      // Confidence suppression: skip possible downstream when root is
      // confirmed or likely. They still get rootCauseId (hidden from main
      // list) but aren't shown as sub-items.
      if (downstream.confidence == IssueConfidence.possible &&
          root.confidence != IssueConfidence.possible) {
        continue;
      }

      (rootDownstream[rootIdx] ??= []).add(downId);
    }

    // 6. Annotate issues via copyWith.
    final result = <PerformanceIssue>[];
    for (var i = 0; i < issues.length; i++) {
      final owner = downstreamOwner[i];
      final downstream = rootDownstream[i];

      if (owner != null) {
        // This issue is downstream of a root.
        final rootId = issues[owner].stableId ?? issues[owner].title;
        result.add(issues[i].copyWith(rootCauseId: rootId));
      } else if (downstream != null && downstream.isNotEmpty) {
        // This issue is a root with downstream effects.
        result.add(issues[i].copyWith(downstreamIds: downstream));
      } else {
        // Standalone — no causal chain.
        result.add(issues[i]);
      }
    }
    return result;
  }

  /// Find all issue indices matching a stableId [pattern].
  /// Supports exact match and trailing `*` prefix match.
  static List<int> _findMatching(
    Map<String, List<int>> idToIndices,
    String pattern,
  ) {
    if (pattern.endsWith('*')) {
      final prefix = pattern.substring(0, pattern.length - 1);
      final result = <int>[];
      for (final entry in idToIndices.entries) {
        if (entry.key.startsWith(prefix)) {
          result.addAll(entry.value);
        }
      }
      return result;
    }
    return idToIndices[pattern] ?? const [];
  }

  static int _severityRank(IssueSeverity s) => switch (s) {
        IssueSeverity.critical => 3,
        IssueSeverity.warning => 2,
        IssueSeverity.ok => 1,
      };
}
