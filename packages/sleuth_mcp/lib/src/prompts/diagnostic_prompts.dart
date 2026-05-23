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
  usesTools: {
    'get_snapshot',
    'get_issues',
    'explain_issue',
    'get_route_health'
  },
  text: 'You are triaging a Flutter app\'s runtime performance using the '
      'Sleuth MCP tools. Work through these steps:\n'
      '1. Call `get_snapshot` for the current picture — issues, frame stats, '
      'route history.\n'
      '2. Read the highest-priority entries from `get_issues` (they arrive '
      'already ranked).\n'
      '3. For the most severe issue, call `explain_issue` with its stableId to '
      'get the cause and fix guidance.\n'
      '4. Call `get_route_health` to find the worst-scoring route.\n'
      'Then summarize the top problems, their likely causes, and concrete '
      'fixes — ordered by severity.',
);

const _auditMemory = DiagnosticPrompt(
  descriptor: Prompt(
    name: 'audit_memory',
    description:
        'Investigate memory growth and leaks in a Flutter app and recommend '
        'remediations.',
  ),
  usesTools: {'get_issues', 'explain_issue'},
  text: 'You are auditing a Flutter app for memory growth and leaks using the '
      'Sleuth MCP tools. Work through these steps:\n'
      '1. Call `get_issues` and focus only on the memory class — heap growth, '
      'retained streams, and long-lived or over-concurrent tracked '
      'resources.\n'
      '2. For each memory issue, call `explain_issue` with its stableId for '
      'the cause and fix.\n'
      'Then recommend concrete remediations (dispose controllers and streams, '
      'bound caches, untrack resources). Ignore frame and jank issues.',
);

const _releaseCheck = DiagnosticPrompt(
  descriptor: Prompt(
    name: 'release_check',
    description:
        'Run a pre-release performance gate and report a PASS or FAIL verdict.',
  ),
  usesTools: {'check_budgets', 'get_issues'},
  text: 'You are running a pre-release performance gate on a Flutter app using '
      'the Sleuth MCP tools. Work through these steps:\n'
      '1. Determine the team\'s budget thresholds (minimum FPS, max issues, '
      'max critical issues). If you do not already know them, ask the user '
      'for them — never guess.\n'
      '2. Call `check_budgets` with those thresholds.\n'
      '3. Call `get_issues` and list any critical-severity issues.\n'
      'Then report a clear PASS or FAIL verdict, naming the specific budget '
      'violations and critical issues that must be resolved before release.',
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
