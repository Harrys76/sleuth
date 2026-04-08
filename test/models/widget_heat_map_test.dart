import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_heat_map_entry.dart';

PerformanceIssue _issue({
  required String widgetName,
  required String stableId,
  IssueSeverity severity = IssueSeverity.warning,
  int rankingScore = 200,
}) =>
    PerformanceIssue(
      severity: severity,
      category: IssueCategory.build,
      confidence: IssueConfidence.possible,
      title: 'test',
      detail: '',
      fixHint: '',
      widgetName: widgetName,
      stableId: stableId,
      rankingScore: rankingScore,
    );

void main() {
  group('buildWidgetHeatMap', () {
    test('aggregates issues by widgetName', () {
      final issues = [
        _issue(
            widgetName: 'MyProductCard',
            stableId: 'rebuild_debug_MyProductCard'),
        _issue(widgetName: 'MyProductCard', stableId: 'uncached_images'),
        _issue(widgetName: 'MyProductCard', stableId: 'layout_bottleneck'),
      ];
      final heatMap = buildWidgetHeatMap(issues);
      expect(heatMap, hasLength(1));
      expect(heatMap.first.widgetName, 'MyProductCard');
      expect(heatMap.first.issueCount, 3);
      expect(heatMap.first.totalRankingScore, 600); // 200 * 3
      expect(heatMap.first.detectorStableIds, hasLength(3));
    });

    test('filters out framework widgets', () {
      final issues = [
        _issue(widgetName: 'Column', stableId: 'layout_bottleneck'),
        _issue(widgetName: 'Row', stableId: 'layout_bottleneck'),
        _issue(widgetName: 'Scaffold', stableId: 'layout_bottleneck'),
        _issue(widgetName: 'ListView', stableId: 'layout_bottleneck'),
        _issue(widgetName: 'AppBar', stableId: 'layout_bottleneck'),
        _issue(widgetName: 'ElevatedButton', stableId: 'layout_bottleneck'),
        _issue(widgetName: 'MyWidget', stableId: 'rebuild_debug_MyWidget'),
      ];
      final heatMap = buildWidgetHeatMap(issues);
      expect(heatMap, hasLength(1));
      expect(heatMap.first.widgetName, 'MyWidget');
    });

    test('respects maxEntries', () {
      final issues = [
        _issue(widgetName: 'WidgetA', stableId: 'a', rankingScore: 300),
        _issue(widgetName: 'WidgetB', stableId: 'b', rankingScore: 200),
        _issue(widgetName: 'WidgetC', stableId: 'c', rankingScore: 100),
      ];
      final heatMap = buildWidgetHeatMap(issues, maxEntries: 2);
      expect(heatMap, hasLength(2));
      expect(heatMap[0].widgetName, 'WidgetA'); // highest score first
      expect(heatMap[1].widgetName, 'WidgetB');
    });

    test('sorts by total ranking score descending', () {
      final issues = [
        _issue(widgetName: 'Low', stableId: 'a', rankingScore: 100),
        _issue(widgetName: 'High', stableId: 'b', rankingScore: 300),
        _issue(widgetName: 'High', stableId: 'c', rankingScore: 300),
      ];
      final heatMap = buildWidgetHeatMap(issues);
      expect(heatMap.first.widgetName, 'High');
      expect(heatMap.first.totalRankingScore, 600);
    });

    test('tracks worst severity per widget', () {
      final issues = [
        _issue(
          widgetName: 'MyWidget',
          stableId: 'a',
          severity: IssueSeverity.warning,
        ),
        _issue(
          widgetName: 'MyWidget',
          stableId: 'b',
          severity: IssueSeverity.critical,
        ),
      ];
      final heatMap = buildWidgetHeatMap(issues);
      expect(heatMap.first.worstSeverity, IssueSeverity.critical);
    });

    test('skips issues without widgetName', () {
      final issues = [
        PerformanceIssue(
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          title: 'no widget',
          detail: '',
          fixHint: '',
          stableId: 'orphan',
          rankingScore: 200,
        ),
        _issue(widgetName: 'Named', stableId: 'x'),
      ];
      final heatMap = buildWidgetHeatMap(issues);
      expect(heatMap, hasLength(1));
      expect(heatMap.first.widgetName, 'Named');
    });

    test('empty issue list returns empty heat map', () {
      expect(buildWidgetHeatMap([]), isEmpty);
    });

    test('deduplicates stableIds within a widget', () {
      final issues = [
        _issue(widgetName: 'W', stableId: 'same_id'),
        _issue(widgetName: 'W', stableId: 'same_id'),
      ];
      final heatMap = buildWidgetHeatMap(issues);
      expect(heatMap.first.detectorStableIds, ['same_id']);
      expect(heatMap.first.issueCount, 2);
    });
  });

  group('WidgetHeatMapEntry serialization', () {
    test('toJson/fromJson round-trip', () {
      const entry = WidgetHeatMapEntry(
        widgetName: 'MyCard',
        issueCount: 3,
        totalRankingScore: 450,
        detectorStableIds: ['rebuild_debug_MyCard', 'uncached_images'],
        worstSeverity: IssueSeverity.critical,
      );
      final json = entry.toJson();
      final restored = WidgetHeatMapEntry.fromJson(json);
      expect(restored.widgetName, 'MyCard');
      expect(restored.issueCount, 3);
      expect(restored.totalRankingScore, 450);
      expect(restored.detectorStableIds, hasLength(2));
      expect(restored.worstSeverity, IssueSeverity.critical);
    });
  });
}
