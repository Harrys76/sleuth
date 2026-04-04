import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/models/frame_verdict.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/ranking/issue_ranker.dart';

void main() {
  const ranker = IssueRanker();

  PerformanceIssue makeIssue({
    IssueSeverity severity = IssueSeverity.warning,
    IssueCategory category = IssueCategory.build,
    IssueConfidence confidence = IssueConfidence.possible,
    String? stableId,
    String title = 'test issue',
  }) {
    return PerformanceIssue(
      severity: severity,
      category: category,
      confidence: confidence,
      title: title,
      detail: '',
      fixHint: '',
      stableId: stableId,
    );
  }

  group('IssueRanker', () {
    group('severity dominance', () {
      test('critical outranks warning regardless of other signals', () {
        // Worst-case critical: possible confidence, no jank, no recurrence
        final critical = makeIssue(
          severity: IssueSeverity.critical,
          confidence: IssueConfidence.possible,
          category: IssueCategory.font,
          stableId: 'critical_1',
        );

        // Best-case warning: confirmed confidence, matching jank, max recurrence
        final warning = makeIssue(
          severity: IssueSeverity.warning,
          confidence: IssueConfidence.confirmed,
          category: IssueCategory.build,
          stableId: 'warning_1',
        );

        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.build,
          recurrenceCounts: {'warning_1': 5},
        );

        final result = ranker.rank([warning, critical], context);
        expect(result.first.stableId, 'critical_1');

        // Verify scores: critical minimum > warning maximum
        final criticalScore = ranker.scoreOf(critical, context);
        final warningScore = ranker.scoreOf(warning, context);
        expect(criticalScore, greaterThan(warningScore));
        // critical: 3*100 + 1*8 + 1*5 + 0*2 = 313
        // warning: 2*100 + 3*8 + 3*5 + 5*2 = 249
        expect(criticalScore, 313);
        expect(warningScore, 249);
      });

      test('warning outranks ok regardless of other signals', () {
        final warning = makeIssue(
          severity: IssueSeverity.warning,
          confidence: IssueConfidence.possible,
          stableId: 'w',
        );
        final ok = makeIssue(
          severity: IssueSeverity.ok,
          confidence: IssueConfidence.confirmed,
          category: IssueCategory.build,
          stableId: 'o',
        );

        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.build,
          recurrenceCounts: {'o': 5},
        );

        final result = ranker.rank([ok, warning], context);
        expect(result.first.stableId, 'w');
      });
    });

    group('frame impact boost', () {
      test('build-category issue boosted when jank phase is build', () {
        final buildIssue = makeIssue(
          category: IssueCategory.build,
          stableId: 'build',
        );
        final memoryIssue = makeIssue(
          category: IssueCategory.memory,
          stableId: 'memory',
        );

        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.build,
        );

        final result = ranker.rank([memoryIssue, buildIssue], context);
        expect(result.first.stableId, 'build');
      });

      test('paint-category issue boosted when jank phase is paint', () {
        final paintIssue = makeIssue(
          category: IssueCategory.paint,
          stableId: 'paint',
        );
        final memoryIssue = makeIssue(
          category: IssueCategory.memory,
          stableId: 'memory',
        );

        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.paint,
        );

        final result = ranker.rank([memoryIssue, paintIssue], context);
        expect(result.first.stableId, 'paint');
      });

      test('layout-category boosted when jank phase is build', () {
        final layoutIssue = makeIssue(
          category: IssueCategory.layout,
          stableId: 'layout',
        );
        final rasterIssue = makeIssue(
          category: IssueCategory.raster,
          stableId: 'raster',
        );

        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.build,
        );

        final result = ranker.rank([rasterIssue, layoutIssue], context);
        expect(result.first.stableId, 'layout');
      });

      test('raster-category boosted when jank phase is raster', () {
        final rasterIssue = makeIssue(
          category: IssueCategory.raster,
          stableId: 'raster',
        );
        final buildIssue = makeIssue(
          category: IssueCategory.build,
          stableId: 'build',
        );

        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.raster,
        );

        final result = ranker.rank([buildIssue, rasterIssue], context);
        expect(result.first.stableId, 'raster');
      });

      test('no boost when no jank active', () {
        final buildIssue = makeIssue(
          category: IssueCategory.build,
          stableId: 'build',
        );
        final paintIssue = makeIssue(
          category: IssueCategory.paint,
          stableId: 'paint',
        );

        const context = IssueRankingContext(jankActive: false);

        // Both get frameImpact=0, so equal score → input order preserved
        final result = ranker.rank([paintIssue, buildIssue], context);
        expect(result.first.stableId, 'paint');
      });

      test('non-matching category gets partial boost during jank', () {
        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.build,
        );

        // memory category doesn't match build phase → partial boost (1)
        final memoryIssue = makeIssue(
          category: IssueCategory.memory,
          stableId: 'memory',
        );
        final score = ranker.scoreOf(memoryIssue, context);
        // 2*100 + 1*8 + 1*5 + 0*2 = 213
        expect(score, 213);
      });

      test('paint is UI-thread: boosted with build/layout/paint phase', () {
        final paintIssue = makeIssue(
          category: IssueCategory.paint,
          stableId: 'paint',
        );
        final rasterIssue = makeIssue(
          category: IssueCategory.raster,
          stableId: 'raster',
        );

        // Paint gets full boost (3) during build phase — it's UI-thread
        final buildCtx = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.build,
        );
        expect(
          ranker.rank([rasterIssue, paintIssue], buildCtx).first.stableId,
          'paint',
        );

        // Paint gets partial boost (1) during raster phase — not raster-thread
        final rasterCtx = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.raster,
        );
        expect(
          ranker.rank([paintIssue, rasterIssue], rasterCtx).first.stableId,
          'raster',
        );
      });

      test('raster-only: only raster category gets full boost', () {
        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.raster,
        );

        final rasterIssue = makeIssue(
          category: IssueCategory.raster,
          stableId: 'raster',
        );
        final paintIssue = makeIssue(
          category: IssueCategory.paint,
          stableId: 'paint',
        );
        final buildIssue = makeIssue(
          category: IssueCategory.build,
          stableId: 'build',
        );

        // raster gets 3, paint and build get 1
        final rasterScore = ranker.scoreOf(rasterIssue, context);
        final paintScore = ranker.scoreOf(paintIssue, context);
        final buildScore = ranker.scoreOf(buildIssue, context);
        expect(rasterScore, greaterThan(paintScore));
        expect(rasterScore, greaterThan(buildScore));
        expect(paintScore, buildScore); // both partial
      });

      test('phase-agnostic categories get partial boost during jank', () {
        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.build,
        );

        for (final cat in [
          IssueCategory.memory,
          IssueCategory.channel,
          IssueCategory.font,
        ]) {
          final issue = makeIssue(category: cat);
          final score = ranker.scoreOf(issue, context);
          // frameImpact = 1 (partial), so +8
          expect(score, 213, reason: '$cat should get partial boost');
        }
      });
    });

    group('confidence', () {
      test('confirmed outranks likely at same severity', () {
        final confirmed = makeIssue(
          confidence: IssueConfidence.confirmed,
          stableId: 'confirmed',
        );
        final likely = makeIssue(
          confidence: IssueConfidence.likely,
          stableId: 'likely',
        );

        const context = IssueRankingContext();
        final result = ranker.rank([likely, confirmed], context);
        expect(result.first.stableId, 'confirmed');
      });

      test('likely outranks possible at same severity', () {
        final likely = makeIssue(
          confidence: IssueConfidence.likely,
          stableId: 'likely',
        );
        final possible = makeIssue(
          confidence: IssueConfidence.possible,
          stableId: 'possible',
        );

        const context = IssueRankingContext();
        final result = ranker.rank([possible, likely], context);
        expect(result.first.stableId, 'likely');
      });
    });

    group('recurrence', () {
      test('recurring issue outranks first-time at same severity+confidence',
          () {
        final recurring = makeIssue(stableId: 'recurring');
        final fresh = makeIssue(stableId: 'fresh');

        final context = IssueRankingContext(
          recurrenceCounts: {'recurring': 3},
        );

        final result = ranker.rank([fresh, recurring], context);
        expect(result.first.stableId, 'recurring');
      });

      test('recurrence capped at 5', () {
        final issue = makeIssue(stableId: 'high_recurrence');

        final context = IssueRankingContext(
          recurrenceCounts: {'high_recurrence': 100},
        );

        final score = ranker.scoreOf(issue, context);
        // recurrence = min(100, 5) = 5, so +10
        // 2*100 + 0*8 + 1*5 + 5*2 = 215
        expect(score, 215);
      });
    });

    group('composite ranking', () {
      test('realistic multi-issue sort matches expected order', () {
        // Critical + confirmed + no jank = 300 + 0 + 15 + 0 = 315
        final criticalConfirmed = makeIssue(
          severity: IssueSeverity.critical,
          confidence: IssueConfidence.confirmed,
          stableId: 'A',
        );
        // Critical + possible + no jank = 300 + 0 + 5 + 0 = 305
        final criticalPossible = makeIssue(
          severity: IssueSeverity.critical,
          confidence: IssueConfidence.possible,
          stableId: 'B',
        );
        // Warning + confirmed + no jank = 200 + 0 + 15 + 0 = 215
        final warningConfirmed = makeIssue(
          severity: IssueSeverity.warning,
          confidence: IssueConfidence.confirmed,
          stableId: 'C',
        );
        // Warning + possible + no jank = 200 + 0 + 5 + 0 = 205
        final warningPossible = makeIssue(
          severity: IssueSeverity.warning,
          confidence: IssueConfidence.possible,
          stableId: 'D',
        );

        const context = IssueRankingContext();
        final result = ranker.rank(
          [
            warningPossible,
            criticalPossible,
            warningConfirmed,
            criticalConfirmed
          ],
          context,
        );

        expect(
          result.map((i) => i.stableId).toList(),
          ['A', 'B', 'C', 'D'],
        );
      });

      test('stable sort: equal-score issues preserve input order', () {
        // All same severity/confidence/category, no jank, no recurrence
        final a = makeIssue(stableId: 'a', title: 'First');
        final b = makeIssue(stableId: 'b', title: 'Second');
        final c = makeIssue(stableId: 'c', title: 'Third');

        const context = IssueRankingContext();
        final result = ranker.rank([a, b, c], context);

        expect(
          result.map((i) => i.stableId).toList(),
          ['a', 'b', 'c'],
        );
      });

      test('empty list returns empty', () {
        const context = IssueRankingContext();
        expect(ranker.rank([], context), isEmpty);
      });

      test('single issue returns unchanged', () {
        final issue = makeIssue(stableId: 'only');
        const context = IssueRankingContext();
        final result = ranker.rank([issue], context);
        expect(result.length, 1);
        expect(result.first.stableId, 'only');
      });
    });

    group('scoring edge cases', () {
      test('issue with null stableId uses title for recurrence lookup', () {
        final issue = makeIssue(stableId: null, title: 'My Title');

        final context = IssueRankingContext(
          recurrenceCounts: {'My Title': 3},
        );

        final score = ranker.scoreOf(issue, context);
        // 2*100 + 0 + 1*5 + 3*2 = 211
        expect(score, 211);
      });

      test('no suspectedPhase with jankActive gives partial boost to all', () {
        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: null,
        );

        final buildIssue = makeIssue(category: IssueCategory.build);
        final paintIssue = makeIssue(category: IssueCategory.paint);
        final memoryIssue = makeIssue(category: IssueCategory.memory);

        // All get frameImpact=1 (partial boost)
        final buildScore = ranker.scoreOf(buildIssue, context);
        final paintScore = ranker.scoreOf(paintIssue, context);
        final memoryScore = ranker.scoreOf(memoryIssue, context);

        expect(buildScore, paintScore);
        expect(paintScore, memoryScore);
        // 2*100 + 1*8 + 1*5 + 0 = 213
        expect(buildScore, 213);
      });

      test('PipelinePhase.unknown gives partial boost', () {
        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.unknown,
        );

        final issue = makeIssue(category: IssueCategory.build);
        final score = ranker.scoreOf(issue, context);
        // frameImpact=1 (partial), so 2*100 + 1*8 + 1*5 + 0 = 213
        expect(score, 213);
      });
    });

    group('rankWithScores', () {
      test('returns issues with non-null rankingScore', () {
        final issues = [
          makeIssue(severity: IssueSeverity.critical),
          makeIssue(severity: IssueSeverity.warning),
        ];
        const context = IssueRankingContext();

        final result = ranker.rankWithScores(issues, context);
        expect(result, hasLength(2));
        for (final issue in result) {
          expect(issue.rankingScore, isNotNull);
          expect(issue.rankingBreakdown, isNotNull);
        }
      });

      test('sort order identical to rank()', () {
        final issues = [
          makeIssue(
            severity: IssueSeverity.ok,
            confidence: IssueConfidence.confirmed,
            stableId: 'ok_1',
          ),
          makeIssue(
            severity: IssueSeverity.critical,
            confidence: IssueConfidence.possible,
            stableId: 'critical_1',
          ),
          makeIssue(
            severity: IssueSeverity.warning,
            confidence: IssueConfidence.likely,
            stableId: 'warning_1',
          ),
        ];
        const context = IssueRankingContext();

        final ranked = ranker.rank(issues, context);
        final rankedWithScores = ranker.rankWithScores(issues, context);

        for (var i = 0; i < ranked.length; i++) {
          expect(rankedWithScores[i].title, ranked[i].title);
          expect(rankedWithScores[i].severity, ranked[i].severity);
        }
      });

      test('breakdown keys match expected components', () {
        final issues = [makeIssue()];
        const context = IssueRankingContext();

        final result = ranker.rankWithScores(issues, context);
        final breakdown = result.first.rankingBreakdown!;

        expect(breakdown.containsKey('severity'), isTrue);
        expect(breakdown.containsKey('frameImpact'), isTrue);
        expect(breakdown.containsKey('confidence'), isTrue);
        expect(breakdown.containsKey('recurrence'), isTrue);
        expect(breakdown.length, 4);
      });

      test('breakdown values sum to rankingScore', () {
        final issues = [
          makeIssue(
            severity: IssueSeverity.critical,
            confidence: IssueConfidence.confirmed,
            stableId: 'test_sum',
          ),
        ];
        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.build,
          recurrenceCounts: {'test_sum': 3},
        );

        final result = ranker.rankWithScores(issues, context);
        final score = result.first.rankingScore!;
        final breakdown = result.first.rankingBreakdown!;
        final sum = breakdown.values.reduce((a, b) => a + b);

        expect(sum, score);
      });

      test('empty list returns empty', () {
        const context = IssueRankingContext();
        final result = ranker.rankWithScores([], context);
        expect(result, isEmpty);
      });

      test('single-issue list gets score attached', () {
        final issues = [makeIssue()];
        const context = IssueRankingContext();

        final result = ranker.rankWithScores(issues, context);
        expect(result, hasLength(1));
        expect(result.first.rankingScore, isNotNull);
        expect(
            result.first.rankingScore, ranker.scoreOf(issues.first, context));
      });
    });
  });
}
