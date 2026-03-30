/// A serializable summary of a GC event extracted from VM timeline data.
///
/// The raw `TimelineEvent` from `package:vm_service` is not cleanly
/// serializable. This class captures only the fields consumers need
/// for offline analysis.
class GcEventSummary {
  const GcEventSummary({
    required this.timestampUs,
    required this.durationUs,
    required this.category,
    required this.name,
  });

  /// Absolute monotonic timestamp in microseconds.
  final int timestampUs;

  /// GC pause duration in microseconds.
  final int durationUs;

  /// GC category from the timeline event (e.g. "GC", "gc").
  final String category;

  /// Event name (e.g. "CollectNewGeneration", "GC").
  final String name;

  Map<String, dynamic> toJson() => {
        'timestampUs': timestampUs,
        'durationUs': durationUs,
        'category': category,
        'name': name,
      };

  factory GcEventSummary.fromJson(Map<String, dynamic> json) => GcEventSummary(
        timestampUs: json['timestampUs'] as int,
        durationUs: json['durationUs'] as int,
        category: json['category'] as String,
        name: json['name'] as String,
      );
}
