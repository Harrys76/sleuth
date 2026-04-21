import 'dart:async';
import 'dart:collection';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../network/request_record.dart';
import '../utils/fix_hint_builder.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';

/// Detects slow, excessive, or oversized HTTP requests.
///
/// Receives [RequestRecord]s from the [SleuthHttpOverrides] monitoring
/// proxy and evaluates three issue types:
/// - **Slow Request**: response time exceeds threshold
/// - **Frequency Spike**: too many requests in a 5-second window
/// - **Large Response**: response body exceeds size threshold
///
/// Uses a ring buffer of records with buffer-derived issue lifecycle:
/// issues are cleared and rebuilt from current buffer state on each
/// new record and on each frequency timer tick. The buffer is cleared
/// on route transitions via [clearRecords], so issues from a previous
/// page don't persist on the new page.
class NetworkMonitorDetector extends BaseDetector
    with DetectorMetadataProvider {
  NetworkMonitorDetector({
    this.slowThresholdMs = 1000,
    this.criticalSlowThresholdMs = 3000,
    this.frequencyLimit = 30,
    this.largeResponseBytes = 1048576,
    DateTime Function()? clock,
  })  : assert(
          slowThresholdMs >= 0,
          'slowThresholdMs must be >= 0.',
        ),
        assert(
          criticalSlowThresholdMs > slowThresholdMs,
          'criticalSlowThresholdMs must be strictly greater than '
          'slowThresholdMs so the critical tier is reachable.',
        ),
        _clock = clock ?? DateTime.now,
        super(
          type: DetectorType.networkMonitor,
          lifecycle: DetectorLifecycle.runtime,
          name: 'Network Monitor',
          description: 'Detects slow, excessive, or large HTTP requests',
        );

  /// Slow request warning threshold in milliseconds. Default 1000 ms.
  ///
  /// Aligned with 2025–2026 mobile-API guidance: ideal 100–300 ms,
  /// acceptable 500–800 ms, "slow" at ~1 s. Anything past this gate
  /// emits a `slow_request` warning. Set higher (e.g. 2000) if your
  /// app intentionally does long uploads/downloads.
  final int slowThresholdMs;

  /// Slow request critical threshold in milliseconds. Default 3000 ms.
  ///
  /// Requests slower than this are classified as critical rather than
  /// warning. Must be strictly greater than [slowThresholdMs] (enforced
  /// by an assert in the constructor) so the critical tier is always
  /// reachable from the warning tier.
  final int criticalSlowThresholdMs;

  /// Maximum requests per 5-second window. Default 30.
  final int frequencyLimit;

  /// Large response threshold in bytes. Default 1MB.
  final int largeResponseBytes;

  final DateTime Function() _clock;

  static const int _bufferCapacity = 200;
  static const int _frequencyWindowMs = 5000;
  static const int _duplicateWindowMs = 500;
  static const int _duplicateThreshold = 3;
  static const int _criticalDuplicateThreshold = 10;

  final Queue<RequestRecord> _records = Queue<RequestRecord>();
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;
  Timer? _frequencyTimer;

  /// Records with `startedAt` before this timestamp are from a previous page
  /// and are silently dropped by [processRecord]. Set by [clearRecords] on
  /// route transitions.
  DateTime? _ignoreBeforeTimestamp;

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

    // Drop records from a previous page: their startedAt precedes the last
    // clearRecords() call, meaning the request was initiated before the user
    // navigated away. Without this guard, slow responses arriving after
    // navigation pollute the new page's buffer.
    if (_ignoreBeforeTimestamp != null &&
        !record.startedAt.isAfter(_ignoreBeforeTimestamp!)) {
      return;
    }

    // Add to ring buffer (FIFO eviction)
    _records.add(record);
    if (_records.length > _bufferCapacity) _records.removeFirst();

    // Start frequency timer on first record
    _frequencyTimer ??= Timer.periodic(
      const Duration(milliseconds: _frequencyWindowMs),
      (_) => _evaluate(),
    );

    // Full re-evaluation from buffer
    _evaluate();
  }

  /// Clear all buffered records and issues.
  ///
  /// Called by [SleuthController] on route transitions so that network
  /// issues from a previous page don't persist on the new page.
  ///
  /// **Test authors beware:** this stamps [_ignoreBeforeTimestamp] at the
  /// current clock reading, and [processRecord] drops any subsequent record
  /// whose `startedAt` is `<=` that timestamp (not strictly before). Under a
  /// fake/frozen clock, the very next record — whose `startedAt` defaults to
  /// `_clock()` — will share the cutoff timestamp and be silently dropped.
  /// When writing boundary tests that need to reset state between probes,
  /// prefer constructing a fresh [NetworkMonitorDetector] instance over
  /// calling [clearRecords] followed by a default-timestamped record.
  void clearRecords() {
    // Mark the cutoff so in-flight responses from the previous page are
    // silently dropped when they arrive via processRecord().
    _ignoreBeforeTimestamp = _clock();
    _records.clear();
    _issues.clear();
    _activeRequests.clear();
    _frequencyTimer?.cancel();
    _frequencyTimer = null;
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
    _evaluateErrors();
    _evaluateHighFrequencySamePath();

    // Cancel timer when buffer is empty — no point ticking on stale state.
    // Timer restarts on next processRecord().
    if (_records.isEmpty) {
      _frequencyTimer?.cancel();
      _frequencyTimer = null;
    }
  }

  void _evaluateSlowRequests() {
    // Cancelled requests are kept in the record buffer so pending-request
    // accounting stays honest, but an intentional abort is not evidence
    // of a slow API — filter them out before latency classification.
    final slowRecords = _records
        .where((r) => !r.cancelled && r.durationMs >= slowThresholdMs)
        .toList();
    if (slowRecords.isEmpty) return;

    final worstMs =
        slowRecords.map((r) => r.durationMs).reduce((a, b) => a > b ? a : b);
    final severity = worstMs >= criticalSlowThresholdMs
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
      confidenceReason: 'Measured directly from HTTP interception',
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
      confidenceReason: 'Measured directly from HTTP interception',
    ));
  }

  void _evaluateFrequency() {
    // Cancels are excluded from frequency classification — a prefetch
    // that the caller aborts is not evidence of a noisy endpoint.
    final recordsList =
        _records.where((r) => !r.cancelled).toList(growable: false);
    if (recordsList.length <= frequencyLimit) return;

    // Find the peak 5-second window across the entire buffer.
    // This keeps the spike visible while evidence remains in the buffer,
    // rather than vanishing after the 5-second detection window.
    // Buffer is cleared on route transitions via clearRecords().
    int peakCount = 0;
    int left = 0;
    for (var right = 0; right < recordsList.length; right++) {
      while (left < right &&
          recordsList[right]
                  .startedAt
                  .difference(recordsList[left].startedAt)
                  .inMilliseconds >
              _frequencyWindowMs) {
        left++;
      }
      final windowSize = right - left + 1;
      if (windowSize > peakCount) peakCount = windowSize;
    }

    if (peakCount <= frequencyLimit) return;

    final (hint, effort) = FixHintBuilder.requestFrequency();
    _issues.add(PerformanceIssue(
      stableId: 'request_frequency',
      severity: IssueSeverity.warning,
      category: IssueCategory.network,
      confidence: IssueConfidence.confirmed,
      title: 'Request Frequency Spike: $peakCount requests in 5s '
          '(limit: $frequencyLimit)',
      detail: '$peakCount HTTP requests within a 5-second window. '
          'Threshold: $frequencyLimit/5s.',
      fixHint: hint,
      fixEffort: effort,
      detectedAt: _clock(),
      confidenceReason: 'Measured directly from HTTP interception',
    ));
  }

  void _evaluateErrors() {
    // Filter to error records, then find peak 5-second window.
    final errorRecords = _records
        .where((r) => r.statusCode >= 400 || r.statusCode == -1)
        .toList();

    if (errorRecords.length < 3) return;

    // Find peak 5-second error window across the buffer, tracking bounds
    // so severity and detail are scoped to the same window.
    int peakCount = 0;
    int peakLeft = 0;
    int peakRight = 0;
    int left = 0;
    for (var right = 0; right < errorRecords.length; right++) {
      while (left < right &&
          errorRecords[right]
                  .startedAt
                  .difference(errorRecords[left].startedAt)
                  .inMilliseconds >
              _frequencyWindowMs) {
        left++;
      }
      final windowSize = right - left + 1;
      if (windowSize > peakCount) {
        peakCount = windowSize;
        peakLeft = left;
        peakRight = right;
      }
    }

    if (peakCount < 3) return;

    // Scope breakdown counts to the peak window so severity, title, and
    // detail all describe the same set of errors.
    final peakRecords = errorRecords.sublist(peakLeft, peakRight + 1);
    final transportFailures =
        peakRecords.where((r) => r.statusCode == -1).length;
    final serverErrors = peakRecords.where((r) => r.statusCode >= 500).length;

    final severity = peakCount >= 10 || serverErrors >= 5
        ? IssueSeverity.critical
        : IssueSeverity.warning;

    final urlDetails = peakRecords
        .take(5)
        .map((r) => '${r.method.toUpperCase()} ${_shortenUrl(r.url)} — '
            '${r.statusCode == -1 ? 'FAILED' : r.statusCode}')
        .join('\n');

    final (hint, effort) = FixHintBuilder.httpErrorSpike(
      errorCount: peakCount,
      transportFailures: transportFailures,
    );

    _issues.add(PerformanceIssue(
      stableId: 'http_error_spike',
      severity: severity,
      category: IssueCategory.network,
      confidence: IssueConfidence.confirmed,
      title: 'HTTP Error Spike: $peakCount errors in 5s',
      detail: '$peakCount HTTP errors within a 5-second window'
          '${transportFailures > 0 ? ' ($transportFailures transport failures)' : ''}'
          '${serverErrors > 0 ? ' ($serverErrors server errors)' : ''}.\n\n'
          '$urlDetails',
      fixHint: hint,
      fixEffort: effort,
      detectedAt: _clock(),
      confidenceReason: 'Measured directly from HTTP interception',
    ));
  }

  void _evaluateHighFrequencySamePath() {
    // Group all buffered records by normalized URL (method + path, no query
    // params). Flag when ≥3 requests to the same endpoint cluster within
    // 500ms — this is high-frequency traffic to one path that strongly
    // indicates missing cache, un-debounced input, or redundant fetches
    // from multiple widgets. Query strings are intentionally stripped so
    // that pagination / search params still count as the same endpoint
    // for burst detection. Uses the full buffer so evidence persists
    // until route transition clears records.
    // Cancels excluded — an aborted request to the same path is not
    // evidence of missing caching or un-debounced input.
    final recentRecords =
        _records.where((r) => !r.cancelled).toList(growable: false);

    // Group by method + normalized URL
    final groups = <String, List<RequestRecord>>{};
    for (final record in recentRecords) {
      final key = '${record.method.toUpperCase()} ${_normalizeUrl(record.url)}';
      (groups[key] ??= []).add(record);
    }

    for (final entry in groups.entries) {
      final records = entry.value;
      if (records.length < _duplicateThreshold) continue;

      // Only detect duplicates for idempotent methods where repeated
      // identical requests are clearly redundant. POST/PUT/PATCH may
      // hit the same URL with different payloads intentionally.
      final method = entry.key.split(' ').first;
      if (method != 'GET' && method != 'HEAD' && method != 'OPTIONS') continue;

      // Check if at least _duplicateThreshold records cluster within 500ms
      records.sort((a, b) => a.startedAt.compareTo(b.startedAt));
      int maxCluster = 1;
      int clusterStart = 0;
      for (var i = 1; i < records.length; i++) {
        if (records[i]
                .startedAt
                .difference(records[clusterStart].startedAt)
                .inMilliseconds <=
            _duplicateWindowMs) {
          final clusterSize = i - clusterStart + 1;
          if (clusterSize > maxCluster) maxCluster = clusterSize;
        } else {
          clusterStart = i;
        }
      }

      if (maxCluster < _duplicateThreshold) continue;

      final severity = maxCluster >= _criticalDuplicateThreshold
          ? IssueSeverity.critical
          : IssueSeverity.warning;

      final (hint, effort) = FixHintBuilder.highFrequencySamePath(
        url: records.first.url,
        count: maxCluster,
      );

      // Use method+URL fingerprint for stable identity across scans.
      // Index-based IDs jitter when records age in/out of the buffer.
      final fingerprint = entry.key.hashCode.abs().toRadixString(16);
      _issues.add(PerformanceIssue(
        stableId: 'high_frequency_same_path:$fingerprint',
        severity: severity,
        category: IssueCategory.network,
        confidence: IssueConfidence.likely,
        title: 'High-Frequency Requests: ${entry.key.split(' ').first} '
            '${_shortenUrl(records.first.url)} ×$maxCluster in '
            '${_duplicateWindowMs}ms',
        detail: '$maxCluster requests to '
            '${_shortenUrl(records.first.url)} within ${_duplicateWindowMs}ms '
            '(query strings ignored). This often indicates missing caching, '
            'un-debounced input, redundant fetches from multiple widgets, or '
            'a rebuild triggering repeated API calls.',
        fixHint: hint,
        fixEffort: effort,
        detectedAt: _clock(),
        confidenceReason:
            'Request timing correlation + same-path clustering (query stripped)',
      ));
    }
  }

  /// Normalize URL for duplicate comparison: strip query params, keep
  /// scheme + host + path. Different query params to the same endpoint
  /// are treated as the same resource for dedup purposes.
  static String _normalizeUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.replace(query: '', fragment: '').toString();
    } catch (_) {
      return url;
    }
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

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Scope: `slow_request` family only (both warning + critical '
            'tiers pinned by the same hermetic reproducer). Pinning: '
            'direct processRecord boundary tests at 999/1000/2999/3000/3001 ms '
            'plus a loopback HttpServer exercising the full '
            'SleuthHttpOverrides → RequestRecord → processRecord pipeline '
            'across `await for`, `.listen()`, `.drain()`, and `.asFuture()` '
            'consumption paths. An `externallyCited` tier raise for the '
            '1000 ms WARNING tier was staged in v0.16.4 with NNG "Response '
            'Times" as the source of truth but REVERTED post-adversarial-'
            'review: the v0.16.4 `above` capture landed at 3117 ms, which '
            'ambiently brackets the 3000 ms critical tier and provides '
            'dual-use evidence the prose scope boundary cannot un-bracket. '
            'Re-raise deferred to v0.16.5 once (a) an `above` capture is '
            're-recorded within `[1000, 2000)` so it cannot ambiently '
            'bracket the 3000 ms critical tier, (b) severity-scoped '
            'metadata (`coveredThresholds: {"slow_request.warning"}`) is '
            'wired through the audit + ledger, and (c) the schema\'s '
            '`aboveCeilingMultiplier` guard (landed in v0.16.4) '
            'mechanically rejects any drift. Other issue families '
            '(large_response, request_frequency, http_error_spike, '
            'high_frequency_same_path) remain implicitly unvalidated — '
            'see `coveredStableIds`.',
        reproducerPath: 'test/validation/network_monitor_reproducer_test.dart',
        coveredStableIds: {'slow_request'},
      );
}
