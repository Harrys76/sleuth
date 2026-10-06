import '../mcp/mcp_types.dart';

/// A guided-diagnostic prompt: a static [descriptor] + the user-message [text]
/// that tells an MCP client's model to chain Sleuth tools. [usesTools] lists
/// the tool names [text] references; a test cross-checks it against the live
/// tool registry both ways so a renamed tool can't silently rot the prose.
class DiagnosticPrompt {
  const DiagnosticPrompt({
    required this.descriptor,
    required this.usesTools,
    required this.text,
  });

  final Prompt descriptor;
  final Set<String> usesTools;
  final String text;

  /// MCP `prompts/get` message sequence — a single user turn carrying [text].
  List<Map<String, Object?>> messages() => [
    {
      'role': 'user',
      'content': {'type': 'text', 'text': text},
    },
  ];
}

const _triagePerformance = DiagnosticPrompt(
  descriptor: Prompt(
    name: 'triage_performance',
    description:
        'Investigate a Flutter app\'s current runtime performance and report '
        'the top problems with concrete fixes.',
  ),
  usesTools: {'get_issues', 'get_snapshot', 'explain_issue'},
  text:
      'You are triaging a Flutter app\'s runtime performance using the '
      'Sleuth MCP tools. Work through these steps:\n'
      '1. Call `get_issues` for the current issues. They arrive ranked, '
      'most important first.\n'
      '2. Call `get_snapshot` with sections ["frameStatsSummary", '
      '"sessionSummary", "recurrenceTrends", "routeSessions"] for frame '
      'stats, the frame-time histogram, the memory trend, issues that are '
      'getting worse, and the health score of each route. Leave out '
      'currentIssues, because step 1 already returned the issues.\n'
      '3. For the most severe issue, call `explain_issue` with its stableId '
      'to get the cause and fix guidance.\n'
      'Then summarize the top problems, their likely causes, the '
      'worst-scoring route, and concrete fixes, ordered by severity.',
);

const _auditMemory = DiagnosticPrompt(
  descriptor: Prompt(
    name: 'audit_memory',
    description:
        'Investigate memory growth and leaks in a Flutter app and recommend '
        'fixes.',
  ),
  usesTools: {'get_issues', 'explain_issue'},
  text:
      'You are auditing a Flutter app for memory growth and leaks using the '
      'Sleuth MCP tools. Work through these steps:\n'
      '1. Call `get_issues` and keep only the memory issues: heap growth, '
      'retained streams, and tracked resources that live too long or have '
      'too many live instances.\n'
      '2. For each memory issue, call `explain_issue` with its stableId for '
      'the cause and fix.\n'
      'Then recommend concrete fixes, such as disposing controllers and '
      'streams, bounding caches and untracking resources. Ignore frame and '
      'jank issues.',
);

const _releaseCheck = DiagnosticPrompt(
  descriptor: Prompt(
    name: 'release_check',
    description:
        'Run a pre-release performance gate and report a PASS, FAIL, or NOT '
        'RUN verdict.',
  ),
  usesTools: {'check_budgets', 'get_issues'},
  text:
      'You are running a pre-release performance gate on a Flutter app using '
      'the Sleuth MCP tools. Work through these steps:\n'
      '1. Find out the team\'s budget thresholds: the minimum FPS, the most '
      'issues and the most critical issues allowed. If you do not already '
      'know them, ask the user. Never guess them.\n'
      '2. Call `check_budgets` with those thresholds. If it returns an error '
      'instead of a result, the gate did NOT RUN. For example, '
      '`coverage_degraded` means the app has no VM service link, so the '
      'memory, CPU and repaint detectors never ran. Report NOT RUN with the '
      'error\'s remedy and stop. Never report PASS in that case.\n'
      '3. Call `get_issues` and list any critical-severity issues.\n'
      'Then report a clear PASS or FAIL verdict. Name the budget violations '
      'and the critical issues to resolve before release.',
);

/// The locked set of guided-diagnostic prompts, keyed by name.
final Map<String, DiagnosticPrompt> builtInPrompts = {
  for (final p in <DiagnosticPrompt>[
    _triagePerformance,
    _auditMemory,
    _releaseCheck,
  ])
    p.descriptor.name: p,
};
