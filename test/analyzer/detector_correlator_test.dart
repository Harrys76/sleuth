import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/analyzer/detector_correlator.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

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
      expect(heavyCompute.rootCauseId, 'setstate_scope');
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
      expect(raster.rootCauseId, 'always_repaint_painter');
    });
  });

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
