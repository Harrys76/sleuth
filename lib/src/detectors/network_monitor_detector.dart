import 'dart:async';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../network/request_record.dart';
import '../utils/fix_hint_builder.dart';

/// Detects slow, excessive, or oversized HTTP requests.
///
/// Receives [RequestRecord]s from the [WatchdogHttpOverrides] monitoring
/// proxy and evaluates three issue types:
/// - **Slow Request**: response time exceeds threshold
/// - **Frequency Spike**: too many requests in a 5-second window
/// - **Large Response**: response body exceeds size threshold
///
/// Uses a ring buffer of records with buffer-derived issue lifecycle:
/// issues are cleared and rebuilt from current buffer state on each
/// new record and on each frequency timer tick.
class NetworkMonitorDetector extends BaseDetector {
  NetworkMonitorDetector({
    this.slowThresholdMs = 2000,
    this.frequencyLimit = 30,
    this.largeResponseBytes = 1048576,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        super(
          type: DetectorType.networkMonitor,
          lifecycle: DetectorLifecycle.runtime,
          name: 'Network Monitor',
          description: 'Detects slow, excessive, or large HTTP requests',
        );

  /// Slow request threshold in milliseconds. Default 2000ms.
  final int slowThresholdMs;

  /// Maximum requests per 5-second window. Default 30.
  final int frequencyLimit;

  /// Large response threshold in bytes. Default 1MB.
  final int largeResponseBytes;

  final DateTime Function() _clock;

  static const int _bufferCapacity = 200;
  static const int _frequencyWindowMs = 5000;
  static const int _criticalSlowThresholdMs = 5000;

  final List<RequestRecord> _records = [];
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;
  Timer? _frequencyTimer;

  /// Active (in-flight) requests tracked by monotonic ID.
  final Map<int, DateTime> _activeRequests = {};

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) {
    _isEnabled = value;
    if (!value) {
      _frequencyTimer?.cancel();
      _frequencyTimer = null;
      _activeRequests.clear();
    }
  }

  /// Unmodifiable view of the ring buffer for session export.
  List<RequestRecord> get records => List.unmodifiable(_records);

  /// Called when an HTTP request starts (before response).
  void startRequest(int requestId, DateTime startedAt) {
    if (!_isEnabled) return;
    _activeRequests[requestId] = startedAt;
  }

  /// Called when an HTTP request completes or fails.
  void endRequest(int requestId) {
    _activeRequests.remove(requestId);
  }

  /// Snapshot of pending requests at this instant.
  /// Returns (0, null) when no requests are in-flight.
  (int count, int? slowestPendingMs) pendingRequestSnapshot() {
    if (_activeRequests.isEmpty) return (0, null);
    final now = _clock();
    int maxMs = 0;
    for (final startedAt in _activeRequests.values) {
      final ms = now.difference(startedAt).inMilliseconds;
      if (ms > maxMs) maxMs = ms;
    }
    return (_activeRequests.length, maxMs);
  }

  /// Process a completed (or failed) HTTP request.
  void processRecord(RequestRecord record) {
    if (!_isEnabled) return;

    // Add to ring buffer (FIFO eviction)
    _records.add(record);
    if (_records.length > _bufferCapacity) _records.removeAt(0);

    // Start frequency timer on first record
    _frequencyTimer ??= Timer.periodic(
      const Duration(milliseconds: _frequencyWindowMs),
      (_) => _evaluate(),
    );

    // Full re-evaluation from buffer
    _evaluate();
  }

  /// Clear and rebuild all issues from current buffer state.
  void _evaluate() {
    if (!_isEnabled) {
      _issues.clear();
      return;
    }

    _issues.clear();
    _evaluateSlowRequests();
    _evaluateLargeResponses();
    _evaluateFrequency();

    // Cancel timer when buffer is empty — no point ticking on stale state.
    // Timer restarts on next processRecord().
    if (_records.isEmpty) {
      _frequencyTimer?.cancel();
      _frequencyTimer = null;
    }
  }

  void _evaluateSlowRequests() {
    final slowRecords =
        _records.where((r) => r.durationMs >= slowThresholdMs).toList();
    if (slowRecords.isEmpty) return;

    final worstMs =
        slowRecords.map((r) => r.durationMs).reduce((a, b) => a > b ? a : b);
    final severity = worstMs >= _criticalSlowThresholdMs
        ? IssueSeverity.critical
        : IssueSeverity.warning;

    // Build detail listing slow URLs
    final urlDetails = slowRecords
        .map((r) => '${r.method.toUpperCase()} ${_shortenUrl(r.url)} — '
            '${(r.durationMs / 1000).toStringAsFixed(1)}s')
        .join('\n');

    final (hint, effort) = FixHintBuilder.slowRequest(
      worstUrl: slowRecords.isNotEmpty ? slowRecords.first.url : null,
    );
    _issues.add(PerformanceIssue(
      stableId: 'slow_request',
      severity: severity,
      category: IssueCategory.network,
      confidence: IssueConfidence.confirmed,
      title:
          'Slow Request: ${slowRecords.length} request${slowRecords.length > 1 ? 's' : ''} '
          '> ${(slowThresholdMs / 1000).toStringAsFixed(0)}s '
          '(worst: ${(worstMs / 1000).toStringAsFixed(1)}s)',
      detail: '$urlDetails\n\n'
          'Threshold: ${(slowThresholdMs / 1000).toStringAsFixed(0)}s. '
          '${slowRecords.length} slow request${slowRecords.length > 1 ? 's' : ''} '
          'in buffer.',
      fixHint: hint,
      fixEffort: effort,
      detectedAt: _clock(),
    ));
  }

  void _evaluateLargeResponses() {
    final largeRecords =
        _records.where((r) => r.responseBytes >= largeResponseBytes).toList();
    if (largeRecords.isEmpty) return;

    final worstBytes = largeRecords
        .map((r) => r.responseBytes)
        .reduce((a, b) => a > b ? a : b);

    final urlDetails = largeRecords
        .map((r) => '${r.method.toUpperCase()} ${_shortenUrl(r.url)} — '
            '${_formatBytes(r.responseBytes)}')
        .join('\n');

    final (hint, effort) = FixHintBuilder.largeResponse(
      worstUrl: largeRecords.isNotEmpty ? largeRecords.first.url : null,
    );
    _issues.add(PerformanceIssue(
      stableId: 'large_response',
      severity: IssueSeverity.warning,
      category: IssueCategory.network,
      confidence: IssueConfidence.confirmed,
      title:
          'Large Response: ${largeRecords.length} response${largeRecords.length > 1 ? 's' : ''} '
          '> ${_formatBytes(largeResponseBytes)} '
          '(largest: ${_formatBytes(worstBytes)})',
      detail: '$urlDetails\n\n'
          'Threshold: ${_formatBytes(largeResponseBytes)}. '
          '${largeRecords.length} large response${largeRecords.length > 1 ? 's' : ''} '
          'in buffer.',
      fixHint: hint,
      fixEffort: effort,
      detectedAt: _clock(),
    ));
  }

  void _evaluateFrequency() {
    final now = _clock();
    final windowStart =
        now.subtract(const Duration(milliseconds: _frequencyWindowMs));
    final recentCount =
        _records.where((r) => r.startedAt.isAfter(windowStart)).length;

    if (recentCount <= frequencyLimit) return;

    final (hint, effort) = FixHintBuilder.requestFrequency();
    _issues.add(PerformanceIssue(
      stableId: 'request_frequency',
      severity: IssueSeverity.warning,
      category: IssueCategory.network,
      confidence: IssueConfidence.confirmed,
      title: 'Request Frequency Spike: $recentCount requests in 5s '
          '(limit: $frequencyLimit)',
      detail: '$recentCount HTTP requests in the last 5 seconds. '
          'Threshold: $frequencyLimit/5s.',
      fixHint: hint,
      fixEffort: effort,
      detectedAt: _clock(),
    ));
  }

  static String _shortenUrl(String url) {
    try {
      final uri = Uri.parse(url);
      // Show path only (drop scheme/host for readability)
      final path = uri.path.isEmpty ? '/' : uri.path;
      return path.length > 60 ? '${path.substring(0, 57)}...' : path;
    } catch (_) {
      return url.length > 60 ? '${url.substring(0, 57)}...' : url;
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  @override
  void dispose() {
    _frequencyTimer?.cancel();
    _frequencyTimer = null;
    _records.clear();
    _issues.clear();
    _activeRequests.clear();
  }
}
