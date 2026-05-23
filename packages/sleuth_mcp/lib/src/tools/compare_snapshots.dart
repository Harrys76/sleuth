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

  // Reject when either side capped its issue list: an issue that merely
  // left the top-N window is indistinguishable from one that resolved, so
  // added/removed would lie even when both caps match. (maxRouteCount
  // doesn't affect the issue diff.)
  final cappedReject = _cappedIssuesReject(before, after);
  if (cappedReject != null) return cappedReject;

  // Reject diffing differently-projected snapshots: a section or cap
  // present in one but not the other makes "removed"/"added" lie (the
  // entry was filtered, not actually gone). Compared as a Set so list
  // ordering of `_projectedSections` is irrelevant.
  final mismatch = _projectionMismatch(before, after);
  if (mismatch != null) return mismatch;

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

/// Returns an error envelope when either snapshot capped its issue list
/// (`_projectionLimits.maxIssueCount`), else null. A truncated top-N
/// window can't be diffed: an issue dropping out of the window looks
/// identical to one that resolved.
ToolCallResult? _cappedIssuesReject(
  Map<String, Object?> before,
  Map<String, Object?> after,
) {
  bool capped(Map<String, Object?> s) {
    final limits = s['_projectionLimits'];
    return limits is Map && limits['maxIssueCount'] != null;
  }

  if (capped(before) || capped(after)) {
    return ToolCallResult.text(
      'arg_capped_issues_uncomparable: one or both snapshots were projected '
      'with maxIssueCount, so an issue leaving the top-N window is '
      'indistinguishable from one that resolved. Re-capture both without '
      'maxIssueCount.',
      isError: true,
    );
  }
  return null;
}

/// Returns a `ToolCallResult` error envelope when the two snapshots
/// were projected differently (different section set or different
/// caps), else null. Unprojected snapshots (both metadata absent)
/// always compare cleanly.
ToolCallResult? _projectionMismatch(
  Map<String, Object?> before,
  Map<String, Object?> after,
) {
  Set<String> sections(Map<String, Object?> s) {
    final raw = s['_projectedSections'];
    return raw is List ? raw.map((e) => '$e').toSet() : const <String>{};
  }

  String limits(Map<String, Object?> s) {
    final raw = s['_projectionLimits'];
    if (raw is! Map) return '';
    final mi = raw['maxIssueCount'];
    final mr = raw['maxRouteCount'];
    return 'i=$mi,r=$mr';
  }

  final bSec = sections(before);
  final aSec = sections(after);
  if (!_setEquals(bSec, aSec)) {
    return ToolCallResult.text(
      'arg_section_mismatch: snapshots were projected to different '
      'sections (before=${(bSec.toList()..sort())}, '
      'after=${(aSec.toList()..sort())}); cannot diff — re-capture both '
      'with the same `sections`',
      isError: true,
    );
  }
  if (limits(before) != limits(after)) {
    return ToolCallResult.text(
      'arg_section_mismatch: snapshots were projected with different '
      'pagination limits; cannot diff — re-capture both with the same '
      '`maxIssueCount`/`maxRouteCount`',
      isError: true,
    );
  }
  return null;
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

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
