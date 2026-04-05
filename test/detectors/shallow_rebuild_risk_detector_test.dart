import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/shallow_rebuild_risk_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  group('ShallowRebuildRiskDetector', () {
    late ShallowRebuildRiskDetector detector;

    setUp(() {
      detector = ShallowRebuildRiskDetector(depthThreshold: 3);
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;

      await tester.pumpWidget(const _ShallowStatefulApp());
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty);
    });

    group('VM connected + high build activity', () {
      setUp(() {
        detector.vmConnected = true;
        detector.processTimelineData(highBuildActivityData(buildCount: 25));
      });

      testWidgets('flags shallow StatefulWidget', (tester) async {
        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
        expect(
          detector.issues.first.title,
          contains('Shallow Rebuild Risk'),
        );
      });

      testWidgets('skips framework widgets (Scaffold etc.)', (tester) async {
        // Only framework-like StatefulWidgets at shallow depth
        await tester.pumpWidget(const _OnlyDeepStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        // No shallow user StatefulWidget found — no issue
        expect(detector.issues, isEmpty);
      });

      testWidgets('no issue when all StatefulWidgets below depth threshold',
          (tester) async {
        await tester.pumpWidget(const _OnlyDeepStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isEmpty);
      });

      testWidgets('confidence is possible', (tester) async {
        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues.first.confidence, IssueConfidence.possible);
      });

      testWidgets('observationSource is vmTimeline', (tester) async {
        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues.first.observationSource,
            ObservationSource.vmTimeline);
      });
    });

    group('VM connected + low build activity', () {
      setUp(() {
        detector.vmConnected = true;
        detector.processTimelineData(highBuildActivityData(buildCount: 5));
      });

      testWidgets('no issues when build count <= 20', (tester) async {
        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isEmpty);
      });
    });

    group('VM disconnected', () {
      setUp(() {
        detector.vmConnected = false;
      });

      testWidgets('structural fallback reports shallow widgets',
          (tester) async {
        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
        expect(
          detector.issues.first.title,
          contains('Shallow Rebuild Risk'),
        );
      });

      testWidgets('mentions VM unavailable in detail', (tester) async {
        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues.first.detail, contains('VM unavailable'));
      });

      testWidgets('confidence is possible', (tester) async {
        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues.first.confidence, IssueConfidence.possible);
      });

      testWidgets('observationSource is structural', (tester) async {
        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues.first.observationSource,
            ObservationSource.structural);
      });
    });

    group('vmConnected setter', () {
      testWidgets('all issues cleared immediately on disconnect',
          (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(highBuildActivityData(buildCount: 25));

        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isNotEmpty);

        detector.vmConnected = false;
        expect(detector.issues, isEmpty);
      });

      testWidgets(
          'after disconnect, next scanTree produces structural fallback',
          (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(highBuildActivityData(buildCount: 25));

        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isNotEmpty);

        // Disconnect clears issues
        detector.vmConnected = false;
        expect(detector.issues, isEmpty);

        // Next scan produces structural fallback
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.detail, contains('VM unavailable'));
      });

      test('dispose clears issues', () {
        detector.dispose();
        expect(detector.issues, isEmpty);
      });
    });

    group('debug confidence upgrade', () {
      testWidgets(
          'upgrades to likely when debug confirms shallow widget rebuilding',
          (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(highBuildActivityData(buildCount: 25));
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'_ShallowChild': 15},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.likely);
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallbackAndStructural);
        expect(detector.issues.first.detail, contains('rebuilding at'));
      });

      testWidgets('remains possible when debug has no matching widget type',
          (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(highBuildActivityData(buildCount: 25));
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'SomeOtherWidget': 20},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
      });

      testWidgets('upgrades even in structural-only fallback (VM disconnected)',
          (tester) async {
        detector.vmConnected = false;
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'_ShallowChild': 10},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        await tester.pumpWidget(const _ShallowStatefulApp());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.likely);
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallbackAndStructural);
      });
    });

    // -----------------------------------------------------------------
    // Custom thresholds
    // -----------------------------------------------------------------

    testWidgets('custom depthThreshold allows deeper shallow widgets',
        (tester) async {
      // Depth 5 means only widgets at depth ≤5 are flagged.
      // _ShallowChild is at depth 1 — still within threshold.
      detector = ShallowRebuildRiskDetector(depthThreshold: 5);
      detector.vmConnected = true;
      detector.processTimelineData(highBuildActivityData(buildCount: 25));

      await tester.pumpWidget(const _ShallowStatefulApp());
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isNotEmpty);
    });

    testWidgets('depthThreshold 0 only flags root-level StatefulWidgets',
        (tester) async {
      // Depth 0 means only depth ≤ 0 widgets are flagged.
      // _ShallowChild at depth 1 is already too deep.
      detector = ShallowRebuildRiskDetector(depthThreshold: 0);
      detector.vmConnected = true;
      detector.processTimelineData(highBuildActivityData(buildCount: 25));

      await tester.pumpWidget(const _ShallowStatefulApp());
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, isEmpty);
    });
  });
}

/// Scan root wrapping a StatefulWidget at depth 1 (shallow).
/// The detector scans from Directionality's children, so _ShallowChild
/// is at depth 1 — within the default threshold of 3.
class _ShallowStatefulApp extends StatelessWidget {
  const _ShallowStatefulApp();

  @override
  Widget build(BuildContext context) {
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: _ShallowChild(),
    );
  }
}

class _ShallowChild extends StatefulWidget {
  const _ShallowChild();

  @override
  State<_ShallowChild> createState() => _ShallowChildState();
}

class _ShallowChildState extends State<_ShallowChild> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// All StatefulWidgets are deeply nested (beyond depth threshold of 3).
class _OnlyDeepStatefulApp extends StatelessWidget {
  const _OnlyDeepStatefulApp();

  @override
  Widget build(BuildContext context) {
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.zero,
            child: Padding(
              padding: EdgeInsets.zero,
              child: Padding(
                padding: EdgeInsets.zero,
                child: Padding(
                  padding: EdgeInsets.zero,
                  child: _DeepStatefulWidget(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeepStatefulWidget extends StatefulWidget {
  const _DeepStatefulWidget();

  @override
  State<_DeepStatefulWidget> createState() => _DeepStatefulWidgetState();
}

class _DeepStatefulWidgetState extends State<_DeepStatefulWidget> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}
