// Hermetic reproducer for `RepaintDetector`.
//
// Drives the detector at all three emission paths:
//   VM aggregate (`excessive_repaint`) — feeds N PAINT events through
//     `TimelineParser.parse()` into `processTimelineData`, advances a fake
//     clock past the 1s window so the count stages, then triggers
//     `_evaluate` via `scanAndIssues`. Pins the strict-greater rate gate
//     (`> paintFrequencyThreshold`, default 30) and 2× critical
//     escalation (`> 60`).
//   Per-widget debug (`repaint_debug_<typeName>`) — supplies a
//     `DebugSnapshot` with `paintCounts` keyed by widget type. Pins the
//     residual-rate gate (`>= threshold`) on a triad: just-below /
//     boundary / 2× critical.
//   Aggregate debug (`excessive_repaint_debug`) — supplies a snapshot with
//     empty `paintCounts` but non-zero `totalPaintCount` while VM is
//     disconnected, exercising the residual-aggregate fallback path. Same
//     triad shape.
//
// Gate B (animation-owned suppression) — stages a VM count that would
// otherwise fire `excessive_repaint`, plus a per-widget snapshot where
// every paint is fully owned by an animation driver. Asserts the issues
// list is empty (broad assertion — the gate must suppress every emission
// path, not just the per-widget one).
//
// Reconnect-flush — disconnects then reconnects VM and asserts prior
// issues are cleared on the first post-reconnect evaluate (cold-init
// `vmConnected=false → true` transition stages `_pendingVmWindowCount=0`,
// causing the next `_evaluate` to clear and re-emit nothing).
//
// Highlights — pins per-type emission count and `_maxHighlightsPerType=3`
// cap by mounting 5 instances of one type and asserting only 3
// highlights are emitted.
//
// `_vmConnected` defaults to false; setUp explicitly sets `true` so VM-
// backed tests aren't silently routed into structural-only fallback.
// `fakeNow` is injected via `clock:` constructor callback; advancing it
// before each `processTimelineData` call closes the 1s window in a
// single call (no helper needed beyond the inline pattern).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '_helpers/structural_reproducer_harness.dart';
import '_helpers/vm_reproducer_harness.dart';

void main() {
  group('RepaintDetector reproducer', () {
    late RepaintDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = RepaintDetector(clock: () => fakeNow);
      // Cold-init false → true stages a sentinel `_pendingVmWindowCount=0`
      // that a subsequent `processTimelineData` overwrites.
      detector.vmConnected = true;
    });

    // -- Helpers ----------------------------------------------------------

    List<TimelineEvent> paintEvents(int n) => List.generate(
          n,
          (i) => buildEvent(
            name: 'PAINT',
            ph: 'X',
            dur: 100,
            ts: 1000 + i * 100,
          ),
        );

    /// PAINT events carrying `dirty count` enrichment in `args`.
    ///
    /// Flutter writes timeline args as `Map<String, String>`, so numeric
    /// values arrive string-encoded. `TimelineParser._parseIntArg` parses
    /// them back into int. Each event contributes [perEventDirty] to the
    /// detector's `_pendingEnrichedDirtyTotal` accumulator.
    List<TimelineEvent> paintEventsWithDirty(int n, {int perEventDirty = 1}) =>
        List.generate(
          n,
          (i) => buildEvent(
            name: 'PAINT',
            ph: 'X',
            dur: 100,
            ts: 1000 + i * 100,
            args: {'dirty count': '$perEventDirty'},
          ),
        );

    ParsedShape paintShape(int n) => (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: n,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: n,
        );

    /// Stage a VM window with [paintCount] paint events. Advances the fake
    /// clock past the 1s threshold first so the call stages atomically.
    void primeVmWindow(int paintCount) {
      fakeNow = fakeNow.add(const Duration(milliseconds: 1100));
      final parsed = parseAndAssertShape(
        paintEvents(paintCount),
        paintShape(paintCount),
      );
      detector.processTimelineData(parsed);
    }

    DebugSnapshot perWidgetSnapshot({
      required String typeName,
      required int count,
      Duration elapsed = const Duration(seconds: 1),
      int ownedCount = 0,
    }) {
      return DebugSnapshot(
        rebuildCounts: const {},
        totalPaintCount: count,
        paintCounts: {typeName: count},
        animationOwnedPaintCounts:
            ownedCount > 0 ? {typeName: ownedCount} : const {},
        totalAnimationOwnedPaintCount: ownedCount,
        elapsed: elapsed,
      );
    }

    DebugSnapshot aggregateSnapshot({
      required int totalPaintCount,
      Duration elapsed = const Duration(seconds: 1),
      int ownedTotal = 0,
    }) {
      return DebugSnapshot(
        rebuildCounts: const {},
        totalPaintCount: totalPaintCount,
        totalAnimationOwnedPaintCount: ownedTotal,
        elapsed: elapsed,
      );
    }

    // -- Group A: VM aggregate excessive_repaint triad --------------------

    group('excessive_repaint VM triad (strict > 30)', () {
      testWidgets('paintCount = 30 (boundary): no fire', (tester) async {
        primeVmWindow(30);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });

      testWidgets('paintCount = 31: warning', (tester) async {
        primeVmWindow(31);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('excessive_repaint'));
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.confirmed);
        expect(issue.observationSource, ObservationSource.vmTimeline);
      });

      testWidgets('paintCount = 61 (> 2× threshold): critical', (tester) async {
        primeVmWindow(61);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('excessive_repaint'));
        expect(issue.severity, IssueSeverity.critical);
      });

      testWidgets(
          'enriched dirty-count surfaces in detail (parser arg path exercised)',
          (tester) async {
        // Each PAINT event carries `args: {'dirty count': '5'}`. Parser
        // string-decodes via `_parseIntArg`; detector accumulates
        // `_pendingEnrichedDirtyTotal` and stages atomically with the
        // window count. Without this fixture the enrichment branch
        // (`event.dirtyCount != null`) is never entered.
        fakeNow = fakeNow.add(const Duration(milliseconds: 1100));
        final events = paintEventsWithDirty(31, perEventDirty: 5);
        final parsed = parseAndAssertShape(events, paintShape(31));
        // Sanity-check the parser actually populated dirtyCount on each
        // phase event (detector reads `event.dirtyCount` directly).
        expect(
          parsed.phaseEvents.every((e) => e.dirtyCount == 5),
          isTrue,
          reason: 'TimelineParser must decode `dirty count` arg into '
              'PhaseEvent.dirtyCount; mismatch = arg-name typo or '
              'string-int parse regression.',
        );
        detector.processTimelineData(parsed);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasStableId('excessive_repaint'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'excessive_repaint');
        // 31 events × 5 = 155 enriched dirty RenderObjects total.
        expect(issue.detail, contains('155 dirty RenderObjects'));
        expect(issue.detail, contains('timeline enrichment'));
      });

      testWidgets('exact 1000ms elapsed: window stages (gate is `>=` not `>`)',
          (tester) async {
        // Pins `if (now.difference(_windowStart).inMilliseconds >= 1000)`.
        // A regression flipping to strict `>` would only fail at exactly
        // 1000ms; reproducer's 1100ms helper would still pass.
        fakeNow = fakeNow.add(const Duration(milliseconds: 1000));
        final parsed = parseAndAssertShape(paintEvents(31), paintShape(31));
        detector.processTimelineData(parsed);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasStableId('excessive_repaint'));
      });
    });

    // -- Group A': aggregate debug excessive_repaint_debug triad ----------

    group('excessive_repaint_debug aggregate triad (>= 30)', () {
      testWidgets('rate = 29 (just-below): no fire', (tester) async {
        // Disconnect VM so the aggregate path is reachable (per-widget
        // path requires non-empty paintCounts; aggregate path requires
        // hasFreshDebug but NOT hasFreshVm).
        detector.vmConnected = false;
        detector.updateDebugSnapshot(aggregateSnapshot(totalPaintCount: 29));
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });

      testWidgets('rate = 30 (boundary): warning', (tester) async {
        detector.vmConnected = false;
        detector.updateDebugSnapshot(aggregateSnapshot(totalPaintCount: 30));
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('excessive_repaint_debug'));
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.likely);
      });

      testWidgets('rate = 61 (> 2× threshold): critical', (tester) async {
        detector.vmConnected = false;
        detector.updateDebugSnapshot(aggregateSnapshot(totalPaintCount: 61));
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('excessive_repaint_debug'));
        expect(issue.severity, IssueSeverity.critical);
      });
    });

    // -- Group B: per-widget repaint_debug_<Type> triad -------------------

    group('repaint_debug_<Type> per-widget triad (rate >= 30)', () {
      testWidgets('rate = 29 (just-below): no fire', (tester) async {
        detector.updateDebugSnapshot(
          perWidgetSnapshot(typeName: 'MyWidget', count: 29),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });

      testWidgets('rate = 30 (boundary): warning', (tester) async {
        detector.updateDebugSnapshot(
          perWidgetSnapshot(typeName: 'MyWidget', count: 30),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('repaint_debug_MyWidget'));
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.confirmed);
        expect(issue.observationSource, ObservationSource.debugCallback);
      });

      testWidgets('rate = 61 (> 2× threshold): critical', (tester) async {
        detector.updateDebugSnapshot(
          perWidgetSnapshot(typeName: 'MyWidget', count: 61),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('repaint_debug_MyWidget'));
        expect(issue.severity, IssueSeverity.critical);
      });
    });

    // -- Group C: Gate B (all paints animation-owned) suppresses ALL paths

    group('Gate B animation-owned suppression', () {
      testWidgets(
          'all paints owned + VM count > threshold: issues empty (broad)',
          (tester) async {
        // Stage a VM count that would normally fire excessive_repaint AND
        // a per-widget snapshot where every paint is owned. Gate B must
        // suppress the VM aggregate fallback so the issues list stays
        // empty across all three emission paths.
        primeVmWindow(61);
        detector.updateDebugSnapshot(
          perWidgetSnapshot(typeName: 'Spinner', count: 50, ownedCount: 50),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        // Broad assertion — the gate must mask the VM aggregate AND the
        // per-widget AND the aggregate-debug paths simultaneously.
        expect(issues, isEmpty);
      });

      testWidgets(
          'partial ownership (residual > 0): per-widget fires on residual',
          (tester) async {
        // Subset relation: ownedCount < total. Residual = 50 - 20 = 30.
        // Rate = 30/sec → boundary fires warning on the residual.
        detector.updateDebugSnapshot(
          perWidgetSnapshot(typeName: 'MyWidget', count: 50, ownedCount: 20),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasStableId('repaint_debug_MyWidget'));
      });

      testWidgets(
          'mixed ownership: one type fully owned, another unowned with '
          'sub-threshold residual → Gate B AND-semantics: VM aggregate fires',
          (tester) async {
        // Two types: Spinner fully owned (residual=0, skipped), Chart
        // unowned but residual rate (20/sec) below the per-widget gate
        // (30). Per-widget produces no issues. Gate B's
        // `_allPaintsAnimationOwned` walks both: Spinner ok, Chart
        // owned=0 < total=20 → returns false → VM aggregate runs.
        //
        // A regression flipping the gate from "all owned" (AND) to "any
        // owned" (OR) would short-circuit on Spinner and incorrectly
        // suppress the VM fallback. Single-type Gate B fixture cannot
        // distinguish AND from OR.
        primeVmWindow(31);
        detector.updateDebugSnapshot(
          DebugSnapshot(
            rebuildCounts: const {},
            totalPaintCount: 70,
            paintCounts: const {'Spinner': 50, 'Chart': 20},
            animationOwnedPaintCounts: const {'Spinner': 50},
            totalAnimationOwnedPaintCount: 50,
            elapsed: const Duration(seconds: 1),
          ),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('excessive_repaint'));
        expect(issue.severity, IssueSeverity.warning);
      });
    });

    // -- Group E: Reconnect-flush -----------------------------------------

    group('VM reconnect flush', () {
      testWidgets(
          'disconnect → reconnect clears prior excessive_repaint on next scan',
          (tester) async {
        // Step 1: prime + scan → fires excessive_repaint warning.
        primeVmWindow(31);
        final firstIssues =
            await scanAndIssues(tester, detector, const SizedBox());
        expect(firstIssues, hasStableId('excessive_repaint'));

        // Step 2: disconnect (clears VM staging, _issues unaffected).
        detector.vmConnected = false;
        // Step 3: reconnect — wasConnected=false → stages _pending=0.
        detector.vmConnected = true;

        // Step 4: scan with NO new VM events. Reconnect-staged 0 makes
        // hasFreshVm=true so _issues.clear() runs; vmWindowCount=0 means
        // _evaluateVmData is not invoked → issues list ends up empty.
        final secondIssues =
            await scanAndIssues(tester, detector, const SizedBox());
        expect(secondIssues, isEmpty);
      });
    });

    // -- Group F: highlights (severity match + cap = 3) -------------------

    group('highlights', () {
      testWidgets('severity matches issue severity (warning)', (tester) async {
        detector.updateDebugSnapshot(
          perWidgetSnapshot(typeName: '_PaintLeaf', count: 30),
        );
        final issues = await scanAndIssues(
          tester,
          detector,
          const _PaintTree(leafCount: 1),
        );
        expect(issues, hasLength(1));
        expect(issues, hasStableId('repaint_debug__PaintLeaf'));
        final highlight = detector.highlights.firstWhere(
          (h) => h.widgetName == '_PaintLeaf',
        );
        expect(highlight.severity, IssueSeverity.warning);
      });

      testWidgets('5 instances at hot rate emit only 3 highlights (cap)',
          (tester) async {
        // Rate 30/sec → _hotTypes['_PaintLeaf'] = 30.0. Tree has 5
        // _PaintLeaf elements; checkElement adds highlights up to
        // _maxHighlightsPerType=3 then skips the rest.
        detector.updateDebugSnapshot(
          perWidgetSnapshot(typeName: '_PaintLeaf', count: 30),
        );
        await scanAndIssues(
          tester,
          detector,
          const _PaintTree(leafCount: 5),
        );
        final leafHighlights = detector.highlights
            .where((h) => h.widgetName == '_PaintLeaf')
            .toList();
        expect(leafHighlights.length, 3);
      });
    });

    // -- Negative controls ------------------------------------------------

    group('negative controls', () {
      testWidgets('disabled detector does not stage VM data', (tester) async {
        detector.isEnabled = false;
        fakeNow = fakeNow.add(const Duration(milliseconds: 1100));
        final parsed = parseAndAssertShape(paintEvents(100), paintShape(100));
        detector.processTimelineData(parsed);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });

      testWidgets('empty events + plain tree emits nothing', (tester) async {
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });
    });
  });
}

// -- Test fixtures -----------------------------------------------------

class _PaintTree extends StatelessWidget {
  const _PaintTree({required this.leafCount});
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        leafCount,
        (i) => _PaintLeaf(key: ValueKey(i)),
      ),
    );
  }
}

class _PaintLeaf extends StatelessWidget {
  const _PaintLeaf({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}
