import '../models/performance_issue.dart';
import 'ai_session_context.dart';
import 'issue_explanation_builder.dart';

/// Builds AI system prompts from issue context and generates starter questions.
///
/// This is the core value-add of the AI chat feature: assembling rich context
/// from the detected issue, encyclopedia knowledge, and session state into a
/// prompt that makes any AI model's response dramatically more useful than
/// generic Flutter performance advice.
class AiContextBuilder {
  AiContextBuilder._();

  /// Most root cause ids named in the prompt.
  static const int _maxCauses = 5;

  /// Builds a system prompt from the focus [issue] and optional [allIssues].
  ///
  /// Budget target: ~2000 tokens. Sections are prioritized:
  /// 1. Role preamble
  /// 2. Focus issue full context
  /// 3. Session state ([session], when given)
  /// 4. Encyclopedia knowledge for focus issue
  /// 5. Other active issues (max 5, one-line each)
  /// 6. Response instructions
  ///
  /// [allIssues] holds the issues the prompt may name: a root cause or
  /// downstream id of [issue] is named only when it is one of theirs (or
  /// [issue]'s own); the rest are counted. A parametric id carries the
  /// app's names (`tracked_resource_concurrent:PaymentToken`), and an
  /// issue the user hid is left out of [allIssues]. Routes lose their
  /// query and fragment ([AiSessionContext.promptRoute]).
  static String buildSystemPrompt({
    required PerformanceIssue issue,
    List<PerformanceIssue> allIssues = const [],
    AiSessionContext? session,
  }) {
    final routeName = issue.routeName;
    if (routeName != null) {
      final route = AiSessionContext.promptRoute(routeName);
      if (route != routeName) issue = issue.copyWith(routeName: route);
    }
    final buf = StringBuffer();

    // 1. Role preamble
    buf.writeln(
      'You are a Flutter performance expert helping a developer '
      'investigate a specific issue detected by Sleuth, a runtime '
      'performance diagnostics tool.',
    );
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
    if (issue.routeDisplayName != null) {
      buf.writeln('Route: ${issue.routeDisplayName}');
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
    // Related ids are named only for issues the prompt may name; the
    // others (hidden by the user, or no longer active) are counted. The
    // causal graph names an issue by its stable id, else its title.
    final nameable = <String>{
      for (final other in allIssues) other.stableId ?? other.title,
      issue.stableId ?? issue.title,
    };
    final unlisted = <String>{};
    List<String> listed(List<String>? ids) {
      final out = <String>[];
      for (final id in ids ?? const <String>[]) {
        if (nameable.contains(id)) {
          out.add(id);
        } else {
          unlisted.add(id);
        }
      }
      return out;
    }

    final causeIds = listed(issue.rootCauseIds);
    if (causeIds.isNotEmpty) {
      // Every co-firing upstream cause is listed, capped with "(+N more)"
      // so a long fan-in does not flood the prompt.
      final display = causeIds.length <= _maxCauses
          ? causeIds.join(', ')
          : '${causeIds.take(_maxCauses).join(', ')} '
                '(+${causeIds.length - _maxCauses} more)';
      final label = causeIds.length == 1
          ? 'Root cause issue'
          : 'Root cause issues';
      buf.writeln('$label: $display');
    }
    final downstreamIds = listed(issue.downstreamIds);
    if (downstreamIds.isNotEmpty) {
      buf.writeln('Downstream effects: ${downstreamIds.join(', ')}');
    }
    if (unlisted.isNotEmpty) {
      final n = unlisted.length;
      buf.writeln('$n related ${n == 1 ? 'issue' : 'issues'} not listed');
    }
    buf.writeln();

    // 3. Session state
    if (session != null) {
      buf.writeln('## Session');
      buf.write(session.render());
      buf.writeln();
    }

    // 4. Encyclopedia knowledge
    final rawExplanation = IssueExplanationBuilder.explain(issue.stableId);
    final explanation = rawExplanation == null
        ? null
        : IssueExplanationBuilder.substitute(rawExplanation, issue);
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
      if (explanation.relatedIssues != null &&
          explanation.relatedIssues!.isNotEmpty) {
        final names = explanation.relatedIssues!
            .map((id) => IssueExplanationBuilder.explain(id)?.displayName)
            .whereType<String>()
            .toList();
        if (names.isNotEmpty) {
          buf.writeln('Related issues: ${names.join(', ')}');
        }
      }
      buf.writeln();
    }

    // 5. Other active issues (max 5)
    final otherIssues =
        allIssues.where((i) => i.stableId != issue.stableId).toList()
          ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
    if (otherIssues.isNotEmpty) {
      final capped = otherIssues.take(5);
      buf.writeln('## Other Active Issues');
      for (final other in capped) {
        buf.writeln(
          '- ${other.title} (${other.severity.name}, ${other.category.name})',
        );
      }
      if (otherIssues.length > 5) {
        buf.writeln('- ...and ${otherIssues.length - 5} more');
      }
      buf.writeln();
    }

    // 6. Instructions
    buf.writeln('## Instructions');
    buf.writeln(
      'Answer concisely. Reference the specific metrics and '
      'values shown in the issue detail. Suggest concrete code changes '
      'when possible. If the developer asks about something outside your '
      'knowledge, say so rather than guessing.',
    );

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
      case IssueCategory.startup:
        return [
          'Why is my app startup slow?',
          'How do I reduce time-to-first-frame?',
          'What should I defer to after first frame?',
        ];
    }
  }
}
