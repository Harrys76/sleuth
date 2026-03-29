/// A single class's allocation contribution during heap growth.
///
/// Produced from [AllocationProfile.members] (ClassHeapStats) when the
/// memory pressure detector flags sustained heap growth.
class AllocationEntry {
  const AllocationEntry({
    required this.className,
    required this.libraryUri,
    required this.instancesDelta,
    required this.bytesDelta,
    required this.percentage,
  });

  /// Class name (e.g. "MyWidget", "_GrowableList").
  final String className;

  /// Library URI (e.g. "package:my_app/models/item.dart").
  final String libraryUri;

  /// Number of instances allocated since last reset.
  final int instancesDelta;

  /// Bytes allocated since last reset.
  final int bytesDelta;

  /// Percentage of total allocation bytes, 0.0–100.0.
  final double percentage;

  /// Display-friendly byte size.
  String get displayBytes {
    final bytes = bytesDelta < 0 ? 0 : bytesDelta;
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  Map<String, dynamic> toJson() => {
        'className': className,
        'libraryUri': libraryUri,
        'instancesDelta': instancesDelta,
        'bytesDelta': bytesDelta,
        'percentage': double.parse(percentage.toStringAsFixed(1)),
      };

  factory AllocationEntry.fromJson(Map<String, dynamic> json) =>
      AllocationEntry(
        className: json['className'] as String,
        libraryUri: json['libraryUri'] as String,
        instancesDelta: json['instancesDelta'] as int,
        bytesDelta: json['bytesDelta'] as int,
        percentage: (json['percentage'] as num).toDouble(),
      );

  @override
  String toString() =>
      'AllocationEntry($className, $displayBytes, ${percentage.toStringAsFixed(1)}%)';
}
