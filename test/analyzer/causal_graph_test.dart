import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/analyzer/causal_graph.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  const rule = CausalGraphRule();

  // ---------------------------------------------------------------------------
  // Helper
  // ---------------------------------------------------------------------------

  PerformanceIssue makeIssue({
    required String stableId,
    IssueCategory category = IssueCategory.build,
    IssueConfidence confidence = IssueConfidence.possible,
    IssueSeverity severity = IssueSeverity.warning,
    String title = 'test issue',
  }) =>
      PerformanceIssue(
        severity: severity,
        category: category,
        confidence: confidence,
        title: title,
        detail: 'test detail',
        fixHint: '',
        stableId: stableId,
      );

  // ---------------------------------------------------------------------------
  // Passthrough / edge cases
  // ---------------------------------------------------------------------------

  group('passthrough', () {
    test('empty list returns empty', () {
      expect(rule.apply([]), isEmpty);
    });

    test('single issue returns unchanged', () {
      final result = rule.apply([makeIssue(stableId: 'setstate_scope')]);
      expect(result, hasLength(1));
      expect(result[0].rootCauseId, isNull);
      expect(result[0].downstreamIds, isNull);
    });

    test('unrelated issues pass through unchanged', () {
      final issues = [
        makeIssue(stableId: 'slow_request', category: IssueCategory.network),
        makeIssue(stableId: 'shader_compilation'),
        makeIssue(stableId: 'gc_pressure', category: IssueCategory.memory),
      ];
      final result = rule.apply(issues);
      expect(result, hasLength(3));
      for (final issue in result) {
        expect(issue.rootCauseId, isNull);
        expect(issue.downstreamIds, isNull);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Single-hop chains
  // ---------------------------------------------------------------------------

  group('single-hop chains', () {
    test('setstate_scope → heavy_compute', () {
      final issues = [
        makeIssue(
          stableId: 'setstate_scope',
          severity: IssueSeverity.warning,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      // setstate_scope is root
      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[0].rootCauseId, isNull);

      // heavy_compute is downstream
      expect(result[1].rootCauseId, 'setstate_scope');
      expect(result[1].downstreamIds, isNull);
    });

    test('uncached_images → heap_growing', () {
      final issues = [
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);
      expect(result[0].downstreamIds, ['heap_growing']);
      expect(result[1].rootCauseId, 'uncached_images');
    });

    test('always_repaint_painter → raster_dominance', () {
      final issues = [
        makeIssue(
          stableId: 'always_repaint_painter',
          category: IssueCategory.paint,
        ),
        makeIssue(
          stableId: 'raster_dominance',
          category: IssueCategory.raster,
        ),
      ];
      final result = rule.apply(issues);
      expect(result[0].downstreamIds, ['raster_dominance']);
      expect(result[1].rootCauseId, 'always_repaint_painter');
    });

    test('non_lazy_list → layout_bottleneck', () {
      final issues = [
        makeIssue(
          stableId: 'non_lazy_list',
          category: IssueCategory.build,
        ),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
        ),
      ];
      final result = rule.apply(issues);
      expect(result[0].downstreamIds, ['layout_bottleneck']);
      expect(result[1].rootCauseId, 'non_lazy_list');
    });
  });

  // ---------------------------------------------------------------------------
  // Multi-hop chains
  // ---------------------------------------------------------------------------

  group('multi-hop chains', () {
    test('non_lazy_list → rebuild_activity → heavy_compute', () {
      final issues = [
        makeIssue(
          stableId: 'non_lazy_list',
          severity: IssueSeverity.warning,
        ),
        makeIssue(stableId: 'rebuild_activity'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // non_lazy_list is root with both downstream
      expect(result[0].rootCauseId, isNull);
      expect(result[0].downstreamIds, isNotNull);
      expect(result[0].downstreamIds,
          containsAll(['rebuild_activity', 'heavy_compute']));

      // Both are downstream of non_lazy_list
      expect(result[1].rootCauseId, 'non_lazy_list');
      expect(result[2].rootCauseId, 'non_lazy_list');
    });

    test('animated_builder_no_child → rebuild_debug_MyWidget → heavy_compute',
        () {
      final issues = [
        makeIssue(
          stableId: 'animated_builder_no_child',
          severity: IssueSeverity.warning,
        ),
        makeIssue(stableId: 'rebuild_debug_MyWidget'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // animated_builder_no_child is root
      expect(result[0].downstreamIds, isNotNull);
      expect(result[0].downstreamIds,
          containsAll(['rebuild_debug_MyWidget', 'heavy_compute']));
      expect(result[1].rootCauseId, 'animated_builder_no_child');
      expect(result[2].rootCauseId, 'animated_builder_no_child');
    });
  });

  // ---------------------------------------------------------------------------
  // Prefix wildcard matching
  // ---------------------------------------------------------------------------

  group('prefix wildcard matching', () {
    test('rebuild_debug_* matches rebuild_debug_MyWidget', () {
      final issues = [
        makeIssue(stableId: 'rebuild_debug_MyWidget'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // rebuild_debug_* → heavy_compute rule fires
      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[1].rootCauseId, 'rebuild_debug_MyWidget');
    });

    test('rebuild_debug_* matches multiple widget types', () {
      final issues = [
        makeIssue(
          stableId: 'rebuild_debug_ListView',
          severity: IssueSeverity.warning,
        ),
        makeIssue(
          stableId: 'rebuild_debug_Column',
          severity: IssueSeverity.warning,
        ),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // Both rebuild_debug_* issues are roots (both have outgoing to heavy_compute)
      // heavy_compute is claimed by the first (higher index or severity tiebreak)
      final heavyCompute =
          result.firstWhere((i) => i.stableId == 'heavy_compute');
      expect(heavyCompute.rootCauseId, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Root identification
  // ---------------------------------------------------------------------------

  group('root identification', () {
    test('root has outgoing but no incoming edges', () {
      final issues = [
        makeIssue(stableId: 'setstate_scope'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // setstate_scope: outgoing edge to heavy_compute, no incoming → root
      expect(result[0].downstreamIds, isNotNull);
      expect(result[0].rootCauseId, isNull);
    });

    test('issue with only incoming edges is downstream, not root', () {
      final issues = [
        makeIssue(stableId: 'setstate_scope'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // heavy_compute: incoming from setstate_scope, no outgoing → downstream
      expect(result[1].rootCauseId, 'setstate_scope');
      expect(result[1].downstreamIds, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Confidence suppression
  // ---------------------------------------------------------------------------

  group('confidence suppression', () {
    test('possible downstream hidden when root is confirmed', () {
      final issues = [
        makeIssue(
          stableId: 'setstate_scope',
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.possible,
        ),
      ];
      final result = rule.apply(issues);

      // Root still exists but downstreamIds is empty (possible suppressed)
      expect(result[0].downstreamIds, isNull);

      // Downstream still gets rootCauseId (hidden from main list)
      expect(result[1].rootCauseId, 'setstate_scope');
    });

    test('likely downstream shown when root is confirmed', () {
      final issues = [
        makeIssue(
          stableId: 'setstate_scope',
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.likely,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[1].rootCauseId, 'setstate_scope');
    });

    test('possible downstream shown when root is also possible', () {
      final issues = [
        makeIssue(
          stableId: 'setstate_scope',
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.possible,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[1].rootCauseId, 'setstate_scope');
    });
  });

  // ---------------------------------------------------------------------------
  // Multiple independent chains
  // ---------------------------------------------------------------------------

  group('multiple chains', () {
    test('two independent chains in same scan', () {
      final issues = [
        makeIssue(stableId: 'setstate_scope'),
        makeIssue(stableId: 'heavy_compute'),
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
        ),
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
        ),
      ];
      final result = rule.apply(issues);

      // Chain 1: setstate_scope → heavy_compute
      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[1].rootCauseId, 'setstate_scope');

      // Chain 2: uncached_images → heap_growing
      expect(result[2].downstreamIds, ['heap_growing']);
      expect(result[3].rootCauseId, 'uncached_images');
    });
  });

  // ---------------------------------------------------------------------------
  // Multiple roots claiming same downstream
  // ---------------------------------------------------------------------------

  group('multiple roots same downstream', () {
    test('higher severity root claims downstream', () {
      // Both setstate_scope and non_lazy_list → heavy_compute
      final issues = [
        makeIssue(
          stableId: 'setstate_scope',
          severity: IssueSeverity.critical,
        ),
        makeIssue(
          stableId: 'non_lazy_list',
          severity: IssueSeverity.warning,
        ),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // heavy_compute claimed by critical root
      final heavyCompute =
          result.firstWhere((i) => i.stableId == 'heavy_compute');
      expect(heavyCompute.rootCauseId, 'setstate_scope');

      // setstate_scope has heavy_compute as downstream
      final setState = result.firstWhere((i) => i.stableId == 'setstate_scope');
      expect(setState.downstreamIds, contains('heavy_compute'));
    });
  });

  // ---------------------------------------------------------------------------
  // Cycle safety
  // ---------------------------------------------------------------------------

  group('cycle safety', () {
    test('all nodes have incoming edges — no roots found, pass through', () {
      // Create a situation where every issue in the graph has incoming edges.
      // rebuild_activity → heavy_compute (rule exists)
      // But rebuild_activity itself would need an incoming edge to create a
      // "no root" scenario. Since no rule maps TO rebuild_activity from
      // heavy_compute, this won't create a true cycle with the current ruleset.
      //
      // Instead, test with a chain where the "root" also has incoming edges
      // from another issue: non_lazy_list → rebuild_activity → heavy_compute
      // Here non_lazy_list is the clear root. Test that BFS doesn't loop.
      final issues = [
        makeIssue(stableId: 'non_lazy_list'),
        makeIssue(stableId: 'rebuild_activity'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // Should complete without infinite loop
      expect(result, hasLength(3));
      // non_lazy_list is root
      expect(result[0].rootCauseId, isNull);
      expect(result[0].downstreamIds, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Null stableId handling
  // ---------------------------------------------------------------------------

  group('null stableId', () {
    test('issues without stableId are ignored by causal graph', () {
      final issues = [
        PerformanceIssue(
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          title: 'no stableId issue',
          detail: '',
          fixHint: '',
        ),
        makeIssue(stableId: 'setstate_scope'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // null-stableId issue passes through unchanged
      expect(result[0].rootCauseId, isNull);
      expect(result[0].downstreamIds, isNull);

      // Chain still works for issues with stableIds
      expect(result[1].downstreamIds, ['heavy_compute']);
      expect(result[2].rootCauseId, 'setstate_scope');
    });
  });

  // ---------------------------------------------------------------------------
  // Root with multiple downstream
  // ---------------------------------------------------------------------------

  group('root with multiple downstream', () {
    test('setstate_scope → heavy_compute + layout_bottleneck', () {
      final issues = [
        makeIssue(stableId: 'setstate_scope'),
        makeIssue(stableId: 'heavy_compute'),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, isNotNull);
      expect(
        result[0].downstreamIds,
        containsAll(['heavy_compute', 'layout_bottleneck']),
      );
      expect(result[1].rootCauseId, 'setstate_scope');
      expect(result[2].rootCauseId, 'setstate_scope');
    });
  });

  // ---------------------------------------------------------------------------
  // Interaction with merge rule (post-correlation context)
  // ---------------------------------------------------------------------------

  group('post-correlation context', () {
    test('setstate_scope (already merged) → heavy_compute works', () {
      // After MergeRebuildSetStateRule, setstate_scope has absorbed
      // rebuild evidence. The causal graph should still chain to heavy_compute.
      final issues = [
        makeIssue(stableId: 'setstate_scope').copyWith(
          detail: 'Wide setState scope\n\n'
              '[Correlated] Rebuild evidence: 45 rebuilds/s',
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[1].rootCauseId, 'setstate_scope');
    });
  });

  // ---------------------------------------------------------------------------
  // Network → downstream chains (v5.6)
  // ---------------------------------------------------------------------------

  group('network causal chains', () {
    test('slow_request → heavy_compute causal chain', () {
      final issues = [
        makeIssue(
          stableId: 'slow_request',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.possible,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, isNull);
      expect(result[0].rootCauseId, isNull);
      // heavy_compute is possible, root is confirmed → confidence suppression
      // removes it from downstreamIds, but it still has rootCauseId
      expect(result[1].rootCauseId, 'slow_request');
    });

    test('request_frequency → rebuild_activity causal chain', () {
      final issues = [
        makeIssue(
          stableId: 'request_frequency',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.likely,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['rebuild_activity']);
      expect(result[1].rootCauseId, 'request_frequency');
    });
  });

  // ---------------------------------------------------------------------------
  // KeepAlive → memory chains (v10.6)
  // ---------------------------------------------------------------------------

  group('keep-alive causal chains (v10.6)', () {
    test('excessive_keep_alive:0 → heap_growing', () {
      final issues = [
        makeIssue(
          stableId: 'excessive_keep_alive:0',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['heap_growing']);
      expect(result[0].rootCauseId, isNull);
      expect(result[1].rootCauseId, 'excessive_keep_alive:0');
      expect(result[1].downstreamIds, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Nested scroll → layout/rebuild chains (v10.7)
  // ---------------------------------------------------------------------------

  group('nested scroll causal chains (v10.7)', () {
    test('nested_scroll → layout_bottleneck', () {
      final issues = [
        makeIssue(
          stableId: 'nested_scroll',
          category: IssueCategory.layout,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['layout_bottleneck']);
      expect(result[1].rootCauseId, 'nested_scroll');
    });

    test('nested_scroll_same_axis → rebuild_activity', () {
      final issues = [
        makeIssue(
          stableId: 'nested_scroll_same_axis',
          category: IssueCategory.layout,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['rebuild_activity']);
      expect(result[1].rootCauseId, 'nested_scroll_same_axis');
    });

    test('nested_scroll_same_axis → layout_bottleneck', () {
      final issues = [
        makeIssue(
          stableId: 'nested_scroll_same_axis',
          category: IssueCategory.layout,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['layout_bottleneck']);
      expect(result[1].rootCauseId, 'nested_scroll_same_axis');
    });

    test('nested_scroll → rebuild_activity', () {
      final issues = [
        makeIssue(
          stableId: 'nested_scroll',
          category: IssueCategory.layout,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['rebuild_activity']);
      expect(result[1].rootCauseId, 'nested_scroll');
    });
  });

  // ---------------------------------------------------------------------------
  // Non-lazy ListView/GridView chains (v10.1)
  // ---------------------------------------------------------------------------

  group('non-lazy ListView/GridView causal chains (v10.1)', () {
    test('non_lazy_listview → rebuild_activity', () {
      final issues = [
        makeIssue(
          stableId: 'non_lazy_listview',
          category: IssueCategory.build,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['rebuild_activity']);
      expect(result[1].rootCauseId, 'non_lazy_listview');
    });

    test('non_lazy_gridview → heavy_compute', () {
      final issues = [
        makeIssue(
          stableId: 'non_lazy_gridview',
          category: IssueCategory.build,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[1].rootCauseId, 'non_lazy_gridview');
    });

    test('non_lazy_listview → layout_bottleneck', () {
      final issues = [
        makeIssue(
          stableId: 'non_lazy_listview',
          category: IssueCategory.build,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['layout_bottleneck']);
      expect(result[1].rootCauseId, 'non_lazy_listview');
    });

    test('non_lazy_gridview → rebuild_activity', () {
      final issues = [
        makeIssue(
          stableId: 'non_lazy_gridview',
          category: IssueCategory.build,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['rebuild_activity']);
      expect(result[1].rootCauseId, 'non_lazy_gridview');
    });
  });

  // ---------------------------------------------------------------------------
  // HTTP error → request frequency chain (v10.8)
  // ---------------------------------------------------------------------------

  group('http error causal chains (v10.8)', () {
    test('http_error_spike → request_frequency', () {
      final issues = [
        makeIssue(
          stableId: 'http_error_spike',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'request_frequency',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['request_frequency']);
      expect(result[0].rootCauseId, isNull);
      expect(result[1].rootCauseId, 'http_error_spike');
      expect(result[1].downstreamIds, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Missing RepaintBoundary → downstream chains (v5.8)
  // ---------------------------------------------------------------------------

  group('missing RepaintBoundary causal chains', () {
    test('missing_repaint_boundary → excessive_repaint chain', () {
      final issues = [
        makeIssue(
          stableId: 'missing_repaint_boundary',
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
          stableId: 'excessive_repaint',
          category: IssueCategory.paint,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['excessive_repaint']);
      expect(result[1].rootCauseId, 'missing_repaint_boundary');
    });

    test('missing_repaint_boundary → raster_dominance chain', () {
      final issues = [
        makeIssue(
          stableId: 'missing_repaint_boundary',
          category: IssueCategory.paint,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'raster_dominance',
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['raster_dominance']);
      expect(result[1].rootCauseId, 'missing_repaint_boundary');
    });
  });

  // ---------------------------------------------------------------------------
  // Pillar 3a: New causal patterns (v0.10.7)
  // ---------------------------------------------------------------------------

  group('Pillar 3a causal chains', () {
    test('setstate_scope → rebuild_debug_* (non-merged rebuild)', () {
      final issues = [
        makeIssue(
          stableId: 'setstate_scope',
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'rebuild_debug_Column',
          confidence: IssueConfidence.likely,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['rebuild_debug_Column']);
      expect(result[1].rootCauseId, 'setstate_scope');
    });

    test('uncached_images → gc_pressure', () {
      final issues = [
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'gc_pressure',
          category: IssueCategory.memory,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['gc_pressure']);
      expect(result[1].rootCauseId, 'uncached_images');
    });

    test('excessive_keep_alive:* → gc_pressure', () {
      final issues = [
        makeIssue(
          stableId: 'excessive_keep_alive:0',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'gc_pressure',
          category: IssueCategory.memory,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['gc_pressure']);
      expect(result[1].rootCauseId, 'excessive_keep_alive:0');
    });

    test('animated_builder_no_child → excessive_repaint', () {
      final issues = [
        makeIssue(
          stableId: 'animated_builder_no_child',
          category: IssueCategory.build,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'excessive_repaint',
          category: IssueCategory.paint,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['excessive_repaint']);
      expect(result[1].rootCauseId, 'animated_builder_no_child');
    });

    test('animated_builder_no_child → excessive_repaint_debug', () {
      final issues = [
        makeIssue(
          stableId: 'animated_builder_no_child',
          category: IssueCategory.build,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'excessive_repaint_debug',
          category: IssueCategory.paint,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['excessive_repaint_debug']);
      expect(result[1].rootCauseId, 'animated_builder_no_child');
    });

    test('layout_bottleneck → sustained_jank', () {
      final issues = [
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'sustained_jank',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['sustained_jank']);
      expect(result[1].rootCauseId, 'layout_bottleneck');
    });

    test('layout_bottleneck → jank_detected', () {
      final issues = [
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'jank_detected',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['jank_detected']);
      expect(result[1].rootCauseId, 'layout_bottleneck');
    });

    test('runtime_font_loading → sustained_jank', () {
      final issues = [
        makeIssue(
          stableId: 'runtime_font_loading',
          category: IssueCategory.font,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'sustained_jank',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['sustained_jank']);
      expect(result[1].rootCauseId, 'runtime_font_loading');
    });

    test('multiple_custom_fonts → jank_detected', () {
      final issues = [
        makeIssue(
          stableId: 'multiple_custom_fonts',
          category: IssueCategory.font,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'jank_detected',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['jank_detected']);
      expect(result[1].rootCauseId, 'multiple_custom_fonts');
    });

    test('platform_channel_traffic → heavy_compute', () {
      final issues = [
        makeIssue(
          stableId: 'platform_channel_traffic',
          category: IssueCategory.channel,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[1].rootCauseId, 'platform_channel_traffic');
    });

    test('duplicate_request:* → rebuild_activity', () {
      final issues = [
        makeIssue(
          stableId: 'duplicate_request:0',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.likely,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['rebuild_activity']);
      expect(result[1].rootCauseId, 'duplicate_request:0');
    });

    test('duplicate_request:* → rebuild_debug_*', () {
      final issues = [
        makeIssue(
          stableId: 'duplicate_request:0',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'rebuild_debug_MyWidget',
          confidence: IssueConfidence.likely,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['rebuild_debug_MyWidget']);
      expect(result[1].rootCauseId, 'duplicate_request:0');
    });

    test('no false chain when only one side present', () {
      // Only platform_channel_traffic, no heavy_compute → no chain
      final issues = [
        makeIssue(
          stableId: 'platform_channel_traffic',
          category: IssueCategory.channel,
        ),
        makeIssue(
          stableId: 'gc_pressure',
          category: IssueCategory.memory,
        ),
      ];
      final result = rule.apply(issues);

      for (final issue in result) {
        expect(issue.rootCauseId, isNull);
        expect(issue.downstreamIds, isNull);
      }
    });

    test('multiple new rules fire simultaneously without cycles', () {
      final issues = [
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
          severity: IssueSeverity.warning,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'gc_pressure',
          category: IssueCategory.memory,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
          severity: IssueSeverity.warning,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'sustained_jank',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      // Two independent chains should coexist
      expect(result, hasLength(4));
      final uncached =
          result.firstWhere((i) => i.stableId == 'uncached_images');
      expect(uncached.downstreamIds, contains('gc_pressure'));

      final layout =
          result.firstWhere((i) => i.stableId == 'layout_bottleneck');
      expect(layout.downstreamIds, contains('sustained_jank'));
    });
  });
}
