import 'dart:convert';

import '../network/request_record.dart';
import 'capture_buffer.dart';
import 'frame_stats.dart';
import 'gc_event_summary.dart';
import 'heap_sample.dart';
import 'performance_issue.dart';
import 'phase_event.dart';
import 'platform_channel_summary.dart';

/// A point-in-time snapshot of a watchdog session for export.
class SessionSnapshot {
  const SessionSnapshot({
    required this.exportedAt,
    required this.capturedFrames,
    required this.currentIssues,
    required this.frameStatsSummary,
    this.schemaVersion = 2,
    this.packageVersion = '',
    this.isVmConnected = false,
    this.isDebugMode = false,
    this.recentRequests,
    this.heapSamples,
    this.suppressedCount = 0,
    this.phaseEvents,
    this.gcEvents,
    this.platformChannelEvents,
    this.recentFrames,
  });

  /// Schema version for forward-compatible parsing.
  /// v1: implicit (no field), v2: adds phase/GC/channel events, FPS
  /// percentiles, ranking scores, and recent frames.
  final int schemaVersion;

  /// Wall-clock time when this snapshot was exported.
  final DateTime exportedAt;

  /// Worst jank frames captured during the session (curated, up to 50).
  final List<CaptureEntry> capturedFrames;

  /// Latest ranked issue list at export time.
  /// When [schemaVersion] >= 2, each issue carries [PerformanceIssue.rankingScore]
  /// and [PerformanceIssue.rankingBreakdown].
  final List<PerformanceIssue> currentIssues;

  /// Aggregate frame stats from the live buffer.
  final FrameStatsSummary frameStatsSummary;

  /// Package version string for snapshot provenance.
  final String packageVersion;

  /// Whether VM service was connected at export time.
  final bool isVmConnected;

  /// Whether the app was running in debug mode at export time.
  final bool isDebugMode;

  /// Recent HTTP request records from network monitoring (if active).
  final List<RequestRecord>? recentRequests;

  /// Rolling window of heap memory samples (if VM was connected).
  final List<HeapSample>? heapSamples;

  /// Number of issues hidden by the suppression list at export time.
  final int suppressedCount;

  /// Recent VM timeline phase events (rolling buffer, up to 100).
  /// Null when VM service was not connected.
  final List<PhaseEvent>? phaseEvents;

  /// Recent GC events extracted from VM timeline (rolling buffer, up to 50).
  /// Null when VM service was not connected.
  final List<GcEventSummary>? gcEvents;

  /// Recent platform channel events from VM timeline (rolling buffer, up to 50).
  /// Null when VM service was not connected.
  final List<PlatformChannelSummary>? platformChannelEvents;

  /// Last N frames from the live buffer for trend analysis (temporal window).
  /// Unlike [capturedFrames] which stores the worst jank frames, this provides
  /// a continuous time series regardless of jank status.
  /// Null when no frames have been recorded.
  final List<FrameStats>? recentFrames;

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'exportedAt': exportedAt.toIso8601String(),
        'packageVersion': packageVersion,
        'isVmConnected': isVmConnected,
        'isDebugMode': isDebugMode,
        'frameStatsSummary': frameStatsSummary.toJson(),
        'capturedFrames': capturedFrames.map((e) => e.toJson()).toList(),
        'currentIssues': currentIssues.map((i) => i.toJson()).toList(),
        if (recentRequests != null && recentRequests!.isNotEmpty)
          'recentRequests': recentRequests!.map((r) => r.toJson()).toList(),
        if (heapSamples != null && heapSamples!.isNotEmpty)
          'heapSamples': heapSamples!.map((s) => s.toJson()).toList(),
        if (suppressedCount > 0) 'suppressedCount': suppressedCount,
        if (phaseEvents != null && phaseEvents!.isNotEmpty)
          'phaseEvents': phaseEvents!.map((e) => e.toJson()).toList(),
        if (gcEvents != null && gcEvents!.isNotEmpty)
          'gcEvents': gcEvents!.map((e) => e.toJson()).toList(),
        if (platformChannelEvents != null && platformChannelEvents!.isNotEmpty)
          'platformChannelEvents':
              platformChannelEvents!.map((e) => e.toJson()).toList(),
        if (recentFrames != null && recentFrames!.isNotEmpty)
          'recentFrames': recentFrames!.map((f) => f.toJson()).toList(),
      };

  /// Pretty-printed JSON string for export/sharing.
  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory SessionSnapshot.fromJson(Map<String, dynamic> json) =>
      SessionSnapshot(
        schemaVersion: json['schemaVersion'] as int? ?? 1,
        exportedAt: DateTime.parse(json['exportedAt'] as String),
        packageVersion: json['packageVersion'] as String? ?? '',
        isVmConnected: json['isVmConnected'] as bool? ?? false,
        isDebugMode: json['isDebugMode'] as bool? ?? false,
        frameStatsSummary: FrameStatsSummary.fromJson(
            json['frameStatsSummary'] as Map<String, dynamic>),
        capturedFrames: (json['capturedFrames'] as List<dynamic>)
            .map((e) => CaptureEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        currentIssues: (json['currentIssues'] as List<dynamic>)
            .map((e) => PerformanceIssue.fromJson(e as Map<String, dynamic>))
            .toList(),
        suppressedCount: json['suppressedCount'] as int? ?? 0,
        // recentRequests and heapSamples are export-only; not deserialized
        phaseEvents: json['phaseEvents'] != null
            ? (json['phaseEvents'] as List<dynamic>)
                .map((e) => PhaseEvent.fromJson(e as Map<String, dynamic>))
                .toList()
            : null,
        gcEvents: json['gcEvents'] != null
            ? (json['gcEvents'] as List<dynamic>)
                .map((e) => GcEventSummary.fromJson(e as Map<String, dynamic>))
                .toList()
            : null,
        platformChannelEvents: json['platformChannelEvents'] != null
            ? (json['platformChannelEvents'] as List<dynamic>)
                .map((e) =>
                    PlatformChannelSummary.fromJson(e as Map<String, dynamic>))
                .toList()
            : null,
        recentFrames: json['recentFrames'] != null
            ? (json['recentFrames'] as List<dynamic>)
                .map((e) => FrameStats.fromJson(e as Map<String, dynamic>))
                .toList()
            : null,
      );
}

/// Aggregated frame stats summary for the export.
class FrameStatsSummary {
  const FrameStatsSummary({
    required this.totalFrames,
    required this.jankFrames,
    required this.averageFps,
    required this.worstFrameTimeUs,
    this.fpsPercentiles,
  });

  /// Total frames observed since monitoring started.
  final int totalFrames;

  /// Number of frames that exceeded the frame budget.
  final int jankFrames;

  /// Average FPS across the live frame buffer.
  final double averageFps;

  /// Duration of the worst single frame in microseconds.
  final int worstFrameTimeUs;

  /// FPS percentiles (p50, p95, p99) from the live frame buffer.
  /// Null when the buffer has fewer than 2 frames or for v1 snapshots.
  final FpsPercentiles? fpsPercentiles;

  Map<String, dynamic> toJson() => {
        'totalFrames': totalFrames,
        'jankFrames': jankFrames,
        'averageFps': double.parse(averageFps.toStringAsFixed(1)),
        'worstFrameTimeUs': worstFrameTimeUs,
        if (fpsPercentiles != null) 'fpsPercentiles': fpsPercentiles!.toJson(),
      };

  factory FrameStatsSummary.fromJson(Map<String, dynamic> json) =>
      FrameStatsSummary(
        totalFrames: json['totalFrames'] as int,
        jankFrames: json['jankFrames'] as int,
        averageFps: (json['averageFps'] as num).toDouble(),
        worstFrameTimeUs: json['worstFrameTimeUs'] as int,
        fpsPercentiles: json['fpsPercentiles'] != null
            ? FpsPercentiles.fromJson(
                json['fpsPercentiles'] as Map<String, dynamic>)
            : null,
      );
}
