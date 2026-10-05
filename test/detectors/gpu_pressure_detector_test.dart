import 'dart:developer' show Timeline;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/performance_issue.dart';

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

    group('VM connected — raster ratio', () {
      setUp(() {
        detector.vmConnected = true;
      });

      testWidgets('no issue when raster <= UI x threshold', (tester) async {
        // Raster 10ms, UI 10ms — ratio = 1.0 (below 2.0 threshold)
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 10000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
          ),
        );

        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));

        expect(detector.issues, isEmpty);
      });

      testWidgets('warning when raster > UI x 2.0', (tester) async {
        // Raster 25ms, UI 10ms — ratio = 2.5
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 25000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
          ),
        );

        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity, IssueSeverity.warning);
        expect(detector.issues.first.title, contains('Raster Dominance'));
      });

      testWidgets('critical when raster > UI x 4.0', (tester) async {
        // Raster 50ms, UI 10ms — ratio = 5.0
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 50000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
          ),
        );

        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity, IssueSeverity.critical);
      });

      testWidgets('confidence is confirmed without expensive nodes', (
        tester,
      ) async {
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 25000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
          ),
        );

        // Simple tree — no expensive render objects
        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
      });

      testWidgets('splits observed raster signal from likely node cause', (
        tester,
      ) async {
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 25000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
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

        expect(rasterIssue.stableId, 'raster_dominance');
        expect(nodeIssue.stableId, 'expensive_gpu_nodes');
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
          contains('No raster timing observed yet.'),
        );
        expect(
          rasterIssues.first.confidenceReason,
          'Structural pattern only — no raster-dominant frames observed',
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
        expect(nodes.detail, isNot(contains('No raster timing')));
      });
    });

    group('vmConnected setter', () {
      testWidgets('VM-sourced raster_dominance cleared on disconnect', (
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
          rasterDominantData(
            rasterUs: 25000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
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
          'Structural pattern only — no raster-dominant frames observed',
        );
      });

      testWidgets(
        'after disconnect, next scanTree only produces structural issues',
        (tester) async {
          detector.vmConnected = true;
          detector.processTimelineData(
            rasterDominantData(
              rasterUs: 25000,
              buildUs: 5000,
              layoutUs: 3000,
              paintUs: 2000,
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

      /// Feeds [rasterUs] frames (UI 1 ms each) at 60 Hz from [startUs].
      void feed(List<int> rasterUs, {int startUs = 0, int spacingUs = 16667}) {
        for (var i = 0; i < rasterUs.length; i++) {
          final vsync = startUs + i * spacingUs;
          detector.processFrame(
            _frame(
              uiUs: 1000,
              rasterUs: rasterUs[i],
              vsyncStartUs: vsync,
              rasterFinishUs: vsync + rasterUs[i],
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
        feed([12000, 10000, 14000]);
        final issue = raster(await scan(tester));

        expect(issue, isNotNull);
        expect(issue!.confidence, IssueConfidence.likely);
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.observationSource, ObservationSource.frameTiming);
        expect(issue.title, 'Raster Dominance: 12.0× UI time');
        expect(
          issue.confidenceReason,
          'Per-frame FrameTiming raster vs UI durations',
        );
        expect(issue.detail, contains('3 of 3 frames since the last scan'));
        expect(issue.detail, contains('worst raster 14.0ms'));
        expect(issue.extraTraceArgs!.keys.toSet(), {
          'source',
          'dominantFrameCount',
          'windowFrameCount',
          'worstFrameRasterUs',
          'medianRatio',
          'lifecyclePhase',
        });
        expect(issue.extraTraceArgs!['source'], 'frame_timing');
        expect(issue.extraTraceArgs!['dominantFrameCount'], '3');
        expect(issue.extraTraceArgs!['windowFrameCount'], '3');
        expect(issue.extraTraceArgs!['worstFrameRasterUs'], '14000');
        expect(issue.extraTraceArgs!['medianRatio'], '12.00');
        expect(issue.extraTraceArgs!['lifecyclePhase'], 'steady');
        // Last qualifying frame: vsync 2 × 16667 + raster 14000.
        expect(issue.dedupIdentityMicros, 2 * 16667 + 14000);
        expect(
          detector.issues.where((i) => i.stableId == 'raster_dominance'),
          hasLength(1),
        );
      });

      testWidgets('2 dominant frames → none', (tester) async {
        feed([12000, 12000]);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('3 dominant frames 2 s apart → none', (tester) async {
        feed([12000, 12000, 12000], spacingUs: 2000000);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('3 inside one second plus 1 outside → emits, 3 qualify', (
        tester,
      ) async {
        feed([12000], startUs: 0);
        feed([12000, 12000, 12000], startUs: 3000000);
        final issue = raster(await scan(tester));

        expect(issue, isNotNull);
        expect(issue!.detail, contains('4 of 4 frames'));
        expect(issue.detail, contains('3 within one second'));
        expect(issue.extraTraceArgs!['dominantFrameCount'], '4');
      });

      testWidgets('non-monotonic vsync timestamps are ordered before the '
          'span check', (tester) async {
        for (final vsync in [500000, 0, 200000]) {
          detector.processFrame(
            _frame(uiUs: 1000, rasterUs: 12000, vsyncStartUs: vsync),
          );
        }
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('frames without timestamps count as one span', (
        tester,
      ) async {
        for (var i = 0; i < 3; i++) {
          detector.processFrame(_frame(uiUs: 1000, rasterUs: 12000));
        }
        final issue = raster(await scan(tester));
        expect(issue, isNotNull);
        expect(issue!.dedupIdentityMicros, isNull);
      });

      testWidgets('a route epoch drops the dominant frames seen before it', (
        tester,
      ) async {
        feed([12000, 12000]);
        detector.markRouteEpoch();
        feed([12000], startUs: 2 * 16667);
        expect(raster(await scan(tester)), isNull);

        // Three on the new route emit.
        feed([12000, 12000, 12000], startUs: 100000);
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
        feed([12000, 12000, 12000]);
        final issue = raster(await scan(tester))!;
        route = '/settings';
        expect(issue.sourceRoute, '/feed');
        expect(raster(detector.issues)!.sourceRoute, '/feed');
      });

      testWidgets('3 frames with raster above the frame budget → critical', (
        tester,
      ) async {
        feed([20000, 21000, 22000]);
        final issue = raster(await scan(tester));
        expect(issue!.severity, IssueSeverity.critical);
      });

      testWidgets('2 of 3 frames above budget → warning', (tester) async {
        feed([20000, 21000, 12000]);
        final issue = raster(await scan(tester));
        expect(issue!.severity, IssueSeverity.warning);
      });

      testWidgets('6 ms raster vs 1 ms UI stays under the 8000us floor', (
        tester,
      ) async {
        feed([6000, 6000, 6000, 6000]);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('updateFrameBudget lowers the floor; reset restores it', (
        tester,
      ) async {
        detector.updateFrameBudget(8333);
        expect(detector.effectiveMaxFrameRasterFloorUs, 4166);
        feed([5000, 5000, 5000]);
        expect(raster(await scan(tester)), isNotNull);

        detector.resetFrameBudget();
        feed([5000, 5000, 5000]);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('frames with zero UI or zero raster are skipped', (
        tester,
      ) async {
        for (var i = 0; i < 3; i++) {
          detector.processFrame(_frame(uiUs: 0, rasterUs: 12000));
          detector.processFrame(_frame(uiUs: 1000, rasterUs: 0));
        }
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('frames inside the startup window are ignored', (
        tester,
      ) async {
        ageUs = 1000000; // 1 s after Dart entry, inside the 5 s window.
        feed([12000, 12000, 12000]);
        expect(raster(await scan(tester)), isNull);

        ageUs = 10000000; // 10 s after Dart entry.
        feed([12000, 12000, 12000]);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('VM timeline polls inside the startup window are ignored', (
        tester,
      ) async {
        detector.vmConnected = true;
        ageUs = 1000000;
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 25000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
          ),
        );
        expect(raster(await scan(tester)), isNull);

        ageUs = 10000000;
        detector.processTimelineData(
          rasterDominantData(
            rasterUs: 25000,
            buildUs: 5000,
            layoutUs: 3000,
            paintUs: 2000,
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
        feed([12000, 12000, 12000]);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('frame state clears after each scan', (tester) async {
        feed([12000, 12000, 12000]);
        expect(raster(await scan(tester)), isNotNull);
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('VM and frame legs → one confirmed issue, corroborated', (
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
        feed([12000, 12000, 12000]);
        final issues = await scan(tester);

        final rasterIssues = issues
            .where((i) => i.stableId == 'raster_dominance')
            .toList();
        expect(rasterIssues, hasLength(1));
        expect(rasterIssues.single.confidence, IssueConfidence.confirmed);
        expect(
          rasterIssues.single.observationSource,
          ObservationSource.vmTimeline,
        );
        expect(
          rasterIssues.single.confidenceReason,
          contains('corroborated by 3 raster-dominant frames'),
        );
      });

      testWidgets('VM disconnect keeps the frame-leg issue and likely nodes', (
        tester,
      ) async {
        detector.vmConnected = true;
        feed([12000, 12000, 12000]);
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

      testWidgets('VM disconnect after a corroborated scan swaps in the '
          'frame-leg issue', (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(rasterDominantData(rasterUs: 25000));
        feed([12000, 12000, 12000]);
        await scan(tester, const _OpacityDeepTree());
        expect(raster(detector.issues)!.confidence, IssueConfidence.confirmed);

        detector.vmConnected = false;

        final rasterIssues = detector.issues
            .where((i) => i.stableId == 'raster_dominance')
            .toList();
        expect(rasterIssues, hasLength(1));
        expect(rasterIssues.single.confidence, IssueConfidence.likely);
        expect(
          rasterIssues.single.observationSource,
          ObservationSource.frameTiming,
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
        detector.processTimelineData(rasterDominantData(rasterUs: 25000));
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
        feed([12000, 12000, 12000]);
        final issues = await scan(tester, const _OpacityDeepTree());
        final nodes = issues.firstWhere(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(nodes.confidence, IssueConfidence.likely);
        expect(
          nodes.confidenceReason,
          'Raster-dominant frames + structural render node scan',
        );
        expect(nodes.detail, isNot(contains('No raster timing')));
      });

      testWidgets('disabled detector ignores frames', (tester) async {
        detector.isEnabled = false;
        feed([12000, 12000, 12000]);
        detector.isEnabled = true;
        expect(raster(await scan(tester)), isNull);
      });

      testWidgets('rasterMultiplierThreshold applies per frame', (
        tester,
      ) async {
        detector = GpuPressureDetector(
          rasterMultiplierThreshold: 3.0,
          maxFrameRasterFloorUs: 2000,
          appStartMonotonicUsForTest: () => Timeline.now - ageUs,
        );
        // Ratio 2.5 with UI 1 ms: below 3.0.
        feed([2500, 2500, 2500]);
        expect(raster(await scan(tester)), isNull);
        // Ratio 3.5: above 3.0.
        feed([3500, 3500, 3500]);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('minRasterDominantFrames applies', (tester) async {
        detector = GpuPressureDetector(
          minRasterDominantFrames: 5,
          appStartMonotonicUsForTest: () => Timeline.now - ageUs,
        );
        feed([12000, 12000, 12000, 12000]);
        expect(raster(await scan(tester)), isNull);
        feed([12000, 12000, 12000, 12000, 12000]);
        expect(raster(await scan(tester)), isNotNull);
      });

      testWidgets('100 dominant frames: ring keeps 64, count reports 100', (
        tester,
      ) async {
        for (var i = 0; i < 100; i++) {
          detector.processFrame(_frame(uiUs: 1000, rasterUs: 12000));
        }
        final issue = raster(await scan(tester));
        expect(issue!.extraTraceArgs!['dominantFrameCount'], '100');
        expect(issue.detail, contains('64 within one second'));
      });

      testWidgets('dispose clears frame state', (tester) async {
        feed([12000, 12000, 12000]);
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
      // UI = 5000+3000+2000 = 10000; Raster 35000; ratio = 3.5 > 3.0 → warning
      detector.processTimelineData(rasterDominantData(rasterUs: 35000));
      await tester.pumpWidget(const _GpuTestApp());
      detector.scanTree(tester.element(find.byType(_GpuTestApp)));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    testWidgets('custom threshold below ratio does not fire', (tester) async {
      detector = GpuPressureDetector(rasterMultiplierThreshold: 3.0);
      detector.vmConnected = true;
      // UI = 10000; Raster 25000; ratio = 2.5 < 3.0 → no issue
      detector.processTimelineData(rasterDominantData(rasterUs: 25000));
      await tester.pumpWidget(const _GpuTestApp());
      detector.scanTree(tester.element(find.byType(_GpuTestApp)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('custom threshold critical at 2x multiplier', (tester) async {
      detector = GpuPressureDetector(rasterMultiplierThreshold: 3.0);
      detector.vmConnected = true;
      // UI = 10000; Raster 70000; ratio = 7.0 > 6.0 (3.0*2) → critical
      detector.processTimelineData(rasterDominantData(rasterUs: 70000));
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
  const _BackdropFilterTree({required this.sigma});
  final double sigma;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
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
