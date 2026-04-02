import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/debug/debug_snapshot.dart';
import 'package:widget_watchdog/src/detectors/setstate_scope_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

void main() {
  group('SetStateScopeDetector', () {
    late SetStateScopeDetector detector;

    setUp(() {
      detector = SetStateScopeDetector();
    });

    test('default threshold is 0.5', () {
      expect(detector.dirtyRatioThreshold, 0.5);
    });

    test('default minSubtreeSize is 50', () {
      expect(detector.minSubtreeSize, 50);
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;

      await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
      detector.scanTree(tester.element(find.byType(_Wrapper)));

      expect(detector.issues, isEmpty);
    });

    testWidgets('flags StatefulWidget owning large portion of tree', (
      tester,
    ) async {
      detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.3,
        minSubtreeSize: 3,
      );

      // _Wrapper is the scan root; LargePageWidget is a child StatefulWidget
      await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
      detector.scanTree(tester.element(find.byType(_Wrapper)));

      expect(detector.issues, isNotEmpty);
      expect(detector.issues.first.title, contains('Wide setState Scope'));
      expect(detector.issues.first.widgetName, 'LargePageWidget');
    });

    testWidgets('no issues for small StatefulWidget subtree', (tester) async {
      await tester.pumpWidget(const _Wrapper(child: SmallStateful()));
      detector.scanTree(tester.element(find.byType(_Wrapper)));

      // minSubtreeSize=50 prevents flagging small trees
      expect(detector.issues, isEmpty);
    });

    testWidgets('no issues when ratio is below threshold', (tester) async {
      detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.99,
        minSubtreeSize: 1,
      );

      await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
      detector.scanTree(tester.element(find.byType(_Wrapper)));

      expect(detector.issues, isEmpty);
    });

    testWidgets('no false positive for scroll-heavy page', (tester) async {
      detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.3,
        minSubtreeSize: 3,
      );

      await tester.pumpWidget(const _Wrapper(child: ScrollHeavyPage()));
      detector.scanTree(tester.element(find.byType(_Wrapper)));

      // Scrollable/SingleChildScrollView are framework widgets — should not
      // be flagged even though they own a large subtree.
      expect(detector.issues, isEmpty);
    });

    testWidgets('highlights align with issues when flagged', (tester) async {
      detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.3,
        minSubtreeSize: 3,
      );

      await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
      detector.scanTree(tester.element(find.byType(_Wrapper)));

      expect(detector.issues, isNotEmpty);
      expect(detector.highlights, isNotEmpty);
      expect(detector.highlights.length, detector.issues.length);
      expect(detector.highlights.first.detectorName, 'setState');
    });

    testWidgets('no highlights when no issues', (tester) async {
      await tester.pumpWidget(const _Wrapper(child: SmallStateful()));
      detector.scanTree(tester.element(find.byType(_Wrapper)));

      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    test('dispose clears issues and highlights', () {
      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    group('debug correlation', () {
      testWidgets(
          'upgrades to confirmed when type is unique and appears in rebuildCounts',
          (tester) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'LargePageWidget': 15},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        // Only one LargePageWidget instance on screen
        await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
        detector.scanTree(tester.element(find.byType(_Wrapper)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
      });

      testWidgets(
          'caps at likely when multiple instances of flagged type exist',
          (tester) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'LargePageWidget': 15},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        // Two instances of LargePageWidget
        await tester.pumpWidget(
          const _Wrapper(
            child: Column(
              children: [
                LargePageWidget(),
                LargePageWidget(),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(_Wrapper)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.likely);
      });

      testWidgets('stays possible when type not in rebuildCounts',
          (tester) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'SomeOtherWidget': 15},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
        detector.scanTree(tester.element(find.byType(_Wrapper)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
      });

      testWidgets('stays possible when no debug data available',
          (tester) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        // No updateDebugSnapshot called
        await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
        detector.scanTree(tester.element(find.byType(_Wrapper)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
        expect(detector.issues.first.observationSource,
            ObservationSource.structural);
      });

      testWidgets(
          'observationSource set to debugCallbackAndStructural on upgrade',
          (tester) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'LargePageWidget': 15},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
        detector.scanTree(tester.element(find.byType(_Wrapper)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallbackAndStructural);
      });
    });

    group('abort safety', () {
      testWidgets('no issues emitted when walk aborts mid-tree', (
        tester,
      ) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
        final context = tester.element(find.byType(_Wrapper));

        // Simulate partial walk: prepareScan, then abort early
        detector.prepareScan(context);
        int visited = 0;
        void partialVisitor(Element element) {
          detector.checkElement(element);
          if (visited++ > 3) return; // abort — no afterElement for remaining
          element.visitChildren(partialVisitor);
          detector.afterElement(element);
        }

        try {
          context.visitChildElements(partialVisitor);
        } catch (_) {}
        detector.finalizeScan();

        // Stack was not fully drained → finalizeScan should bail out
        expect(detector.issues, isEmpty);
      });

      testWidgets('rebuild baseline preserved after aborted walk', (
        tester,
      ) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        // Phase 1: Complete scan to establish snapshot baseline
        await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
        final context = tester.element(find.byType(_Wrapper));
        detector.scanTree(context);

        // Phase 2: Aborted scan — should NOT overwrite _childSnapshots
        detector.prepareScan(context);
        int visited = 0;
        void partialVisitor(Element element) {
          detector.checkElement(element);
          if (visited++ > 3) return;
          element.visitChildren(partialVisitor);
          detector.afterElement(element);
        }

        try {
          context.visitChildElements(partialVisitor);
        } catch (_) {}
        detector.finalizeScan();

        // Phase 3: Full scan should still detect issues (baseline intact)
        detector.scanTree(context);
        expect(detector.issues, isNotEmpty);
      });
    });

    group('clearSnapshots retention fix', () {
      testWidgets('clearSnapshots nulls widest-widget state', (tester) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        // Phase 1: Scan a large tree — detector accumulates widest state
        await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
        detector.scanTree(tester.element(find.byType(_Wrapper)));
        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.widgetName, 'LargePageWidget');

        // Phase 2: Simulate navigation abort — clearSnapshots called
        detector.clearSnapshots();

        // Phase 3: Scan a DIFFERENT small tree — must not see stale state
        await tester.pumpWidget(const _Wrapper(child: SmallStateful()));
        detector.scanTree(tester.element(find.byType(_Wrapper)));

        // SmallStateful is below minSubtreeSize → no issues.
        expect(detector.issues, isEmpty);
      });
    });
  });
}

// --- Test widgets ---

/// Scan root wrapper — not a StatefulWidget, just provides Directionality.
class _Wrapper extends StatelessWidget {
  const _Wrapper({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Directionality(textDirection: TextDirection.ltr, child: child);
  }
}

/// Public-name StatefulWidget with a large subtree (the anti-pattern).
class LargePageWidget extends StatefulWidget {
  const LargePageWidget({super.key});

  @override
  State<LargePageWidget> createState() => _LargePageWidgetState();
}

class _LargePageWidgetState extends State<LargePageWidget> {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        30,
        (i) => SizedBox(key: ValueKey(i), height: 10),
      ),
    );
  }
}

class SmallStateful extends StatefulWidget {
  const SmallStateful({super.key});

  @override
  State<SmallStateful> createState() => _SmallStatefulState();
}

class _SmallStatefulState extends State<SmallStateful> {
  @override
  Widget build(BuildContext context) {
    return const SizedBox(width: 10, height: 10);
  }
}

/// A page with only scroll framework widgets owning large subtrees.
/// No user StatefulWidget — should NOT trigger the detector.
class ScrollHeavyPage extends StatelessWidget {
  const ScrollHeavyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: List.generate(
          30,
          (i) => SizedBox(key: ValueKey(i), height: 10),
        ),
      ),
    );
  }
}
