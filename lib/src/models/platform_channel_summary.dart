/// A serializable summary of a platform channel event from VM timeline data.
///
/// The raw `TimelineEvent` from `package:vm_service` is not cleanly
/// serializable. This class captures only the fields consumers need
/// for offline analysis of platform channel overhead.
class PlatformChannelSummary {
  const PlatformChannelSummary({
    required this.timestampUs,
    required this.durationUs,
    required this.name,
  });

  /// Absolute monotonic timestamp in microseconds.
  final int timestampUs;

  /// Call duration in microseconds.
  final int durationUs;

  /// Method or channel name from the timeline event.
  final String name;

  Map<String, dynamic> toJson() => {
        'timestampUs': timestampUs,
        'durationUs': durationUs,
        'name': name,
      };

  factory PlatformChannelSummary.fromJson(Map<String, dynamic> json) =>
      PlatformChannelSummary(
        timestampUs: json['timestampUs'] as int,
        durationUs: json['durationUs'] as int,
        name: json['name'] as String,
      );
}
