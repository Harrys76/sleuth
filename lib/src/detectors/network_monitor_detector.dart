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

  /// Last observed peak count from the trailing 5 s sliding window.
  /// Computed on every `_evaluateFrequency` call regardless of whether
  /// the count crosses [frequencyLimit] — capture-mode tooling reads
  /// this so the below-leg's exported magnitude reflects what the
  /// detector measured rather than the operator's plan.
  // _evaluateFrequency rewrites this on every tick and clearRecords
  // resets it on session boundaries; cannot be final.
  // ignore: prefer_final_fields
  int _lastObservedPeakCount = 0;

  /// Detector-measured peak count from the most recent
  /// [_evaluateFrequency] call. Capture-mode operators export this
  /// for sub-threshold legs where no warning event fires.
  int get lastObservedPeakCount => _lastObservedPeakCount;

  /// Recomputes [lastObservedPeakCount] without emitting any
  /// `request_frequency` issue. Capture screens call this before
  /// reading the peak getter so the operator's export pathway is
  /// decoupled from the periodic `_frequencyTimer` phase. Idempotent —
  /// repeated calls with the same buffer yield the same peak value
  /// and do NOT append duplicate issues to `_issues` (issue emission
  /// is owned by [_evaluateFrequency], which only runs from the scan
  /// pipeline's `_evaluate` wrapper that clears `_issues` first).
  void flushFrequencyEvaluation() => _recomputeFrequencyPeak();

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
    _lastObservedPeakCount = 0;
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
    final detectedAt = _clock();
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
      detectedAt: detectedAt,
      dedupIdentityMicros: detectedAt.microsecondsSinceEpoch,
      extraTraceArgs: {'observedResponseBytes': worstBytes.toString()},
      confidenceReason: 'Measured directly from HTTP interception',
    ));
  }

  /// Pure peak recompute — updates [_lastObservedPeakCount] only,
  /// never appends to `_issues`. Issue emission is owned by
  /// [_evaluateFrequency]. Split so [flushFrequencyEvaluation]
  /// (capture-mode tooling) can refresh the peak getter without
  /// minting duplicate `request_frequency` issues each call. _records
  /// is capped at _bufferCapacity (200), so the window scan is O(200)
  /// bounded.
  void _recomputeFrequencyPeak() {
    // Cancels are excluded from frequency classification — a prefetch
    // that the caller aborts is not evidence of a noisy endpoint.
    final recordsList =
        _records.where((r) => !r.cancelled).toList(growable: false);
    int peakCount = 0;
    if (recordsList.isNotEmpty) {
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
    }
    _lastObservedPeakCount = peakCount;
  }

  void _evaluateFrequency() {
    _recomputeFrequencyPeak();
    final peakCount = _lastObservedPeakCount;
    if (peakCount <= frequencyLimit) return;

    final (hint, effort) = FixHintBuilder.requestFrequency();
    final detectedAt = _clock();
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
      detectedAt: detectedAt,
      dedupIdentityMicros: detectedAt.microsecondsSinceEpoch,
      extraTraceArgs: {'observedRequestCount': peakCount.toString()},
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
        rationale: 'Hermetic reproducer: direct `processRecord` boundary '
            'tests at 999/1000/2999/3000/3001 ms plus a loopback '
            '`HttpServer` exercising the full `SleuthHttpOverrides` → '
            '`_MonitoringHttpClient` → `RequestRecord` → `processRecord` '
            'pipeline. Three families ship at runtimeVerified backed by '
            'on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.x): '
            'slow_request (1000 ms warning), large_response (1 MB warning), '
            'and request_frequency (>30 req per 5 s sliding window '
            'warning). Captures driven by the in-app capture helper '
            'screen via a loopback HTTP server; mode toggle selects '
            'family. slow_request scenarios delay the response to '
            '800/1020/1500 ms; large_response returns sized payloads '
            '(800 KB / 1.05 MB / 1.5 MB); request_frequency spreads N '
            'parallel requests across a 5.5 s scenario span with '
            '`Sleuth.suspendNonEssentialTimelineStreams` to prevent '
            'ring-buffer overflow on the longer span. Each leg brackets '
            'the workload in `Sleuth.markScenarioBegin/End` markers with '
            'a 200 ms post-completion dwell so detector trace events '
            'land inside the scenario span, then exports the wrapped '
            'JSON via the iOS clipboard. request_frequency uses '
            '`atTolerance: 0.50` (at-band [30, 45]) to absorb iOS '
            'scheduling jitter on Dart `HttpClient` request dispatch; '
            'multiple in-span emissions per scenario carry distinct '
            '`detectedAtMicros` and a monotone-growing `peakCount` that '
            'the audit-gate MAX reduction picks. Critical tier '
            '(slow_request 3000 ms) and the two unraised families '
            '(http_error_spike, high_frequency_same_path) stay '
            'reproducerOnly.',
        reproducerPath: 'test/validation/network_monitor_reproducer_test.dart',
        profileCapturePaths: [
          'test/validation/captures/network_monitor/slow_request_below.json',
          'test/validation/captures/network_monitor/slow_request_at.json',
          'test/validation/captures/network_monitor/slow_request_above.json',
        ],
        bracketThreshold: 1000,
        bracketUnit: 'ms',
        bracketStableId: 'slow_request',
        bracketSeverityLabel: 'warning',
        // Default 2.0 → above-ceiling = 2000 ms, well below the 3000 ms
        // critical threshold so the above-bracket capture cannot
        // ambiently bracket the critical tier. Explicit declaration is
        // required by the audit when `coveredThresholds` is set.
        aboveCeilingMultiplier: 2.0,
        coveredStableIds: {
          'slow_request',
          'large_response',
          'request_frequency',
          'http_error_spike',
          'high_frequency_same_path',
        },
        perStableIdTier: {
          'slow_request': EvidenceTier.runtimeVerified,
          'large_response': EvidenceTier.runtimeVerified,
          'request_frequency': EvidenceTier.runtimeVerified,
        },
        coveredThresholds: {'slow_request.warning'},
        // Captures recorded under v0.18.1+ producer-side dedup, so
        // every in-span trace record carries a distinct
        // `detectedAtMicros`. Opting in locks single-issue replay
        // protection on the audit gate (see ProfileCaptureSchema
        // `requireUniqueDetectedAtMicros`).
        bracketRequireUniqueDetectedAtMicros: true,
        additionalBrackets: [
          BracketSpec(
            stableId: 'large_response',
            severityLabel: 'warning',
            threshold: 1048576,
            unit: 'bytes',
            coveredThresholds: {'large_response.warning'},
            profileCapturePaths: [
              'test/validation/captures/network_monitor/large_response_below.json',
              'test/validation/captures/network_monitor/large_response_at.json',
              'test/validation/captures/network_monitor/large_response_above.json',
            ],
            atTolerance: 0.10,
            aboveCeilingMultiplier: 2.0,
            observedAxisArgKey: 'observedResponseBytes',
            requireUniqueDetectedAtMicros: true,
            requireDetectorTraceRecord: true,
          ),
          BracketSpec(
            stableId: 'request_frequency',
            severityLabel: 'warning',
            threshold: 30,
            unit: 'events',
            coveredThresholds: {'request_frequency.warning'},
            profileCapturePaths: [
              'test/validation/captures/network_monitor/request_frequency_below.json',
              'test/validation/captures/network_monitor/request_frequency_at.json',
              'test/validation/captures/network_monitor/request_frequency_above.json',
            ],
            // iOS scheduling jitter on Dart HttpClient request dispatch
            // makes ±10% unreachable; ±50% gives at-band [30, 45].
            atTolerance: 0.50,
            aboveCeilingMultiplier: 2.0,
            observedAxisArgKey: 'observedRequestCount',
            requireUniqueDetectedAtMicros: true,
            requireDetectorTraceRecord: true,
          ),
        ],
      );
}
