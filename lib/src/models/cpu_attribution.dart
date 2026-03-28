/// A single function's CPU attribution during a jank frame.
///
/// Produced by [CpuSampleAggregator] from VM CPU profiling samples.
/// Represents the percentage of exclusive (self) CPU time spent in this
/// function during the frame window.
class CpuAttribution {
  const CpuAttribution({
    required this.functionName,
    required this.className,
    required this.libraryUri,
    required this.percentage,
  });

  /// The function name (e.g. "build", "jsonDecode").
  final String functionName;

  /// The owning class name, or empty string for top-level functions.
  final String className;

  /// The library URI (e.g. "package:my_app/widgets/my_widget.dart").
  final String libraryUri;

  /// Percentage of exclusive (self) CPU time, 0.0–100.0.
  final double percentage;

  /// Display name: "ClassName.method" or bare "method".
  String get displayName =>
      className.isNotEmpty ? '$className.$functionName' : functionName;

  Map<String, dynamic> toJson() => {
        'functionName': functionName,
        'className': className,
        'libraryUri': libraryUri,
        'percentage': double.parse(percentage.toStringAsFixed(1)),
        'displayName': displayName,
      };

  factory CpuAttribution.fromJson(Map<String, dynamic> json) => CpuAttribution(
        functionName: json['functionName'] as String,
        className: json['className'] as String,
        libraryUri: json['libraryUri'] as String,
        percentage: (json['percentage'] as num).toDouble(),
      );

  @override
  String toString() =>
      'CpuAttribution($displayName, ${percentage.toStringAsFixed(1)}%)';
}
