import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/utils/ai_context_builder.dart';

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
    String? rootCauseId,
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
      rootCauseId: rootCauseId,
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
        (i) => makeIssue(
          title: 'Issue $i',
          stableId: 'issue_$i',
        ),
      );
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(stableId: 'focus_issue'),
        allIssues: [makeIssue(stableId: 'focus_issue'), ...others],
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

    test('includes downstream and rootCause when present', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(
          rootCauseId: 'rebuild_activity',
          downstreamIds: ['gc_pressure', 'heap_growing'],
        ),
      );
      expect(prompt, contains('Root cause issue: rebuild_activity'));
      expect(prompt, contains('gc_pressure, heap_growing'));
    });

    test('includes response instructions', () {
      final prompt = AiContextBuilder.buildSystemPrompt(
        issue: makeIssue(),
      );
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
        expect(questions.length, inInclusiveRange(2, 3),
            reason: 'Wrong count for $category');
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
}
