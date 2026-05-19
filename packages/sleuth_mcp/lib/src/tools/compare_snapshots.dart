import '../bridge/vm_bridge.dart';
import '../mcp/mcp_types.dart';

/// Diff two `SessionSnapshot` `data` payloads. Pure client-side; no
/// bridge call. Returns `{added, removed, elevatedSeverity, fpsDelta}`.
///
/// Schema-drift behaviour: this tool consumes `currentIssues[].stableId`,
/// `currentIssues[].severity`, and `frameStatsSummary.averageFps |
/// actualFps`. If those nested fields are missing or malformed the tool
/// returns an error envelope rather than silently dropping entries —
/// otherwise a rename in the snapshot schema would surface as an empty
/// diff and look like a clean comparison.
Future<Object> compareSnapshotsHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  final before = args['before'];
  final after = args['after'];
  if (before is! Map<String, Object?>) {
    return ToolCallResult.text(
      'arg "before" must be object (SessionSnapshot data)',
      isError: true,
    );
  }
  if (after is! Map<String, Object?>) {
    return ToolCallResult.text(
      'arg "after" must be object (SessionSnapshot data)',
      isError: true,
    );
  }
  final beforeIssues = _issueMap(before, 'before');
  if (beforeIssues is ToolCallResult) return beforeIssues;
  final afterIssues = _issueMap(after, 'after');
  if (afterIssues is ToolCallResult) return afterIssues;
  final beforeIssuesMap = beforeIssues as Map<String, Map<String, Object?>>;
  final afterIssuesMap = afterIssues as Map<String, Map<String, Object?>>;
  final beforeIds = beforeIssuesMap.keys.toSet();
  final afterIds = afterIssuesMap.keys.toSet();

  final added = afterIds.difference(beforeIds).toList()..sort();
  final removed = beforeIds.difference(afterIds).toList()..sort();
  final elevated = <Map<String, Object?>>[];
  for (final id in beforeIds.intersection(afterIds)) {
    final beforeSev = beforeIssuesMap[id]?['severity'];
    final afterSev = afterIssuesMap[id]?['severity'];
    if (beforeSev != afterSev &&
        _severityRank(afterSev) > _severityRank(beforeSev)) {
      elevated.add({
        'stableId': id,
        'before': beforeSev,
        'after': afterSev,
      });
    }
  }
  elevated.sort(
      (a, b) => (a['stableId'] as String).compareTo(b['stableId'] as String));

  final beforeFps = _avgFps(before, 'before');
  if (beforeFps is ToolCallResult) return beforeFps;
  final afterFps = _avgFps(after, 'after');
  if (afterFps is ToolCallResult) return afterFps;
  final beforeFpsDouble = beforeFps as double?;
  final afterFpsDouble = afterFps as double?;
  final fpsDelta = (beforeFpsDouble != null && afterFpsDouble != null)
      ? afterFpsDouble - beforeFpsDouble
      : null;

  return <String, Object?>{
    'added': added,
    'removed': removed,
    'elevatedSeverity': elevated,
    'fpsDelta': fpsDelta,
    'beforeFps': beforeFpsDouble,
    'afterFps': afterFpsDouble,
  };
}

/// Parse `currentIssues` from a snapshot payload. Returns either a
/// `Map<stableId, issueMap>` or a `ToolCallResult` error envelope
/// describing the drift.
Object _issueMap(Map<String, Object?> snapshot, String label) {
  final list = snapshot['currentIssues'];
  if (list == null) {
    return ToolCallResult.text(
      'snapshot "$label" missing required currentIssues',
      isError: true,
    );
  }
  if (list is! List) {
    return ToolCallResult.text(
      'snapshot "$label" currentIssues must be List, got ${list.runtimeType}',
      isError: true,
    );
  }
  final result = <String, Map<String, Object?>>{};
  for (var i = 0; i < list.length; i++) {
    final entry = list[i];
    if (entry is! Map<String, Object?>) {
      return ToolCallResult.text(
        'snapshot "$label" currentIssues[$i] must be Map, '
        'got ${entry.runtimeType}',
        isError: true,
      );
    }
    final id = entry['stableId'];
    final sev = entry['severity'];
    if (id is! String) {
      return ToolCallResult.text(
        'snapshot "$label" currentIssues[$i] missing required '
        'stableId (got ${id.runtimeType})',
        isError: true,
      );
    }
    if (sev is! String) {
      return ToolCallResult.text(
        'snapshot "$label" currentIssues[$i] (stableId=$id) missing '
        'required severity (got ${sev.runtimeType})',
        isError: true,
      );
    }
    result[id] = entry;
  }
  return result;
}

int _severityRank(Object? severity) {
  if (severity is! String) return 0;
  switch (severity.toLowerCase()) {
    case 'critical':
      return 3;
    case 'warning':
      return 2;
    case 'ok':
      return 1;
    default:
      return 0;
  }
}

/// Parse `frameStatsSummary.{averageFps|actualFps}` from a snapshot.
/// Returns either a nullable double or a `ToolCallResult` error
/// envelope. `frameStatsSummary` itself is required at the snapshot
/// top level (schema); a missing key indicates drift. Empty-summary or
/// summary-without-fps-fields is also drift — both fields cannot be
/// simultaneously absent.
Object _avgFps(Map<String, Object?> snapshot, String label) {
  final summary = snapshot['frameStatsSummary'];
  if (summary == null) {
    return ToolCallResult.text(
      'snapshot "$label" missing required frameStatsSummary',
      isError: true,
    );
  }
  if (summary is! Map<String, Object?>) {
    return ToolCallResult.text(
      'snapshot "$label" frameStatsSummary must be Map, '
      'got ${summary.runtimeType}',
      isError: true,
    );
  }
  final avg = summary['averageFps'];
  final actual = summary['actualFps'];
  if (avg == null && actual == null) {
    return ToolCallResult.text(
      'snapshot "$label" frameStatsSummary missing both averageFps '
      'and actualFps — schema drift',
      isError: true,
    );
  }
  final fps = avg ?? actual;
  if (fps is num) return fps.toDouble();
  return ToolCallResult.text(
    'snapshot "$label" frameStatsSummary.averageFps/actualFps must be '
    'num, got ${fps.runtimeType}',
    isError: true,
  );
}
