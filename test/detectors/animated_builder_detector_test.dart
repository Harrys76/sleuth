import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/animated_builder_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

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
        contains('AnimatedBuilder without child'),
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
