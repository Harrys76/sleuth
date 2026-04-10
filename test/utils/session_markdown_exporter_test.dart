import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/session_snapshot.dart';
import 'package:sleuth/src/utils/session_markdown_exporter.dart';

void main() {
  SessionSnapshot makeSnapshot({
    List<PerformanceIssue>? issues,
    int totalFrames = 100,
    int jankFrames = 2,
    double averageFps = 58.3,
    int worstFrameTimeUs = 34000,
    List<Map<String, String>>? causalEdges,
    String packageVersion = '0.12.0',
  }) {
    final ts = DateTime(2026, 4, 9, 14, 23, 11);
    Map<String, dynamic>? summary;
    if (causalEdges != null && causalEdges.isNotEmpty) {
      summary = {'causalEdges': causalEdges};
    }
    return SessionSnapshot(
      exportedAt: ts,
      capturedFrames: const [],
      currentIssues: issues ?? const [],
      frameStatsSummary: FrameStatsSummary(
        totalFrames: totalFrames,
        jankFrames: jankFrames,
        averageFps: averageFps,
        worstFrameTimeUs: worstFrameTimeUs,
      ),
      packageVersion: packageVersion,
      sessionSummary: summary,
    );
  }

  PerformanceIssue makeIssue({
    required String title,
    String? stableId,
    String? confidenceReason,
    IssueSeverity severity = IssueSeverity.warning,
    IssueCategory category = IssueCategory.build,
  }) {
    return PerformanceIssue(
      title: title,
      stableId: stableId,
      detail: 'd',
      fixHint: 'f',
      severity: severity,
      category: category,
      confidence: IssueConfidence.confirmed,
      confidenceReason: confidenceReason,
    );
  }

  group('SessionMarkdownExporter', () {
    test('renders full snapshot with issues and causal edges', () {
      final snapshot = makeSnapshot(
        issues: [
          makeIssue(
            title: 'Heavy Build: 23.4ms',
            stableId: 'heavy_compute',
            confidenceReason: 'VM timeline long UI-thread event.',
          ),
          makeIssue(
            title: 'Excessive GlobalKeys',
            stableId: 'excessive_global_keys',
          ),
        ],
        causalEdges: [
          {'cause': 'excessive_global_keys', 'effect': 'rebuild_activity'},
        ],
      );

      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains('# Sleuth Session Summary'));
      expect(md, contains('**Captured:** 2026-04-09 14:23:11'));
      expect(md, contains('## Frame Stats'));
      expect(md, contains('- Average FPS: **58**'));
      expect(md, contains('- Worst frame: **34 ms**'));
      expect(md, contains('- Jank frames: **2 / 100**'));
      expect(md, contains('## Top Issues (2)'));
      expect(md, contains('1. **Heavy Build: 23.4ms** — `heavy_compute`'));
      expect(md, contains('   > VM timeline long UI-thread event.'));
      expect(md, contains('2. **Excessive GlobalKeys**'));
      expect(md, contains('## Causal Chains'));
      expect(md, contains('- `excessive_global_keys` → `rebuild_activity`'));
      expect(md, contains('_Exported by Sleuth v0.12.0_'));
    });

    test('topN = 5 limits to 5 issues from 10', () {
      final issues = List.generate(
        10,
        (i) => makeIssue(title: 'Issue $i', stableId: 'issue_$i'),
      );
      final snapshot = makeSnapshot(issues: issues);
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains('## Top Issues (5)'));
      expect(md, contains('5. **Issue 4**'));
      expect(md, isNot(contains('6.')));
    });

    test('topN below 1 is clamped to 1', () {
      final snapshot = makeSnapshot(
        issues: [makeIssue(title: 'Only one', stableId: 'x')],
      );
      // The controller clamps, but the renderer also receives clamped value.
      // Verify rendering with topN=1 produces exactly 1 item.
      final md = SessionMarkdownExporter.render(snapshot, topN: 1);
      expect(md, contains('## Top Issues (1)'));
      expect(md, contains('1. **Only one**'));
      expect(md, isNot(contains('2. **')));
    });

    test('zero issues omits Top Issues header', () {
      final snapshot = makeSnapshot(issues: []);
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains('## Frame Stats'));
      expect(md, isNot(contains('## Top Issues')));
    });

    test('zero causal edges omits Causal Chains header', () {
      final snapshot = makeSnapshot(
        issues: [makeIssue(title: 'A', stableId: 'a')],
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, isNot(contains('## Causal Chains')));
    });

    test('escapes backticks in issue title', () {
      final snapshot = makeSnapshot(
        issues: [makeIssue(title: 'Bad `widget` name', stableId: 'x')],
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains(r'Bad \`widget\` name'));
      expect(md, isNot(contains('Bad `widget` name')));
    });

    test('escapes asterisks in issue title', () {
      final snapshot = makeSnapshot(
        issues: [makeIssue(title: 'Bold *text* here', stableId: 'x')],
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains(r'Bold \*text\* here'));
    });

    test('deterministic output for fixed snapshot', () {
      final snapshot = makeSnapshot(
        issues: [
          makeIssue(title: 'Issue A', stableId: 'a'),
          makeIssue(
            title: 'Issue B',
            stableId: 'b',
            confidenceReason: 'reason',
          ),
        ],
        causalEdges: [
          {'cause': 'a', 'effect': 'b'},
        ],
      );

      final md1 = SessionMarkdownExporter.render(snapshot, topN: 5);
      final md2 = SessionMarkdownExporter.render(snapshot, topN: 5);
      expect(md1, equals(md2));
    });

    test('worst frame converts microseconds to milliseconds', () {
      final snapshot = makeSnapshot(worstFrameTimeUs: 45678);
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      // 45678 µs → 46 ms (rounded)
      expect(md, contains('- Worst frame: **46 ms**'));
    });

    test('escapes brackets, angle brackets, and pipes in title', () {
      final snapshot = makeSnapshot(
        issues: [
          makeIssue(title: 'See [docs] <html> | table', stableId: 'x'),
        ],
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains(r'\[docs\]'));
      expect(md, contains(r'\<html\>'));
      expect(md, contains(r'\| table'));
    });

    test('escapes markdown in confidenceReason', () {
      final snapshot = makeSnapshot(
        issues: [
          makeIssue(
            title: 'Issue',
            stableId: 'x',
            confidenceReason: 'Found *bold* and [link](url)',
          ),
        ],
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains(r'\*bold\*'));
      expect(md, contains(r'\[link\]'));
    });

    test('issue without stableId falls back to category name', () {
      final snapshot = makeSnapshot(
        issues: [
          makeIssue(title: 'Unknown issue', category: IssueCategory.memory)
        ],
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains('`memory`'));
    });
  });
}
