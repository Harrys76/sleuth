/// Projectable sections of the `ext.sleuth.snapshot` payload, in the order
/// of the sleuth package's `SnapshotSection` enum
/// (`lib/src/models/snapshot_sections.dart`).
///
/// The sidecar cannot import sleuth, which needs the Flutter SDK, so this
/// list mirrors the enum. A test checks it against `doc/mcp_schema.json`
/// and, inside the sleuth repo, against the enum source.
const List<String> snapshotSectionKeys = [
  'frameStatsSummary',
  'capturedFrames',
  'currentIssues',
  'recentRequests',
  'heapSamples',
  'phaseEvents',
  'gcEvents',
  'platformChannelEvents',
  'recentFrames',
  'widgetHeatMap',
  'recurrenceTrends',
  'sessionSummary',
  'startupMetrics',
  'routeSessions',
];

/// Sections a `get_snapshot` call leaves out unless it passes `full: true`
/// or names them in `sections`: the per-frame data and the raw sample
/// buffers.
///
/// Measured on an iPhone 12, `capturedFrames` (40 frames, about 120 KB)
/// and `recentFrames` (240 frames, about 110 KB) were about 90 % of a
/// snapshot after a few minutes on an animated screen. `recentRequests`
/// holds up to 200 requests with their URLs, and `heapSamples`,
/// `phaseEvents`, `gcEvents` and `platformChannelEvents` add about 20 KB
/// of raw samples. Without them a snapshot is about 3 to 15 KB.
const List<String> heavySnapshotSections = [
  'capturedFrames',
  'recentRequests',
  'heapSamples',
  'phaseEvents',
  'gcEvents',
  'platformChannelEvents',
  'recentFrames',
];

/// Sections a default `get_snapshot` call returns: every section in
/// [snapshotSectionKeys] except [heavySnapshotSections]. They hold
/// everything `compare_snapshots` and `check_budgets` read.
const List<String> defaultSnapshotSections = [
  'frameStatsSummary',
  'currentIssues',
  'widgetHeatMap',
  'recurrenceTrends',
  'sessionSummary',
  'startupMetrics',
  'routeSessions',
];

/// Top-level keys of the snapshot `data` block that are not sections and
/// always come back, with or without projection.
const Set<String> snapshotMetadataKeys = {
  'schemaVersion',
  'exportedAt',
  'packageVersion',
  'isVmConnected',
  'isDebugMode',
  'suppressedCount',
};
