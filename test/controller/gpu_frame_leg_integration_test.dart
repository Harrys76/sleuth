import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart' show Sleuth;
import 'package:sleuth/src/controller/detector_thresholds.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/models/base_detector.dart' show DetectorType;
import 'package:sleuth/src/models/performance_issue.dart';

int _vsync = 1000000000;

/// [count] real engine timings at 60 Hz spacing with [buildUs] of UI work
/// followed by [rasterUs] of raster work.
List<FrameTiming> _timings(
  int count, {
  required int buildUs,
  required int rasterUs,
}) => [
  for (var i = 0; i < count; i++)
    () {
      _vsync += 16667;
      final buildFinish = _vsync + buildUs;
      return FrameTiming(
        vsyncStart: _vsync,
        buildStart: _vsync,
        buildFinish: buildFinish,
        rasterStart: buildFinish,
        rasterFinish: buildFinish + rasterUs,
        rasterFinishWallTime: buildFinish + rasterUs,
      );
    }(),
];

/// Raster-bound frames: 1 ms build, 12 ms raster.
List<FrameTiming> _rasterBound(int count) =>
    _timings(count, buildUs: 1000, rasterUs: 12000);

SleuthController _controller({int startupPhaseWindowSeconds = 5}) {
  final c = SleuthController(
    config: SleuthConfig(
      enabledDetectors: const {
        DetectorType.frameTiming,
        DetectorType.gpuPressure,
      },
      thresholds: DetectorThresholds(
        startupPhaseWindowSeconds: startupPhaseWindowSeconds,
      ),
    ),
  )..initializeDetectorsForTest();
  addTearDown(c.dispose);
  return c;
}

Future<BuildContext> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
  return tester.element(find.byType(MaterialApp));
}

List<PerformanceIssue> _raster(SleuthController c) => c.issuesNotifier.value
    .where((i) => i.stableId == 'raster_dominance')
    .toList();

void main() {
  setUp(Sleuth.resetStartupForTest);
  tearDown(Sleuth.resetStartupForTest);

  group('raster_dominance from real FrameTiming without a VM', () {
    testWidgets('raster-bound frames after the startup window → one likely '
        'issue, one notification', (tester) async {
      final c = _controller(startupPhaseWindowSeconds: 1);
      Sleuth.init();
      // Real monotonic clock: step past the 1 s startup window.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      final root = await _pumpApp(tester);
      var notifications = 0;
      c.issuesNotifier.addListener(() => notifications++);

      c.handleTimingsForTest(_rasterBound(20));
      c.scanTreeFullPathForTest(root);

      expect(c.isVmConnected, isFalse);
      final issues = _raster(c);
      expect(issues, hasLength(1));
      expect(issues.single.confidence, IssueConfidence.likely);
      expect(issues.single.observationSource, ObservationSource.frameTiming);
      expect(issues.single.severity, IssueSeverity.warning);
      expect(issues.single.extraTraceArgs!['dominantFrameCount'], '20');
      expect(notifications, 1);
    });

    testWidgets('frames inside the startup window are ignored', (tester) async {
      final c = _controller();
      Sleuth.init();
      final root = await _pumpApp(tester);

      c.handleTimingsForTest(_rasterBound(20));
      c.scanTreeFullPathForTest(root);

      expect(_raster(c), isEmpty);
    });

    testWidgets('without a Dart-entry anchor frames count', (tester) async {
      final c = _controller();
      final root = await _pumpApp(tester);

      c.handleTimingsForTest(_rasterBound(20));
      c.scanTreeFullPathForTest(root);

      expect(_raster(c), hasLength(1));
    });

    testWidgets('balanced frames (2 ms build, 2 ms raster) → none', (
      tester,
    ) async {
      final c = _controller();
      final root = await _pumpApp(tester);

      c.handleTimingsForTest(_timings(60, buildUs: 2000, rasterUs: 2000));
      c.scanTreeFullPathForTest(root);

      expect(_raster(c), isEmpty);
    });

    testWidgets('startupPhaseWindowSeconds reaches the GPU detector', (
      tester,
    ) async {
      final c = _controller(startupPhaseWindowSeconds: 7);
      final gpu = c.detectorsForAudit.whereType<GpuPressureDetector>().single;
      expect(gpu.startupPhaseWindowSeconds, 7);
    });
  });

  group('raster_dominance across a route change', () {
    Widget app() => MaterialApp(
      initialRoute: '/home',
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => Scaffold(body: SizedBox(key: ValueKey(settings.name))),
      ),
    );

    BuildContext root(WidgetTester tester) =>
        tester.element(find.byType(MaterialApp));

    testWidgets('dominant frames from the previous route do not count', (
      tester,
    ) async {
      final c = _controller();
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      c.scanTreeFullPathForTest(root(tester));

      c.handleTimingsForTest(_rasterBound(2));
      tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/b');
      await tester.pumpAndSettle();
      c.handleTimingsForTest(_rasterBound(1));
      c.scanTreeFullPathForTest(root(tester));

      expect(c.activeRouteSessionForTest!.routeName, '/b');
      expect(_raster(c), isEmpty);
    });

    testWidgets('the issue carries the route it was emitted on', (
      tester,
    ) async {
      final c = _controller();
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      c.scanTreeFullPathForTest(root(tester));

      c.handleTimingsForTest(_rasterBound(5));
      c.scanTreeFullPathForTest(root(tester));

      expect(_raster(c).single.sourceRoute, '/home');
    });
  });
}
