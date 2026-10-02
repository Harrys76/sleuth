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
  }) => PerformanceIssue(
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
      expect(result[0].rootCauseIds, isNull);
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
        expect(issue.rootCauseIds, isNull);
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
      expect(result[0].rootCauseIds, isNull);

      // heavy_compute is downstream
      expect(result[1].rootCauseIds, ['setstate_scope']);
      expect(result[1].downstreamIds, isNull);
    });

    test('likely uncached_images → likely native_memory_growing', () {
      // Decoded bitmaps live in native memory.
      final issues = [
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'native_memory_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
      ];
      final result = rule.apply(issues);
      expect(result[0].downstreamIds, ['native_memory_growing']);
      expect(result[1].rootCauseIds, ['uncached_images']);
    });

    test('possible uncached_images does not claim likely '
        'native_memory_growing', () {
      final issues = [
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
          stableId: 'native_memory_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
      ];
      final result = rule.apply(issues);
      expect(result[0].downstreamIds, isNull);
      expect(result[1].rootCauseIds, isNull);
    });

    test('always_repaint_painter → raster_dominance', () {
      final issues = [
        makeIssue(
          stableId: 'always_repaint_painter',
          category: IssueCategory.paint,
        ),
        makeIssue(stableId: 'raster_dominance', category: IssueCategory.raster),
      ];
      final result = rule.apply(issues);
      expect(result[0].downstreamIds, ['raster_dominance']);
      expect(result[1].rootCauseIds, ['always_repaint_painter']);
    });

    test('non_lazy_list does NOT collapse layout_bottleneck', () {
      final issues = [
        makeIssue(stableId: 'non_lazy_list', category: IssueCategory.build),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
        ),
      ];
      final result = rule.apply(issues);
      // layout_bottleneck is independently actionable — not downstream
      expect(result[0].downstreamIds, isNull);
      expect(result[1].rootCauseIds, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Multi-hop chains
  // ---------------------------------------------------------------------------

  group('multi-hop chains', () {
    test('non_lazy_list → rebuild_activity → heavy_compute', () {
      final issues = [
        makeIssue(stableId: 'non_lazy_list', severity: IssueSeverity.warning),
        makeIssue(stableId: 'rebuild_activity'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // non_lazy_list is root with both downstream
      expect(result[0].rootCauseIds, isNull);
      expect(result[0].downstreamIds, isNotNull);
      expect(
        result[0].downstreamIds,
        containsAll(['rebuild_activity', 'heavy_compute']),
      );

      // Both are downstream of non_lazy_list
      expect(result[1].rootCauseIds, ['non_lazy_list']);
      expect(result[2].rootCauseIds, ['non_lazy_list']);
    });

    test(
      'animated_builder_no_child → rebuild_debug_MyWidget → heavy_compute',
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
        expect(
          result[0].downstreamIds,
          containsAll(['rebuild_debug_MyWidget', 'heavy_compute']),
        );
        expect(result[1].rootCauseIds, ['animated_builder_no_child']);
        expect(result[2].rootCauseIds, ['animated_builder_no_child']);
      },
    );
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
      expect(result[1].rootCauseIds, ['rebuild_debug_MyWidget']);
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
      final heavyCompute = result.firstWhere(
        (i) => i.stableId == 'heavy_compute',
      );
      expect(heavyCompute.rootCauseIds, isNotNull);
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
      expect(result[0].rootCauseIds, isNull);
    });

    test('issue with only incoming edges is downstream, not root', () {
      final issues = [
        makeIssue(stableId: 'setstate_scope'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final result = rule.apply(issues);

      // heavy_compute: incoming from setstate_scope, no outgoing → downstream
      expect(result[1].rootCauseIds, ['setstate_scope']);
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
      expect(result[1].rootCauseIds, ['setstate_scope']);
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
      expect(result[1].rootCauseIds, ['setstate_scope']);
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
      expect(result[1].rootCauseIds, ['setstate_scope']);
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
        makeIssue(stableId: 'uncached_images', category: IssueCategory.memory),
        makeIssue(
          stableId: 'native_memory_growing',
          category: IssueCategory.memory,
        ),
      ];
      final result = rule.apply(issues);

      // Chain 1: setstate_scope → heavy_compute
      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[1].rootCauseIds, ['setstate_scope']);

      // Chain 2: uncached_images → native_memory_growing
      expect(result[2].downstreamIds, ['native_memory_growing']);
      expect(result[3].rootCauseIds, ['uncached_images']);
    });
  });

  // ---------------------------------------------------------------------------
  // Multiple roots claiming same downstream
  // ---------------------------------------------------------------------------

  group('multiple roots same downstream', () {
    test(
      'every co-firing root claims downstream (multi-parent, severity-sorted)',
      () {
        // Both setstate_scope (direct rule) and non_lazy_list (multi-hop via
        // rebuild_activity) reach heavy_compute. Multi-parent annotation
        // (v0.24.2+) lists every reaching root in rootCauseIds; sort key is
        // severity desc then stableId asc, so the critical root precedes
        // the warning root.
        final issues = [
          makeIssue(
            stableId: 'setstate_scope',
            severity: IssueSeverity.critical,
          ),
          makeIssue(stableId: 'non_lazy_list', severity: IssueSeverity.warning),
          makeIssue(stableId: 'heavy_compute'),
        ];
        final result = rule.apply(issues);

        final heavyCompute = result.firstWhere(
          (i) => i.stableId == 'heavy_compute',
        );
        expect(heavyCompute.rootCauseIds, [
          'setstate_scope',
          'non_lazy_list',
        ], reason: 'critical-severity root sorts before warning-severity root');

        // Both roots have heavy_compute as downstream.
        final setState = result.firstWhere(
          (i) => i.stableId == 'setstate_scope',
        );
        expect(setState.downstreamIds, contains('heavy_compute'));
        final nonLazy = result.firstWhere((i) => i.stableId == 'non_lazy_list');
        expect(nonLazy.downstreamIds, contains('heavy_compute'));
      },
    );
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
      expect(result[0].rootCauseIds, isNull);
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
      expect(result[0].rootCauseIds, isNull);
      expect(result[0].downstreamIds, isNull);

      // Chain still works for issues with stableIds
      expect(result[1].downstreamIds, ['heavy_compute']);
      expect(result[2].rootCauseIds, ['setstate_scope']);
    });
  });

  // ---------------------------------------------------------------------------
  // Root with multiple downstream
  // ---------------------------------------------------------------------------

  group('root with multiple downstream', () {
    test('setstate_scope → heavy_compute (layout_bottleneck standalone)', () {
      final issues = [
        makeIssue(stableId: 'setstate_scope'),
        makeIssue(stableId: 'heavy_compute'),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
        ),
      ];
      final result = rule.apply(issues);

      // layout_bottleneck is independently actionable — only heavy_compute
      // is downstream of setstate_scope
      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[1].rootCauseIds, ['setstate_scope']);
      expect(result[2].rootCauseIds, isNull);
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
          detail:
              'Wide setState scope\n\n'
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
      expect(result[1].rootCauseIds, ['setstate_scope']);
    });
  });

  // ---------------------------------------------------------------------------
  // Network → downstream chains (v5.6)
  // ---------------------------------------------------------------------------

  group('network causal chains', () {
    test('large_response → heavy_compute causal chain', () {
      // JSON decode of a large body runs on the main isolate.
      final issues = [
        makeIssue(
          stableId: 'large_response',
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
      expect(result[0].rootCauseIds, isNull);
      // heavy_compute is possible, root is confirmed → confidence suppression
      // removes it from downstreamIds, but it still has rootCauseIds
      expect(result[1].rootCauseIds, ['large_response']);
    });

    test('large_response → confirmed heavy_compute lists the downstream', () {
      final issues = [
        makeIssue(
          stableId: 'large_response',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['heavy_compute']);
      expect(result[1].rootCauseIds, ['large_response']);
      expect(CausalGraphRule.activeEdges(issues), [
        {'cause': 'large_response', 'effect': 'heavy_compute'},
      ]);
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
      expect(result[0].rootCauseIds, isNull);
      expect(result[1].rootCauseIds, ['excessive_keep_alive:0']);
      expect(result[1].downstreamIds, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Nested scroll → layout/rebuild chains (v10.7)
  // ---------------------------------------------------------------------------

  group('nested scroll causal chains (v10.7)', () {
    test('nested_scroll does NOT collapse layout_bottleneck', () {
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

      // layout_bottleneck is independently actionable — standalone
      expect(result[0].downstreamIds, isNull);
      expect(result[1].rootCauseIds, isNull);
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
      expect(result[1].rootCauseIds, ['nested_scroll_same_axis']);
    });

    test('nested_scroll_same_axis does NOT collapse layout_bottleneck', () {
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

      // layout_bottleneck is independently actionable — standalone
      expect(result[0].downstreamIds, isNull);
      expect(result[1].rootCauseIds, isNull);
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
      expect(result[1].rootCauseIds, ['nested_scroll']);
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
      expect(result[1].rootCauseIds, ['non_lazy_listview']);
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
      expect(result[1].rootCauseIds, ['non_lazy_gridview']);
    });

    test('non_lazy_listview does NOT collapse layout_bottleneck', () {
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

      // layout_bottleneck is independently actionable — standalone
      expect(result[0].downstreamIds, isNull);
      expect(result[1].rootCauseIds, isNull);
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
      expect(result[1].rootCauseIds, ['non_lazy_gridview']);
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
      expect(result[0].rootCauseIds, isNull);
      expect(result[1].rootCauseIds, ['http_error_spike']);
      expect(result[1].downstreamIds, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Missing RepaintBoundary → downstream chains (v5.8)
  // ---------------------------------------------------------------------------

  group('missing RepaintBoundary causal chains', () {
    test('possible missing_repaint_boundary does not claim confirmed '
        'excessive_repaint', () {
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

      expect(result[0].downstreamIds, isNull);
      expect(result[1].rootCauseIds, isNull);
    });

    test('likely missing_repaint_boundary → excessive_repaint chain', () {
      final issues = [
        makeIssue(
          stableId: 'missing_repaint_boundary',
          category: IssueCategory.paint,
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
      expect(result[1].rootCauseIds, ['missing_repaint_boundary']);
    });

    test('excessive_repaint → raster_dominance chain', () {
      final issues = [
        makeIssue(
          stableId: 'excessive_repaint',
          category: IssueCategory.paint,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'raster_dominance',
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['raster_dominance']);
      expect(result[1].rootCauseIds, ['excessive_repaint']);
      expect(CausalGraphRule.activeEdges(issues), [
        {'cause': 'excessive_repaint', 'effect': 'raster_dominance'},
      ]);
    });

    test('likely missing_repaint_boundary reaches raster_dominance through '
        'excessive_repaint', () {
      final issues = [
        makeIssue(
          stableId: 'missing_repaint_boundary',
          category: IssueCategory.paint,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'excessive_repaint',
          category: IssueCategory.paint,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'raster_dominance',
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, [
        'excessive_repaint',
        'raster_dominance',
      ]);
      expect(result[1].rootCauseIds, ['missing_repaint_boundary']);
      expect(result[2].rootCauseIds, ['missing_repaint_boundary']);
    });
  });

  // ---------------------------------------------------------------------------
  // Confidence guard: possible roots claim only possible effects
  // ---------------------------------------------------------------------------

  group('confidence guard', () {
    test('possible → confirmed is not claimed', () {
      final issues = [
        makeIssue(stableId: 'non_lazy_list'),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, isNull);
      expect(result[1].rootCauseIds, isNull);
    });

    test('possible → likely is not claimed', () {
      final issues = [
        makeIssue(stableId: 'non_lazy_list'),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.likely,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, isNull);
      expect(result[1].rootCauseIds, isNull);
    });

    test('possible always_repaint_painter does not claim a likely '
        'frame-timing raster_dominance', () {
      final issues = [
        makeIssue(stableId: 'always_repaint_painter'),
        makeIssue(
          stableId: 'raster_dominance',
          category: IssueCategory.raster,
          confidence: IssueConfidence.likely,
        ).copyWith(observationSource: ObservationSource.frameTiming),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, isNull);
      expect(result[1].rootCauseIds, isNull);
    });

    test('possible → possible is claimed', () {
      final issues = [
        makeIssue(stableId: 'non_lazy_list'),
        makeIssue(stableId: 'rebuild_activity'),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['rebuild_activity']);
      expect(result[1].rootCauseIds, ['non_lazy_list']);
    });

    test('likely → confirmed is claimed', () {
      final issues = [
        makeIssue(
          stableId: 'non_lazy_list',
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      expect(result[0].downstreamIds, ['rebuild_activity']);
      expect(result[1].rootCauseIds, ['non_lazy_list']);
    });

    test('chain A(possible) → B(confirmed) → C(confirmed): B becomes the '
        'root, A claims nothing', () {
      final issues = [
        makeIssue(stableId: 'non_lazy_list'),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = rule.apply(issues);

      // non_lazy_list → heavy_compute is also a rule edge; the guard drops
      // it as well.
      expect(result[0].downstreamIds, isNull);
      expect(result[0].rootCauseIds, isNull);
      expect(result[1].rootCauseIds, isNull);
      expect(result[1].downstreamIds, ['heavy_compute']);
      expect(result[2].rootCauseIds, ['rebuild_activity']);
    });

    test('activeEdges omits possible → confirmed pairs', () {
      final edges = CausalGraphRule.activeEdges([
        makeIssue(stableId: 'non_lazy_list'),
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.confirmed,
        ),
      ]);
      expect(edges, isEmpty);
    });

    test('activeEdges keeps possible → possible pairs', () {
      final edges = CausalGraphRule.activeEdges([
        makeIssue(stableId: 'non_lazy_list'),
        makeIssue(stableId: 'rebuild_activity'),
      ]);
      expect(edges, [
        {'cause': 'non_lazy_list', 'effect': 'rebuild_activity'},
      ]);
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
      expect(result[1].rootCauseIds, ['setstate_scope']);
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
      expect(result[1].rootCauseIds, ['animated_builder_no_child']);
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
      expect(result[1].rootCauseIds, ['animated_builder_no_child']);
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
      expect(result[1].rootCauseIds, ['layout_bottleneck']);
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
      expect(result[1].rootCauseIds, ['layout_bottleneck']);
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
      expect(result[1].rootCauseIds, ['runtime_font_loading']);
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
      expect(result[1].rootCauseIds, ['platform_channel_traffic']);
    });

    test('no false chain when only one side present', () {
      // Only platform_channel_traffic, no heavy_compute → no chain
      final issues = [
        makeIssue(
          stableId: 'platform_channel_traffic',
          category: IssueCategory.channel,
        ),
        makeIssue(stableId: 'gc_pressure', category: IssueCategory.memory),
      ];
      final result = rule.apply(issues);

      for (final issue in result) {
        expect(issue.rootCauseIds, isNull);
        expect(issue.downstreamIds, isNull);
      }
    });

    test('multiple new rules fire simultaneously without cycles', () {
      final issues = [
        makeIssue(
          stableId: 'stream_resource_growth',
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
      final stream = result.firstWhere(
        (i) => i.stableId == 'stream_resource_growth',
      );
      expect(stream.downstreamIds, contains('gc_pressure'));

      final layout = result.firstWhere(
        (i) => i.stableId == 'layout_bottleneck',
      );
      expect(layout.downstreamIds, contains('sustained_jank'));
    });
  });

  // ---------------------------------------------------------------------------
  // Memory fan-in multi-parent annotation (v0.24.2+)
  // ---------------------------------------------------------------------------

  // Pins the multi-parent annotation contract for a 3-cause memory fan-in:
  // when excessive_keep_alive:foo, stream_resource_growth, and
  // tracked_resource_concurrent:x co-fire alongside heap_growing, the
  // effect carries ALL three upstream causes in rootCauseIds and every
  // cause lists heap_growing in downstreamIds. apply() mirrors
  // activeEdges()'s parallel-edge enumeration on the UI annotation path.
  group('memory fan-in multi-parent annotation', () {
    const causes = [
      'excessive_keep_alive:foo',
      'stream_resource_growth',
      'tracked_resource_concurrent:x',
    ];

    test('3 causes → heap_growing: the effect carries all 3 parents; every '
        'cause lists the downstream', () {
      final issues = [
        for (final id in causes)
          makeIssue(stableId: id, category: IssueCategory.memory),
        makeIssue(stableId: 'heap_growing', category: IssueCategory.memory),
      ];
      final result = rule.apply(issues);

      PerformanceIssue findById(String id) =>
          result.firstWhere((i) => i.stableId == id);

      // Severity is tied (all warning), so deterministic order is
      // stableId ascending.
      final effect = findById('heap_growing');
      expect(
        effect.rootCauseIds,
        causes,
        reason: 'heap_growing must list every co-firing cause, sorted',
      );
      expect(effect.downstreamIds, isNull);

      for (final causeId in causes) {
        final cause = findById(causeId);
        expect(
          cause.rootCauseIds,
          isNull,
          reason: '$causeId is a root — no incoming edges',
        );
        expect(cause.downstreamIds, ['heap_growing']);
      }
    });

    test('multi-parent rule-ordering invariant: shuffling input issue order '
        'does not change rootCauseIds membership', () {
      // Multi-parent annotation MUST be order-independent: every parent
      // that reaches a downstream appears in rootCauseIds regardless of
      // input order.
      final ids = [...causes, 'heap_growing', 'heap_near_capacity'];
      List<PerformanceIssue> build(List<String> order) => [
        for (final id in order)
          makeIssue(stableId: id, category: IssueCategory.memory),
      ];

      final ascending = rule.apply(build(ids));
      final reversed = rule.apply(build(ids.reversed.toList()));

      Set<String> parentsOf(List<PerformanceIssue> result, String id) =>
          result.firstWhere((i) => i.stableId == id).rootCauseIds!.toSet();

      for (final effect in ['heap_growing', 'heap_near_capacity']) {
        expect(
          parentsOf(ascending, effect),
          parentsOf(reversed, effect),
          reason:
              'rootCauseIds membership for $effect must be input-order independent',
        );
      }
      expect(parentsOf(ascending, 'heap_growing'), causes.toSet());
    });

    test('multi-parent confidence suppression: possible downstream with '
        'any-stronger parent is dropped from downstreamIds but retains '
        'rootCauseIds', () {
      // 3 causes, 1 possible-confidence downstream. Two causes are likely
      // (stronger), one is possible (same tier). Suppression rule:
      // possible downstream skipped from EVERY likely parent's
      // downstreamIds; possible parent's downstreamIds also skipped
      // (because ANY stronger parent triggers global suppression).
      final issues = [
        makeIssue(
          stableId: 'stream_resource_growth',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'tracked_resource_concurrent:x',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'excessive_keep_alive:foo',
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
        ),
      ];
      final result = rule.apply(issues);

      PerformanceIssue findById(String id) =>
          result.firstWhere((i) => i.stableId == id);

      // Downstream still carries rootCauseIds — UI annotation works.
      final downstream = findById('heap_growing');
      expect(downstream.rootCauseIds, containsAll(causes));

      // No parent lists this downstream in downstreamIds — suppressed
      // because at least one parent is likely-confidence.
      for (final parentId in causes) {
        expect(
          findById(parentId).downstreamIds,
          isNull,
          reason:
              '$parentId must not list possible-downstream when any-stronger parent suppresses',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // activeEdges static method (v0.10.7 — 3b.9 Session Summary Export)
  // ---------------------------------------------------------------------------

  group('activeEdges', () {
    bool hasEdge(
      List<Map<String, String>> edges,
      String cause,
      String effect,
    ) => edges.any((e) => e['cause'] == cause && e['effect'] == effect);

    test('returns edges for co-occurring issues with a causal rule', () {
      final issues = [
        makeIssue(stableId: 'setstate_scope'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final edges = CausalGraphRule.activeEdges(issues);

      expect(edges, isNotEmpty);
      expect(hasEdge(edges, 'setstate_scope', 'heavy_compute'), isTrue);
    });

    test('returns empty for single issue', () {
      final issues = [makeIssue(stableId: 'setstate_scope')];
      final edges = CausalGraphRule.activeEdges(issues);

      expect(edges, isEmpty);
    });

    test('returns empty for unrelated issues', () {
      final issues = [
        makeIssue(
          stableId: 'shader_compilation',
          category: IssueCategory.raster,
        ),
        makeIssue(stableId: 'gc_pressure', category: IssueCategory.memory),
      ];
      final edges = CausalGraphRule.activeEdges(issues);

      expect(edges, isEmpty);
    });

    test('deduplicates same cause-effect pair from multiple rule matches', () {
      // non_lazy_list has rules pointing to both rebuild_activity and
      // heavy_compute. Two separate issues that both match rebuild_debug_*
      // prefix should not produce duplicate edges for the same pair.
      final issues = [
        makeIssue(stableId: 'non_lazy_list'),
        makeIssue(stableId: 'rebuild_activity'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final edges = CausalGraphRule.activeEdges(issues);

      // Count edges from non_lazy_list → rebuild_activity
      final rebuildEdges = edges.where(
        (e) =>
            e['cause'] == 'non_lazy_list' && e['effect'] == 'rebuild_activity',
      );
      expect(
        rebuildEdges,
        hasLength(1),
        reason: 'Same cause→effect pair should appear exactly once',
      );

      // Count edges from non_lazy_list → heavy_compute
      final computeEdges = edges.where(
        (e) => e['cause'] == 'non_lazy_list' && e['effect'] == 'heavy_compute',
      );
      expect(computeEdges, hasLength(1));
    });

    test('returns edges for prefix-matched stableIds', () {
      final issues = [
        makeIssue(stableId: 'rebuild_debug_MyWidget'),
        makeIssue(stableId: 'heavy_compute'),
      ];
      final edges = CausalGraphRule.activeEdges(issues);

      expect(edges, isNotEmpty);
      expect(hasEdge(edges, 'rebuild_debug_MyWidget', 'heavy_compute'), isTrue);
    });

    test('returns empty for empty issue list', () {
      final edges = CausalGraphRule.activeEdges([]);
      expect(edges, isEmpty);
    });

    test('returns multiple edges for multi-hop chain', () {
      final issues = [
        makeIssue(stableId: 'setstate_scope'),
        makeIssue(stableId: 'heavy_compute'),
        makeIssue(stableId: 'rebuild_debug_MyWidget'),
      ];
      final edges = CausalGraphRule.activeEdges(issues);

      expect(hasEdge(edges, 'setstate_scope', 'heavy_compute'), isTrue);
      expect(
        hasEdge(edges, 'setstate_scope', 'rebuild_debug_MyWidget'),
        isTrue,
      );
    });

    test('stream_resource_growth → heap_growing edge surfaces on co-fire', () {
      final issues = [
        makeIssue(
          stableId: 'stream_resource_growth',
          category: IssueCategory.memory,
        ),
        makeIssue(stableId: 'heap_growing', category: IssueCategory.memory),
      ];
      final edges = CausalGraphRule.activeEdges(issues);
      expect(hasEdge(edges, 'stream_resource_growth', 'heap_growing'), isTrue);
    });

    test(
      'stream_resource_growth → heap_near_capacity edge surfaces on co-fire',
      () {
        final issues = [
          makeIssue(
            stableId: 'stream_resource_growth',
            category: IssueCategory.memory,
          ),
          makeIssue(
            stableId: 'heap_near_capacity',
            category: IssueCategory.memory,
          ),
        ];
        final edges = CausalGraphRule.activeEdges(issues);
        expect(
          hasEdge(edges, 'stream_resource_growth', 'heap_near_capacity'),
          isTrue,
        );
      },
    );

    test('stream_resource_growth → gc_pressure edge surfaces on co-fire', () {
      final issues = [
        makeIssue(
          stableId: 'stream_resource_growth',
          category: IssueCategory.memory,
        ),
        makeIssue(stableId: 'gc_pressure', category: IssueCategory.memory),
      ];
      final edges = CausalGraphRule.activeEdges(issues);
      expect(hasEdge(edges, 'stream_resource_growth', 'gc_pressure'), isTrue);
    });

    test(
      'stream_resource_growth alone surfaces no causal edges (negative control)',
      () {
        final issues = [
          makeIssue(
            stableId: 'stream_resource_growth',
            category: IssueCategory.memory,
          ),
        ];
        final edges = CausalGraphRule.activeEdges(issues);
        expect(edges, isEmpty);
      },
    );

    test(
      'tracked_resource_concurrent → heap_growing edge surfaces on co-fire',
      () {
        final issues = [
          makeIssue(
            stableId: 'tracked_resource_concurrent:chat_socket',
            category: IssueCategory.memory,
          ),
          makeIssue(stableId: 'heap_growing', category: IssueCategory.memory),
        ];
        final edges = CausalGraphRule.activeEdges(issues);
        expect(
          hasEdge(
            edges,
            'tracked_resource_concurrent:chat_socket',
            'heap_growing',
          ),
          isTrue,
        );
      },
    );

    test(
      'tracked_resource_long_lived → heap_growing edge surfaces on co-fire',
      () {
        final issues = [
          makeIssue(
            stableId: 'tracked_resource_long_lived:chat_socket',
            category: IssueCategory.memory,
          ),
          makeIssue(stableId: 'heap_growing', category: IssueCategory.memory),
        ];
        final edges = CausalGraphRule.activeEdges(issues);
        expect(
          hasEdge(
            edges,
            'tracked_resource_long_lived:chat_socket',
            'heap_growing',
          ),
          isTrue,
        );
      },
    );

    test(
      'tracked_resource alone surfaces no causal edges (negative control)',
      () {
        final issues = [
          makeIssue(
            stableId: 'tracked_resource_concurrent:chat_socket',
            category: IssueCategory.memory,
          ),
          makeIssue(
            stableId: 'tracked_resource_long_lived:chat_socket',
            category: IssueCategory.memory,
          ),
        ];
        final edges = CausalGraphRule.activeEdges(issues);
        expect(edges, isEmpty);
      },
    );

    test('tracked_resource_concurrent + stream_resource_growth co-firing on '
        'heap_growing both surface as parents', () {
      final issues = [
        makeIssue(
          stableId: 'tracked_resource_concurrent:chat_socket',
          category: IssueCategory.memory,
        ),
        makeIssue(
          stableId: 'stream_resource_growth',
          category: IssueCategory.memory,
        ),
        makeIssue(stableId: 'heap_growing', category: IssueCategory.memory),
      ];
      final edges = CausalGraphRule.activeEdges(issues);
      expect(
        hasEdge(
          edges,
          'tracked_resource_concurrent:chat_socket',
          'heap_growing',
        ),
        isTrue,
      );
      expect(hasEdge(edges, 'stream_resource_growth', 'heap_growing'), isTrue);
    });

    test('multi-cause memory co-fire surfaces every parallel edge', () {
      // 3 causes → heap_growing. Each cause→effect pair must surface as a
      // distinct edge so the UI's "Caused by" section can list all three
      // causes.
      const causes = [
        'stream_resource_growth',
        'tracked_resource_concurrent:x',
        'excessive_keep_alive:foo',
      ];
      final issues = [
        for (final id in causes)
          makeIssue(stableId: id, category: IssueCategory.memory),
        makeIssue(stableId: 'heap_growing', category: IssueCategory.memory),
      ];
      final edges = CausalGraphRule.activeEdges(issues);
      for (final cause in causes) {
        expect(
          hasEdge(edges, cause, 'heap_growing'),
          isTrue,
          reason: 'Expected $cause → heap_growing edge to surface on co-fire.',
        );
      }
      expect(edges, hasLength(3));
    });
  });

  // ---------------------------------------------------------------------------
  // Removed edges: evidence direction and memory type
  // ---------------------------------------------------------------------------

  group('removed edges', () {
    // Both ends likely/confirmed so the confidence guard is not what
    // blocks the claim — only the missing rule is.
    const removed = [
      ('uncached_images', 'heap_growing'),
      ('uncached_images', 'heap_near_capacity'),
      ('uncached_images', 'gc_pressure'),
      ('excessive_keep_alive:0', 'gc_pressure'),
      ('slow_request', 'heavy_compute'),
      ('request_frequency', 'rebuild_activity'),
      ('high_frequency_same_path:0', 'rebuild_activity'),
      ('high_frequency_same_path:0', 'rebuild_debug_MyWidget'),
      ('multiple_custom_fonts', 'sustained_jank'),
      ('multiple_custom_fonts', 'jank_detected'),
      ('missing_repaint_boundary', 'raster_dominance'),
    ];

    for (final (cause, effect) in removed) {
      test('$cause → $effect is not an edge', () {
        final issues = [
          makeIssue(stableId: cause, confidence: IssueConfidence.likely),
          makeIssue(stableId: effect, confidence: IssueConfidence.confirmed),
        ];
        final result = rule.apply(issues);

        expect(result[0].downstreamIds, isNull);
        expect(result[1].rootCauseIds, isNull);
        expect(CausalGraphRule.activeEdges(issues), isEmpty);
      });
    }

    test('rulesJson carries none of the removed pairs', () {
      final pairs = {
        for (final r in CausalGraphRule.rulesJson)
          '${r['trigger']}→${r['effect']}',
      };
      for (final p in const [
        'uncached_images→heap_growing',
        'uncached_images→heap_near_capacity',
        'uncached_images→gc_pressure',
        'excessive_keep_alive:*→gc_pressure',
        'slow_request→heavy_compute',
        'request_frequency→rebuild_activity',
        'high_frequency_same_path:*→rebuild_activity',
        'high_frequency_same_path:*→rebuild_debug_*',
        'multiple_custom_fonts→sustained_jank',
        'multiple_custom_fonts→jank_detected',
        'missing_repaint_boundary→raster_dominance',
      ]) {
        expect(pairs, isNot(contains(p)));
      }
      expect(CausalGraphRule.rulesJson, hasLength(40));
    });

    test('no rule has jank_detected or sustained_jank as effect except the '
        'layout_bottleneck and runtime_font_loading edges', () {
      final jankEdges = {
        for (final r in CausalGraphRule.rulesJson)
          if (r['effect'] == 'jank_detected' || r['effect'] == 'sustained_jank')
            '${r['trigger']}→${r['effect']}',
      };
      expect(jankEdges, {
        'layout_bottleneck→sustained_jank',
        'layout_bottleneck→jank_detected',
        'runtime_font_loading→sustained_jank',
        'runtime_font_loading→jank_detected',
      });
    });
  });
}
