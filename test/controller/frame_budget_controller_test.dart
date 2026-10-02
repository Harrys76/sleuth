import 'dart:ui' show FrameTiming;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/detector_thresholds.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/detectors/heavy_compute_detector.dart';
import 'package:sleuth/src/models/base_detector.dart' show DetectorType;
import 'package:sleuth/src/models/frame_budget.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/ui/sleuth_overlay.dart';
import 'package:sleuth/src/vm/service_extension_handlers.dart';

int _vsync = 1000000000;

/// [count] frames whose vsyncStart deltas are [periodUs], 4 ms each.
List<FrameTiming> _frames(int count, int periodUs) => [
  for (var i = 0; i < count; i++)
    () {
      _vsync += periodUs;
      return FrameTiming(
        vsyncStart: _vsync,
        buildStart: _vsync,
        buildFinish: _vsync + 2000,
        rasterStart: _vsync + 2000,
        rasterFinish: _vsync + 4000,
        rasterFinishWallTime: _vsync + 4000,
      );
    }(),
];

HeavyComputeDetector _heavy(SleuthController c) =>
    c.detectorsForAudit.whereType<HeavyComputeDetector>().single;

GpuPressureDetector _gpu(SleuthController c) =>
    c.detectorsForAudit.whereType<GpuPressureDetector>().single;

FrameStats _latestFrame(SleuthController c) {
  c.handleTimingsForTest(_frames(1, 8333));
  return c.frameStatsNotifier.value.latest!;
}

SleuthController _controller([SleuthConfig config = const SleuthConfig()]) {
  final c = SleuthController(config: config)..initializeDetectorsForTest();
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SleuthController frame budget', () {
    test('starts at the fpsTarget budget with detector defaults', () {
      final c = _controller();
      expect(c.frameBudgetUs, 16667);
      expect(c.effectiveFrameRateHz, 60);
      expect(c.frameRateSource, FrameRateSource.fixed);
      expect(_heavy(c).effectiveLagThresholdUs, 8000);
      expect(_gpu(c).effectiveMaxFrameRasterFloorUs, 8000);
    });

    test('120 Hz cadence on a 120 Hz display tightens every consumer', () {
      final c = _controller()..attachDisplayRefreshRate(120);
      expect(c.frameBudgetUs, 16667, reason: 'display alone is a cap');
      c.handleTimingsForTest(_frames(60, 8333));
      expect(c.frameBudgetUs, 8333);
      expect(c.effectiveFrameRateHz, 120);
      expect(c.frameRateSource, FrameRateSource.measured);
      expect(_heavy(c).effectiveLagThresholdUs, 4166);
      expect(_gpu(c).effectiveMaxFrameRasterFloorUs, 4166);
      expect(_latestFrame(c).frameBudgetUs, 8333);

      // Cadence falls back to 60: consumers return to their defaults.
      c.handleTimingsForTest(_frames(120, 16667));
      expect(c.frameBudgetUs, 16667);
      expect(_heavy(c).effectiveLagThresholdUs, 8000);
      expect(_gpu(c).effectiveMaxFrameRasterFloorUs, 8000);
    });

    test('ProMotion display rendering at 60 keeps 16667', () {
      final c = _controller()..attachDisplayRefreshRate(120);
      c.handleTimingsForTest(_frames(60, 16667));
      expect(c.frameBudgetUs, 16667);
      expect(c.frameRateSource, FrameRateSource.measured);
    });

    test('cadence above the display rate clamps to the display', () {
      final c = _controller()..attachDisplayRefreshRate(60);
      c.handleTimingsForTest(_frames(60, 8333));
      expect(c.frameBudgetUs, 16667);
      expect(c.frameRateSource, FrameRateSource.display);
    });

    test('captureMode resolves fixed even at 120 Hz', () {
      final c = _controller(const SleuthConfig(captureMode: true))
        ..attachDisplayRefreshRate(120);
      c.handleTimingsForTest(_frames(60, 8333));
      expect(c.frameBudgetUs, 16667);
      expect(c.frameRateSource, FrameRateSource.fixed);
      expect(_heavy(c).effectiveLagThresholdUs, 8000);
      expect(_gpu(c).effectiveMaxFrameRasterFloorUs, 8000);
      expect(_latestFrame(c).frameBudgetUs, 16667);
    });

    test('autoFrameBudget false resolves fixed', () {
      final c = _controller(const SleuthConfig(autoFrameBudget: false))
        ..attachDisplayRefreshRate(120);
      c.handleTimingsForTest(_frames(60, 8333));
      expect(c.frameBudgetUs, 16667);
      expect(c.frameRateSource, FrameRateSource.fixed);
    });

    test('explicit heavyComputeGapMs does not scale', () {
      final c = _controller(
        const SleuthConfig(
          thresholds: DetectorThresholds(heavyComputeGapMs: 8),
        ),
      )..attachDisplayRefreshRate(120);
      c.handleTimingsForTest(_frames(60, 8333));
      expect(c.frameBudgetUs, 8333);
      expect(_heavy(c).effectiveLagThresholdUs, 8000);
    });

    test('a re-enabled detector picks up the current budget', () {
      final c = _controller()..attachDisplayRefreshRate(120);
      c.handleTimingsForTest(_frames(60, 8333));
      c.disableDetector(DetectorType.heavyCompute);
      c.enableDetector(DetectorType.heavyCompute);
      expect(_heavy(c).effectiveLagThresholdUs, 4166);
    });

    test('diagnose reports the resolved budget', () async {
      final c = _controller()..attachDisplayRefreshRate(120);
      c.handleTimingsForTest(_frames(60, 8333));
      final env = await extDiagnoseHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      expect(data['frameBudgetUs'], 8333);
      expect(data['effectiveFrameRateHz'], 120.0);
      expect(data['frameRateSource'], 'measured');
    });
  });

  group('SleuthOverlay display refresh rate', () {
    Future<SleuthController> pumpOverlay(
      WidgetTester tester, [
      SleuthConfig config = const SleuthConfig(),
    ]) async {
      final c = SleuthController(config: config);
      await tester.pumpWidget(
        SleuthOverlay(controller: c, child: const SizedBox()),
      );
      return c;
    }

    testWidgets('120 Hz display + 120 Hz frames -> 8333 measured', (
      tester,
    ) async {
      addTearDown(tester.view.display.resetRefreshRate);
      final c = await pumpOverlay(tester);
      tester.view.display.refreshRate = 120;
      c.handleTimingsForTest(_frames(60, 8333));
      expect(c.frameBudgetUs, 8333);
      expect(c.frameRateSource, FrameRateSource.measured);
    });

    testWidgets('120 Hz display + 60 Hz frames -> 16667', (tester) async {
      addTearDown(tester.view.display.resetRefreshRate);
      final c = await pumpOverlay(tester);
      tester.view.display.refreshRate = 120;
      c.handleTimingsForTest(_frames(60, 16667));
      expect(c.frameBudgetUs, 16667);
    });

    testWidgets('unknown display rate -> 16667 fixed', (tester) async {
      addTearDown(tester.view.display.resetRefreshRate);
      final c = await pumpOverlay(tester);
      tester.view.display.refreshRate = 0;
      c.handleTimingsForTest(_frames(60, 8333));
      expect(c.frameBudgetUs, 16667);
      expect(c.frameRateSource, FrameRateSource.fixed);
    });

    testWidgets('autoFrameBudget false -> fixed', (tester) async {
      addTearDown(tester.view.display.resetRefreshRate);
      final c = await pumpOverlay(
        tester,
        const SleuthConfig(autoFrameBudget: false),
      );
      tester.view.display.refreshRate = 120;
      c.handleTimingsForTest(_frames(60, 8333));
      expect(c.frameBudgetUs, 16667);
      expect(c.frameRateSource, FrameRateSource.fixed);
    });
  });
}
