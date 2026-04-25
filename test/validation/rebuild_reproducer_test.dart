// Hermetic reproducer for `RebuildDetector`.
//
// Drives the detector at all four emission paths:
//   VM aggregate (`rebuild_activity`) — feeds N BUILD events through
//     `TimelineParser.parse()` into `processTimelineData`, advances a
//     fake clock past the 1s window so the count stages, then triggers
//     `_evaluate` via `scanAndIssues`. Pins the strict-greater rate gate
//     (`> rebuildsPerSecThreshold`, default 10) and 3× critical
//     escalation (`> 30`).
//   Per-widget debug non-builder (`rebuild_debug_<typeName>`) — supplies
//     a `DebugSnapshot` keyed by widget type with the standard 10/sec
//     threshold. Triad: just-below / boundary / 3× critical.
//   Per-widget debug builder (`rebuild_debug_StreamBuilder`) — same
//     snapshot path with a builder-listed type that uses the 3× threshold
//     multiplier (effective 30/sec). Includes a paired non-builder/builder
//     test at the SAME rate to prove the multiplier is active rather than
//     a coincidental gate.
//   Source-mode suppression — `source: RebuildCountSource.flutterTimeline`
//     blocks `_evaluateDebugData` because profile-mode counts include
//     initial inflations (KDD-5). Default `RebuildCountSource.none` keeps
//     the per-type path live for backwards compatibility.
//   Structural fallback (`stateful_density`) — disconnects VM, mounts a
//     tree of public-named StatefulWidgets above the threshold, asserts
//     the structural-only emission fires.
//
// Reconnect-flush — disconnects then reconnects VM and asserts prior
// rebuild_activity is cleared on the first post-reconnect evaluate.
//
// Highlights — pins `_maxHighlightsPerType=3` cap by mounting 5 instances
// of one type with a hot rebuild rate.
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
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '_helpers/structural_reproducer_harness.dart';
import '_helpers/vm_reproducer_harness.dart';

void main() {
  group('RebuildDetector reproducer', () {
    late RebuildDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = RebuildDetector(clock: () => fakeNow);
      // Cold-init false → true stages a sentinel `_pendingVmWindowCount=0`
      // that a subsequent `processTimelineData` overwrites.
      detector.vmConnected = true;
    });

    // -- Helpers ----------------------------------------------------------

    List<TimelineEvent> buildEvents(int n) => List.generate(
          n,
          (i) => buildEvent(
            name: 'BUILD',
            ph: 'X',
            dur: 100,
            ts: 1000 + i * 100,
          ),
        );

    /// BUILD events carrying `build scope dirty list` enrichment in `args`.
    ///
    /// Flutter writes timeline args as `Map<String, String>`; the dirty
    /// list arrives as the `toString()` of a Dart `List<String>`
    /// (e.g. `'[Foo, Bar]'`). `TimelineParser._parseDirtyList` strips
    /// the `[]` wrapper and splits on `', '`. Each event's list is
    /// appended to the detector's `_pendingEnrichedNames` accumulator.
    List<TimelineEvent> buildEventsWithDirtyList(int n,
            {required List<String> dirtyPerEvent}) =>
        List.generate(
          n,
          (i) => buildEvent(
            name: 'BUILD',
            ph: 'X',
            dur: 100,
            ts: 1000 + i * 100,
            args: {
              'build scope dirty list': '[${dirtyPerEvent.join(', ')}]',
            },
          ),
        );

    ParsedShape buildShape(int n) => (
          buildEventCount: n,
          buildScopeCount: n,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: n,
        );

    /// Stage a VM window with [buildCount] build events. Advances the
    /// fake clock past the 1s threshold first so the call stages
    /// atomically in a single processTimelineData call.
    void primeVmWindow(int buildCount) {
      fakeNow = fakeNow.add(const Duration(milliseconds: 1100));
      final parsed = parseAndAssertShape(
        buildEvents(buildCount),
        buildShape(buildCount),
      );
      detector.processTimelineData(parsed);
    }

    DebugSnapshot perTypeSnapshot({
      required Map<String, int> rebuildCounts,
      Duration elapsed = const Duration(seconds: 1),
      RebuildCountSource source = RebuildCountSource.none,
    }) {
      return DebugSnapshot(
        rebuildCounts: rebuildCounts,
        totalPaintCount: 0,
        elapsed: elapsed,
        source: source,
      );
    }

    // -- Group A: VM aggregate rebuild_activity triad --------------------

    group('rebuild_activity VM triad (strict > 10)', () {
      testWidgets('buildCount = 10 (boundary): no fire', (tester) async {
        primeVmWindow(10);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });

      testWidgets('buildCount = 11: warning', (tester) async {
        primeVmWindow(11);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('rebuild_activity'));
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.confirmed);
        expect(issue.observationSource, ObservationSource.vmTimeline);
      });

      testWidgets('buildCount = 31 (> 3× threshold): critical', (tester) async {
        primeVmWindow(31);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('rebuild_activity'));
        expect(issue.severity, IssueSeverity.critical);
      });

      testWidgets(
          'enriched dirty-list surfaces in detail (parser arg path exercised)',
          (tester) async {
        // Each BUILD event carries `args: {'build scope dirty list':
        // '[Foo, Bar]'}`. Parser strips brackets + splits on `', '`;
        // detector concatenates into `_pendingEnrichedNames` and emits
        // top-3 in detail. Without this fixture the enrichment branch
        // (`event.dirtyList != null`) is never entered.
        fakeNow = fakeNow.add(const Duration(milliseconds: 1100));
        final events = buildEventsWithDirtyList(
          11,
          dirtyPerEvent: const ['Foo', 'Bar'],
        );
        final parsed = parseAndAssertShape(events, buildShape(11));
        expect(
          parsed.phaseEvents.every((e) => e.dirtyList?.length == 2),
          isTrue,
          reason: 'TimelineParser must decode `build scope dirty list` '
              'arg into PhaseEvent.dirtyList; mismatch = arg-name typo '
              'or list-format parse regression.',
        );
        detector.processTimelineData(parsed);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasStableId('rebuild_activity'));
        final issue =
            issues.firstWhere((i) => i.stableId == 'rebuild_activity');
        expect(issue.detail, contains('timeline enrichment'));
        expect(issue.detail, contains('Foo'));
        expect(issue.detail, contains('Bar'));
      });

      testWidgets('exact 1000ms elapsed: window stages (gate is `>=` not `>`)',
          (tester) async {
        // Pins `if (now.difference(_windowStart).inMilliseconds >= 1000)`.
        // A regression flipping to strict `>` would only fail at exactly
        // 1000ms; reproducer's 1100ms helper would still pass.
        fakeNow = fakeNow.add(const Duration(milliseconds: 1000));
        final parsed = parseAndAssertShape(buildEvents(11), buildShape(11));
        detector.processTimelineData(parsed);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasStableId('rebuild_activity'));
      });
    });

    // -- Group B: per-widget non-builder triad (>= 10) -------------------

    group('rebuild_debug_<Type> non-builder triad (rate >= 10)', () {
      testWidgets('rate = 9 (just-below): no fire', (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'MyWidget': 9}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });

      testWidgets('rate = 10 (boundary): warning', (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'MyWidget': 10}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('rebuild_debug_MyWidget'));
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.confirmed);
        expect(issue.observationSource, ObservationSource.debugCallback);
      });

      testWidgets('rate = 31 (> 3× threshold): critical', (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'MyWidget': 31}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('rebuild_debug_MyWidget'));
        expect(issue.severity, IssueSeverity.critical);
      });
    });

    // -- Group BB: per-widget builder triad (3× multiplier, >= 30) -------

    group('rebuild_debug_<Builder> builder triad (rate >= 30)', () {
      testWidgets('rate = 29 (just-below builder threshold): no fire',
          (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'StreamBuilder': 29}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });

      testWidgets('rate = 30 (boundary): warning', (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'StreamBuilder': 30}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('rebuild_debug_StreamBuilder'));
        expect(issue.severity, IssueSeverity.warning);
      });

      testWidgets('rate = 91 (> 3× builder threshold): critical',
          (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'StreamBuilder': 91}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('rebuild_debug_StreamBuilder'));
        expect(issue.severity, IssueSeverity.critical);
      });
    });

    // -- Group B': paired multiplier proof at identical rate -------------

    group('builder multiplier proof (paired at rate=25)', () {
      testWidgets('non-builder MyWidget at 25/sec fires (25 > 10)',
          (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'MyWidget': 25}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        expect(issues, hasStableId('rebuild_debug_MyWidget'));
      });

      testWidgets('builder StreamBuilder at 25/sec suppressed (25 < 30)',
          (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'StreamBuilder': 25}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });
    });

    // -- Group B'': source-mode flutterTimeline suppresses per-type ------

    group('source-mode RebuildCountSource.flutterTimeline gate', () {
      testWidgets(
          'flutterTimeline source: per-type path skipped even at warning rate',
          (tester) async {
        // Per-type rate 20/sec would normally fire warning. Profile-mode
        // counts include initial inflations (KDD-5) so the per-type
        // emission is gated off; route entry must not surface critical
        // false positives for `ProductCard × 50` list inflations.
        detector.updateDebugSnapshot(
          perTypeSnapshot(
            rebuildCounts: const {'ProductCard': 20},
            source: RebuildCountSource.flutterTimeline,
          ),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });

      testWidgets(
          'default source none: per-type path active (backwards-compat)',
          (tester) async {
        // Same fixture, default source: pre-v15 const-literal snapshots
        // keep exercising the per-type path unchanged.
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'ProductCard': 20}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        expect(issues, hasStableId('rebuild_debug_ProductCard'));
      });
    });

    // -- Group D: structural fallback stateful_density -------------------

    group('stateful_density structural fallback (VM disconnected)', () {
      testWidgets('11 public-named StatefulWidgets fires warning',
          (tester) async {
        detector.vmConnected = false;
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulTree(leafCount: 11),
        );
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('stateful_density'));
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.possible);
        expect(issue.observationSource, ObservationSource.structural);
      });

      testWidgets('9 public-named StatefulWidgets stays below threshold',
          (tester) async {
        detector.vmConnected = false;
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulTree(leafCount: 9),
        );
        expect(issues, isEmpty);
      });

      testWidgets('framework + private widgets do not inflate the count',
          (tester) async {
        // `_PrivateLeaf` instances are skipped because their typeName
        // starts with `_`. 30 private-named widgets must not trigger
        // stateful_density even though raw count exceeds threshold.
        detector.vmConnected = false;
        final issues = await scanAndIssues(
          tester,
          detector,
          const _PrivateStatefulTree(leafCount: 30),
        );
        expect(issues, isEmpty);
      });
    });

    // -- Group E: VM reconnect flush -------------------------------------

    group('VM reconnect flush', () {
      testWidgets(
          'disconnect → reconnect clears prior rebuild_activity on next scan',
          (tester) async {
        primeVmWindow(11);
        final firstIssues =
            await scanAndIssues(tester, detector, const SizedBox());
        expect(firstIssues, hasStableId('rebuild_activity'));

        detector.vmConnected = false;
        detector.vmConnected = true;

        final secondIssues =
            await scanAndIssues(tester, detector, const SizedBox());
        expect(secondIssues, isEmpty);
      });
    });

    // -- Group F: highlights cap (= 3) -----------------------------------

    group('highlights', () {
      testWidgets('5 instances at hot rate emit only 3 highlights (cap)',
          (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'_RebuildLeaf': 11}),
        );
        await scanAndIssues(
          tester,
          detector,
          const _RebuildLeafTree(leafCount: 5),
        );
        final leafHighlights = detector.highlights
            .where((h) => h.widgetName == '_RebuildLeaf')
            .toList();
        expect(leafHighlights.length, 3);
      });
    });

    // -- Group G: highlight ↔ issue parity --------------------------------
    //
    // Pins that highlight emission shares the same source-mode gate AND
    // effective-threshold severity logic as `_evaluateDebugData`. A
    // regression that derives `_hotTypes` without source filtering, or
    // uses `rebuildsPerSecThreshold * 3` (plain) instead of
    // `effectiveThreshold * 3` for severity, fires user-visible overlay
    // false positives that the cap-only test cannot detect.

    group('highlight ↔ issue parity', () {
      testWidgets(
          'flutterTimeline source: issues empty AND highlights empty (parity)',
          (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(
            rebuildCounts: const {'AnimatedBuilder': 50},
            source: RebuildCountSource.flutterTimeline,
          ),
        );
        final issues = await scanAndIssues(
          tester,
          detector,
          AnimatedBuilder(
            animation: const AlwaysStoppedAnimation<double>(0.0),
            builder: (_, __) => const SizedBox(),
          ),
        );
        // Issue suppression for KDD-5 inflation false-positives.
        expect(issues, isEmpty);
        // Highlight path must share the gate. Without it, overlay paints
        // hot-widget boxes for `ProductCard × 50` list-entry inflations
        // even though the issue was correctly suppressed.
        expect(detector.highlights, isEmpty);
      });

      testWidgets(
          'builder warning rate: issue AND highlight both warning (severity parity)',
          (tester) async {
        // AnimatedBuilder is in `_builderWidgetTypes`. Effective threshold
        // = 10 * 3 = 30/sec. Issue at rate=35 fires warning (35 ≤ 90,
        // critical at > 90). Highlight must use the SAME effective × 3
        // gate; a plain `rebuildsPerSecThreshold * 3` (= 30) would
        // escalate this case to critical.
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'AnimatedBuilder': 35}),
        );
        final issues = await scanAndIssues(
          tester,
          detector,
          AnimatedBuilder(
            animation: const AlwaysStoppedAnimation<double>(0.0),
            builder: (_, __) => const SizedBox(),
          ),
        );
        expect(issues, hasLength(1));
        expect(issues, hasStableId('rebuild_debug_AnimatedBuilder'));
        expect(issues.single.severity, IssueSeverity.warning);
        final highlight = detector.highlights.firstWhere(
          (h) => h.widgetName == 'AnimatedBuilder',
        );
        expect(highlight.severity, IssueSeverity.warning);
      });
    });

    // -- Group H: stale `_pendingVmWindowCount` after flutterTimeline ----
    //
    // Pins the fix for the `flutterTimeline + totalRebuilds > 0 +
    // hasFreshVm` fall-through branch in `_evaluate`. The fresh-debug
    // branch must consume the staged VM count even when neither inner
    // sub-case fires; otherwise the next scan replays the stale count as
    // `rebuild_activity` after enrichment + tree context have already
    // been discarded — a ghost issue surfacing 1+ seconds late, often
    // after navigation.

    group('stale VM stage (flutterTimeline fall-through)', () {
      testWidgets(
          'flutterTimeline + VM staged: next empty scan does NOT replay '
          'rebuild_activity', (tester) async {
        primeVmWindow(15);
        detector.updateDebugSnapshot(
          perTypeSnapshot(
            rebuildCounts: const {'ProductCard': 20},
            source: RebuildCountSource.flutterTimeline,
          ),
        );
        final firstIssues =
            await scanAndIssues(tester, detector, const SizedBox());
        expect(firstIssues, isEmpty);

        final secondIssues =
            await scanAndIssues(tester, detector, const SizedBox());
        // Without the fix, `_pendingVmWindowCount=15` lingers from tick 1.
        // Tick 2 takes the `else if (hasFreshVm)` branch and emits
        // `rebuild_activity` for the stale window.
        expect(secondIssues, isEmpty);
      });
    });

    // -- Group I: same-tick VM fallback when per-type emits nothing -------
    //
    // Pins the fix for the case where a debug snapshot has totalRebuilds>0
    // BUT no individual per-type crosses its threshold (e.g. a rebuild
    // storm spread across many widgets at sub-threshold rate). Without
    // the same-tick fallback, the staged VM count was discarded along
    // with the snapshot, silently dropping real `rebuild_activity` evidence.

    group('same-tick VM fallback (sub-threshold per-type)', () {
      testWidgets(
          'totalRebuilds=50 spread sub-threshold + VM staged 50 → '
          'rebuild_activity fires', (tester) async {
        primeVmWindow(50);
        detector.updateDebugSnapshot(
          perTypeSnapshot(
            // 10 widget types, each rebuilding at 5/sec — below the per-
            // type threshold of 10. `_evaluateDebugData` emits nothing.
            // Without the same-tick VM fallback, the staged 50 is dropped
            // silently and the rebuild storm goes unreported.
            rebuildCounts: const {
              'WidgetA': 5,
              'WidgetB': 5,
              'WidgetC': 5,
              'WidgetD': 5,
              'WidgetE': 5,
              'WidgetF': 5,
              'WidgetG': 5,
              'WidgetH': 5,
              'WidgetI': 5,
              'WidgetJ': 5,
            },
          ),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        expect(issues, hasStableId('rebuild_activity'));
      });
    });

    // -- Group J: generic builder canonicalization ------------------------
    //
    // Production builder widgets are generic — `StreamBuilder<int>`,
    // `FutureBuilder<Foo>`, `ValueListenableBuilder<bool>`. Prior to
    // canonicalization, `_builderWidgetTypes.contains('StreamBuilder<int>')`
    // returned false → builder fired at the non-builder threshold (10/sec
    // instead of 30/sec) and escalated critical at 30/sec instead of 90.
    // The reproducer's earlier Group BB used bare 'StreamBuilder' which
    // skipped the production runtime-type shape.

    group('generic builder canonicalization', () {
      testWidgets(
          'StreamBuilder<int> at rate=35: warning (NOT critical), '
          'builder threshold applied', (tester) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(
            // Generic-suffixed key matches the production shape from
            // `runtimeType.toString()`. Pre-fix, this would fire as a
            // non-builder warning (35 > 10) AND escalate critical (35 > 30).
            // Post-fix, the canonicalized base name `StreamBuilder` matches
            // the builder set → effective threshold 30 → 35 fires warning,
            // critical only above 90.
            rebuildCounts: const {'StreamBuilder<int>': 35},
          ),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        expect(issues, hasStableId('rebuild_debug_StreamBuilder<int>'));
        expect(issues.single.severity, IssueSeverity.warning);
      });

      testWidgets(
          'StreamBuilder<int> at rate=29 (just-below builder threshold): '
          'no fire', (tester) async {
        // Without canonicalization, this would fire at non-builder
        // threshold (29 > 10).
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'StreamBuilder<int>': 29}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });
    });

    // -- Negative controls -----------------------------------------------

    group('negative controls', () {
      testWidgets('disabled detector does not stage VM data', (tester) async {
        detector.isEnabled = false;
        fakeNow = fakeNow.add(const Duration(milliseconds: 1100));
        final parsed = parseAndAssertShape(buildEvents(50), buildShape(50));
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

class _StatefulTree extends StatelessWidget {
  const _StatefulTree({required this.leafCount});
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        leafCount,
        (i) => StatefulLeaf(key: ValueKey(i)),
      ),
    );
  }
}

class _PrivateStatefulTree extends StatelessWidget {
  const _PrivateStatefulTree({required this.leafCount});
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        leafCount,
        (i) => _PrivateLeaf(key: ValueKey(i)),
      ),
    );
  }
}

class _RebuildLeafTree extends StatelessWidget {
  const _RebuildLeafTree({required this.leafCount});
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        leafCount,
        (i) => _RebuildLeaf(key: ValueKey(i)),
      ),
    );
  }
}

// Public-named StatefulWidget — `stateful_density` counts these.
class StatefulLeaf extends StatefulWidget {
  const StatefulLeaf({super.key});
  @override
  State<StatefulLeaf> createState() => _StatefulLeafState();
}

class _StatefulLeafState extends State<StatefulLeaf> {
  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}

// Private-named StatefulWidget — filtered out of `stateful_density`.
class _PrivateLeaf extends StatefulWidget {
  const _PrivateLeaf({super.key});
  @override
  State<_PrivateLeaf> createState() => _PrivateLeafState();
}

class _PrivateLeafState extends State<_PrivateLeaf> {
  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}

// Stateless leaf used for highlight-cap fixture (highlights only need
// matching typeName via the debug snapshot — stateful-ness is unused).
class _RebuildLeaf extends StatelessWidget {
  const _RebuildLeaf({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}
