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
/// and annotates issues with [PerformanceIssue.rootCauseIds] /
/// [PerformanceIssue.downstreamIds].
///
/// Runs after the 5 existing correlation rules, operating on the
/// merged/escalated/deduplicated issue set. Does NOT remove issues — only
/// adds metadata. The UI uses this metadata to collapse downstream issues
/// under their root causes.
///
/// **Multi-parent annotation (v0.24.2+):** every reaching root claims each
/// downstream effect. A downstream with N upstream roots carries all N
/// stableIds in `rootCauseIds`, sorted severity desc then stableId asc.
/// Intermediate nodes in a multi-hop chain are not annotated as parents —
/// only the originating roots are.
///
/// **Confidence suppression:** When any reaching root is `confirmed` or
/// `likely`, downstream issues with `possible` confidence are excluded
/// from every root's [PerformanceIssue.downstreamIds] (they still receive
/// `rootCauseIds` so the UI hides them from the main list, but they
/// don't appear as sub-items under the root).
class CausalGraphRule extends CorrelationRule {
  const CausalGraphRule();

  @override
  String get name => 'CausalGraph';

  // 44 causal rules. Order doesn't matter — all are evaluated, and the
  // graph is built from the full edge set.
  static const _causalRules = <CausalRule>[
    // setState-triggered chains (rebuild intermediate absorbed by Rule 2)
    CausalRule('setstate_scope', 'heavy_compute'),

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

    // Rules below cover stableIds whose source detectors were removed in
    // v0.20.0 (animated_builder, opacity, shallow_rebuild_risk,
    // nested_scroll, global_key). They remain so causal correlation
    // applied to v0.19 saved snapshots still produces full chains. Do
    // not delete without bumping snapshot schemaVersion.

    // AnimatedBuilder → rebuild chains (only fires if not suppressed)
    CausalRule('animated_builder_no_child', 'rebuild_activity'),
    CausalRule('animated_builder_no_child', 'rebuild_debug_*'),

    // Non-lazy list chains
    CausalRule('non_lazy_list', 'rebuild_activity'),
    CausalRule('non_lazy_list', 'rebuild_debug_*'),
    CausalRule('non_lazy_list', 'heavy_compute'),

    // Non-lazy ListView/GridView chains (v10.1)
    CausalRule('non_lazy_listview', 'rebuild_activity'),
    CausalRule('non_lazy_listview', 'rebuild_debug_*'),
    CausalRule('non_lazy_listview', 'heavy_compute'),
    CausalRule('non_lazy_gridview', 'rebuild_activity'),
    CausalRule('non_lazy_gridview', 'rebuild_debug_*'),
    CausalRule('non_lazy_gridview', 'heavy_compute'),

    // Rebuild cascade chains (fire when rebuild NOT merged into setstate_scope)
    CausalRule('rebuild_activity', 'heavy_compute'),
    CausalRule('rebuild_debug_*', 'heavy_compute'),

    // KeepAlive → memory chains (v10.6)
    CausalRule('excessive_keep_alive:*', 'heap_growing'),
    CausalRule('excessive_keep_alive:*', 'heap_near_capacity'),

    // Nested scroll → rebuild chains (v10.7)
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

    // Stream resource leaks → memory-pressure family. Same shape as the
    // uncached_images / excessive_keep_alive rules above: a retention
    // anti-pattern propagates to all three memory effects. Emission is
    // already gated on co-firing `heap_growing`, so the heap_growing
    // edge surfaces immediately; the other two surface when the
    // respective gates fire on the same scan.
    //
    // TODO(v0.24.2+): consider an explicit co-escalation rule that
    // hardens stream_resource_growth severity when heap_near_capacity
    // also fires. Out of scope for v0.24.1.
    CausalRule('stream_resource_growth', 'heap_growing'),
    CausalRule('stream_resource_growth', 'heap_near_capacity'),
    CausalRule('stream_resource_growth', 'gc_pressure'),

    // Tracked-resource leaks (user-confirmed via Sleuth.trackResource)
    // are direct causes of heap_growing — each retained instance keeps
    // its captured state alive past the GC root the user expected.
    CausalRule('tracked_resource_concurrent:*', 'heap_growing'),
    CausalRule('tracked_resource_long_lived:*', 'heap_growing'),

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

    // High-frequency same-path traffic → rebuilds
    CausalRule('high_frequency_same_path:*', 'rebuild_activity'),
    CausalRule('high_frequency_same_path:*', 'rebuild_debug_*'),
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
    // Multi-parent annotation (v0.24.2+): every reachable root claims each
    // downstream. A downstream effect with N upstream causes carries all N
    // roots in `rootCauseIds`. Pre-v0.24.2 single-owner semantics (first
    // root wins by severity-then-index) is replaced — UI now renders the
    // full parent set.
    final downstreamOwners =
        <int, Set<int>>{}; // downstream index → set of root indices

    for (final rootIdx in roots) {
      final visited = <int>{rootIdx};
      final queue = <int>[...?outgoing[rootIdx]];

      while (queue.isNotEmpty) {
        final current = queue.removeAt(0);
        if (!visited.add(current)) continue; // cycle safety

        // Accumulate every root that reaches this downstream.
        (downstreamOwners[current] ??= <int>{}).add(rootIdx);

        // Continue BFS through this node's outgoing edges.
        final children = outgoing[current];
        if (children != null) {
          queue.addAll(children);
        }
      }
    }

    if (downstreamOwners.isEmpty) return issues;

    // 5. Build root → downstream mapping with confidence suppression.
    // Suppression rule (multi-parent): skip a `possible`-confidence
    // downstream from a root's downstreamIds list when ANY reaching
    // root for that downstream is `confirmed` or `likely`. The check
    // operates on the union of REACHING ROOTS (the BFS sources), not
    // the immediate graph-parents of the downstream — but the
    // user-visible effect is the same because pre-existing causal
    // chains are short (≤ 2 hops in current rules). The downstream
    // still carries rootCauseIds for UI annotation; the suppression
    // only prevents the root from listing it as a sub-item in the
    // main list rendering.
    final rootDownstream =
        <int, List<String>>{}; // root index → downstream stableIds

    for (final entry in downstreamOwners.entries) {
      final downIdx = entry.key;
      final ownerIndices = entry.value;
      final downstream = issues[downIdx];
      final downId = downstream.stableId ?? downstream.title;

      final anyStrongerParent = ownerIndices.any(
        (rootIdx) => issues[rootIdx].confidence != IssueConfidence.possible,
      );
      final shouldSuppress =
          downstream.confidence == IssueConfidence.possible &&
              anyStrongerParent;

      for (final rootIdx in ownerIndices) {
        if (shouldSuppress) continue;
        (rootDownstream[rootIdx] ??= []).add(downId);
      }
    }

    // 6. Annotate issues via copyWith.
    final result = <PerformanceIssue>[];
    for (var i = 0; i < issues.length; i++) {
      final owners = downstreamOwners[i];
      final downstream = rootDownstream[i];

      if (owners != null && owners.isNotEmpty) {
        // This issue is downstream of one or more roots. Sort root ids
        // deterministically: severity descending (critical first), then
        // stableId ascending. Title fallback below is defensive — the
        // root indexing at the top of apply() filters out null-stableId
        // issues, so a root with non-null stableId is guaranteed in
        // current code paths. The fallback exists in case a future
        // refactor admits null-stableId nodes into the BFS.
        final sortedRoots = owners.toList()
          ..sort((a, b) {
            final sa = _severityRank(issues[a].severity);
            final sb = _severityRank(issues[b].severity);
            if (sa != sb) return sb.compareTo(sa);
            final ka = issues[a].stableId ?? issues[a].title;
            final kb = issues[b].stableId ?? issues[b].title;
            return ka.compareTo(kb);
          });
        final rootIds = [
          for (final rootIdx in sortedRoots)
            issues[rootIdx].stableId ?? issues[rootIdx].title,
        ];
        // Also propagate downstreamIds if this issue is itself a root for
        // some other downstream (a node can be both downstream and root in
        // a chain like A→B→C).
        if (downstream != null && downstream.isNotEmpty) {
          result.add(issues[i].copyWith(
            rootCauseIds: rootIds,
            downstreamIds: downstream,
          ));
        } else {
          result.add(issues[i].copyWith(rootCauseIds: rootIds));
        }
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

  /// Returns the list of active causal edges for the given issues.
  ///
  /// Each edge is a `{cause, effect}` map representing a directed
  /// relationship between two stableIds. Only edges where both cause
  /// and effect are present in [issues] are returned.
  static List<Map<String, String>> activeEdges(List<PerformanceIssue> issues) {
    if (issues.length < 2) return const [];

    final idToIndices = <String, List<int>>{};
    for (var i = 0; i < issues.length; i++) {
      final id = issues[i].stableId;
      if (id != null) {
        (idToIndices[id] ??= []).add(i);
      }
    }
    if (idToIndices.isEmpty) return const [];

    final edges = <Map<String, String>>[];
    final seen = <String>{};

    for (final rule in _causalRules) {
      final causeIndices = _findMatching(idToIndices, rule.causePattern);
      final effectIndices = _findMatching(idToIndices, rule.effectPattern);

      for (final ci in causeIndices) {
        for (final ei in effectIndices) {
          if (ci == ei) continue;
          final causeId = issues[ci].stableId!;
          final effectId = issues[ei].stableId!;
          final key = '$causeId→$effectId';
          if (seen.add(key)) {
            edges.add({'cause': causeId, 'effect': effectId});
          }
        }
      }
    }
    return edges;
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
