import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/analyzer/jank_relation.dart';
import 'package:sleuth/src/analyzer/render_pipeline_analyzer.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/frame_verdict.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

PerformanceIssue _issue(String stableId, IssueCategory category) =>
    PerformanceIssue(
      stableId: stableId,
      severity: IssueSeverity.warning,
      category: category,
      confidence: IssueConfidence.confirmed,
      title: stableId,
      detail: '',
      fixHint: '',
    );

final _rebuild = _issue('rebuild_activity', IssueCategory.build);
final _layout = _issue('layout_bottleneck', IssueCategory.layout);
final _paint = _issue('excessive_repaint', IssueCategory.paint);
final _raster = _issue('raster_dominance', IssueCategory.raster);
final _stall = _issue('event_loop_stall', IssueCategory.build);
final _memory = _issue('gc_pressure', IssueCategory.memory);
final _network = _issue('slow_request', IssueCategory.network);
final _jank = _issue('jank_detected', IssueCategory.build);
final _sustained = _issue('sustained_jank', IssueCategory.build);

final _all = [
  _rebuild,
  _layout,
  _paint,
  _raster,
  _stall,
  _memory,
  _network,
  _jank,
  _sustained,
];

void main() {
  group('relatedToPhase', () {
    test('each UI or raster phase takes its own category', () {
      expect(relatedToPhase(PipelinePhase.build, _all), [_rebuild, _stall]);
      expect(relatedToPhase(PipelinePhase.layout, _all), [_layout]);
      expect(relatedToPhase(PipelinePhase.paint, _all), [_paint]);
      expect(relatedToPhase(PipelinePhase.raster, _all), [_raster]);
    });

    test('a start delay takes event_loop_stall only', () {
      expect(relatedToPhase(PipelinePhase.schedulerDelay, _all), [_stall]);
    });

    test('a stall or an unknown phase takes nothing', () {
      expect(relatedToPhase(PipelinePhase.pipelineStall, _all), isEmpty);
      expect(relatedToPhase(PipelinePhase.unknown, _all), isEmpty);
    });

    test('jank symptoms are never a cause', () {
      for (final phase in PipelinePhase.values) {
        final related = relatedToPhase(phase, _all);
        expect(related, isNot(contains(_jank)), reason: '$phase');
        expect(related, isNot(contains(_sustained)), reason: '$phase');
      }
      expect(isJankSymptom(_jank), isTrue);
      expect(isJankSymptom(_sustained), isTrue);
      expect(isJankSymptom(_stall), isFalse);
    });
  });

  group('verdicts carry the phase filter', () {
    FrameStats frame({required int uiMs, required int rasterMs}) => FrameStats(
      frameNumber: 1,
      uiDuration: Duration(milliseconds: uiMs),
      rasterDuration: Duration(milliseconds: rasterMs),
      timestamp: DateTime(2026, 1, 1),
      frameBudgetMs: 16,
      frameBudgetUs: 16667,
    );

    test('a basic-tier verdict tags only build or raster issues', () {
      final analyzer = RenderPipelineAnalyzer();
      final build = analyzer.analyzeBasicMode(
        frameStats: frame(uiMs: 30, rasterMs: 10),
        relatedIssues: _all,
      );
      expect(build.suspectedPhase, PipelinePhase.build);
      expect(build.relatedIssues, [_rebuild, _stall]);

      final raster = analyzer.analyzeBasicMode(
        frameStats: frame(uiMs: 5, rasterMs: 30),
        relatedIssues: _all,
      );
      expect(raster.suspectedPhase, PipelinePhase.raster);
      expect(raster.relatedIssues, [_raster]);
    });

    test('the reason names a related issue of the phase', () {
      final verdict = RenderPipelineAnalyzer().analyzeFullMode(
        frameStats: frame(uiMs: 5, rasterMs: 30),
        timelineData: emptyTimelineData(),
        relatedIssues: [_jank, _memory, _raster],
      );
      expect(verdict.relatedIssues, [_raster]);
      expect(verdict.reason, contains('Related: raster_dominance'));
    });
  });
}
