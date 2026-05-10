import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  // Pins the post-escalation re-sort contract: a downstream's
  // `rootCauseIds` list must be ordered by CURRENT severity (post
  // duration-escalation) so [PerformanceIssue.toJson] derives a fresh
  // legacy `rootCauseId` emission for v0.24.1 readers. Without this,
  // [CausalGraphRule.apply] sorts once at correlation time and a later
  // promotion of a tied parent silently leaves the stale order intact.
  group('rootCauseIds re-sort by current severity', () {
    late SleuthController controller;

    PerformanceIssue makeIssue({
      required String stableId,
      required IssueSeverity severity,
      List<String>? rootCauseIds,
      IssueCategory category = IssueCategory.memory,
      IssueConfidence confidence = IssueConfidence.confirmed,
    }) =>
        PerformanceIssue(
          severity: severity,
          category: category,
          confidence: confidence,
          title: stableId,
          detail: 'Detail',
          fixHint: 'Fix',
          stableId: stableId,
          rootCauseIds: rootCauseIds,
        );

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test(
        'tied parents at correlation: post-escalation promotes one parent → '
        're-sort puts critical parent first (overrides alphabetical)', () {
      // Simulates the post-correlate state: A and B tied at warning,
      // alphabetically sorted by apply(). C is the downstream. Then
      // duration escalation promotes B to critical. The re-sort pass
      // must reorder C.rootCauseIds to ['B', 'A'].
      final issues = [
        makeIssue(stableId: 'A', severity: IssueSeverity.warning),
        makeIssue(stableId: 'B', severity: IssueSeverity.critical),
        makeIssue(
          stableId: 'C',
          severity: IssueSeverity.warning,
          rootCauseIds: ['A', 'B'],
        ),
      ];

      controller.resortRootCauseIdsByCurrentSeverityForTest(issues);

      final c = issues.firstWhere((i) => i.stableId == 'C');
      expect(c.rootCauseIds, ['B', 'A'],
          reason: 'critical-severity B must lead after re-sort even though '
              'apply() placed A first under tied-warning semantics');
    });

    test('alphabetical tie-break preserved when severities truly tied', () {
      final issues = [
        makeIssue(stableId: 'A', severity: IssueSeverity.warning),
        makeIssue(stableId: 'B', severity: IssueSeverity.warning),
        makeIssue(
          stableId: 'C',
          severity: IssueSeverity.warning,
          rootCauseIds: ['B', 'A'],
        ),
      ];

      controller.resortRootCauseIdsByCurrentSeverityForTest(issues);

      final c = issues.firstWhere((i) => i.stableId == 'C');
      expect(c.rootCauseIds, ['A', 'B'],
          reason: 'tied severity → alphabetical stableId tie-break');
    });

    test('missing parent (suppressed by ranker) sorts last', () {
      // Parent 'missing' is not in the issues list — ranker suppressed it
      // upstream. The re-sort pushes it to the end so present parents
      // lead `rootCauseIds.first`.
      final issues = [
        makeIssue(stableId: 'A', severity: IssueSeverity.warning),
        makeIssue(
          stableId: 'C',
          severity: IssueSeverity.warning,
          rootCauseIds: ['missing', 'A'],
        ),
      ];

      controller.resortRootCauseIdsByCurrentSeverityForTest(issues);

      final c = issues.firstWhere((i) => i.stableId == 'C');
      expect(c.rootCauseIds, ['A', 'missing'],
          reason: 'a present parent must lead a suppressed/absent one');
    });

    test('single-parent rootCauseIds is left unchanged (skip cost)', () {
      final issues = [
        makeIssue(stableId: 'A', severity: IssueSeverity.warning),
        makeIssue(
          stableId: 'C',
          severity: IssueSeverity.warning,
          rootCauseIds: ['A'],
        ),
      ];

      controller.resortRootCauseIdsByCurrentSeverityForTest(issues);

      final c = issues.firstWhere((i) => i.stableId == 'C');
      expect(c.rootCauseIds, ['A']);
    });

    test('null rootCauseIds left unchanged', () {
      final issues = [
        makeIssue(stableId: 'A', severity: IssueSeverity.warning),
      ];

      controller.resortRootCauseIdsByCurrentSeverityForTest(issues);

      expect(issues[0].rootCauseIds, isNull);
    });

    test('order already correct → no copyWith allocation', () {
      // Critical B already first; warning A second. Re-sort produces the
      // same order → the pass returns the same instance via the
      // change-tracking guard.
      final original = makeIssue(
        stableId: 'C',
        severity: IssueSeverity.warning,
        rootCauseIds: ['B', 'A'],
      );
      final issues = [
        makeIssue(stableId: 'A', severity: IssueSeverity.warning),
        makeIssue(stableId: 'B', severity: IssueSeverity.critical),
        original,
      ];

      controller.resortRootCauseIdsByCurrentSeverityForTest(issues);

      final c = issues.firstWhere((i) => i.stableId == 'C');
      expect(identical(c, original), isTrue,
          reason: 'no copyWith allocation when sort produces the same order');
    });
  });
}
