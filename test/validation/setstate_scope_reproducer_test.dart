// Hermetic reproducer for [SetStateScopeDetector].
//
// Pins `setstate_scope` via real tree + `scanTree`-equivalent walks
// (anti-tautology). Emission requires observed rebuilds: the
// two-scan path mounts a public StatefulWidget that owns most of the
// tree, scans, triggers a real `setState`, pumps, and scans again so
// child-identity churn crosses `rebuildEvidenceThreshold`. A debug-callback
// DebugSnapshot naming the owner is the other accepted evidence;
// timeline-sourced snapshots are not.
//
// Thresholds are tuned down (`minSubtreeSize: 1`,
// `rebuildEvidenceThreshold: 1`) so small hermetic trees cross. The
// tuning tests classification SEMANTICS, not threshold VALUES —
// production defaults (50 / 0.5 / 2) stay as-is.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/sleuth.dart' show IssueConfidence, IssueSeverity;
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/setstate_scope_detector.dart';

import '_helpers/structural_reproducer_harness.dart';

/// Public-named StatefulWidget whose `build()` output is rebuilt (new
/// widget instance) on every [ChurnStatefulState.bump].
class ChurnStateful extends StatefulWidget {
  const ChurnStateful({super.key, required this.builder});
  final Widget Function(int generation) builder;
  @override
  State<ChurnStateful> createState() => ChurnStatefulState();
}

class ChurnStatefulState extends State<ChurnStateful> {
  int _generation = 0;
  void bump() => setState(() => _generation++);
  @override
  Widget build(BuildContext context) => widget.builder(_generation);
}

/// Private-named twin — detector filter `!name.startsWith('_')` must skip
/// it as a candidate.
class _PrivateChurn extends StatefulWidget {
  // ignore: unused_element_parameter
  const _PrivateChurn({super.key, required this.builder});
  final Widget Function(int generation) builder;
  @override
  State<_PrivateChurn> createState() => _PrivateChurnState();
}

class _PrivateChurnState extends State<_PrivateChurn> {
  int _generation = 0;
  void bump() => setState(() => _generation++);
  @override
  Widget build(BuildContext context) => widget.builder(_generation);
}

/// Dummy listenable so AnimatedBuilder does not require a ticker.
class _StaticListenable extends Listenable {
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

Widget _eightLeaves(int generation) => Column(
  children: [
    SizedBox(key: ValueKey('g$generation')),
    for (int i = 0; i < 7; i++) SizedBox(key: ValueKey(i)),
  ],
);

void main() {
  group('SetStateScopeDetector reproducer', () {
    // --- setstate_scope (two-scan churn) -------------------------------

    testWidgets('setstate_scope: two-scan churn on a wide owner fires '
        '(warning, likely)', (tester) async {
      // 8 mutable owner-subtree elements of 13 → ratio ~0.62: above the
      // 0.5 threshold, at or below the 0.75 critical ratio. (The owner
      // element keeps its widget instance, so it counts as const.)
      final key = GlobalKey<ChurnStatefulState>();
      final detector = SetStateScopeDetector(
        minSubtreeSize: 1,
        rebuildEvidenceThreshold: 1,
      );
      final first = await scanAndIssues(
        tester,
        detector,
        Column(
          children: [
            ChurnStateful(key: key, builder: _eightLeaves),
            for (int i = 0; i < 2; i++) SizedBox(key: ValueKey('pad$i')),
          ],
        ),
      );
      expect(
        first,
        lacksStableId('setstate_scope'),
        reason: 'One scan has no rebuild evidence.',
      );

      key.currentState!.bump();
      await tester.pump();
      final issues = rescanIssues(tester, detector);

      expect(issues, hasStableId('setstate_scope'));
      final issue = issues.firstWhere((i) => i.stableId == 'setstate_scope');
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.confidence, IssueConfidence.likely);
    });

    testWidgets('setstate_scope: churn above 1.5× the ratio threshold is '
        'critical', (tester) async {
      // 9 mutable owner-subtree elements of 10 → ratio 0.9 > 0.75.
      final key = GlobalKey<ChurnStatefulState>();
      final detector = SetStateScopeDetector(
        minSubtreeSize: 1,
        rebuildEvidenceThreshold: 1,
      );
      await scanAndIssues(
        tester,
        detector,
        ChurnStateful(key: key, builder: _eightLeaves),
      );
      key.currentState!.bump();
      await tester.pump();
      final issues = rescanIssues(tester, detector);

      final issue = issues.firstWhere((i) => i.stableId == 'setstate_scope');
      expect(issue.severity, IssueSeverity.critical);
    });

    testWidgets('setstate_scope: wide owner without rebuilds stays silent', (
      tester,
    ) async {
      final detector = SetStateScopeDetector(
        minSubtreeSize: 1,
        rebuildEvidenceThreshold: 1,
      );
      await scanAndIssues(
        tester,
        detector,
        const ChurnStateful(builder: _eightLeaves),
      );
      final issues = rescanIssues(tester, detector);
      expect(issues, lacksStableId('setstate_scope'));
    });

    testWidgets('setstate_scope: no user StatefulWidget → silent', (
      tester,
    ) async {
      // Stateless-only tree has no StatefulElement candidate; `_widestElement`
      // stays null and finalizeScan early-returns before ratio check.
      final detector = SetStateScopeDetector(
        minSubtreeSize: 1,
        rebuildEvidenceThreshold: 1,
      );
      final issues = await scanAndIssues(
        tester,
        detector,
        Column(children: List.generate(8, (i) => SizedBox(key: ValueKey(i)))),
      );
      expect(issues, lacksStableId('setstate_scope'));
    });

    testWidgets('setstate_scope: private-named StatefulWidget skipped '
        '(filter `!name.startsWith("_")`)', (tester) async {
      final key = GlobalKey<_PrivateChurnState>();
      final detector = SetStateScopeDetector(
        minSubtreeSize: 1,
        rebuildEvidenceThreshold: 1,
      );
      await scanAndIssues(
        tester,
        detector,
        _PrivateChurn(key: key, builder: _eightLeaves),
      );
      key.currentState!.bump();
      await tester.pump();
      final issues = rescanIssues(tester, detector);
      expect(issues, lacksStableId('setstate_scope'));
    });

    testWidgets('setstate_scope: subtree below minSubtreeSize silent '
        '(guard: `_maxSubtreeSize < minSubtreeSize`)', (tester) async {
      final key = GlobalKey<ChurnStatefulState>();
      final detector = SetStateScopeDetector(
        minSubtreeSize: 50,
        rebuildEvidenceThreshold: 1,
      );
      await scanAndIssues(
        tester,
        detector,
        ChurnStateful(key: key, builder: _eightLeaves),
      );
      key.currentState!.bump();
      await tester.pump();
      final issues = rescanIssues(tester, detector);
      expect(issues, lacksStableId('setstate_scope'));
    });

    testWidgets('setstate_scope: churn with AnimatedBuilder in subtree '
        'drops to possible', (tester) async {
      final key = GlobalKey<ChurnStatefulState>();
      final detector = SetStateScopeDetector(
        minSubtreeSize: 1,
        rebuildEvidenceThreshold: 1,
      );
      await scanAndIssues(
        tester,
        detector,
        ChurnStateful(
          key: key,
          builder: (g) => AnimatedBuilder(
            animation: _StaticListenable(),
            builder: (_, _) => _eightLeaves(g),
          ),
        ),
      );
      key.currentState!.bump();
      await tester.pump();
      final issues = rescanIssues(tester, detector);

      final issue = issues.firstWhere((i) => i.stableId == 'setstate_scope');
      expect(issue.confidence, IssueConfidence.possible);
    });

    testWidgets('setstate_scope: churn with generic '
        '`ValueListenableBuilder<int>` in subtree drops to possible '
        '(canonicalization pin)', (tester) async {
      // `_containsAnimationScope` falls back to a name-equality check for
      // `ListenableBuilder` / `ValueListenableBuilder`. Production runtime
      // types arrive as `ValueListenableBuilder<int>` etc.; without
      // canonicalization the animation scope is missed → likely.
      final key = GlobalKey<ChurnStatefulState>();
      final detector = SetStateScopeDetector(
        minSubtreeSize: 1,
        rebuildEvidenceThreshold: 1,
      );
      final notifier = ValueNotifier<int>(0);
      addTearDown(notifier.dispose);
      await scanAndIssues(
        tester,
        detector,
        ChurnStateful(
          key: key,
          builder: (g) => ValueListenableBuilder<int>(
            valueListenable: notifier,
            builder: (_, _, _) => _eightLeaves(g),
          ),
        ),
      );
      key.currentState!.bump();
      await tester.pump();
      final issues = rescanIssues(tester, detector);

      final issue = issues.firstWhere((i) => i.stableId == 'setstate_scope');
      expect(issue.confidence, IssueConfidence.possible);
    });

    testWidgets('setstate_scope: FutureBuilder owner never emits', (
      tester,
    ) async {
      final completer = Completer<int>();
      final detector = SetStateScopeDetector(
        minSubtreeSize: 1,
        rebuildEvidenceThreshold: 1,
      );
      await scanAndIssues(
        tester,
        detector,
        FutureBuilder<int>(
          future: completer.future,
          builder: (_, snap) => _eightLeaves(snap.data ?? 0),
        ),
      );
      final before = tester.widget(find.byType(Column));
      completer.complete(1);
      await tester.pump();
      await tester.pump();
      expect(
        identical(tester.widget(find.byType(Column)), before),
        isFalse,
        reason: 'FutureBuilder must have rebuilt its subtree.',
      );
      final issues = rescanIssues(tester, detector);
      expect(issues, lacksStableId('setstate_scope'));
    });

    testWidgets('setstate_scope: debug-callback snapshot naming the owner '
        'fires confirmed; a timeline snapshot does not', (tester) async {
      DebugSnapshot snapshot(RebuildCountSource source) => DebugSnapshot(
        rebuildCounts: const {'ChurnStateful': 3},
        totalPaintCount: 0,
        elapsed: const Duration(seconds: 1),
        source: source,
      );

      final timeline = SetStateScopeDetector(
        minSubtreeSize: 1,
        rebuildEvidenceThreshold: 1,
      )..updateDebugSnapshot(snapshot(RebuildCountSource.flutterTimeline));
      final silent = await scanAndIssues(
        tester,
        timeline,
        const ChurnStateful(builder: _eightLeaves),
      );
      expect(silent, lacksStableId('setstate_scope'));

      final callback = SetStateScopeDetector(
        minSubtreeSize: 1,
        rebuildEvidenceThreshold: 1,
      )..updateDebugSnapshot(snapshot(RebuildCountSource.debugCallback));
      final issues = rescanIssues(tester, callback);
      expect(issues, hasStableId('setstate_scope'));
      final issue = issues.firstWhere((i) => i.stableId == 'setstate_scope');
      expect(issue.confidence, IssueConfidence.confirmed);
    });
  });
}
