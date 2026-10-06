import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/setstate_scope_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/rebuild_capture_helpers.dart';

/// Debug snapshot naming [type] with [count] rebuilds from [source].
DebugSnapshot _snapshot(
  String type, {
  int count = 15,
  RebuildCountSource source = RebuildCountSource.debugCallback,
}) => DebugSnapshot(
  rebuildCounts: {type: count},
  totalPaintCount: 0,
  elapsed: const Duration(seconds: 1),
  source: source,
);

/// Mounts `Column([TestCounterWidget(childCount: 55), ...padding])`,
/// scans, triggers [rebuilds] real setState rebuilds with a scan after
/// each, and returns the last scan's issues.
///
/// Owner subtree: Column + 56 SizedBoxes = 57 mutable elements. Total
/// elements: outer Column + owner + 57 + [padding]. With padding 36 the
/// ratio is 57/95 = 0.6; with padding 55 it is 57/114 = 0.5.
Future<List<PerformanceIssue>> _churnScan(
  WidgetTester tester,
  SetStateScopeDetector detector, {
  required int padding,
  int rebuilds = 1,
}) async {
  final key = GlobalKey<TestCounterWidgetState>();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          TestCounterWidget(key: key, childCount: 55),
          for (int i = 0; i < padding; i++)
            SizedBox.shrink(key: ValueKey('pad$i')),
        ],
      ),
    ),
  );
  final root = tester.element(find.byType(Directionality));
  detector.scanTree(root);
  for (int i = 0; i < rebuilds; i++) {
    key.currentState!.triggerRebuild();
    await tester.pump();
    detector.scanTree(root);
  }
  return detector.issues;
}

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

    testWidgets('two-scan churn on a wide owner fires warning/likely', (
      tester,
    ) async {
      detector = SetStateScopeDetector(rebuildEvidenceThreshold: 1);

      final issues = await _churnScan(tester, detector, padding: 36);

      final issue = issues.single;
      expect(issue.title, contains('Wide setState Scope'));
      expect(issue.widgetName, 'TestCounterWidget');
      expect(
        issue.severity,
        IssueSeverity.warning,
        reason: 'ratio 0.6 is above 0.5 but not above 1.5 × 0.5 = 0.75',
      );
      expect(issue.confidence, IssueConfidence.likely);
    });

    testWidgets('structural ratio alone never emits', (tester) async {
      // Default thresholds; owner holds 57 of 59 elements (ratio ~0.97)
      // across two scans with no rebuild in between.
      final key = GlobalKey<TestCounterWidgetState>();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: TestCounterWidget(key: key, childCount: 55),
        ),
      );
      final root = tester.element(find.byType(Directionality));
      detector.scanTree(root);
      detector.scanTree(root);
      expect(detector.issues, isEmpty);

      // Control: the same page emits once rebuilds are observed (default
      // rebuildEvidenceThreshold is 2 churns in the window).
      for (int i = 0; i < 2; i++) {
        key.currentState!.triggerRebuild();
        await tester.pump();
        detector.scanTree(root);
      }
      expect(detector.issues, hasLength(1));
    });

    testWidgets('one churn is below the default evidence threshold', (
      tester,
    ) async {
      final issues = await _churnScan(tester, detector, padding: 36);
      expect(issues, isEmpty);
      expect(detector.hasRebuildEvidenceFor('TestCounterWidget'), isFalse);
    });

    testWidgets('critical when the ratio exceeds 1.5 × a lowered threshold', (
      tester,
    ) async {
      detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.3,
        rebuildEvidenceThreshold: 1,
      );

      final issues = await _churnScan(tester, detector, padding: 55);

      expect(
        issues.single.severity,
        IssueSeverity.critical,
        reason: 'ratio 0.5 is above 1.5 × 0.3 = 0.45',
      );
    });

    testWidgets('FutureBuilder owner with churn never emits', (tester) async {
      detector = SetStateScopeDetector(rebuildEvidenceThreshold: 1);
      final completer = Completer<int>();

      Widget leaves(int generation) => Column(
        children: [
          SizedBox(key: ValueKey('g$generation'), height: 10),
          for (int i = 0; i < 55; i++) SizedBox(key: ValueKey(i), height: 1),
        ],
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: FutureBuilder<int>(
            future: completer.future,
            builder: (_, snap) => leaves(snap.data ?? 0),
          ),
        ),
      );
      final root = tester.element(find.byType(Directionality));
      detector.scanTree(root);
      final before = tester.widget(find.byType(Column));
      completer.complete(1);
      await tester.pump();
      await tester.pump();
      expect(
        identical(tester.widget(find.byType(Column)), before),
        isFalse,
        reason: 'FutureBuilder must have rebuilt its subtree',
      );
      detector.scanTree(root);
      expect(detector.issues, isEmpty);

      // Control: a user StatefulWidget with the same shape and churn emits.
      final issues = await _churnScan(tester, detector, padding: 0);
      expect(issues, hasLength(1));
    });

    testWidgets('no issues for small StatefulWidget subtree', (tester) async {
      detector.updateDebugSnapshot(_snapshot('SmallStateful'));
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
      detector.updateDebugSnapshot(_snapshot('LargePageWidget'));

      await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
      detector.scanTree(tester.element(find.byType(_Wrapper)));

      expect(detector.issues, isEmpty);
    });

    testWidgets('no false positive for scroll-heavy page', (tester) async {
      detector = SetStateScopeDetector(
        dirtyRatioThreshold: 0.3,
        minSubtreeSize: 3,
      );

      detector.updateDebugSnapshot(
        DebugSnapshot(
          rebuildCounts: const {'SingleChildScrollView': 5, 'Scrollable': 5},
          totalPaintCount: 0,
          elapsed: const Duration(seconds: 1),
          source: RebuildCountSource.debugCallback,
        ),
      );
      await tester.pumpWidget(const _Wrapper(child: ScrollHeavyPage()));
      detector.scanTree(tester.element(find.byType(_Wrapper)));

      // Scrollable/SingleChildScrollView are framework widgets — should not
      // be flagged even though they own a large subtree.
      expect(detector.issues, isEmpty);
    });

    testWidgets('highlights align with issues when flagged', (tester) async {
      detector = SetStateScopeDetector(rebuildEvidenceThreshold: 1);

      await _churnScan(tester, detector, padding: 36);

      expect(detector.issues, isNotEmpty);
      expect(detector.highlights, isNotEmpty);
      expect(detector.highlights.length, detector.issues.length);
      expect(detector.highlights.first.detectorName, 'setState');
      expect(
        detector.highlights.first.severity,
        detector.issues.first.severity,
        reason: 'highlight severity follows the issue ratio rule',
      );
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

          detector.updateDebugSnapshot(_snapshot('LargePageWidget'));

          // Only one LargePageWidget instance on screen
          await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
          detector.scanTree(tester.element(find.byType(_Wrapper)));

          expect(detector.issues, isNotEmpty);
          expect(detector.issues.first.confidence, IssueConfidence.confirmed);
        },
      );

      testWidgets(
        'caps at likely when multiple instances of flagged type exist',
        (tester) async {
          detector = SetStateScopeDetector(
            dirtyRatioThreshold: 0.3,
            minSubtreeSize: 3,
          );

          detector.updateDebugSnapshot(_snapshot('LargePageWidget'));

          // Two instances of LargePageWidget
          await tester.pumpWidget(
            const _Wrapper(
              child: Column(children: [LargePageWidget(), LargePageWidget()]),
            ),
          );
          detector.scanTree(tester.element(find.byType(_Wrapper)));

          expect(detector.issues, isNotEmpty);
          expect(detector.issues.first.confidence, IssueConfidence.likely);
        },
      );

      testWidgets('snapshot naming another type is not evidence', (
        tester,
      ) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        detector.updateDebugSnapshot(_snapshot('SomeOtherWidget'));

        await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
        detector.scanTree(tester.element(find.byType(_Wrapper)));

        expect(detector.issues, isEmpty);
      });

      testWidgets(
        'debugCallback counts for the owner without churn emit confirmed',
        (tester) async {
          detector = SetStateScopeDetector(
            dirtyRatioThreshold: 0.3,
            minSubtreeSize: 3,
          );

          detector.updateDebugSnapshot(_snapshot('LargePageWidget', count: 3));

          await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
          detector.scanTree(tester.element(find.byType(_Wrapper)));

          final issue = detector.issues.single;
          expect(issue.confidence, IssueConfidence.confirmed);
          expect(
            issue.observationSource,
            ObservationSource.debugCallbackAndStructural,
          );
        },
      );

      testWidgets('flutterTimeline counts for the owner are not evidence', (
        tester,
      ) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        // Timeline counts include first builds, so a non-zero count does
        // not prove a rebuild.
        detector.updateDebugSnapshot(
          _snapshot(
            'LargePageWidget',
            count: 3,
            source: RebuildCountSource.flutterTimeline,
          ),
        );

        await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
        detector.scanTree(tester.element(find.byType(_Wrapper)));

        expect(detector.issues, isEmpty);
      });

      testWidgets('flutterTimeline counts do not upgrade churn confidence', (
        tester,
      ) async {
        detector = SetStateScopeDetector(rebuildEvidenceThreshold: 1);
        detector.updateDebugSnapshot(
          _snapshot(
            'TestCounterWidget',
            source: RebuildCountSource.flutterTimeline,
          ),
        );

        final issues = await _churnScan(tester, detector, padding: 36);

        expect(issues.single.confidence, IssueConfidence.likely);
        expect(issues.single.observationSource, ObservationSource.structural);
      });

      testWidgets(
        'observationSource set to debugCallbackAndStructural on upgrade',
        (tester) async {
          detector = SetStateScopeDetector(
            dirtyRatioThreshold: 0.3,
            minSubtreeSize: 3,
          );

          detector.updateDebugSnapshot(_snapshot('LargePageWidget'));

          await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
          detector.scanTree(tester.element(find.byType(_Wrapper)));

          expect(detector.issues, isNotEmpty);
          expect(
            detector.issues.first.observationSource,
            ObservationSource.debugCallbackAndStructural,
          );
        },
      );
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
          rebuildEvidenceThreshold: 1,
        );
        final key = GlobalKey<TestCounterWidgetState>();

        // Phase 1: Complete scan to establish snapshot baseline
        await tester.pumpWidget(
          _Wrapper(child: TestCounterWidget(key: key, childCount: 20)),
        );
        final context = tester.element(find.byType(_Wrapper));
        detector.scanTree(context);
        key.currentState!.triggerRebuild();
        await tester.pump();

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

        // Phase 3: Full scan still sees churn against the phase-1 baseline
        detector.scanTree(context);
        expect(detector.issues, isNotEmpty);
      });
    });

    // -----------------------------------------------------------------
    // v11.5: Const subtree discounting
    // -----------------------------------------------------------------

    group('const subtree discounting', () {
      testWidgets('debug-callback evidence without churn uses raw size', (
        tester,
      ) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );
        detector.updateDebugSnapshot(_snapshot('ConstHeavyPageWidget'));
        await tester.pumpWidget(const _Wrapper(child: ConstHeavyPageWidget()));
        final root = tester.element(find.byType(_Wrapper));
        detector.scanTree(root);
        detector.scanTree(root);

        // No churn → no const discount, even though every child is const.
        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.detail, isNot(contains('mutable')));
      });

      testWidgets(
        'detail includes const count when rebuild evidence + const children',
        (tester) async {
          final key = GlobalKey<RebuildableConstHeavyWidgetState>();
          // Use very low threshold so const-discounted ratio still triggers
          detector = SetStateScopeDetector(
            dirtyRatioThreshold: 0.01,
            minSubtreeSize: 3,
            rebuildEvidenceThreshold: 1,
          );

          await tester.pumpWidget(
            _Wrapper(child: RebuildableConstHeavyWidget(key: key)),
          );

          // Scan 1: establish baseline (element widget identity snapshot)
          detector.scanTree(tester.element(find.byType(_Wrapper)));

          // Trigger a real setState — changes the mutable child's identity
          // while const children keep the same widget instance
          key.currentState!.triggerRebuild();
          await tester.pump();

          // Scan 2: rebuild evidence fires (first child identity changed),
          // const children are detected as stable
          detector.scanTree(tester.element(find.byType(_Wrapper)));

          expect(
            detector.hasRebuildEvidenceFor('RebuildableConstHeavyWidget'),
            true,
            reason: 'setState should produce rebuild evidence',
          );
          expect(
            detector.issues,
            isNotEmpty,
            reason: 'Should still flag wide subtree at low threshold',
          );
          final detail = detector.issues.first.detail;
          expect(
            detail,
            contains('mutable'),
            reason: 'Detail should show const/mutable breakdown',
          );
        },
      );

      testWidgets('const discount suppresses issue that would otherwise fire', (
        tester,
      ) async {
        final key = GlobalKey<RebuildableConstHeavyWidgetState>();
        // Use a threshold where the RAW ratio (all elements) fires
        // but the MUTABLE ratio (after const discount) does not.
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
          rebuildEvidenceThreshold: 1,
        );

        await tester.pumpWidget(
          _Wrapper(child: RebuildableConstHeavyWidget(key: key)),
        );

        // Scan 1: debug-callback evidence, no churn baseline → raw size
        // fires (proves the raw ratio crosses the threshold).
        detector.updateDebugSnapshot(_snapshot('RebuildableConstHeavyWidget'));
        detector.scanTree(tester.element(find.byType(_Wrapper)));
        expect(
          detector.issues,
          isNotEmpty,
          reason: 'Raw subtree size should cross the threshold',
        );

        // Drop debug evidence; churn becomes the only evidence.
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 0,
            elapsed: Duration(seconds: 1),
          ),
        );
        key.currentState!.triggerRebuild();
        await tester.pump();

        // Scan 2: const discount reduces mutable ratio below threshold
        detector.scanTree(tester.element(find.byType(_Wrapper)));
        expect(
          detector.issues,
          isEmpty,
          reason: 'Const discount should reduce mutable ratio below threshold',
        );
      });

      testWidgets('second scan without rebuild uses raw size (no discount)', (
        tester,
      ) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );
        detector.updateDebugSnapshot(_snapshot('LargePageWidget'));

        // Scan 1: establish baseline
        await tester.pumpWidget(const _Wrapper(child: LargePageWidget()));
        detector.scanTree(tester.element(find.byType(_Wrapper)));
        expect(detector.issues, isNotEmpty);

        // Scan 2: no churn → should still detect (no discount)
        detector.scanTree(tester.element(find.byType(_Wrapper)));
        expect(
          detector.issues,
          isNotEmpty,
          reason: 'Without churn evidence, const discount should not apply',
        );
      });
    });

    group('clearSnapshots retention fix', () {
      testWidgets('clearSnapshots nulls widest-widget state', (tester) async {
        detector = SetStateScopeDetector(
          dirtyRatioThreshold: 0.3,
          minSubtreeSize: 3,
        );

        detector.updateDebugSnapshot(_snapshot('LargePageWidget'));

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

    // -----------------------------------------------------------------
    // Anti-tautology: drive a real setState rebuild through the
    // real DebugInstrumentationCoordinator pipeline and feed the
    // resulting DebugSnapshot to the detector. Verifies that the
    // between-scan child-identity rebuild detection AND the debug
    // correlation upgrade both hold under the real pipeline shape, not
    // just against hand-written fixtures.
    // -----------------------------------------------------------------

    group('real widget tree (anti-tautology)', () {
      testWidgets(
        'real debug snapshot upgrades SetStateScope confidence to confirmed',
        (tester) async {
          detector = SetStateScopeDetector(
            dirtyRatioThreshold: 0.3,
            minSubtreeSize: 50,
            rebuildEvidenceThreshold: 1,
          );

          // childCount: 55 gives 56 SizedBoxes × 10px = 560px, fitting the
          // 600px default test viewport. Subtree size is
          // 1 (Column) + 56 (SizedBoxes) = 57 → exceeds minSubtreeSize: 50.
          final key = GlobalKey<TestCounterWidgetState>();
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: TestCounterWidget(key: key, childCount: 55),
            ),
          );

          // Scan 1 — establishes the child-identity baseline for the
          // between-scan rebuild check. On a first scan _childSnapshots
          // is empty, so no evidence is staged here.
          detector.scanTree(tester.element(find.byType(Directionality)));

          // Drive one real setState rebuild through a real coordinator.
          // The returned snapshot's shape is exactly what production
          // detectors receive — not a hand-written fixture.
          final snapshot = await captureDebugCallbackCounts(
            tester: tester,
            key: key,
            count: 1,
          );

          expect(snapshot.source, RebuildCountSource.debugCallback);
          expect(
            snapshot.rebuildCounts['TestCounterWidget'],
            greaterThan(0),
            reason:
                'real coordinator pipeline must count TestCounterWidget '
                'rebuilds',
          );

          // Scan 2 — TestCounterWidget's child identity has changed
          // (setState bumped the counter → new Column instance), so the
          // between-scan rebuild check stages evidence; the real snapshot
          // then upgrades confidence to `confirmed` because the scanned
          // tree holds exactly one TestCounterWidget instance.
          detector.updateDebugSnapshot(snapshot);
          detector.scanTree(tester.element(find.byType(Directionality)));

          expect(
            detector.hasRebuildEvidenceFor('TestCounterWidget'),
            isTrue,
            reason:
                'real setState must produce child-identity change '
                'that flows into _pendingEvidence',
          );
          expect(detector.issues, isNotEmpty);
          final issue = detector.issues.first;
          expect(issue.widgetName, 'TestCounterWidget');
          expect(issue.confidence, IssueConfidence.confirmed);
          expect(
            issue.observationSource,
            ObservationSource.debugCallbackAndStructural,
          );
        },
      );
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

/// StatefulWidget with mostly const children — const discounting should apply.
class ConstHeavyPageWidget extends StatefulWidget {
  const ConstHeavyPageWidget({super.key});

  @override
  State<ConstHeavyPageWidget> createState() => _ConstHeavyPageWidgetState();
}

class _ConstHeavyPageWidgetState extends State<ConstHeavyPageWidget> {
  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
        SizedBox(height: 10),
      ],
    );
  }
}

/// StatefulWidget with mostly const children that can trigger setState
/// externally via GlobalKey. The first child is mutable (changes on rebuild),
/// while the rest are const. This allows testing const-discounting when
/// rebuild evidence is present.
class RebuildableConstHeavyWidget extends StatefulWidget {
  const RebuildableConstHeavyWidget({super.key});

  @override
  State<RebuildableConstHeavyWidget> createState() =>
      RebuildableConstHeavyWidgetState();
}

class RebuildableConstHeavyWidgetState
    extends State<RebuildableConstHeavyWidget> {
  int _counter = 0;

  void triggerRebuild() => setState(() => _counter++);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // One mutable child — changes identity on every rebuild
        SizedBox(key: ValueKey(_counter), height: 10),
        // 29 const children — identity stays the same across rebuilds
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
      ],
    );
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
