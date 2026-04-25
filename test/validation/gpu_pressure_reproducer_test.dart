// Hermetic reproducer for `GpuPressureDetector`.
//
// Drives the detector at both legs:
//   VM leg — feeds raster + UI events through `TimelineParser.parse()` into
//     `processTimelineData`. Pins `raster_dominance` ratio gate (strict
//     `> 2.0`), critical escalation (`> 4.0`), and the
//     `hasRasterTiming` precondition (`vmConnected && _lastUiUs > 0 &&
//     _lastRasterUs > 0`).
//   Structural leg — pumps widget trees that produce the 5 RenderObject
//     types the detector flags (`RenderOpacity`, `RenderClipPath`,
//     `RenderBackdropFilter`, `RenderShaderMask`, `ColorFiltered` widget)
//     and asserts the subtree-size gate (`> 5` strict). Also pins
//     RenderOpacity opacity-value short-circuit (0.0 / 1.0 → suppressed)
//     and BackdropFilter sigma 3-band (≤ 2.0 suppressed; (2.0, 10.0]
//     warning; > 10.0 critical highlight severity).
//
// Confidence correlation: `expensive_gpu_nodes` confidence is `likely`
// only when `hasRasterDominance` is true; `possible` in every other case
// (vmConnected=false, or vmConnected=true but no raster events).
//
// VM disconnect: setter clears `_lastRasterUs`/`_lastUiUs`, removes any
// `raster_dominance` issue, and downgrades surviving `expensive_gpu_nodes`
// to `possible` confidence.
//
// `_vmConnected` defaults to false; setUp explicitly sets `true` so VM-
// backed tests aren't silently routed into structural-only fallback.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' hide Stack;

import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
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
            name: 'PAINT', ph: 'X', dur: perPhaseUi + remainder, ts: 3000),
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

    // -- VM leg: raster_dominance ratio triad -----------------------------

    group('raster_dominance VM ratio triad (strict > 2.0)', () {
      testWidgets('ratio = 1.99 does NOT emit raster_dominance',
          (tester) async {
        // raster=1990, ui=1000 → ratio 1.99
        final issues = await primeVmThenScan(
          tester,
          const SizedBox(),
          rasterUs: 1990,
          uiUs: 1000,
        );
        expect(issues, lacksStableId('raster_dominance'));
      });

      testWidgets('ratio = 2.0 does NOT emit (strict-greater)', (tester) async {
        final issues = await primeVmThenScan(
          tester,
          const SizedBox(),
          rasterUs: 2001, // 2001/1000 still rounds to ratio 2.001 — see below
          uiUs: 1000,
        );
        // The strict gate is `ratio > rasterMultiplierThreshold` (2.0).
        // Build exact-2.0 case via raster=2000, ui=1000.
        // (Above primed ratio 2.001 would fire — separate test for that.)
        // Replace fixture to assert exact-boundary suppression:
        detector.dispose();
        detector = GpuPressureDetector();
        detector.vmConnected = true;
        final exact2Issues = await primeVmThenScan(
          tester,
          const SizedBox(),
          rasterUs: 2000,
          uiUs: 1000,
        );
        expect(exact2Issues, lacksStableId('raster_dominance'));
        // Suppress unused-variable warning for the priming call above.
        expect(issues, isNotNull);
      });

      testWidgets('ratio just-above 2.0 emits raster_dominance (warning)',
          (tester) async {
        // raster=2010, ui=1000 → ratio 2.01
        final issues = await primeVmThenScan(
          tester,
          const SizedBox(),
          rasterUs: 2010,
          uiUs: 1000,
        );
        expect(issues, hasStableId('raster_dominance'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'raster_dominance');
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.confirmed);
      });

      testWidgets('ratio > 4.0 (2× threshold) escalates to critical',
          (tester) async {
        // raster=4010, ui=1000 → ratio 4.01 → critical
        final issues = await primeVmThenScan(
          tester,
          const SizedBox(),
          rasterUs: 4010,
          uiUs: 1000,
        );
        expect(issues, hasStableId('raster_dominance'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'raster_dominance');
        expect(issue.severity, IssueSeverity.critical);
      });

      testWidgets(
          'raster events with totalUi == 0 does NOT emit (hasRasterTiming gate)',
          (tester) async {
        // The detector's hasRasterTiming check requires _lastUiUs > 0
        // independently of vmConnected and rasterUs. Feed only raster
        // events; UI denominator zero blocks emission even though raster
        // is large.
        final events = [
          buildEvent(name: 'Raster', ph: 'X', dur: 5000, ts: 1000),
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
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, lacksStableId('raster_dominance'));
      });
    });

    // -- Structural leg: RenderOpacity opacity-value × subtree matrix -----

    group('RenderOpacity opacity-value × subtree matrix', () {
      testWidgets('opacity=0.0, subtree>>5: short-circuit suppresses (no fire)',
          (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          _OpacityTree(opacity: 0.0, leafCount: 10),
        );
        expect(issues, lacksStableId('expensive_gpu_nodes'));
      });

      testWidgets('opacity=1.0, subtree>>5: no-op suppresses (no fire)',
          (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          _OpacityTree(opacity: 1.0, leafCount: 10),
        );
        expect(issues, lacksStableId('expensive_gpu_nodes'));
      });

      testWidgets('opacity=0.5, subtree small (<= 5): subtree gate suppresses',
          (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          _OpacityTree(opacity: 0.5, leafCount: 2),
        );
        expect(issues, lacksStableId('expensive_gpu_nodes'));
      });

      testWidgets('opacity=0.5, subtree > 5: fires expensive_gpu_nodes',
          (tester) async {
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
      });

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
        expect(
          issues.first.detail,
          contains('σ=5.0'),
        );
        // Highlight severity follows sigma; warning at this sigma.
        final highlight = detector.highlights
            .firstWhere((h) => h.widgetName == 'RenderBackdropFilter');
        expect(highlight.severity, IssueSeverity.warning);
      });

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
        final highlight = detector.highlights
            .firstWhere((h) => h.widgetName == 'RenderBackdropFilter');
        expect(highlight.severity, IssueSeverity.critical);
      });
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
      });
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
        expect(occurrences, greaterThanOrEqualTo(2),
            reason: 'detail should contain entries for both '
                'inner and outer RenderOpacity');
      });
    });

    // -- Confidence correlation matrix (3 sub-cases for `possible`) -------

    group('expensive_gpu_nodes confidence correlation', () {
      testWidgets('vmConnected=true + raster dominance + expense → likely',
          (tester) async {
        final issues = await primeVmThenScan(
          tester,
          _OpacityTree(opacity: 0.5, leafCount: 10),
          rasterUs: 3000, // ratio = 3.0 (raster_dominance fires)
          uiUs: 1000,
        );
        final issue =
            issues.firstWhere((i) => i.stableId == 'expensive_gpu_nodes');
        expect(issue.confidence, IssueConfidence.likely);
        expect(
          issue.confidenceReason,
          'Raster dominance timing + structural render node scan',
        );
      });

      testWidgets('vmConnected=true + NO raster events + expense → possible',
          (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          _OpacityTree(opacity: 0.5, leafCount: 10),
        );
        final issue =
            issues.firstWhere((i) => i.stableId == 'expensive_gpu_nodes');
        expect(issue.confidence, IssueConfidence.possible);
        expect(
          issue.confidenceReason,
          'Structural pattern only — connect VM for higher confidence',
        );
      });

      testWidgets(
          'vmConnected=false + expense → possible + detail "VM unavailable"',
          (tester) async {
        detector.vmConnected = false;
        final issues = await scanAndIssues(
          tester,
          detector,
          _OpacityTree(opacity: 0.5, leafCount: 10),
        );
        final issue =
            issues.firstWhere((i) => i.stableId == 'expensive_gpu_nodes');
        expect(issue.confidence, IssueConfidence.possible);
        expect(issue.detail, contains('VM unavailable'));
      });

      testWidgets(
          'vmConnected=true + raster events present + ratio ≤ 2.0 + expense'
          ' → possible (gate is hasRasterDominance, not hasRasterTiming)',
          (tester) async {
        // hasRasterTiming is true (vmConnected + ui>0 + raster>0) but
        // hasRasterDominance is false (ratio 1.5 ≤ 2.0). Confidence
        // must be `possible`, not `likely`. A regression that widens
        // the gate from `hasRasterDominance` to mere `hasRasterTiming`
        // would flip this case to `likely` — only this test catches it.
        final issues = await primeVmThenScan(
          tester,
          _OpacityTree(opacity: 0.5, leafCount: 10),
          rasterUs: 1500,
          uiUs: 1000,
        );
        expect(issues, lacksStableId('raster_dominance'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'expensive_gpu_nodes');
        expect(issue.confidence, IssueConfidence.possible);
        expect(
          issue.confidenceReason,
          'Structural pattern only — connect VM for higher confidence',
        );
      });
    });

    // -- VM-disconnect downgrade ------------------------------------------

    group('VM-disconnect downgrade', () {
      testWidgets(
          'setting vmConnected=false removes raster_dominance + downgrades expensive_gpu_nodes',
          (tester) async {
        // First scan: VM-backed, both issues fire at high confidence.
        final firstIssues = await primeVmThenScan(
          tester,
          _OpacityTree(opacity: 0.5, leafCount: 10),
          rasterUs: 3000,
          uiUs: 1000,
        );
        expect(firstIssues, hasStableId('raster_dominance'));
        expect(firstIssues, hasStableId('expensive_gpu_nodes'));
        final preDowngrade =
            firstIssues.firstWhere((i) => i.stableId == 'expensive_gpu_nodes');
        expect(preDowngrade.confidence, IssueConfidence.likely);

        // Disconnect: setter mutates the issue list in-place.
        detector.vmConnected = false;
        expect(detector.issues, lacksStableId('raster_dominance'));
        final postDowngrade = detector.issues
            .firstWhere((i) => i.stableId == 'expensive_gpu_nodes');
        expect(postDowngrade.confidence, IssueConfidence.possible);
        expect(
          postDowngrade.confidenceReason,
          'Structural pattern only — connect VM for higher confidence',
        );
      });
    });

    // -- Negative controls ------------------------------------------------

    group('negative controls', () {
      testWidgets(
          'disabled detector ignores VM data — no raster_dominance even with'
          ' large ratio', (tester) async {
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
          rasterUs: 5000,
          uiUs: 1000,
        );
        expect(issues, lacksStableId('raster_dominance'));
      });

      testWidgets('empty events + plain tree emit nothing', (tester) async {
        final issues = await scanAndIssues(
          tester,
          detector,
          const SizedBox(),
        );
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
