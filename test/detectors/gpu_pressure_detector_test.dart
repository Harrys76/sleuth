import 'dart:developer' show Timeline;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheet,
        CupertinoActionSheetAction,
        CupertinoApp,
        CupertinoIcons,
        CupertinoNavigationBar,
        CupertinoPageScaffold,
        CupertinoPopupSurface,
        CupertinoSliverNavigationBar,
        CupertinoTabBar;
import 'package:flutter/material.dart'
    show BottomNavigationBarItem, Material, MaterialType;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/utils/fix_hint_builder.dart';
import 'package:sleuth/src/utils/framework_types.dart' show cupertinoBlurOwner;
import 'package:sleuth/src/vm/timeline_parser.dart';

import '../helpers/measurement_matchers.dart';
import '../helpers/timeline_test_helpers.dart';

void main() {
  group('GpuPressureDetector', () {
    late GpuPressureDetector detector;

    setUp(() {
      detector = GpuPressureDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      detector.vmConnected = true;
      detector.processTimelineData(rasterDominantData());

      await tester.pumpWidget(const _GpuTestApp());
      detector.scanTree(tester.element(find.byType(_GpuTestApp)));

      expect(detector.issues, isEmpty);
    });

    group('VM connected, no frame timings', () {
      setUp(() {
        detector.vmConnected = true;
      });

      Future<List<PerformanceIssue>> scanVm(WidgetTester tester) async {
        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));
        return detector.issues;
      }

      testWidgets(
        'no issue when raster is at most 2.0× the UI time per frame',
        (tester) async {
          // Three frames over the 16.7 ms budget, each 20 ms against 10 ms of
          // UI per frame: ratio 2.0, not above the threshold.
          detector.processTimelineData(
            rasterFramesData(
              rasterUs: const [20000, 20000, 20000],
              uiPerFrameUs: 10000,
            ),
          );
          expect(await scanVm(tester), isEmpty);
        },
      );

      testWidgets('no issue when the frames fit the frame budget', (
        tester,
      ) async {
        // Ratio 8, but 16 ms is under the 16.7 ms budget.
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [16000, 16000, 16000],
            uiPerFrameUs: 2000,
          ),
        );
        expect(await scanVm(tester), isEmpty);
      });

      testWidgets('2 missed frames in one poll stay silent', (tester) async {
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [25000, 25000, 1000, 1000],
            uiPerFrameUs: 10000,
          ),
        );
        expect(await scanVm(tester), isEmpty);
      });

      testWidgets('warning at 3 missed frames in one poll', (tester) async {
        // 25 ms of raster against 10 ms of UI per frame: ratio 2.5.
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [25000, 25000, 25000],
            uiPerFrameUs: 10000,
          ),
        );

        final issues = await scanVm(tester);
        expect(issues, hasLength(1));
        final issue = issues.first;
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.confirmed);
        expect(issue.title, 'Raster Dominance: 2.5× UI time');
        expect(issue.observationSource, ObservationSource.vmTimeline);
        expect(
          issue.confidenceReason,
          'Measured directly from VM timeline raster timing',
        );
        expect(
          issue.detail,
          '3 frames in one VM poll (about half a second) took longer than '
          'the 16.7ms frame budget to rasterize, with raster above 2.0 '
          'times the UI time of an average frame in that poll. The worst '
          'took 25.0ms against 10.0ms of UI time. No frame timings arrived, '
          'so this comes from the VM timeline alone.',
        );
        // Counted in one poll, so no window.
        expectMeasurement(
          issue,
          value: 3,
          unit: MeasurementUnit.frames,
          warningAt: detector.minRasterDominantFrames.toDouble(),
          criticalAt: detector.criticalRasterDominantFrames.toDouble(),
        );
      });

      testWidgets('9 missed frames in one poll warn, 10 are critical', (
        tester,
      ) async {
        await tester.pumpWidget(const _GpuTestApp());
        IssueSeverity? severityFor(int missed) {
          detector.processTimelineData(
            rasterFramesData(
              rasterUs: List.filled(missed, 20000),
              uiPerFrameUs: 1000,
            ),
          );
          detector.scanTree(tester.element(find.byType(_GpuTestApp)));
          return detector.issues.firstOrNull?.severity;
        }

        expect(severityFor(9), IssueSeverity.warning);
        expectSeverityMatchesMeasurement(detector.issues.single);
        expect(severityFor(10), IssueSeverity.critical);
        expectMeasurement(
          detector.issues.single,
          value: 10,
          unit: MeasurementUnit.frames,
          warningAt: detector.minRasterDominantFrames.toDouble(),
          criticalAt: detector.criticalRasterDominantFrames.toDouble(),
        );
        expectSeverityMatchesMeasurement(detector.issues.single);
      });

      testWidgets('severity follows the missed-frame count, not the raster '
          'time', (tester) async {
        await tester.pumpWidget(const _GpuTestApp());
        // Three frames of 50 ms, three times the budget: still a warning.
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [50000, 50000, 50000],
            uiPerFrameUs: 1000,
          ),
        );
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));
        expect(detector.issues.single.severity, IssueSeverity.warning);

        // Ten frames just over the budget: critical.
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: List.filled(10, 16668),
            uiPerFrameUs: 1000,
          ),
        );
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));
        expect(detector.issues.single.severity, IssueSeverity.critical);
      });

      testWidgets('missed frames count per poll, not across polls', (
        tester,
      ) async {
        // Two polls of 2 missed frames each: no single poll holds 3.
        detector
          ..processTimelineData(
            rasterFramesData(
              rasterUs: const [25000, 25000],
              uiPerFrameUs: 1000,
            ),
          )
          ..processTimelineData(
            rasterFramesData(
              rasterUs: const [25000, 25000],
              uiPerFrameUs: 1000,
            ),
          );
        expect(await scanVm(tester), isEmpty);
      });

      testWidgets('UI time is set per frame, not per poll', (tester) async {
        // Thirty frames of 40 ms against 2 ms of UI each: 60 ms of UI in the
        // poll. Against the poll's total the ratio would read 0.7.
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: List.filled(30, 40000),
            uiPerFrameUs: 2000,
          ),
        );
        final issues = await scanVm(tester);
        expect(issues.single.title, 'Raster Dominance: 20.0× UI time');
        expect(issues.single.severity, IssueSeverity.critical);
      });

      testWidgets('VM timing is read once per scan', (tester) async {
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [25000, 25000, 25000],
            uiPerFrameUs: 10000,
          ),
        );
        expect(await scanVm(tester), hasLength(1));

        // No poll since the last scan: nothing left to judge.
        expect(await scanVm(tester), isEmpty);
      });

      testWidgets('a batch without UI work is ignored', (tester) async {
        detector.processTimelineData(
          ParsedTimelineData(rasterDurations: const [30000, 30000, 30000]),
        );
        expect(await scanVm(tester), isEmpty);
      });

      testWidgets('the slowest missed frame sets the ratio', (tester) async {
        // 20 ms against 5 ms per frame (ratio 4), then 30 ms against 10 ms
        // per frame (ratio 3): the 30 ms frame is the worst.
        detector
          ..processTimelineData(
            rasterFramesData(
              rasterUs: const [20000, 20000, 20000],
              uiPerFrameUs: 5000,
            ),
          )
          ..processTimelineData(
            rasterFramesData(
              rasterUs: const [30000, 30000, 30000],
              uiPerFrameUs: 10000,
            ),
          );
        final issues = await scanVm(tester);
        expect(issues.single.title, 'Raster Dominance: 3.0× UI time');
        expect(issues.single.detail, contains('The worst took 30.0ms'));
      });

      testWidgets('updateFrameBudget sets the budget, floored at '
          'maxFrameRasterFloorUs', (tester) async {
        expect(detector.effectiveMaxFrameRasterFloorUs, 16667);
        detector.updateFrameBudget(8333);
        expect(detector.effectiveMaxFrameRasterFloorUs, 8333);
        detector.updateFrameBudget(4000);
        expect(detector.effectiveMaxFrameRasterFloorUs, 8000);
        detector.updateFrameBudget(0);
        expect(detector.effectiveMaxFrameRasterFloorUs, 8000);
        detector.resetFrameBudget();
        expect(detector.effectiveMaxFrameRasterFloorUs, 16667);

        // 12 ms against 3 ms of UI per frame misses a 120 Hz budget only.
        await tester.pumpWidget(const _GpuTestApp());
        detector.updateFrameBudget(8333);
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [12000, 12000, 12000],
            uiPerFrameUs: 3000,
          ),
        );
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));
        expect(detector.issues, hasLength(1));

        detector.resetFrameBudget();
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [12000, 12000, 12000],
            uiPerFrameUs: 3000,
          ),
        );
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('a route epoch drops the VM timing seen before it', (
        tester,
      ) async {
        detector.processTimelineData(
          rasterFramesData(rasterUs: List.filled(5, 25000), uiPerFrameUs: 1000),
        );
        detector.markRouteEpoch();
        // The route-change scan sees no frames, so only a VM timing held
        // from the previous route could raise the VM leg.
        expect(await scanVm(tester), isEmpty);
      });

      testWidgets('splits observed raster signal from likely node cause', (
        tester,
      ) async {
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [25000, 25000, 25000],
            uiPerFrameUs: 10000,
          ),
        );

        await tester.pumpWidget(const _OpacityDeepTree());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(2));

        final rasterIssue = detector.issues.firstWhere(
          (issue) => issue.stableId == 'raster_dominance',
        );
        final nodeIssue = detector.issues.firstWhere(
          (issue) => issue.stableId == 'expensive_gpu_nodes',
        );

        expect(rasterIssue.confidence, IssueConfidence.confirmed);
        expect(rasterIssue.detail, isNot(contains('Suspected cause')));
        expect(nodeIssue.confidence, IssueConfidence.likely);
        expect(nodeIssue.detail, contains('Raster-dominant frames coincided'));
      });
    });

    group('structural-only — expensive nodes', () {
      testWidgets('reports expensive nodes as possible', (tester) async {
        // No VM data, but tree has an Opacity with many descendants
        detector.vmConnected = false;

        await tester.pumpWidget(const _OpacityDeepTree());
        detector.scanTree(tester.element(find.byType(Directionality)));

        // RenderOpacity with >5 descendants should produce a structural issue
        expect(
          detector.issues,
          isNotEmpty,
          reason: 'RenderOpacity with deep subtree should be flagged',
        );
        expect(detector.issues.first.confidence, IssueConfidence.possible);
        expect(detector.issues.first.category, IssueCategory.raster);
        expect(detector.issues.first.title, contains('Expensive Render Nodes'));
        expect(detector.issues.first.measurement, isNull);
      });

      testWidgets('skips the clip a transparency Material builds for '
          'itself, keeps a user ClipPath', (tester) async {
        detector.vmConnected = false;

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Material(
              type: MaterialType.transparency,
              shape: const StadiumBorder(),
              child: Column(
                children: List.generate(8, (_) => const SizedBox(height: 2)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(
          detector.issues,
          isEmpty,
          reason: 'Material builds its own ClipPath for the shape',
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ClipPath(
              clipper: const ShapeBorderClipper(shape: StadiumBorder()),
              child: Column(
                children: List.generate(8, (_) => const SizedBox(height: 2)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues.single.stableId, 'expensive_gpu_nodes');
        expect(detector.issues.single.detail, contains('RenderClipPath'));
      });

      testWidgets('one render object is reported once however many wrapper '
          'elements resolve to it', (tester) async {
        detector.vmConnected = false;
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (_) => Builder(
                builder: (_) => ClipPath(
                  clipper: const ShapeBorderClipper(shape: StadiumBorder()),
                  child: Column(
                    children: List.generate(
                      8,
                      (_) => const SizedBox(height: 2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        final issue = detector.issues.single;
        expect(issue.title, 'Expensive Render Nodes: 1 found');
        expect('RenderClipPath'.allMatches(issue.detail).length, 1);
      });

      testWidgets('skips RenderOpacity when opacity is 1.0', (tester) async {
        detector.vmConnected = false;

        await tester.pumpWidget(const _OpacityFullTree(opacity: 1.0));
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues,
          isEmpty,
          reason: 'Opacity 1.0 skips saveLayer — should not be flagged',
        );
      });

      testWidgets('skips RenderOpacity when opacity is 0.0', (tester) async {
        detector.vmConnected = false;

        await tester.pumpWidget(const _OpacityFullTree(opacity: 0.0));
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues,
          isEmpty,
          reason: 'Opacity 0.0 short-circuits paint — should not be flagged',
        );
      });

      testWidgets('flags RenderOpacity when opacity is fractional', (
        tester,
      ) async {
        detector.vmConnected = false;

        await tester.pumpWidget(const _OpacityFullTree(opacity: 0.5));
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues,
          isNotEmpty,
          reason: 'Fractional opacity triggers saveLayer — should flag',
        );
      });

      testWidgets('flags ColorFiltered with deep subtree (v11.8)', (
        tester,
      ) async {
        detector.vmConnected = false;

        await tester.pumpWidget(const _ColorFilteredDeepTree());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues,
          isNotEmpty,
          reason: 'ColorFiltered with deep subtree should be flagged',
        );
        expect(detector.issues.first.detail, contains('RenderColorFiltered'));
      });

      testWidgets('notes missing raster timing with no VM and no frames', (
        tester,
      ) async {
        detector.vmConnected = false;

        await tester.pumpWidget(const _OpacityDeepTree());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues,
          isNotEmpty,
          reason: 'Should flag expensive nodes even without VM',
        );
        final rasterIssues = detector.issues.where(
          (i) => i.category == IssueCategory.raster,
        );
        expect(rasterIssues, isNotEmpty);
        expect(
          rasterIssues.first.detail,
          contains('Sleuth has not observed raster timing yet.'),
        );
        expect(
          rasterIssues.first.confidenceReason,
          'Structural pattern only. Sleuth saw no raster-dominant frames',
        );
      });

      testWidgets('drops the missing-timing note once frames arrive', (
        tester,
      ) async {
        detector = GpuPressureDetector(
          appStartMonotonicUsForTest: () => Timeline.now - 60000000,
        );
        detector.vmConnected = false;
        // A non-dominant frame still counts as raster timing observed.
        detector.processFrame(_frame(uiUs: 4000, rasterUs: 3000));

        await tester.pumpWidget(const _OpacityDeepTree());
        detector.scanTree(tester.element(find.byType(Directionality)));

        final nodes = detector.issues.single;
        expect(nodes.stableId, 'expensive_gpu_nodes');
        expect(nodes.confidence, IssueConfidence.possible);
        expect(nodes.detail, isNot(contains('has not observed raster timing')));
      });
    });

    group('vmConnected setter', () {
      testWidgets('VM-sourced raster_dominance cleared on disconnect', (
        tester,
      ) async {
        detector.vmConnected = true;
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [25000, 25000, 25000],
            uiPerFrameUs: 10000,
          ),
        );

        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));
        expect(detector.issues, isNotEmpty);

        detector.vmConnected = false;
        // No frame evidence: the VM-sourced issue is removed outright and
        // nothing confirmed or likely is left.
        expect(
          detector.issues.where((i) => i.stableId == 'raster_dominance'),
          isEmpty,
        );
        expect(
          detector.issues.where(
            (i) =>
                i.confidence == IssueConfidence.confirmed ||
                i.confidence == IssueConfidence.likely,
          ),
          isEmpty,
        );
      });

      testWidgets('structural issue survives disconnect downgraded when no frame '
          'evidence backs it', (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [25000, 25000, 25000],
            uiPerFrameUs: 10000,
          ),
        );

        // Use OpacityDeepTree to generate both raster_dominance + expensive_gpu_nodes
        await tester.pumpWidget(const _OpacityDeepTree());
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, hasLength(2));

        // Verify expensive_gpu_nodes starts as likely (corroborated by raster dominance)
        final nodesBefore = detector.issues.firstWhere(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(nodesBefore.confidence, IssueConfidence.likely);

        // Disconnect
        detector.vmConnected = false;

        // raster_dominance should be removed
        expect(
          detector.issues.where((i) => i.stableId == 'raster_dominance'),
          isEmpty,
        );

        // expensive_gpu_nodes should survive but downgraded to possible
        final nodesAfter = detector.issues.where(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(nodesAfter, hasLength(1));
        expect(nodesAfter.first.confidence, IssueConfidence.possible);
        expect(
          nodesAfter.first.confidenceReason,
          'Structural pattern only. Sleuth saw no raster-dominant frames',
        );
      });

      testWidgets(
        'after disconnect, next scanTree only produces structural issues',
        (tester) async {
          detector.vmConnected = true;
          detector.processTimelineData(
            rasterFramesData(
              rasterUs: const [25000, 25000, 25000],
              uiPerFrameUs: 10000,
            ),
          );

          await tester.pumpWidget(const _GpuTestApp());
          detector.scanTree(tester.element(find.byType(_GpuTestApp)));
          expect(detector.issues, isNotEmpty);

          // Disconnect
          detector.vmConnected = false;

          // Next scan should not produce raster ratio issues: the VM
          // values were cleared and no frames arrived.
          detector.scanTree(tester.element(find.byType(_GpuTestApp)));
          for (final issue in detector.issues) {
            expect(issue.confidence, IssueConfidence.possible);
          }
        },
      );
    });

    group('FrameTiming leg', () {
      // 60 s past Dart entry: outside the default 5 s startup window.
      var ageUs = 60000000;

      setUp(() {
        ageUs = 60000000;
        detector = GpuPressureDetector(
          appStartMonotonicUsForTest: () => Timeline.now - ageUs,
        );
      });

      /// Feeds [rasterUs] frames from [startUs], [spacingUs] apart, each
      /// with [uiUs] of UI time and a [frameBudgetUs] budget.
      void feed(
        List<int> rasterUs, {
        int startUs = 0,
        int spacingUs = 16667,
        int uiUs = 1000,
        int frameBudgetUs = 16667,
      }) {
        for (var i = 0; i < rasterUs.length; i++) {
          final vsync = startUs + i * spacingUs;
          detector.processFrame(
            _frame(
              uiUs: uiUs,
              rasterUs: rasterUs[i],
              vsyncStartUs: vsync,
              rasterFinishUs: vsync + rasterUs[i],
              frameBudgetUs: frameBudgetUs,
            ),
          );
        }
      }

      Future<List<PerformanceIssue>> scan(
        WidgetTester tester, [
        Widget tree = const _GpuTestApp(),
      ]) async {
        await tester.pumpWidget(tree);
        detector.scanTree(tester.element(find.byType(Directionality)));
        return detector.issues;
      }

      PerformanceIssue? raster(List<PerformanceIssue> issues) =>
          issues.where((i) => i.stableId == 'raster_dominance').firstOrNull;

      testWidgets('3 dominant frames in one second → likely warning', (
        tester,
      ) async {
        feed([19000, 18000, 20000]);
        final issue = raster(await scan(tester));

        expect(issue, isNotNull);
        expect(issue!.confidence, IssueConfidence.likely);
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.observationSource, ObservationSource.frameTiming);
        expect(issue.title, 'Raster Dominance: 19.0× UI time');
        expect(
          issue.confidenceReason,
          'Per-frame FrameTiming raster and UI durations',
        );
        expect(
          issue.detail,
          startsWith(
            '3 frames within one second missed their budget on the raster '
            'thread, with raster above 2.0 times the UI time (median '
            'raster-to-UI ratio 19.0).',
          ),
        );
        expect(
          issue.detail,
          contains(
            '3 of 3 frames since the last scan did so, the worst taking '
            '20.0ms.',
          ),
        );
        expect(issue.extraTraceArgs!.keys.toSet(), {
          'source',
          'observedDominantFrames',
          'dominantFrameCount',
          'windowFrameCount',
          'worstFrameRasterUs',
          'medianRatio',
          'lifecyclePhase',
        });
        expect(issue.extraTraceArgs!['source'], 'frame_timing');
        expect(issue.extraTraceArgs!['observedDominantFrames'], '3');
        expect(issue.extraTraceArgs!['dominantFrameCount'], '3');
        expect(issue.extraTraceArgs!['windowFrameCount'], '3');
        expect(issue.extraTraceArgs!['worstFrameRasterUs'], '20000');
        expect(issue.extraTraceArgs!['medianRatio'], '19.00');
        expect(issue.extraTraceArgs!['lifecyclePhase'], 'steady');
        // Last qualifying frame: vsync 2 × 16667 + raster 20000.
        expect(issue.dedupIdentityMicros, 2 * 16667 + 20000);
        // The count that sets severity, not the ratio in the title.
        expectMeasurement(
          issue,
          value: 3,
          unit: MeasurementUnit.frames,
          warningAt: detector.minRasterDominantFrames.toDouble(),
          criticalAt: detector.criticalRasterDominantFrames.toDouble(),
          window: const Duration(seconds: 1),
        );
        expect(
          detector.issues.where((i) => i.stableId == 'raster_dominance'),
          hasLength(1),
        );
      });

      testWidgets('2 dominant frames → none', (tester) async {
        feed([20000, 20000]);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('3 dominant frames 2 s apart → none', (tester) async {
        feed([20000, 20000, 20000], spacingUs: 2000000);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('3 inside one second plus 1 outside → emits, 3 qualify', (
        tester,
      ) async {
        feed([20000], startUs: 0);
        feed([20000, 20000, 20000], startUs: 3000000);
        final issue = raster(await scan(tester));

        expect(issue, isNotNull);
        expect(issue!.detail, startsWith('3 frames within one second'));
        expect(issue.detail, contains('4 of 4 frames since the last scan'));
        expect(issue.extraTraceArgs!['dominantFrameCount'], '4');
        expect(issue.extraTraceArgs!['observedDominantFrames'], '3');
      });

      testWidgets('a frame within its budget does not count, however large '
          'its ratio', (tester) async {
        // 16 ms of raster against 1 ms of UI, but the 60 Hz frame made its
        // deadline.
        feed([16000, 16000, 16000, 16000]);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('each frame is judged against its own budget', (
        tester,
      ) async {
        // 14 ms of raster misses a 90 Hz budget.
        feed([14000, 14000, 14000], frameBudgetUs: 11111);
        expect(raster(await scan(tester)), isNotNull);

        // The same frames fit a 60 Hz budget.
        detector = GpuPressureDetector(
          appStartMonotonicUsForTest: () => Timeline.now - ageUs,
        );
        feed([14000, 14000, 14000]);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('updateFrameBudget does not change the frame leg', (
        tester,
      ) async {
        detector.updateFrameBudget(8333);
        // 12 ms of raster fits each frame's own 60 Hz budget.
        feed([12000, 12000, 12000]);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('maxFrameRasterFloorUs applies on top of the frame budget', (
        tester,
      ) async {
        detector = GpuPressureDetector(
          maxFrameRasterFloorUs: 25000,
          appStartMonotonicUsForTest: () => Timeline.now - ageUs,
        );
        feed([24000, 24000, 24000]);
        expect(raster(await scan(tester)), isNull);
        feed([26000, 26000, 26000], startUs: 5000000);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('non-monotonic vsync timestamps are ordered before the '
          'span check', (tester) async {
        for (final vsync in [500000, 0, 200000]) {
          detector.processFrame(
            _frame(uiUs: 1000, rasterUs: 20000, vsyncStartUs: vsync),
          );
        }
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('frames without timestamps count as one span', (
        tester,
      ) async {
        for (var i = 0; i < 3; i++) {
          detector.processFrame(_frame(uiUs: 1000, rasterUs: 20000));
        }
        final issue = raster(await scan(tester));
        expect(issue, isNotNull);
        expect(issue!.dedupIdentityMicros, isNull);
      });

      testWidgets('a route epoch drops the dominant frames seen before it', (
        tester,
      ) async {
        feed([20000, 20000]);
        detector.markRouteEpoch();
        feed([20000], startUs: 2 * 16667);
        expect(raster(await scan(tester)), isNull);

        // Three on the new route emit.
        feed([20000, 20000, 20000], startUs: 100000);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('the issue keeps the route active at emission', (
        tester,
      ) async {
        var route = '/feed';
        detector = GpuPressureDetector(
          sourceRouteProvider: () => route,
          appStartMonotonicUsForTest: () => Timeline.now - ageUs,
        );
        feed([20000, 20000, 20000]);
        final issue = raster(await scan(tester))!;
        route = '/settings';
        expect(issue.sourceRoute, '/feed');
        expect(raster(detector.issues)!.sourceRoute, '/feed');
      });

      testWidgets('10 dominant frames in one second → critical', (
        tester,
      ) async {
        feed(List.filled(10, 20000));
        final issue = raster(await scan(tester));
        expect(issue!.severity, IssueSeverity.critical);
        expect(issue.detail, startsWith('10 frames within one second'));
        expectMeasurement(
          issue,
          value: 10,
          unit: MeasurementUnit.frames,
          warningAt: detector.minRasterDominantFrames.toDouble(),
          criticalAt: detector.criticalRasterDominantFrames.toDouble(),
          window: const Duration(seconds: 1),
        );
        expectSeverityMatchesMeasurement(issue);
      });

      testWidgets('9 dominant frames in one second → warning', (tester) async {
        feed(List.filled(9, 20000));
        expect(raster(await scan(tester))!.severity, IssueSeverity.warning);
      });

      testWidgets('10 dominant frames spread over 2 s → warning', (
        tester,
      ) async {
        // 200 ms apart: at most 5 inside any one-second span.
        feed(List.filled(10, 20000), spacingUs: 200000);
        final issue = raster(await scan(tester));
        expect(issue!.severity, IssueSeverity.warning);
        expect(issue.detail, startsWith('5 frames within one second'));
        expect(issue.measurement!.value, 5);
        expectSeverityMatchesMeasurement(issue);
      });

      testWidgets('criticalRasterDominantFrames sets the critical count', (
        tester,
      ) async {
        detector = GpuPressureDetector(
          criticalRasterDominantFrames: 4,
          appStartMonotonicUsForTest: () => Timeline.now - ageUs,
        );
        feed([20000, 20000, 20000]);
        expect(raster(await scan(tester))!.severity, IssueSeverity.warning);
        feed([20000], startUs: 3 * 16667);
        final critical = raster(await scan(tester))!;
        expect(critical.severity, IssueSeverity.critical);
        expect(critical.measurement!.criticalAt, 4);
        expectSeverityMatchesMeasurement(critical);
      });

      testWidgets('frames with zero UI or zero raster are skipped', (
        tester,
      ) async {
        for (var i = 0; i < 3; i++) {
          detector.processFrame(_frame(uiUs: 0, rasterUs: 20000));
          detector.processFrame(_frame(uiUs: 1000, rasterUs: 0));
        }
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('frames inside the startup window are ignored', (
        tester,
      ) async {
        ageUs = 1000000; // 1 s after Dart entry, inside the 5 s window.
        feed([20000, 20000, 20000]);
        expect(raster(await scan(tester)), isNull);

        ageUs = 10000000; // 10 s after Dart entry.
        feed([20000, 20000, 20000]);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('VM timeline polls inside the startup window are ignored', (
        tester,
      ) async {
        detector.vmConnected = true;
        ageUs = 1000000;
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [25000, 25000, 25000],
            uiPerFrameUs: 10000,
          ),
        );
        expect(raster(await scan(tester)), isNull);

        ageUs = 10000000;
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [25000, 25000, 25000],
            uiPerFrameUs: 10000,
          ),
        );
        final issue = raster(await scan(tester));
        expect(issue, isNotNull);
        expect(issue!.observationSource, ObservationSource.vmTimeline);
      });

      testWidgets('startupPhaseWindowSeconds sets the window', (tester) async {
        ageUs = 3000000;
        detector = GpuPressureDetector(
          startupPhaseWindowSeconds: 2,
          appStartMonotonicUsForTest: () => Timeline.now - ageUs,
        );
        feed([20000, 20000, 20000]);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('a burst split by a scan counts once', (tester) async {
        feed([20000, 20000]);
        expect(raster(await scan(tester)), isNull);

        feed([20000], startUs: 2 * 16667);
        final issue = raster(await scan(tester));
        expect(issue, isNotNull);
        expect(issue!.detail, startsWith('3 frames within one second'));
        expect(issue.detail, contains('1 of 1 frames since the last scan'));
        expect(issue.extraTraceArgs!['dominantFrameCount'], '1');
        expect(issue.extraTraceArgs!['windowFrameCount'], '1');
        // The span reaches back across the scan, so it holds all three.
        expect(issue.extraTraceArgs!['observedDominantFrames'], '3');
      });

      testWidgets('10 dominant frames split by a scan reach critical', (
        tester,
      ) async {
        feed(List.filled(5, 20000));
        final first = raster(await scan(tester))!;
        expect(first.severity, IssueSeverity.warning);
        expect(first.extraTraceArgs!['observedDominantFrames'], '5');

        feed(List.filled(5, 20000), startUs: 5 * 16667);
        final second = raster(await scan(tester))!;
        expect(second.severity, IssueSeverity.critical);
        expect(second.extraTraceArgs!['observedDominantFrames'], '10');
        expect(second.dedupIdentityMicros, isNot(first.dedupIdentityMicros));
      });

      testWidgets('a burst longer than a second stamps its busiest span, '
          'not its length', (tester) async {
        // 14 dominant frames 80 ms apart span 1.04 s; the busiest half-open
        // second holds 13 of them.
        feed(List.filled(14, 20000), spacingUs: 80000);
        final issue = raster(await scan(tester))!;
        expect(issue.extraTraceArgs!['observedDominantFrames'], '13');
        expect(issue.extraTraceArgs!['dominantFrameCount'], '14');
        expect(issue.severity, IssueSeverity.critical);
      });

      testWidgets('two frames exactly a second apart fall in different spans', (
        tester,
      ) async {
        feed([20000, 20000], spacingUs: 1000000);
        feed([20000], startUs: 1000000 + 16667);
        // Frames at 0, 1 000 000 and 1 016 667: the second span holds 2.
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('resetCaptureState drops held frames, the VM leg and the '
          'raster issue', (tester) async {
        feed([20000, 20000, 20000]);
        await scan(tester, const _OpacityDeepTree());
        expect(raster(detector.issues), isNotNull);

        detector.resetCaptureState();
        expect(raster(detector.issues), isNull);
        expect(
          detector.issues.where((i) => i.stableId == 'expensive_gpu_nodes'),
          hasLength(1),
        );

        // Two frames after the reset cannot pair with the three before it.
        feed([20000, 20000], startUs: 3 * 16667);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('resetCaptureState clears VM timing seen before it', (
        tester,
      ) async {
        detector.vmConnected = true;
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 25000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
          ),
        );
        detector.resetCaptureState();
        feed([20000, 20000, 20000]);
        final issue = raster(await scan(tester))!;
        expect(issue.confidence, IssueConfidence.likely);
        expect(issue.extraTraceArgs!.containsKey('vmWorstRasterUs'), isFalse);
      });

      testWidgets('a scan drops held frames more than a second before the '
          'newest frame', (tester) async {
        feed([20000, 20000, 20000]);
        // Balanced frames run on to 2 s past the burst before the scan.
        feed([2000], startUs: 2000000);
        expect(raster(await scan(tester)), isNotNull);

        // The burst was dropped at that scan, so a later frame finds
        // nothing held.
        feed([2000], startUs: 2000000 + 16667);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('a burst is reported at one scan only', (tester) async {
        feed([20000, 20000, 20000]);
        feed(List.filled(20, 2000), startUs: 3 * 16667);
        expect(raster(await scan(tester)), isNotNull);

        // Balanced frames within a second of the burst: the burst stays
        // held for a later split, but it is not reported again.
        feed(List.filled(20, 2000), startUs: 23 * 16667);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('new dominant frames in another second do not revive a '
          'reported burst', (tester) async {
        feed([20000, 20000, 20000]);
        expect(raster(await scan(tester)), isNotNull);

        // Two dominant frames just over a second after the burst began
        // share a second with at most one held frame.
        feed([20000, 20000], startUs: 1020000);
        expect(raster(await scan(tester)), isNull);

        // A third new frame in that second fires.
        feed([20000], startUs: 1020000 + 2 * 16667);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('a frame without a timestamp held after a timed one is '
          'dropped at the scan', (tester) async {
        feed([20000, 20000]);
        detector.processFrame(_frame(uiUs: 1000, rasterUs: 20000));
        expect(raster(await scan(tester)), isNull);

        // Had the untimed frame survived, it and two new untimed frames
        // would form a span of 3.
        detector
          ..processFrame(_frame(uiUs: 1000, rasterUs: 20000))
          ..processFrame(_frame(uiUs: 1000, rasterUs: 20000));
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('a scan without new frames keeps the held frames', (
        tester,
      ) async {
        feed([20000, 20000]);
        expect(raster(await scan(tester)), isNull);

        // Nothing arrived since the last scan, as when a scan lands between
        // two frame-timing batches: no issue, and the held frames stay.
        expect(raster(await scan(tester)), isNull);

        feed([20000], startUs: 2 * 16667);
        final issue = raster(await scan(tester));
        expect(issue, isNotNull);
        expect(issue!.detail, startsWith('3 frames within one second'));
      });

      testWidgets('a held burst older than a second is pruned at the next '
          'scan with frames', (tester) async {
        feed([20000, 20000]);
        expect(raster(await scan(tester)), isNull);
        expect(raster(await scan(tester)), isNull);

        // The next frames arrive 2 s later: the held pair cannot join them.
        feed([20000], startUs: 2000000);
        expect(raster(await scan(tester)), isNull);
        feed([20000], startUs: 2000000 + 16667);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('VM and frame legs → one confirmed issue', (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 25000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
          ),
        );
        feed([20000, 20000, 20000]);
        final issues = await scan(tester);

        final rasterIssues = issues
            .where((i) => i.stableId == 'raster_dominance')
            .toList();
        expect(rasterIssues, hasLength(1));
        final issue = rasterIssues.single;
        expect(issue.confidence, IssueConfidence.confirmed);
        expect(issue.observationSource, ObservationSource.frameTiming);
        expect(
          issue.confidenceReason,
          'Per-frame FrameTiming raster and UI durations, confirmed by the '
          'VM timeline raster timing',
        );
        expect(issue.extraTraceArgs!['vmWorstRasterUs'], '25000');
      });

      testWidgets('a realistic VM poll of 30 raster-bound frames confirms '
          'the frame-leg issue', (tester) async {
        detector.vmConnected = true;
        // 40 ms of raster against 2 ms of UI per frame, 60 ms of UI in the
        // poll. Against the poll's UI total the ratio would read 0.7 and
        // never confirm.
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: List.filled(30, 40000),
            uiPerFrameUs: 2000,
          ),
        );
        feed([20000, 20000, 20000]);
        final issue = raster(await scan(tester))!;
        expect(issue.confidence, IssueConfidence.confirmed);
        expect(issue.extraTraceArgs!['vmWorstRasterUs'], '40000');
      });

      testWidgets('a UI-bound VM poll of 30 frames does not confirm', (
        tester,
      ) async {
        detector.vmConnected = true;
        // 18 ms of raster misses the budget, but against 20 ms of UI per
        // frame raster is not the larger cost.
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: List.filled(30, 18000),
            uiPerFrameUs: 20000,
          ),
        );
        feed([20000, 20000, 20000]);
        final issue = raster(await scan(tester))!;
        expect(issue.confidence, IssueConfidence.likely);
        expect(issue.extraTraceArgs!.containsKey('vmWorstRasterUs'), isFalse);
      });

      testWidgets('VM timing within the budget leaves the frame-leg issue '
          'likely', (tester) async {
        detector.vmConnected = true;
        // Ratio 8, but 16 ms fits the 60 Hz budget.
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 16000,
            buildUs: 1000,
            layoutUs: 500,
            paintUs: 500,
          ),
        );
        feed([20000, 20000, 20000]);
        final issue = raster(await scan(tester))!;
        expect(issue.confidence, IssueConfidence.likely);
        expect(issue.extraTraceArgs!.containsKey('vmWorstRasterUs'), isFalse);
      });

      testWidgets('VM timing at or below the ratio leaves the frame-leg issue '
          'likely', (tester) async {
        detector.vmConnected = true;
        // 20 ms over the budget against 10 ms of UI: ratio 2.0.
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 20000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
          ),
        );
        feed([20000, 20000, 20000]);
        expect(raster(await scan(tester))!.confidence, IssueConfidence.likely);
      });

      testWidgets('the VM leg stays silent while frames arrive', (
        tester,
      ) async {
        detector.vmConnected = true;
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [25000, 25000, 25000],
            uiPerFrameUs: 10000,
          ),
        );
        // Balanced frames: the frame leg does not fire, and the VM leg
        // only speaks for itself when no frames arrived.
        feed([3000, 3000, 3000]);
        final issues = await scan(tester, const _OpacityDeepTree());
        expect(raster(issues), isNull);
        final nodes = issues.firstWhere(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(nodes.confidence, IssueConfidence.possible);
      });

      testWidgets('VM disconnect keeps the frame-leg issue and likely nodes', (
        tester,
      ) async {
        detector.vmConnected = true;
        feed([20000, 20000, 20000]);
        await scan(tester, const _OpacityDeepTree());
        expect(raster(detector.issues)!.confidence, IssueConfidence.likely);

        detector.vmConnected = false;

        final issue = raster(detector.issues);
        expect(issue, isNotNull);
        expect(issue!.confidence, IssueConfidence.likely);
        expect(issue.observationSource, ObservationSource.frameTiming);
        final nodes = detector.issues.firstWhere(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(nodes.confidence, IssueConfidence.likely);
      });

      testWidgets('VM disconnect returns a VM-confirmed frame-leg issue to '
          'likely', (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(rasterDominantData(rasterUs: 25000));
        feed([20000, 20000, 20000]);
        await scan(tester, const _OpacityDeepTree());
        expect(raster(detector.issues)!.confidence, IssueConfidence.confirmed);

        detector.vmConnected = false;

        final rasterIssues = detector.issues
            .where((i) => i.stableId == 'raster_dominance')
            .toList();
        expect(rasterIssues, hasLength(1));
        final issue = rasterIssues.single;
        expect(issue.confidence, IssueConfidence.likely);
        expect(issue.observationSource, ObservationSource.frameTiming);
        expect(
          issue.confidenceReason,
          'Per-frame FrameTiming raster and UI durations',
        );
        final nodes = detector.issues.firstWhere(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(nodes.confidence, IssueConfidence.likely);
      });

      testWidgets('VM disconnect with a VM-only issue removes it', (
        tester,
      ) async {
        detector.vmConnected = true;
        detector.processTimelineData(
          rasterFramesData(
            rasterUs: const [25000, 25000, 25000],
            uiPerFrameUs: 10000,
          ),
        );
        await scan(tester, const _OpacityDeepTree());
        expect(raster(detector.issues), isNotNull);

        detector.vmConnected = false;

        expect(raster(detector.issues), isNull);
        final nodes = detector.issues.firstWhere(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(nodes.confidence, IssueConfidence.possible);
      });

      testWidgets('expensive_gpu_nodes is likely on the frame leg alone', (
        tester,
      ) async {
        feed([20000, 20000, 20000]);
        final issues = await scan(tester, const _OpacityDeepTree());
        final nodes = issues.firstWhere(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(nodes.confidence, IssueConfidence.likely);
        expect(
          nodes.confidenceReason,
          'Raster-dominant frames and a structural render node scan',
        );
        expect(nodes.detail, isNot(contains('has not observed raster timing')));
      });

      testWidgets('disabled detector ignores frames', (tester) async {
        detector.isEnabled = false;
        feed([20000, 20000, 20000]);
        detector.isEnabled = true;
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('rasterMultiplierThreshold applies per frame', (
        tester,
      ) async {
        detector = GpuPressureDetector(
          rasterMultiplierThreshold: 3.0,
          appStartMonotonicUsForTest: () => Timeline.now - ageUs,
        );
        // Ratio 2.86 (20 ms against 7 ms): below 3.0.
        feed([20000, 20000, 20000], uiUs: 7000);
        expect(raster(await scan(tester)), isNull);
        // Ratio 3.33 (20 ms against 6 ms): above 3.0.
        feed([20000, 20000, 20000], startUs: 5000000, uiUs: 6000);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('minRasterDominantFrames applies', (tester) async {
        detector = GpuPressureDetector(
          minRasterDominantFrames: 5,
          appStartMonotonicUsForTest: () => Timeline.now - ageUs,
        );
        feed([20000, 20000, 20000, 20000]);
        expect(raster(await scan(tester)), isNull);
        feed([20000], startUs: 4 * 16667);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('100 dominant frames: ring keeps 64, count reports 100', (
        tester,
      ) async {
        for (var i = 0; i < 100; i++) {
          detector.processFrame(_frame(uiUs: 1000, rasterUs: 20000));
        }
        final issue = raster(await scan(tester));
        expect(issue!.extraTraceArgs!['dominantFrameCount'], '100');
        expect(issue.detail, startsWith('64 frames within one second'));
        expect(issue.severity, IssueSeverity.critical);
      });

      testWidgets('dispose clears frame state', (tester) async {
        feed([20000, 20000, 20000]);
        detector.dispose();
        expect(raster(await scan(tester)), isNull);
      });
    });

    group('highlights', () {
      testWidgets('no highlights when no expensive nodes found', (
        tester,
      ) async {
        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));

        expect(detector.highlights, isEmpty);
      });

      test('highlights cleared on dispose', () {
        detector.dispose();
        expect(detector.highlights, isEmpty);
      });
    });

    // -----------------------------------------------------------------
    // Custom thresholds
    // -----------------------------------------------------------------

    testWidgets('custom rasterMultiplierThreshold fires at adjusted ratio', (
      tester,
    ) async {
      detector = GpuPressureDetector(rasterMultiplierThreshold: 3.0);
      detector.vmConnected = true;
      // 32 ms against 10 ms of UI per frame: ratio 3.2 > 3.0, warning.
      detector.processTimelineData(
        rasterFramesData(
          rasterUs: const [32000, 32000, 32000],
          uiPerFrameUs: 10000,
        ),
      );
      await tester.pumpWidget(const _GpuTestApp());
      detector.scanTree(tester.element(find.byType(_GpuTestApp)));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    testWidgets('custom threshold below ratio does not fire', (tester) async {
      detector = GpuPressureDetector(rasterMultiplierThreshold: 3.0);
      detector.vmConnected = true;
      // 25 ms against 10 ms of UI per frame: ratio 2.5 < 3.0, no issue.
      detector.processTimelineData(
        rasterFramesData(
          rasterUs: const [25000, 25000, 25000],
          uiPerFrameUs: 10000,
        ),
      );
      await tester.pumpWidget(const _GpuTestApp());
      detector.scanTree(tester.element(find.byType(_GpuTestApp)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('with a custom threshold, critical still follows the '
        'missed-frame count', (tester) async {
      detector = GpuPressureDetector(rasterMultiplierThreshold: 3.0);
      detector.vmConnected = true;
      // 35 ms against 10 ms of UI per frame: ratio 3.5, under twice the
      // threshold, but 10 such frames in one poll are critical.
      detector.processTimelineData(
        rasterFramesData(rasterUs: List.filled(10, 35000), uiPerFrameUs: 10000),
      );
      await tester.pumpWidget(const _GpuTestApp());
      detector.scanTree(tester.element(find.byType(_GpuTestApp)));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    // -----------------------------------------------------------------
    // v11.12: BackdropFilter sigma-aware severity
    // -----------------------------------------------------------------

    group('BackdropFilter sigma-aware severity', () {
      testWidgets('suppresses BackdropFilter with low sigma (<=2.0)', (
        tester,
      ) async {
        await tester.pumpWidget(const _BackdropFilterTree(sigma: 1.0));
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues,
          isEmpty,
          reason: 'Low sigma (1.0) should be suppressed',
        );
        expect(detector.highlights, isEmpty);
      });

      testWidgets('suppresses BackdropFilter at sigma boundary (2.0)', (
        tester,
      ) async {
        await tester.pumpWidget(const _BackdropFilterTree(sigma: 2.0));
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues,
          isEmpty,
          reason: 'Sigma 2.0 at threshold — should be suppressed',
        );
      });

      testWidgets('flags BackdropFilter with medium sigma (5.0)', (
        tester,
      ) async {
        await tester.pumpWidget(const _BackdropFilterTree(sigma: 5.0));
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues,
          isNotEmpty,
          reason: 'Sigma 5.0 should be flagged',
        );
        expect(detector.issues.first.detail, contains('σ=5.0'));
      });

      testWidgets('critical highlight for high sigma (>10.0)', (tester) async {
        await tester.pumpWidget(const _BackdropFilterTree(sigma: 15.0));
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.highlights, isNotEmpty);
        expect(detector.highlights.first.severity, IssueSeverity.critical);
        expect(detector.highlights.first.detail, contains('σ=15.0'));
      });

      testWidgets('warning highlight for moderate sigma', (tester) async {
        await tester.pumpWidget(const _BackdropFilterTree(sigma: 5.0));
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.highlights, isNotEmpty);
        expect(detector.highlights.first.severity, IssueSeverity.warning);
      });

      testWidgets('expensive node detail includes sigma', (tester) async {
        await tester.pumpWidget(const _BackdropFilterTree(sigma: 8.0));
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.detail, contains('σ=8.0'));
      });

      testWidgets('sigma just above threshold (3.0) is flagged', (
        tester,
      ) async {
        await tester.pumpWidget(const _BackdropFilterTree(sigma: 3.0));
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues,
          isNotEmpty,
          reason: 'Sigma 3.0 is above 2.0 threshold — should flag',
        );
      });

      testWidgets('non-blur ImageFilter gracefully handled', (tester) async {
        // BackdropFilter with a non-blur filter (dilate) — sigma extraction
        // returns null, so no suppression or sigma detail.
        await tester.pumpWidget(const _BackdropFilterNonBlur());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(
          detector.issues,
          isNotEmpty,
          reason: 'Non-blur BackdropFilter should still be flagged',
        );
        // No sigma in detail since it's not a blur filter.
        expect(detector.issues.first.detail, isNot(contains('σ=')));
      });

      testWidgets('a disabled BackdropFilter draws nothing and is not '
          'reported', (tester) async {
        await tester.pumpWidget(
          const _BackdropFilterTree(sigma: 20, enabled: false),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('a blur composed with a matrix has an unknown sigma and '
          'is reported without one', (tester) async {
        await tester.pumpWidget(
          _BackdropFilterTree.withFilter(
            ui.ImageFilter.compose(
              outer: ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1),
              inner: ui.ImageFilter.matrix(
                Matrix4.diagonal3Values(2, 2, 1).storage,
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.detail, isNot(contains('σ=')));
      });

      testWidgets('two weak blurs composed add up: 1 and 1 stay below the '
          'threshold, 1 and 2 (2.24) cross it', (tester) async {
        await tester.pumpWidget(
          _BackdropFilterTree.withFilter(
            ui.ImageFilter.compose(
              outer: ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1),
              inner: ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);

        await tester.pumpWidget(
          _BackdropFilterTree.withFilter(
            ui.ImageFilter.compose(
              outer: ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1),
              inner: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isNotEmpty);
      });
    });

    group('Cupertino chrome blur', () {
      Widget page({Color? barColor}) => CupertinoApp(
        home: CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: const Text('Title'),
            backgroundColor: barColor,
            automaticBackgroundVisibility: false,
          ),
          child: ListView(
            children: List.generate(
              30,
              (i) => SizedBox(key: ValueKey(i), height: 40),
            ),
          ),
        ),
      );

      testWidgets('a translucent navigation bar is reported as the bar\'s '
          'own blur, with a fix the app can make', (tester) async {
        await tester.pumpWidget(page());
        detector.scanTree(tester.element(find.byType(CupertinoApp)));
        expect(detector.issues, hasLength(1));
        final issue = detector.issues.single;
        expect(issue.detail, contains('σ=10.0'));
        expect(issue.detail, contains('drawn by CupertinoNavigationBar'));
        expect(issue.fixHint, contains('opaque backgroundColor'));
        expect(issue.fixHint, contains('enableBackgroundFilterBlur: false'));
      });

      testWidgets('an opaque navigation bar is not reported', (tester) async {
        await tester.pumpWidget(page(barColor: const Color(0xFFFFFFFF)));
        detector.scanTree(tester.element(find.byType(CupertinoApp)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('a card of chrome blurs only leaves out the '
          'RepaintBoundary advice', (tester) async {
        await tester.pumpWidget(page());
        detector.scanTree(tester.element(find.byType(CupertinoApp)));
        expect(
          detector.issues.single.fixHint,
          isNot(contains('Wrap expensive subtrees')),
        );
      });

      test('two bars read as one sentence in the plural', () {
        final (hint, _) = FixHintBuilder.expensiveGpuNodes(
          blurChromeOwners: {'CupertinoTabBar', 'CupertinoNavigationBar'},
          onlyChrome: true,
        );
        expect(
          hint,
          contains(
            'CupertinoNavigationBar and CupertinoTabBar blur the content '
            'behind them while their background is translucent. Give them',
          ),
        );
      });

      testWidgets('every SDK chrome widget owns its blur within its hop '
          'budget', (tester) async {
        final cases = <String, Widget>{
          'CupertinoNavigationBar': const CupertinoNavigationBar(
            middle: Text('Title'),
            automaticBackgroundVisibility: false,
          ),
          'CupertinoTabBar': CupertinoTabBar(
            items: const [
              BottomNavigationBarItem(icon: Icon(CupertinoIcons.home)),
              BottomNavigationBarItem(icon: Icon(CupertinoIcons.search)),
            ],
          ),
          'CupertinoSliverNavigationBar': const SizedBox(
            height: 300,
            child: CustomScrollView(
              slivers: [CupertinoSliverNavigationBar(largeTitle: Text('T'))],
            ),
          ),
          'CupertinoPopupSurface': const CupertinoPopupSurface(
            child: SizedBox(width: 100, height: 100),
          ),
          'CupertinoActionSheet': CupertinoActionSheet(
            actions: [
              CupertinoActionSheetAction(
                onPressed: () {},
                child: const Text('A'),
              ),
            ],
          ),
        };
        for (final MapEntry(key: owner, value: widget) in cases.entries) {
          await tester.pumpWidget(
            CupertinoApp(
              home: CupertinoPageScaffold(
                child: SafeArea(child: SingleChildScrollView(child: widget)),
              ),
            ),
          );
          final owners = {
            for (final e in find.byType(BackdropFilter).evaluate())
              cupertinoBlurOwner(e),
          };
          expect(owners, contains(owner), reason: owner);
        }
      });

      testWidgets('an app blur inside an unpainted popup surface is the '
          'app\'s', (tester) async {
        await tester.pumpWidget(
          CupertinoApp(
            home: CupertinoPopupSurface(
              isSurfacePainted: false,
              child: BackdropFilter(
                key: const ValueKey('app'),
                filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: const SizedBox(width: 100, height: 100),
              ),
            ),
          ),
        );
        expect(
          cupertinoBlurOwner(tester.element(find.byKey(const ValueKey('app')))),
          isNull,
        );
      });

      testWidgets('an app blur keeps the plain fix hint', (tester) async {
        await tester.pumpWidget(const _BackdropFilterTree(sigma: 20));
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues.single.detail, isNot(contains('drawn by')));
        expect(
          detector.issues.single.fixHint,
          isNot(contains('enableBackgroundFilterBlur')),
        );
      });
    });
  });
}

FrameStats _frame({
  required int uiUs,
  required int rasterUs,
  int? vsyncStartUs,
  int? rasterFinishUs,
  int frameBudgetUs = 16667,
}) => FrameStats(
  frameNumber: 0,
  uiDuration: Duration(microseconds: uiUs),
  rasterDuration: Duration(microseconds: rasterUs),
  timestamp: DateTime(2026),
  frameBudgetUs: frameBudgetUs,
  vsyncStartUs: vsyncStartUs,
  rasterFinishUs: rasterFinishUs,
);

/// Simple widget tree with no expensive render objects.
class _GpuTestApp extends StatelessWidget {
  const _GpuTestApp();

  @override
  Widget build(BuildContext context) {
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          SizedBox(width: 10, height: 10),
          SizedBox(width: 10, height: 10),
        ],
      ),
    );
  }
}

/// Widget tree with configurable opacity wrapping many descendants.
class _OpacityFullTree extends StatelessWidget {
  const _OpacityFullTree({required this.opacity});
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Opacity(
        opacity: opacity,
        child: Column(
          children: List.generate(
            10,
            (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
          ),
        ),
      ),
    );
  }
}

/// Widget tree with Opacity wrapping many descendants.
class _OpacityDeepTree extends StatelessWidget {
  const _OpacityDeepTree();

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Opacity(
        opacity: 0.5,
        child: Column(
          children: List.generate(
            10,
            (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
          ),
        ),
      ),
    );
  }
}

/// Widget tree with ColorFiltered wrapping many descendants.
class _ColorFilteredDeepTree extends StatelessWidget {
  const _ColorFilteredDeepTree();

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColorFiltered(
        colorFilter: const ColorFilter.mode(
          Color(0x80000000),
          BlendMode.srcATop,
        ),
        child: Column(
          children: List.generate(
            10,
            (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
          ),
        ),
      ),
    );
  }
}

/// Widget tree with BackdropFilter wrapping many descendants at a given sigma.
class _BackdropFilterTree extends StatelessWidget {
  const _BackdropFilterTree({required double this.sigma, this.enabled = true})
    : filter = null;
  const _BackdropFilterTree.withFilter(ui.ImageFilter this.filter)
    : sigma = null,
      enabled = true;
  final double? sigma;
  final ui.ImageFilter? filter;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          BackdropFilter(
            enabled: enabled,
            filter:
                filter ?? ui.ImageFilter.blur(sigmaX: sigma!, sigmaY: sigma!),
            child: Column(
              children: List.generate(
                10,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// BackdropFilter with a non-blur ImageFilter (dilate).
class _BackdropFilterNonBlur extends StatelessWidget {
  const _BackdropFilterNonBlur();

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          BackdropFilter(
            filter: ui.ImageFilter.dilate(radiusX: 2, radiusY: 2),
            child: Column(
              children: List.generate(
                10,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
