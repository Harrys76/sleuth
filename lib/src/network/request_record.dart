/// A recorded HTTP request with timing and size metadata.
///
/// Stored in the [NetworkMonitorDetector]'s ring buffer and included
/// in session exports. Never captures request/response bodies.
class RequestRecord {
  const RequestRecord({
    required this.url,
    required this.method,
    required this.statusCode,
    required this.durationMs,
    required this.responseBytes,
    required this.startedAt,
  });

  /// The full request URL.
  final String url;

  /// HTTP method (GET, POST, etc.).
  final String method;

  /// HTTP status code. -1 for failed/errored requests.
  final int statusCode;

  /// Total request duration in milliseconds (from open to response stream end).
  final int durationMs;

  /// Total response body size in bytes (counted from stream chunks).
  final int responseBytes;

  /// When the request was initiated.
  final DateTime startedAt;

  Map<String, dynamic> toJson() => {
        'url': url,
        'method': method,
        'statusCode': statusCode,
        'durationMs': durationMs,
        'responseBytes': responseBytes,
        'startedAt': startedAt.toIso8601String(),
      };

  @override
  String toString() =>
      'RequestRecord($method $url, ${durationMs}ms, ${responseBytes}B, status=$statusCode)';
}
