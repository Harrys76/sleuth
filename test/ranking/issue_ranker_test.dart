import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/frame_verdict.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ranking/issue_ranker.dart';

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
    group('evidence tiers', () {
      // Lower issue gets the maximum bonus (frameImpact 3, recurrence 5);
      // higher issue gets none. The higher issue must still win.
      final maxBonusContext = IssueRankingContext(
        jankActive: true,
        suspectedPhase: PipelinePhase.build,
        recurrenceCounts: {'low': 5},
      );

      PerformanceIssue low(IssueSeverity s, IssueConfidence c) => makeIssue(
        severity: s,
        confidence: c,
        category: IssueCategory.build,
        stableId: 'low',
      );

      PerformanceIssue high(IssueSeverity s, IssueConfidence c) => makeIssue(
        severity: s,
        confidence: c,
        category: IssueCategory.font,
        stableId: 'high',
      );

      test('confirmed warning outranks possible critical', () {
        // A structural-only critical guess ranks below a warning observed
        // at runtime.
        final critical = makeIssue(
          severity: IssueSeverity.critical,
          confidence: IssueConfidence.possible,
          category: IssueCategory.font,
          stableId: 'critical_1',
        );
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

        final result = ranker.rank([critical, warning], context);
        expect(result.first.stableId, 'warning_1');

        // critical/possible: 3*100 + 1*8 + 0*2 = 308
        // warning/confirmed: 4*100 + 3*8 + 5*2 = 434
        expect(ranker.scoreOf(critical, context), 308);
        expect(ranker.scoreOf(warning, context), 434);

        // Holds without bonuses on the warning too.
        expect(
          ranker
              .rank([
                high(IssueSeverity.critical, IssueConfidence.possible),
                low(IssueSeverity.warning, IssueConfidence.confirmed),
              ], const IssueRankingContext())
              .first
              .stableId,
          'low',
        );
      });

      test('likely critical outranks confirmed warning', () {
        final critical = high(IssueSeverity.critical, IssueConfidence.likely);
        final warning = low(IssueSeverity.warning, IssueConfidence.confirmed);

        final result = ranker.rank([warning, critical], maxBonusContext);
        expect(result.first.stableId, 'high');
        // 5*100 + 1*8 = 508 vs 4*100 + 3*8 + 5*2 = 434
        expect(ranker.scoreOf(critical, maxBonusContext), 508);
        expect(ranker.scoreOf(warning, maxBonusContext), 434);
      });

      test('possible critical outranks likely warning', () {
        final critical = high(IssueSeverity.critical, IssueConfidence.possible);
        final warning = low(IssueSeverity.warning, IssueConfidence.likely);

        final result = ranker.rank([warning, critical], maxBonusContext);
        expect(result.first.stableId, 'high');
        // 3*100 + 1*8 = 308 vs 2*100 + 3*8 + 5*2 = 234
        expect(ranker.scoreOf(critical, maxBonusContext), 308);
        expect(ranker.scoreOf(warning, maxBonusContext), 234);
      });

      test('confirmed ok ranks below every warning', () {
        final ok = low(IssueSeverity.ok, IssueConfidence.confirmed);
        // 0*100 + 3*8 + 5*2 = 34
        expect(ranker.scoreOf(ok, maxBonusContext), 34);

        for (final c in IssueConfidence.values) {
          final warning = high(IssueSeverity.warning, c);
          final result = ranker.rank([ok, warning], maxBonusContext);
          expect(result.first.stableId, 'high', reason: 'warning/$c');
        }
      });

      test('max bonuses (frameImpact 3, recurrence 5) cannot lift an issue '
          'past the next tier', () {
        // Tier order, highest first. ok shares tier 0 across confidences.
        const order = [
          (IssueSeverity.critical, IssueConfidence.confirmed),
          (IssueSeverity.critical, IssueConfidence.likely),
          (IssueSeverity.warning, IssueConfidence.confirmed),
          (IssueSeverity.critical, IssueConfidence.possible),
          (IssueSeverity.warning, IssueConfidence.likely),
          (IssueSeverity.warning, IssueConfidence.possible),
          (IssueSeverity.ok, IssueConfidence.confirmed),
        ];
        const expectedBase = [600, 500, 400, 300, 200, 100, 0];

        for (var i = 0; i < order.length; i++) {
          final (s, c) = order[i];
          expect(
            ranker.scoreOf(high(s, c), const IssueRankingContext()),
            expectedBase[i],
            reason: '$s/$c base',
          );
        }

        for (var i = 0; i < order.length - 1; i++) {
          final (hs, hc) = order[i];
          final (ls, lc) = order[i + 1];
          final upper = high(hs, hc);
          final lower = low(ls, lc);
          final lowerScore = ranker.scoreOf(lower, maxBonusContext);
          expect(lowerScore, expectedBase[i + 1] + 34);
          expect(
            ranker.scoreOf(upper, const IssueRankingContext()),
            greaterThan(lowerScore),
            reason: '$hs/$hc vs boosted $ls/$lc',
          );
          expect(
            ranker.rank([lower, upper], maxBonusContext).first.stableId,
            'high',
          );
        }
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
        // warning/possible tier 1: 1*100 + 1*8 + 0*2 = 108
        expect(score, 108);
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
          expect(score, 108, reason: '$cat should get partial boost');
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
      test(
        'recurring issue outranks first-time at same severity+confidence',
        () {
          final recurring = makeIssue(stableId: 'recurring');
          final fresh = makeIssue(stableId: 'fresh');

          final context = IssueRankingContext(
            recurrenceCounts: {'recurring': 3},
          );

          final result = ranker.rank([fresh, recurring], context);
          expect(result.first.stableId, 'recurring');
        },
      );

      test('recurrence capped at 5', () {
        final issue = makeIssue(stableId: 'high_recurrence');

        final context = IssueRankingContext(
          recurrenceCounts: {'high_recurrence': 100},
        );

        final score = ranker.scoreOf(issue, context);
        // recurrence = min(100, 5) = 5, so +10
        // 1*100 + 0*8 + 5*2 = 110
        expect(score, 110);
      });
    });

    group('composite ranking', () {
      test('realistic multi-issue sort matches expected order', () {
        // Critical + confirmed + no jank = 600
        final criticalConfirmed = makeIssue(
          severity: IssueSeverity.critical,
          confidence: IssueConfidence.confirmed,
          stableId: 'A',
        );
        // Critical + possible + no jank = 300
        final criticalPossible = makeIssue(
          severity: IssueSeverity.critical,
          confidence: IssueConfidence.possible,
          stableId: 'B',
        );
        // Warning + confirmed + no jank = 400
        final warningConfirmed = makeIssue(
          severity: IssueSeverity.warning,
          confidence: IssueConfidence.confirmed,
          stableId: 'C',
        );
        // Warning + possible + no jank = 100
        final warningPossible = makeIssue(
          severity: IssueSeverity.warning,
          confidence: IssueConfidence.possible,
          stableId: 'D',
        );

        const context = IssueRankingContext();
        final result = ranker.rank([
          warningPossible,
          criticalPossible,
          warningConfirmed,
          criticalConfirmed,
        ], context);

        // Confirmed warning C ranks above possible critical B.
        expect(result.map((i) => i.stableId).toList(), ['A', 'C', 'B', 'D']);
      });

      test('stable sort: equal-score issues preserve input order', () {
        // All same severity/confidence/category, no jank, no recurrence
        final a = makeIssue(stableId: 'a', title: 'First');
        final b = makeIssue(stableId: 'b', title: 'Second');
        final c = makeIssue(stableId: 'c', title: 'Third');

        const context = IssueRankingContext();
        final result = ranker.rank([a, b, c], context);

        expect(result.map((i) => i.stableId).toList(), ['a', 'b', 'c']);
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

        final context = IssueRankingContext(recurrenceCounts: {'My Title': 3});

        final score = ranker.scoreOf(issue, context);
        // 1*100 + 0 + 3*2 = 106
        expect(score, 106);
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
        // 1*100 + 1*8 + 0 = 108
        expect(buildScore, 108);
      });

      test('PipelinePhase.unknown gives partial boost', () {
        final context = IssueRankingContext(
          jankActive: true,
          suspectedPhase: PipelinePhase.unknown,
        );

        final issue = makeIssue(category: IssueCategory.build);
        final score = ranker.scoreOf(issue, context);
        // frameImpact=1 (partial), so 1*100 + 1*8 + 0 = 108
        expect(score, 108);
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

      test('breakdown splits tier into severity base and confidence', () {
        const context = IssueRankingContext();
        Map<String, int> breakdownOf(IssueSeverity s, IssueConfidence c) =>
            ranker
                .rankWithScores([
                  makeIssue(severity: s, confidence: c),
                ], context)
                .first
                .rankingBreakdown!;

        final cases = {
          (IssueSeverity.critical, IssueConfidence.confirmed): (400, 200),
          (IssueSeverity.critical, IssueConfidence.likely): (400, 100),
          (IssueSeverity.critical, IssueConfidence.possible): (400, -100),
          (IssueSeverity.warning, IssueConfidence.confirmed): (200, 200),
          (IssueSeverity.warning, IssueConfidence.likely): (200, 0),
          (IssueSeverity.warning, IssueConfidence.possible): (200, -100),
          (IssueSeverity.ok, IssueConfidence.confirmed): (0, 0),
          (IssueSeverity.ok, IssueConfidence.possible): (0, 0),
        };
        cases.forEach((key, value) {
          final b = breakdownOf(key.$1, key.$2);
          expect(b['severity'], value.$1, reason: '$key severity');
          expect(b['confidence'], value.$2, reason: '$key confidence');
        });
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
          result.first.rankingScore,
          ranker.scoreOf(issues.first, context),
        );
      });
    });
  });
}
