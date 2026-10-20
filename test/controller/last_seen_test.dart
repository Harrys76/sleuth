import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';

/// Reports one issue per occurrence in [occurrences], all under one
/// stable id and widget.
class _TwinDetector extends BaseDetector {
  _TwinDetector()
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.structural,
        name: 'Twins',
        description: 'Issues sharing a stable id.',
      );

  List<int> occurrences = [1, 2];
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => _issues;
  @override
  List<WidgetHighlight> get highlights => const [];
  @override
  bool get isEnabled => _isEnabled;
  @override
  set isEnabled(bool v) => _isEnabled = v;

  @override
  void scanTree(BuildContext context) {
    _issues
      ..clear()
      ..addAll([for (final o in occurrences) _issue(o)]);
  }

  static PerformanceIssue _issue(int occurrence) => PerformanceIssue(
    stableId: 'twin_issue',
    widgetName: 'Row',
    occurrenceId: occurrence,
    severity: IssueSeverity.warning,
    category: IssueCategory.layout,
    confidence: IssueConfidence.possible,
    title: 'Twin $occurrence',
    detail: 'D',
    fixHint: 'F',
  );

  @override
  void dispose() => _issues.clear();
}

void main() {
  testWidgets('each occurrence keeps its own last-seen time', (tester) async {
    final detector = _TwinDetector();
    final controller = SleuthController(
      config: SleuthConfig(
        enabledDetectors: const {DetectorType.frameTiming},
        customDetectors: [detector],
      ),
    )..initializeDetectorsForTest();
    addTearDown(controller.dispose);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final root = tester.element(find.byType(MaterialApp));

    controller.scanTreeFullPathForTest(root);
    final first = _TwinDetector._issue(1);
    final second = _TwinDetector._issue(2);
    final seen = controller.lastSeenAt(first);
    expect(seen, isNotNull);
    expect(controller.lastSeenAt(second), isNotNull);

    // The first occurrence goes; the second is still reported.
    detector.occurrences = [2];
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    controller.scanTreeFullPathForTest(root);
    expect(controller.lastSeenAt(first), seen);
    expect(controller.lastSeenAt(second)!.isAfter(seen!), isTrue);
  });
}
