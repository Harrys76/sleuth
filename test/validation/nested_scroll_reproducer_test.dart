// Hermetic reproducer for [NestedScrollDetector].
//
// Pins two stableIds via real `scanTree(root)` on a `pumpWidget` tree
// (anti-tautology, Tactic 9). All scenarios configure the detector
// with `childThreshold: 3` so boundary tests run on small trees.
//
//   - `nested_scroll` — SingleChildScrollView inside another scrollable
//     (same axis) whose child Column/Row exceeds childThreshold.
//   - `nested_scroll_same_axis` — any other scrollable (ListView,
//     GridView, CustomScrollView, or small SingleChildScrollView)
//     nested inside another scrollable on the same axis.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/src/detectors/nested_scroll_detector.dart';

import '_helpers/structural_reproducer_harness.dart';

void main() {
  group('NestedScrollDetector reproducer', () {
    // --- nested_scroll (SingleChildScrollView + Column > threshold) ----

    testWidgets(
        'nested_scroll: inner SCS+Column with 4 children fires '
        '(childThreshold:3, `>` not `>=`)', (tester) async {
      final detector = NestedScrollDetector(childThreshold: 3);
      final issues = await scanAndIssues(
        tester,
        detector,
        SingleChildScrollView(
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                  4, (i) => SizedBox(key: ValueKey(i), height: 10)),
            ),
          ),
        ),
      );
      expect(issues, hasStableId('nested_scroll'));
    });

    testWidgets(
        'nested_scroll: inner SCS+Column with 3 children silent '
        '(at threshold — strict-greater)', (tester) async {
      final detector = NestedScrollDetector(childThreshold: 3);
      final issues = await scanAndIssues(
        tester,
        detector,
        SingleChildScrollView(
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                  3, (i) => SizedBox(key: ValueKey(i), height: 10)),
            ),
          ),
        ),
      );
      expect(issues, lacksStableId('nested_scroll'));
    });

    testWidgets('nested_scroll: single non-nested scrollable silent',
        (tester) async {
      final detector = NestedScrollDetector(childThreshold: 3);
      final issues = await scanAndIssues(
        tester,
        detector,
        SingleChildScrollView(
          child: Column(
            children:
                List.generate(5, (i) => SizedBox(key: ValueKey(i), height: 10)),
          ),
        ),
      );
      expect(issues, lacksStableId('nested_scroll'));
      expect(issues, lacksStableId('nested_scroll_same_axis'));
    });

    // --- nested_scroll_same_axis (other scrollable nesting) ------------

    testWidgets('nested_scroll_same_axis: ListView inside SCS fires',
        (tester) async {
      final detector = NestedScrollDetector(childThreshold: 3);
      final issues = await scanAndIssues(
        tester,
        detector,
        SingleChildScrollView(
          child: SizedBox(
            height: 200,
            child: ListView(
              children: const [SizedBox(height: 10), SizedBox(height: 10)],
            ),
          ),
        ),
      );
      expect(issues, hasStableId('nested_scroll_same_axis'));
    });

    testWidgets(
        'nested_scroll_same_axis: cross-axis nesting silent '
        '(horizontal ListView inside vertical SCS)', (tester) async {
      final detector = NestedScrollDetector(childThreshold: 3);
      final issues = await scanAndIssues(
        tester,
        detector,
        SingleChildScrollView(
          child: SizedBox(
            height: 100,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: const [SizedBox(width: 10), SizedBox(width: 10)],
            ),
          ),
        ),
      );
      expect(issues, lacksStableId('nested_scroll'));
      expect(issues, lacksStableId('nested_scroll_same_axis'));
    });

    testWidgets(
        'nested_scroll_same_axis: inner with NeverScrollableScrollPhysics '
        'silent (intentional scroll delegation)', (tester) async {
      final detector = NestedScrollDetector(childThreshold: 3);
      final issues = await scanAndIssues(
        tester,
        detector,
        SingleChildScrollView(
          child: SizedBox(
            height: 200,
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              children: const [SizedBox(height: 10), SizedBox(height: 10)],
            ),
          ),
        ),
      );
      expect(issues, lacksStableId('nested_scroll'));
      expect(issues, lacksStableId('nested_scroll_same_axis'));
    });
  });
}
