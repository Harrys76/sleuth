import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';
import 'package:sleuth/src/vm/service_extension_handlers.dart';

/// Emits one issue per scan. [title] is mutable so a test can simulate a
/// live counter; `detectedAt` and the `tick` trace arg change every scan.
class _TickingDetector extends BaseDetector {
  _TickingDetector()
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.structural,
        name: 'Ticking',
        description: 'One issue per scan.',
      );

  String title = 'Steady issue';
  IssueMeasurement? measurement;
  int scans = 0;
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
    scans++;
    _issues
      ..clear()
      ..add(
        PerformanceIssue(
          stableId: 'ticking_issue',
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          title: title,
          detail: 'Same detail',
          fixHint: 'Fix',
          detectedAt: DateTime.fromMillisecondsSinceEpoch(scans * 1000),
          extraTraceArgs: {'tick': '$scans'},
          measurement: measurement,
        ),
      );
  }

  @override
  void dispose() => _issues.clear();
}

void main() {
  late _TickingDetector detector;
  late SleuthController controller;
  late int notifications;

  setUp(() {
    detector = _TickingDetector();
    controller = SleuthController(
      config: SleuthConfig(
        enabledDetectors: const {DetectorType.frameTiming},
        customDetectors: [detector],
      ),
    );
    controller.initializeDetectorsForTest();
    notifications = 0;
    controller.issuesNotifier.addListener(() => notifications++);
  });

  tearDown(() => controller.dispose());

  Future<BuildContext> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    return tester.element(find.byType(MaterialApp));
  }

  testWidgets('unchanged ticks notify once; a visible change notifies again', (
    tester,
  ) async {
    final root = await pumpApp(tester);
    for (var i = 0; i < 10; i++) {
      controller.scanTreeFullPathForTest(root);
    }
    expect(detector.scans, 10);
    expect(notifications, 1);

    detector.title = 'Steady issue (2)';
    controller.scanTreeFullPathForTest(root);
    expect(notifications, 2);
    expect(controller.issuesNotifier.value.single.title, 'Steady issue (2)');

    controller.scanTreeFullPathForTest(root);
    expect(notifications, 2);
  });

  testWidgets(
    'a measurement change notifies only when the card reads it differently',
    (tester) async {
      // The card's Measured row shows the value rounded, so a value that
      // moves within one reading must not rebuild the card.
      final root = await pumpApp(tester);
      IssueMeasurement rate(double value) => IssueMeasurement(
        value: value,
        unit: MeasurementUnit.perSecond,
        warningAt: 10,
        criticalAt: 30,
      );

      detector.measurement = rate(44.9);
      controller.scanTreeFullPathForTest(root);
      expect(notifications, 1);

      // Both read "45/s".
      detector.measurement = rate(45.1);
      controller.scanTreeFullPathForTest(root);
      expect(notifications, 1);
      expect(controller.latestIssues.single.measurement, rate(45.1));

      detector.measurement = rate(46);
      controller.scanTreeFullPathForTest(root);
      expect(notifications, 2);

      // A gauge line moves.
      detector.measurement = IssueMeasurement(
        value: 46,
        unit: MeasurementUnit.perSecond,
        warningAt: 10,
        criticalAt: 40,
      );
      controller.scanTreeFullPathForTest(root);
      expect(notifications, 3);

      // The row goes away.
      detector.measurement = null;
      controller.scanTreeFullPathForTest(root);
      expect(notifications, 4);
    },
  );

  testWidgets('a tab of the same route with the same issue notifies', (
    tester,
  ) async {
    final tab = ValueNotifier<int>(0);
    addTearDown(tab.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: tab,
          builder: (_, index, _) => IndexedStack(
            index: index,
            children: const [
              Scaffold(body: Text('one')),
              Scaffold(body: Text('two')),
            ],
          ),
        ),
      ),
    );
    final root = tester.element(find.byType(MaterialApp));
    controller.scanTreeFullPathForTest(root);
    expect(notifications, 1);
    final first = controller.issuesNotifier.value.single.scaffoldHashKey;

    // Both tabs are first visits, so only the scaffold tells them apart.
    tab.value = 1;
    await tester.pump();
    controller.scanTreeFullPathForTest(root);
    expect(notifications, 2);
    expect(
      controller.issuesNotifier.value.single.scaffoldHashKey,
      isNot(first),
    );
  });

  testWidgets('scan pulse fires once per tick', (tester) async {
    final root = await pumpApp(tester);
    var pulses = 0;
    controller.scanTickNotifier.addListener(() => pulses++);
    for (var i = 0; i < 5; i++) {
      controller.scanTreeFullPathForTest(root);
    }
    expect(pulses, 5);
    expect(controller.scanTickNotifier.value, 5);
  });

  testWidgets('export and ext.sleuth.issues read the latest aggregation', (
    tester,
  ) async {
    final root = await pumpApp(tester);
    controller.scanTreeFullPathForTest(root);
    controller.scanTreeFullPathForTest(root);
    controller.scanTreeFullPathForTest(root);
    expect(notifications, 1);

    final latest = controller.latestIssues.single;
    expect(latest.extraTraceArgs?['tick'], '3');
    // The notifier still holds the first tick's list.
    expect(controller.issuesNotifier.value.single.extraTraceArgs?['tick'], '1');

    final exported = controller.exportSnapshot().currentIssues.single;
    expect(exported.detectedAt, latest.detectedAt);
    expect(exported.extraTraceArgs?['tick'], '3');

    final env = await extIssuesHandler(controller, const {});
    final issues = (env['data'] as Map<String, Object?>)['issues'] as List;
    expect(issues, hasLength(1));
    expect(
      (issues.single as Map)['detectedAt'],
      latest.detectedAt!.toIso8601String(),
    );
  });

  testWidgets('ext.sleuth.issues carries the measurement', (tester) async {
    final root = await pumpApp(tester);
    detector.measurement = const IssueMeasurement(
      value: 34,
      unit: MeasurementUnit.perSecond,
      warningAt: 20,
      criticalAt: 40,
    );
    controller.scanTreeFullPathForTest(root);

    final env = await extIssuesHandler(controller, const {});
    final issue =
        ((env['data'] as Map<String, Object?>)['issues'] as List).single as Map;
    expect(issue['measurement'], {
      'value': 34.0,
      'unit': 'perSecond',
      'warningAt': 20.0,
      'criticalAt': 40.0,
    });
  });
}
