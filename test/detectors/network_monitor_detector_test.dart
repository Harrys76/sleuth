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

    test('warning when slow request threshold exceeded (>2s)', () {
      detector.processRecord(makeRecord(durationMs: 2500));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
      expect(detector.issues.first.stableId, 'slow_request');
    });

    test('critical when slow request > 5s', () {
      detector.processRecord(makeRecord(durationMs: 5500));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
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

    test('warning when large response threshold exceeded (>1MB)', () {
      detector.processRecord(makeRecord(responseBytes: 2000000));
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
    // Duplicate request detection (v11.15)
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
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
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
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
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
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
      expect(dupIssues, isEmpty);
    });

    test('requests >500ms apart not clustered as duplicates', () {
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'GET',
        startedAt: fakeNow,
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'GET',
        startedAt: fakeNow.add(const Duration(milliseconds: 600)),
      ));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/users',
        method: 'GET',
        startedAt: fakeNow.add(const Duration(milliseconds: 1200)),
      ));
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
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
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
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
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
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
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
      expect(dupIssues, hasLength(1));
      expect(dupIssues.first.severity, IssueSeverity.critical);
    });

    test('duplicate issue cleared when records age out of window', () {
      final base = fakeNow;
      // Add 3 duplicates within 500ms
      for (int i = 0; i < 3; i++) {
        detector.processRecord(makeRecord(
          url: 'https://api.example.com/users',
          method: 'GET',
          startedAt: base.add(Duration(milliseconds: i * 100)),
        ));
      }
      expect(
        detector.issues
            .where((i) => i.stableId?.startsWith('duplicate_request') == true),
        hasLength(1),
      );

      // Advance clock past 5s window and add a non-duplicate record
      fakeNow = base.add(const Duration(seconds: 6));
      detector.processRecord(makeRecord(
        url: 'https://api.example.com/other',
        method: 'GET',
        startedAt: fakeNow,
      ));
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
      expect(dupIssues, isEmpty);
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
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
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
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
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
          (i) => i.stableId?.startsWith('duplicate_request') == true);
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
          .where((i) => i.stableId?.startsWith('duplicate_request') == true)
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
          .where((i) => i.stableId?.startsWith('duplicate_request') == true)
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
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
      expect(dupIssues, isEmpty,
          reason: 'POST may have different payloads — not idempotent');
    });

    test('PUT requests not flagged as duplicates', () {
      final base = fakeNow;
      for (int i = 0; i < 5; i++) {
        detector.processRecord(makeRecord(
          url: 'https://api.example.com/resource/1',
          method: 'PUT',
          startedAt: base.add(Duration(milliseconds: i * 50)),
        ));
      }
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
      expect(dupIssues, isEmpty, reason: 'PUT may carry different payloads');
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
      final dupIssues = detector.issues
          .where((i) => i.stableId?.startsWith('duplicate_request') == true);
      expect(dupIssues, hasLength(1),
          reason: 'HEAD is idempotent — duplicates should be flagged');
    });
  });
}
