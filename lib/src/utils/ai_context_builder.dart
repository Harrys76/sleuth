import '../models/performance_issue.dart';
import 'issue_explanation_builder.dart';

/// Builds AI system prompts from issue context and generates starter questions.
///
/// This is the core value-add of the AI chat feature: assembling rich context
/// from the detected issue, encyclopedia knowledge, and session state into a
/// prompt that makes any AI model's response dramatically more useful than
/// generic Flutter performance advice.
class AiContextBuilder {
  AiContextBuilder._();

  /// Builds a system prompt from the focus [issue] and optional [allIssues].
  ///
  /// Budget target: ~2000 tokens. Sections are prioritized:
  /// 1. Role preamble
  /// 2. Focus issue full context
  /// 3. Encyclopedia knowledge for focus issue
  /// 4. Other active issues (max 5, one-line each)
  /// 5. Response instructions
  static String buildSystemPrompt({
    required PerformanceIssue issue,
    List<PerformanceIssue> allIssues = const [],
  }) {
    final buf = StringBuffer();

    // 1. Role preamble
    buf.writeln('You are a Flutter performance expert helping a developer '
        'investigate a specific issue detected by Widget Watchdog, a runtime '
        'performance diagnostics tool.');
    buf.writeln();

    // 2. Focus issue
    buf.writeln('## Current Issue');
    buf.writeln('Title: ${issue.title}');
    buf.writeln('Severity: ${issue.severity.name}');
    buf.writeln('Category: ${issue.category.name}');
    buf.writeln('Confidence: ${issue.confidence.name}');
    buf.writeln('Detail: ${issue.detail}');
    buf.writeln('Suggested fix: ${issue.fixHint}');
    if (issue.widgetName != null) {
      buf.writeln('Widget: ${issue.widgetName}');
    }
    if (issue.routeName != null) {
      buf.writeln('Route: ${issue.routeName}');
    }
    if (issue.ancestorChain != null) {
      buf.writeln('Ancestor chain: ${issue.ancestorChain}');
    }
    if (issue.interactionContext != null) {
      buf.writeln('User was: ${issue.interactionContext!.name} when detected');
    }
    if (issue.observationSource != null) {
      buf.writeln('Observation source: ${issue.observationSource!.name}');
    }
    if (issue.fixEffort != null) {
      buf.writeln('Estimated fix effort: ${issue.fixEffort!.name}');
    }
    if (issue.rootCauseId != null) {
      buf.writeln('Root cause issue: ${issue.rootCauseId}');
    }
    if (issue.downstreamIds != null && issue.downstreamIds!.isNotEmpty) {
      buf.writeln('Downstream effects: ${issue.downstreamIds!.join(', ')}');
    }
    buf.writeln();

    // 3. Encyclopedia knowledge
    final explanation = IssueExplanationBuilder.explain(issue.stableId);
    if (explanation != null) {
      buf.writeln('## Encyclopedia Knowledge');
      buf.writeln('What it is: ${explanation.whatItIs}');
      if (explanation.readingTheData != null) {
        buf.writeln('Reading the data: ${explanation.readingTheData}');
      }
      buf.writeln('Why it matters: ${explanation.whyItMatters}');
      buf.writeln('How to fix: ${explanation.howToFix}');
      if (explanation.whenToIgnore != null) {
        buf.writeln('When to ignore: ${explanation.whenToIgnore}');
      }
      buf.writeln();
    }

    // 4. Other active issues (max 5)
    final otherIssues = allIssues
        .where((i) => i.stableId != issue.stableId)
        .toList()
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
    if (otherIssues.isNotEmpty) {
      final capped = otherIssues.take(5);
      buf.writeln('## Other Active Issues');
      for (final other in capped) {
        buf.writeln(
            '- ${other.title} (${other.severity.name}, ${other.category.name})');
      }
      if (otherIssues.length > 5) {
        buf.writeln('- ...and ${otherIssues.length - 5} more');
      }
      buf.writeln();
    }

    // 5. Instructions
    buf.writeln('## Instructions');
    buf.writeln('Answer concisely. Reference the specific metrics and '
        'values shown in the issue detail. Suggest concrete code changes '
        'when possible. If the developer asks about something outside your '
        'knowledge, say so rather than guessing.');

    return buf.toString();
  }

  /// Returns 2-3 contextual starter questions based on the issue.
  ///
  /// Questions are personalized with [PerformanceIssue.widgetName] when
  /// available, making them feel specific rather than generic.
  static List<String> starterQuestions(PerformanceIssue issue) {
    final widget = issue.widgetName ?? 'this widget';

    switch (issue.category) {
      case IssueCategory.build:
        return [
          'Why is $widget rebuilding so often?',
          'How do I reduce the rebuild scope?',
          'Should I extract a child widget here?',
        ];
      case IssueCategory.layout:
        return [
          'What makes this layout expensive?',
          'How can I simplify the layout tree?',
        ];
      case IssueCategory.paint:
        return [
          'What is causing excessive repaints?',
          'Should I add a RepaintBoundary here?',
          'How do I isolate the painting cost?',
        ];
      case IssueCategory.raster:
        return [
          'What is making the GPU work hard?',
          'How can I reduce rasterization cost?',
          'Should I simplify the visual effects?',
        ];
      case IssueCategory.memory:
        return [
          'What is causing high memory usage?',
          'Which allocations should I investigate?',
          'How do I find memory leaks?',
        ];
      case IssueCategory.network:
        return [
          'Is this request pattern normal?',
          'How can I reduce the payload size?',
          'Should I add caching here?',
        ];
      case IssueCategory.font:
        return [
          'Are all these fonts necessary?',
          'How do I reduce font loading impact?',
        ];
      case IssueCategory.channel:
        return [
          'Why are there so many platform calls?',
          'Can I batch these channel invocations?',
          'Is this call frequency expected?',
        ];
    }
  }
}
