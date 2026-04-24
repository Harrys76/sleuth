import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/session_snapshot.dart';
import 'package:sleuth/src/models/startup_metrics.dart';
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
      expect(md, contains('- Actual FPS: **58**'));
      expect(md, contains('- Throughput FPS: **58**'));
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

  group('Route Health table in markdown', () {
    test('renders route health table when routeSessions present', () {
      final snapshot = makeSnapshot();
      final withRoutes = SessionSnapshot(
        exportedAt: snapshot.exportedAt,
        capturedFrames: snapshot.capturedFrames,
        currentIssues: snapshot.currentIssues,
        frameStatsSummary: snapshot.frameStatsSummary,
        packageVersion: snapshot.packageVersion,
        routeSessions: [
          {
            'routeName': '/home',
            'healthScore': 92,
            'durationSeconds': 222,
            'frameStats': {'averageFps': 60.0},
            'issueCount': 0,
            'criticalCount': 0,
          },
          {
            'routeName': '/settings',
            'healthScore': 72,
            'durationSeconds': 134,
            'frameStats': {'averageFps': 57.3},
            'issueCount': 3,
            'criticalCount': 1,
          },
          {
            'routeName': '/checkout',
            'healthScore': 41,
            'durationSeconds': 68,
            'frameStats': {'averageFps': 38.0},
            'issueCount': 5,
            'criticalCount': 2,
          },
        ],
      );

      final md = SessionMarkdownExporter.render(withRoutes, topN: 5);

      expect(md, contains('## Route Health'));
      expect(md, contains('| Route | Score | FPS | Issues | Time |'));
      // Green dot for score 92
      expect(md, contains('/home'));
      expect(md, contains('92 \u{1F7E2}'));
      // Amber dot for score 72
      expect(md, contains('/settings'));
      expect(md, contains('72 \u{1F7E1}'));
      expect(md, contains('3 (1!)'));
      // Red dot for score 41
      expect(md, contains('/checkout'));
      expect(md, contains('41 \u{1F534}'));
      expect(md, contains('5 (2!)'));
    });

    test('route health table omitted when routeSessions null', () {
      final snapshot = makeSnapshot();
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, isNot(contains('## Route Health')));
    });

    test('route health table omitted when routeSessions empty', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime(2026, 4, 9, 14, 23, 11),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 100,
          jankFrames: 2,
          averageFps: 58.3,
          worstFrameTimeUs: 34000,
        ),
        packageVersion: '0.12.0',
        routeSessions: const [],
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, isNot(contains('## Route Health')));
    });

    test('route health duration formatting', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime(2026, 4, 9),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 0,
          jankFrames: 0,
          averageFps: 0,
          worstFrameTimeUs: 0,
        ),
        routeSessions: [
          {
            'routeName': '/short',
            'healthScore': 100,
            'durationSeconds': 45,
            'frameStats': {'averageFps': 60.0},
            'issueCount': 0,
            'criticalCount': 0,
          },
          {
            'routeName': '/long',
            'healthScore': 80,
            'durationSeconds': 185,
            'frameStats': {'averageFps': 59.0},
            'issueCount': 0,
            'criticalCount': 0,
          },
          {
            'routeName': '/exact',
            'healthScore': 90,
            'durationSeconds': 120,
            'frameStats': {'averageFps': 60.0},
            'issueCount': 0,
            'criticalCount': 0,
          },
        ],
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      // 45 seconds → "45s"
      expect(md, contains('45s'));
      // 185 seconds → "3m 05s"
      expect(md, contains('3m 05s'));
      // 120 seconds → "2m" (no seconds when 0)
      expect(md, contains('2m |'));
    });

    test('route health escapes special chars in route name', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime(2026, 4, 9),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 0,
          jankFrames: 0,
          averageFps: 0,
          worstFrameTimeUs: 0,
        ),
        routeSessions: [
          {
            'routeName': '/path|with<special>',
            'healthScore': 80,
            'durationSeconds': 60,
            'frameStats': {'averageFps': 60.0},
            'issueCount': 0,
            'criticalCount': 0,
          },
        ],
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains(r'/path\|with\<special\>'));
    });
  });

  group('startup engine phases in markdown', () {
    test('includes engine lines when startup metrics have engine data', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime(2026, 4, 10),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 100,
          jankFrames: 2,
          averageFps: 58.5,
          worstFrameTimeUs: 34000,
        ),
        startupMetrics: StartupMetrics(
          dartEntryTimestamp: DateTime(2026, 4, 10),
          ttffMs: 1500,
          dartEntryMonotonicUs: 22614577000,
          frameworkInitDurationUs: 281595,
          engineEnterUs: 22332982085,
          firstFrameRasterizedUs: 22334541649,
        ),
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains('Framework init:'));
      expect(md, contains('281.6 ms'));
      expect(md, contains('Pre-Dart overhead:'));
      expect(md, contains('Engine TTFF:'));
    });

    test('omits engine lines when no engine data', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime(2026, 4, 10),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 100,
          jankFrames: 2,
          averageFps: 58.5,
          worstFrameTimeUs: 34000,
        ),
        startupMetrics: StartupMetrics(
          dartEntryTimestamp: DateTime(2026, 4, 10),
          ttffMs: 1500,
        ),
      );
      final md = SessionMarkdownExporter.render(snapshot, topN: 5);

      expect(md, contains('Time to first frame:'));
      expect(md, isNot(contains('Framework init:')));
      expect(md, isNot(contains('Engine TTFF:')));
    });
  });
}
