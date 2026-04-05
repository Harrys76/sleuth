import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/utils/issue_explanation_builder.dart';

void main() {
  group('IssueExplanationBuilder', () {
    test('returns null for null stableId', () {
      expect(IssueExplanationBuilder.explain(null), isNull);
    });

    test('returns null for unknown stableId', () {
      expect(IssueExplanationBuilder.explain('unknown_detector'), isNull);
    });

    test('returns explanation for exact stableId', () {
      final result = IssueExplanationBuilder.explain('heap_near_capacity');
      expect(result, isNotNull);
      expect(result!.whatItIs, contains('80%'));
      expect(result.readingTheData, isNotNull);
      expect(result.readingTheData, contains('80%'));
      expect(result.whyItMatters, contains('GC'));
      expect(result.howToFix, contains('cacheWidth'));
    });

    test('strips colon suffix for keep_alive', () {
      final result = IssueExplanationBuilder.explain('excessive_keep_alive:3');
      expect(result, isNotNull);
      expect(result!.whatItIs, contains('KeepAlive'));
    });

    test('strips colon suffix for global_keys', () {
      final result = IssueExplanationBuilder.explain('excessive_global_keys:0');
      expect(result, isNotNull);
      expect(result!.whatItIs, contains('GlobalKey'));
    });

    test('strips dynamic suffix for rebuild_debug', () {
      final result = IssueExplanationBuilder.explain('rebuild_debug_MyWidget');
      expect(result, isNotNull);
      expect(result!.whatItIs, contains('specific widget type'));
    });

    test('strips dynamic suffix for repaint_debug', () {
      final result = IssueExplanationBuilder.explain('repaint_debug_MyWidget');
      expect(result, isNotNull);
      expect(result!.whatItIs, contains('specific widget type'));
    });

    test('all explanations have non-empty fields', () {
      const stableIds = [
        'sustained_jank',
        'jank_detected',
        'raster_cache_thrashing',
        'raster_cache_growing',
        'shader_compilation',
        'heavy_compute',
        'gc_pressure',
        'heap_growing',
        'heap_near_capacity',
        'native_memory_growing',
        'rebuild_activity',
        'rebuild_debug_X',
        'stateful_density',
        'excessive_repaint',
        'repaint_debug_X',
        'excessive_repaint_debug',
        'raster_dominance',
        'expensive_gpu_nodes',
        'setstate_scope',
        'shallow_rebuild_risk',
        'non_lazy_list',
        'uncached_images',
        'excessive_global_keys:0',
        'nested_scroll',
        'nested_scroll_same_axis',
        'opacity_zero',
        'layout_bottleneck',
        'always_repaint_painter',
        'frequent_repaint_painter',
        'excessive_keep_alive:1',
        'animated_builder_no_child',
        'multiple_custom_fonts',
        'missing_repaint_boundary',
        'slow_request',
        'large_response',
        'request_frequency',
        'platform_channel_traffic',
      ];

      for (final id in stableIds) {
        final result = IssueExplanationBuilder.explain(id);
        expect(result, isNotNull, reason: 'Missing explanation for $id');
        expect(result!.whatItIs, isNotEmpty, reason: 'Empty whatItIs for $id');
        expect(result.whyItMatters, isNotEmpty,
            reason: 'Empty whyItMatters for $id');
        expect(result.howToFix, isNotEmpty, reason: 'Empty howToFix for $id');
      }
    });

    test('whenToIgnore is null for issues that should never be ignored', () {
      // heavy_compute and nested_scroll_same_axis have no false-positive case
      final heavyCompute = IssueExplanationBuilder.explain('heavy_compute');
      expect(heavyCompute!.whenToIgnore, isNull);

      final nestedSameAxis =
          IssueExplanationBuilder.explain('nested_scroll_same_axis');
      expect(nestedSameAxis!.whenToIgnore, isNull);
    });

    test('whenToIgnore is non-null for issues with false-positive guidance',
        () {
      final heapNear = IssueExplanationBuilder.explain('heap_near_capacity');
      expect(heapNear!.whenToIgnore, isNotNull);
      expect(heapNear.whenToIgnore, isNotEmpty);

      final nonLazy = IssueExplanationBuilder.explain('non_lazy_list');
      expect(nonLazy!.whenToIgnore, isNotNull);
    });

    test('displayName is non-empty for all entries', () {
      for (final entry in IssueExplanationBuilder.allExplanations.entries) {
        expect(entry.value.displayName, isNotEmpty,
            reason: 'Empty displayName for ${entry.key}');
      }
    });

    test('category is set for all entries', () {
      for (final entry in IssueExplanationBuilder.allExplanations.entries) {
        expect(IssueCategory.values, contains(entry.value.category),
            reason: 'Invalid category for ${entry.key}');
      }
    });

    test('allExplanations returns all 37 entries', () {
      expect(IssueExplanationBuilder.allExplanations.length, 37);
    });

    test('groupedEntries returns 8 groups', () {
      final groups = IssueExplanationBuilder.groupedEntries;
      expect(groups.length, 8);

      // Verify rendering pipeline order
      expect(groups[0].category, IssueCategory.build);
      expect(groups[1].category, IssueCategory.layout);
      expect(groups[2].category, IssueCategory.paint);
      expect(groups[3].category, IssueCategory.raster);
      expect(groups[4].category, IssueCategory.memory);
      expect(groups[5].category, IssueCategory.network);
      expect(groups[6].category, IssueCategory.font);
      expect(groups[7].category, IssueCategory.channel);
    });

    test('groupedEntries contains all entries', () {
      final groups = IssueExplanationBuilder.groupedEntries;
      final totalEntries =
          groups.fold<int>(0, (sum, g) => sum + g.entries.length);
      expect(totalEntries, 37);
    });

    test('readingTheData is non-null for runtime detector entries', () {
      const runtimeIds = [
        'sustained_jank',
        'jank_detected',
        'raster_cache_thrashing',
        'raster_cache_growing',
        'shader_compilation',
        'heavy_compute',
        'gc_pressure',
        'heap_growing',
        'heap_near_capacity',
        'native_memory_growing',
        'rebuild_activity',
        'rebuild_debug_X',
        'excessive_repaint',
        'repaint_debug_X',
        'excessive_repaint_debug',
        'raster_dominance',
        'expensive_gpu_nodes',
        'slow_request',
        'large_response',
        'request_frequency',
        'platform_channel_traffic',
      ];

      for (final id in runtimeIds) {
        final result = IssueExplanationBuilder.explain(id);
        expect(result, isNotNull, reason: 'Missing explanation for $id');
        expect(result!.readingTheData, isNotNull,
            reason: 'Missing readingTheData for $id');
        expect(result.readingTheData, isNotEmpty,
            reason: 'Empty readingTheData for $id');
      }
    });

    test('readingTheData is null for structural detection entries', () {
      const structuralIds = [
        'stateful_density',
        'setstate_scope',
        'shallow_rebuild_risk',
        'non_lazy_list',
        'uncached_images',
        'excessive_global_keys:0',
        'nested_scroll',
        'nested_scroll_same_axis',
        'opacity_zero',
        'layout_bottleneck',
        'always_repaint_painter',
        'frequent_repaint_painter',
        'missing_repaint_boundary',
        'excessive_keep_alive:1',
        'animated_builder_no_child',
        'multiple_custom_fonts',
      ];

      for (final id in structuralIds) {
        final result = IssueExplanationBuilder.explain(id);
        expect(result, isNotNull, reason: 'Missing explanation for $id');
        expect(result!.readingTheData, isNull,
            reason: 'Unexpected readingTheData for $id');
      }
    });
  });
}
