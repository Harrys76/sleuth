/// Payload-bearing sections of a [SessionSnapshot] JSON envelope that a
/// consumer can opt out of via projection. Metadata keys
/// (`schemaVersion`, `exportedAt`, `packageVersion`, `isVmConnected`,
/// `isDebugMode`, `suppressedCount`) are never projectable — they are
/// small and required for parsing, so they always serialize.
///
/// [jsonKey] MUST match the corresponding key in
/// `SessionSnapshot.toJson` byte-for-byte; the snapshot-sections drift
/// test asserts this in both directions.
enum SnapshotSection {
  frameStatsSummary,
  capturedFrames,
  currentIssues,
  recentRequests,
  heapSamples,
  phaseEvents,
  gcEvents,
  platformChannelEvents,
  recentFrames,
  widgetHeatMap,
  recurrenceTrends,
  sessionSummary,
  startupMetrics,
  routeSessions;

  /// JSON envelope key. Equals the enum name for every current section,
  /// but kept as an explicit getter so a key rename doesn't silently
  /// desync from the enum identifier.
  String get jsonKey => name;

  /// Case-insensitive, whitespace-tolerant lookup. Returns null when no
  /// section matches — callers map that to a typed `arg_invalid_section`
  /// error rather than silently dropping the token.
  static SnapshotSection? fromString(String raw) {
    final needle = raw.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final s in values) {
      if (s.jsonKey.toLowerCase() == needle) return s;
    }
    return null;
  }

  /// Envelope keys excluded from projection gating — they serialize
  /// independent of `include`. Most always emit; `suppressedCount` is
  /// conditional (`> 0`) but is still never gated by a section filter.
  /// The drift test uses this set to skip metadata in the
  /// "every payload key has a section" check.
  static const Set<String> alwaysOnKeys = {
    'schemaVersion',
    'exportedAt',
    'packageVersion',
    'isVmConnected',
    'isDebugMode',
    'suppressedCount',
  };
}
