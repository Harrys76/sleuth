import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

void main() {
  group('PerformanceIssue', () {
    test('creates with required fields', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Test Issue',
        detail: 'Detail text',
        fixHint: 'Fix this',
      );

      expect(issue.severity, IssueSeverity.warning);
      expect(issue.category, IssueCategory.build);
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.title, 'Test Issue');
    });

    test('copyWith preserves original values', () {
      const original = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Original',
        detail: 'Detail',
        fixHint: 'Fix',
      );

      final copy = original.copyWith(severity: IssueSeverity.critical);
      expect(copy.severity, IssueSeverity.critical);
      expect(copy.title, 'Original'); // Preserved
    });
  });

  group('FrameStats', () {
    test('detects jank correctly', () {
      final stats = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 20),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
      );

      expect(stats.isJank, true);
      expect(stats.isSevereJank, false);
    });

    test('detects severe jank', () {
      final stats = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 40),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
      );

      expect(stats.isSevereJank, true);
    });

    test('frameBudgetMs drives jank thresholds', () {
      // 120fps → 8ms budget. A 10ms frame is jank at 120fps but not at 60fps.
      final at120fps = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 5),
        timestamp: DateTime.now(),
        frameBudgetMs: 8, // 120fps
      );

      final at60fps = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 5),
        timestamp: DateTime.now(),
        frameBudgetMs: 16, // 60fps (default)
      );

      expect(at120fps.isJank, true);
      expect(at60fps.isJank, false);

      // Severe jank = 2x budget. 20ms is severe at 120fps (>16ms) but not at 60fps (>32ms).
      final severe120 = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 20),
        rasterDuration: const Duration(milliseconds: 5),
        timestamp: DateTime.now(),
        frameBudgetMs: 8,
      );

      expect(severe120.isSevereJank, true);
      expect(at60fps.isSevereJank, false);
    });
  });

  group('FrameStatsBuffer', () {
    test('maintains capacity limit', () {
      final buffer = FrameStatsBuffer(capacity: 3);

      for (var i = 0; i < 5; i++) {
        buffer.add(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(milliseconds: 8),
          rasterDuration: const Duration(milliseconds: 4),
          timestamp: DateTime.now(),
        ));
      }

      expect(buffer.length, 3);
      expect(buffer.frames.first.frameNumber, 2);
    });
  });

  group('TimelineParser', () {
    test('parses empty list', () {
      final result = TimelineParser.parse([]);
      expect(result.hasData, false);
    });
  });
}
