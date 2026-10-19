// Hermetic reproducer for [LayoutBottleneckDetector].
//
// Pins two stableIds via the real `scanTree(root)` entry point on a
// hand-built `pumpWidget` tree (anti-tautology: the detector observes the
// live Element/RenderObject tree, not hand-rolled PerformanceIssue
// objects).
//
//   - `layout_bottleneck` — fired when the scanned subtree contains at
//     least one `IntrinsicHeight` or `IntrinsicWidth` widget that is
//     NOT built by a framework owner (ToggleButtons, MenuBar, dialogs,
//     popup menus, etc.). A single intrinsic is warning/possible; nested
//     intrinsics escalate to critical/likely.
//   - `wrap_layout_bottleneck` — fired when a `Wrap` widget has more
//     than `_wrapChildThreshold` (30) children. Threshold is private
//     const so the reproducer uses 31 children to cross it.
//
// Known limitation (documented gap): intrinsics built by framework
// widgets like `ToggleButtons` / `AlertDialog` are deliberately
// suppressed — developers cannot control that usage. Separate test
// documents this suppression.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/src/detectors/layout_bottleneck_detector.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/measurement_matchers.dart';
import '_helpers/structural_reproducer_harness.dart';

/// The detector's private Wrap child threshold; critical is twice it.
const _wrapLine = 30.0;

void main() {
  group('LayoutBottleneckDetector reproducer', () {
    // --- layout_bottleneck ---------------------------------------------

    testWidgets('layout_bottleneck: IntrinsicHeight fires', (tester) async {
      final detector = LayoutBottleneckDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const IntrinsicHeight(child: SizedBox(height: 10, width: 10)),
      );
      expect(issues, hasStableId('layout_bottleneck'));
    });

    testWidgets('layout_bottleneck: IntrinsicWidth fires', (tester) async {
      final detector = LayoutBottleneckDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const IntrinsicWidth(child: SizedBox(height: 10, width: 10)),
      );
      expect(issues, hasStableId('layout_bottleneck'));
    });

    testWidgets('layout_bottleneck: no intrinsics stays silent', (
      tester,
    ) async {
      final detector = LayoutBottleneckDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const SizedBox(height: 10, width: 10),
      );
      expect(issues, lacksStableId('layout_bottleneck'));
    });

    testWidgets('layout_bottleneck: nested intrinsic escalates to critical', (
      tester,
    ) async {
      final detector = LayoutBottleneckDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const IntrinsicHeight(
          child: IntrinsicWidth(child: SizedBox(height: 10, width: 10)),
        ),
      );
      final issue = issues.firstWhere((i) => i.stableId == 'layout_bottleneck');
      expect(
        issue.severity.name,
        'critical',
        reason: 'Nested intrinsic must escalate — exponential layout cost.',
      );
      expect(issue.confidence.name, 'likely');
    });

    testWidgets('layout_bottleneck: single intrinsic is warning/possible', (
      tester,
    ) async {
      final detector = LayoutBottleneckDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const IntrinsicHeight(child: SizedBox(height: 10, width: 10)),
      );
      final issue = issues.firstWhere((i) => i.stableId == 'layout_bottleneck');
      expect(
        issue.severity.name,
        'warning',
        reason: 'Cost of one intrinsic depends on subtree size.',
      );
      expect(issue.confidence.name, 'possible');
      // Severity comes from nesting, not from a number: no measurement.
      expect(issue.measurement, isNull);
    });

    // --- wrap_layout_bottleneck ----------------------------------------

    testWidgets('wrap_layout_bottleneck: Wrap with 31 children fires '
        '(> 30-child threshold)', (tester) async {
      final detector = LayoutBottleneckDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        Wrap(children: List.generate(31, (i) => SizedBox(key: ValueKey(i)))),
      );
      expect(issues, hasStableId('wrap_layout_bottleneck'));
      final issue = issues.firstWhere(
        (i) => i.stableId == 'wrap_layout_bottleneck',
      );
      expect(issue.severity, IssueSeverity.warning);
      expectMeasurement(
        issue,
        value: 31,
        unit: MeasurementUnit.count,
        warningAt: _wrapLine,
        criticalAt: _wrapLine * 2,
      );
    });

    testWidgets('wrap_layout_bottleneck: Wrap with 61 children is critical '
        'and measured at 61', (tester) async {
      final detector = LayoutBottleneckDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        Wrap(children: List.generate(61, (i) => SizedBox(key: ValueKey(i)))),
      );
      final issue = issues.firstWhere(
        (i) => i.stableId == 'wrap_layout_bottleneck',
      );
      expect(issue.severity, IssueSeverity.critical);
      expectMeasurement(
        issue,
        value: 61,
        unit: MeasurementUnit.count,
        warningAt: _wrapLine,
        criticalAt: _wrapLine * 2,
      );
      expectSeverityMatchesMeasurement(issue, strict: true);
    });

    testWidgets('wrap_layout_bottleneck: Wrap with 30 children silent '
        '(at-threshold lower-boundary — `>` not `>=`)', (tester) async {
      // Detector uses `childCount > _wrapChildThreshold` so exactly 30
      // children does NOT fire. Pins the strict-greater contract.
      final detector = LayoutBottleneckDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        Wrap(children: List.generate(30, (i) => SizedBox(key: ValueKey(i)))),
      );
      expect(issues, lacksStableId('wrap_layout_bottleneck'));
    });

    testWidgets('wrap_layout_bottleneck: small Wrap stays silent', (
      tester,
    ) async {
      final detector = LayoutBottleneckDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        Wrap(children: List.generate(5, (i) => SizedBox(key: ValueKey(i)))),
      );
      expect(issues, lacksStableId('wrap_layout_bottleneck'));
    });

    // --- known limitation gap test -------------------------------------

    // Framework-owner suppression (_frameworkIntrinsicOwners table) is
    // enforced by _isFrameworkIntrinsic inside the detector;
    // exercising it requires mounting MaterialApp + routed dialog
    // widgets which couple the test to Material routing. That contract
    // is covered by test/detectors/layout_bottleneck_detector_test.dart;
    // this reproducer pins the raw emission boundary only.
  });
}
