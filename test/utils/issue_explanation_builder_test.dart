// IDE analyzer false-positive: dart:core RegExp uses @Deprecated.implement
// (fires only on subclassing). Remove when analyzer-server recognizes the
// implement-only kind.
// ignore_for_file: deprecated_member_use
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

    test('strips colon suffix for high_frequency_same_path', () {
      final result =
          IssueExplanationBuilder.explain('high_frequency_same_path:abcdef');
      expect(result, isNotNull);
      expect(result!.whatItIs, contains('same endpoint'));
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
        'http_error_spike',
        'platform_channel_traffic',
        // v11.20: 8 new entries
        'high_frequency_same_path:testfp',
        'wrap_layout_bottleneck',
        'sliver_to_box_adapter_large',
        'sliver_fill_remaining_scrollable',
        'sliver_to_box_adapter_shrinkwrap',
        'global_key_recreation',
        'excessive_repaint_boundary',
        'runtime_font_loading',
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

    test('allExplanations returns all 50 entries', () {
      expect(IssueExplanationBuilder.allExplanations.length, 50);
    });

    test('groupedEntries returns 9 groups', () {
      final groups = IssueExplanationBuilder.groupedEntries;
      expect(groups.length, 9);

      // Verify rendering pipeline order
      expect(groups[0].category, IssueCategory.build);
      expect(groups[1].category, IssueCategory.layout);
      expect(groups[2].category, IssueCategory.paint);
      expect(groups[3].category, IssueCategory.raster);
      expect(groups[4].category, IssueCategory.memory);
      expect(groups[5].category, IssueCategory.network);
      expect(groups[6].category, IssueCategory.font);
      expect(groups[7].category, IssueCategory.channel);
      expect(groups[8].category, IssueCategory.startup);
    });

    test('groupedEntries contains all entries', () {
      final groups = IssueExplanationBuilder.groupedEntries;
      final totalEntries =
          groups.fold<int>(0, (sum, g) => sum + g.entries.length);
      expect(totalEntries, 50);
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
        'http_error_spike',
        'platform_channel_traffic',
        'high_frequency_same_path:testfp',
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

    test('readingTheData is non-null for ALL entries', () {
      for (final entry in IssueExplanationBuilder.allExplanations.entries) {
        final result = IssueExplanationBuilder.explain(entry.key);
        expect(result, isNotNull,
            reason: 'Missing explanation for ${entry.key}');
        expect(result!.readingTheData, isNotNull,
            reason: 'Missing readingTheData for ${entry.key}');
        expect(result.readingTheData, isNotEmpty,
            reason: 'Empty readingTheData for ${entry.key}');
      }
    });

    // v11.23: Build-phase content enrichment
    test('heavy_compute howToFix contains Isolate.run', () {
      final result = IssueExplanationBuilder.explain('heavy_compute');
      expect(result!.howToFix, contains('Isolate.run'));
    });

    test('setstate_scope howToFix contains ValueListenableBuilder', () {
      final result = IssueExplanationBuilder.explain('setstate_scope');
      expect(result!.howToFix, contains('ValueListenableBuilder'));
    });

    test('animated_builder_no_child howToFix explains child caching', () {
      final result =
          IssueExplanationBuilder.explain('animated_builder_no_child');
      expect(result!.howToFix, contains('cached'));
    });

    // v11.24: Memory/image content enrichment
    test('gc_pressure mentions micro-stutters and const', () {
      final result = IssueExplanationBuilder.explain('gc_pressure');
      expect(result!.whyItMatters, contains('stutter'));
      expect(result.howToFix, contains('const'));
    });

    test('heap_growing howToFix mentions snapshot', () {
      final result = IssueExplanationBuilder.explain('heap_growing');
      expect(result!.howToFix, contains('snapshot'));
    });

    test('uncached_images howToFix mentions ResizeImage', () {
      final result = IssueExplanationBuilder.explain('uncached_images');
      expect(result!.howToFix, contains('ResizeImage'));
    });

    // v11.25: Paint/layout content enrichment
    test('excessive_repaint howToFix mentions island concept', () {
      final result = IssueExplanationBuilder.explain('excessive_repaint');
      expect(result!.howToFix, contains('island'));
    });

    test('layout_bottleneck howToFix mentions CrossAxisAlignment.stretch', () {
      final result = IssueExplanationBuilder.explain('layout_bottleneck');
      expect(result!.howToFix, contains('CrossAxisAlignment.stretch'));
    });

    test('opacity_zero howToFix mentions maintainSize', () {
      final result = IssueExplanationBuilder.explain('opacity_zero');
      expect(result!.howToFix, contains('maintainSize'));
    });

    // v11.26: Raster/network/scroll content enrichment
    test('shader_compilation mentions Impeller', () {
      final result = IssueExplanationBuilder.explain('shader_compilation');
      expect(result!.whatItIs, contains('Impeller'));
    });

    test('platform_channel_traffic howToFix mentions Pigeon', () {
      final result =
          IssueExplanationBuilder.explain('platform_channel_traffic');
      expect(result!.howToFix, contains('Pigeon'));
    });

    test('non_lazy_list howToFix mentions itemExtent', () {
      final result = IssueExplanationBuilder.explain('non_lazy_list');
      expect(result!.howToFix, contains('itemExtent'));
    });

    test('nested_scroll_same_axis howToFix mentions CustomScrollView', () {
      final result = IssueExplanationBuilder.explain('nested_scroll_same_axis');
      expect(result!.howToFix, contains('CustomScrollView'));
    });

    // v11.27: relatedIssues cross-references
    test('relatedIssues is non-null for entries with causal links', () {
      const expectedNonNull = [
        'setstate_scope',
        'uncached_images',
        'always_repaint_painter',
        'missing_repaint_boundary',
        'animated_builder_no_child',
        'non_lazy_list',
        'layout_bottleneck',
        'high_frequency_same_path',
        'rebuild_activity',
        'heavy_compute',
        'gc_pressure',
        'heap_growing',
        'sustained_jank',
        'jank_detected',
        'raster_dominance',
        'excessive_repaint',
        'excessive_keep_alive',
        'nested_scroll',
        'nested_scroll_same_axis',
        'stateful_density',
        'shallow_rebuild_risk',
        'frequent_repaint_painter',
        'opacity_zero',
        'request_frequency',
        'http_error_spike',
      ];

      for (final id in expectedNonNull) {
        final result = IssueExplanationBuilder.explain(id);
        expect(result, isNotNull, reason: 'Missing explanation for $id');
        expect(result!.relatedIssues, isNotNull,
            reason: 'Missing relatedIssues for $id');
        expect(result.relatedIssues, isNotEmpty,
            reason: 'Empty relatedIssues for $id');
      }
    });

    test('relatedIssues are bidirectional', () {
      final all = IssueExplanationBuilder.allExplanations;
      for (final entry in all.entries) {
        final related = entry.value.relatedIssues;
        if (related == null) continue;
        for (final relatedId in related) {
          final other = all[relatedId];
          expect(other, isNotNull,
              reason: '${entry.key} references non-existent entry $relatedId');
          expect(other!.relatedIssues, isNotNull,
              reason:
                  '$relatedId is referenced by ${entry.key} but has null relatedIssues');
          expect(other.relatedIssues!, contains(entry.key),
              reason:
                  '${entry.key} lists $relatedId but $relatedId does not list ${entry.key}');
        }
      }
    });

    test('all relatedIssues stableIds exist in explanations', () {
      final all = IssueExplanationBuilder.allExplanations;
      for (final entry in all.entries) {
        final related = entry.value.relatedIssues;
        if (related == null) continue;
        for (final relatedId in related) {
          expect(all.containsKey(relatedId), isTrue,
              reason:
                  '${entry.key} references $relatedId which is not in _explanations');
        }
      }
    });

    // ── v11.29: Content quality guardrail tests ──────────────────────────

    group('documentation quality', () {
      test('whatItIs has minimum word count (≥ 20 words) for all entries', () {
        for (final entry in IssueExplanationBuilder.allExplanations.entries) {
          final wordCount = entry.value.whatItIs.split(RegExp(r'\s+')).length;
          expect(wordCount, greaterThanOrEqualTo(20),
              reason:
                  '${entry.key} whatItIs has only $wordCount words (min 20)');
        }
      });

      test('whyItMatters has minimum word count (≥ 20 words) for all entries',
          () {
        for (final entry in IssueExplanationBuilder.allExplanations.entries) {
          final wordCount =
              entry.value.whyItMatters.split(RegExp(r'\s+')).length;
          expect(wordCount, greaterThanOrEqualTo(20),
              reason:
                  '${entry.key} whyItMatters has only $wordCount words (min 20)');
        }
      });

      test('howToFix has minimum word count (≥ 30 words) for all entries', () {
        for (final entry in IssueExplanationBuilder.allExplanations.entries) {
          final wordCount = entry.value.howToFix.split(RegExp(r'\s+')).length;
          expect(wordCount, greaterThanOrEqualTo(30),
              reason:
                  '${entry.key} howToFix has only $wordCount words (min 30)');
        }
      });

      test('at least 25 readingTheData entries contain metric threshold', () {
        final metricPattern = RegExp(r'\d+\s*(ms|%|/sec|KB|MB|GB|/min|×|px)',
            caseSensitive: false);
        var matchCount = 0;
        for (final entry in IssueExplanationBuilder.allExplanations.entries) {
          final rtd = entry.value.readingTheData;
          expect(rtd, isNotNull, reason: '${entry.key} missing readingTheData');
          if (metricPattern.hasMatch(rtd!)) matchCount++;
        }
        expect(matchCount, greaterThanOrEqualTo(25),
            reason: 'Only $matchCount entries have metric thresholds (min 25)');
      });

      test('readingTheData contains an analogy (Like pattern)', () {
        final analogyPattern = RegExp(r'Like [a-z]', caseSensitive: false);
        for (final entry in IssueExplanationBuilder.allExplanations.entries) {
          final rtd = entry.value.readingTheData;
          expect(rtd, isNotNull, reason: '${entry.key} missing readingTheData');
          expect(analogyPattern.hasMatch(rtd!), isTrue,
              reason: '${entry.key} readingTheData has no analogy');
        }
      });

      test('at least 10 entries have code examples in howToFix', () {
        var codeExampleCount = 0;
        // Code examples contain indentation patterns or keywords
        final codePattern = RegExp(
            r'(^\s{2,}[a-zA-Z]|Before.*:.*\n|After.*:.*\n|Widget build|ListView\.|Isolate\.run|RepaintBoundary\(|AnimatedBuilder\(|CustomScrollView\()',
            multiLine: true);
        for (final entry in IssueExplanationBuilder.allExplanations.entries) {
          if (codePattern.hasMatch(entry.value.howToFix)) {
            codeExampleCount++;
          }
        }
        expect(codeExampleCount, greaterThanOrEqualTo(10),
            reason:
                'Only $codeExampleCount entries have code examples (min 10)');
      });

      test('at least 5 entries reference DevTools', () {
        var devToolsCount = 0;
        for (final entry in IssueExplanationBuilder.allExplanations.entries) {
          final allText = '${entry.value.whatItIs} '
              '${entry.value.readingTheData ?? ''} '
              '${entry.value.whyItMatters} '
              '${entry.value.howToFix} '
              '${entry.value.whenToIgnore ?? ''}';
          if (allText.contains('DevTools')) {
            devToolsCount++;
          }
        }
        expect(devToolsCount, greaterThanOrEqualTo(5),
            reason: 'Only $devToolsCount entries reference DevTools (min 5)');
      });

      test('every detector stableId has an encyclopedia entry', () {
        // All known detector stableId base prefixes
        const detectorStableIds = [
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
          'rebuild_debug',
          'stateful_density',
          'excessive_repaint',
          'repaint_debug',
          'excessive_repaint_debug',
          'raster_dominance',
          'expensive_gpu_nodes',
          'setstate_scope',
          'shallow_rebuild_risk',
          'non_lazy_list',
          'uncached_images',
          'excessive_global_keys',
          'nested_scroll',
          'nested_scroll_same_axis',
          'opacity_zero',
          'layout_bottleneck',
          'always_repaint_painter',
          'frequent_repaint_painter',
          'excessive_keep_alive',
          'animated_builder_no_child',
          'multiple_custom_fonts',
          'missing_repaint_boundary',
          'slow_request',
          'large_response',
          'request_frequency',
          'http_error_spike',
          'platform_channel_traffic',
          'high_frequency_same_path',
          'wrap_layout_bottleneck',
          'sliver_to_box_adapter_large',
          'sliver_fill_remaining_scrollable',
          'sliver_to_box_adapter_shrinkwrap',
          'global_key_recreation',
          'excessive_repaint_boundary',
          'runtime_font_loading',
        ];

        for (final id in detectorStableIds) {
          expect(IssueExplanationBuilder.explain(id), isNotNull,
              reason: 'Detector stableId "$id" has no encyclopedia entry');
        }
      });

      test('no duplicate entries (each stableId appears once)', () {
        final all = IssueExplanationBuilder.allExplanations;
        // The map itself enforces uniqueness, but verify the count
        expect(all.length, 50);
        // Verify no two entries share the same displayName
        final names = all.values.map((e) => e.displayName).toList();
        expect(names.toSet().length, names.length,
            reason: 'Duplicate displayName found');
      });
    });
  });
}
