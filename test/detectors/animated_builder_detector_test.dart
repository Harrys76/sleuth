import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/animated_builder_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/rebuild_capture_helpers.dart';

void main() {
  group('AnimatedBuilderDetector', () {
    late AnimatedBuilderDetector detector;

    setUp(() {
      detector = AnimatedBuilderDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;

      await tester.pumpWidget(const TestAnimatedApp(useChild: false));
      detector.scanTree(tester.element(find.byType(TestAnimatedApp)));

      expect(detector.issues, isEmpty);
    });

    testWidgets('flags AnimatedBuilder without child param', (tester) async {
      await tester.pumpWidget(const TestAnimatedApp(useChild: false));
      detector.scanTree(tester.element(find.byType(TestAnimatedApp)));

      expect(detector.issues, isNotEmpty);
      expect(
        detector.issues.first.title,
        contains('without child'),
      );
    });

    testWidgets('no issues when AnimatedBuilder uses child', (tester) async {
      await tester.pumpWidget(const TestAnimatedApp(useChild: true));
      detector.scanTree(tester.element(find.byType(TestAnimatedApp)));

      expect(detector.issues, isEmpty);
    });

    testWidgets('ignores small subtrees (<=50 widgets)', (tester) async {
      await tester.pumpWidget(const TinyAnimatedBuilder());
      detector.scanTree(tester.element(find.byType(TinyAnimatedBuilder)));

      expect(detector.issues, isEmpty);
    });

    testWidgets('ignores medium subtrees at threshold boundary',
        (tester) async {
      await tester.pumpWidget(const MediumAnimatedBuilder());
      detector.scanTree(tester.element(find.byType(MediumAnimatedBuilder)));

      expect(detector.issues, isEmpty,
          reason: 'Subtree of ~15 widgets should not trigger (threshold 50)');
    });

    testWidgets('no false positive on scroll page without AnimatedBuilder', (
      tester,
    ) async {
      await tester.pumpWidget(const ScrollPageNoAnimatedBuilder());
      detector.scanTree(
        tester.element(find.byType(ScrollPageNoAnimatedBuilder)),
      );

      // Framework-internal AnimatedBuilders (from Scaffold, scroll widgets)
      // should be filtered out — no user AnimatedBuilder exists here.
      expect(detector.issues, isEmpty);
    });

    test('dispose clears issues', () {
      detector.dispose();
      expect(detector.issues, isEmpty);
    });

    group('debug rebuild evidence', () {
      testWidgets('detail includes rebuild rate when high', (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'AnimatedBuilder': 60},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(const TestAnimatedApp(useChild: false));
        detector.scanTree(tester.element(find.byType(TestAnimatedApp)));

        expect(detector.issues, isNotEmpty);
        expect(
          detector.issues.first.detail,
          contains('AnimatedBuilder rebuilding at 60/sec'),
        );
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallbackAndStructural);
      });

      testWidgets('confidence upgrades to likely with high rebuild rate',
          (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'AnimatedBuilder': 60},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(const TestAnimatedApp(useChild: false));
        detector.scanTree(tester.element(find.byType(TestAnimatedApp)));

        expect(detector.issues.first.confidence, IssueConfidence.likely);
      });

      testWidgets('confidence stays possible with low rebuild rate',
          (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'AnimatedBuilder': 10},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(const TestAnimatedApp(useChild: false));
        detector.scanTree(tester.element(find.byType(TestAnimatedApp)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
        expect(detector.issues.first.observationSource, isNull);
      });

      testWidgets('confidence is possible without debug snapshot',
          (tester) async {
        await tester.pumpWidget(const TestAnimatedApp(useChild: false));
        detector.scanTree(tester.element(find.byType(TestAnimatedApp)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
      });

      testWidgets('debug evidence includes paint rate when high',
          (tester) async {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'AnimatedBuilder': 60},
          totalPaintCount: 40,
          elapsed: Duration(seconds: 1),
          paintCounts: {'AnimatedBuilder': 40},
        ));

        await tester.pumpWidget(const TestAnimatedApp(useChild: false));
        detector.scanTree(tester.element(find.byType(TestAnimatedApp)));

        expect(detector.issues, isNotEmpty);
        expect(
          detector.issues.first.detail,
          contains('painting at 40/sec'),
        );
      });
    });

    // -----------------------------------------------------------------
    // Custom thresholds
    // -----------------------------------------------------------------

    testWidgets('custom minSubtreeSize lowers detection threshold',
        (tester) async {
      // MediumAnimatedBuilder has 15-child subtree (Column + 15 SizedBox).
      // Default threshold (50) ignores it, but minSubtreeSize: 5 fires.
      detector = AnimatedBuilderDetector(minSubtreeSize: 5);
      await tester.pumpWidget(const MediumAnimatedBuilder());
      detector.scanTree(tester.element(find.byType(MediumAnimatedBuilder)));

      expect(detector.issues, isNotEmpty);
    });

    testWidgets('default minSubtreeSize ignores medium subtrees',
        (tester) async {
      // MediumAnimatedBuilder has 15-child subtree — below default 50.
      await tester.pumpWidget(const MediumAnimatedBuilder());
      detector.scanTree(tester.element(find.byType(MediumAnimatedBuilder)));

      expect(detector.issues, isEmpty);
    });

    // -----------------------------------------------------------------
    // v11.10: TweenAnimationBuilder detection
    // -----------------------------------------------------------------

    group('TweenAnimationBuilder detection', () {
      testWidgets('flags TweenAnimationBuilder without child', (tester) async {
        await tester.pumpWidget(const TestTweenBuilder(useChild: false));
        detector.scanTree(tester.element(find.byType(TestTweenBuilder)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.title, contains('TweenAnimationBuilder'));
        expect(detector.issues.first.title, contains('without child'));
      });

      testWidgets('no issue when TweenAnimationBuilder uses child',
          (tester) async {
        await tester.pumpWidget(const TestTweenBuilder(useChild: true));
        detector.scanTree(tester.element(find.byType(TestTweenBuilder)));

        expect(detector.issues, isEmpty);
      });

      testWidgets(
          'not blocked by isFrameworkOwned inside Scaffold-like ancestor',
          (tester) async {
        // TweenAnimationBuilder extends ImplicitlyAnimatedWidget, which
        // isFrameworkWidget() classifies as framework-owned. Wrapping it in
        // another StatefulWidget that IS framework-owned (ScrollView, etc.)
        // should NOT suppress detection.
        await tester.pumpWidget(const TweenBuilderInsideFrameworkWidget());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty,
            reason: 'TweenAnimationBuilder should be detected even inside '
                'framework-owned ancestors');
      });

      testWidgets('ignores small TweenAnimationBuilder subtrees',
          (tester) async {
        await tester.pumpWidget(const TinyTweenBuilder());
        detector.scanTree(tester.element(find.byType(TinyTweenBuilder)));

        expect(detector.issues, isEmpty);
      });
    });

    // -----------------------------------------------------------------
    // M11: Anti-tautology — drive rebuilds through the real
    // DebugInstrumentationCoordinator pipeline and feed the resulting
    // snapshot to the detector. Catches any divergence between the
    // hand-rolled fixtures above and what production actually emits.
    // -----------------------------------------------------------------

    group('real widget tree (anti-tautology)', () {
      testWidgets(
          'real debug snapshot upgrades AnimatedBuilder confidence to likely',
          (tester) async {
        final key = GlobalKey<ManualAnimatedWidgetState>();
        await tester.pumpWidget(ManualAnimatedWidget(key: key, childCount: 60));

        // 40 real notifier ticks — each one fires a rebuild-dirty-widget
        // callback for AnimatedBuilder's StatefulElement.
        final snapshot = await captureRebuildsViaTrigger(
          tester: tester,
          trigger: () async => key.currentState!.tick(),
          scanRoot: find.byType(ManualAnimatedWidget),
          iterations: 40,
        );

        expect(snapshot.source, RebuildCountSource.debugCallback);
        expect(snapshot.rebuildCounts['AnimatedBuilder'], greaterThan(0),
            reason: 'coordinator pipeline must record AnimatedBuilder '
                'rebuilds from the real setState path');
        expect(snapshot.rebuildsPerSecond('AnimatedBuilder'), greaterThan(30),
            reason: 'detector requires >30/sec to upgrade confidence');

        detector.updateDebugSnapshot(snapshot);
        detector.scanTree(tester.element(find.byType(ManualAnimatedWidget)));

        expect(detector.issues, isNotEmpty);
        final issue = detector.issues.first;
        expect(issue.title, contains('AnimatedBuilder'));
        expect(issue.confidence, IssueConfidence.likely);
        expect(issue.observationSource,
            ObservationSource.debugCallbackAndStructural);
        expect(issue.detail, contains('rebuilding at'));
      });
    });
  });
}

// --- Test widgets (public names so isFrameworkOwned returns false) ---

class TestAnimatedApp extends StatefulWidget {
  const TestAnimatedApp({super.key, required this.useChild});

  final bool useChild;

  @override
  State<TestAnimatedApp> createState() => TestAnimatedAppState();
}

class TestAnimatedAppState extends State<TestAnimatedApp>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: AnimatedBuilder(
        animation: controller,
        child: widget.useChild
            ? Column(
                children: List.generate(
                  51,
                  (i) => SizedBox(key: ValueKey(i), height: 10),
                ),
              )
            : null,
        builder: (context, child) {
          if (child != null) return child;
          return Column(
            children: List.generate(
              51,
              (i) => SizedBox(key: ValueKey(i), height: 10),
            ),
          );
        },
      ),
    );
  }
}

class TinyAnimatedBuilder extends StatefulWidget {
  const TinyAnimatedBuilder({super.key});

  @override
  State<TinyAnimatedBuilder> createState() => TinyAnimatedBuilderState();
}

class TinyAnimatedBuilderState extends State<TinyAnimatedBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          return const SizedBox(width: 10, height: 10);
        },
      ),
    );
  }
}

/// Medium-sized subtree (15 children) — should NOT trigger at threshold 20.
class MediumAnimatedBuilder extends StatefulWidget {
  const MediumAnimatedBuilder({super.key});

  @override
  State<MediumAnimatedBuilder> createState() => MediumAnimatedBuilderState();
}

class MediumAnimatedBuilderState extends State<MediumAnimatedBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          return Column(
            children: List.generate(
              15,
              (i) => SizedBox(key: ValueKey(i), height: 10),
            ),
          );
        },
      ),
    );
  }
}

/// A scroll-heavy page with NO user AnimatedBuilder.
/// Any AnimatedBuilder found here is framework-internal and should be ignored.
class ScrollPageNoAnimatedBuilder extends StatelessWidget {
  const ScrollPageNoAnimatedBuilder({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SingleChildScrollView(
        child: Column(
          children: List.generate(
            30,
            (i) => SizedBox(key: ValueKey(i), height: 10),
          ),
        ),
      ),
    );
  }
}

// --- v11.10: TweenAnimationBuilder test widgets ---

class TestTweenBuilder extends StatelessWidget {
  const TestTweenBuilder({super.key, required this.useChild});
  final bool useChild;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(seconds: 1),
        child: useChild
            ? Column(
                children: List.generate(
                  51,
                  (i) => SizedBox(key: ValueKey(i), height: 10),
                ),
              )
            : null,
        builder: (context, value, child) {
          if (child != null) return child;
          return Column(
            children: List.generate(
              51,
              (i) => SizedBox(key: ValueKey(i), height: 10),
            ),
          );
        },
      ),
    );
  }
}

class TinyTweenBuilder extends StatelessWidget {
  const TinyTweenBuilder({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(seconds: 1),
        builder: (context, value, child) {
          return const SizedBox(width: 10, height: 10);
        },
      ),
    );
  }
}

/// TweenAnimationBuilder inside a framework-owned StatefulWidget ancestor.
/// Tests that isFrameworkOwned does NOT suppress TweenAnimationBuilder.
class TweenBuilderInsideFrameworkWidget extends StatelessWidget {
  const TweenBuilderInsideFrameworkWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SingleChildScrollView(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(seconds: 1),
          builder: (context, value, child) {
            return Column(
              children: List.generate(
                51,
                (i) => SizedBox(key: ValueKey(i), height: 10),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// M11: Manually-driven AnimatedBuilder — a ValueNotifier replaces the
/// auto-ticking AnimationController so the anti-tautology test can drive a
/// known number of real rebuilds through the framework's rebuild-dirty-widget
/// callback instead of relying on a ticker that doesn't advance the same way
/// under `flutter_test`.
///
/// Public name + public state class so [AnimatedBuilderDetector.isFrameworkOwned]
/// classifies it as user code and the `_frameworkWidgetNames` filter in
/// [RebuildDetector] doesn't drop its rebuilds.
class ManualAnimatedWidget extends StatefulWidget {
  const ManualAnimatedWidget({super.key, required this.childCount});

  /// Size of the leaf subtree under the AnimatedBuilder. Must exceed
  /// [AnimatedBuilderDetector.minSubtreeSize] (default 50) for the detector
  /// to flag the no-child usage.
  final int childCount;

  @override
  State<ManualAnimatedWidget> createState() => ManualAnimatedWidgetState();
}

class ManualAnimatedWidgetState extends State<ManualAnimatedWidget> {
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);

  /// Bump the notifier — AnimatedBuilder listens to it and rebuilds on the
  /// next frame. Called from the test via `GlobalKey.currentState!.tick()`.
  void tick() => _tick.value++;

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: AnimatedBuilder(
        animation: _tick,
        builder: (context, _) => Column(
          children: List.generate(
            widget.childCount,
            (i) => SizedBox(key: ValueKey(i), height: 1),
          ),
        ),
      ),
    );
  }
}
