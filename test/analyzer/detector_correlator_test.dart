import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/analyzer/detector_correlator.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  const correlator = DetectorCorrelator();

  // ---------------------------------------------------------------------------
  // Helper
  // ---------------------------------------------------------------------------

  PerformanceIssue makeIssue({
    String? stableId,
    String? widgetName,
    IssueCategory category = IssueCategory.build,
    IssueConfidence confidence = IssueConfidence.possible,
    IssueSeverity severity = IssueSeverity.warning,
    String title = 'test issue',
    String detail = 'test detail',
  }) =>
      PerformanceIssue(
        severity: severity,
        category: category,
        confidence: confidence,
        title: title,
        detail: detail,
        fixHint: '',
        stableId: stableId,
        widgetName: widgetName,
      );

  // ---------------------------------------------------------------------------
  // Passthrough
  // ---------------------------------------------------------------------------

  group('passthrough', () {
    test('empty list returns empty', () {
      expect(correlator.correlate([]), isEmpty);
    });

    test('single issue passes through unchanged', () {
      final issue = makeIssue(stableId: 'some_unrelated_issue');
      final result = correlator.correlate([issue]);
      expect(result, hasLength(1));
      expect(result[0].stableId, 'some_unrelated_issue');
    });

    test('unrelated issues pass through unchanged', () {
      final issues = [
        makeIssue(stableId: 'slow_request', category: IssueCategory.network),
        makeIssue(
            stableId: 'layout_bottleneck', category: IssueCategory.layout),
        makeIssue(
            stableId: 'multiple_custom_fonts', category: IssueCategory.font),
      ];
      final result = correlator.correlate(issues);
      expect(result, hasLength(3));
      expect(result.map((i) => i.stableId).toList(), [
        'slow_request',
        'layout_bottleneck',
        'multiple_custom_fonts',
      ]);
    });
  });

  // ---------------------------------------------------------------------------
  // SuppressAnimatedBuilderRule (Rule 4)
  // ---------------------------------------------------------------------------

  group('SuppressAnimatedBuilderRule', () {
    test('suppresses animated_builder when possible and no paint issues', () {
      final issues = [
        makeIssue(
          stableId: 'animated_builder_no_child',
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
            stableId: 'layout_bottleneck', category: IssueCategory.layout),
      ];

      final result = correlator.correlate(issues);
      expect(result, hasLength(1));
      expect(result[0].stableId, 'layout_bottleneck');
    });

    test('does NOT suppress when confidence is likely', () {
      final issues = [
        makeIssue(
          stableId: 'animated_builder_no_child',
          category: IssueCategory.build,
          confidence: IssueConfidence.likely,
        ),
      ];

      final result = correlator.correlate(issues);
      expect(result, hasLength(1));
      expect(result[0].stableId, 'animated_builder_no_child');
    });

    test('does NOT suppress when paint issues exist', () {
      final issues = [
        makeIssue(
          stableId: 'animated_builder_no_child',
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
          stableId: 'excessive_repaint',
          category: IssueCategory.paint,
          confidence: IssueConfidence.confirmed,
        ),
      ];

      final result = correlator.correlate(issues);
      expect(result, hasLength(2));
      expect(result.map((i) => i.stableId).toList(), [
        'animated_builder_no_child',
        'excessive_repaint',
      ]);
    });
  });

  // ---------------------------------------------------------------------------
  // MergeRebuildSetStateRule (Rule 1)
  // ---------------------------------------------------------------------------

  group('MergeRebuildSetStateRule', () {
    test('merges rebuild_debug_X with setstate_scope on same widgetName', () {
      final issues = [
        makeIssue(
          stableId: 'rebuild_debug_MyWidget',
          widgetName: 'MyWidget',
          confidence: IssueConfidence.confirmed,
          title: 'High Rebuild Activity: 45 builds/sec',
        ),
        makeIssue(
          stableId: 'setstate_scope',
          widgetName: 'MyWidget',
          confidence: IssueConfidence.likely,
          title: 'Wide setState Scope: MyWidget owns ~80% of tree',
          detail: 'MyWidget has 200 of 250 elements.',
        ),
      ];

      final result = correlator.correlate(issues);
      expect(result, hasLength(1));
      expect(result[0].stableId, 'setstate_scope');
      expect(result[0].detail, contains('[Correlated]'));
      expect(result[0].detail, contains('45 builds/sec'));
    });

    test('falls back to rebuild_activity weak match', () {
      final issues = [
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.confirmed,
          title: 'High Rebuild Activity: 30 builds/sec',
        ),
        makeIssue(
          stableId: 'setstate_scope',
          widgetName: 'SomePage',
          confidence: IssueConfidence.possible,
          detail: 'SomePage has wide setState.',
        ),
      ];

      final result = correlator.correlate(issues);
      expect(result, hasLength(1));
      expect(result[0].stableId, 'setstate_scope');
      expect(result[0].detail, contains('[Correlated]'));
      expect(result[0].detail, contains('30 builds/sec'));
    });

    test('upgrades confidence to likely when setState was possible', () {
      final issues = [
        makeIssue(
          stableId: 'rebuild_activity',
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'setstate_scope',
          widgetName: 'W',
          confidence: IssueConfidence.possible,
        ),
      ];

      final result = correlator.correlate(issues);
      expect(result[0].confidence, IssueConfidence.likely);
    });

    test('preserves confirmed confidence', () {
      final issues = [
        makeIssue(
          stableId: 'rebuild_debug_W',
          widgetName: 'W',
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'setstate_scope',
          widgetName: 'W',
          confidence: IssueConfidence.confirmed,
        ),
      ];

      final result = correlator.correlate(issues);
      expect(result[0].confidence, IssueConfidence.confirmed);
    });
  });

  // ---------------------------------------------------------------------------
  // EscalateGpuCustomPainterRule (Rule 2)
  // ---------------------------------------------------------------------------

  group('EscalateGpuCustomPainterRule', () {
    test('escalates painter from possible to likely with raster_dominance', () {
      final issues = [
        makeIssue(
          stableId: 'raster_dominance',
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'always_repaint_painter',
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
          detail: '2 CustomPainter(s) return true.',
        ),
      ];

      final result = correlator.correlate(issues);
      expect(result, hasLength(2));

      final painter = result.firstWhere(
        (i) => i.stableId == 'always_repaint_painter',
      );
      expect(painter.confidence, IssueConfidence.likely);
      expect(painter.detail, contains('[Correlated]'));
      expect(painter.detail, contains('GPU raster pressure'));
    });

    test('does NOT escalate already-likely painter', () {
      final issues = [
        makeIssue(
          stableId: 'raster_dominance',
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'always_repaint_painter',
          category: IssueCategory.paint,
          confidence: IssueConfidence.likely,
          detail: 'Original detail.',
        ),
      ];

      final result = correlator.correlate(issues);
      final painter = result.firstWhere(
        (i) => i.stableId == 'always_repaint_painter',
      );
      expect(painter.confidence, IssueConfidence.likely);
      expect(painter.detail, isNot(contains('[Correlated]')));
    });
  });

  // ---------------------------------------------------------------------------
  // EscalateMemoryImageRule (Rule 3)
  // ---------------------------------------------------------------------------

  group('EscalateMemoryImageRule', () {
    test('escalates images from possible to likely with heap_growing', () {
      final issues = [
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
          detail: '5 Image widgets without resizing.',
        ),
      ];

      final result = correlator.correlate(issues);
      final images = result.firstWhere(
        (i) => i.stableId == 'uncached_images',
      );
      expect(images.confidence, IssueConfidence.likely);
      expect(images.detail, contains('[Correlated]'));
      expect(images.detail, contains('Heap growth'));
    });

    test('does NOT escalate already-confirmed uncached_images', () {
      final issues = [
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
          confidence: IssueConfidence.confirmed,
          detail: '5 Image widgets without resizing.',
        ),
      ];

      final result = correlator.correlate(issues);
      final images = result.firstWhere(
        (i) => i.stableId == 'uncached_images',
      );
      expect(images.confidence, IssueConfidence.confirmed);
      expect(images.detail, isNot(contains('[Correlated]')));
    });
  });

  // ---------------------------------------------------------------------------
  // DeduplicateRebuildRepaintRule (Rule 5)
  // ---------------------------------------------------------------------------

  group('DeduplicateRebuildRepaintRule', () {
    test('keeps higher confidence — rebuild wins', () {
      final issues = [
        makeIssue(
          stableId: 'rebuild_debug_ListView',
          widgetName: 'ListView',
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'repaint_debug_ListView',
          widgetName: 'ListView',
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
        ),
      ];

      final result = correlator.correlate(issues);
      expect(result, hasLength(1));
      expect(result[0].stableId, 'rebuild_debug_ListView');
      expect(result[0].confidence, IssueConfidence.likely);
    });

    test('rebuild wins on tie', () {
      final issues = [
        makeIssue(
          stableId: 'rebuild_debug_Foo',
          widgetName: 'Foo',
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
          stableId: 'repaint_debug_Foo',
          widgetName: 'Foo',
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
        ),
      ];

      final result = correlator.correlate(issues);
      expect(result, hasLength(1));
      expect(result[0].stableId, 'rebuild_debug_Foo');
    });
  });

  // ---------------------------------------------------------------------------
  // Rule ordering / interaction
  // ---------------------------------------------------------------------------

  group('rule ordering', () {
    test('all rules fire in sequence on combined input', () {
      final issues = [
        // Rule 4 target: suppress (possible, no paint issues initially)
        makeIssue(
          stableId: 'animated_builder_no_child',
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
        ),
        // Rule 1 targets: merge
        makeIssue(
          stableId: 'rebuild_debug_PageWidget',
          widgetName: 'PageWidget',
          confidence: IssueConfidence.confirmed,
          title: 'High Rebuild: 50/sec',
        ),
        makeIssue(
          stableId: 'setstate_scope',
          widgetName: 'PageWidget',
          confidence: IssueConfidence.possible,
          detail: 'PageWidget owns 70% of tree.',
        ),
        // Rule 2 targets: escalate
        makeIssue(
          stableId: 'raster_dominance',
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'always_repaint_painter',
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
        ),
        // Rule 3 targets: escalate
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
        ),
        // Rule 5 targets: deduplicate
        makeIssue(
          stableId: 'rebuild_debug_Text',
          widgetName: 'Text',
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'repaint_debug_Text',
          widgetName: 'Text',
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
        ),
      ];

      final result = correlator.correlate(issues);

      // Rule 4: animated_builder suppressed? NO — paint issue exists
      // (always_repaint_painter has category paint). So it's retained.
      // But wait — suppress runs FIRST, before escalate.
      // At the time suppress runs, always_repaint_painter IS present
      // with category paint. So animated_builder is NOT suppressed.
      expect(
        result.any((i) => i.stableId == 'animated_builder_no_child'),
        isTrue,
        reason: 'Rule 4: paint issues exist, so animated_builder retained',
      );

      // Rule 1: rebuild_debug_PageWidget merged into setstate_scope
      expect(
        result.any((i) => i.stableId == 'rebuild_debug_PageWidget'),
        isFalse,
        reason: 'Rule 1: rebuild merged into setstate_scope',
      );
      final merged = result.firstWhere((i) => i.stableId == 'setstate_scope');
      expect(merged.detail, contains('[Correlated]'));
      expect(merged.confidence, IssueConfidence.likely);

      // Rule 2: always_repaint_painter escalated
      final painter = result.firstWhere(
        (i) => i.stableId == 'always_repaint_painter',
      );
      expect(painter.confidence, IssueConfidence.likely);

      // Rule 3: uncached_images escalated
      final images = result.firstWhere(
        (i) => i.stableId == 'uncached_images',
      );
      expect(images.confidence, IssueConfidence.likely);

      // Rule 5: rebuild_debug_Text vs repaint_debug_Text — rebuild wins
      expect(
        result.any((i) => i.stableId == 'rebuild_debug_Text'),
        isTrue,
      );
      expect(
        result.any((i) => i.stableId == 'repaint_debug_Text'),
        isFalse,
      );

      // Total: animated_builder(1) + setstate_scope(1) + raster_dominance(1)
      // + always_repaint_painter(1) + heap_growing(1) + uncached_images(1)
      // + rebuild_debug_Text(1) = 7
      // Original 9 - 1 (merge) - 1 (dedup) = 7
      expect(result, hasLength(7));
    });

    test('merge removes rebuild before dedup sees it', () {
      // Input: rebuild_debug_X + repaint_debug_X + setstate_scope(widgetName:X)
      // Merge removes rebuild_debug_X → dedup doesn't see the overlap
      // → repaint_debug_X survives.
      final issues = [
        makeIssue(
          stableId: 'rebuild_debug_MyPage',
          widgetName: 'MyPage',
          confidence: IssueConfidence.confirmed,
          title: 'Rebuild: 40/sec',
        ),
        makeIssue(
          stableId: 'repaint_debug_MyPage',
          widgetName: 'MyPage',
          category: IssueCategory.paint,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'setstate_scope',
          widgetName: 'MyPage',
          confidence: IssueConfidence.possible,
        ),
      ];

      final result = correlator.correlate(issues);

      // Merge consumed rebuild_debug_MyPage into setstate_scope
      expect(
        result.any((i) => i.stableId == 'rebuild_debug_MyPage'),
        isFalse,
      );
      // setstate_scope now has [Correlated] evidence
      expect(
        result.any((i) => i.stableId == 'setstate_scope'),
        isTrue,
      );
      // repaint_debug_MyPage survives because no rebuild_debug_MyPage
      // remains for dedup to match against
      expect(
        result.any((i) => i.stableId == 'repaint_debug_MyPage'),
        isTrue,
      );

      expect(result, hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // Duplicate stableIds
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // CausalGraphRule (Rule 6) — integration with full pipeline
  // ---------------------------------------------------------------------------

  group('CausalGraphRule via full pipeline', () {
    test('causal graph annotates after 5 existing rules', () {
      final issues = [
        makeIssue(
          stableId: 'setstate_scope',
          widgetName: 'MyPage',
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
          stableId: 'rebuild_debug_MyPage',
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'heavy_compute',
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = correlator.correlate(issues);

      // Rule 2 (MergeRebuildSetState) merges rebuild into setstate_scope.
      // Rule 6 (CausalGraph) chains setstate_scope → heavy_compute.
      expect(result.any((i) => i.stableId == 'rebuild_debug_MyPage'), isFalse,
          reason: 'Merge rule should absorb rebuild');

      final setState = result.firstWhere((i) => i.stableId == 'setstate_scope');
      expect(setState.downstreamIds, ['heavy_compute']);
      expect(setState.detail, contains('[Correlated]'));

      final heavyCompute =
          result.firstWhere((i) => i.stableId == 'heavy_compute');
      expect(heavyCompute.rootCauseIds, ['setstate_scope']);
    });

    test('existing rules still work unchanged with causal graph', () {
      // Verify the 5 existing rules are not broken by the 6th.
      final issues = [
        makeIssue(
          stableId: 'always_repaint_painter',
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
          stableId: 'raster_dominance',
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = correlator.correlate(issues);

      // Rule 3 escalates painter confidence to likely.
      final painter =
          result.firstWhere((i) => i.stableId == 'always_repaint_painter');
      expect(painter.confidence, IssueConfidence.likely);

      // Rule 6 chains painter → raster_dominance.
      expect(painter.downstreamIds, ['raster_dominance']);

      final raster = result.firstWhere((i) => i.stableId == 'raster_dominance');
      expect(raster.rootCauseIds, ['always_repaint_painter']);
    });

    test(
        'multi-parent end-to-end: 3-cause memory fan-in flows through '
        'correlator and surfaces every parent on the downstream effect', () {
      // Smoke test the full v0.24.2 pipeline (correlator → multi-parent
      // apply() → resulting issues are renderable). The detector_correlator
      // path is the same one FloatingIssuesCard reads from, so this also
      // validates the visible-filter and parent-resolution wiring.
      final issues = [
        makeIssue(
          stableId: 'stream_resource_growth',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'excessive_keep_alive:foo',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.confirmed,
        ),
      ];
      final result = correlator.correlate(issues);

      final downstream = result.firstWhere((i) => i.stableId == 'heap_growing');
      expect(
        downstream.rootCauseIds,
        containsAll([
          'stream_resource_growth',
          'uncached_images',
          'excessive_keep_alive:foo',
        ]),
        reason:
            'Every co-firing cause must annotate the downstream effect via the full pipeline',
      );
      expect(downstream.rootCauseIds, hasLength(3));

      // Every parent owns the downstream in its downstreamIds (no
      // confidence suppression because confirmed > likely is the
      // expected escalation, not the other way around).
      for (final parentId in [
        'stream_resource_growth',
        'uncached_images',
        'excessive_keep_alive:foo',
      ]) {
        final parent = result.firstWhere((i) => i.stableId == parentId);
        expect(parent.downstreamIds, contains('heap_growing'),
            reason: '$parentId must list heap_growing as downstream');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // EscalateKeepAliveMemoryRule (v10.6)
  // ---------------------------------------------------------------------------

  group('EscalateKeepAliveMemoryRule', () {
    test('escalates keep-alive from possible to likely with heap_growing', () {
      final issues = [
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'excessive_keep_alive:0',
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
          detail: 'Route 0 uses AutomaticKeepAliveClientMixin.',
        ),
      ];

      final result = correlator.correlate(issues);
      final keepAlive = result.firstWhere(
        (i) => i.stableId == 'excessive_keep_alive:0',
      );
      expect(keepAlive.confidence, IssueConfidence.likely);
      expect(keepAlive.detail, contains('[Correlated]'));
      expect(keepAlive.detail, contains('Heap pressure'));
    });

    test('escalates keep-alive with heap_near_capacity', () {
      final issues = [
        makeIssue(
          stableId: 'heap_near_capacity',
          category: IssueCategory.memory,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'excessive_keep_alive:1',
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
          detail: 'Route 1 uses AutomaticKeepAliveClientMixin.',
        ),
      ];

      final result = correlator.correlate(issues);
      final keepAlive = result.firstWhere(
        (i) => i.stableId == 'excessive_keep_alive:1',
      );
      expect(keepAlive.confidence, IssueConfidence.likely);
      expect(keepAlive.detail, contains('[Correlated]'));
    });

    test('does NOT escalate when no heap pressure exists', () {
      final issues = [
        makeIssue(
          stableId: 'excessive_keep_alive:0',
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
          detail: 'Route 0 uses AutomaticKeepAliveClientMixin.',
        ),
        makeIssue(
          stableId: 'slow_request',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
      ];

      final result = correlator.correlate(issues);
      final keepAlive = result.firstWhere(
        (i) => i.stableId == 'excessive_keep_alive:0',
      );
      expect(keepAlive.confidence, IssueConfidence.possible);
      expect(keepAlive.detail, isNot(contains('[Correlated]')));
    });

    test('does NOT escalate already-likely keep-alive', () {
      final issues = [
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'excessive_keep_alive:0',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
          detail: 'Already escalated.',
        ),
      ];

      final result = correlator.correlate(issues);
      final keepAlive = result.firstWhere(
        (i) => i.stableId == 'excessive_keep_alive:0',
      );
      expect(keepAlive.confidence, IssueConfidence.likely);
      expect(keepAlive.detail, isNot(contains('[Correlated]')));
    });
  });

  // ---------------------------------------------------------------------------
  // EnrichRebuildRepaintBoundaryRule (v10.9)
  // ---------------------------------------------------------------------------

  group('EnrichRebuildRepaintBoundaryRule', () {
    test('annotates rebuild_activity when missing_repaint_boundary present',
        () {
      final issues = [
        makeIssue(
          stableId: 'missing_repaint_boundary',
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
          stableId: 'rebuild_activity',
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          detail: 'High rebuild rate: 60 builds/sec.',
        ),
      ];

      final result = correlator.correlate(issues);
      final rebuild = result.firstWhere(
        (i) => i.stableId == 'rebuild_activity',
      );
      expect(rebuild.detail, contains('[Correlated] Missing RepaintBoundary'));
      expect(rebuild.detail, contains('unnecessary repaints'));
      // Confidence should NOT change (informational only).
      expect(rebuild.confidence, IssueConfidence.confirmed);
    });

    test(
        'annotates rebuild_debug_MyWidget when missing_repaint_boundary present',
        () {
      final issues = [
        makeIssue(
          stableId: 'missing_repaint_boundary',
          category: IssueCategory.paint,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'rebuild_debug_MyWidget',
          category: IssueCategory.build,
          confidence: IssueConfidence.likely,
          detail: 'MyWidget: 40 rebuilds/sec.',
        ),
      ];

      final result = correlator.correlate(issues);
      final rebuild = result.firstWhere(
        (i) => i.stableId == 'rebuild_debug_MyWidget',
      );
      expect(rebuild.detail, contains('[Correlated] Missing RepaintBoundary'));
      // Confidence unchanged.
      expect(rebuild.confidence, IssueConfidence.likely);
    });

    test('does NOT annotate rebuilds when no missing_repaint_boundary', () {
      final issues = [
        makeIssue(
          stableId: 'rebuild_activity',
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          detail: 'High rebuild rate.',
        ),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
          confidence: IssueConfidence.likely,
        ),
      ];

      final result = correlator.correlate(issues);
      final rebuild = result.firstWhere(
        (i) => i.stableId == 'rebuild_activity',
      );
      expect(rebuild.detail, isNot(contains('[Correlated]')));
      expect(rebuild.confidence, IssueConfidence.confirmed);
    });

    test('confidence does NOT change (informational only)', () {
      final issues = [
        makeIssue(
          stableId: 'missing_repaint_boundary',
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
        ),
        makeIssue(
          stableId: 'rebuild_activity',
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          detail: 'Low rebuild rate.',
        ),
      ];

      final result = correlator.correlate(issues);
      final rebuild = result.firstWhere(
        (i) => i.stableId == 'rebuild_activity',
      );
      expect(rebuild.confidence, IssueConfidence.possible);
      expect(rebuild.detail, contains('[Correlated] Missing RepaintBoundary'));
    });
  });

  // ---------------------------------------------------------------------------
  // Duplicate stableIds
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // EscalateStructuralWithJankRule (v0.10.8)
  // ---------------------------------------------------------------------------

  group('EscalateStructuralWithJankRule', () {
    test('escalates non_lazy_list from possible to likely with sustained_jank',
        () {
      final issues = [
        makeIssue(
          stableId: 'sustained_jank',
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'non_lazy_list',
          category: IssueCategory.layout,
          confidence: IssueConfidence.possible,
          detail: 'Non-lazy list detected.',
        ),
      ];

      final result = correlator.correlate(issues);
      final nonLazy = result.firstWhere(
        (i) => i.stableId == 'non_lazy_list',
      );
      expect(nonLazy.confidence, IssueConfidence.likely);
      expect(nonLazy.confidenceReason, isNotNull);
      expect(nonLazy.confidenceReason, contains('jank'));
      expect(nonLazy.detail, contains('[Correlated]'));
    });

    test('does NOT escalate already-likely non_lazy_list', () {
      final issues = [
        makeIssue(
          stableId: 'sustained_jank',
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'non_lazy_list',
          category: IssueCategory.layout,
          confidence: IssueConfidence.likely,
          detail: 'Already likely.',
        ),
      ];

      final result = correlator.correlate(issues);
      final nonLazy = result.firstWhere(
        (i) => i.stableId == 'non_lazy_list',
      );
      expect(nonLazy.confidence, IssueConfidence.likely);
      expect(nonLazy.detail, isNot(contains('[Correlated]')));
    });

    test('no jank present — no change', () {
      final issues = [
        makeIssue(
          stableId: 'non_lazy_list',
          category: IssueCategory.layout,
          confidence: IssueConfidence.possible,
          detail: 'Non-lazy list detected.',
        ),
        makeIssue(
          stableId: 'slow_request',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
      ];

      final result = correlator.correlate(issues);
      final nonLazy = result.firstWhere(
        (i) => i.stableId == 'non_lazy_list',
      );
      expect(nonLazy.confidence, IssueConfidence.possible);
      expect(nonLazy.detail, isNot(contains('[Correlated]')));
    });

    test('also triggers with jank_detected', () {
      final issues = [
        makeIssue(
          stableId: 'jank_detected',
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
          confidence: IssueConfidence.possible,
          detail: 'Layout bottleneck.',
        ),
      ];

      final result = correlator.correlate(issues);
      final layout = result.firstWhere(
        (i) => i.stableId == 'layout_bottleneck',
      );
      expect(layout.confidence, IssueConfidence.likely);
      expect(layout.detail, contains('[Correlated]'));
    });

    test('escalates sliver stableIds with sustained_jank', () {
      // Verify all new sliver IDs are covered by the rule.
      const sliverIds = [
        'non_lazy_sliver_list',
        'non_lazy_sliver_grid',
        'sliver_to_box_adapter_large',
        'sliver_fill_remaining_scrollable',
        'sliver_to_box_adapter_shrinkwrap',
      ];

      for (final sliverId in sliverIds) {
        final issues = [
          makeIssue(
            stableId: 'sustained_jank',
            category: IssueCategory.build,
            confidence: IssueConfidence.confirmed,
          ),
          makeIssue(
            stableId: sliverId,
            category: IssueCategory.layout,
            confidence: IssueConfidence.possible,
            detail: 'Sliver anti-pattern.',
          ),
        ];

        final result = correlator.correlate(issues);
        final sliver = result.firstWhere((i) => i.stableId == sliverId);
        expect(sliver.confidence, IssueConfidence.likely,
            reason: '$sliverId should be escalated with jank');
        expect(sliver.detail, contains('[Correlated]'),
            reason: '$sliverId detail should have [Correlated] tag');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // EscalateStructuralWithRebuildRule (v0.10.8)
  // ---------------------------------------------------------------------------

  group('EscalateStructuralWithRebuildRule', () {
    test(
        'escalates animated_builder_no_child from possible to likely with rebuild_activity',
        () {
      // Paint issue keeps animated_builder alive past SuppressAnimatedBuilderRule.
      final issues = [
        makeIssue(
          stableId: 'rebuild_activity',
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'animated_builder_no_child',
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          detail: 'AnimatedBuilder without child.',
        ),
        makeIssue(
          stableId: 'excessive_repaint',
          category: IssueCategory.paint,
          confidence: IssueConfidence.confirmed,
        ),
      ];

      final result = correlator.correlate(issues);
      final animBuilder = result.firstWhere(
        (i) => i.stableId == 'animated_builder_no_child',
      );
      expect(animBuilder.confidence, IssueConfidence.likely);
      expect(animBuilder.confidenceReason, isNotNull);
      expect(animBuilder.confidenceReason, contains('rebuild'));
      expect(animBuilder.detail, contains('[Correlated]'));
    });

    test('no rebuild evidence — suppressed by SuppressAnimatedBuilderRule', () {
      // Without paint issues AND without rebuild evidence, suppress rule
      // removes animated_builder before escalation can fire.
      final issues = [
        makeIssue(
          stableId: 'animated_builder_no_child',
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          detail: 'AnimatedBuilder without child.',
        ),
        makeIssue(
          stableId: 'slow_request',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
      ];

      final result = correlator.correlate(issues);
      expect(
        result.any((i) => i.stableId == 'animated_builder_no_child'),
        isFalse,
        reason:
            'SuppressAnimatedBuilderRule removes possible animated_builder when no paint issues exist',
      );
    });

    test(
        'no rebuild evidence with paint issues present — animated_builder survives but not escalated',
        () {
      final issues = [
        makeIssue(
          stableId: 'animated_builder_no_child',
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          detail: 'AnimatedBuilder without child.',
        ),
        makeIssue(
          stableId: 'excessive_repaint',
          category: IssueCategory.paint,
          confidence: IssueConfidence.confirmed,
        ),
      ];

      final result = correlator.correlate(issues);
      // Paint issues exist → SuppressAnimatedBuilderRule does NOT suppress.
      // No rebuild evidence → EscalateStructuralWithRebuildRule does NOT escalate.
      final animBuilder = result.firstWhere(
        (i) => i.stableId == 'animated_builder_no_child',
      );
      expect(animBuilder.confidence, IssueConfidence.possible);
      expect(animBuilder.detail, isNot(contains('[Correlated]')));
    });

    test('also triggers with rebuild_debug_ prefix', () {
      final issues = [
        makeIssue(
          stableId: 'rebuild_debug_MyWidget',
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'setstate_scope',
          widgetName: 'OtherWidget',
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          detail: 'Wide setState scope.',
        ),
      ];

      final result = correlator.correlate(issues);
      // MergeRebuildSetStateRule runs first — it looks for rebuild_debug_ matching
      // widgetName or falls back to rebuild_activity. rebuild_debug_MyWidget won't
      // match OtherWidget and it's not rebuild_activity, so no merge.
      // EscalateStructuralWithRebuildRule sees rebuild_debug_ prefix → escalates.
      final setStateScopeIssues =
          result.where((i) => i.stableId == 'setstate_scope').toList();
      expect(setStateScopeIssues, hasLength(1));
      expect(setStateScopeIssues[0].confidence, IssueConfidence.likely);
      expect(setStateScopeIssues[0].detail, contains('[Correlated]'));
    });
  });

  // ---------------------------------------------------------------------------
  // Existing escalation rules set confidenceReason (3b.6 verification)
  // ---------------------------------------------------------------------------

  group('Existing escalation rules set confidenceReason', () {
    test('EscalateGpuCustomPainterRule sets confidenceReason', () {
      final issues = [
        makeIssue(
          stableId: 'raster_dominance',
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
        ),
        makeIssue(
          stableId: 'always_repaint_painter',
          category: IssueCategory.paint,
          confidence: IssueConfidence.possible,
          detail: 'CustomPainter returns true.',
        ),
      ];

      final result = correlator.correlate(issues);
      final painter = result.firstWhere(
        (i) => i.stableId == 'always_repaint_painter',
      );
      expect(painter.confidence, IssueConfidence.likely);
      expect(painter.confidenceReason, isNotNull);
      expect(painter.confidenceReason, contains('GPU raster pressure'));
    });

    test('EscalateMemoryImageRule sets confidenceReason', () {
      final issues = [
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'uncached_images',
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
          detail: 'Images without resizing.',
        ),
      ];

      final result = correlator.correlate(issues);
      final images = result.firstWhere(
        (i) => i.stableId == 'uncached_images',
      );
      expect(images.confidence, IssueConfidence.likely);
      expect(images.confidenceReason, isNotNull);
      expect(images.confidenceReason, contains('heap growth'));
    });

    test('EscalateKeepAliveMemoryRule sets confidenceReason', () {
      final issues = [
        makeIssue(
          stableId: 'heap_growing',
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
        ),
        makeIssue(
          stableId: 'excessive_keep_alive:0',
          category: IssueCategory.memory,
          confidence: IssueConfidence.possible,
          detail: 'Route 0 uses keep-alive.',
        ),
      ];

      final result = correlator.correlate(issues);
      final keepAlive = result.firstWhere(
        (i) => i.stableId == 'excessive_keep_alive:0',
      );
      expect(keepAlive.confidence, IssueConfidence.likely);
      expect(keepAlive.confidenceReason, isNotNull);
      expect(keepAlive.confidenceReason, contains('heap pressure'));
    });
  });

  // ---------------------------------------------------------------------------
  // Duplicate stableIds (existing group continues below)
  // ---------------------------------------------------------------------------

  group('duplicate stableIds', () {
    test('deterministic output when duplicate stableIds exist', () {
      final issues = [
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
          confidence: IssueConfidence.likely,
          detail: 'First layout bottleneck.',
        ),
        makeIssue(
          stableId: 'layout_bottleneck',
          category: IssueCategory.layout,
          confidence: IssueConfidence.possible,
          detail: 'Second layout bottleneck.',
        ),
        makeIssue(
          stableId: 'slow_request',
          category: IssueCategory.network,
          confidence: IssueConfidence.confirmed,
        ),
      ];

      // Run twice to verify deterministic output.
      final result1 = correlator.correlate(issues);
      final result2 = correlator.correlate(issues);

      // No crash, all issues preserved (no rule targets these stableIds).
      expect(result1, hasLength(3));
      expect(result2, hasLength(3));

      // Output order and content are identical across runs.
      for (var i = 0; i < result1.length; i++) {
        expect(result1[i].stableId, result2[i].stableId);
        expect(result1[i].confidence, result2[i].confidence);
        expect(result1[i].detail, result2[i].detail);
      }
    });
  });
}
