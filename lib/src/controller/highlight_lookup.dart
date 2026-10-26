/// What a highlight lookup for an issue found.
enum HighlightLookup {
  /// A highlight of the issue is selected.
  found,

  /// The last scan has no highlight of the issue, so its widget is not on
  /// screen.
  notFound,

  /// No tree scan has run yet. The lookup runs again after the first scan
  /// and reports [found] or [notFound] then.
  pending,
}
