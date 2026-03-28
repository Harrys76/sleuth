import 'dart:convert';

import '../network/request_record.dart';
import 'capture_buffer.dart';
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
  });

  final DateTime exportedAt;

  /// Worst jank frames captured during the session.
  final List<CaptureEntry> capturedFrames;

  /// Latest ranked issue list at export time.
  final List<PerformanceIssue> currentIssues;

  /// Aggregate frame stats from the live buffer.
  final FrameStatsSummary frameStatsSummary;

  final String packageVersion;
  final bool isVmConnected;
  final bool isDebugMode;

  /// Recent HTTP request records from network monitoring (if active).
  final List<RequestRecord>? recentRequests;

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
        // recentRequests is export-only; not deserialized
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

  final int totalFrames;
  final int jankFrames;
  final double averageFps;
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
