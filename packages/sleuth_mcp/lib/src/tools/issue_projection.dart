/// Compact-issue projection shared by `get_issues` and `get_snapshot`.
///
/// The app emits each issue with ~22 fields, most of them internal
/// provenance an MCP client never acts on. These helpers trim to the
/// actionable subset (default) so responses stay readable + cheap, while a
/// `verbose` flag preserves the full shape.
library;

/// Fields kept in a compact issue. `stableId` + `severity` are mandatory —
/// `compare_snapshots` keys its diff on them.
const Set<String> compactIssueKeys = {
  'severity',
  'category',
  'confidence',
  'title',
  'detail',
  'fixHint',
  'stableId',
  'widgetName',
  'routeName',
  'sourceRoute',
  'confidenceReason',
  'rootCauseIds',
};

/// Trims one full issue map to [compactIssueKeys]. Only copies keys that are
/// present, so absent optional fields stay absent (not null).
Map<String, Object?> compactIssue(Map<String, Object?> full) {
  final out = <String, Object?>{};
  for (final key in compactIssueKeys) {
    if (full.containsKey(key)) out[key] = full[key];
  }
  return out;
}

/// Result of [projectIssues]: the (possibly capped + compacted) list, whether
/// a cap dropped any, and the pre-cap total.
typedef ProjectedIssues = ({
  List<Map<String, Object?>> issues,
  bool truncated,
  int total,
});

/// Projects a raw issue list for a tool response.
///
/// Cap and field-trim are orthogonal:
/// - [maxCount] keeps the front-N of the already-ranked list (so front = top
///   priority). [maxCount] <= 0 = no cap, but `0` is the only public sentinel —
///   callers reject negatives upstream. Independent of [verbose].
/// - [verbose] picks field shape only — true keeps every field, false trims
///   each kept issue to [compactIssueKeys].
///
/// `total` is the pre-cap count (after any upstream filtering).
ProjectedIssues projectIssues(
  List<Map<String, Object?>> issues, {
  required bool verbose,
  required int maxCount,
}) {
  final total = issues.length;
  final kept =
      (maxCount > 0 && total > maxCount) ? issues.sublist(0, maxCount) : issues;
  return (
    issues: verbose ? kept : [for (final i in kept) compactIssue(i)],
    truncated: kept.length < total,
    total: total,
  );
}
