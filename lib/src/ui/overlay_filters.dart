import '../models/performance_issue.dart';

/// Filters the live issue list to the set of cards that actually render
/// in the overlay.
///
/// Three transformations are collapsed here:
///
///  1. Multi-parent downstream (≥2 causes in `rootCauseIds`) ALWAYS
///     surfaces standalone with a "Caused by" badge. Surfacing
///     bidirectionally lets the user see the multi-cause relationship
///     at a glance from the top-level list — without it, multi-cause
///     issues are only visible by expanding one of their parent cards.
///  2. Single-parent downstream collapses under its parent when that
///     parent is present AND the parent's severity is at least the
///     child's — the parent's expanded "Related effects" sub-list shows
///     it. A child more severe than its only parent stays standalone so
///     a critical effect is never hidden under a warning card. If the
///     parent is suppressed (not in the visible set), the downstream
///     re-surfaces standalone so an orphan effect is not silently lost.
///  3. 0-parent issues (roots, standalone) always surface.
///
/// Shared by the card's list build, its stale-state pruning and
/// [applyOverlayFilters], so every surface agrees on what "visible"
/// means — pin ids keyed against the visible list must survive mutations
/// to collapsed downstream entries, and stale-state pruning must not
/// delete a pin just because its root's downstream children churn.
List<PerformanceIssue> computeVisibleIssues(List<PerformanceIssue> issues) {
  int rank(IssueSeverity s) => switch (s) {
    IssueSeverity.critical => 2,
    IssueSeverity.warning => 1,
    IssueSeverity.ok => 0,
  };
  // id → highest severity rank among issues carrying that id.
  final severityById = <String, int>{};
  for (final i in issues) {
    final id = i.stableId ?? i.title;
    final r = rank(i.severity);
    final prev = severityById[id];
    if (prev == null || r > prev) severityById[id] = r;
  }
  return issues.where((i) {
    final parents = i.rootCauseIds;
    if (parents == null || parents.isEmpty) return true;
    // Multi-parent downstream always visible — the "Caused by" badge
    // surface is the user's primary discoverability path for multi-cause
    // relationships. Same downstream may also appear nested in each
    // visible parent's "Related effects" list — bidirectional info,
    // accepted redundancy.
    if (parents.length >= 2) return true;
    // Single-parent: collapse under a present parent that is at least as
    // severe; surface when the parent is suppressed or less severe.
    final parentRank = severityById[parents.first];
    if (parentRank == null) return true;
    return parentRank < rank(i.severity);
  }).toList();
}

/// Identity of [issue] for runtime hiding in the overlay: `stableId`
/// (or `title` when the issue has none), plus `|widgetName` when the
/// issue names a widget, so two widgets reporting the same detector id
/// hide independently.
String hideKeyFor(PerformanceIssue issue) {
  final base = issue.stableId ?? issue.title;
  final widgetName = issue.widgetName;
  return widgetName == null ? base : '$base|$widgetName';
}

/// Identity of [issue]'s card in the overlay list: the list key, the
/// expansion and order-snapshot bookkeeping and the highlight selection.
/// Same as [hideKeyFor], so two widgets reporting the same detector id
/// render as two cards.
String listKeyFor(PerformanceIssue issue) => hideKeyFor(issue);

/// The overlay's card list: [issues] filtered to [severities], collapsed
/// by [computeVisibleIssues], then stripped of cards whose [hideKeyFor]
/// is in [hiddenKeys].
///
/// The severity filter runs before collapsing, so an effect whose only
/// parent is filtered out surfaces as its own card. Hiding runs after
/// collapsing, so a hidden root takes its collapsed effects with it and
/// restoring the root brings the group back.
List<PerformanceIssue> applyOverlayFilters(
  List<PerformanceIssue> issues, {
  required Set<IssueSeverity> severities,
  required Set<String> hiddenKeys,
}) {
  final bySeverity = severities.length == IssueSeverity.values.length
      ? issues
      : [
          for (final i in issues)
            if (severities.contains(i.severity)) i,
        ];
  final visible = computeVisibleIssues(bySeverity);
  if (hiddenKeys.isEmpty) return visible;
  return [
    for (final i in visible)
      if (!hiddenKeys.contains(hideKeyFor(i))) i,
  ];
}
