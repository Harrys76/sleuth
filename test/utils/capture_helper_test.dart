// Verifies the wire-format shape of issue trace events composed by
// `CaptureHelper.composeIssueEvent` plus the gating semantics of
// `recordIssue`. Round-trip parity with the schema parser is covered
// by `test/validation/capture_event_constants_test.dart`; this file
// only exercises the emitter side.
//
// Composition is pure data so a unit test can assert on the returned
// `CaptureIssueEvent` directly, sidestepping the VM-service round-trip
// that would be required to read the actual Timeline buffer.

import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/utils/capture_helper.dart';
import 'package:sleuth/src/validation/capture_event_constants.dart';

void main() {
  group('CaptureHelper.composeIssueEvent', () {
    test('warning severity: name suffix is `.warning`', () {
      final event = CaptureHelper.composeIssueEvent(
        _issue(stableId: 'heavy_compute', severity: IssueSeverity.warning),
      );
      expect(event, isNotNull);
      expect(event!.name, 'sleuth.issue.heavy_compute.warning');
    });

    test('critical severity: name suffix is `.critical`', () {
      final event = CaptureHelper.composeIssueEvent(
        _issue(stableId: 'heavy_compute', severity: IssueSeverity.critical),
      );
      expect(event!.name, 'sleuth.issue.heavy_compute.critical');
    });

    test('args carry detectedAtMicros as string', () {
      final issue = _issue(
        stableId: 'heavy_compute',
        severity: IssueSeverity.warning,
        detectedAt: DateTime.fromMicrosecondsSinceEpoch(1234567),
      );
      final event = CaptureHelper.composeIssueEvent(issue);
      expect(event!.args[issueTraceArgDetectedAtMicros], '1234567');
    });

    test('null detectedAt falls back to DateTime.now()', () {
      final event = CaptureHelper.composeIssueEvent(
        _issue(
          stableId: 'heavy_compute',
          severity: IssueSeverity.warning,
          detectedAt: null,
        ),
      );
      // Real-time fallback — we don't assert exact value, just that the
      // arg is populated with a parseable string.
      final raw = event!.args[issueTraceArgDetectedAtMicros];
      expect(int.tryParse(raw!), isNotNull);
    });

    test('null stableId: returns null (skipped)', () {
      final event = CaptureHelper.composeIssueEvent(
        _issue(stableId: null, severity: IssueSeverity.warning),
      );
      expect(event, isNull);
    });

    test('empty stableId: returns null (skipped)', () {
      final event = CaptureHelper.composeIssueEvent(
        _issue(stableId: '', severity: IssueSeverity.warning),
      );
      expect(event, isNull);
    });

    test('all framework-set stableIds compose successfully', () {
      // Smoke test: every IssueSeverity value composes a non-null
      // event when stableId is non-empty.
      for (final severity in IssueSeverity.values) {
        if (severity == IssueSeverity.ok) continue;
        final event = CaptureHelper.composeIssueEvent(
          _issue(stableId: 'some_detector', severity: severity),
        );
        expect(event, isNotNull, reason: 'severity=$severity');
        expect(event!.name, contains('.${severity.name}'));
      }
    });
  });

  group('CaptureHelper.recordIssue gating', () {
    // `recordIssue` is the gated entry point. The full triple-gate is
    // (kReleaseMode + captureMode + non-null stableId). kReleaseMode is
    // a compile-time const so we can't toggle it; captureMode is the
    // runtime gate this test exercises. The third gate (stableId) is
    // covered by the composeIssueEvent group above.

    test('captureMode false: no Timeline.instantSync call', () {
      // No exception, no observable side effect.
      // Implementation early-returns before composing or emitting.
      expect(
        () => CaptureHelper.recordIssue(
          _issue(stableId: 'heavy_compute', severity: IssueSeverity.warning),
          captureMode: false,
        ),
        returnsNormally,
      );
    });

    test('captureMode true: completes without throwing', () {
      // We can't intercept Timeline.instantSync from a unit test
      // without VM service. Verify only that the call shape is valid
      // and the emit path doesn't throw — composition correctness is
      // covered by composeIssueEvent tests above.
      expect(
        () => CaptureHelper.recordIssue(
          _issue(stableId: 'heavy_compute', severity: IssueSeverity.warning),
          captureMode: true,
        ),
        returnsNormally,
      );
    });
  });
}

PerformanceIssue _issue({
  required String? stableId,
  required IssueSeverity severity,
  DateTime? detectedAt = const _UseDefault(),
}) {
  return PerformanceIssue(
    stableId: stableId,
    severity: severity,
    category: IssueCategory.build,
    confidence: IssueConfidence.confirmed,
    title: 'test issue',
    detail: 'test detail',
    fixHint: 'test fix',
    fixEffort: FixEffort.quick,
    observationSource: ObservationSource.vmTimeline,
    detectedAt: identical(detectedAt, const _UseDefault())
        ? DateTime.fromMicrosecondsSinceEpoch(1234567)
        : detectedAt,
    confidenceReason: 'test',
  );
}

class _UseDefault implements DateTime {
  const _UseDefault();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('sentinel only');
}
