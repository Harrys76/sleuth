/// A single heap memory usage sample from the VM service.
///
/// Captured every 500ms alongside the timeline poll. Used by
/// [MemoryPressureDetector] for trend analysis and included in
/// session export for offline investigation.
class HeapSample {
  const HeapSample({
    required this.heapUsage,
    required this.heapCapacity,
    required this.externalUsage,
    required this.timestamp,
    this.rssBytes,
  });

  /// Current Dart heap usage in bytes.
  final int heapUsage;

  /// Total Dart heap capacity in bytes (from OS perspective).
  final int heapCapacity;

  /// Non-Dart memory retained by Dart objects (images, platform channels).
  /// Applies GC pressure but is separate from [heapUsage]/[heapCapacity].
  final int externalUsage;

  /// When this sample was captured.
  final DateTime timestamp;

  /// Process-level Resident Set Size in bytes, from [ProcessInfo.currentRss].
  /// Null when running on web or when [ProcessInfo] is unavailable.
  final int? rssBytes;

  /// Estimated native (non-Dart) memory: RSS minus Dart heap usage.
  /// Null when [rssBytes] is unavailable. Clamped to [0, rssBytes] to handle
  /// edge cases where RSS lags behind heap expansion.
  int? get nativeBytes =>
      rssBytes != null ? (rssBytes! - heapUsage).clamp(0, rssBytes!) : null;

  Map<String, dynamic> toJson() => {
        'heapUsage': heapUsage,
        'heapCapacity': heapCapacity,
        'externalUsage': externalUsage,
        'timestamp': timestamp.toIso8601String(),
        if (rssBytes != null) 'rssBytes': rssBytes,
        if (nativeBytes != null) 'nativeBytes': nativeBytes,
      };
}
