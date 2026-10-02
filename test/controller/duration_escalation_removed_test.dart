import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';

/// Custom detector that always reports one confirmed warning.
class _PersistentWarningDetector extends BaseDetector {
  _PersistentWarningDetector()
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.structural,
        name: 'Persistent Warning',
        description: 'Emits one confirmed warning',
      );

  final List<PerformanceIssue> _issues = [
    const PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Persistent warning',
      detail: 'Detail',
      fixHint: 'Fix',
      stableId: 'persistent_warning',
      confidenceReason: 'Observed at runtime',
    ),
  ];
  bool _enabled = true;

  @override
  List<PerformanceIssue> get issues => _issues;
  @override
  List<WidgetHighlight> get highlights => const [];
  @override
  bool get isEnabled => _enabled;
  @override
  set isEnabled(bool v) => _enabled = v;

  @override
  void scanTree(BuildContext context) {}

  @override
  void dispose() {}
}

void main() {
  test('a warning that persists for 40 cycles stays a warning: severity '
      'comes from the detector, not from duration', () {
    final controller = SleuthController(
      config: SleuthConfig(
        customDetectors: [_PersistentWarningDetector()],
        enabledDetectors: const {DetectorType.frameTiming},
      ),
    );
    addTearDown(controller.dispose);
    controller.initializeDetectorsForTest();

    controller.recordRecurrenceForTest(
      'persistent_warning',
      IssueSeverity.warning,
      40,
    );
    expect(
      controller.recurrenceTrends['persistent_warning']!.presentCount,
      greaterThanOrEqualTo(30),
    );

    controller.aggregateIssuesForTest();

    final issue = controller.issuesNotifier.value.singleWhere(
      (i) => i.stableId == 'persistent_warning',
    );
    expect(issue.severity, IssueSeverity.warning);
    expect(issue.confidenceReason, 'Observed at runtime');
    expect(issue.confidenceReason, isNot(contains('Auto-escalated')));
  });
}
