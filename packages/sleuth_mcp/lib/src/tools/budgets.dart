import '../bridge/vm_bridge.dart';
import '../mcp/mcp_types.dart';

/// Evaluate live snapshot against FPS / issue-count budgets. Returns a
/// `{passed, violations, observed}` shape. Pure data — no exit code
/// (sidecar is long-running stdio; CI gate is `sleuth_check` binary).
Future<Object> checkBudgetsHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  final minFps = args['minFps'];
  final maxIssues = args['maxIssues'];
  final maxCriticalIssues = args['maxCriticalIssues'];
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

  final envelope = await bridge.callExtension('ext.sleuth.snapshot');
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
/// one-shot binary reuse.
Map<String, Object?> evaluateBudgets({
  required Map<String, Object?> snapshot,
  required double minFps,
  required int maxIssues,
  required int maxCriticalIssues,
}) {
  final issues = snapshot['currentIssues'];
  int issueCount = 0;
  int criticalCount = 0;
  if (issues is List) {
    for (final i in issues) {
      if (i is! Map<String, Object?>) continue;
      issueCount++;
      final sev = i['severity'];
      if (sev is String && sev.toLowerCase() == 'critical') {
        criticalCount++;
      }
    }
  }
  double? observedFps;
  final summary = snapshot['frameStatsSummary'];
  if (summary is Map<String, Object?>) {
    final fps = summary['averageFps'] ?? summary['actualFps'];
    if (fps is num) observedFps = fps.toDouble();
  }
  final violations = <Map<String, Object?>>[];
  if (observedFps != null && observedFps < minFps) {
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
  return {
    'passed': violations.isEmpty,
    'violations': violations,
    'observed': {
      'fps': observedFps,
      'issueCount': issueCount,
      'criticalCount': criticalCount,
    },
  };
}
