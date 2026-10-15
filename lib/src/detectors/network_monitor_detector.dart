import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../network/request_record.dart';
import '../utils/fix_hint_builder.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';

/// Detects slow, excessive, or oversized HTTP requests.
///
/// Receives [RequestRecord]s from the `SleuthHttpOverrides` monitoring
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
  }) : assert(slowThresholdMs >= 0, 'slowThresholdMs must not be negative.'),
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

  /// Errors in the peak 5 s window that raise `http_error_spike`.
  @visibleForTesting
  static const int errorSpikeThreshold = 3;

  /// Errors in the peak 5 s window that make `http_error_spike` critical.
  @visibleForTesting
  static const int errorSpikeCriticalThreshold = 10;

  /// The `high_frequency_same_path` window, threshold and critical count,
  /// exposed for the explanation drift test.
  @visibleForTesting
  static const int duplicateWindowMs = _duplicateWindowMs;
  @visibleForTesting
  static const int duplicateThreshold = _duplicateThreshold;
  @visibleForTesting
  static const int criticalDuplicateThreshold = _criticalDuplicateThreshold;

  final Queue<RequestRecord> _records = Queue<RequestRecord>();
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;
  Timer? _frequencyTimer;

  /// Last observed peak count from the trailing 5 s sliding window.
  /// Computed on every `_evaluateFrequency` call regardless of whether
  /// the count crosses [frequencyLimit] — capture-mode tooling reads
  /// this so the below-leg's exported magnitude reflects what the
  /// detector measured rather than the operator's plan.
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

  int _lastObservedErrorCount = 0;

  /// Most HTTP errors (status 400 or above, or a transport failure)
  /// that started within one 5 s window of the buffer, from the most
  /// recent evaluation, below [errorSpikeThreshold] too. Capture screens
  /// export it for legs where no `http_error_spike` issue fires.
  int get lastObservedErrorCount => _lastObservedErrorCount;

  /// Recomputes [lastObservedErrorCount] without emitting an issue.
  void flushErrorSpikeEvaluation() => _errorPeak();

  int _lastObservedSamePathCluster = 0;

  /// Most GET, HEAD or OPTIONS requests to one path (query stripped)
  /// that started within 500 ms of each other, from the most recent
  /// evaluation, below [duplicateThreshold] too. Capture screens export
  /// it for legs where no `high_frequency_same_path` issue fires.
  int get lastObservedSamePathCluster => _lastObservedSamePathCluster;

  /// Recomputes [lastObservedSamePathCluster] without emitting an issue.
  void flushSamePathEvaluation() => _samePathClusters();

  /// Identities of the last `http_error_spike` and
  /// `high_frequency_same_path` emissions. Each emission's identity is
  /// its `detectedAt`, moved past the previous one when two evaluations
  /// share a clock reading, so capture records never share an identity.
  int _lastErrorIdentityMicros = 0;
  int _lastSamePathIdentityMicros = 0;

  static int _nextIdentity(DateTime at, int previous) {
    final micros = at.microsecondsSinceEpoch;
    return micros > previous ? micros : previous + 1;
  }

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
  /// Called by `SleuthController` on route transitions so that network
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
    _lastObservedErrorCount = 0;
    _lastObservedSamePathCluster = 0;
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

    final worstMs = slowRecords
        .map((r) => r.durationMs)
        .reduce((a, b) => a > b ? a : b);
    final severity = worstMs >= criticalSlowThresholdMs
        ? IssueSeverity.critical
        : IssueSeverity.warning;

    // Build detail listing slow URLs
    final urlDetails = slowRecords
        .map(
          (r) =>
              '${r.method.toUpperCase()} ${_shortenUrl(r.url)} '
              '(${(r.durationMs / 1000).toStringAsFixed(1)}s)',
        )
        .join('\n');

    final (hint, effort) = FixHintBuilder.slowRequest(
      worstUrl: slowRecords.isNotEmpty ? slowRecords.first.url : null,
    );
    final detectedAt = _clock();
    _issues.add(
      PerformanceIssue(
        stableId: 'slow_request',
        severity: severity,
        category: IssueCategory.network,
        confidence: IssueConfidence.confirmed,
        title:
            'Slow Request: ${slowRecords.length} request${slowRecords.length > 1 ? 's' : ''} '
            '> ${(slowThresholdMs / 1000).toStringAsFixed(0)}s '
            '(worst: ${(worstMs / 1000).toStringAsFixed(1)}s)',
        detail:
            '$urlDetails\n\n'
            'Threshold: ${(slowThresholdMs / 1000).toStringAsFixed(0)}s. '
            'The buffer holds ${slowRecords.length} slow '
            'request${slowRecords.length > 1 ? 's' : ''}.',
        fixHint: hint,
        fixEffort: effort,
        detectedAt: detectedAt,
        // Audit gate cross-checks `expectedMagnitude.observed` (operator-
        // Stopwatch) against this detector-side measurement so a regression
        // in HTTP-duration computation cannot certify the wrong magnitude.
        extraTraceArgs: {'observedDurationMs': worstMs.toString()},
        confidenceReason: 'Measured directly from HTTP interception',
      ),
    );
  }

  /// Media responses (images, video, audio, fonts) are large by nature;
  /// `large_response` targets oversized data payloads.
  static bool _isMediaContentType(String? contentType) {
    if (contentType == null) return false;
    final type = contentType.toLowerCase();
    return type.startsWith('image/') ||
        type.startsWith('video/') ||
        type.startsWith('audio/') ||
        type.startsWith('font/');
  }

  void _evaluateLargeResponses() {
    final largeRecords = _records
        .where(
          (r) =>
              r.responseBytes >= largeResponseBytes &&
              !_isMediaContentType(r.contentType),
        )
        .toList();
    if (largeRecords.isEmpty) return;

    final worstBytes = largeRecords
        .map((r) => r.responseBytes)
        .reduce((a, b) => a > b ? a : b);

    final urlDetails = largeRecords
        .map(
          (r) =>
              '${r.method.toUpperCase()} ${_shortenUrl(r.url)} '
              '(${_formatBytes(r.responseBytes)})',
        )
        .join('\n');

    final (hint, effort) = FixHintBuilder.largeResponse(
      worstUrl: largeRecords.isNotEmpty ? largeRecords.first.url : null,
    );
    final detectedAt = _clock();
    _issues.add(
      PerformanceIssue(
        stableId: 'large_response',
        severity: IssueSeverity.warning,
        category: IssueCategory.network,
        confidence: IssueConfidence.confirmed,
        title:
            'Large Response: ${largeRecords.length} response${largeRecords.length > 1 ? 's' : ''} '
            '> ${_formatBytes(largeResponseBytes)} '
            '(largest: ${_formatBytes(worstBytes)})',
        detail:
            '$urlDetails\n\n'
            'Threshold: ${_formatBytes(largeResponseBytes)}. '
            'The buffer holds ${largeRecords.length} large '
            'response${largeRecords.length > 1 ? 's' : ''}.',
        fixHint: hint,
        fixEffort: effort,
        detectedAt: detectedAt,
        dedupIdentityMicros: detectedAt.microsecondsSinceEpoch,
        extraTraceArgs: {'observedResponseBytes': worstBytes.toString()},
        confidenceReason: 'Measured directly from HTTP interception',
      ),
    );
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
    final recordsList = _records
        .where((r) => !r.cancelled)
        .toList(growable: false);
    int peakCount = 0;
    if (recordsList.isNotEmpty) {
      int left = 0;
      for (var right = 0; right < recordsList.length; right++) {
        while (left < right &&
            recordsList[right].startedAt
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
    _issues.add(
      PerformanceIssue(
        stableId: 'request_frequency',
        severity: IssueSeverity.warning,
        category: IssueCategory.network,
        confidence: IssueConfidence.confirmed,
        title:
            'Request Frequency Spike: $peakCount requests in 5s '
            '(limit: $frequencyLimit)',
        detail:
            'The app sent $peakCount HTTP requests within a 5-second window. '
            'Threshold: $frequencyLimit/5s.',
        fixHint: hint,
        fixEffort: effort,
        detectedAt: detectedAt,
        dedupIdentityMicros: detectedAt.microsecondsSinceEpoch,
        extraTraceArgs: {'observedRequestCount': peakCount.toString()},
        confidenceReason: 'Measured directly from HTTP interception',
      ),
    );
  }

  /// The largest 5 s window of error records by start time, as the
  /// error records sorted by `startedAt`, the window's size and its first
  /// index. Records arrive in completion order; a slow error that
  /// finishes after a later one is sorted back into place. Updates
  /// [lastObservedErrorCount].
  ({List<RequestRecord> errors, int count, int left}) _errorPeak() {
    final errors =
        _records
            .where((r) => r.statusCode >= 400 || r.statusCode == -1)
            .toList()
          ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    var peakCount = 0;
    var peakLeft = 0;
    var left = 0;
    for (var right = 0; right < errors.length; right++) {
      while (left < right &&
          errors[right].startedAt
                  .difference(errors[left].startedAt)
                  .inMilliseconds >
              _frequencyWindowMs) {
        left++;
      }
      final windowSize = right - left + 1;
      if (windowSize > peakCount) {
        peakCount = windowSize;
        peakLeft = left;
      }
    }
    _lastObservedErrorCount = peakCount;
    return (errors: errors, count: peakCount, left: peakLeft);
  }

  void _evaluateErrors() {
    final (errors: errorRecords, count: peakCount, left: peakLeft) =
        _errorPeak();
    if (peakCount < errorSpikeThreshold) return;

    // Scope breakdown counts to the peak window so severity, title, and
    // detail all describe the same set of errors.
    final peakRecords = errorRecords.sublist(peakLeft, peakLeft + peakCount);
    final transportFailures = peakRecords
        .where((r) => r.statusCode == -1)
        .length;
    final serverErrors = peakRecords.where((r) => r.statusCode >= 500).length;

    // Severity counts errors only; the detail still reports the 5xx share.
    final severity = peakCount >= errorSpikeCriticalThreshold
        ? IssueSeverity.critical
        : IssueSeverity.warning;

    final urlDetails = peakRecords
        .take(5)
        .map(
          (r) =>
              '${r.method.toUpperCase()} ${_shortenUrl(r.url)} '
              '(${r.statusCode == -1 ? 'FAILED' : r.statusCode})',
        )
        .join('\n');

    final (hint, effort) = FixHintBuilder.httpErrorSpike(
      errorCount: peakCount,
      transportFailures: transportFailures,
    );

    final detectedAt = _clock();
    _lastErrorIdentityMicros = _nextIdentity(
      detectedAt,
      _lastErrorIdentityMicros,
    );
    _issues.add(
      PerformanceIssue(
        stableId: 'http_error_spike',
        severity: severity,
        category: IssueCategory.network,
        confidence: IssueConfidence.confirmed,
        title: 'HTTP Error Spike: $peakCount errors in 5s',
        detail:
            '$peakCount HTTP errors occurred within a 5-second window'
            '${transportFailures > 0 ? ' ($transportFailures transport failures)' : ''}'
            '${serverErrors > 0 ? ' ($serverErrors server errors)' : ''}.\n\n'
            '$urlDetails',
        fixHint: hint,
        fixEffort: effort,
        detectedAt: detectedAt,
        dedupIdentityMicros: _lastErrorIdentityMicros,
        extraTraceArgs: {'observedErrorCount': peakCount.toString()},
        confidenceReason: 'Measured directly from HTTP interception',
      ),
    );
  }

  /// The idempotent request groups (method + path, query stripped) with
  /// their records sorted by `startedAt` and their largest 500 ms
  /// cluster. Updates [lastObservedSamePathCluster].
  List<({String key, List<RequestRecord> records, int cluster})>
  _samePathClusters() {
    // Group all buffered records by normalized URL (method + path, no
    // query params). Query strings are intentionally stripped so that
    // pagination / search params still count as the same endpoint for
    // burst detection. Uses the full buffer so evidence persists until
    // route transition clears records. Cancels excluded — an aborted
    // request to the same path is not evidence of missing caching or
    // un-debounced input.
    final groups = <String, List<RequestRecord>>{};
    for (final record in _records) {
      if (record.cancelled) continue;
      final key = '${record.method.toUpperCase()} ${_normalizeUrl(record.url)}';
      (groups[key] ??= []).add(record);
    }

    final result = <({String key, List<RequestRecord> records, int cluster})>[];
    var largest = 0;
    for (final entry in groups.entries) {
      // Only idempotent methods, where repeated identical requests are
      // clearly redundant. POST/PUT/PATCH may hit the same URL with
      // different payloads intentionally.
      final method = entry.key.split(' ').first;
      if (method != 'GET' && method != 'HEAD' && method != 'OPTIONS') continue;

      // Largest number of requests whose start times lie within 500 ms of
      // each other (inclusive). The left edge slides, so a cluster that
      // begins after an earlier request is still counted in full.
      final records = entry.value
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      var maxCluster = 1;
      var clusterStart = 0;
      for (var i = 1; i < records.length; i++) {
        while (records[i].startedAt
                .difference(records[clusterStart].startedAt)
                .inMilliseconds >
            _duplicateWindowMs) {
          clusterStart++;
        }
        final clusterSize = i - clusterStart + 1;
        if (clusterSize > maxCluster) maxCluster = clusterSize;
      }
      if (maxCluster > largest) largest = maxCluster;
      result.add((key: entry.key, records: records, cluster: maxCluster));
    }
    _lastObservedSamePathCluster = largest;
    return result;
  }

  void _evaluateHighFrequencySamePath() {
    // Flag when ≥3 requests to the same endpoint cluster within 500ms —
    // high-frequency traffic to one path strongly indicates missing
    // cache, un-debounced input, or redundant fetches from multiple
    // widgets.
    for (final (key: key, records: records, cluster: maxCluster)
        in _samePathClusters()) {
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
      final fingerprint = key.hashCode.abs().toRadixString(16);
      final detectedAt = _clock();
      _lastSamePathIdentityMicros = _nextIdentity(
        detectedAt,
        _lastSamePathIdentityMicros,
      );
      _issues.add(
        PerformanceIssue(
          stableId: 'high_frequency_same_path:$fingerprint',
          // The fingerprint hashes the host and port, so capture records
          // carry the bare family name the bracket matches.
          captureTraceStableId: 'high_frequency_same_path',
          severity: severity,
          category: IssueCategory.network,
          confidence: IssueConfidence.likely,
          title:
              'High-Frequency Requests: ${key.split(' ').first} '
              '${_shortenUrl(records.first.url)} ×$maxCluster in '
              '${_duplicateWindowMs}ms',
          detail:
              '$maxCluster requests went to '
              '${_shortenUrl(records.first.url)} within ${_duplicateWindowMs}ms '
              '(query strings ignored). Common causes are missing caching, '
              'input without a debounce, redundant fetches from several '
              'widgets, or a rebuild that repeats API calls.',
          fixHint: hint,
          fixEffort: effort,
          detectedAt: detectedAt,
          dedupIdentityMicros: _lastSamePathIdentityMicros,
          extraTraceArgs: {'observedClusterSize': maxCluster.toString()},
          confidenceReason:
              'Request timing correlation and same-path clustering (query '
              'stripped)',
        ),
      );
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
    rationale:
        'The hermetic reproducer has direct `processRecord` boundary tests '
        'at 999, 1000, 2999, 3000 and 3001 ms. It also runs a loopback '
        '`HttpServer` through the full pipeline, from `SleuthHttpOverrides` '
        'through `_MonitoringHttpClient` and `RequestRecord` to '
        '`processRecord`. Three families ship at runtimeVerified, backed by '
        'on-device captures (iPhone 12, iOS 17.5, Flutter 3.41.x): '
        'slow_request (1000 ms warning), large_response (1 MB warning) and '
        'request_frequency (warning above 30 requests per 5 s sliding '
        'window). The in-app capture helper screen drives the captures '
        'through a loopback HTTP server, and a mode toggle selects the '
        'family. slow_request scenarios delay the response to 800, 1020 and '
        '1500 ms. large_response returns sized payloads (800 KB, 1.05 MB, '
        '1.5 MB). request_frequency spreads N parallel requests across a '
        '5.5 s scenario span and calls '
        '`Sleuth.suspendNonEssentialTimelineStreams` to prevent ring-buffer '
        'overflow on the longer span. Each leg wraps the workload in '
        '`Sleuth.markScenarioBegin/End` markers with a 200 ms dwell after '
        'completion, so detector trace events land inside the scenario '
        'span. The leg then exports the wrapped JSON through the iOS '
        'clipboard. request_frequency uses `atTolerance: 0.50` (at-band '
        '[30, 45]) to absorb iOS scheduling jitter on Dart `HttpClient` '
        'request dispatch. Multiple in-span emissions per scenario carry '
        'distinct `detectedAtMicros` and a `peakCount` that only grows, '
        'which the audit-gate MAX reduction picks. The critical tier '
        '(slow_request 3000 ms) is raised through its own bracket in '
        '`additionalBrackets`. http_error_spike (3 errors in 5 s) and '
        'high_frequency_same_path (3 GETs to one path in 500 ms) warnings '
        'are runtimeVerified on iPhone 12, iOS 17.5 and Flutter 3.47.x. The '
        'loopback server answers 500 for the error legs (2, 3 and 6 errors '
        '700 ms apart), and the same-path legs send 2, 3 and 6 GETs 50 ms '
        'apart. Each leg exports the detector\'s peak count '
        '(`lastObservedErrorCount`, `lastObservedSamePathCluster`), which '
        'it holds below the threshold too. The same-path issue carries '
        '`captureTraceStableId` because its id hashes the host and port. '
        'Both families stay reproducerOnly at critical.',
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
      'http_error_spike': EvidenceTier.runtimeVerified,
      'high_frequency_same_path': EvidenceTier.runtimeVerified,
    },
    coveredThresholds: {'slow_request.warning', 'slow_request.critical'},
    // Captures recorded under v0.18.1+ producer-side dedup, so
    // every in-span trace record carries a distinct
    // `detectedAtMicros`. Opting in locks single-issue replay
    // protection on the audit gate (see ProfileCaptureSchema
    // `requireUniqueDetectedAtMicros`).
    bracketRequireUniqueDetectedAtMicros: true,
    // Detector stamps per-request worst-duration ms into
    // `extraTraceArgs` so the audit gate cross-checks operator-
    // Stopwatch observed against detector-side measurement (closes
    // the wrong-magnitude gap when `magnitudeSourceEventName: ''`
    // bypasses BUILD-derivation). Backward-compatible: pre-arg
    // captures lack the key and the cross-check is skipped per-record.
    observedAxisArgKey: 'observedDurationMs',
    // Tighter than schema default 0.25 because both measurement
    // paths (operator Stopwatch, detector RequestRecord.durationMs)
    // wrap the same loopback round-trip and routinely agree to the
    // millisecond — a 10 % tolerance still absorbs scheduler jitter
    // while catching small constant-offset regressions a 25 % band
    // would silently pass.
    observedAxisTolerance: 0.10,
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
      // Critical-tier bracket (3000 ms = 3× warning). atTolerance
      // 0.40 (at-band [3000, 4200]) is forward-compat re-record
      // headroom — wider than warning's 0.10 because the operator
      // targets 3000+ ms on a stub HTTP server with iOS scheduler +
      // network RTT variance. Tighter than HeavyCompute's 0.60
      // because network-bound work is more deterministic than CPU-
      // bound thermal drift. Above-ceiling 6000 ms (no super-tier
      // above; iOS NSURLSession 60 s default leaves comfortable
      // margin). Cross-spec uniqueness tuple
      // (stableId, severityLabel, argKey) distinguishes this from
      // the canonical warning bracket via severityLabel.
      BracketSpec(
        stableId: 'slow_request',
        severityLabel: 'critical',
        threshold: 3000,
        unit: 'ms',
        coveredThresholds: {'slow_request.critical'},
        profileCapturePaths: [
          'test/validation/captures/network_monitor/slow_request_critical_below.json',
          'test/validation/captures/network_monitor/slow_request_critical_at.json',
          'test/validation/captures/network_monitor/slow_request_critical_above.json',
        ],
        atTolerance: 0.40,
        aboveCeilingMultiplier: 2.0,
        observedAxisArgKey: 'observedDurationMs',
        // Same tighter tolerance as canonical bracket — loopback
        // measurement paths agree to the millisecond.
        observedAxisTolerance: 0.10,
        requireUniqueDetectedAtMicros: true,
        requireDetectorTraceRecord: true,
      ),
      // Warning brackets for the two count families. Both fire at 3 or
      // more and turn critical at 10, so the above ceiling of 2.5 (7.5)
      // keeps the above leg a warning. The exported magnitude and the
      // stamped arg are the same detector peak, hence the tight
      // observed-axis tolerance.
      BracketSpec(
        stableId: 'http_error_spike',
        severityLabel: 'warning',
        threshold: 3,
        unit: 'events',
        coveredThresholds: {'http_error_spike.warning'},
        profileCapturePaths: [
          'test/validation/captures/network_monitor/http_error_spike_below.json',
          'test/validation/captures/network_monitor/http_error_spike_at.json',
          'test/validation/captures/network_monitor/http_error_spike_above.json',
        ],
        atTolerance: 0.5,
        aboveCeilingMultiplier: 2.5,
        observedAxisArgKey: 'observedErrorCount',
        observedAxisTolerance: 0.10,
        requireUniqueDetectedAtMicros: true,
        requireDetectorTraceRecord: true,
      ),
      BracketSpec(
        stableId: 'high_frequency_same_path',
        severityLabel: 'warning',
        threshold: 3,
        unit: 'events',
        coveredThresholds: {'high_frequency_same_path.warning'},
        profileCapturePaths: [
          'test/validation/captures/network_monitor/high_frequency_same_path_below.json',
          'test/validation/captures/network_monitor/high_frequency_same_path_at.json',
          'test/validation/captures/network_monitor/high_frequency_same_path_above.json',
        ],
        atTolerance: 0.5,
        aboveCeilingMultiplier: 2.5,
        observedAxisArgKey: 'observedClusterSize',
        observedAxisTolerance: 0.10,
        requireUniqueDetectedAtMicros: true,
        requireDetectorTraceRecord: true,
      ),
    ],
  );
}
