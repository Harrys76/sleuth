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
///     it. When several issues share the parent's id, the severity is
///     that of the instances listing the child in `downstreamIds`. A child more severe than its only parent stays standalone so
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
  // id → highest severity rank among issues carrying that id, and among
  // the instances of that id that list a given child as a downstream
  // effect (the instances whose card shows it).
  final severityById = <String, int>{};
  final ownerSeverity = <(String, String), int>{};
  for (final i in issues) {
    final id = i.stableId ?? i.title;
    final r = rank(i.severity);
    final prev = severityById[id];
    if (prev == null || r > prev) severityById[id] = r;
    for (final child in i.downstreamIds ?? const <String>[]) {
      final key = (id, child);
      final prevOwner = ownerSeverity[key];
      if (prevOwner == null || r > prevOwner) ownerSeverity[key] = r;
    }
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
    // severe; surface when the parent is suppressed or less severe. When
    // several issues share the parent's id, the one that lists this child
    // decides; another instance's severity does not.
    final parentId = parents.first;
    final parentRank =
        ownerSeverity[(parentId, i.stableId ?? i.title)] ??
        severityById[parentId];
    if (parentRank == null) return true;
    return parentRank < rank(i.severity);
  }).toList();
}

/// Identity of [issue]'s card in the overlay list: `stableId` (or `title`
/// when the issue has none), plus `|widgetName` when the issue names a
/// widget, so two widgets reporting the same detector id render as two
/// cards. Used for the held order and the hide key; [occurrenceKeysFor]
/// tells apart cards that share it.
String listKeyFor(PerformanceIssue issue) {
  final base = issue.stableId ?? issue.title;
  final widgetName = issue.widgetName;
  return widgetName == null ? base : '$base|$widgetName';
}

/// Suffix of the hide key of a critical issue.
const String _criticalHideSuffix = '!critical';

/// Key that hides [issue]'s card: its [listKeyFor], plus `!critical` when
/// the issue is critical. A key taken from a warning or ok card does not
/// hide the same card once it turns critical; a critical key hides it at
/// any severity. See [isHiddenBy].
String hideKeyFor(PerformanceIssue issue) {
  final key = listKeyFor(issue);
  return issue.severity == IssueSeverity.critical
      ? '$key$_criticalHideSuffix'
      : key;
}

/// The hide keys that hide [issue]: its critical key, and its plain key
/// below critical, each also in its any-widget form from [legacyHideKey].
/// Removing them all shows it again.
List<String> hideKeysOf(PerformanceIssue issue) {
  final key = listKeyFor(issue);
  final any = _anyWidgetKeyFor(issue);
  final belowCritical = issue.severity != IssueSeverity.critical;
  return [
    '$key$_criticalHideSuffix',
    '$any$_criticalHideSuffix',
    if (belowCritical) key,
    if (belowCritical) any,
  ];
}

/// Whether [hideKey] was taken from a critical card.
bool isCriticalHideKey(String hideKey) => hideKey.endsWith(_criticalHideSuffix);

/// The [listKeyFor] of the cards [hideKey] names.
String listKeyOfHideKey(String hideKey) => isCriticalHideKey(hideKey)
    ? hideKey.substring(0, hideKey.length - _criticalHideSuffix.length)
    : hideKey;

/// Widget part of a hide key that names any widget: `base|*` hides the
/// cards of `base` whatever widget they name, or none.
const String _anyWidget = '|*';

/// The list key that matches every card of [issue]'s stable id (or title).
String _anyWidgetKeyFor(PerformanceIssue issue) =>
    '${issue.stableId ?? issue.title}$_anyWidget';

/// [hideKey] as read from a store written before 1.0. Wrap layout,
/// excessive RepaintBoundary and custom structural issues gained a widget
/// name in 1.0, which their list keys now carry, so a key without a widget
/// name becomes one that matches any widget and keeps hiding those cards.
String legacyHideKey(String hideKey) {
  final listKey = listKeyOfHideKey(hideKey);
  if (listKey.contains('|')) return hideKey;
  return '$listKey$_anyWidget'
      '${isCriticalHideKey(hideKey) ? _criticalHideSuffix : ''}';
}

/// Whether the list part of a hide key, [listKey], names [issue]'s card:
/// its [listKeyFor], or the any-widget key of its stable id.
bool hideListKeyMatches(String listKey, PerformanceIssue issue) =>
    listKey == listKeyFor(issue) || listKey == _anyWidgetKeyFor(issue);

/// Whether [hiddenKeys] hides [issue]: its own [hideKeyFor], or the
/// critical key of the same card, each also in its any-widget form from
/// [legacyHideKey].
bool isHiddenBy(PerformanceIssue issue, Set<String> hiddenKeys) {
  if (hiddenKeys.isEmpty) return false;
  final key = listKeyFor(issue);
  final any = _anyWidgetKeyFor(issue);
  return hiddenKeys.contains('$key$_criticalHideSuffix') ||
      hiddenKeys.contains('$any$_criticalHideSuffix') ||
      (issue.severity != IssueSeverity.critical &&
          (hiddenKeys.contains(key) || hiddenKeys.contains(any)));
}

/// Keys that tell apart the cards of [issues] in their order: the
/// [listKeyFor] of each, with `#2`, `#3` added to the second and later
/// card sharing one (a detector that emits one issue per occurrence
/// under one stable id and widget). The card list keys its cards with
/// these, so two such cards keep their own state; cards frozen while one
/// is expanded keep the key they had when the zone was captured.
List<String> occurrenceKeysFor(List<PerformanceIssue> issues) {
  final seen = <String, int>{};
  final keys = <String>[];
  for (final issue in issues) {
    final key = listKeyFor(issue);
    final n = (seen[key] ?? 0) + 1;
    seen[key] = n;
    keys.add(n == 1 ? key : '$key#$n');
  }
  return keys;
}

/// The overlay's card list: [issues] filtered to [severities], collapsed
/// by [computeVisibleIssues], then stripped of cards [hiddenKeys] hides
/// ([isHiddenBy]).
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
      if (!isHiddenBy(i, hiddenKeys)) i,
  ];
}
