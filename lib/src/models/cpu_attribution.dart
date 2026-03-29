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
    this.callChain,
    this.inclusivePercentage,
  });

  /// The function name (e.g. "build", "jsonDecode").
  final String functionName;

  /// The owning class name, or empty string for top-level functions.
  final String className;

  /// The library URI (e.g. "package:my_app/widgets/my_widget.dart").
  final String libraryUri;

  /// Percentage of exclusive (self) CPU time, 0.0–100.0.
  final double percentage;

  /// Call chain from user-root to this function, e.g.
  /// ["MyWidget.build", "performLayout", "layout"].
  /// Null when call chain extraction is unavailable or samples are empty.
  final List<String>? callChain;

  /// Percentage of samples where this function was anywhere in the stack
  /// (inclusive), 0.0–100.0. Always >= [percentage] (exclusive).
  /// Null when inclusive counting is unavailable.
  final double? inclusivePercentage;

  /// Display name: "ClassName.method" or bare "method".
  String get displayName =>
      className.isNotEmpty ? '$className.$functionName' : functionName;

  /// Arrow-separated call chain for display, or null if no chain.
  /// Example: "MyWidget.build → performLayout → layout"
  String? get chainDisplay => callChain != null && callChain!.isNotEmpty
      ? callChain!.join(' → ')
      : null;

  Map<String, dynamic> toJson() => {
        'functionName': functionName,
        'className': className,
        'libraryUri': libraryUri,
        'percentage': double.parse(percentage.toStringAsFixed(1)),
        'displayName': displayName,
        if (callChain != null) 'callChain': callChain,
        if (inclusivePercentage != null)
          'inclusivePercentage':
              double.parse(inclusivePercentage!.toStringAsFixed(1)),
      };

  factory CpuAttribution.fromJson(Map<String, dynamic> json) => CpuAttribution(
        functionName: json['functionName'] as String,
        className: json['className'] as String,
        libraryUri: json['libraryUri'] as String,
        percentage: (json['percentage'] as num).toDouble(),
        callChain: (json['callChain'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList(),
        inclusivePercentage: (json['inclusivePercentage'] as num?)?.toDouble(),
      );

  @override
  String toString() {
    final chain = chainDisplay != null ? ' [$chainDisplay]' : '';
    final incl = inclusivePercentage != null
        ? ', incl: ${inclusivePercentage!.toStringAsFixed(1)}%'
        : '';
    return 'CpuAttribution($displayName, ${percentage.toStringAsFixed(1)}%$incl$chain)';
  }
}
