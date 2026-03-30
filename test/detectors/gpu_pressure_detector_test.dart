import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/gpu_pressure_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  group('GpuPressureDetector', () {
    late GpuPressureDetector detector;

    setUp(() {
      detector = GpuPressureDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      detector.vmConnected = true;
      detector.processTimelineData(rasterDominantData());

      await tester.pumpWidget(const _GpuTestApp());
      detector.scanTree(tester.element(find.byType(_GpuTestApp)));

      expect(detector.issues, isEmpty);
    });

    group('VM connected — raster ratio', () {
      setUp(() {
        detector.vmConnected = true;
      });

      testWidgets('no issue when raster <= UI x threshold', (tester) async {
        // Raster 10ms, UI 10ms — ratio = 1.0 (below 1.5 threshold)
        detector.processTimelineData(rasterDominantData(
          rasterUs: 10000,
          buildUs: 5000,
          layoutUs: 3000,
          paintUs: 2000,
        ));

        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));

        expect(detector.issues, isEmpty);
      });

      testWidgets('warning when raster > UI x 1.5', (tester) async {
        // Raster 20ms, UI 10ms — ratio = 2.0
        detector.processTimelineData(rasterDominantData(
          rasterUs: 20000,
          buildUs: 5000,
          layoutUs: 3000,
          paintUs: 2000,
        ));

        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity, IssueSeverity.warning);
        expect(detector.issues.first.title, contains('Raster Dominance'));
      });

      testWidgets('critical when raster > UI x 3.0', (tester) async {
        // Raster 40ms, UI 10ms — ratio = 4.0
        detector.processTimelineData(rasterDominantData(
          rasterUs: 40000,
          buildUs: 5000,
          layoutUs: 3000,
          paintUs: 2000,
        ));

        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity, IssueSeverity.critical);
      });

      testWidgets('confidence is confirmed without expensive nodes',
          (tester) async {
        detector.processTimelineData(rasterDominantData(
          rasterUs: 20000,
          buildUs: 5000,
          layoutUs: 3000,
          paintUs: 2000,
        ));

        // Simple tree — no expensive render objects
        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
      });

      testWidgets('splits observed raster signal from likely node cause',
          (tester) async {
        detector.processTimelineData(rasterDominantData(
          rasterUs: 20000,
          buildUs: 5000,
          layoutUs: 3000,
          paintUs: 2000,
        ));

        await tester.pumpWidget(const _OpacityDeepTree());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(2));

        final rasterIssue = detector.issues.firstWhere(
          (issue) => issue.stableId == 'raster_dominance',
        );
        final nodeIssue = detector.issues.firstWhere(
          (issue) => issue.stableId == 'expensive_gpu_nodes',
        );

        expect(rasterIssue.confidence, IssueConfidence.confirmed);
        expect(rasterIssue.detail, isNot(contains('Suspected cause')));
        expect(nodeIssue.confidence, IssueConfidence.likely);
        expect(nodeIssue.detail, contains('Raster-dominant frames coincided'));
      });
    });

    group('structural-only — expensive nodes', () {
      testWidgets('reports expensive nodes as possible', (tester) async {
        // No VM data, but tree has an Opacity with many descendants
        detector.vmConnected = false;

        await tester.pumpWidget(const _OpacityDeepTree());
        detector.scanTree(tester.element(find.byType(Directionality)));

        // RenderOpacity with >5 descendants should produce a structural issue
        expect(detector.issues, isNotEmpty,
            reason: 'RenderOpacity with deep subtree should be flagged');
        expect(detector.issues.first.confidence, IssueConfidence.possible);
        expect(detector.issues.first.category, IssueCategory.raster);
        expect(detector.issues.first.title, contains('Expensive Render Nodes'));
      });

      testWidgets('mentions VM unavailable when disconnected', (tester) async {
        detector.vmConnected = false;

        await tester.pumpWidget(const _OpacityDeepTree());
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty,
            reason: 'Should flag expensive nodes even without VM');
        final rasterIssues =
            detector.issues.where((i) => i.category == IssueCategory.raster);
        expect(rasterIssues, isNotEmpty);
        expect(rasterIssues.first.detail, contains('VM unavailable'));
      });
    });

    group('vmConnected setter', () {
      testWidgets('confirmed/likely issues cleared immediately on disconnect',
          (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(rasterDominantData(
          rasterUs: 20000,
          buildUs: 5000,
          layoutUs: 3000,
          paintUs: 2000,
        ));

        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));
        expect(detector.issues, isNotEmpty);

        detector.vmConnected = false;
        // Confirmed/likely issues should be cleared
        expect(
          detector.issues.where(
            (i) =>
                i.confidence == IssueConfidence.confirmed ||
                i.confidence == IssueConfidence.likely,
          ),
          isEmpty,
        );
      });

      testWidgets(
          'structural issue survives disconnect with downgraded confidence',
          (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(rasterDominantData(
          rasterUs: 20000,
          buildUs: 5000,
          layoutUs: 3000,
          paintUs: 2000,
        ));

        // Use OpacityDeepTree to generate both raster_dominance + expensive_gpu_nodes
        await tester.pumpWidget(const _OpacityDeepTree());
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, hasLength(2));

        // Verify expensive_gpu_nodes starts as likely (corroborated by raster dominance)
        final nodesBefore = detector.issues
            .firstWhere((i) => i.stableId == 'expensive_gpu_nodes');
        expect(nodesBefore.confidence, IssueConfidence.likely);

        // Disconnect
        detector.vmConnected = false;

        // raster_dominance should be removed
        expect(
          detector.issues.where((i) => i.stableId == 'raster_dominance'),
          isEmpty,
        );

        // expensive_gpu_nodes should survive but downgraded to possible
        final nodesAfter =
            detector.issues.where((i) => i.stableId == 'expensive_gpu_nodes');
        expect(nodesAfter, hasLength(1));
        expect(nodesAfter.first.confidence, IssueConfidence.possible);
      });

      testWidgets(
          'after disconnect, next scanTree only produces structural issues',
          (tester) async {
        detector.vmConnected = true;
        detector.processTimelineData(rasterDominantData(
          rasterUs: 20000,
          buildUs: 5000,
          layoutUs: 3000,
          paintUs: 2000,
        ));

        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));
        expect(detector.issues, isNotEmpty);

        // Disconnect
        detector.vmConnected = false;

        // Next scan should not produce raster ratio issues
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));
        for (final issue in detector.issues) {
          expect(issue.confidence, IssueConfidence.possible);
        }
      });
    });

    group('highlights', () {
      testWidgets('no highlights when no expensive nodes found',
          (tester) async {
        await tester.pumpWidget(const _GpuTestApp());
        detector.scanTree(tester.element(find.byType(_GpuTestApp)));

        expect(detector.highlights, isEmpty);
      });

      test('highlights cleared on dispose', () {
        detector.dispose();
        expect(detector.highlights, isEmpty);
      });
    });

    // -----------------------------------------------------------------
    // Custom thresholds
    // -----------------------------------------------------------------

    testWidgets('custom rasterMultiplierThreshold fires at adjusted ratio',
        (tester) async {
      detector = GpuPressureDetector(rasterMultiplierThreshold: 2.0);
      detector.vmConnected = true;
      // UI = 5000+3000+2000 = 10000; Raster 25000; ratio = 2.5 > 2.0 → warning
      detector.processTimelineData(rasterDominantData(rasterUs: 25000));
      await tester.pumpWidget(const _GpuTestApp());
      detector.scanTree(tester.element(find.byType(_GpuTestApp)));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    testWidgets('custom threshold below ratio does not fire', (tester) async {
      detector = GpuPressureDetector(rasterMultiplierThreshold: 2.0);
      detector.vmConnected = true;
      // UI = 10000; Raster 18000; ratio = 1.8 < 2.0 → no issue
      detector.processTimelineData(rasterDominantData(rasterUs: 18000));
      await tester.pumpWidget(const _GpuTestApp());
      detector.scanTree(tester.element(find.byType(_GpuTestApp)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('custom threshold critical at 2x multiplier', (tester) async {
      detector = GpuPressureDetector(rasterMultiplierThreshold: 2.0);
      detector.vmConnected = true;
      // UI = 10000; Raster 45000; ratio = 4.5 > 4.0 (2.0*2) → critical
      detector.processTimelineData(rasterDominantData(rasterUs: 45000));
      await tester.pumpWidget(const _GpuTestApp());
      detector.scanTree(tester.element(find.byType(_GpuTestApp)));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });
  });
}

/// Simple widget tree with no expensive render objects.
class _GpuTestApp extends StatelessWidget {
  const _GpuTestApp();

  @override
  Widget build(BuildContext context) {
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          SizedBox(width: 10, height: 10),
          SizedBox(width: 10, height: 10),
        ],
      ),
    );
  }
}

/// Widget tree with Opacity wrapping many descendants.
class _OpacityDeepTree extends StatelessWidget {
  const _OpacityDeepTree();

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Opacity(
        opacity: 0.5,
        child: Column(
          children: List.generate(
            10,
            (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
          ),
        ),
      ),
    );
  }
}
