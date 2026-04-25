// Hermetic reproducer for `ShallowRebuildRiskDetector`.
//
// Drives the detector at three legs:
//   VM activity gate — `processTimelineData` consumes
//     `data.buildEventCount` only; `_lastBuildCount > 20` (strict) is the
//     gate the VM-backed branch checks before emitting.
//   Structural — `scanTree` flags `StatefulElement`s at depth ≤ 3 that
//     are NOT in the framework allowlist (Scaffold, Material, Navigator,
//     etc.).
//   DebugSnapshot — `updateDebugSnapshot(DebugSnapshot)` upgrades issue
//     confidence from `possible` to `likely` when the snapshot reports
//     a non-zero per-second rebuild rate for the top usage's widget
//     name. Consumed in `finalizeScan` → `_evaluate()`, so the snapshot
//     MUST be set BEFORE `scanAndIssues` is called.
//
// Three gate states (covered exhaustively):
//   1. vmConnected=true && buildCount > 20 + shallow Stateful → fires
//      VM-backed issue at `possible` (no DebugSnapshot) or `likely`
//      (with DebugSnapshot reporting rate > 0).
//   2. vmConnected=false + shallow Stateful → fires structural fallback
//      issue. Detail says "VM unavailable".
//   3. vmConnected=true && buildCount ≤ 20 + shallow Stateful → SILENT
//      no-fire ("VM connected but build count ≤ 20 — activity is low").
//      A regression that flips the gate to `>=` or removes the activity
//      check shows up here, not in (1) or (2).
//
// `_vmConnected` defaults to false; setUp sets `true` explicitly so the
// VM-backed-path tests aren't silently routed into the structural
// fallback in (2).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart' hide Stack;

import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/shallow_rebuild_risk_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '_helpers/structural_reproducer_harness.dart';
import '_helpers/vm_reproducer_harness.dart';

void main() {
  group('ShallowRebuildRiskDetector reproducer', () {
    late ShallowRebuildRiskDetector detector;

    setUp(() {
      detector = ShallowRebuildRiskDetector();
      // _vmConnected defaults to false; VM-backed paths require true.
      detector.vmConnected = true;
    });

    // Build N BUILD events so `buildEventCount` matches N exactly.
    List<TimelineEvent> buildEventBatch(int count) {
      return List.generate(
        count,
        (i) => buildEvent(
          name: 'BUILD',
          ph: 'X',
          dur: 1000,
          ts: 1000 + i,
        ),
      );
    }

    void primeVmBuildCount(int count) {
      final events = buildEventBatch(count);
      final parsed = parseAndAssertShape(events, (
        buildEventCount: count,
        buildScopeCount: count,
        layoutCount: 0,
        paintCount: 0,
        rasterCount: 0,
        shaderCount: 0,
        channelCount: 0,
        gcCount: 0,
        phaseEventCount: count,
      ));
      detector.processTimelineData(parsed);
    }

    // -- Gate state matrix (the four cells) -------------------------------

    group('three gate states (the silent State-4 case is the key pin)', () {
      testWidgets(
          'State 1: vmConnected=true, buildCount=20 → no fire (strict > 20)',
          (tester) async {
        primeVmBuildCount(20);
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth1(),
        );
        expect(issues, lacksStableId('shallow_rebuild_risk'));
      });

      testWidgets(
          'State 2: vmConnected=true, buildCount=21 → fires (warning, possible)',
          (tester) async {
        primeVmBuildCount(21);
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth1(),
        );
        expect(issues, hasStableId('shallow_rebuild_risk'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'shallow_rebuild_risk');
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.possible);
        expect(issue.observationSource, ObservationSource.vmTimeline);
      });

      testWidgets('State 3: vmConnected=false → fires structural fallback',
          (tester) async {
        detector.vmConnected = false;
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth1(),
        );
        expect(issues, hasStableId('shallow_rebuild_risk'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'shallow_rebuild_risk');
        expect(issue.observationSource, ObservationSource.structural);
        expect(issue.detail, contains('VM unavailable'));
      });

      testWidgets(
          'State 4 (silent): vmConnected=true, buildCount=15 → no fire '
          '(activity gate)', (tester) async {
        // Activity-low branch is comment-only at line 238 of the
        // detector (`else: VM connected but build count ≤ 20 — no
        // issue`). A regression that flips the gate to `>=` or removes
        // the activity check would silently start firing in this case
        // — only an explicit assertion catches it.
        primeVmBuildCount(15);
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth1(),
        );
        expect(issues, lacksStableId('shallow_rebuild_risk'));
      });
    });

    // -- Structural depth threshold ---------------------------------------

    group('structural depth threshold (default 3)', () {
      testWidgets('Stateful at depth 3 fires (boundary inclusive)',
          (tester) async {
        primeVmBuildCount(50);
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth3(),
        );
        expect(issues, hasStableId('shallow_rebuild_risk'));
      });

      testWidgets('Stateful at depth 4 does NOT fire (past depth threshold)',
          (tester) async {
        primeVmBuildCount(50);
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth4(),
        );
        expect(issues, lacksStableId('shallow_rebuild_risk'));
      });
    });

    // -- Framework allowlist negative -------------------------------------

    group('framework allowlist suppression', () {
      testWidgets(
          'allowlist-only Stateful (Navigator) at shallow depth → no fire',
          (tester) async {
        // Build a tree where the only shallow Stateful candidates are
        // framework allowlist names. Walker visits them but the
        // detector's allowlist filter excludes them, so `_usages`
        // stays empty and `_evaluate()` returns early at line 132.
        primeVmBuildCount(50);
        final issues = await scanAndIssues(
          tester,
          detector,
          // Navigator is in the allowlist; no other custom Stateful
          // widget at shallow depth.
          Navigator(
            onGenerateRoute: (settings) => PageRouteBuilder<void>(
                pageBuilder: (_, __, ___) => const SizedBox()),
          ),
        );
        expect(issues, lacksStableId('shallow_rebuild_risk'));
      });
    });

    // -- DebugSnapshot confidence upgrade ---------------------------------

    group('DebugSnapshot confidence upgrade', () {
      testWidgets(
          'updateDebugSnapshot BEFORE scanAndIssues + non-zero rate '
          '→ confidence upgrades to likely', (tester) async {
        primeVmBuildCount(50);
        // Ordering pin: snapshot must be set before finalizeScan
        // consumes _lastDebugSnapshot.
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'_StatefulHost': 50},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth1(),
        );
        expect(issues, hasStableId('shallow_rebuild_risk'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'shallow_rebuild_risk');
        expect(issue.confidence, IssueConfidence.likely);
        expect(
          issue.observationSource,
          ObservationSource.debugCallbackAndStructural,
        );
        expect(issue.detail, contains('rebuilding at 50/sec'));
      });

      testWidgets(
          'structural-fallback branch (vmConnected=false) + non-zero rate '
          '→ also upgrades to likely', (tester) async {
        // The VM-backed branch (line 138-186) and structural-fallback
        // branch (line 187-237) duplicate DebugSnapshot upgrade logic.
        // A regression in ONLY the fallback branch would silently break
        // debug-mode users when VM drops out — only this test catches
        // that path. Eventually the duplicated block should be factored
        // into a shared helper.
        detector.vmConnected = false;
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'_StatefulHost': 50},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth1(),
        );
        expect(issues, hasStableId('shallow_rebuild_risk'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'shallow_rebuild_risk');
        expect(issue.confidence, IssueConfidence.likely);
        expect(
          issue.observationSource,
          ObservationSource.debugCallbackAndStructural,
        );
        expect(issue.detail, contains('rebuilding at 50/sec'));
      });

      testWidgets('structural-fallback branch + rate=0 → stays possible',
          (tester) async {
        detector.vmConnected = false;
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'_StatefulHost': 0},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth1(),
        );
        expect(issues, hasStableId('shallow_rebuild_risk'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'shallow_rebuild_risk');
        expect(issue.confidence, IssueConfidence.possible);
      });

      testWidgets(
          'snapshot with rate=0 (zero rebuilds) does NOT upgrade confidence',
          (tester) async {
        primeVmBuildCount(50);
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'_StatefulHost': 0},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth1(),
        );
        expect(issues, hasStableId('shallow_rebuild_risk'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'shallow_rebuild_risk');
        expect(issue.confidence, IssueConfidence.possible);
      });
    });

    // -- VM-disconnect immediate-effect -----------------------------------

    group('VM-disconnect semantics', () {
      testWidgets(
          'setting vmConnected=false clears existing issues immediately',
          (tester) async {
        primeVmBuildCount(50);
        await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth1(),
        );
        expect(detector.issues, hasStableId('shallow_rebuild_risk'));

        // Setter wipes _lastBuildCount + _issues synchronously. Note
        // that on the NEXT scanAndIssues, the structural fallback path
        // re-emits — that is verified by State 3 above. This test pins
        // the immediate-effect contract specifically.
        detector.vmConnected = false;
        expect(detector.issues, isEmpty);
      });
    });

    // -- Negative controls ------------------------------------------------

    group('negative controls', () {
      testWidgets('disabled detector ignores VM data', (tester) async {
        // isEnabled=false short-circuits processTimelineData, so
        // _lastBuildCount stays 0. With vmConnected=true and
        // _lastBuildCount=0, the gate falls into State 4 (silent
        // no-fire). Structural _usages still populates during
        // checkElement (no isEnabled guard there) but `_evaluate()`
        // also has no usages-only emission while vmConnected=true and
        // buildCount=0, so issues stay empty.
        detector.isEnabled = false;
        primeVmBuildCount(50);
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulHostAtDepth1(),
        );
        expect(issues, lacksStableId('shallow_rebuild_risk'));
      });

      testWidgets('plain stateless tree does not emit', (tester) async {
        primeVmBuildCount(50);
        final issues = await scanAndIssues(
          tester,
          detector,
          const SizedBox(),
        );
        expect(issues, lacksStableId('shallow_rebuild_risk'));
      });
    });
  });
}

// -- Test fixture widgets ---------------------------------------------

/// `_StatefulHost` is a custom StatefulWidget — its name does NOT match
/// any entry in the detector's framework allowlist, so it qualifies as
/// a shallow rebuild risk when discovered at depth ≤ 3.
class _StatefulHost extends StatefulWidget {
  const _StatefulHost();
  @override
  State<_StatefulHost> createState() => _StatefulHostState();
}

class _StatefulHostState extends State<_StatefulHost> {
  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}

/// `_StatefulHostAtDepth1` puts `_StatefulHost` directly under the
/// scanAndIssues root. The detector's `_depth` counter increments on
/// each `checkElement` call, so this fixture's host element is at
/// depth 1 in the walker — comfortably ≤ depthThreshold (default 3).
class _StatefulHostAtDepth1 extends StatelessWidget {
  const _StatefulHostAtDepth1();
  @override
  Widget build(BuildContext context) => const _StatefulHost();
}

/// `_StatefulHostAtDepth3` chains plain StatelessWidget wrappers so the
/// host element lands at exactly depth 3 — at the inclusive boundary
/// of `depthThreshold`. Adding intermediate widgets that build sub-trees
/// (Center, Padding) is unsafe because each one adds an extra element
/// layer the walker counts; plain wrappers contribute exactly 1 each.
class _StatefulHostAtDepth3 extends StatelessWidget {
  const _StatefulHostAtDepth3();
  @override
  Widget build(BuildContext context) =>
      const _DepthWrap(child: _StatefulHost());
}

/// `_StatefulHostAtDepth4` adds one more wrapper so the host lands at
/// depth 4 — past the threshold.
class _StatefulHostAtDepth4 extends StatelessWidget {
  const _StatefulHostAtDepth4();
  @override
  Widget build(BuildContext context) =>
      const _DepthWrap(child: _DepthWrap(child: _StatefulHost()));
}

class _DepthWrap extends StatelessWidget {
  const _DepthWrap({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}
