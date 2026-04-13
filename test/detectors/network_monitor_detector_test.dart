import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/network_monitor_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/network/request_record.dart';

RequestRecord makeRecord({
  String url = 'https://example.com/api/data',
  String method = 'GET',
  int statusCode = 200,
  int durationMs = 150,
  int responseBytes = 4096,
  DateTime? startedAt,
}) {
  return RequestRecord(
    url: url,
    method: method,
    statusCode: statusCode,
    durationMs: durationMs,
    responseBytes: responseBytes,
    startedAt: startedAt ?? DateTime(2026, 1, 1),
  );
}

void main() {
  group('NetworkMonitorDetector', () {
    late NetworkMonitorDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1);
      detector = NetworkMonitorDetector(clock: () => fakeNow);
    });

    tearDown(() => detector.dispose());

    test('no issues when disabled', () {
      detector.isEnabled = false;
      detector.processRecord(makeRecord(durationMs: 5000));
      expect(detector.issues, isEmpty);
    });

    // ---------------------------------------------------------------
    // Slow request detection
    // ---------------------------------------------------------------

    test('no slow issue when duration below threshold', () {
      detector.processRecord(makeRecord(durationMs: 1999));
      expect(detector.issues, isEmpty);
    });

    test('slow issue at exactly threshold', () {
      detector.processRecord(makeRecord(durationMs: 2000));
      expect(detector.issues.where((i) => i.stableId == 'slow_request'),
          hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    test('critical at exactly 5s', () {
      detector.processRecord(makeRecord(durationMs: 5000));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    test('slow request detail contains URL and duration', () {
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'POST',
        durationMs: 3200,
      ));
      final issue = detector.issues.first;
      expect(issue.detail, contains('POST'));
      expect(issue.detail, contains('/users'));
      expect(issue.detail, contains('3.2s'));
    });

    // ---------------------------------------------------------------
    // Large response detection
    // ---------------------------------------------------------------

    test('no large issue when response below threshold', () {
      detector.processRecord(makeRecord(responseBytes: 1048575)); // 1MB - 1
      final largeIssues =
          detector.issues.where((i) => i.stableId == 'large_response');
      expect(largeIssues, isEmpty);
    });

    test('large issue at exactly threshold', () {
      detector.processRecord(makeRecord(responseBytes: 1048576));
      final largeIssues =
          detector.issues.where((i) => i.stableId == 'large_response');
      expect(largeIssues, hasLength(1));
      expect(largeIssues.first.severity, IssueSeverity.warning);
    });

    test('large response detail contains URL and size', () {
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/images',
        responseBytes: 2097152, // 2MB
      ));
      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'large_response');
      expect(issue.detail, contains('/images'));
      expect(issue.detail, contains('2.0 MB'));
    });

    // ---------------------------------------------------------------
    // Frequency spike detection
    // ---------------------------------------------------------------

    test('no frequency issue when count within limit', () {
      for (int i = 0; i < 30; i++) {
        detector.processRecord(makeRecord(startedAt: fakeNow));
      }
      final freqIssues =
          detector.issues.where((i) => i.stableId == 'request_frequency');
      expect(freqIssues, isEmpty);
    });

    test('warning when frequency spike exceeded (>30 in 5s)', () {
      for (int i = 0; i < 31; i++) {
        detector.processRecord(makeRecord(startedAt: fakeNow));
      }
      final freqIssues =
          detector.issues.where((i) => i.stableId == 'request_frequency');
      expect(freqIssues, hasLength(1));
      expect(freqIssues.first.severity, IssueSeverity.warning);
    });

    test('frequency spike detail contains count and threshold', () {
      for (int i = 0; i < 35; i++) {
        detector.processRecord(makeRecord(startedAt: fakeNow));
      }
      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'request_frequency');
      expect(issue.detail, contains('35'));
      expect(issue.detail, contains('30/5s'));
    });

    // ---------------------------------------------------------------
    // stableId, confidence, category
    // ---------------------------------------------------------------

    test('stableId, confidence, and category for slow request', () {
      detector.processRecord(makeRecord(durationMs: 3000));
      final issue = detector.issues.first;
      expect(issue.stableId, 'slow_request');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.network);
    });

    test('stableId, confidence, and category for large response', () {
      detector.processRecord(makeRecord(responseBytes: 2000000));
      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'large_response');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.network);
    });

    test('stableId, confidence, and category for frequency spike', () {
      for (int i = 0; i < 31; i++) {
        detector.processRecord(makeRecord(startedAt: fakeNow));
      }
      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'request_frequency');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.network);
    });

    // ---------------------------------------------------------------
    // Fix hints
    // ---------------------------------------------------------------

    test('slow request fixHint contains actionable advice', () {
      detector.processRecord(makeRecord(durationMs: 3000));
      expect(detector.issues.first.fixHint, contains('caching'));
    });

    test('large response fixHint mentions pagination or compression', () {
      detector.processRecord(makeRecord(responseBytes: 2000000));
      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'large_response');
      expect(issue.fixHint, contains('Paginate'));
    });

    test('frequency spike fixHint mentions batching', () {
      for (int i = 0; i < 31; i++) {
        detector.processRecord(makeRecord(startedAt: fakeNow));
      }
      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'request_frequency');
      expect(issue.fixHint, contains('Batch'));
    });

    test('frequency spike persists until clearRecords', () {
      // Fire 31 requests at t=0
      for (int i = 0; i < 31; i++) {
        detector.processRecord(makeRecord(startedAt: fakeNow));
      }
      expect(detector.issues.where((i) => i.stableId == 'request_frequency'),
          hasLength(1));

      // Advance 10 seconds — well past the 5s detection window, but
      // records still in buffer. Issue should persist.
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      detector.processRecord(makeRecord(startedAt: fakeNow));
      expect(detector.issues.where((i) => i.stableId == 'request_frequency'),
          hasLength(1));

      // Route transition clears records — issue disappears.
      detector.clearRecords();
      expect(detector.issues, isEmpty);
      expect(detector.records, isEmpty);
    });

    // ---------------------------------------------------------------
    // Buffer bounds and issue lifecycle
    // ---------------------------------------------------------------

    test('buffer evicts oldest record after 200 entries', () {
      for (int i = 0; i < 201; i++) {
        detector.processRecord(makeRecord(
          url: 'https://example.com/api/$i',
          startedAt: fakeNow,
        ));
      }
      expect(detector.records, hasLength(200));
      // First record (index 0) should be evicted; first should be index 1
      expect(detector.records.first.url, 'https://example.com/api/1');
    });

    test('slow issue disappears after triggering record evicted', () {
      // Add one slow record
      detector.processRecord(makeRecord(durationMs: 3000));
      expect(detector.issues.where((i) => i.stableId == 'slow_request'),
          hasLength(1));

      // Fill buffer with 200 fast records to push out the slow one
      for (int i = 0; i < 200; i++) {
        detector.processRecord(makeRecord(
          durationMs: 100,
          startedAt: fakeNow,
        ));
      }
      expect(
          detector.issues.where((i) => i.stableId == 'slow_request'), isEmpty);
    });

    test('clearRecords clears all records and issues', () {
      detector.processRecord(makeRecord(durationMs: 3000, startedAt: fakeNow));
      expect(detector.issues.where((i) => i.stableId == 'slow_request'),
          hasLength(1));
      expect(detector.records, isNotEmpty);

      // Simulate route transition
      detector.clearRecords();
      expect(detector.issues, isEmpty);
      expect(detector.records, isEmpty);
    });

    test('new records after clearRecords evaluated independently', () {
      // Add a slow record, then clear (simulating route change)
      detector.processRecord(makeRecord(durationMs: 3000, startedAt: fakeNow));
      expect(detector.issues, isNotEmpty);

      detector.clearRecords();
      expect(detector.issues, isEmpty);

      // New fast record on the new page — no issues
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processRecord(makeRecord(durationMs: 100, startedAt: fakeNow));
      expect(
          detector.issues.where((i) => i.stableId == 'slow_request'), isEmpty);
      expect(detector.records, hasLength(1));
    });

    test('in-flight responses from previous page dropped after clearRecords',
        () {
      // Simulate: request started at t=0 on page A
      final requestStartedAt = fakeNow;

      // Navigate at t=1s — clearRecords called
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.clearRecords();

      // Response arrives at t=3s (slow request from page A)
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processRecord(makeRecord(
        durationMs: 3000,
        startedAt: requestStartedAt, // started before clear
      ));

      // Should be silently dropped — no issues on home page
      expect(detector.issues, isEmpty);
      expect(detector.records, isEmpty);
    });

    test('requests started after clearRecords are accepted', () {
      // Navigate at t=0
      detector.clearRecords();

      // New request starts at t=1s on the new page
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processRecord(makeRecord(
        durationMs: 3000,
        startedAt: fakeNow, // started after clear
      ));

      // Should be accepted — issue shows on new page
      expect(detector.issues.where((i) => i.stableId == 'slow_request'),
          hasLength(1));
      expect(detector.records, hasLength(1));
    });

    // ---------------------------------------------------------------
    // Custom thresholds
    // ---------------------------------------------------------------

    test('custom slow threshold works', () {
      detector = NetworkMonitorDetector(
        slowThresholdMs: 500,
        clock: () => fakeNow,
      );
      detector.processRecord(makeRecord(durationMs: 600));
      expect(detector.issues.where((i) => i.stableId == 'slow_request'),
          hasLength(1));
    });

    test('custom frequency limit works', () {
      detector = NetworkMonitorDetector(
        frequencyLimit: 5,
        clock: () => fakeNow,
      );
      for (int i = 0; i < 6; i++) {
        detector.processRecord(makeRecord(startedAt: fakeNow));
      }
      expect(detector.issues.where((i) => i.stableId == 'request_frequency'),
          hasLength(1));
    });

    test('custom large response threshold works', () {
      detector = NetworkMonitorDetector(
        largeResponseBytes: 1024,
        clock: () => fakeNow,
      );
      detector.processRecord(makeRecord(responseBytes: 2048));
      expect(detector.issues.where((i) => i.stableId == 'large_response'),
          hasLength(1));
    });

    // ---------------------------------------------------------------
    // Mixed scenarios
    // ---------------------------------------------------------------

    test('slow + large + frequency simultaneously → 3 issues', () {
      detector = NetworkMonitorDetector(
        frequencyLimit: 3,
        clock: () => fakeNow,
      );
      // Add a slow + large record
      detector.processRecord(makeRecord(
        durationMs: 5000,
        responseBytes: 2000000,
        startedAt: fakeNow,
      ));
      // Add more records with different URLs to trigger frequency without duplicates
      for (int i = 0; i < 3; i++) {
        detector.processRecord(makeRecord(
          url: 'https://example.com/api/endpoint$i',
          startedAt: fakeNow,
        ));
      }
      expect(detector.issues, hasLength(3));
      expect(detector.issues.map((i) => i.stableId).toSet(), {
        'slow_request',
        'large_response',
        'request_frequency',
      });
    });

    // ---------------------------------------------------------------
    // HTTP error spike detection
    // ---------------------------------------------------------------

    test('no error spike with fewer than 3 errors', () {
      for (int i = 0; i < 2; i++) {
        detector.processRecord(makeRecord(
          statusCode: 500,
          startedAt: fakeNow.add(Duration(milliseconds: i * 100)),
        ));
      }
      final errorIssues =
          detector.issues.where((i) => i.stableId == 'http_error_spike');
      expect(errorIssues, isEmpty);
    });

    test('error spike at 3 errors in 5s window', () {
      for (int i = 0; i < 3; i++) {
        detector.processRecord(makeRecord(
          statusCode: 500,
          startedAt: fakeNow.add(Duration(milliseconds: i * 100)),
        ));
      }
      final errorIssues =
          detector.issues.where((i) => i.stableId == 'http_error_spike');
      expect(errorIssues, hasLength(1));
      expect(errorIssues.first.severity, IssueSeverity.warning);
      expect(errorIssues.first.confidence, IssueConfidence.confirmed);
      expect(errorIssues.first.category, IssueCategory.network);
    });

    test('error spike uses peak 5s window, not entire buffer', () {
      // Spread 4 errors across 20 seconds — no 5s window has 3
      for (int i = 0; i < 4; i++) {
        detector.processRecord(makeRecord(
          statusCode: 500,
          startedAt: fakeNow.add(Duration(seconds: i * 6)),
        ));
      }
      final errorIssues =
          detector.issues.where((i) => i.stableId == 'http_error_spike');
      expect(errorIssues, isEmpty,
          reason: 'Each 5s window has at most 1 error');
    });

    test('error spike critical at 10+ errors in 5s window', () {
      for (int i = 0; i < 10; i++) {
        detector.processRecord(makeRecord(
          statusCode: 500,
          startedAt: fakeNow.add(Duration(milliseconds: i * 100)),
        ));
      }
      final errorIssues =
          detector.issues.where((i) => i.stableId == 'http_error_spike');
      expect(errorIssues, hasLength(1));
      expect(errorIssues.first.severity, IssueSeverity.critical);
    });

    test('error spike critical at 5+ server errors in peak window', () {
      for (int i = 0; i < 5; i++) {
        detector.processRecord(makeRecord(
          statusCode: 502,
          startedAt: fakeNow.add(Duration(milliseconds: i * 100)),
        ));
      }
      final errorIssues =
          detector.issues.where((i) => i.stableId == 'http_error_spike');
      expect(errorIssues, hasLength(1));
      expect(errorIssues.first.severity, IssueSeverity.critical);
    });

    test('error spike severity uses peak window counts, not buffer-wide', () {
      // 6 server errors spread over 25s — peak 5s window has only 2
      // plus 1 transport failure in the same window = 3 total errors
      // but only 2 server errors in peak → should be warning, not critical
      detector.processRecord(makeRecord(
        statusCode: 500,
        startedAt: fakeNow,
      ));
      detector.processRecord(makeRecord(
        statusCode: 500,
        startedAt: fakeNow.add(const Duration(milliseconds: 100)),
      ));
      detector.processRecord(makeRecord(
        statusCode: -1,
        startedAt: fakeNow.add(const Duration(milliseconds: 200)),
      ));
      // Gap > 5s
      detector.processRecord(makeRecord(
        statusCode: 500,
        startedAt: fakeNow.add(const Duration(seconds: 10)),
      ));
      detector.processRecord(makeRecord(
        statusCode: 500,
        startedAt: fakeNow.add(const Duration(seconds: 15)),
      ));
      detector.processRecord(makeRecord(
        statusCode: 500,
        startedAt: fakeNow.add(const Duration(seconds: 20)),
      ));
      final errorIssues =
          detector.issues.where((i) => i.stableId == 'http_error_spike');
      expect(errorIssues, hasLength(1));
      // Peak window has 3 errors (2 server + 1 transport) — warning
      expect(errorIssues.first.severity, IssueSeverity.warning);
    });

    test('transport failures reported in error spike detail', () {
      for (int i = 0; i < 3; i++) {
        detector.processRecord(makeRecord(
          statusCode: -1,
          startedAt: fakeNow.add(Duration(milliseconds: i * 100)),
        ));
      }
      final issue =
          detector.issues.firstWhere((i) => i.stableId == 'http_error_spike');
      expect(issue.detail, contains('transport failures'));
      expect(issue.title, contains('3 errors'));
    });

    test('4xx errors counted in error spike', () {
      for (int i = 0; i < 3; i++) {
        detector.processRecord(makeRecord(
          statusCode: 404,
          startedAt: fakeNow.add(Duration(milliseconds: i * 100)),
        ));
      }
      final errorIssues =
          detector.issues.where((i) => i.stableId == 'http_error_spike');
      expect(errorIssues, hasLength(1));
    });

    // ---------------------------------------------------------------
    // clearRecords completeness
    // ---------------------------------------------------------------

    test('clearRecords clears active requests', () {
      detector.startRequest(1, fakeNow);
      detector.startRequest(2, fakeNow);
      expect(detector.pendingRequestSnapshot().$1, 2);

      detector.clearRecords();
      expect(detector.pendingRequestSnapshot().$1, 0);
    });

    // ---------------------------------------------------------------
    // Dispose
    // ---------------------------------------------------------------

    test('dispose clears issues, records, and cancels timer', () {
      detector.processRecord(makeRecord(durationMs: 3000, startedAt: fakeNow));
      expect(detector.issues, isNotEmpty);
      expect(detector.records, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.records, isEmpty);
    });

    // ---------------------------------------------------------------
    // Records exposed for export
    // ---------------------------------------------------------------

    test('records getter returns unmodifiable view', () {
      detector.processRecord(makeRecord());
      expect(detector.records, hasLength(1));
      expect(() => (detector.records as List).add(makeRecord()),
          throwsUnsupportedError);
    });

    // ---------------------------------------------------------------
    // Active request tracking (v5.6)
    // ---------------------------------------------------------------

    test('pendingRequestSnapshot returns (0, null) when no active requests',
        () {
      final (count, slowestMs) = detector.pendingRequestSnapshot();
      expect(count, 0);
      expect(slowestMs, isNull);
    });

    test('startRequest/endRequest tracks in-flight requests correctly', () {
      detector.startRequest(1, fakeNow);
      detector.startRequest(2, fakeNow);

      var (count, _) = detector.pendingRequestSnapshot();
      expect(count, 2);

      detector.endRequest(1);
      (count, _) = detector.pendingRequestSnapshot();
      expect(count, 1);

      detector.endRequest(2);
      (count, _) = detector.pendingRequestSnapshot();
      expect(count, 0);
    });

    test('pendingRequestSnapshot reports slowest pending duration', () {
      final earlyStart = fakeNow.subtract(const Duration(seconds: 3));
      final lateStart = fakeNow.subtract(const Duration(seconds: 1));

      detector.startRequest(1, earlyStart);
      detector.startRequest(2, lateStart);

      final (count, slowestMs) = detector.pendingRequestSnapshot();
      expect(count, 2);
      expect(slowestMs, 3000);
    });

    test('active requests cleared on disable', () {
      detector.startRequest(1, fakeNow);
      detector.isEnabled = false;

      final (count, _) = detector.pendingRequestSnapshot();
      expect(count, 0);
    });

    test('active requests cleared on dispose', () {
      detector.startRequest(1, fakeNow);
      detector.dispose();

      final (count, _) = detector.pendingRequestSnapshot();
      expect(count, 0);
    });

    // ---------------------------------------------------------------
    // High-frequency same-path detection (v11.15, renamed v0.14.2)
    // ---------------------------------------------------------------

    test('3 identical GET requests within 500ms flagged as duplicate', () {
      final base = fakeNow;
      for (int i = 0; i < 3; i++) {
        detector.processRecord(makeRecord(
          url: 'https://api.example.com/users?page=1',
          method: 'GET',
          startedAt: base.add(Duration(milliseconds: i * 100)),
        ));
      }
      final dupIssues = detector.issues.where(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(dupIssues, hasLength(1));
      expect(dupIssues.first.severity, IssueSeverity.warning);
      expect(dupIssues.first.confidence, IssueConfidence.likely);
      expect(dupIssues.first.category, IssueCategory.network);
    });

    test('2 identical requests NOT flagged (below threshold)', () {
      final base = fakeNow;
      for (int i = 0; i < 2; i++) {
        detector.processRecord(makeRecord(
          url: 'https://api.example.com/users',
          method: 'GET',
          startedAt: base.add(Duration(milliseconds: i * 100)),
        ));
      }
      final dupIssues = detector.issues.where(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(dupIssues, isEmpty);
    });

    test('same URL but different methods not grouped as duplicates', () {
      final base = fakeNow;
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'GET',
        startedAt: base,
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'POST',
        startedAt: base.add(const Duration(milliseconds: 100)),
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'PUT',
        startedAt: base.add(const Duration(milliseconds: 200)),
      ));
      final dupIssues = detector.issues.where(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(dupIssues, isEmpty);
    });

    test('requests exactly 500ms apart are still clustered', () {
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'GET',
        startedAt: fakeNow,
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'GET',
        startedAt: fakeNow.add(const Duration(milliseconds: 250)),
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'GET',
        startedAt: fakeNow.add(const Duration(milliseconds: 500)),
      ));
      final dupIssues = detector.issues.where(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(dupIssues, hasLength(1),
          reason: '500ms span (0→500) should be within window (<=500ms)');
    });

    test('requests at 501ms apart are NOT clustered', () {
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'GET',
        startedAt: fakeNow,
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'GET',
        startedAt: fakeNow.add(const Duration(milliseconds: 250)),
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'GET',
        startedAt: fakeNow.add(const Duration(milliseconds: 501)),
      ));
      final dupIssues = detector.issues.where(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(dupIssues, isEmpty, reason: '501ms span exceeds 500ms window');
    });

    test('severity critical at 10+ duplicate requests', () {
      final base = fakeNow;
      for (int i = 0; i < 10; i++) {
        detector.processRecord(makeRecord(
          url: 'https://api.example.com/data',
          method: 'GET',
          startedAt: base.add(Duration(milliseconds: i * 40)),
        ));
      }
      final dupIssues = detector.issues.where(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(dupIssues, hasLength(1));
      expect(dupIssues.first.severity, IssueSeverity.critical);
    });

    test('different query params treated as same endpoint for dedup', () {
      final base = fakeNow;
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users?page=1',
        method: 'GET',
        startedAt: base,
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users?page=2',
        method: 'GET',
        startedAt: base.add(const Duration(milliseconds: 100)),
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users?page=3',
        method: 'GET',
        startedAt: base.add(const Duration(milliseconds: 200)),
      ));
      final dupIssues = detector.issues.where(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(dupIssues, hasLength(1));
    });

    test('maxCluster tracks largest cluster when later cluster is smaller', () {
      // Regression: [0ms, 100ms, 200ms, 700ms, 800ms]
      // First cluster=3, second cluster=2. maxCluster should be 3.
      final base = fakeNow;
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/data',
        method: 'GET',
        startedAt: base,
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/data',
        method: 'GET',
        startedAt: base.add(const Duration(milliseconds: 100)),
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/data',
        method: 'GET',
        startedAt: base.add(const Duration(milliseconds: 200)),
      ));
      // Gap > 500ms
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/data',
        method: 'GET',
        startedAt: base.add(const Duration(milliseconds: 700)),
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/data',
        method: 'GET',
        startedAt: base.add(const Duration(milliseconds: 800)),
      ));
      final dupIssues = detector.issues.where(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(dupIssues, hasLength(1),
          reason: 'First cluster of 3 should exceed threshold');
    });

    test('duplicate fixHint mentions caching and deduplication', () {
      final base = fakeNow;
      for (int i = 0; i < 3; i++) {
        detector.processRecord(makeRecord(
          url: 'https://api.example.com/users',
          method: 'GET',
          startedAt: base.add(Duration(milliseconds: i * 100)),
        ));
      }
      final issue = detector.issues.firstWhere(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(issue.fixHint, contains('Cache'));
      expect(issue.fixHint, contains('Deduplicate'));
    });

    test('stableId is URL-derived, not index-based', () {
      final base = fakeNow;
      // Add duplicates for two different endpoints
      for (int i = 0; i < 3; i++) {
        detector.processRecord(makeRecord(
          url: 'https://api.example.com/users',
          method: 'GET',
          startedAt: base.add(Duration(milliseconds: i * 100)),
        ));
        detector.processRecord(makeRecord(
          url: 'https://api.example.com/posts',
          method: 'GET',
          startedAt: base.add(Duration(milliseconds: i * 100)),
        ));
      }

      final dupIssues = detector.issues
          .where(
              (i) => i.stableId?.startsWith('high_frequency_same_path') == true)
          .toList();
      expect(dupIssues, hasLength(2));

      // Each stableId should be stable (URL-derived fingerprint)
      final ids = dupIssues.map((i) => i.stableId).toSet();
      expect(ids.length, 2, reason: 'Each endpoint should have a distinct ID');

      // Re-process same records — IDs should be identical
      fakeNow = base; // reset clock
      final detector2 = NetworkMonitorDetector(clock: () => fakeNow);
      for (int i = 0; i < 3; i++) {
        detector2.processRecord(makeRecord(
          url: 'https://api.example.com/users',
          method: 'GET',
          startedAt: base.add(Duration(milliseconds: i * 100)),
        ));
        detector2.processRecord(makeRecord(
          url: 'https://api.example.com/posts',
          method: 'GET',
          startedAt: base.add(Duration(milliseconds: i * 100)),
        ));
      }
      final ids2 = detector2.issues
          .where(
              (i) => i.stableId?.startsWith('high_frequency_same_path') == true)
          .map((i) => i.stableId)
          .toSet();
      expect(ids2, ids, reason: 'Same endpoints should produce same stableIds');
    });

    test('POST requests not flagged as duplicates', () {
      final base = fakeNow;
      for (int i = 0; i < 5; i++) {
        detector.processRecord(makeRecord(
          url: 'https://api.example.com/submit',
          method: 'POST',
          startedAt: base.add(Duration(milliseconds: i * 50)),
        ));
      }
      final dupIssues = detector.issues.where(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(dupIssues, isEmpty,
          reason: 'POST may have different payloads — not idempotent');
    });

    test('HEAD requests flagged as duplicates (idempotent)', () {
      final base = fakeNow;
      for (int i = 0; i < 3; i++) {
        detector.processRecord(makeRecord(
          url: 'https://api.example.com/health',
          method: 'HEAD',
          startedAt: base.add(Duration(milliseconds: i * 100)),
        ));
      }
      final dupIssues = detector.issues.where(
          (i) => i.stableId?.startsWith('high_frequency_same_path') == true);
      expect(dupIssues, hasLength(1),
          reason: 'HEAD is idempotent — duplicates should be flagged');
    });
  });
}
