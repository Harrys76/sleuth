import '../models/frame_stats.dart';
import '../models/phase_event.dart';

/// Per-frame correlated timeline data — only events that belong to this frame.
class CorrelatedFrameData {
  const CorrelatedFrameData({
    this.buildScopeUs = 0,
    this.flushLayoutUs = 0,
    this.flushPaintUs = 0,
    this.rasterUs = 0,
    this.shaderCompileUs = 0,
    this.matchedEventCount = 0,
    required this.totalBatchEventCount,
  });

  /// Per-frame summed durations (microseconds).
  final int buildScopeUs;
  final int flushLayoutUs;
  final int flushPaintUs;
  final int rasterUs;
  final int shaderCompileUs;

  /// How many events from the batch matched this frame.
  final int matchedEventCount;

  /// Total events in the batch (across all frames).
  final int totalBatchEventCount;

  /// Fraction of batch events that correlated to ANY frame.
  /// Low values suggest clock mismatch or sparse timeline data.
  double get coverageRatio =>
      totalBatchEventCount == 0 ? 0 : matchedEventCount / totalBatchEventCount;

  /// Whether this correlation has enough data for a trustworthy verdict.
  bool get isTrustworthy => matchedEventCount > 0 && coverageRatio >= 0.2;
}

/// Matches VM timeline events to specific frames by timestamp correlation.
///
/// Uses [FrameStats] phase timestamps (from [FrameTiming]) to determine
/// which frame each timeline event belongs to, solving the batch attribution
/// error where 500ms of events were attributed to a single frame.
class FrameEventCorrelator {
  const FrameEventCorrelator();

  /// Correlate timeline events to specific frames by timestamp.
  ///
  /// Returns a map from frameNumber → [CorrelatedFrameData].
  /// Only frames with [FrameStats.hasPhaseTimestamps] are eligible.
  Map<int, CorrelatedFrameData> correlate({
    required List<FrameStats> recentFrames,
    required List<PhaseEvent> phaseEvents,
  }) {
    if (phaseEvents.isEmpty) return const {};

    // Filter to frames with phase timestamps
    final eligibleFrames =
        recentFrames.where((f) => f.hasPhaseTimestamps).toList();
    if (eligibleFrames.isEmpty) return const {};

    // Mutable buckets for accumulating per-frame durations
    final buckets = <int, _MutableBucket>{};
    for (final frame in eligibleFrames) {
      buckets[frame.frameNumber] = _MutableBucket();
    }

    final totalEvents = phaseEvents.length;

    // For each event, find the matching frame
    for (final event in phaseEvents) {
      final isUiThread = event.phase == TimelinePhase.build ||
          event.phase == TimelinePhase.layout ||
          event.phase == TimelinePhase.paint;

      int? matchedFrameNumber;

      for (final frame in eligibleFrames) {
        if (isUiThread) {
          // UI-thread events: match against build window
          if (event.timestampUs >= frame.buildStartUs! &&
              event.timestampUs <= frame.buildFinishUs!) {
            matchedFrameNumber = frame.frameNumber;
            break;
          }
        } else {
          // Raster-thread events: match against raster window
          if (event.timestampUs >= frame.rasterStartUs! &&
              event.timestampUs <= frame.rasterFinishUs!) {
            matchedFrameNumber = frame.frameNumber;
            break;
          }
        }
      }

      if (matchedFrameNumber != null) {
        final bucket = buckets[matchedFrameNumber]!;
        bucket.matchedCount++;
        switch (event.phase) {
          case TimelinePhase.build:
            bucket.buildScopeUs += event.durationUs;
          case TimelinePhase.layout:
            bucket.flushLayoutUs += event.durationUs;
          case TimelinePhase.paint:
            bucket.flushPaintUs += event.durationUs;
          case TimelinePhase.raster:
            bucket.rasterUs += event.durationUs;
          case TimelinePhase.shader:
            bucket.shaderCompileUs += event.durationUs;
        }
      }
    }

    // Convert to immutable results
    final result = <int, CorrelatedFrameData>{};
    for (final entry in buckets.entries) {
      final b = entry.value;
      result[entry.key] = CorrelatedFrameData(
        buildScopeUs: b.buildScopeUs,
        flushLayoutUs: b.flushLayoutUs,
        flushPaintUs: b.flushPaintUs,
        rasterUs: b.rasterUs,
        shaderCompileUs: b.shaderCompileUs,
        matchedEventCount: b.matchedCount,
        totalBatchEventCount: totalEvents,
      );
    }

    return result;
  }
}

class _MutableBucket {
  int buildScopeUs = 0;
  int flushLayoutUs = 0;
  int flushPaintUs = 0;
  int rasterUs = 0;
  int shaderCompileUs = 0;
  int matchedCount = 0;
}
