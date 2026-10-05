import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/frame_verdict.dart';
import 'package:sleuth/src/utils/ai_context_builder.dart';
import 'package:sleuth/src/utils/ai_session_context.dart';
import 'package:sleuth/src/vm/connection_mode.dart';

void main() {
  PerformanceIssue makeIssue({
    String title = 'Test Issue',
    String detail = 'Detail text',
    String fixHint = 'Fix hint',
    IssueSeverity severity = IssueSeverity.warning,
    IssueCategory category = IssueCategory.memory,
    IssueConfidence confidence = IssueConfidence.confirmed,
    String? stableId,
    String? widgetName,
    String? routeName,
    String? ancestorChain,
    InteractionContext? interactionContext,
    ObservationSource? observationSource,
    FixEffort? fixEffort,
    List<String>? rootCauseIds,
    List<String>? downstreamIds,
  }) {
    return PerformanceIssue(
      title: title,
      detail: detail,
      fixHint: fixHint,
      severity: severity,
      category: category,
      confidence: confidence,
      stableId: stableId,
      widgetName: widgetName,
      routeName: routeName,
      ancestorChain: ancestorChain,
      interactionContext: interactionContext,
      observationSource: observationSource,
      fixEffort: fixEffort,
      rootCauseIds: rootCauseIds,
      downstreamIds: downstreamIds,
    );
  }

  group('AiContextBuilder.buildSystemPrompt', () {
    test('includes issue title and detail', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(title: 'Heap Growing', detail: '512 KB/s growth'),
      );
      expect(prompt, contains('Heap Growing'));
      expect(prompt, contains('512 KB/s growth'));
    });

    test('includes fixHint', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(fixHint: 'Use cacheWidth on images'),
      );
      expect(prompt, contains('Use cacheWidth on images'));
    });

    test('includes severity and category', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(
          severity: IssueSeverity.critical,
          category: IssueCategory.raster,
        ),
      );
      expect(prompt, contains('critical'));
      expect(prompt, contains('raster'));
    });

    test('includes widgetName when present', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(widgetName: 'ProductGrid'),
      );
      expect(prompt, contains('Widget: ProductGrid'));
    });

    test('omits null widgetName', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(widgetName: null),
      );
      expect(prompt, isNot(contains('Widget:')));
    });

    test('omits null routeName', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(routeName: null),
      );
      expect(prompt, isNot(contains('Route:')));
    });

    test('includes routeName when present', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(routeName: '/home'),
      );
      expect(prompt, contains('Route: /home'));
    });

    test('includes ancestorChain when present', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(ancestorChain: 'Scaffold > Column > Image'),
      );
      expect(prompt, contains('Scaffold > Column > Image'));
    });

    test('omits null ancestorChain', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(ancestorChain: null),
      );
      expect(prompt, isNot(contains('Ancestor chain:')));
    });

    test('includes interactionContext when present', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(interactionContext: InteractionContext.scrolling),
      );
      expect(prompt, contains('scrolling'));
    });

    test('includes encyclopedia content when stableId matches', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(stableId: 'heap_near_capacity'),
      );
      // Encyclopedia entry exists for heap_near_capacity
      expect(prompt, contains('Encyclopedia Knowledge'));
      expect(prompt, contains('What it is:'));
      expect(prompt, contains('Why it matters:'));
      expect(prompt, contains('How to fix:'));
    });

    test('omits encyclopedia section for unknown stableId', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(stableId: 'unknown_xyz'),
      );
      expect(prompt, isNot(contains('Encyclopedia Knowledge')));
    });

    test('includes other active issues', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(stableId: 'heap_near_capacity'),
        allIssues: [
          makeIssue(stableId: 'heap_near_capacity'),
          makeIssue(
            title: 'GC Pressure',
            stableId: 'gc_pressure',
            severity: IssueSeverity.warning,
            category: IssueCategory.memory,
          ),
          makeIssue(
            title: 'Shader Jank',
            stableId: 'shader_compilation',
            severity: IssueSeverity.critical,
            category: IssueCategory.raster,
          ),
        ],
      );
      expect(prompt, contains('Other Active Issues'));
      expect(prompt, contains('GC Pressure'));
      expect(prompt, contains('Shader Jank'));
    });

    test('caps other-issues at 5', () {
      final others = List.generate(
        8,
        (i) => makeIssue(title: 'Issue $i', stableId: 'issue_$i'),
      );
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(stableId: 'focus_issue'),
        allIssues: [
          makeIssue(stableId: 'focus_issue'),
          ...others,
        ],
      );
      // Should show 5 + "and N more"
      expect(prompt, contains('and 3 more'));
    });

    test('excludes focus issue from other issues list', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(title: 'Focus', stableId: 'focus_id'),
        allIssues: [
          makeIssue(title: 'Focus', stableId: 'focus_id'),
          makeIssue(title: 'Other', stableId: 'other_id'),
        ],
      );
      // "Other Active Issues" should not contain "Focus"
      final otherSection = prompt.split('Other Active Issues')[1];
      expect(otherSection, isNot(contains('- Focus')));
      expect(otherSection, contains('Other'));
    });

    test('includes downstream and single rootCause when present', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(
          rootCauseIds: ['rebuild_activity'],
          downstreamIds: ['gc_pressure', 'heap_growing'],
        ),
      );
      expect(prompt, contains('Root cause issue: rebuild_activity'));
      expect(prompt, contains('gc_pressure, heap_growing'));
    });

    test('multi-parent: lists every cause, plural label, no truncation '
        'under 5', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(
          rootCauseIds: ['stream_resource_growth', 'uncached_images'],
        ),
      );
      expect(
        prompt,
        contains('Root cause issues: stream_resource_growth, uncached_images'),
      );
      expect(prompt, isNot(contains('more)')));
    });

    test('multi-parent: caps at 5 with "+N more" suffix', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(rootCauseIds: ['a', 'b', 'c', 'd', 'e', 'f', 'g']),
      );
      expect(prompt, contains('Root cause issues: a, b, c, d, e (+2 more)'));
      expect(prompt, isNot(contains('f, g')));
    });

    test('includes response instructions', () {
      final prompt = AiContextBuilder.buildSystemPrompt(issue: makeIssue());
      expect(prompt, contains('Instructions'));
      expect(prompt, contains('Answer concisely'));
    });
  });

  group('AiContextBuilder.starterQuestions', () {
    test('returns 2-3 questions for each category', () {
      for (final category in IssueCategory.values) {
        final questions = AiContextBuilder.starterQuestions(
          makeIssue(category: category),
        );
        expect(
          questions.length,
          inInclusiveRange(2, 3),
          reason: 'Wrong count for $category',
        );
      }
    });

    test('returns non-empty strings', () {
      for (final category in IssueCategory.values) {
        final questions = AiContextBuilder.starterQuestions(
          makeIssue(category: category),
        );
        for (final q in questions) {
          expect(q, isNotEmpty, reason: 'Empty question for $category');
        }
      }
    });

    test('personalizes with widgetName when available', () {
      final questions = AiContextBuilder.starterQuestions(
        makeIssue(category: IssueCategory.build, widgetName: 'MyWidget'),
      );
      expect(questions.any((q) => q.contains('MyWidget')), isTrue);
    });

    test('uses generic text when widgetName is null', () {
      final questions = AiContextBuilder.starterQuestions(
        makeIssue(category: IssueCategory.build, widgetName: null),
      );
      expect(questions.any((q) => q.contains('this widget')), isTrue);
    });
  });

  group('AiContextBuilder encyclopedia placeholders', () {
    test('substitutes route into heavy_compute explanation', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(
          stableId: 'heavy_compute',
          category: IssueCategory.build,
          routeName: '/home',
        ),
      );
      final encyclopedia = prompt.substring(
        prompt.indexOf('## Encyclopedia Knowledge'),
      );
      expect(encyclopedia, contains('/home'));
      expect(prompt, isNot(contains('{routeName}')));
    });
  });

  group('AiContextBuilder session section', () {
    const session = AiSessionContext(
      route: '/catalog',
      actualFps: 24.6,
      throughputFps: 48.2,
      fpsTarget: 60,
      verdictPhase: PipelinePhase.build,
      verdictReason: 'Build scope took 22 ms',
      verdictMode: 'correlated',
      criticalCount: 2,
      warningCount: 9,
      okCount: 1,
      hiddenCount: 3,
      isDebugMode: true,
      connectionMode: ConnectionMode.correlated,
      platform: 'iOS',
    );

    test('is absent without a session', () {
      final prompt = AiContextBuilder.buildSystemPrompt(issue: makeIssue());
      expect(prompt, isNot(contains('## Session')));
      expect(prompt, isNot(contains('Current route:')));
    });

    test('sits between the current issue and the encyclopedia', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(stableId: 'heap_growing'),
        session: session,
      );
      final current = prompt.indexOf('## Current Issue');
      final block = prompt.indexOf('## Session');
      final encyclopedia = prompt.indexOf('## Encyclopedia Knowledge');
      expect(current, lessThan(block));
      expect(block, lessThan(encyclopedia));
    });

    test('carries the labelled facts', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(),
        session: session,
      );
      expect(prompt, contains('Current route: /catalog'));
      expect(
        prompt,
        contains('Frame rate: 25 FPS presented, 48 FPS throughput (target 60)'),
      );
      expect(
        prompt,
        contains(
          'Latest frame verdict: build: Build scope took 22 ms [correlated]',
        ),
      );
      expect(
        prompt,
        contains('Active issues: 12 (2 critical, 9 warning, 1 ok)'),
      );
      expect(prompt, contains('Hidden by user: 3'));
      expect(prompt, contains('Build: debug'));
      expect(prompt, contains('Connection: correlated'));
      expect(prompt, contains('Platform: iOS'));
      // The issue has no route, so the issue section's label stays out.
      expect(prompt, isNot(contains('\nRoute:')));
      expect(prompt, isNot(contains('more)')));
    });

    test('a long verdict reason is cut', () {
      final long = AiSessionContext(
        verdictPhase: PipelinePhase.raster,
        verdictReason: 'x' * 400,
      ).render();
      final line = long
          .split('\n')
          .firstWhere((l) => l.startsWith('Latest frame verdict'));
      expect(line.length, lessThan(AiSessionContext.maxReasonLength + 40));
    });

    test('a verdict reason keeps its first line, without Related', () {
      final rendered = const AiSessionContext(
        verdictPhase: PipelinePhase.build,
        verdictReason:
            'Build   phase took\t22 ms Related: Hidden title\n'
            'Related: Hidden title\nMore detail',
      ).render();
      expect(rendered, isNot(contains('Hidden title')));
      expect(rendered, isNot(contains('More detail')));
      expect(
        rendered,
        contains('Latest frame verdict: build: Build phase took 22 ms\n'),
      );
      expect(
        AiSessionContext.summarizeReason('Slow raster\nRelated: Secret'),
        'Slow raster',
      );
      expect(AiSessionContext.summarizeReason('Related: Secret'), isEmpty);
    });

    test('the caption names route, FPS capped at the target, and count', () {
      expect(session.caption(), 'Context: /catalog · 48 FPS · 12 issues');
      expect(
        const AiSessionContext(throughputFps: 118, fpsTarget: 60).caption(),
        'Context: no route yet · 60 FPS · 0 issues',
      );
    });
  });
}
