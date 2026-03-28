import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/network_monitor_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/network/request_record.dart';

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
      // Add more records to trigger frequency
      for (int i = 0; i < 3; i++) {
        detector.processRecord(makeRecord(startedAt: fakeNow));
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
  });
}
