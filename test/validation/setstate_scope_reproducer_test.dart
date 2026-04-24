// Hermetic reproducer for [SetStateScopeDetector].
//
// Pins `setstate_scope` via real tree + `scanTree(root)` (anti-tautology,
// Tactic 9). Covers the STRUCTURAL / possible-confidence path only:
// ratio > dirtyRatioThreshold AND _maxSubtreeSize > minSubtreeSize AND
// no rebuild evidence AND no animation scope. The DebugSnapshot
// confidence-upgrade path (→ confirmed / likely) is NOT exercised here —
// documented in the detector validation rationale as a known coverage
// gap for reproducerOnly tier.
//
// Thresholds are tuned down (`minSubtreeSize: 1`,
// `dirtyRatioThreshold: 0.1`) so small hermetic trees cross. The
// tuning tests classification SEMANTICS, not threshold VALUES —
// production defaults (50 / 0.5) stay as-is.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/sleuth.dart' show IssueConfidence, IssueSeverity;
import 'package:sleuth/src/detectors/setstate_scope_detector.dart';

import '_helpers/structural_reproducer_harness.dart';

/// Public-named StatefulWidget — detector filter
/// `!name.startsWith('_')` requires a public type for candidacy. Holds
/// a large child subtree so `_maxSubtreeSize > minSubtreeSize` crosses
/// and ratio approaches ~1.0.
class HeavyStateful extends StatefulWidget {
  const HeavyStateful({super.key, required this.child});
  final Widget child;
  @override
  State<HeavyStateful> createState() => _HeavyStatefulState();
}

class _HeavyStatefulState extends State<HeavyStateful> {
  @override
  Widget build(BuildContext context) => widget.child;
}

/// Private-named StatefulWidget — detector filter
/// `!name.startsWith('_')` must skip it as a candidate.
class _PrivateHeavy extends StatefulWidget {
  // ignore: unused_element_parameter
  const _PrivateHeavy({super.key, required this.child});
  final Widget child;
  @override
  State<_PrivateHeavy> createState() => _PrivateHeavyState();
}

class _PrivateHeavyState extends State<_PrivateHeavy> {
  @override
  Widget build(BuildContext context) => widget.child;
}

/// Dummy listenable so AnimatedBuilder does not require a ticker.
class _StaticListenable extends Listenable {
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

void main() {
  group('SetStateScopeDetector reproducer', () {
    // --- setstate_scope (structural / possible-confidence) -------------

    testWidgets(
        'setstate_scope: public StatefulWidget owning ~all of tree fires '
        '(structural path, possible confidence)', (tester) async {
      final detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.1,
        minSubtreeSize: 1,
      );
      final issues = await scanAndIssues(
        tester,
        detector,
        HeavyStateful(
          child: Column(
            children: List.generate(8, (i) => SizedBox(key: ValueKey(i))),
          ),
        ),
      );
      expect(issues, hasStableId('setstate_scope'));
      // Structural / no-rebuild-evidence branch → warning + possible.
      // The critical-severity branch (`hasRebuildEvidence && ratio > 0.5`)
      // is disclosed as uncovered at this tier.
      final issue = issues.firstWhere((i) => i.stableId == 'setstate_scope');
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.confidence, IssueConfidence.possible);
    });

    testWidgets('setstate_scope: no user StatefulWidget → silent',
        (tester) async {
      // Stateless-only tree has no StatefulElement candidate; `_widestElement`
      // stays null and finalizeScan early-returns before ratio check.
      final detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.1,
        minSubtreeSize: 1,
      );
      final issues = await scanAndIssues(
        tester,
        detector,
        Column(
          children: List.generate(8, (i) => SizedBox(key: ValueKey(i))),
        ),
      );
      expect(issues, lacksStableId('setstate_scope'));
    });

    testWidgets(
        'setstate_scope: private-named StatefulWidget skipped '
        '(filter `!name.startsWith("_")`)', (tester) async {
      // _PrivateHeavy is the only stateful candidate — filter skips it,
      // `_widestStatefulWidget` stays null, finalizeScan early-returns.
      final detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.1,
        minSubtreeSize: 1,
      );
      final issues = await scanAndIssues(
        tester,
        detector,
        _PrivateHeavy(
          child: Column(
            children: List.generate(8, (i) => SizedBox(key: ValueKey(i))),
          ),
        ),
      );
      expect(issues, lacksStableId('setstate_scope'));
    });

    testWidgets(
        'setstate_scope: subtree below minSubtreeSize silent '
        '(guard: `_maxSubtreeSize < minSubtreeSize`)', (tester) async {
      // Only 2 descendant elements — with minSubtreeSize=50 (production
      // default) finalizeScan early-returns before ratio check.
      final detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.1,
        minSubtreeSize: 50,
      );
      final issues = await scanAndIssues(
        tester,
        detector,
        const HeavyStateful(child: SizedBox()),
      );
      expect(issues, lacksStableId('setstate_scope'));
    });

    testWidgets(
        'setstate_scope: widest subtree contains AnimatedBuilder → '
        'suppressed (`hasAnimScope && !hasRebuildEvidence`)', (tester) async {
      // Detector's _containsAnimationScope walks up to 5 levels down and
      // treats AnimatedWidget descendants as "animation scope" —
      // structural path with no rebuild evidence is intentionally
      // suppressed to avoid false positives on animation pages.
      final detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.1,
        minSubtreeSize: 1,
      );
      final issues = await scanAndIssues(
        tester,
        detector,
        HeavyStateful(
          child: AnimatedBuilder(
            animation: _StaticListenable(),
            builder: (_, __) => Column(
              children: List.generate(8, (i) => SizedBox(key: ValueKey(i))),
            ),
          ),
        ),
      );
      expect(issues, lacksStableId('setstate_scope'));
    });
  });
}
