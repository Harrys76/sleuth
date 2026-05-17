import '../bridge/vm_bridge.dart';
import '../mcp/mcp_types.dart';

/// Diff two `SessionSnapshot` `data` payloads. Pure client-side; no
/// bridge call. Returns `{added, removed, elevatedSeverity, fpsDelta}`.
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
  final beforeIssues = _issueMap(before);
  final afterIssues = _issueMap(after);
  final beforeIds = beforeIssues.keys.toSet();
  final afterIds = afterIssues.keys.toSet();

  final added = afterIds.difference(beforeIds).toList()..sort();
  final removed = beforeIds.difference(afterIds).toList()..sort();
  final elevated = <Map<String, Object?>>[];
  for (final id in beforeIds.intersection(afterIds)) {
    final beforeSev = beforeIssues[id]?['severity'];
    final afterSev = afterIssues[id]?['severity'];
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

  final beforeFps = _avgFps(before);
  final afterFps = _avgFps(after);
  final fpsDelta =
      (beforeFps != null && afterFps != null) ? afterFps - beforeFps : null;

  return <String, Object?>{
    'added': added,
    'removed': removed,
    'elevatedSeverity': elevated,
    'fpsDelta': fpsDelta,
    'beforeFps': beforeFps,
    'afterFps': afterFps,
  };
}

Map<String, Map<String, Object?>> _issueMap(Map<String, Object?> snapshot) {
  final result = <String, Map<String, Object?>>{};
  final list = snapshot['currentIssues'];
  if (list is! List) return result;
  for (final entry in list) {
    if (entry is! Map<String, Object?>) continue;
    final id = entry['stableId'];
    if (id is String) result[id] = entry;
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

double? _avgFps(Map<String, Object?> snapshot) {
  final summary = snapshot['frameStatsSummary'];
  if (summary is! Map<String, Object?>) return null;
  final fps = summary['averageFps'] ?? summary['actualFps'];
  if (fps is num) return fps.toDouble();
  return null;
}
