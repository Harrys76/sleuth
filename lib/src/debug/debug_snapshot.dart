/// Origin of the [DebugSnapshot.rebuildCounts] data.
///
/// Sleuth populates rebuild counts from exactly one source per mode
/// (see spec v15 KDD-1 "mutual exclusivity by mode"):
///
/// - [debugCallback]: debug-mode `debugOnRebuildDirtyWidget` callback.
///   Counts actual rebuilds only (initial builds excluded).
/// - [flutterTimeline]: profile-mode `FlutterTimeline.debugCollect()` drain.
///   Counts include initial widget inflations as well as rebuilds (KDD-5),
///   so route entry shows transient elevated values.
/// - [none]: no source is active; `rebuildCounts` is empty. Also the
///   default used by fixture/test snapshots that don't care about source.
enum RebuildCountSource { none, debugCallback, flutterTimeline }

/// A snapshot of debug callback data accumulated over a time window.
///
/// Produced by [DebugInstrumentationCoordinator.snapshot()] and consumed
/// by detectors to provide per-widget-type rebuild and paint attribution.
class DebugSnapshot {
  const DebugSnapshot({
    required this.rebuildCounts,
    required this.totalPaintCount,
    required this.elapsed,
    this.paintCounts = const {},
    this.ancestorChains = const {},
    this.source = RebuildCountSource.none,
  });

  /// Per-widget-type rebuild counts (key = widget runtimeType name).
  ///
  /// From `debugOnRebuildDirtyWidget` which provides the [Element],
  /// giving us `.widget.runtimeType`.
  final Map<String, int> rebuildCounts;

  /// Per-widget-type paint counts (key = widget runtimeType name).
  ///
  /// From `debugOnProfilePaint` via `renderObject.debugCreator` mapping
  /// back to the originating widget type. Empty when `debugCreator` is
  /// unavailable (non-widget RenderObjects).
  final Map<String, int> paintCounts;

  /// Per-widget-type ancestor chains (key = widget runtimeType name).
  ///
  /// Captured on first occurrence of each type in the debug callbacks.
  /// Provides widget tree hierarchy for source-location enrichment.
  final Map<String, String> ancestorChains;

  /// Aggregate paint call count (includes paints where widget attribution
  /// was not possible).
  final int totalPaintCount;

  /// Time since last snapshot. Detectors MUST normalize counts to
  /// per-second rates using this before applying thresholds, since
  /// the snapshot interval is not guaranteed to be 1 second.
  final Duration elapsed;

  /// Origin of [rebuildCounts]. See [RebuildCountSource] for semantics.
  ///
  /// Defaults to [RebuildCountSource.none] so existing const-literal
  /// fixture snapshots compile unchanged. Code that cares about the
  /// profile-mode path (e.g. the controller merge into
  /// `RouteSession.rebuildCountsByType`) should gate on
  /// `source == RebuildCountSource.flutterTimeline`.
  final RebuildCountSource source;

  /// Total rebuilds across all widget types.
  int get totalRebuilds => rebuildCounts.values.fold(0, (a, b) => a + b);

  /// Rebuilds per second for a specific widget type.
  ///
  /// Uses microseconds throughout to avoid int truncation at sub-second
  /// windows and division-by-zero when elapsed is very small.
  double rebuildsPerSecond(String typeName) {
    final us = elapsed.inMicroseconds;
    if (us == 0) return 0;
    return (rebuildCounts[typeName] ?? 0) /
        (us / Duration.microsecondsPerSecond);
  }

  /// Total paints per second (aggregate, not per-widget).
  double get paintsPerSecond {
    final us = elapsed.inMicroseconds;
    if (us == 0) return 0;
    return totalPaintCount / (us / Duration.microsecondsPerSecond);
  }

  /// Paints per second for a specific widget type.
  double paintsPerSecondForType(String typeName) {
    final us = elapsed.inMicroseconds;
    if (us == 0) return 0;
    return (paintCounts[typeName] ?? 0) / (us / Duration.microsecondsPerSecond);
  }

  /// Total paints with widget-type attribution.
  int get totalPaintsFromTypes => paintCounts.values.fold(0, (a, b) => a + b);
}
