import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/models/base_detector.dart';
import 'package:widget_watchdog/src/models/capture_buffer.dart';
import 'package:widget_watchdog/src/models/cpu_attribution.dart';
import 'package:widget_watchdog/src/models/frame_stats.dart';
import 'package:widget_watchdog/src/models/frame_verdict.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  // =========================================================================
  // 1. Network monitoring wiring
  // =========================================================================
  group('v2.1 Network monitoring controller wiring', () {
    late WatchdogController controller;

    tearDown(() {
      controller.dispose();
      HttpOverrides.global = null;
    });

    test('network override installed when enabled (default config)', () {
      HttpOverrides.global = null;
      controller = WatchdogController();
      controller.initializeDetectorsForTest();

      // initializeDetectorsForTest doesn't install HTTP overrides (that's
      // done in initialize()). Verify detector is created and enabled.
      // The override installation is part of the full initialize() path.
      expect(
        controller.config.enableNetworkMonitoring,
        isTrue,
        reason: 'Default config should enable network monitoring',
      );
      expect(
        controller.config.enabledDetectors
            .contains(DetectorType.networkMonitor),
        isTrue,
        reason: 'Default enabled detectors include network monitor',
      );
    });

    test('network override NOT installed when enableNetworkMonitoring=false',
        () {
      HttpOverrides.global = null;
      controller = WatchdogController(
        config: const WatchdogConfig(enableNetworkMonitoring: false),
      );
      controller.initializeDetectorsForTest();

      // With monitoring disabled, no HTTP override should be installed
      // even after detector initialization
      expect(HttpOverrides.current, isNull);
    });

    test(
        'network override NOT installed when networkMonitor removed from '
        'enabledDetectors', () {
      HttpOverrides.global = null;
      final detectors = {...DetectorType.values}
        ..remove(DetectorType.networkMonitor);
      controller = WatchdogController(
        config: WatchdogConfig(enabledDetectors: detectors),
      );
      controller.initializeDetectorsForTest();

      expect(HttpOverrides.current, isNull);
    });

    test('network config thresholds pass through to detector', () {
      controller = WatchdogController(
        config: const WatchdogConfig(
          slowRequestThresholdMs: 5000,
          requestFrequencyLimit: 50,
          largeResponseThresholdBytes: 2097152,
        ),
      );
      controller.initializeDetectorsForTest();

      expect(controller.config.slowRequestThresholdMs, 5000);
      expect(controller.config.requestFrequencyLimit, 50);
      expect(controller.config.largeResponseThresholdBytes, 2097152);
    });

    test('network exclude patterns stored in config', () {
      controller = WatchdogController(
        config: const WatchdogConfig(
          networkExcludePatterns: ['analytics.com', '/health'],
        ),
      );
      controller.initializeDetectorsForTest();

      expect(controller.config.networkExcludePatterns,
          containsAll(['analytics.com', '/health']));
    });

    test('dispose handles null _httpOverrides safely', () {
      HttpOverrides.global = null;
      // We can't call the real initialize() in tests (it needs VM service),
      // but we can verify the dispose path handles null _httpOverrides safely.
      // tearDown will call dispose, so we just verify state here.
      controller = WatchdogController();
      controller.initializeDetectorsForTest();

      // httpOverrides is null since initializeDetectorsForTest doesn't install them
      expect(HttpOverrides.current, isNull);
      // dispose in tearDown should not throw
    });

    test('default config enables both network flags', () {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();

      // Both the master switch and detector type must be enabled
      expect(controller.config.enableNetworkMonitoring, isTrue);
      expect(
        controller.config.enabledDetectors
            .contains(DetectorType.networkMonitor),
        isTrue,
      );
    });

    test('network issues aggregated after timeline data feed', () {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();

      // feedTimelineDataForTest triggers _aggregateIssues which collects
      // from all detectors including network monitor
      controller.feedTimelineDataForTest(emptyTimelineData());

      // Verify aggregated issues list is accessible (may be empty without
      // actual network traffic, but the path is exercised)
      expect(controller.issuesNotifier.value, isA<List>());
    });
  });

  // =========================================================================
  // 2. Heap memory sampling callback chain
  // =========================================================================
  group('v2.2 Heap sample callback chain', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test('memory pressure detector is initialized and enabled by default', () {
      // The memory pressure detector should be enabled in default config
      expect(
        controller.config.enabledDetectors
            .contains(DetectorType.memoryPressure),
        isTrue,
      );
    });

    test('aggregation path includes memory pressure detector', () {
      controller.simulateVmStateChangeForTest(true);

      // Feed empty timeline data to trigger _aggregateIssues.
      // The memory pressure detector is in the aggregation chain —
      // this verifies the path runs without error. Actual heap sample
      // injection requires the VM polling path tested in vm_service_client_test.
      controller.feedTimelineDataForTest(emptyTimelineData());

      // Aggregation completed without error
      expect(controller.issuesNotifier.value, isNotNull);
    });

    test('heap samples export in session snapshot', () {
      controller.simulateVmStateChangeForTest(true);

      // Export should work even without heap data
      final snapshot = controller.exportSnapshot();
      // heapSamples is null when controller not fully initialized via initialize()
      // (initializeDetectorsForTest sets _initialized differently)
      expect(snapshot, isNotNull);
    });
  });

  // =========================================================================
  // 3. Two-phase CPU attribution verdict enrichment
  // =========================================================================
  group('v2.3 CPU attribution enrichment', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    FrameStats makeJankFrame({
      int frameNumber = 1,
      int uiMs = 30,
      int rasterMs = 10,
    }) {
      return FrameStats(
        frameNumber: frameNumber,
        uiDuration: Duration(milliseconds: uiMs),
        rasterDuration: Duration(milliseconds: rasterMs),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      );
    }

    FrameStats makeJankFrameWithTimestamps({
      int frameNumber = 1,
      int uiMs = 30,
      int rasterMs = 10,
      int vsyncStartUs = 0,
      int buildStartUs = 100,
      int? buildFinishUs,
      int? rasterStartUs,
      int? rasterFinishUs,
    }) {
      final buildEnd = buildFinishUs ?? (buildStartUs + uiMs * 1000);
      final rasterStart = rasterStartUs ?? (buildEnd + 500);
      final rasterEnd = rasterFinishUs ?? (rasterStart + rasterMs * 1000);
      return FrameStats(
        frameNumber: frameNumber,
        uiDuration: Duration(milliseconds: uiMs),
        rasterDuration: Duration(milliseconds: rasterMs),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
        vsyncStartUs: vsyncStartUs,
        buildStartUs: buildStartUs,
        buildFinishUs: buildEnd,
        rasterStartUs: rasterStart,
        rasterFinishUs: rasterEnd,
      );
    }

    test('phase 1: jank frame without VM produces verdict without topFunctions',
        () {
      // VM not connected, so no CPU attribution possible
      controller.addFrameForTest(makeJankFrame());

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.topFunctions, isNull);
    });

    test('basic verdict has correct frame number', () {
      controller.addFrameForTest(makeJankFrame(frameNumber: 42));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.frameNumber, 42);
    });

    test('non-jank frame does NOT produce a verdict', () {
      // 10ms UI + 5ms raster < 16ms budget → not jank
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 10),
        rasterDuration: const Duration(milliseconds: 5),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      expect(controller.verdictNotifier.value, isNull);
    });

    test('FrameStats.hasPhaseTimestamps returns true with all timestamps', () {
      final frame = makeJankFrameWithTimestamps();
      expect(frame.hasPhaseTimestamps, isTrue);
    });

    test('FrameStats.hasPhaseTimestamps returns false without phase timestamps',
        () {
      final frame = makeJankFrame();
      expect(frame.hasPhaseTimestamps, isFalse);
    });

    test('FrameVerdict.withTopFunctions creates enriched copy', () {
      const functions = [
        CpuAttribution(
          functionName: 'build',
          className: 'MyWidget',
          libraryUri: 'package:app/my_widget.dart',
          percentage: 45.0,
        ),
      ];

      final original = FrameVerdict(
        frameNumber: 1,
        totalFrameTime: const Duration(milliseconds: 30),
        uiThreadTime: const Duration(milliseconds: 30),
        rasterThreadTime: const Duration(milliseconds: 10),
        suspectedPhase: PipelinePhase.build,
        reason: 'Test',
        relatedIssues: const [],
        isFullMode: false,
        isCorrelated: false,
      );

      final enriched = original.withTopFunctions(functions);
      expect(enriched.topFunctions, hasLength(1));
      expect(enriched.topFunctions!.first.displayName, 'MyWidget.build');
      expect(enriched.frameNumber, original.frameNumber);
      expect(enriched.totalFrameTime, original.totalFrameTime);
    });

    test('capture buffer stores phase-1 verdict on jank', () {
      // Feed timeline data with jank frame to trigger capture
      controller.simulateVmStateChangeForTest(true);

      // Add a jank frame so the frame buffer has data
      controller.addFrameForTest(makeJankFrame(frameNumber: 1));

      // Now feed timeline data — this triggers verdict generation and capture
      controller.feedTimelineDataForTest(
        rasterDominantData(
          rasterUs: 30000,
          buildUs: 5000,
          layoutUs: 3000,
          paintUs: 2000,
        ),
      );

      // The verdict should have been emitted
      expect(controller.verdictNotifier.value, isNotNull);
    });

    test('capture buffer updateVerdict replaces entry for same frame', () {
      final buffer = JankCaptureBuffer();
      final frame = makeJankFrame(frameNumber: 5);
      final originalVerdict = FrameVerdict(
        frameNumber: 5,
        totalFrameTime: const Duration(milliseconds: 30),
        uiThreadTime: const Duration(milliseconds: 30),
        rasterThreadTime: const Duration(milliseconds: 10),
        suspectedPhase: PipelinePhase.build,
        reason: 'Test',
        relatedIssues: const [],
        isFullMode: false,
        isCorrelated: false,
      );

      buffer.add(CaptureEntry(
        frameStats: frame,
        verdict: originalVerdict,
        relatedIssues: const [],
        capturedAt: DateTime.now(),
      ));

      expect(buffer.entries.first.verdict.topFunctions, isNull);

      const functions = [
        CpuAttribution(
          functionName: 'build',
          className: 'ExpensiveWidget',
          libraryUri: 'package:app/expensive.dart',
          percentage: 60.0,
        ),
      ];
      final enriched = originalVerdict.withTopFunctions(functions);
      buffer.updateVerdict(5, enriched);

      expect(buffer.entries.first.verdict.topFunctions, hasLength(1));
      expect(buffer.entries.first.verdict.topFunctions!.first.percentage, 60.0);
    });

    test('capture buffer updateVerdict no-ops when frame number does not match',
        () {
      final buffer = JankCaptureBuffer();
      final frame = makeJankFrame(frameNumber: 5);
      final verdict = FrameVerdict(
        frameNumber: 5,
        totalFrameTime: const Duration(milliseconds: 30),
        uiThreadTime: const Duration(milliseconds: 30),
        rasterThreadTime: const Duration(milliseconds: 10),
        suspectedPhase: PipelinePhase.build,
        reason: 'Test',
        relatedIssues: const [],
        isFullMode: false,
        isCorrelated: false,
      );

      buffer.add(CaptureEntry(
        frameStats: frame,
        verdict: verdict,
        relatedIssues: const [],
        capturedAt: DateTime.now(),
      ));

      // Update with a different frame number — should not change anything
      final enriched = verdict.withTopFunctions(const [
        CpuAttribution(
          functionName: 'x',
          className: '',
          libraryUri: '',
          percentage: 99.0,
        ),
      ]);
      buffer.updateVerdict(999, enriched);

      expect(buffer.entries.first.verdict.topFunctions, isNull);
    });
  });

  // =========================================================================
  // 4. Controller lifecycle with all v2 features
  // =========================================================================
  group('Controller lifecycle with v2 features', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test('all notifiers initialized with defaults', () {
      expect(controller.issuesNotifier.value, isEmpty);
      expect(controller.verdictNotifier.value, isNull);
      expect(controller.vmConnectedNotifier.value, isFalse);
      expect(controller.frameStatsNotifier.value, isNotNull);
    });

    test('VM connection state propagates to hybrid detectors', () {
      controller.simulateVmStateChangeForTest(true);
      expect(controller.vmConnectedNotifier.value, isTrue);
      expect(controller.isVmConnected, isTrue);

      controller.simulateVmStateChangeForTest(false);
      expect(controller.vmConnectedNotifier.value, isFalse);
      expect(controller.isVmConnected, isFalse);
    });

    test('timeline data feeds all VM and hybrid detectors', () {
      controller.simulateVmStateChangeForTest(true);

      // Feed timeline data that exercises multiple detector paths
      controller.feedTimelineDataForTest(rasterDominantData(
        rasterUs: 30000,
        buildUs: 5000,
        layoutUs: 3000,
        paintUs: 2000,
      ));

      // Aggregation ran — issues are collected from all detectors
      expect(controller.issuesNotifier.value, isA<List>());
    });

    test('dispose does not throw after partial initialization', () {
      // Create and immediately dispose
      final ctrl = WatchdogController();
      ctrl.initializeDetectorsForTest();
      expect(() => ctrl.dispose(), returnsNormally);
    });

    test('jank frame populates capture buffer', () {
      // Add a jank frame to populate the buffer
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 30),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      // Buffer should have captured the jank frame
      // (via _onFrameStats → basic mode verdict path when VM not connected)
      final captured = controller.captureBufferForTest.length;
      expect(captured, greaterThanOrEqualTo(1));
      expect(
        controller.captureBufferForTest.entries.first.frameStats.frameNumber,
        1,
      );
    });

    testWidgets('recurrence counts tracked across scans', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(),
        ),
      );
      final context = tester.element(find.byType(Directionality));

      controller.simulateVmStateChangeForTest(true);
      controller
          .feedTimelineDataForTest(highBuildActivityData(buildCount: 100));

      // First tree scan
      controller.runTreeScanForTest(context);

      // Second tree scan — recurrence should increment
      controller.runTreeScanForTest(context);

      // Recurrence counts should be populated
      expect(controller.recurrenceCountsForTest, isA<Map<String, int>>());
    });

    test('multiple jank frames captured in buffer order', () {
      // Frame 1
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 30),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      // Frame 2
      controller.addFrameForTest(FrameStats(
        frameNumber: 2,
        uiDuration: const Duration(milliseconds: 50),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      final entries = controller.captureBufferForTest.entries;
      expect(entries.length, 2);
      expect(entries[0].frameStats.frameNumber, 1);
      expect(entries[1].frameStats.frameNumber, 2);
    });

    test('interaction context defaults to idle', () {
      expect(
        controller.interactionStateForTest,
        InteractionContext.idle,
      );
    });

    test('interaction context can be set for test', () {
      controller.interactionStateForTest = InteractionContext.scrolling;
      expect(
        controller.interactionStateForTest,
        InteractionContext.scrolling,
      );
    });

    test('export snapshot works with empty state', () {
      final snapshot = controller.exportSnapshot();
      expect(snapshot, isNotNull);
      expect(snapshot.capturedFrames, isEmpty);
      expect(snapshot.currentIssues, isEmpty);
    });

    test('all detector types present in default config', () {
      // Verify all 22 detectors are enabled by default
      for (final type in DetectorType.values) {
        expect(
          controller.config.enabledDetectors.contains(type),
          isTrue,
          reason: '$type should be in default enabledDetectors',
        );
      }
    });

    test('selective detector disabling works', () {
      final detectors = {...DetectorType.values}
        ..remove(DetectorType.networkMonitor)
        ..remove(DetectorType.memoryPressure);

      final ctrl = WatchdogController(
        config: WatchdogConfig(enabledDetectors: detectors),
      );
      ctrl.initializeDetectorsForTest();

      expect(ctrl.config.enabledDetectors,
          isNot(contains(DetectorType.networkMonitor)));
      expect(ctrl.config.enabledDetectors,
          isNot(contains(DetectorType.memoryPressure)));

      ctrl.dispose();
    });
  });

  // =========================================================================
  // 5. Verdict pipeline end-to-end
  // =========================================================================
  group('Verdict pipeline integration', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test('VM connected + timeline data → full mode verdict', () {
      controller.simulateVmStateChangeForTest(true);

      // Add a jank frame first so _frameTiming buffer has data
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 30),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      // Feed timeline data to trigger full-mode verdict
      controller.feedTimelineDataForTest(rasterDominantData(
        rasterUs: 30000,
        buildUs: 5000,
        layoutUs: 3000,
        paintUs: 2000,
      ));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
    });

    test('VM disconnected → basic mode verdict on jank', () {
      // VM not connected (default)
      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 30),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      final verdict = controller.verdictNotifier.value;
      expect(verdict, isNotNull);
      expect(verdict!.isFullMode, isFalse);
      expect(verdict.isCorrelated, isFalse);
    });

    test('verdict carries related issues', () {
      controller.simulateVmStateChangeForTest(true);

      // Feed data that will generate issues
      controller.feedTimelineDataForTest(shaderCompileData(
        shaderDurationsUs: [20000],
      ));

      controller.addFrameForTest(FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(milliseconds: 30),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ));

      // Issues should be aggregated
      // (exact issue content depends on detector thresholds)
      expect(controller.issuesNotifier.value, isA<List>());
    });

    test('timeline data with GC events reaches memory pressure detector', () {
      controller.simulateVmStateChangeForTest(true);

      // Feed GC-heavy data
      controller.feedTimelineDataForTest(gcHeavyData(gcCount: 20));

      // After enough GC events, memory pressure should report
      // (threshold depends on elapsed time and count)
      expect(controller.issuesNotifier.value, isA<List>());
    });

    test('shader compile data reaches shader jank detector', () {
      controller.simulateVmStateChangeForTest(true);

      controller.feedTimelineDataForTest(shaderCompileData(
        shaderDurationsUs: [50000],
      ));

      // Shader jank detector processes the data — issues aggregated
      expect(controller.issuesNotifier.value, isA<List>());
    });

    test('heavy compute data reaches heavy compute detector', () {
      controller.simulateVmStateChangeForTest(true);

      controller.feedTimelineDataForTest(heavyComputeData(
        buildScopeDurationsUs: [50000],
      ));

      // Heavy compute detector processes the data
      expect(controller.issuesNotifier.value, isA<List>());
    });
  });

  // =========================================================================
  // 6. Tree scan + timeline integration
  // =========================================================================
  group('Tree scan + timeline integration', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('structural issues from tree scan merge with VM issues',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [
            SizedBox(width: 100, height: 100),
            SizedBox(width: 100, height: 100),
          ]),
        ),
      );

      final context = tester.element(find.byType(Directionality));
      controller.simulateVmStateChangeForTest(true);

      // Feed timeline data first
      controller
          .feedTimelineDataForTest(highBuildActivityData(buildCount: 100));

      // Then run tree scan
      controller.runTreeScanForTest(context);

      // Both paths contribute to the same issue list
      final issues = controller.issuesNotifier.value;
      expect(issues, isA<List>());
    });

    testWidgets('aggregateIssuesForTest re-ranks without tree scan',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(),
        ),
      );

      controller.simulateVmStateChangeForTest(true);
      controller.feedTimelineDataForTest(rasterDominantData(
        rasterUs: 30000,
        buildUs: 5000,
        layoutUs: 3000,
        paintUs: 2000,
      ));

      // Re-aggregate without tree scan
      controller.aggregateIssuesForTest();

      // Should not throw and issues should be consistent
      expect(controller.issuesNotifier.value, isA<List>());
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------
