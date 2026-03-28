import 'frame_stats.dart';
import 'frame_verdict.dart';
import 'performance_issue.dart';

/// A single captured jank frame with its verdict, stamped issues, and timing.
///
/// [relatedIssues] is the canonical issue list with route/context tags
/// (populated from [issuesNotifier.value] after aggregation). This is
/// separate from [verdict.relatedIssues] which may be unstamped.
class CaptureEntry {
  const CaptureEntry({
    required this.frameStats,
    required this.verdict,
    required this.relatedIssues,
    required this.capturedAt,
  });

  final FrameStats frameStats;
  final FrameVerdict verdict;

  /// Stamped issues active at capture time (with routeName, interactionContext).
  final List<PerformanceIssue> relatedIssues;

  /// Wall-clock time when this entry was captured.
  final DateTime capturedAt;

  Map<String, dynamic> toJson() {
    final verdictJson = verdict.toJson();
    verdictJson.remove('relatedIssues'); // avoid unstamped duplicate
    return {
      'frameStats': frameStats.toJson(),
      'verdict': verdictJson,
      'relatedIssues': relatedIssues.map((i) => i.toJson()).toList(),
      'capturedAt': capturedAt.toIso8601String(),
    };
  }

  factory CaptureEntry.fromJson(Map<String, dynamic> json) => CaptureEntry(
        frameStats:
            FrameStats.fromJson(json['frameStats'] as Map<String, dynamic>),
        verdict: FrameVerdict.fromJson(json['verdict'] as Map<String, dynamic>),
        relatedIssues: (json['relatedIssues'] as List<dynamic>)
            .map((e) => PerformanceIssue.fromJson(e as Map<String, dynamic>))
            .toList(),
        capturedAt: DateTime.parse(json['capturedAt'] as String),
      );
}

/// Bounded rolling buffer of worst jank frames.
///
/// Only jank frames are captured. When full, evicts the entry with the
/// smallest [FrameStats.effectiveTotalDuration] to keep the worst offenders.
/// New entries milder than all existing ones are rejected.
class JankCaptureBuffer {
  JankCaptureBuffer({this.capacity = 50});

  final int capacity;
  final List<CaptureEntry> _entries = [];

  List<CaptureEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  /// Add a jank frame capture. If full, evicts the mildest entry only if
  /// the new entry is worse.
  void add(CaptureEntry entry) {
    if (_entries.length >= capacity) {
      int minIndex = 0;
      int minUs = _entries[0].frameStats.effectiveTotalDuration.inMicroseconds;
      for (int i = 1; i < _entries.length; i++) {
        final us = _entries[i].frameStats.effectiveTotalDuration.inMicroseconds;
        if (us < minUs) {
          minUs = us;
          minIndex = i;
        }
      }
      if (entry.frameStats.effectiveTotalDuration.inMicroseconds <= minUs) {
        return;
      }
      _entries.removeAt(minIndex);
    }
    _entries.add(entry);
  }

  void clear() => _entries.clear();
}
