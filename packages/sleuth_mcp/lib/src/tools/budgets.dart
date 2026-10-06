import '../bridge/vm_bridge.dart';
import '../mcp/mcp_types.dart';
import 'launch_mode_advisory.dart';

/// `check_budgets` default for `minFps`, the same as `sleuth_check --min-fps`.
const int defaultMinFps = 55;

/// `check_budgets` default for `maxIssues`, the same as
/// `sleuth_check --max-issues`. It sets no practical limit.
const int defaultMaxIssues = 999999;

/// `check_budgets` default for `maxCriticalIssues`, the same as
/// `sleuth_check --max-critical-issues`.
const int defaultMaxCriticalIssues = 0;

/// The snapshot sections [evaluateBudgets] reads. It also reads
/// `isVmConnected`, a metadata key that every snapshot carries.
const List<String> budgetSnapshotSections = [
  'currentIssues',
  'frameStatsSummary',
];

/// `ext.sleuth.snapshot` args for a budget check: only
/// [budgetSnapshotSections], so a long session does not ship its per-frame
/// and raw sample data, and no `maxIssueCount`, because a capped issue list
/// would under-count. An app older than sleuth 0.35 ignores the args and
/// returns the full snapshot, which the evaluator reads the same way.
final Map<String, String> budgetSnapshotArgs = Map.unmodifiable({
  'sections': budgetSnapshotSections.join(','),
});

/// Evaluate live snapshot against FPS / issue-count budgets. Returns a
/// `{passed, violations, observed}` shape. Pure data — no exit code
/// (sidecar is long-running stdio; CI gate is `sleuth_check` binary).
/// An omitted threshold takes the `sleuth_check` default: [defaultMinFps],
/// [defaultMaxIssues] and [defaultMaxCriticalIssues].
///
/// Schema-drift behaviour: this tool consumes `isVmConnected`,
/// `currentIssues[].severity` and `frameStatsSummary.averageFps |
/// actualFps`. If those fields are missing or malformed the tool returns
/// an error envelope rather than silently treating the input as
/// zero-issue / null-fps / full coverage.
Future<Object> checkBudgetsHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  final minFps = args['minFps'] ?? defaultMinFps;
  final maxIssues = args['maxIssues'] ?? defaultMaxIssues;
  final maxCriticalIssues =
      args['maxCriticalIssues'] ?? defaultMaxCriticalIssues;
  if (minFps is! num) {
    return ToolCallResult.text('minFps must be number', isError: true);
  }
  if (maxIssues is! int) {
    return ToolCallResult.text('maxIssues must be integer', isError: true);
  }
  if (maxCriticalIssues is! int) {
    return ToolCallResult.text(
      'maxCriticalIssues must be integer',
      isError: true,
    );
  }

  final envelope = await bridge.callExtension(
    'ext.sleuth.snapshot',
    args: budgetSnapshotArgs,
  );
  final data = envelope['data'];
  if (data is! Map<String, Object?>) {
    return ToolCallResult.text(
      'snapshot envelope had no data field',
      isError: true,
    );
  }
  return evaluateBudgets(
    snapshot: data,
    minFps: minFps.toDouble(),
    maxIssues: maxIssues,
    maxCriticalIssues: maxCriticalIssues,
  );
}

/// Evaluate budgets against a snapshot payload. Exposed for `sleuth_check`
/// one-shot binary reuse. Returns either a budget result map or a
/// `ToolCallResult` error envelope on schema drift, a capped issue list, or
/// `coverage_degraded` when the snapshot's `isVmConnected` is false or
/// unreadable.
Object evaluateBudgets({
  required Map<String, Object?> snapshot,
  required double minFps,
  required int maxIssues,
  required int maxCriticalIssues,
}) {
  // A maxIssueCount-capped snapshot carries a truncated currentIssues list;
  // counting it would under-report and let a failing budget pass. Refuse.
  // (maxRouteCount doesn't affect budgets — routes aren't counted here.)
  final limits = snapshot['_projectionLimits'];
  if (limits is Map && limits['maxIssueCount'] != null) {
    return ToolCallResult.text(
      'arg_capped_issues_unbudgetable: this snapshot was projected with '
      'maxIssueCount=${limits['maxIssueCount']}, so its issue list is '
      'truncated and budget counts would be wrong. Re-capture get_snapshot '
      'without maxIssueCount.',
      isError: true,
    );
  }

  // Without a VM service link the VM-only detectors never ran, so a pass
  // would vouch for memory, CPU and repaint behaviour nobody observed.
  // Basic connection mode with the VM connected (no VM-tier frame verdict
  // yet) reports isVmConnected true and passes through.
  final vmConnected = snapshot['isVmConnected'];
  if (vmConnected != true) {
    final reading = vmConnected is bool
        ? 'reports isVmConnected=false'
        : 'has no boolean isVmConnected';
    return ToolCallResult.text(
      'coverage_degraded: the snapshot $reading, so the VM-only detectors '
      '($vmOnlyStableIds) did not run and a pass would not cover memory, '
      'CPU or repaint issues. Relaunch the app so Sleuth connects to the VM '
      'service (`flutter run --profile --no-dds`), then re-run the check.',
      isError: true,
    );
  }

  final issues = snapshot['currentIssues'];
  if (issues == null) {
    return _missingSection(snapshot, 'currentIssues');
  }
  if (issues is! List) {
    return ToolCallResult.text(
      'snapshot currentIssues must be List, got ${issues.runtimeType}',
      isError: true,
    );
  }
  int issueCount = 0;
  int criticalCount = 0;
  for (var i = 0; i < issues.length; i++) {
    final entry = issues[i];
    if (entry is! Map<String, Object?>) {
      return ToolCallResult.text(
        'snapshot currentIssues[$i] must be Map, got ${entry.runtimeType}',
        isError: true,
      );
    }
    final sev = entry['severity'];
    if (sev is! String) {
      return ToolCallResult.text(
        'snapshot currentIssues[$i] missing required severity '
        '(got ${sev.runtimeType})',
        isError: true,
      );
    }
    issueCount++;
    if (sev.toLowerCase() == 'critical') {
      criticalCount++;
    }
  }
  final summary = snapshot['frameStatsSummary'];
  if (summary == null) {
    return _missingSection(snapshot, 'frameStatsSummary');
  }
  if (summary is! Map<String, Object?>) {
    return ToolCallResult.text(
      'snapshot frameStatsSummary must be Map, got ${summary.runtimeType}',
      isError: true,
    );
  }
  final avg = summary['averageFps'];
  final actual = summary['actualFps'];
  if (avg == null && actual == null) {
    return ToolCallResult.text(
      'snapshot frameStatsSummary missing both averageFps and actualFps '
      '— schema drift',
      isError: true,
    );
  }
  final fpsRaw = avg ?? actual;
  if (fpsRaw is! num) {
    return ToolCallResult.text(
      'snapshot frameStatsSummary.averageFps/actualFps must be num, '
      'got ${fpsRaw.runtimeType}',
      isError: true,
    );
  }
  final observedFps = fpsRaw.toDouble();
  final violations = <Map<String, Object?>>[];
  if (observedFps < minFps) {
    violations.add({
      'budget': 'minFps',
      'expected': minFps,
      'observed': observedFps,
    });
  }
  if (issueCount > maxIssues) {
    violations.add({
      'budget': 'maxIssues',
      'expected': maxIssues,
      'observed': issueCount,
    });
  }
  if (criticalCount > maxCriticalIssues) {
    violations.add({
      'budget': 'maxCriticalIssues',
      'expected': maxCriticalIssues,
      'observed': criticalCount,
    });
  }
  return <String, Object?>{
    'passed': violations.isEmpty,
    'violations': violations,
    'observed': <String, Object?>{
      'fps': observedFps,
      'issueCount': issueCount,
      'criticalCount': criticalCount,
    },
  };
}

/// A required section is absent. When the snapshot carries projection
/// metadata, this is a caller error (they projected the section away),
/// so return the typed `arg_missing_required_section`. Otherwise it's
/// genuine schema drift.
ToolCallResult _missingSection(Map<String, Object?> snapshot, String section) {
  final projected = snapshot.containsKey('_projectedSections');
  if (projected) {
    return ToolCallResult.text(
      'arg_missing_required_section: budgets need "$section" but the '
      'snapshot was projected without it — re-capture get_snapshot '
      'including "$section" (or omit `sections` for the full payload)',
      isError: true,
    );
  }
  return ToolCallResult.text(
    'snapshot missing required $section',
    isError: true,
  );
}
