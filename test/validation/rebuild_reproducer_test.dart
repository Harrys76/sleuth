// IDE analyzer false-positive: dart:core RegExp uses @Deprecated.implement
// (fires only on subclassing). Remove when analyzer-server recognizes the
// implement-only kind.
// ignore_for_file: deprecated_member_use
// Hermetic reproducer for `RebuildDetector`.
//
// Drives the detector at all four emission paths:
//   VM aggregate (`rebuild_activity`) — feeds BUILD scopes whose
//     durations sum to a chosen share of a 1 000 ms window through
//     `TimelineParser.parse()` into `processTimelineData`, advances a
//     fake clock to close the window, then triggers `_evaluate` via
//     `scanAndIssues`. Pins the strict-greater time-share gate
//     (`> buildTimePercentThreshold`, default 10 %) and 3× critical
//     escalation (`> 30 %`).
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
//     initial inflations (first builds), not only rebuilds. Default
//     `RebuildCountSource.none` keeps the per-type path live for backwards
//     compatibility.
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

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

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
      // Cold-init false → true stages a sentinel `_pendingVmWindowPercent=0`
      // that a subsequent `processTimelineData` overwrites.
      detector.vmConnected = true;
    });

    // -- Helpers ----------------------------------------------------------

    List<TimelineEvent> buildEvents(int n, {int durUs = 100}) => List.generate(
      n,
      (i) =>
          buildEvent(name: 'BUILD', ph: 'X', dur: durUs, ts: 1000 + i * 50000),
    );

    /// BUILD events carrying `build scope dirty list` enrichment in `args`.
    ///
    /// Flutter writes timeline args as `Map<String, String>`; the dirty
    /// list arrives as the `toString()` of a Dart `List<String>`
    /// (e.g. `'[Foo, Bar]'`). `TimelineParser._parseDirtyList` strips
    /// the `[]` wrapper and splits on `', '`. Each event's list is
    /// appended to the detector's `_pendingEnrichedNames` accumulator.
    List<TimelineEvent> buildEventsWithDirtyList(
      int n, {
      required List<String> dirtyPerEvent,
    }) => List.generate(
      n,
      (i) => buildEvent(
        name: 'BUILD',
        ph: 'X',
        dur: 11000,
        ts: 1000 + i * 50000,
        args: {'build scope dirty list': '[${dirtyPerEvent.join(', ')}]'},
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

    /// Stage a VM window whose BUILD time is [percent] % of a 1 000 ms
    /// window: ten BUILD scopes of `percent × 1000 / 10 × 10` µs each.
    /// Advances the fake clock to exactly 1 000 ms first so the call
    /// stages atomically in a single processTimelineData call.
    void primeVmWindow(double percent) {
      fakeNow = fakeNow.add(const Duration(milliseconds: 1000));
      final parsed = parseAndAssertShape(
        buildEvents(10, durUs: (percent * 1000).round()),
        buildShape(10),
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

    group('rebuild_activity VM triad (strict > 10 %)', () {
      testWidgets('9.5 % build share: no fire', (tester) async {
        primeVmWindow(9.5);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
        expect(detector.lastObservedBuildPercent, closeTo(9.5, 1e-9));
      });

      testWidgets('10.0 % build share (boundary): no fire', (tester) async {
        primeVmWindow(10);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
      });

      testWidgets('10.5 % build share: warning', (tester) async {
        primeVmWindow(10.5);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('rebuild_activity'));
        expect(issue.severity, IssueSeverity.warning);
        expect(issue.confidence, IssueConfidence.confirmed);
        expect(issue.observationSource, ObservationSource.vmTimeline);
        expect(issue.extraTraceArgs?['observedBuildPercent'], '10.5');
      });

      testWidgets('31 % build share (> 3× threshold): critical', (
        tester,
      ) async {
        primeVmWindow(31);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        final issue = issues.single;
        expect(issues, hasStableId('rebuild_activity'));
        expect(issue.severity, IssueSeverity.critical);
        expect(issue.extraTraceArgs?['observedBuildPercent'], '31.0');
      });

      testWidgets('many cheap BUILD scopes stay silent (count is not cost)', (
        tester,
      ) async {
        // 60 BUILD scopes of 100 µs in one second — a 60 fps animation of
        // a small subtree — is 0.6 % of UI time.
        fakeNow = fakeNow.add(const Duration(milliseconds: 1000));
        final parsed = parseAndAssertShape(buildEvents(60), buildShape(60));
        detector.processTimelineData(parsed);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, isEmpty);
        expect(detector.lastObservedBuildPercent, closeTo(0.6, 1e-9));
      });

      testWidgets(
        'enriched dirty-list surfaces in detail (parser arg path exercised)',
        (tester) async {
          // Each BUILD event carries `args: {'build scope dirty list':
          // '[Foo, Bar]'}`. Parser strips brackets + splits on `', '`;
          // detector concatenates into `_pendingEnrichedNames` and emits
          // top-3 in detail. Without this fixture the enrichment branch
          // (`event.dirtyList != null`) is never entered.
          fakeNow = fakeNow.add(const Duration(milliseconds: 1000));
          final events = buildEventsWithDirtyList(
            11,
            dirtyPerEvent: const ['Foo', 'Bar'],
          );
          final parsed = parseAndAssertShape(events, buildShape(11));
          expect(
            parsed.phaseEvents.every((e) => e.dirtyList?.length == 2),
            isTrue,
            reason:
                'TimelineParser must decode `build scope dirty list` '
                'arg into PhaseEvent.dirtyList; mismatch = arg-name typo '
                'or list-format parse regression.',
          );
          detector.processTimelineData(parsed);
          final issues = await scanAndIssues(
            tester,
            detector,
            const SizedBox(),
          );
          expect(issues, hasStableId('rebuild_activity'));
          final issue = issues.firstWhere(
            (i) => i.stableId == 'rebuild_activity',
          );
          expect(issue.detail, contains('timeline enrichment'));
          expect(issue.detail, contains('Foo'));
          expect(issue.detail, contains('Bar'));
        },
      );

      testWidgets(
        'exact 1000ms elapsed: window stages (gate is `>=` not `>`)',
        (tester) async {
          // Pins `elapsedUs >= Duration.microsecondsPerSecond`. A regression
          // flipping to strict `>` would leave the window open at exactly
          // 1000ms and emit nothing.
          fakeNow = fakeNow.add(const Duration(milliseconds: 1000));
          final parsed = parseAndAssertShape(
            buildEvents(11, durUs: 10000),
            buildShape(11),
          );
          detector.processTimelineData(parsed);
          final issues = await scanAndIssues(
            tester,
            detector,
            const SizedBox(),
          );
          expect(issues, hasStableId('rebuild_activity'));
        },
      );
    });

    // -- Group A.1: rebuild_activity.critical bracket contract -----------
    //
    // Pins `additionalBrackets[0]` (critical tier, threshold 30 %,
    // atTolerance 0.5, aboveCeilingMultiplier 2.7) against the stamped
    // `observedBuildPercent`: at-band [30, 45], above-band (45, 81].

    group('rebuild_activity.critical bracket contract', () {
      ({num threshold, double at, double ceiling}) criticalSpec() {
        final spec = detector.validationMetadata.additionalBrackets!.single;
        return (
          threshold: spec.threshold,
          at: spec.atTolerance!,
          ceiling: spec.aboveCeilingMultiplier!,
        );
      }

      Future<PerformanceIssue> emit(WidgetTester tester, double percent) async {
        primeVmWindow(percent);
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        return issues.firstWhere((i) => i.stableId == 'rebuild_activity');
      }

      testWidgets('31 % stamps observedBuildPercent + critical severity', (
        tester,
      ) async {
        final issue = await emit(tester, 31);
        expect(issue.severity, IssueSeverity.critical);
        expect(issue.extraTraceArgs!['observedBuildPercent'], equals('31.0'));
      });

      testWidgets('30 % stays warning (boundary)', (tester) async {
        final issue = await emit(tester, 30);
        expect(issue.severity, IssueSeverity.warning);
      });

      testWidgets('45 % is the last value inside the critical at-band', (
        tester,
      ) async {
        final spec = criticalSpec();
        final issue = await emit(tester, 45);
        expect(issue.severity, IssueSeverity.critical);
        expect(issue.extraTraceArgs!['observedBuildPercent'], equals('45.0'));
        expect(45 <= spec.threshold * (1 + spec.at), isTrue);
      });

      testWidgets('45.5 % lies in the above-band', (tester) async {
        final spec = criticalSpec();
        final issue = await emit(tester, 45.5);
        expect(issue.extraTraceArgs!['observedBuildPercent'], equals('45.5'));
        expect(45.5 > spec.threshold * (1 + spec.at), isTrue);
      });

      testWidgets('81 % sits at the above-ceiling; 81.5 % exceeds it', (
        tester,
      ) async {
        final spec = criticalSpec();
        expect(
          (await emit(tester, 81)).extraTraceArgs!['observedBuildPercent'],
          '81.0',
        );
        expect(81 <= spec.threshold * spec.ceiling, isTrue);
        expect(81.5 > spec.threshold * spec.ceiling, isTrue);
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
      testWidgets('rate = 29 (just-below builder threshold): no fire', (
        tester,
      ) async {
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

      testWidgets('rate = 91 (> 3× builder threshold): critical', (
        tester,
      ) async {
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
      testWidgets('non-builder MyWidget at 25/sec fires (25 > 10)', (
        tester,
      ) async {
        detector.updateDebugSnapshot(
          perTypeSnapshot(rebuildCounts: const {'MyWidget': 25}),
        );
        final issues = await scanAndIssues(tester, detector, const SizedBox());
        expect(issues, hasLength(1));
        expect(issues, hasStableId('rebuild_debug_MyWidget'));
      });

      testWidgets('builder StreamBuilder at 25/sec suppressed (25 < 30)', (
        tester,
      ) async {
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
          // counts include initial inflations (first builds), so the per-type
          // emission is gated off; route entry must not surface critical
          // false positives for `ProductCard × 50` list inflations.
          detector.updateDebugSnapshot(
            perTypeSnapshot(
              rebuildCounts: const {'ProductCard': 20},
              source: RebuildCountSource.flutterTimeline,
            ),
          );
          final issues = await scanAndIssues(
            tester,
            detector,
            const SizedBox(),
          );
          expect(issues, isEmpty);
        },
      );

      testWidgets(
        'default source none: per-type path active (backwards-compat)',
        (tester) async {
          // Same fixture, default source: pre-v15 const-literal snapshots
          // keep exercising the per-type path unchanged.
          detector.updateDebugSnapshot(
            perTypeSnapshot(rebuildCounts: const {'ProductCard': 20}),
          );
          final issues = await scanAndIssues(
            tester,
            detector,
            const SizedBox(),
          );
          expect(issues, hasLength(1));
          expect(issues, hasStableId('rebuild_debug_ProductCard'));
        },
      );
    });

    // -- Group D: structural fallback stateful_density -------------------

    group('stateful_density structural fallback (VM disconnected)', () {
      testWidgets('11 public-named StatefulWidgets fires warning', (
        tester,
      ) async {
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

      testWidgets('9 public-named StatefulWidgets stays below threshold', (
        tester,
      ) async {
        detector.vmConnected = false;
        final issues = await scanAndIssues(
          tester,
          detector,
          const _StatefulTree(leafCount: 9),
        );
        expect(issues, isEmpty);
      });

      testWidgets('framework + private widgets do not inflate the count', (
        tester,
      ) async {
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
          final firstIssues = await scanAndIssues(
            tester,
            detector,
            const SizedBox(),
          );
          expect(firstIssues, hasStableId('rebuild_activity'));

          detector.vmConnected = false;
          detector.vmConnected = true;

          final secondIssues = await scanAndIssues(
            tester,
            detector,
            const SizedBox(),
          );
          expect(secondIssues, isEmpty);
        },
      );
    });

    // -- Group F: highlights cap (= 3) -----------------------------------

    group('highlights', () {
      testWidgets('5 instances at hot rate emit only 3 highlights (cap)', (
        tester,
      ) async {
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
              builder: (_, _) => const SizedBox(),
            ),
          );
          // Profile counts include first builds, so per-type issues stay
          // suppressed to avoid inflation false positives.
          expect(issues, isEmpty);
          // Highlight path must share the gate. Without it, overlay paints
          // hot-widget boxes for `ProductCard × 50` list-entry inflations
          // even though the issue was correctly suppressed.
          expect(detector.highlights, isEmpty);
        },
      );

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
              builder: (_, _) => const SizedBox(),
            ),
          );
          expect(issues, hasLength(1));
          expect(issues, hasStableId('rebuild_debug_AnimatedBuilder'));
          expect(issues.single.severity, IssueSeverity.warning);
          final highlight = detector.highlights.firstWhere(
            (h) => h.widgetName == 'AnimatedBuilder',
          );
          expect(highlight.severity, IssueSeverity.warning);
        },
      );
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
        'flutterTimeline + VM staged: the window is evaluated once and the '
        'next empty scan does NOT replay it',
        (tester) async {
          primeVmWindow(15);
          detector.updateDebugSnapshot(
            perTypeSnapshot(
              rebuildCounts: const {'ProductCard': 20},
              source: RebuildCountSource.flutterTimeline,
            ),
          );
          final firstIssues = await scanAndIssues(
            tester,
            detector,
            const SizedBox(),
          );
          // Profile per-type counts never report; the window does.
          expect(firstIssues, hasLength(1));
          expect(firstIssues, hasStableId('rebuild_activity'));

          final secondIssues = await scanAndIssues(
            tester,
            detector,
            const SizedBox(),
          );
          // The consumed window is not evaluated again: the same issue,
          // no second emission.
          expect(secondIssues.single, same(firstIssues.single));
        },
      );
    });

    // -- Group I: same-tick VM fallback when per-type emits nothing -------
    //
    // Pins the fix for the case where a debug snapshot has totalRebuilds>0
    // BUT no individual per-type crosses its threshold (e.g. a rebuild
    // storm spread across many widgets at sub-threshold rate). Without
    // the same-tick fallback, the staged VM count was discarded along
    // with the snapshot, silently dropping real `rebuild_activity` evidence.

    group('same-tick VM fallback (sub-threshold per-type)', () {
      testWidgets('totalRebuilds=50 spread sub-threshold + VM staged 50 % → '
          'rebuild_activity fires', (tester) async {
        primeVmWindow(50);
        detector.updateDebugSnapshot(
          perTypeSnapshot(
            // 10 widget types, each rebuilding at 5/sec — below the per-
            // type threshold of 10. `_evaluateDebugData` emits nothing.
            // Without the same-tick VM fallback, the staged 50 % is dropped
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
      testWidgets('StreamBuilder<int> at rate=35: warning (NOT critical), '
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
        'no fire',
        (tester) async {
          // Without canonicalization, this would fire at non-builder
          // threshold (29 > 10).
          detector.updateDebugSnapshot(
            perTypeSnapshot(rebuildCounts: const {'StreamBuilder<int>': 29}),
          );
          final issues = await scanAndIssues(
            tester,
            detector,
            const SizedBox(),
          );
          expect(issues, isEmpty);
        },
      );

      testWidgets(
        'mounted StreamBuilder<int> at rate=35: issue + highlight both '
        'warning (canonicalization end-to-end)',
        (tester) async {
          // End-to-end pin: mounting a real `StreamBuilder<int>` widget
          // exercises the highlight path (`_hotRebuildTypes` Priority 1 +
          // `checkElement` severity) alongside the issue path
          // (`_evaluateDebugData`). The runtime-type string the
          // tree-walker observes (`'StreamBuilder<int>'`) matches the
          // snapshot key and the canonicalized base name (`StreamBuilder`)
          // matches the builder set → builder threshold 30/sec applies on
          // BOTH paths.
          final controller = StreamController<int>();
          addTearDown(controller.close);
          detector.updateDebugSnapshot(
            perTypeSnapshot(rebuildCounts: const {'StreamBuilder<int>': 35}),
          );
          final issues = await scanAndIssues(
            tester,
            detector,
            StreamBuilder<int>(
              stream: controller.stream,
              initialData: 0,
              builder: (_, _) => const SizedBox(),
            ),
          );
          expect(issues, hasLength(1));
          expect(issues, hasStableId('rebuild_debug_StreamBuilder<int>'));
          expect(issues.single.severity, IssueSeverity.warning);
          final highlight = detector.highlights.firstWhere(
            (h) => h.widgetName == 'StreamBuilder<int>',
          );
          expect(highlight.severity, IssueSeverity.warning);
        },
      );
    });

    // -- Negative controls -----------------------------------------------

    group('negative controls', () {
      testWidgets('disabled detector does not stage VM data', (tester) async {
        detector.isEnabled = false;
        fakeNow = fakeNow.add(const Duration(milliseconds: 1000));
        final parsed = parseAndAssertShape(
          buildEvents(10, durUs: 50000),
          buildShape(10),
        );
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

  // ----------------------------------------------------------------
  // Producer-wiring guard
  // ----------------------------------------------------------------
  // The schema's per-leg invariants leave below-leg's axis unchecked
  // (a silent leg has no warning event to cross-check against), so a
  // producer that exports a planned target instead of the detector's
  // measurement silently certifies a value the detector never observed.
  // Pin the capture screen's source of truth and its leg factors here.
  group('producer-wiring guard', () {
    final screenFile = File(
      'example/lib/demos/rebuild_activity_capture_screen.dart',
    );
    final driverFile = File('example/lib/demos/capture_driver.dart');

    Map<String, double> legFactors(String src, String constName) {
      final start = src.indexOf('const $constName = <_Leg>[');
      expect(
        start,
        greaterThanOrEqualTo(0),
        reason: 'capture screen must declare const $constName.',
      );
      final block = src.substring(start, src.indexOf('];', start));
      final pattern = RegExp(r"_Leg\('(\w+)',\s*([0-9.]+)\)");
      return {
        for (final m in pattern.allMatches(block))
          m.group(1)!: double.parse(m.group(2)!),
      };
    }

    test('rebuild_activity capture reads the detector, not the plan', () {
      expect(screenFile.existsSync(), isTrue);
      expect(driverFile.existsSync(), isTrue);
      final src = screenFile.readAsStringSync();
      expect(src, contains("'rebuild_activity_\$basename'"));
      expect(
        src,
        contains('detector.peakObservedBuildPercent'),
        reason: 'expectedMagnitude.observed must be the detector peak.',
      );
      expect(
        driverFile.readAsStringSync(),
        contains('final measured = readPeak();'),
        reason: 'the calibration pre-pass must read the detector peak.',
      );
      expect(
        src,
        contains('detector.buildTimePercentThreshold'),
        reason: 'leg targets derive from the live threshold.',
      );
      expect(src, contains('runTimeShareLeg('));

      final driver = driverFile.readAsStringSync();
      expect(driver, contains('Sleuth.flushTimelineNow('));
      expect(driver, contains("unit: 'percent'"));
      expect(driver, contains("magnitudeSourceEventName: ''"));
      // Provenance is read from the build, not assumed.
      expect(driver, contains('flutterVersion: FlutterVersion.version'));
      expect(driver, contains('flutterVersion: provenance.flutterVersion'));
      expect(
        RegExp(r'magnitudeObserved:\s*observed').hasMatch(driver),
        isTrue,
        reason: 'the exported magnitude must be the measured peak.',
      );
      // Boundary between pre-pass and scenario: reset then idle dwell
      // before markScenarioBegin, so pre-pass work never reaches an
      // in-span window.
      final reset = driver.lastIndexOf('resetDetector();');
      final dwell = driver.indexOf('holdInFront(kBoundaryDwell', reset);
      final begin = driver.indexOf('calls.markScenarioBegin(', reset);
      expect(reset, greaterThan(0));
      expect(dwell, greaterThan(reset));
      expect(begin, greaterThan(dwell));
    });

    test('leg factors land each target inside its role band', () {
      final src = screenFile.readAsStringSync();
      final warning = legFactors(src, '_warningLegs');
      final critical = legFactors(src, '_criticalLegs');
      expect(warning, {'below': 0.5, 'at': 1.25, 'above': 2.1});
      expect(critical, {'below': 0.8, 'at': 1.23, 'above': 2.0});

      final meta = RebuildDetector().validationMetadata;
      final criticalSpec = meta.additionalBrackets!.single;
      final tiers = <(Map<String, double>, num, double, double)>[
        (
          warning,
          meta.bracketThreshold!,
          meta.bracketAtTolerance!,
          meta.aboveCeilingMultiplier!,
        ),
        (
          critical,
          criticalSpec.threshold,
          criticalSpec.atTolerance!,
          criticalSpec.aboveCeilingMultiplier!,
        ),
      ];
      for (final (factors, t, at, ceiling) in tiers) {
        final below = factors['below']! * t;
        final atTarget = factors['at']! * t;
        final above = factors['above']! * t;
        expect(below, lessThan(t), reason: 'below target $below vs $t');
        expect(atTarget, inInclusiveRange(t, t * (1 + at)));
        expect(above, greaterThan(t * (1 + at)));
        expect(above, lessThanOrEqualTo(t * ceiling));
      }
      // The warning above leg must stay under the critical threshold so
      // it emits warning only.
      expect(
        warning['above']! * meta.bracketThreshold!,
        lessThan(criticalSpec.threshold),
      );
    });

    // Helper ↔ evidence coherence guard. The capture driver derives each
    // leg's expectedMagnitude band from the tier threshold (warning below
    // [0.5, t], critical below [0.65 t, t], at [t, 1.5 t], above
    // [1.5 t, 2.7 t]). A committed capture recorded by the screen at this
    // revision must carry exactly those bounds.
    test('committed capture expectedMagnitude.min/max match the capture '
        'driver band rule (re-record reproducibility contract)', () {
      final captureDir = Directory('test/validation/captures/rebuild_detector');
      if (!captureDir.existsSync()) {
        markTestSkipped('rebuild_detector captures not present.');
        return;
      }
      final meta = RebuildDetector().validationMetadata;
      final warningT = meta.bracketThreshold!.toDouble();
      final criticalT = meta.additionalBrackets!.single.threshold.toDouble();

      ({double min, double max}) band(String tier, String role, double t) =>
          switch (role) {
            'below' => (min: tier == 'critical' ? 0.65 * t : 0.5, max: t),
            'at' => (min: t, max: 1.5 * t),
            _ => (min: 1.5 * t, max: 2.7 * t),
          };

      void check(String basename, String tier, String role, double t) {
        final f = File('${captureDir.path}/$basename.json');
        if (!f.existsSync()) return;
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final metadata = j['sleuthMetadata'] as Map;
        final em = metadata['expectedMagnitude'] as Map;
        final expected = band(tier, role, t);
        expect(em['unit'], 'percent', reason: '$basename.json unit');
        expect(
          (em['min'] as num).toDouble(),
          closeTo(expected.min, 1e-9),
          reason: 'Drift: $basename.json expectedMagnitude.min',
        );
        expect(
          (em['max'] as num).toDouble(),
          closeTo(expected.max, 1e-9),
          reason: 'Drift: $basename.json expectedMagnitude.max',
        );
        expect(metadata['schemaVersion'], 'v1');
      }

      for (final role in const ['below', 'at', 'above']) {
        check(role, 'warning', role, warningT);
        check('critical_$role', 'critical', role, criticalT);
      }
    });

    // Capture-shape invariant: `Sleuth.exportCaptureJson` filters trace
    // events to a single scenario span, leaving exactly ONE begin + ONE
    // end pair in each capture JSON. The schema rejects multi-pair
    // captures; a regression in exportCaptureJson that dropped the
    // span-overlap filter would silently invalidate every rebuild
    // capture. Pin the count here so the contract is asserted by data,
    // not by reading the export source.
    test('rebuild capture JSONs contain exactly 1 scenario.begin + 1 '
        'scenario.end pair (exportCaptureJson span-filter contract)', () {
      final captureDir = Directory('test/validation/captures/rebuild_detector');
      if (!captureDir.existsSync()) {
        markTestSkipped('rebuild_detector captures not present.');
        return;
      }
      for (final leg in const ['below', 'at', 'above']) {
        final f = File('${captureDir.path}/$leg.json');
        if (!f.existsSync()) continue;
        final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final events = (json['traceEvents'] as List).cast<Map>();
        final begins = events
            .where((e) => e['name'] == 'sleuth.scenario.begin')
            .length;
        final ends = events
            .where((e) => e['name'] == 'sleuth.scenario.end')
            .length;
        expect(
          begins,
          equals(1),
          reason:
              '$leg.json must contain exactly 1 '
              '`sleuth.scenario.begin` marker after exportCaptureJson '
              'span-filtering. Found $begins.',
        );
        expect(
          ends,
          equals(1),
          reason:
              '$leg.json must contain exactly 1 '
              '`sleuth.scenario.end` marker. Found $ends.',
        );
      }
    });
  });

  group('RebuildDetector — lifecyclePhase attribution', () {
    // Pin behaviour for `extraTraceArgs.lifecyclePhase`:
    //   - within startupPhaseWindowSeconds of app-start → 'startup'
    //   - past the window → 'steady'
    //   - no app-start anchor → key omitted
    //
    // The detector reads `Timeline.now` at emission time and compares
    // against `appStartMonotonicUsForTest` or `Sleuth.dartEntryMonotonicUs`.
    // Tests pin the override relative to current `Timeline.now` for a
    // deterministic delta.

    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
    });

    List<TimelineEvent> buildEvents(int n, {int durUs = 100}) => List.generate(
      n,
      (i) =>
          buildEvent(name: 'BUILD', ph: 'X', dur: durUs, ts: 1000 + i * 50000),
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

    /// Closes a 1 000 ms window whose BUILD time is [percent] % of it.
    void primeVmWindow(RebuildDetector detector, double percent) {
      fakeNow = fakeNow.add(const Duration(milliseconds: 1000));
      final parsed = parseAndAssertShape(
        buildEvents(10, durUs: (percent * 1000).round()),
        buildShape(10),
      );
      detector.processTimelineData(parsed);
      detector.evaluateNow();
    }

    test('rebuild_activity stamps lifecyclePhase=startup within window', () {
      final detector = RebuildDetector(
        clock: () => fakeNow,
        appStartMonotonicUsForTest: () => developer.Timeline.now - 1000000,
      );
      detector.vmConnected = true;
      primeVmWindow(detector, 12); // 12 % > 10 % threshold → fires warning
      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'rebuild_activity',
      );
      expect(issue.extraTraceArgs?['lifecyclePhase'], 'startup');
      // Existing observed-axis key remains intact alongside lifecyclePhase.
      expect(issue.extraTraceArgs?['observedBuildPercent'], '12.0');
    });

    test('rebuild_activity stamps lifecyclePhase=steady past window', () {
      final detector = RebuildDetector(
        clock: () => fakeNow,
        appStartMonotonicUsForTest: () => developer.Timeline.now - 10000000,
      );
      detector.vmConnected = true;
      primeVmWindow(detector, 12);
      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'rebuild_activity',
      );
      expect(issue.extraTraceArgs?['lifecyclePhase'], 'steady');
      expect(issue.extraTraceArgs?['observedBuildPercent'], '12.0');
    });

    test('rebuild_debug_<typeName> stamps lifecyclePhase=startup', () {
      final detector = RebuildDetector(
        clock: () => fakeNow,
        appStartMonotonicUsForTest: () => developer.Timeline.now - 1000000,
      );
      detector.vmConnected = true;
      detector.updateDebugSnapshot(
        DebugSnapshot(
          rebuildCounts: {'MyWidget': 12},
          totalPaintCount: 0,
          elapsed: const Duration(seconds: 1),
          source: RebuildCountSource.none,
        ),
      );
      // Trigger _evaluate via timeline tick.
      primeVmWindow(detector, 0);
      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'rebuild_debug_MyWidget',
      );
      expect(issue.extraTraceArgs?['lifecyclePhase'], 'startup');
    });

    test('rebuild_activity omits lifecyclePhase when no app-start anchor', () {
      final detector = RebuildDetector(clock: () => fakeNow);
      detector.vmConnected = true;
      primeVmWindow(detector, 12);
      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'rebuild_activity',
      );
      expect(issue.extraTraceArgs?.containsKey('lifecyclePhase'), false);
      expect(issue.extraTraceArgs?['observedBuildPercent'], '12.0');
    });

    test('audit-gate co-presence: observedBuildPercent stays extractable', () {
      // Regression guard: lifecyclePhase must not displace the
      // runtimeVerified bracket axis key. The audit gate's
      // `validateBracket` reads `args[observedAxisArgKey]` directly, so
      // multi-key extraTraceArgs must still expose 'observedBuildPercent'.
      final detector = RebuildDetector(
        clock: () => fakeNow,
        appStartMonotonicUsForTest: () => developer.Timeline.now - 1000000,
      );
      detector.vmConnected = true;
      primeVmWindow(detector, 35); // above 3× critical → still has the arg
      final issue = detector.issues.firstWhere(
        (i) => i.stableId == 'rebuild_activity',
      );
      // Named-key assertions rather than exact-length: future axis
      // additions to extraTraceArgs should not break this regression
      // guard. The load-bearing invariant is that observedBuildPercent
      // (the audit-gate bracket axis) and lifecyclePhase both extract
      // correctly from the same emission.
      expect(issue.extraTraceArgs, isNotNull);
      expect(
        issue.extraTraceArgs!.containsKey('observedBuildPercent'),
        true,
        reason:
            'observedBuildPercent is the runtimeVerified bracket '
            'axis key — lifecyclePhase must not displace it.',
      );
      expect(issue.extraTraceArgs!['observedBuildPercent'], '35.0');
      expect(issue.extraTraceArgs!.containsKey('lifecyclePhase'), true);
      expect(issue.extraTraceArgs!['lifecyclePhase'], 'startup');
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
      children: List.generate(leafCount, (i) => StatefulLeaf(key: ValueKey(i))),
    );
  }
}

class _PrivateStatefulTree extends StatelessWidget {
  const _PrivateStatefulTree({required this.leafCount});
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(leafCount, (i) => _PrivateLeaf(key: ValueKey(i))),
    );
  }
}

class _RebuildLeafTree extends StatelessWidget {
  const _RebuildLeafTree({required this.leafCount});
  final int leafCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(leafCount, (i) => _RebuildLeaf(key: ValueKey(i))),
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
