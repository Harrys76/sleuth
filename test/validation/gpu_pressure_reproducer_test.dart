// Hermetic reproducer for `GpuPressureDetector`.
//
// Drives the detector at all three legs:
//   Frame leg — feeds per-frame `FrameStats` through `processFrame`. A
//     frame counts when its raster time exceeds its own budget (strict),
//     `maxFrameRasterFloorUs` (strict) and 2.0 × its UI time (strict).
//     Pins the warning at `minRasterDominantFrames` (3) such frames inside
//     one second and critical at `criticalRasterDominantFrames` (10).
//     Emits `likely` with `ObservationSource.frameTiming`, VM or not.
//   VM leg — feeds raster + UI events through `TimelineParser.parse()` into
//     `processTimelineData`. With no frames since the last scan it emits on
//     its own (`confirmed`, `ObservationSource.vmTimeline`) when the worst
//     raster frame exceeds the frame budget (strict) and 2.0 × the batch's
//     UI total (strict); critical above twice the budget. A batch without
//     UI work is ignored.
//   Structural leg — pumps widget trees that produce the 5 RenderObject
//     types the detector flags (`RenderOpacity`, `RenderClipPath`,
//     `RenderBackdropFilter`, `RenderShaderMask`, `ColorFiltered` widget)
//     and asserts the subtree-size gate (`> 5` strict). Also pins
//     RenderOpacity opacity-value short-circuit (0.0 / 1.0 → suppressed)
//     and BackdropFilter sigma 3-band (≤ 2.0 suppressed; (2.0, 10.0]
//     warning; > 10.0 critical highlight severity).
//
// Confidence correlation: `expensive_gpu_nodes` confidence is `likely`
// when either raster leg qualified; `possible` otherwise.
//
// VM disconnect: the setter clears the held VM timing, removes the
// VM-sourced `raster_dominance`, keeps frame-sourced issues at `likely`,
// and downgrades `expensive_gpu_nodes` to `possible` only when no
// frame-sourced `raster_dominance` remains.
//
// `_vmConnected` defaults to false; setUp explicitly sets `true` so VM-
// backed tests aren't silently routed into structural-only fallback.

import 'dart:developer' show Timeline;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' hide Stack, Timeline;

import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '_helpers/structural_reproducer_harness.dart';
import '_helpers/vm_reproducer_harness.dart';

void main() {
  group('GpuPressureDetector reproducer', () {
    late GpuPressureDetector detector;

    setUp(() {
      detector = GpuPressureDetector();
      // _vmConnected defaults to false; VM-backed paths require true.
      detector.vmConnected = true;
    });

    // -- Helpers ----------------------------------------------------------

    /// Build a UI + raster timeline-event batch with the given microsecond
    /// totals. Each list element is one `BUILD` / `LAYOUT` / `PAINT` /
    /// `Raster` event of the given duration.
    List<TimelineEvent> uiAndRasterEvents({
      required int rasterUs,
      required int uiUs,
    }) {
      // Spread UI total across build / layout / paint so all three
      // contribute to `totalBuildScopeUs + totalFlushLayoutUs +
      // totalFlushPaintUs`. Equal split simplifies the math.
      final perPhaseUi = uiUs ~/ 3;
      final remainder = uiUs - (perPhaseUi * 3);
      return [
        buildEvent(name: 'BUILD', ph: 'X', dur: perPhaseUi, ts: 1000),
        buildEvent(name: 'LAYOUT', ph: 'X', dur: perPhaseUi, ts: 2000),
        buildEvent(
          name: 'PAINT',
          ph: 'X',
          dur: perPhaseUi + remainder,
          ts: 3000,
        ),
        buildEvent(name: 'Raster', ph: 'X', dur: rasterUs, ts: 4000),
      ];
    }

    const shapeUiAndRaster = (
      buildEventCount: 1,
      buildScopeCount: 1,
      layoutCount: 1,
      paintCount: 1,
      rasterCount: 1,
      shaderCount: 0,
      channelCount: 0,
      gcCount: 0,
      phaseEventCount: 4,
    );

    Future<List<PerformanceIssue>> primeVmThenScan(
      WidgetTester tester,
      Widget body, {
      int rasterUs = 0,
      int uiUs = 0,
    }) async {
      if (rasterUs > 0 || uiUs > 0) {
        final events = uiAndRasterEvents(rasterUs: rasterUs, uiUs: uiUs);
        final parsed = parseAndAssertShape(events, shapeUiAndRaster);
        detector.processTimelineData(parsed);
      }
      return scanAndIssues(tester, detector, body);
    }

    // Multi-frame raster batch: emit `rasterDurationsUs.length` raster
    // events at fixed timestamp spacing + one combined UI event sized
    // by `uiUs`. Used by the per-frame-floor + idle-batch tests where
    // a batch needs many raster scopes (one per vsync) to exercise the
    // MAX-of-frame gate semantics.
    Future<List<PerformanceIssue>> primeMultiFrameThenScan(
      WidgetTester tester,
      Widget body, {
      required List<int> rasterDurationsUs,
      required int uiUs,
    }) async {
      final perPhaseUi = uiUs ~/ 3;
      final remainder = uiUs - (perPhaseUi * 3);
      final events = <TimelineEvent>[
        buildEvent(name: 'BUILD', ph: 'X', dur: perPhaseUi, ts: 1000),
        buildEvent(name: 'LAYOUT', ph: 'X', dur: perPhaseUi, ts: 2000),
        buildEvent(
          name: 'PAINT',
          ph: 'X',
          dur: perPhaseUi + remainder,
          ts: 3000,
        ),
        for (var i = 0; i < rasterDurationsUs.length; i++)
          buildEvent(
            name: 'Raster',
            ph: 'X',
            dur: rasterDurationsUs[i],
            ts: 4000 + i * 100,
          ),
      ];
      final parsed = parseAndAssertShape(events, (
        buildEventCount: 1,
        buildScopeCount: 1,
        layoutCount: 1,
        paintCount: 1,
        rasterCount: rasterDurationsUs.length,
        shaderCount: 0,
        channelCount: 0,
        gcCount: 0,
        phaseEventCount: 3 + rasterDurationsUs.length,
      ));
      detector.processTimelineData(parsed);
      return scanAndIssues(tester, detector, body);
    }

    /// Detector 60 s past Dart entry, outside the startup window.
    GpuPressureDetector frameLegDetector() => GpuPressureDetector(
      appStartMonotonicUsForTest: () => Timeline.now - 60000000,
    );

    /// Feeds one frame per entry of [rasterUs] (UI 1 ms, 60 Hz spacing,
    /// [frameBudgetUs] budget) through `processFrame`.
    void feedFrames(
      List<int> rasterUs, {
      int uiUs = 1000,
      int frameBudgetUs = 16667,
    }) {
      for (var i = 0; i < rasterUs.length; i++) {
        final vsync = i * 16667;
        detector.processFrame(
          FrameStats(
            frameNumber: i,
            uiDuration: Duration(microseconds: uiUs),
            rasterDuration: Duration(microseconds: rasterUs[i]),
            timestamp: DateTime(2026),
            frameBudgetUs: frameBudgetUs,
            vsyncStartUs: vsync,
            rasterFinishUs: vsync + rasterUs[i],
          ),
        );
      }
    }

    // -- Frame leg: raster_dominance per-frame triad ----------------------

    group('raster_dominance frame-leg triad (3 and 10 frames in 1 s)', () {
      setUp(() {
        // Frame leg holds without a VM.
        detector = frameLegDetector()..vmConnected = false;
      });

      testWidgets('below: 2 dominant frames do NOT emit', (tester) async {
        feedFrames([20000, 20000]);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, lacksStableId('raster_dominance'));
      });

      testWidgets('at: 3 dominant frames emit likely warning', (tester) async {
        feedFrames([20000, 20000, 20000]);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        final issue = issues.firstWhere(
          (i) => i.stableId == 'raster_dominance',
        );
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.likely);
        expect(issue.observationSource, ObservationSource.frameTiming);
      });

      testWidgets('9 dominant frames stay a warning', (tester) async {
        feedFrames(List.filled(9, 20000));
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        final issue = issues.firstWhere(
          (i) => i.stableId == 'raster_dominance',
        );
        expect(issue.severity, IssueSeverity.warning);
      });

      testWidgets('above: 10 dominant frames emit critical', (tester) async {
        feedFrames(List.filled(10, 20000));
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        final issue = issues.firstWhere(
          (i) => i.stableId == 'raster_dominance',
        );
        expect(issue.severity, IssueSeverity.critical);
        expect(issue.confidence, IssueConfidence.likely);
      });

      testWidgets('per-frame ratio is strict-greater (exact 2.0 skipped)', (
        tester,
      ) async {
        feedFrames([20000, 20000, 20000], uiUs: 10000);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, lacksStableId('raster_dominance'));
      });

      testWidgets('per-frame budget is strict-greater (exact 16667us '
          'skipped)', (tester) async {
        feedFrames([16667, 16667, 16667]);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, lacksStableId('raster_dominance'));

        detector = frameLegDetector()..vmConnected = false;
        feedFrames([16668, 16668, 16668]);
        final above = await scanAndIssues(tester, detector, const SizedBox());
        expect(above, hasStableId('raster_dominance'));
      });

      testWidgets('per-frame floor is strict-greater (exact 8000us skipped) '
          'when the budget is below it', (tester) async {
        // A 4 ms budget leaves the 8000us floor as the binding gate.
        feedFrames([8000, 8000, 8000], frameBudgetUs: 4000);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, lacksStableId('raster_dominance'));

        detector = frameLegDetector()..vmConnected = false;
        feedFrames([8001, 8001, 8001], frameBudgetUs: 4000);
        final above = await scanAndIssues(tester, detector, const SizedBox());
        expect(above, hasStableId('raster_dominance'));
      });
    });

    // -- VM leg: raster_dominance ratio triad -----------------------------

    group('raster_dominance VM ratio triad (strict > 2.0)', () {
      testWidgets('ratio = 1.99 does NOT emit raster_dominance', (
        tester,
      ) async {
        // raster=19900, ui=10000 → ratio 1.99 (the worst frame misses the
        // 16667us budget; the ratio gate suppresses).
        final issues = await primeVmThenScan(
          tester,
          const SizedBox(),
          rasterUs: 19900,
          uiUs: 10000,
        );
        expect(issues, lacksStableId('raster_dominance'));
      });

      testWidgets('ratio = 2.0 does NOT emit (strict-greater)', (tester) async {
        // Strict gate is `ratio > rasterMultiplierThreshold` (2.0).
        final issues = await primeVmThenScan(
          tester,
          const SizedBox(),
          rasterUs: 20000,
          uiUs: 10000,
        );
        expect(issues, lacksStableId('raster_dominance'));
      });

      testWidgets('ratio just-above 2.0 emits raster_dominance (warning)', (
        tester,
      ) async {
        // raster=20100, ui=10000 → ratio 2.01, worst frame over budget.
        final issues = await primeVmThenScan(
          tester,
          const SizedBox(),
          rasterUs: 20100,
          uiUs: 10000,
        );
        expect(issues, hasStableId('raster_dominance'));
        final issue = issues.firstWhere(
          (i) => i.stableId == 'raster_dominance',
        );
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.confirmed);
      });

      testWidgets('worst frame above twice the budget escalates to critical '
          '(strict)', (tester) async {
        // raster=33334 = 2 × 16667, ui=8000 → warning.
        final at = await primeVmThenScan(
          tester,
          const SizedBox(),
          rasterUs: 33334,
          uiUs: 8000,
        );
        expect(
          at.firstWhere((i) => i.stableId == 'raster_dominance').severity,
          IssueSeverity.warning,
        );
        // raster=33335, ui=16000 → ratio 2.08, above twice the budget.
        final above = await primeVmThenScan(
          tester,
          const SizedBox(),
          rasterUs: 33335,
          uiUs: 16000,
        );
        expect(
          above.firstWhere((i) => i.stableId == 'raster_dominance').severity,
          IssueSeverity.critical,
        );
      });

      testWidgets('idle batch (60×1ms vsync raster + trivial UI) does NOT emit '
          '— per-frame floor suppresses despite huge aggregate ratio', (
        tester,
      ) async {
        // 60 vsync raster events × 1000us each = 60000us aggregate, UI
        // 500us → aggregate ratio 120. MAX-of-frame raster = 1000us is
        // within the budget → suppressed. Pins the idle-homepage bug class.
        final issues = await primeMultiFrameThenScan(
          tester,
          const SizedBox(),
          rasterDurationsUs: List.filled(60, 1000),
          uiUs: 500,
        );
        expect(issues, lacksStableId('raster_dominance'));
      });

      testWidgets('worst-frame budget strict-greater (just-below + exact + '
          'just-above 16667us)', (tester) async {
        // Just-below: max=16666, ratio 15 (huge) → suppressed.
        final below = await primeMultiFrameThenScan(
          tester,
          const SizedBox(),
          rasterDurationsUs: const [16666, 1000, 1000, 1000, 1000],
          uiUs: 1100,
        );
        expect(below, lacksStableId('raster_dominance'));
        // Exact budget: max=16667 → suppressed (strict `>`).
        detector.dispose();
        detector = GpuPressureDetector();
        detector.vmConnected = true;
        final exact = await primeMultiFrameThenScan(
          tester,
          const SizedBox(),
          rasterDurationsUs: const [16667, 1000, 1000, 1000],
          uiUs: 1100,
        );
        expect(exact, lacksStableId('raster_dominance'));
        // Just-above: max=16668, uiUs=8000 → MAX/uiUs = 2.08 > 2.0
        // → fires warning. Single-frame dominance semantic confirmed:
        // the worst raster scope must EXCEED the UI thread total by
        // > 2.0x, not just miss the budget.
        detector.dispose();
        detector = GpuPressureDetector();
        detector.vmConnected = true;
        final above = await primeMultiFrameThenScan(
          tester,
          const SizedBox(),
          rasterDurationsUs: const [16668, 1000, 1000, 1000],
          uiUs: 8000,
        );
        expect(above, hasStableId('raster_dominance'));
        final aboveIssue = above.firstWhere(
          (i) => i.stableId == 'raster_dominance',
        );
        expect(aboveIssue.severity, IssueSeverity.warning);
      });

      testWidgets('worst-frame budget follows updateFrameBudget, floored at '
          '8000us', (tester) async {
        Future<List<PerformanceIssue>> leg(
          int maxRasterUs, {
          int? budgetUs,
          bool reset = false,
        }) async {
          detector.dispose();
          detector = GpuPressureDetector();
          detector.vmConnected = true;
          if (budgetUs != null) detector.updateFrameBudget(budgetUs);
          if (reset) detector.resetFrameBudget();
          return primeMultiFrameThenScan(
            tester,
            const SizedBox(),
            rasterDurationsUs: [maxRasterUs, 1000, 1000, 1000],
            uiUs: 1100,
          );
        }

        // Default: the 60 Hz budget, 16667us.
        expect(GpuPressureDetector().effectiveMaxFrameRasterFloorUs, 16667);
        expect(await leg(16668), hasStableId('raster_dominance'));
        expect(await leg(16667), lacksStableId('raster_dominance'));
        // 120 Hz budget: 8333us.
        expect(
          await leg(8334, budgetUs: 8333),
          hasStableId('raster_dominance'),
        );
        expect(
          await leg(8333, budgetUs: 8333),
          lacksStableId('raster_dominance'),
        );
        // A budget below the 8000us floor leaves the floor binding.
        expect(
          await leg(8001, budgetUs: 4000),
          hasStableId('raster_dominance'),
        );
        expect(
          await leg(8000, budgetUs: 4000),
          lacksStableId('raster_dominance'),
        );
        // Reset restores the 60 Hz budget.
        expect(
          await leg(8334, budgetUs: 8333, reset: true),
          lacksStableId('raster_dominance'),
        );
      });

      testWidgets('one-spike + idle-tail does NOT inflate ratio '
          '(MAX-of-frame numerator regression)', (tester) async {
        // [16668, 1000×59] + uiUs=10000. Aggregate raster = 75668us
        // would have produced ratio 7.6 under an aggregate-numerator
        // implementation. Because the dominance numerator is MAX-of-frame
        // raster (16668us), MAX/uiUs = 1.67, which is below the > 2.0
        // ratio gate → no fire. Pins the root-cause idle-batch class even
        // when one frame misses the budget.
        final issues = await primeMultiFrameThenScan(
          tester,
          const SizedBox(),
          rasterDurationsUs: [16668, ...List.filled(59, 1000)],
          uiUs: 10000,
        );
        expect(issues, lacksStableId('raster_dominance'));
      });

      testWidgets('at 120 Hz a 12ms worst frame warns and a 17ms one is '
          'critical', (tester) async {
        // Budget 8333us: 12010us misses it (ratio 4.0 against 3ms of UI)
        // and stays under twice it; 17000us is above twice it.
        detector.updateFrameBudget(8333);
        final warn = await primeMultiFrameThenScan(
          tester,
          const SizedBox(),
          rasterDurationsUs: const [12010, 1000, 1000, 1000],
          uiUs: 3000,
        );
        expect(
          warn.firstWhere((i) => i.stableId == 'raster_dominance').severity,
          IssueSeverity.warning,
        );
        final critical = await primeMultiFrameThenScan(
          tester,
          const SizedBox(),
          rasterDurationsUs: const [17000, 1000, 1000, 1000],
          uiUs: 3000,
        );
        expect(
          critical.firstWhere((i) => i.stableId == 'raster_dominance').severity,
          IssueSeverity.critical,
        );
      });

      testWidgets(
        'raster events with totalUi == 0 does NOT emit (no UI to compare)',
        (tester) async {
          // A batch without UI work has no ratio to judge and is ignored,
          // however large its raster frame. Feed only raster events.
          final events = [
            buildEvent(name: 'Raster', ph: 'X', dur: 40000, ts: 1000),
          ];
          final parsed = parseAndAssertShape(events, (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 1,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 1,
          ));
          detector.processTimelineData(parsed);
          final issues = await scanAndIssues(
            tester,
            detector,
            const SizedBox(),
          );
          expect(issues, lacksStableId('raster_dominance'));
        },
      );
    });

    // -- Structural leg: RenderOpacity opacity-value × subtree matrix -----

    group('RenderOpacity opacity-value × subtree matrix', () {
      testWidgets(
        'opacity=0.0, subtree>>5: short-circuit suppresses (no fire)',
        (tester) async {
          final issues = await scanAndIssues(
            tester,
            detector,
            _OpacityTree(opacity: 0.0, leafCount: 10),
          );
          expect(issues, lacksStableId('expensive_gpu_nodes'));
        },
      );

      testWidgets('opacity=1.0, subtree>>5: no-op suppresses (no fire)', (
        tester,
      ) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          _OpacityTree(opacity: 1.0, leafCount: 10),
        );
        expect(issues, lacksStableId('expensive_gpu_nodes'));
      });

      testWidgets(
        'opacity=0.5, subtree small (<= 5): subtree gate suppresses',
        (tester) async {
          final issues = await scanAndIssues(
            tester,
            detector,
            _OpacityTree(opacity: 0.5, leafCount: 2),
          );
          expect(issues, lacksStableId('expensive_gpu_nodes'));
        },
      );

      testWidgets('opacity=0.5, subtree > 5: fires expensive_gpu_nodes', (
        tester,
      ) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          _OpacityTree(opacity: 0.5, leafCount: 10),
        );
        expect(issues, hasStableId('expensive_gpu_nodes'));
      });
    });

    // -- Structural leg: BackdropFilter sigma 3-band ----------------------

    group('BackdropFilter sigma 3-band (suppress / warning / critical)', () {
      testWidgets(
        'sigma = 2.0 (low-sigma threshold): suppressed even with deep subtree',
        (tester) async {
          final issues = await scanAndIssues(
            tester,
            detector,
            _BackdropFilterTree(sigma: 2.0, leafCount: 10),
          );
          // BackdropFilter is the only expense type in the fixture; with
          // sigma=2.0 the detector early-returns at line 135 before
          // adding to `_expensiveNodes`. No issue should fire at all.
          expect(issues, lacksStableId('expensive_gpu_nodes'));
        },
      );

      testWidgets(
        'sigma = 5.0 (mid-band) with subtree > 5: fires warning highlight',
        (tester) async {
          final issues = await scanAndIssues(
            tester,
            detector,
            _BackdropFilterTree(sigma: 5.0, leafCount: 10),
          );
          expect(issues, hasStableId('expensive_gpu_nodes'));
          // Detail string carries sigma annotation so a regression that
          // drops sigma plumbing is visible.
          expect(issues.first.detail, contains('σ=5.0'));
          // Highlight severity follows sigma; warning at this sigma.
          final highlight = detector.highlights.firstWhere(
            (h) => h.widgetName == 'RenderBackdropFilter',
          );
          expect(highlight.severity, IssueSeverity.warning);
        },
      );

      testWidgets(
        'sigma > 10.0 (high-sigma threshold): highlight severity = critical',
        (tester) async {
          final issues = await scanAndIssues(
            tester,
            detector,
            _BackdropFilterTree(sigma: 12.0, leafCount: 10),
          );
          expect(issues, hasStableId('expensive_gpu_nodes'));
          expect(issues.first.detail, contains('σ=12.0'));
          final highlight = detector.highlights.firstWhere(
            (h) => h.widgetName == 'RenderBackdropFilter',
          );
          expect(highlight.severity, IssueSeverity.critical);
        },
      );
    });

    // -- Structural leg: ClipPath / ShaderMask / ColorFiltered ------------

    group('Other expense types (subtree > 5)', () {
      testWidgets('ClipPath with deep subtree fires', (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          _ClipPathTree(leafCount: 10),
        );
        expect(issues, hasStableId('expensive_gpu_nodes'));
        expect(issues.first.detail, contains('RenderClipPath'));
      });

      testWidgets('ShaderMask with deep subtree fires', (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          _ShaderMaskTree(leafCount: 10),
        );
        expect(issues, hasStableId('expensive_gpu_nodes'));
        expect(issues.first.detail, contains('RenderShaderMask'));
      });

      testWidgets(
        'ColorFiltered (widget-level, no public RenderObject type) fires',
        (tester) async {
          final issues = await scanAndIssues(
            tester,
            detector,
            _ColorFilteredTree(leafCount: 10),
          );
          expect(issues, hasStableId('expensive_gpu_nodes'));
          expect(issues.first.detail, contains('RenderColorFiltered'));
        },
      );
    });

    // -- Structural leg: nested expense node accumulator ------------------

    group('nested expense nodes', () {
      testWidgets(
        'Opacity wrapping Opacity emits TWO entries in expensive_gpu_nodes detail',
        (tester) async {
          // Outer subtree includes the inner Opacity + its 10 leaves; inner
          // subtree has just its 10 leaves. Both qualify (> 5) so both
          // appear in _expensiveNodes.
          final issues = await scanAndIssues(
            tester,
            detector,
            _NestedOpacityTree(),
          );
          expect(issues, hasStableId('expensive_gpu_nodes'));
          // Both inner and outer Opacity contribute one node each. Detail
          // joins them with newlines, so two `RenderOpacity` mentions.
          final detail = issues.first.detail;
          final occurrences = 'RenderOpacity'.allMatches(detail).length;
          expect(
            occurrences,
            greaterThanOrEqualTo(2),
            reason:
                'detail should contain entries for both '
                'inner and outer RenderOpacity',
          );
        },
      );
    });

    // -- Confidence correlation matrix (3 sub-cases for `possible`) -------

    group('expensive_gpu_nodes confidence correlation', () {
      testWidgets('vmConnected=true + raster dominance + expense → likely', (
        tester,
      ) async {
        final issues = await primeVmThenScan(
          tester,
          _OpacityTree(opacity: 0.5, leafCount: 10),
          rasterUs: 24000, // ratio 3.0, worst frame over the 16667us budget
          uiUs: 8000,
        );
        final issue = issues.firstWhere(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(issue.confidence, IssueConfidence.likely);
        expect(
          issue.confidenceReason,
          'Raster-dominant frames and a structural render node scan',
        );
      });

      testWidgets('vmConnected=true + NO raster events + expense → possible', (
        tester,
      ) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          _OpacityTree(opacity: 0.5, leafCount: 10),
        );
        final issue = issues.firstWhere(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(issue.confidence, IssueConfidence.possible);
        expect(
          issue.confidenceReason,
          'Structural pattern only. Sleuth saw no raster-dominant frames',
        );
      });

      testWidgets('vmConnected=false + no frames + expense → possible + detail '
          '"Sleuth has not observed raster timing yet."', (tester) async {
        detector.vmConnected = false;
        final issues = await scanAndIssues(
          tester,
          detector,
          _OpacityTree(opacity: 0.5, leafCount: 10),
        );
        final issue = issues.firstWhere(
          (i) => i.stableId == 'expensive_gpu_nodes',
        );
        expect(issue.confidence, IssueConfidence.possible);
        expect(
          issue.confidenceReason,
          'Structural pattern only. Sleuth saw no raster-dominant frames',
        );
        expect(
          issue.detail,
          contains('Sleuth has not observed raster timing yet.'),
        );
      });

      testWidgets(
        'vmConnected=false + dominant frames + expense → likely (frame leg '
        'corroborates without a VM)',
        (tester) async {
          detector = frameLegDetector()..vmConnected = false;
          feedFrames([20000, 20000, 20000]);
          final issues = await scanAndIssues(
            tester,
            detector,
            _OpacityTree(opacity: 0.5, leafCount: 10),
          );
          final issue = issues.firstWhere(
            (i) => i.stableId == 'expensive_gpu_nodes',
          );
          expect(issue.confidence, IssueConfidence.likely);
          expect(
            issue.confidenceReason,
            'Raster-dominant frames and a structural render node scan',
          );
          expect(
            issue.detail,
            isNot(contains('has not observed raster timing')),
          );
        },
      );

      testWidgets(
        'vmConnected=true + raster events present + ratio ≤ 2.0 + expense'
        ' → possible (gate is raster dominance, not raster timing)',
        (tester) async {
          // The VM saw raster timing over the budget, but the ratio is
          // 1.5 ≤ 2.0, so there is no raster dominance. Confidence must be
          // `possible`, not `likely`. A regression that widens the gate
          // from raster dominance to mere raster timing would flip this
          // case to `likely`.
          final issues = await primeVmThenScan(
            tester,
            _OpacityTree(opacity: 0.5, leafCount: 10),
            rasterUs: 24000, // ratio 1.5 (below threshold), over budget
            uiUs: 16000,
          );
          expect(issues, lacksStableId('raster_dominance'));
          final issue = issues.firstWhere(
            (i) => i.stableId == 'expensive_gpu_nodes',
          );
          expect(issue.confidence, IssueConfidence.possible);
          expect(
            issue.confidenceReason,
            'Structural pattern only. Sleuth saw no raster-dominant frames',
          );
        },
      );
    });

    // -- VM-disconnect downgrade ------------------------------------------

    group('VM-disconnect downgrade', () {
      testWidgets(
        'VM-only evidence: vmConnected=false removes raster_dominance + '
        'downgrades expensive_gpu_nodes',
        (tester) async {
          // First scan: VM-backed, both issues fire at high confidence.
          final firstIssues = await primeVmThenScan(
            tester,
            _OpacityTree(opacity: 0.5, leafCount: 10),
            rasterUs: 24000, // ratio 3.0, over the 16667us budget
            uiUs: 8000,
          );
          expect(firstIssues, hasStableId('raster_dominance'));
          expect(firstIssues, hasStableId('expensive_gpu_nodes'));
          final preDowngrade = firstIssues.firstWhere(
            (i) => i.stableId == 'expensive_gpu_nodes',
          );
          expect(preDowngrade.confidence, IssueConfidence.likely);

          // Disconnect: setter mutates the issue list in-place.
          detector.vmConnected = false;
          expect(detector.issues, lacksStableId('raster_dominance'));
          final postDowngrade = detector.issues.firstWhere(
            (i) => i.stableId == 'expensive_gpu_nodes',
          );
          expect(postDowngrade.confidence, IssueConfidence.possible);
          expect(
            postDowngrade.confidenceReason,
            'Structural pattern only. Sleuth saw no raster-dominant frames',
          );
        },
      );

      testWidgets(
        'frame evidence: vmConnected=false keeps a likely raster_dominance '
        'and likely expensive_gpu_nodes',
        (tester) async {
          detector = frameLegDetector()..vmConnected = true;
          feedFrames([20000, 20000, 20000]);
          final firstIssues = await scanAndIssues(
            tester,
            detector,
            _OpacityTree(opacity: 0.5, leafCount: 10),
          );
          final before = firstIssues.firstWhere(
            (i) => i.stableId == 'raster_dominance',
          );
          expect(before.observationSource, ObservationSource.frameTiming);

          detector.vmConnected = false;

          final after = detector.issues.firstWhere(
            (i) => i.stableId == 'raster_dominance',
          );
          expect(after.confidence, IssueConfidence.likely);
          expect(after.observationSource, ObservationSource.frameTiming);
          final nodes = detector.issues.firstWhere(
            (i) => i.stableId == 'expensive_gpu_nodes',
          );
          expect(nodes.confidence, IssueConfidence.likely);
        },
      );
    });

    // -- Negative controls ------------------------------------------------

    group('negative controls', () {
      testWidgets(
        'disabled detector ignores VM data — no raster_dominance even with'
        ' large ratio',
        (tester) async {
          // `isEnabled = false` early-returns from `processTimelineData`,
          // so VM state stays zero and `raster_dominance` cannot fire.
          // Structural emission has no isEnabled guard in the detector —
          // the controller is responsible for skipping disabled detectors
          // in the unified walk in production. Test pins the VM-side
          // behaviour the detector controls directly.
          detector.isEnabled = false;
          final issues = await primeVmThenScan(
            tester,
            const SizedBox(),
            rasterUs: 40000, // would fire if enabled (ratio 5.0, over budget)
            uiUs: 8000,
          );
          expect(issues, lacksStableId('raster_dominance'));
        },
      );

      testWidgets('empty events + plain tree emit nothing', (tester) async {
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });
    });
  });
}

// -- Test fixture widget trees ------------------------------------------

class _OpacityTree extends StatelessWidget {
  const _OpacityTree({required this.opacity, required this.leafCount});
  final double opacity;
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Column(
        children: List.generate(
          leafCount,
          (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
        ),
      ),
    );
  }
}

class _BackdropFilterTree extends StatelessWidget {
  const _BackdropFilterTree({required this.sigma, required this.leafCount});
  final double sigma;
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    // BackdropFilter requires a Stack ancestor so the engine can sample
    // the layer behind it; without one, Flutter substitutes a non-blur
    // RenderObject and the detector's `is RenderBackdropFilter` check
    // never matches the sigma branch.
    return Stack(
      children: [
        BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: Column(
            children: List.generate(
              leafCount,
              (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
            ),
          ),
        ),
      ],
    );
  }
}

class _ClipPathTree extends StatelessWidget {
  const _ClipPathTree({required this.leafCount});
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: _SquareClipper(),
      child: Column(
        children: List.generate(
          leafCount,
          (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
        ),
      ),
    );
  }
}

class _SquareClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) => Path()..addRect(Offset.zero & size);
  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _ShaderMaskTree extends StatelessWidget {
  const _ShaderMaskTree({required this.leafCount});
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        colors: [Color(0xFF000000), Color(0xFFFFFFFF)],
      ).createShader(bounds),
      child: Column(
        children: List.generate(
          leafCount,
          (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
        ),
      ),
    );
  }
}

class _ColorFilteredTree extends StatelessWidget {
  const _ColorFilteredTree({required this.leafCount});
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(Color(0x80000000), BlendMode.srcATop),
      child: Column(
        children: List.generate(
          leafCount,
          (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
        ),
      ),
    );
  }
}

class _NestedOpacityTree extends StatelessWidget {
  const _NestedOpacityTree();

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.6,
      child: Opacity(
        opacity: 0.4,
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
