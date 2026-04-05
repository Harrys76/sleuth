import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  group('RepaintDetector', () {
    late RepaintDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = RepaintDetector(clock: () => fakeNow);
      detector.vmConnected = true;
    });

    group('VM connected', () {
      test('no issues when disabled', () {
        detector.isEnabled = false;
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('no issues when paint count below threshold', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 10));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('warning when paint count exceeds threshold', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 35));
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity, IssueSeverity.warning);
        expect(detector.issues.first.title, contains('Repainting'));
      });

      test('critical when paint count exceeds 2x threshold', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 65));
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity, IssueSeverity.critical);
      });

      test('issue confidence is confirmed (VM data)', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 35));
        detector.evaluateNow();

        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
      });

      test('observationSource is vmTimeline', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 35));
        detector.evaluateNow();

        expect(detector.issues.first.observationSource,
            ObservationSource.vmTimeline);
      });

      test('window resets after 1-second evaluation', () {
        // First window: high activity
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 35));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        // Second window: low activity
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 5));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });
    });

    group('unified evaluation model', () {
      test('processTimelineData accumulates but does not write issues', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));
        expect(detector.issues, isEmpty);
      });

      testWidgets('scanTree triggers _evaluate which writes issues',
          (tester) async {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));

        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
      });

      test('evaluateNow triggers _evaluate without tree walk', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));

        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);
      });

      test('VM takes priority over debug when connected', () {
        // Stage both VM and debug data
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));

        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 100,
          elapsed: Duration(seconds: 1),
        ));

        detector.evaluateNow();

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.observationSource,
            ObservationSource.vmTimeline);
      });

      test('no-op when no fresh data — keeps existing issues', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);
      });

      test('fresh VM window with 0 events clears stale issues', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 0));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('fresh debug snapshot with 0 paints clears stale issues', () {
        // Disconnect VM so debug path is used
        detector.vmConnected = false;

        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 100,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });
    });

    group('hybrid lifecycle with debug fallback', () {
      setUp(() {
        detector.vmConnected = false;
      });

      test('produces aggregate paint rate issue from debug data', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('Repainting'));
      });

      test('no widgetName on paint-only issues (aggregate data)', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues.first.widgetName, isNull);
      });

      test('confidence is likely for aggregate paint data (not confirmed)', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues.first.confidence, IssueConfidence.likely);
      });

      test('normalizes paint count to per-second using elapsed', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 20,
          elapsed: Duration(milliseconds: 500),
        ));
        detector.evaluateNow();

        // 20 paints in 0.5s = 40/sec, exceeds threshold of 30
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('40'));
      });

      test('no issues when debug paint rate below threshold', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 10,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues, isEmpty);
      });

      test('observationSource is debugCallback', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallback);
      });
    });

    group('vmConnected setter', () {
      test('VM staging cleared on disconnect', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));

        detector.vmConnected = false;
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('reconnect flushes stale debug issues', () {
        // Start disconnected with debug-based issues
        detector.vmConnected = false;
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.likely);

        // Reconnect — stages fresh-zero VM window
        detector.vmConnected = true;

        // Next evaluateNow flushes stale debug issues
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });
    });

    test('lifecycle is hybrid', () {
      expect(detector.lifecycle, DetectorLifecycle.hybrid);
    });

    group('per-widget paint attribution', () {
      setUp(() {
        detector.vmConnected = false;
      });

      test('produces per-widget issues with confirmed confidence', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 80,
          paintCounts: {'CustomPaint': 50, 'SomeWidget': 5},
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('CustomPaint'));
        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
        expect(detector.issues.first.widgetName, 'CustomPaint');
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallback);
      });

      test('per-widget takes priority over VM when both available', () {
        detector.vmConnected = true;

        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));

        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 80,
          paintCounts: {'CustomPaint': 50},
          elapsed: Duration(seconds: 1),
        ));

        detector.evaluateNow();

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.title, contains('CustomPaint'));
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallback);
      });

      test('normalizes per-widget rate using elapsed', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 30,
          paintCounts: {'CustomPaint': 20},
          elapsed: Duration(milliseconds: 500),
        ));
        detector.evaluateNow();

        // 20 paints in 0.5s = 40/sec, exceeds threshold of 30
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('40'));
      });

      test('no per-widget issues when paintCounts empty — uses aggregate', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          paintCounts: {},
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.confidence, IssueConfidence.likely);
      });

      test('stale VM data cleared when per-widget branch wins', () {
        detector.vmConnected = true;

        // Stage VM data
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));

        // Stage debug per-widget data
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 60,
          paintCounts: {'MyWidget': 50},
          elapsed: Duration(seconds: 1),
        ));

        detector.evaluateNow();
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallback);

        // Next evaluate should have no fresh data — issues kept as-is.
        detector.evaluateNow();
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallback);
      });

      test(
          'falls through to VM when paintCounts exist but no type crosses '
          'threshold', () {
        detector.vmConnected = true;

        // Stage VM data with high aggregate count
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highPaintActivityData(paintCount: 50));

        // Stage debug data: many types, none above threshold individually
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 60,
          paintCounts: {'TypeA': 5, 'TypeB': 5, 'TypeC': 5},
          elapsed: Duration(seconds: 1),
        ));

        detector.evaluateNow();

        // Per-widget found no issues; should fall through to VM aggregate
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.observationSource,
            ObservationSource.vmTimeline);
      });

      test('critical severity when per-widget rate exceeds 2x threshold', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 100,
          paintCounts: {'HeavyWidget': 70},
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues.first.severity, IssueSeverity.critical);
      });
    });
  });

  group('RepaintDetector enrichment', () {
    late RepaintDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = RepaintDetector(clock: () => fakeNow);
      detector.vmConnected = true;
    });

    test('enriched dirty count appears in VM path issue detail', () {
      detector.processTimelineData(enrichedPaintData(
        paintCount: 50,
        dirtyCount: 8,
      ));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(enrichedPaintData(
        paintCount: 0,
      ));
      detector.evaluateNow();

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.detail, contains('dirty RenderObjects'));
      expect(issue.detail, contains('timeline enrichment'));
    });

    test('VM path without enrichment has no dirty count', () {
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 50));
      detector.evaluateNow();

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.detail, isNot(contains('dirty RenderObjects')));
    });

    test('enrichment cleared between evaluation cycles', () {
      // Cycle 1: enriched data
      detector.processTimelineData(enrichedPaintData(
        paintCount: 50,
        dirtyCount: 5,
      ));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(enrichedPaintData(paintCount: 0));
      detector.evaluateNow();
      expect(detector.issues.first.detail, contains('dirty RenderObjects'));

      // Cycle 2: no enrichment
      detector.processTimelineData(highPaintActivityData(paintCount: 50));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 0));
      detector.evaluateNow();
      expect(
          detector.issues.first.detail, isNot(contains('dirty RenderObjects')));
    });
  });

  group('repaint widget highlights', () {
    late RepaintDetector detector;

    setUp(() {
      detector = RepaintDetector();
      detector.vmConnected = false;
    });

    testWidgets(
        'debug snapshot with high paint rate produces highlights for matching widgets',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestPaintWidget(),
        ),
      );

      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 50,
        paintCounts: {'_TestPaintWidget': 50},
        elapsed: Duration(seconds: 1),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, isNotEmpty);
      expect(detector.highlights.first.widgetName, '_TestPaintWidget');
      expect(detector.highlights.first.detectorName, 'Repaint');
      expect(detector.highlights.first.detail, contains('50 repaints/sec'));
    });

    testWidgets('no debug snapshot produces no highlights', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestPaintWidget(),
        ),
      );

      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isEmpty);
    });

    testWidgets('rate below threshold produces no highlights', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestPaintWidget(),
        ),
      );

      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 10,
        paintCounts: {'_TestPaintWidget': 10},
        elapsed: Duration(seconds: 1),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, isEmpty);
    });

    testWidgets('caps highlights at 3 per type', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              10,
              (i) => _TestPaintWidget(key: ValueKey(i)),
            ),
          ),
        ),
      );

      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 50,
        paintCounts: {'_TestPaintWidget': 50},
        elapsed: Duration(seconds: 1),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights.length, 3);
    });

    testWidgets('critical severity at 2x threshold', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestPaintWidget(),
        ),
      );

      // 65/sec > 30 * 2 = 60 → critical
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 65,
        paintCounts: {'_TestPaintWidget': 65},
        elapsed: Duration(seconds: 1),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights.first.severity, IssueSeverity.critical);
    });

    testWidgets('dispose clears highlights', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestPaintWidget(),
        ),
      );

      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 50,
        paintCounts: {'_TestPaintWidget': 50},
        elapsed: Duration(seconds: 1),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isNotEmpty);

      detector.dispose();
      expect(detector.highlights, isEmpty);
    });
  });
}

class _TestPaintWidget extends StatelessWidget {
  const _TestPaintWidget({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 10);
}
