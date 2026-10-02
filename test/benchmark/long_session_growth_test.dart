@Tags(['benchmark'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/route_session.dart';
import 'package:sleuth/src/models/widget_highlight.dart';

const _iterations = 500;
const _scansPerIteration = 4;
const _idsPerScan = 2;
const _typesPerScan = 100;

/// Long-session growth: hundreds of unnamed pages, thousands of distinct
/// parametric issue ids and rebuild types. Every controller map that grows
/// with session length must stay bounded.
void main() {
  testWidgets('controller maps stay bounded over a long session', (
    tester,
  ) async {
    final detector = _GrowthDetector();
    final coordinator = _FeedingCoordinator();
    final controller = SleuthController(
      config: SleuthConfig(
        enabledDetectors: const {DetectorType.frameTiming},
        customDetectors: [detector],
      ),
    );
    controller.initializeDetectorsForTest();
    controller.debugCoordinatorForTest = coordinator;
    addTearDown(controller.dispose);

    var scan = 0;
    var maxTrends = 0;
    for (var i = 0; i < _iterations; i++) {
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, _) => Scaffold(key: ValueKey(i), body: const SizedBox()),
        ),
      );
      final root = tester.element(find.byType(MaterialApp));
      for (var k = 0; k < _scansPerIteration; k++) {
        detector.firstId = scan * _idsPerScan;
        coordinator.firstType = scan * _typesPerScan;
        controller.scanTreeFullPathForTest(root);
        scan++;
      }
      if (controller.recurrenceTrends.length > maxTrends) {
        maxTrends = controller.recurrenceTrends.length;
      }

      expect(
        controller.unnamedIdByHashLengthForTest,
        lessThanOrEqualTo(controller.config.routeHistoryCapacity + 1),
      );
      expect(
        controller.routeHistoryForTest.length,
        lessThanOrEqualTo(controller.config.routeHistoryCapacity),
      );
    }

    // ignore: avoid_print
    print('  max recurrence trends: $maxTrends');
    // Ids unseen for 120 cycles go stale; each scan adds _idsPerScan.
    expect(maxTrends, lessThanOrEqualTo(122 * _idsPerScan));

    final active = controller.activeRouteSessionForTest!;
    expect(active.rebuildCountsByType.length, RouteSession.maxTrackedEntries);
    for (final s in controller.routeHistoryForTest) {
      expect(
        s.issueSnapshots.length,
        lessThanOrEqualTo(RouteSession.maxTrackedEntries),
      );
      expect(
        s.rebuildCountsByType.length,
        lessThanOrEqualTo(RouteSession.maxTrackedEntries),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

class _GrowthDetector extends BaseDetector {
  _GrowthDetector()
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.structural,
        name: 'Growth',
        description: 'Emits fresh parametric ids every scan.',
      );

  int firstId = 0;
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
      ..addAll([
        for (var k = 0; k < _idsPerScan; k++)
          PerformanceIssue(
            stableId: 'growth:${firstId + k}',
            severity: IssueSeverity.warning,
            category: IssueCategory.build,
            confidence: IssueConfidence.possible,
            title: 'Growth ${firstId + k}',
            detail: 'detail',
            fixHint: 'fix',
          ),
      ]);
  }

  @override
  void dispose() => _issues.clear();
}

/// Returns a profile-source snapshot with [_typesPerScan] fresh widget types
/// on every drain, so each session's rebuild map overflows its cap. A page's
/// first drain lands on the previous session, so each session receives
/// `(_scansPerIteration - 1) * _typesPerScan` types, above
/// [RouteSession.maxTrackedEntries].
class _FeedingCoordinator extends DebugInstrumentationCoordinator {
  _FeedingCoordinator() : super(installRebuild: false, installPaint: false);

  int firstType = 0;

  @override
  DebugSnapshot snapshot() => DebugSnapshot(
    rebuildCounts: {
      for (var k = 0; k < _typesPerScan; k++) 'Type${firstType + k}': 1,
    },
    totalPaintCount: 0,
    elapsed: const Duration(seconds: 1),
    source: RebuildCountSource.flutterTimeline,
  );
}
