import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/fix_verification_result.dart';
import 'package:sleuth/src/models/performance_issue.dart';

PerformanceIssue _issue({
  required String stableId,
  IssueSeverity severity = IssueSeverity.warning,
  int? rankingScore,
}) =>
    PerformanceIssue(
      severity: severity,
      category: IssueCategory.build,
      confidence: IssueConfidence.possible,
      title: stableId,
      detail: '',
      fixHint: '',
      stableId: stableId,
      rankingScore: rankingScore,
    );

void main() {
  group('FixBaseline', () {
    test('captures current issues as snapshots', () {
      final issues = [
        _issue(
            stableId: 'a', severity: IssueSeverity.warning, rankingScore: 200),
        _issue(
            stableId: 'b', severity: IssueSeverity.critical, rankingScore: 300),
      ];
      final baseline = captureFixBaseline(issues);

      expect(baseline.issueSnapshots, hasLength(2));
      expect(baseline.issueSnapshots.containsKey('a'), true);
      expect(baseline.issueSnapshots.containsKey('b'), true);
    });
  });

  group('FixBaseline.compare', () {
    test('resolved after cooldown cycles', () {
      final baseline = captureFixBaseline([
        _issue(stableId: 'a', severity: IssueSeverity.warning),
      ]);

      // Simulate 5 absent cycles
      for (var i = 0; i < 5; i++) {
        baseline.recordAbsence('a');
      }

      final result = baseline.compare([], cooldownCycles: 5);
      expect(result.resolved, hasLength(1));
      expect(result.resolved.first.stableId, 'a');
    });

    test('not resolved before cooldown (treated as unchanged)', () {
      final baseline = captureFixBaseline([
        _issue(stableId: 'a'),
      ]);

      // Only 2 absent cycles (< 5 cooldown)
      baseline.recordAbsence('a');
      baseline.recordAbsence('a');

      final result = baseline.compare([], cooldownCycles: 5);
      expect(result.resolved, isEmpty);
      expect(result.unchanged, hasLength(1));
    });

    test('intermittent issue: absent then returns resets cooldown', () {
      final baseline = captureFixBaseline([
        _issue(stableId: 'a'),
      ]);

      // 3 absent cycles, then issue returns
      baseline.recordAbsence('a');
      baseline.recordAbsence('a');
      baseline.recordAbsence('a');
      baseline.recordPresence('a'); // resets counter

      // 2 more absent cycles (total < 5 since reset)
      baseline.recordAbsence('a');
      baseline.recordAbsence('a');

      final result = baseline.compare([], cooldownCycles: 5);
      expect(result.resolved, isEmpty,
          reason: 'Issue returned after 3 cycles, '
              'only 2 absent since — not resolved');
    });

    test('improved: lower severity', () {
      final baseline = captureFixBaseline([
        _issue(
            stableId: 'a', severity: IssueSeverity.critical, rankingScore: 300),
      ]);

      final result = baseline.compare([
        _issue(
            stableId: 'a', severity: IssueSeverity.warning, rankingScore: 200),
      ]);

      expect(result.improved, hasLength(1));
      expect(result.improved.first.baselineSeverity, IssueSeverity.critical);
      expect(result.improved.first.currentSeverity, IssueSeverity.warning);
    });

    test('worsened: higher severity', () {
      final baseline = captureFixBaseline([
        _issue(
            stableId: 'a', severity: IssueSeverity.warning, rankingScore: 200),
      ]);

      final result = baseline.compare([
        _issue(
            stableId: 'a', severity: IssueSeverity.critical, rankingScore: 300),
      ]);

      expect(result.worsened, hasLength(1));
    });

    test('unchanged: same severity and score', () {
      final baseline = captureFixBaseline([
        _issue(
            stableId: 'a', severity: IssueSeverity.warning, rankingScore: 200),
      ]);

      final result = baseline.compare([
        _issue(
            stableId: 'a', severity: IssueSeverity.warning, rankingScore: 200),
      ]);

      expect(result.unchanged, hasLength(1));
    });

    test('new issues not in baseline', () {
      final baseline = captureFixBaseline([
        _issue(stableId: 'a'),
      ]);

      final result = baseline.compare([
        _issue(stableId: 'a'),
        _issue(stableId: 'b'), // new
      ]);

      expect(result.newIssues, hasLength(1));
      expect(result.newIssues.first.stableId, 'b');
    });

    test('mixed results: resolved + improved + new', () {
      final baseline = captureFixBaseline([
        _issue(stableId: 'resolved_one', severity: IssueSeverity.warning),
        _issue(
            stableId: 'improved_one',
            severity: IssueSeverity.critical,
            rankingScore: 300),
      ]);

      // resolved_one absent for 5+ cycles
      for (var i = 0; i < 5; i++) {
        baseline.recordAbsence('resolved_one');
      }

      final result = baseline.compare([
        _issue(
            stableId: 'improved_one',
            severity: IssueSeverity.warning,
            rankingScore: 200),
        _issue(stableId: 'new_one'),
      ]);

      expect(result.resolved, hasLength(1));
      expect(result.improved, hasLength(1));
      expect(result.newIssues, hasLength(1));
    });

    test('clearing absence counters prevents false resolution', () {
      final baseline = captureFixBaseline([
        _issue(stableId: 'a', severity: IssueSeverity.warning),
      ]);

      // 4 absent cycles (close to cooldown)
      for (var i = 0; i < 4; i++) {
        baseline.recordAbsence('a');
      }

      // Simulate hot-reload clearing counters
      baseline.consecutiveAbsentCycles.clear();

      // 1 more absent cycle after clear — total is 1, not 5
      baseline.recordAbsence('a');

      final result = baseline.compare([], cooldownCycles: 5);
      expect(result.resolved, isEmpty,
          reason: 'Counter was reset — only 1 cycle since clear');
      expect(result.unchanged, hasLength(1));
    });

    test('no baseline returns null from controller compare', () {
      // This tests the absence case — compareToBaseline returns null
      // FixBaseline.compare always returns a result, but the controller
      // guards with null check
      final baseline = captureFixBaseline([]);
      final result = baseline.compare([]);
      expect(result.entries, isEmpty);
    });
  });

  group('FixVerificationResult serialization', () {
    test('toJson includes summary and entries', () {
      final result = FixVerificationResult(
        baselineCapturedAt: DateTime(2024, 1, 1),
        comparedAt: DateTime(2024, 1, 2),
        entries: [
          const IssueVerificationEntry(
            stableId: 'a',
            status: FixVerificationStatus.resolved,
            baselineSeverity: IssueSeverity.warning,
          ),
          const IssueVerificationEntry(
            stableId: 'b',
            status: FixVerificationStatus.newIssue,
            currentSeverity: IssueSeverity.critical,
          ),
        ],
      );

      final json = result.toJson();
      expect(json['summary']['resolved'], 1);
      expect(json['summary']['newIssues'], 1);
      expect(json['entries'], hasLength(2));
    });
  });
}
