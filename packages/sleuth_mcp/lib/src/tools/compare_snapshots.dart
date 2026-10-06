import '../bridge/vm_bridge.dart';
import '../mcp/mcp_types.dart';
import '../util/version_lineage.dart';
import 'launch_mode_advisory.dart';

/// Diff two `SessionSnapshot` `data` payloads. Pure client-side; no
/// bridge call. Returns `{added, removed, elevatedSeverity, countChanged,
/// fpsDelta, beforeFps, afterFps}`, plus `coverageWarning` when neither
/// snapshot had a VM service link.
///
/// Issues aggregate per stableId: the highest severity across its
/// occurrences and the occurrence count. A new critical occurrence beside
/// an existing warning with the same stableId reads as an elevation, and
/// a second occurrence as a count change.
///
/// Refuses snapshots from different sleuth lineages (detector ids and
/// defaults change between lineages, so the diff would report
/// instrumentation changes as app changes) and snapshots whose VM
/// coverage differs or is unknown (VM-only detectors report nothing
/// without a VM link, so their issues would read as resolved or new).
///
/// Schema-drift behaviour: this tool consumes `packageVersion`,
/// `isVmConnected`, `currentIssues[].stableId`, `currentIssues[].severity`,
/// and `frameStatsSummary.averageFps | actualFps`. If those fields are
/// missing or malformed the tool returns an error envelope rather than
/// silently dropping entries — otherwise a rename in the snapshot schema
/// would surface as an empty diff and look like a clean comparison.
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

  final lineageReject = _lineageMismatch(before, after);
  if (lineageReject != null) return lineageReject;

  final coverageReject = _coverageMismatch(before, after);
  if (coverageReject != null) return coverageReject;

  final beforeIssues = _issueMap(before, 'before');
  if (beforeIssues is ToolCallResult) return beforeIssues;
  final afterIssues = _issueMap(after, 'after');
  if (afterIssues is ToolCallResult) return afterIssues;
  final beforeIssuesMap = beforeIssues as Map<String, _IssueAggregate>;
  final afterIssuesMap = afterIssues as Map<String, _IssueAggregate>;
  final beforeIds = beforeIssuesMap.keys.toSet();
  final afterIds = afterIssuesMap.keys.toSet();

  final added = afterIds.difference(beforeIds).toList()..sort();
  final removed = beforeIds.difference(afterIds).toList()..sort();
  final elevated = <Map<String, Object?>>[];
  final countChanged = <Map<String, Object?>>[];
  for (final id in beforeIds.intersection(afterIds)) {
    final b = beforeIssuesMap[id]!;
    final a = afterIssuesMap[id]!;
    if (_severityRank(a.severity) > _severityRank(b.severity)) {
      elevated.add({'stableId': id, 'before': b.severity, 'after': a.severity});
    }
    if (a.count != b.count) {
      countChanged.add({'stableId': id, 'before': b.count, 'after': a.count});
    }
  }
  int byStableId(Map<String, Object?> a, Map<String, Object?> b) =>
      (a['stableId'] as String).compareTo(b['stableId'] as String);
  elevated.sort(byStableId);
  countChanged.sort(byStableId);

  final beforeFps = _avgFps(before, 'before');
  if (beforeFps is ToolCallResult) return beforeFps;
  final afterFps = _avgFps(after, 'after');
  if (afterFps is ToolCallResult) return afterFps;
  final beforeFpsDouble = beforeFps as double?;
  final afterFpsDouble = afterFps as double?;
  final fpsDelta = (beforeFpsDouble != null && afterFpsDouble != null)
      ? afterFpsDouble - beforeFpsDouble
      : null;

  final result = <String, Object?>{
    'added': added,
    'removed': removed,
    'elevatedSeverity': elevated,
    'countChanged': countChanged,
    'fpsDelta': fpsDelta,
    'beforeFps': beforeFpsDouble,
    'afterFps': afterFpsDouble,
  };
  // Coverage matched (checked above), so one side speaks for both.
  if (_vmCoverage(before) == false) {
    result['coverageWarning'] = noVmCoverageWarning;
  }
  return result;
}

/// `coverageWarning` text for a diff of two snapshots that both lacked a
/// VM service link.
const String noVmCoverageWarning =
    'vm_detectors_not_observed: neither snapshot had a VM service link, so '
    'VM-only detectors ($vmOnlyStableIds) did not run in either session; '
    'added, removed, elevatedSeverity and countChanged cover frame-timing '
    'and structural detectors only.';

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

/// Returns an `arg_lineage_mismatch` error envelope when the two
/// snapshots' `packageVersion` values fall in different sleuth lineages,
/// or when either is missing or not a semver version, else null. Detector
/// ids and defaults change between lineages (identity-keyed stableIds,
/// opt-in detectors, new detectors), so a cross-lineage diff would report
/// instrumentation changes as app changes.
ToolCallResult? _lineageMismatch(
  Map<String, Object?> before,
  Map<String, Object?> after,
) {
  final beforeVersion = before['packageVersion'];
  final afterVersion = after['packageVersion'];
  for (final (label, raw) in [
    ('before', beforeVersion),
    ('after', afterVersion),
  ]) {
    if (raw is String && versionLineage(raw) != null) continue;
    final got = raw is String
        ? '"$raw"'
        : (raw == null ? 'nothing' : '${raw.runtimeType}');
    return ToolCallResult.text(
      'arg_lineage_mismatch: snapshot "$label" has no valid packageVersion '
      '(got $got), so the two snapshots cannot be shown to come from the '
      'same sleuth lineage. Re-capture both with get_snapshot.',
      isError: true,
    );
  }
  final beforeLineage = versionLineage(beforeVersion as String);
  final afterLineage = versionLineage(afterVersion as String);
  if (beforeLineage != afterLineage) {
    return ToolCallResult.text(
      'arg_lineage_mismatch: snapshots come from different sleuth lineages '
      '(before=$beforeVersion, after=$afterVersion). Detector ids, defaults '
      'and coverage change between lineages, so the diff would report '
      'instrumentation changes as app changes. Re-capture both runs with '
      'the same sleuth version.',
      isError: true,
    );
  }
  return null;
}

/// VM coverage of one snapshot: true with a VM service link, false without
/// one (`isVmConnected` false, or `get_snapshot` stamped a
/// `launchModeAdvisory` on a degraded session), null when `isVmConnected`
/// is missing or not a bool.
bool? _vmCoverage(Map<String, Object?> snapshot) {
  final connected = snapshot['isVmConnected'];
  if (connected is! bool) return null;
  return connected && !snapshot.containsKey('launchModeAdvisory');
}

/// Returns an `arg_coverage_mismatch` error envelope when the snapshots'
/// VM coverage differs or either side's is unknown, else null. VM-only
/// detectors report nothing without a VM link, so their issues would read
/// as resolved (or new) across a coverage change.
ToolCallResult? _coverageMismatch(
  Map<String, Object?> before,
  Map<String, Object?> after,
) {
  final beforeCoverage = _vmCoverage(before);
  final afterCoverage = _vmCoverage(after);
  if (beforeCoverage == null || afterCoverage == null) {
    final label = beforeCoverage == null ? 'before' : 'after';
    return ToolCallResult.text(
      'arg_coverage_mismatch: snapshot "$label" has no boolean '
      'isVmConnected, so whether VM-only detectors ($vmOnlyStableIds) ran '
      'is unknown. Re-capture both with get_snapshot.',
      isError: true,
    );
  }
  if (beforeCoverage != afterCoverage) {
    final covered = beforeCoverage ? 'before' : 'after';
    return ToolCallResult.text(
      'arg_coverage_mismatch: only the "$covered" snapshot had a VM service '
      'link; the other reports isVmConnected=false or carries a '
      'launchModeAdvisory. VM-only detectors ($vmOnlyStableIds) report '
      'nothing without one, so their issues would read as resolved or new. '
      'Re-capture both runs with a VM link '
      '(`flutter run --profile --no-dds`).',
      isError: true,
    );
  }
  return null;
}

/// Highest severity and occurrence count of one stableId in a snapshot.
class _IssueAggregate {
  _IssueAggregate(this.severity);

  String severity;
  int count = 1;
}

/// Parse `currentIssues` from a snapshot payload. Returns either a
/// `Map<stableId, _IssueAggregate>` or a `ToolCallResult` error envelope
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
  final result = <String, _IssueAggregate>{};
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
    final existing = result[id];
    if (existing == null) {
      result[id] = _IssueAggregate(sev);
    } else {
      existing.count++;
      if (_severityRank(sev) > _severityRank(existing.severity)) {
        existing.severity = sev;
      }
    }
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
