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
  bool get isTrustworthy => matchedEventCount > 0 && coverageRatio >= 0.5;
}

/// Matches VM timeline events to specific frames by timestamp correlation.
///
/// Uses [FrameStats] phase timestamps (from [FrameTiming]) to determine
/// which frame each timeline event belongs to, solving the batch attribution
/// error where 500ms of events were attributed to a single frame.
class FrameEventCorrelator {
  FrameEventCorrelator();

  // Cache: sorted frame lists for binary search, invalidated when
  // eligible frames change (checked via count + object identity).
  List<FrameStats> _cachedUiSorted = const [];
  List<FrameStats> _cachedRasterSorted = const [];
  int _cachedEligibleCount = -1;
  FrameStats? _cachedLastFrame;

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

    // Use cached sorted lists if eligible frames haven't changed.
    // Object identity check: FrameStats instances persist in the buffer,
    // so identical() detects when the same frames are passed again.
    final lastFrame = eligibleFrames.last;
    final count = eligibleFrames.length;
    if (count != _cachedEligibleCount ||
        !identical(lastFrame, _cachedLastFrame)) {
      _cachedUiSorted = List<FrameStats>.from(eligibleFrames)
        ..sort((a, b) => a.buildStartUs!.compareTo(b.buildStartUs!));
      _cachedRasterSorted = List<FrameStats>.from(eligibleFrames)
        ..sort((a, b) => a.rasterStartUs!.compareTo(b.rasterStartUs!));
      _cachedEligibleCount = count;
      _cachedLastFrame = lastFrame;
    }
    final uiSorted = _cachedUiSorted;
    final rasterSorted = _cachedRasterSorted;

    // For each event, binary search for the matching frame (O(E log F))
    for (final event in phaseEvents) {
      final isUiThread = event.phase == TimelinePhase.build ||
          event.phase == TimelinePhase.layout ||
          event.phase == TimelinePhase.paint;

      final matchedFrameNumber = isUiThread
          ? _binarySearchUi(uiSorted, event.timestampUs)
          : _binarySearchRaster(rasterSorted, event.timestampUs);

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

  /// Binary search for a UI-thread timestamp within build windows.
  static int? _binarySearchUi(List<FrameStats> frames, int timestampUs) {
    int lo = 0, hi = frames.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final f = frames[mid];
      if (timestampUs < f.buildStartUs!) {
        hi = mid - 1;
      } else if (timestampUs > f.buildFinishUs!) {
        lo = mid + 1;
      } else {
        return f.frameNumber;
      }
    }
    return null;
  }

  /// Binary search for a raster-thread timestamp within raster windows.
  static int? _binarySearchRaster(List<FrameStats> frames, int timestampUs) {
    int lo = 0, hi = frames.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final f = frames[mid];
      if (timestampUs < f.rasterStartUs!) {
        hi = mid - 1;
      } else if (timestampUs > f.rasterFinishUs!) {
        lo = mid + 1;
      } else {
        return f.frameNumber;
      }
    }
    return null;
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
