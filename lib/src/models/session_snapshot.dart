import 'dart:convert';

import '../network/request_record.dart';
import 'capture_buffer.dart';
import 'heap_sample.dart';
import 'performance_issue.dart';

/// A point-in-time snapshot of a watchdog session for export.
class SessionSnapshot {
  const SessionSnapshot({
    required this.exportedAt,
    required this.capturedFrames,
    required this.currentIssues,
    required this.frameStatsSummary,
    this.packageVersion = '',
    this.isVmConnected = false,
    this.isDebugMode = false,
    this.recentRequests,
    this.heapSamples,
    this.suppressedCount = 0,
  });

  /// Wall-clock time when this snapshot was exported.
  final DateTime exportedAt;

  /// Worst jank frames captured during the session.
  final List<CaptureEntry> capturedFrames;

  /// Latest ranked issue list at export time.
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

  Map<String, dynamic> toJson() => {
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
      };

  /// Pretty-printed JSON string for export/sharing.
  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory SessionSnapshot.fromJson(Map<String, dynamic> json) =>
      SessionSnapshot(
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
      );
}

/// Aggregated frame stats summary for the export.
class FrameStatsSummary {
  const FrameStatsSummary({
    required this.totalFrames,
    required this.jankFrames,
    required this.averageFps,
    required this.worstFrameTimeUs,
  });

  /// Total frames observed since monitoring started.
  final int totalFrames;

  /// Number of frames that exceeded the frame budget.
  final int jankFrames;

  /// Average FPS across the live frame buffer.
  final double averageFps;

  /// Duration of the worst single frame in microseconds.
  final int worstFrameTimeUs;

  Map<String, dynamic> toJson() => {
        'totalFrames': totalFrames,
        'jankFrames': jankFrames,
        'averageFps': double.parse(averageFps.toStringAsFixed(1)),
        'worstFrameTimeUs': worstFrameTimeUs,
      };

  factory FrameStatsSummary.fromJson(Map<String, dynamic> json) =>
      FrameStatsSummary(
        totalFrames: json['totalFrames'] as int,
        jankFrames: json['jankFrames'] as int,
        averageFps: (json['averageFps'] as num).toDouble(),
        worstFrameTimeUs: json['worstFrameTimeUs'] as int,
      );
}
