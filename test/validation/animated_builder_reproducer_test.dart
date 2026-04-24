// Hermetic reproducer for [AnimatedBuilderDetector].
//
// Pins `animated_builder_no_child` via real tree + `scanTree(root)`.
// Configures `minSubtreeSize: 1` so small hermetic trees cross the
// threshold (production default is 50).
//
// The detector ignores framework-owned AnimatedBuilder usage (scroll
// physics, transitions) via `isFrameworkOwned` — tests here place the
// AnimatedBuilder directly under `Directionality` so the ancestor walk
// finds no StatefulElement classified as framework-owned.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/src/detectors/animated_builder_detector.dart';

import '_helpers/structural_reproducer_harness.dart';

/// Dummy listenable so the AnimatedBuilder does not require a ticker.
class _StaticListenable extends Listenable {
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

/// User-defined StatefulWidget host — prevents `isFrameworkOwned` from
/// classifying the AnimatedBuilder as framework-owned. The detector
/// walks up to the nearest StatefulElement and the test-harness root
/// is a framework widget (`View`, etc.) which would otherwise trigger
/// suppression.
class _UserHost extends StatefulWidget {
  const _UserHost({required this.child});
  final Widget child;
  @override
  State<_UserHost> createState() => _UserHostState();
}

class _UserHostState extends State<_UserHost> {
  @override
  Widget build(BuildContext context) => widget.child;
}

void main() {
  group('AnimatedBuilderDetector reproducer', () {
    // --- animated_builder_no_child -------------------------------------

    testWidgets(
        'animated_builder_no_child: AnimatedBuilder with no child + '
        'subtree > minSubtreeSize fires', (tester) async {
      final detector = AnimatedBuilderDetector(minSubtreeSize: 1);
      final issues = await scanAndIssues(
        tester,
        detector,
        _UserHost(
          child: AnimatedBuilder(
            animation: _StaticListenable(),
            builder: (_, __) => const Column(
              children: [SizedBox(height: 10), SizedBox(height: 10)],
            ),
          ),
        ),
      );
      expect(issues, hasStableId('animated_builder_no_child'));
    });

    testWidgets('animated_builder_no_child: AnimatedBuilder WITH child silent',
        (tester) async {
      final detector = AnimatedBuilderDetector(minSubtreeSize: 1);
      final issues = await scanAndIssues(
        tester,
        detector,
        _UserHost(
          child: AnimatedBuilder(
            animation: _StaticListenable(),
            builder: (_, child) => Column(
              children: [child!, const SizedBox(height: 10)],
            ),
            child: const SizedBox(height: 20),
          ),
        ),
      );
      expect(issues, lacksStableId('animated_builder_no_child'));
    });

    testWidgets(
        'animated_builder_no_child: subtree at threshold silent '
        '(`<=` not `<` — strict-greater)', (tester) async {
      // Detector uses `if (subtreeSize <= minSubtreeSize) return;`.
      // minSubtreeSize=1 + one-child subtree (subtreeSize==1) stays silent.
      final detector = AnimatedBuilderDetector(minSubtreeSize: 1);
      final issues = await scanAndIssues(
        tester,
        detector,
        _UserHost(
          child: AnimatedBuilder(
            animation: _StaticListenable(),
            builder: (_, __) => const SizedBox(height: 10),
          ),
        ),
      );
      expect(issues, lacksStableId('animated_builder_no_child'));
    });

    testWidgets(
        'animated_builder_no_child: TweenAnimationBuilder with no child fires '
        '(ImplicitlyAnimatedWidget bypass of isFrameworkOwned)',
        (tester) async {
      final detector = AnimatedBuilderDetector(minSubtreeSize: 1);
      final issues = await scanAndIssues(
        tester,
        detector,
        _UserHost(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 100),
            builder: (_, __, ___) => const Column(
              children: [SizedBox(height: 10), SizedBox(height: 10)],
            ),
          ),
        ),
      );
      expect(issues, hasStableId('animated_builder_no_child'));
    });

    testWidgets('animated_builder_no_child: no AnimatedBuilder stays silent',
        (tester) async {
      final detector = AnimatedBuilderDetector(minSubtreeSize: 1);
      final issues = await scanAndIssues(
        tester,
        detector,
        const Column(
          children: [SizedBox(height: 10), SizedBox(height: 10)],
        ),
      );
      expect(issues, lacksStableId('animated_builder_no_child'));
    });
  });
}
