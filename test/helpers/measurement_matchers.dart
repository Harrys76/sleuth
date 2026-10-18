import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';

/// Checks that [issue] carries a measurement with these fields. Doubles
/// compare within [tolerance] so a value computed by division matches the
/// figure a test writes by hand.
void expectMeasurement(
  PerformanceIssue issue, {
  required double value,
  required MeasurementUnit unit,
  double? warningAt,
  double? criticalAt,
  Duration? window,
  bool? strict,
  bool? warningStrict,
  bool? criticalStrict,
  double tolerance = 1e-6,
}) {
  final m = issue.measurement;
  expect(m, isNotNull, reason: '${issue.stableId} has no measurement');
  m!;
  expect(m.value, closeTo(value, tolerance), reason: '${issue.stableId} value');
  expect(m.unit, same(unit), reason: '${issue.stableId} unit');
  _expectLine(m.warningAt, warningAt, tolerance, '${issue.stableId} warningAt');
  _expectLine(
    m.criticalAt,
    criticalAt,
    tolerance,
    '${issue.stableId} criticalAt',
  );
  expect(m.window, window, reason: '${issue.stableId} window');
  // A flag is only set where its line exists.
  final expectWarning = warningStrict ?? strict;
  final expectCritical = criticalStrict ?? strict;
  if (expectWarning != null) {
    expect(
      m.warningStrict,
      m.warningAt != null && expectWarning,
      reason: '${issue.stableId} warningStrict',
    );
  }
  if (expectCritical != null) {
    expect(
      m.criticalStrict,
      m.criticalAt != null && expectCritical,
      reason: '${issue.stableId} criticalStrict',
    );
  }
}

/// Checks that [issue]'s measurement says how its detector compares (a
/// strict line needs a value above it; [strict] sets both lines,
/// [warningStrict] and [criticalStrict] one each), that the value reaches
/// the warning line when there is one, and that the severity is the one
/// the value reaches. Held severities report a value under their line, so
/// tests of a hold check the measurement with [expectMeasurement] only.
void expectSeverityMatchesMeasurement(
  PerformanceIssue issue, {
  bool strict = false,
  bool? warningStrict,
  bool? criticalStrict,
}) {
  final m = issue.measurement!;
  expect(
    m.warningStrict,
    m.warningAt != null && (warningStrict ?? strict),
    reason: '${issue.stableId} warningStrict',
  );
  expect(
    m.criticalStrict,
    m.criticalAt != null && (criticalStrict ?? strict),
    reason: '${issue.stableId} criticalStrict',
  );
  bool reaches(double? line, bool lineStrict) =>
      line != null && (lineStrict ? m.value > line : m.value >= line);
  if (m.warningAt != null) {
    expect(
      reaches(m.warningAt, m.warningStrict),
      isTrue,
      reason: '${issue.stableId}: ${m.value} reaches warning ${m.warningAt}',
    );
  }
  final expected = reaches(m.criticalAt, m.criticalStrict)
      ? IssueSeverity.critical
      : IssueSeverity.warning;
  expect(
    issue.severity,
    expected,
    reason:
        '${issue.stableId}: value ${m.value} against warning ${m.warningAt} '
        'and critical ${m.criticalAt}',
  );
}

void _expectLine(double? actual, double? expected, double tolerance, String r) {
  if (expected == null) {
    expect(actual, isNull, reason: r);
  } else {
    expect(actual, isNotNull, reason: r);
    expect(actual!, closeTo(expected, tolerance), reason: r);
  }
}
