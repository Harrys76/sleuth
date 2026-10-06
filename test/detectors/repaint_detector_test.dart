import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

import '../helpers/timeline_test_helpers.dart';

/// PAINT scope time equal to [percent] % of a 2 s window — the window
/// length the VM-path tests below advance the fake clock by.
ParsedTimelineData _windowShare(int percent) =>
    paintLoadData(paintTimeUs: percent * 20000);

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
        detector.processTimelineData(_windowShare(15));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('no issues when paint share below threshold', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(5));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('warning when paint share exceeds threshold', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity, IssueSeverity.warning);
        expect(detector.issues.first.title, contains('Repainting'));
      });

      test('critical when paint share exceeds 3x threshold', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(35));
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity, IssueSeverity.critical);
      });

      test('issue confidence is confirmed (VM data)', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));
        detector.evaluateNow();

        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
      });

      test('observationSource is vmTimeline', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));
        detector.evaluateNow();

        expect(
          detector.issues.first.observationSource,
          ObservationSource.vmTimeline,
        );
      });

      test('window resets after 1-second evaluation; the card clears '
          'after two quiet windows', () {
        // First window: high activity
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));
        detector.evaluateNow();
        final issue = detector.issues.single;

        // Low windows: the card is held through one, cleared by two.
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(3));
        detector.evaluateNow();
        expect(detector.issues.single, same(issue));

        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(3));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('a share between 0.8x and the threshold keeps the card', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));
        detector.evaluateNow();
        final issue = detector.issues.single;
        for (var i = 0; i < 3; i++) {
          fakeNow = fakeNow.add(const Duration(seconds: 2));
          detector.processTimelineData(_windowShare(9));
          detector.evaluateNow();
        }
        expect(detector.issues.single, same(issue));
      });

      test('capture mode clears on the first quiet window', () {
        final capture = RepaintDetector(captureMode: true, clock: () => fakeNow)
          ..vmConnected = true;
        capture.evaluateNow();
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        capture.processTimelineData(_windowShare(15));
        capture.evaluateNow();
        expect(capture.issues, isNotEmpty);
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        capture.processTimelineData(_windowShare(3));
        capture.evaluateNow();
        expect(capture.issues, isEmpty);
        capture.dispose();
      });
    });

    group('unified evaluation model', () {
      test('processTimelineData accumulates but does not write issues', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));
        expect(detector.issues, isEmpty);
      });

      testWidgets('scanTree triggers _evaluate which writes issues', (
        tester,
      ) async {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));

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
        detector.processTimelineData(_windowShare(15));

        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);
      });

      test('VM takes priority over debug when connected', () {
        // Stage both VM and debug data
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));

        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 100,
            elapsed: Duration(seconds: 1),
          ),
        );

        detector.evaluateNow();

        expect(detector.issues, isNotEmpty);
        expect(
          detector.issues.first.observationSource,
          ObservationSource.vmTimeline,
        );
      });

      test('no-op when no fresh data — keeps existing issues', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);
      });

      test('fresh VM windows with 0 events clear stale issues', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        for (var i = 0; i < 2; i++) {
          fakeNow = fakeNow.add(const Duration(seconds: 2));
          detector.processTimelineData(_windowShare(0));
          detector.evaluateNow();
        }
        expect(detector.issues, isEmpty);
      });

      test('fresh debug snapshot with 0 paints clears stale issues', () {
        // Disconnect VM so debug path is used
        detector.vmConnected = false;

        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 100,
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 0,
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });
    });

    group('hybrid lifecycle with debug fallback', () {
      setUp(() {
        detector.vmConnected = false;
      });

      test('produces aggregate paint rate issue from debug data', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 50,
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('Repainting'));
      });

      test('no widgetName on paint-only issues (aggregate data)', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 50,
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();

        expect(detector.issues.first.widgetName, isNull);
      });

      test('confidence is likely for aggregate paint data (not confirmed)', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 50,
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();

        expect(detector.issues.first.confidence, IssueConfidence.likely);
      });

      test('normalizes paint count to per-second using elapsed', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 20,
            elapsed: Duration(milliseconds: 500),
          ),
        );
        detector.evaluateNow();

        // 20 paints in 0.5s = 40/sec, exceeds threshold of 30
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('40'));
      });

      test('no issues when debug paint rate below threshold', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 10,
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();

        expect(detector.issues, isEmpty);
      });

      test('observationSource is debugCallback', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 50,
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();

        expect(
          detector.issues.first.observationSource,
          ObservationSource.debugCallback,
        );
      });
    });

    group('vmConnected setter', () {
      test('VM staging cleared on disconnect', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));

        detector.vmConnected = false;
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('reconnect flushes stale debug issues', () {
        // Start disconnected with debug-based issues
        detector.vmConnected = false;
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 50,
            elapsed: Duration(seconds: 1),
          ),
        );
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

    group('per-widget repaint origins', () {
      setUp(() {
        detector.vmConnected = false;
      });

      test('produces per-widget issues with likely confidence', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 80,
            paintCounts: {'CustomPaint': 50, 'SomeWidget': 5},
            paintOrigins: {
              'CustomPaint': PaintOriginStats(maxCount: 50),
              'SomeWidget': PaintOriginStats(maxCount: 5),
            },
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        final issue = detector.issues.first;
        expect(issue.title, 'Likely Repaint Origin: CustomPaint (50/sec)');
        expect(issue.detail, contains('likely origin of 50 repaints'));
        expect(issue.confidence, IssueConfidence.likely);
        expect(issue.widgetName, 'CustomPaint');
        expect(issue.observationSource, ObservationSource.debugCallback);
      });

      test('widgets that only share the layer get no card', () {
        // Every widget in a repainting layer paints each frame; only the
        // origin counts.
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 360,
            paintCounts: {
              'Center': 60,
              'Column': 60,
              'Padding': 120,
              'SizedBox': 120,
              'CustomPaint': 60,
            },
            paintOrigins: {'CustomPaint': PaintOriginStats(maxCount: 60)},
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();

        expect(detector.issues.map((i) => i.stableId), [
          'repaint_debug_CustomPaint',
        ]);
      });

      test('the rate is the busiest instance, never a sum', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 400,
            paintCounts: {'Gauge': 400},
            paintOrigins: {
              'Gauge': PaintOriginStats(maxCount: 10, instanceCount: 40),
            },
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();
        expect(
          detector.issues.where(
            (i) => i.stableId!.startsWith('repaint_debug_'),
          ),
          isEmpty,
        );

        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 400,
            paintCounts: {'Gauge': 400},
            paintOrigins: {
              'Gauge': PaintOriginStats(
                maxCount: 40,
                instanceCount: 3,
                ancestorChain: 'Dashboard > Gauge',
              ),
            },
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();
        final issue = detector.issues.single;
        expect(issue.title, contains('(40/sec)'));
        expect(issue.detail, contains('Gauge (the busiest of 3 instances)'));
        expect(issue.ancestorChain, 'Dashboard > Gauge');
        expect(issue.fixHint, contains('Dashboard > Gauge'));
      });

      test('per-widget takes priority over VM when both available', () {
        detector.vmConnected = true;

        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));

        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 80,
            paintCounts: {'CustomPaint': 50},
            paintOrigins: {'CustomPaint': PaintOriginStats(maxCount: 50)},
            elapsed: Duration(seconds: 1),
          ),
        );

        detector.evaluateNow();

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.title, contains('CustomPaint'));
        expect(
          detector.issues.first.observationSource,
          ObservationSource.debugCallback,
        );
      });

      test('normalizes per-widget rate using elapsed', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 30,
            paintCounts: {'CustomPaint': 20},
            paintOrigins: {'CustomPaint': PaintOriginStats(maxCount: 20)},
            elapsed: Duration(milliseconds: 500),
          ),
        );
        detector.evaluateNow();

        // 20 paints in 0.5s = 40/sec, exceeds threshold of 30
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('40'));
      });

      test('no per-widget issues when paintCounts empty — uses aggregate', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 50,
            paintCounts: {},
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.confidence, IssueConfidence.likely);
      });

      test('stale VM data cleared when per-widget branch wins', () {
        detector.vmConnected = true;

        // Stage VM data
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));

        // Stage debug per-widget data
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 60,
            paintCounts: {'MyWidget': 50},
            paintOrigins: {'MyWidget': PaintOriginStats(maxCount: 50)},
            elapsed: Duration(seconds: 1),
          ),
        );

        detector.evaluateNow();
        expect(
          detector.issues.first.observationSource,
          ObservationSource.debugCallback,
        );

        // Next evaluate should have no fresh data — issues kept as-is.
        detector.evaluateNow();
        expect(
          detector.issues.first.observationSource,
          ObservationSource.debugCallback,
        );
      });

      test('falls through to VM when paintCounts exist but no type crosses '
          'threshold', () {
        detector.vmConnected = true;

        // Stage VM data with high aggregate count
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(_windowShare(15));

        // Stage debug data: many types, none above threshold individually
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 60,
            paintCounts: {'TypeA': 5, 'TypeB': 5, 'TypeC': 5},
            paintOrigins: {
              'TypeA': PaintOriginStats(maxCount: 5),
              'TypeB': PaintOriginStats(maxCount: 5),
              'TypeC': PaintOriginStats(maxCount: 5),
            },
            elapsed: Duration(seconds: 1),
          ),
        );

        detector.evaluateNow();

        // Per-widget found no issues; should fall through to VM aggregate
        expect(detector.issues, hasLength(1));
        expect(
          detector.issues.first.observationSource,
          ObservationSource.vmTimeline,
        );
      });

      test('critical severity when per-widget rate exceeds 2x threshold', () {
        detector.updateDebugSnapshot(
          const DebugSnapshot(
            rebuildCounts: {},
            totalPaintCount: 100,
            paintCounts: {'HeavyWidget': 70},
            paintOrigins: {'HeavyWidget': PaintOriginStats(maxCount: 70)},
            elapsed: Duration(seconds: 1),
          ),
        );
        detector.evaluateNow();

        expect(detector.issues.single.stableId, 'repaint_debug_HeavyWidget');
        expect(detector.issues.single.severity, IssueSeverity.critical);
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
      detector.processTimelineData(
        enrichedPaintData(paintCount: 50, paintDurationUs: 6000, dirtyCount: 8),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(enrichedPaintData(paintCount: 0));
      detector.evaluateNow();

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.detail, contains('dirty RenderObjects'));
      expect(issue.detail, contains('timeline enrichment'));
    });

    test('VM path without enrichment has no dirty count', () {
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(_windowShare(15));
      detector.evaluateNow();

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.detail, isNot(contains('dirty RenderObjects')));
    });

    test('enrichment cleared between evaluation cycles', () {
      // Cycle 1: enriched data
      detector.processTimelineData(
        enrichedPaintData(paintCount: 50, paintDurationUs: 6000, dirtyCount: 5),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(enrichedPaintData(paintCount: 0));
      detector.evaluateNow();
      expect(detector.issues.first.detail, contains('dirty RenderObjects'));

      // Cycle 2: no enrichment
      detector.processTimelineData(_windowShare(15));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(_windowShare(0));
      detector.evaluateNow();
      expect(
        detector.issues.first.detail,
        isNot(contains('dirty RenderObjects')),
      );
    });
  });

  group('repaint widget highlights', () {
    late RepaintDetector detector;

    setUp(() {
      detector = RepaintDetector();
      detector.vmConnected = false;
    });

    /// A one-second window in which each element of [instances] was the
    /// likely origin of [count] repaints.
    DebugSnapshot originsOf(List<Element> instances, int count) =>
        DebugSnapshot(
          rebuildCounts: const {},
          totalPaintCount: count,
          paintCounts: {'_TestPaintWidget': count},
          paintOrigins: {
            '_TestPaintWidget': PaintOriginStats(
              maxCount: count,
              instanceCount: instances.length,
              busiest: [
                for (final element in instances)
                  PaintOriginInstance(element: element, count: count),
              ],
            ),
          },
          elapsed: const Duration(seconds: 1),
        );

    testWidgets('debug snapshot with a high origin rate outlines the origin', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestPaintWidget(),
        ),
      );

      detector.updateDebugSnapshot(
        originsOf([tester.element(find.byType(_TestPaintWidget))], 50),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, isNotEmpty);
      expect(detector.highlights.first.widgetName, '_TestPaintWidget');
      expect(detector.highlights.first.detectorName, 'Repaint');
      expect(detector.highlights.first.detail, 'likely repaint origin, 50/sec');
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

      detector.updateDebugSnapshot(
        originsOf([tester.element(find.byType(_TestPaintWidget))], 10),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, isEmpty);
    });

    testWidgets('outlines only the origin instances, not other instances '
        'of the type', (tester) async {
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
      Element instance(int i) => tester.element(find.byKey(ValueKey(i)));

      detector.updateDebugSnapshot(originsOf([instance(7), instance(2)], 50));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights.map((h) => h.renderObject), [
        instance(2).renderObject,
        instance(7).renderObject,
      ]);
    });

    testWidgets('a held type with no kept instance outlines nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestPaintWidget(),
        ),
      );

      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 50,
          paintCounts: {'_TestPaintWidget': 50},
          paintOrigins: {'_TestPaintWidget': PaintOriginStats(maxCount: 50)},
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues.single.stableId, 'repaint_debug__TestPaintWidget');
      expect(detector.highlights, isEmpty);
    });

    testWidgets('critical severity at 2x threshold', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _TestPaintWidget(),
        ),
      );

      // 65/sec > 30 * 2 = 60 → critical
      detector.updateDebugSnapshot(
        originsOf([tester.element(find.byType(_TestPaintWidget))], 65),
      );
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

      detector.updateDebugSnapshot(
        originsOf([tester.element(find.byType(_TestPaintWidget))], 50),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isNotEmpty);

      detector.dispose();
      expect(detector.highlights, isEmpty);
    });
  });

  // ---------------------------------------------------------------
  // Animation-owned paint filter (Gates A/B/C).
  //
  // Hand-rolled fixture coverage of the helper logic. The companion
  // real-widget falsification test lives in
  //   test/detectors/repaint_animation_filter_real_widget_test.dart
  // and pumps an actual `CircularProgressIndicator` through the real
  // `DebugInstrumentationCoordinator` paint pipeline. The two suites
  // together address the fixture-tautology risk: this group
  // pins the gate algebra against synthetic chains, the real-widget
  // suite proves the chains we depend on actually exist at runtime.
  // ---------------------------------------------------------------
  // Earlier fixtures populated `ancestorChains` with synthetic strings
  // mirroring whatever shape the test author *thought* the coordinator
  // emitted. The detector no longer looks at chains for ownership at
  // all — it reads
  // `animationOwnedPaintCounts` and `totalAnimationOwnedPaintCount`,
  // which the coordinator populates per-paint via `isAnimationOwnedPaint`
  // (chain + bounded descendant walk) on the live element. So these
  // tests now poke the new contract directly: given a snapshot with
  // these owned-counts, what does each gate emit? Coordinator-side
  // attribution correctness is exercised by the real-widget suite.
  group('animation-owned paint filter', () {
    late RepaintDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = RepaintDetector(clock: () => fakeNow);
      // VM disconnected: keep the filter logic isolated from the VM
      // gate's own threshold checks. Specific Gate B tests below
      // re-enable VM where needed.
      detector.vmConnected = false;
    });

    // Gate A: every origin frame of `CustomPaint` was owned, so the
    // coordinator reports no unowned origin for it → no issue emitted
    // even at 60 paints/sec.
    test('Gate A skips per-widget when fully owned (residual=0)', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 60,
          paintCounts: {'CustomPaint': 60},
          animationOwnedPaintCounts: {'CustomPaint': 60},
          totalAnimationOwnedPaintCount: 60,
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(
        detector.issues,
        isEmpty,
        reason:
            'CustomPaint with residual=0 must NOT fire even at '
            '60 paints/sec.',
      );
    });

    // Gate A default-fire: no owned-counts entry → ownedCount
    // defaults to 0, residual = total → fires. Preserves the
    // "never silently mask a real bug" invariant.
    test('Gate A fires when no owned attribution recorded (default-fire)', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 60,
          paintCounts: {'CustomPaint': 60},
          // animationOwnedCount intentionally omitted (defaults to 0).
          // Coordinator never marked any of these as owned.
          paintOrigins: {'CustomPaint': PaintOriginStats(maxCount: 60)},
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(
        detector.issues,
        hasLength(1),
        reason:
            'No owned attribution means no evidence to suppress on; '
            'the detector MUST NOT silently mask a real bug.',
      );
      expect(detector.issues.first.stableId, 'repaint_debug_CustomPaint');
    });

    // Gate A explicit zero-owned: explicit `{'CustomPaint': 0}`
    // is the same as missing key → fires. (Defends against a future
    // change that decides to write zeros instead of omitting keys.)
    test('Gate A fires when explicit owned count is zero', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 60,
          paintCounts: {'CustomPaint': 60},
          animationOwnedPaintCounts: {'CustomPaint': 0},
          paintOrigins: {
            'CustomPaint': PaintOriginStats(
              maxCount: 60,
              animationOwnedCount: 0,
            ),
          },
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.stableId, 'repaint_debug_CustomPaint');
    });

    // Polymorphic-key collision (the bug per-paint attribution exists
    // to solve). Two distinct widgets share `CustomPaint` as their
    // typeName key: half the paints are owned by a CPI's internal
    // CustomPaint, the other half are a chart's bare CustomPaint.
    // Pre-fix, the chain-containment check would either fully fire
    // (cached chain didn't have the owner) or fully suppress (cached
    // chain did) — both wrong. Post-fix, the residual is exactly the
    // unowned half and the issue fires with the residual rate.
    test('Gate A fires with residual rate on partial ownership', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 60,
          paintCounts: {'CustomPaint': 60},
          animationOwnedPaintCounts: {'CustomPaint': 30},
          totalAnimationOwnedPaintCount: 30,
          paintOrigins: {
            'CustomPaint': PaintOriginStats(
              maxCount: 30,
              animationOwnedCount: 30,
            ),
          },
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(
        detector.issues,
        hasLength(1),
        reason:
            'Residual=30/sec is at threshold and must fire even '
            'though the other half of paints are owned.',
      );
      final issue = detector.issues.first;
      expect(issue.stableId, 'repaint_debug_CustomPaint');
      // Title reports the residual rate (30), not the raw 60.
      expect(issue.title, contains('30'));
      expect(issue.title, isNot(contains('60/sec')));
      // Detail discloses the exclusion accounting.
      expect(issue.detail, contains('30 repaints'));
      expect(issue.detail, contains('Excludes 30 animation-owned repaints'));
    });

    // Gate A residual below threshold: 60 total - 35 owned = 25
    // residual which is BELOW the 30/sec threshold → suppressed even
    // though the unowned subset exists.
    test('Gate A suppresses when residual rate is below threshold', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 60,
          paintCounts: {'CustomPaint': 60},
          animationOwnedPaintCounts: {'CustomPaint': 35},
          totalAnimationOwnedPaintCount: 35,
          paintOrigins: {
            'CustomPaint': PaintOriginStats(
              maxCount: 25,
              animationOwnedCount: 35,
            ),
          },
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(detector.issues, isEmpty);
    });

    // Gate B: VM aggregate fallback suppressed when *every*
    // per-widget paint is fully owned. The per-widget rate is
    // sub-threshold (skipping Gate A's residual check), but the VM
    // window says >10 % paint share — without Gate B that VM gate would fire
    // `excessive_repaint`.
    testWidgets('Gate B suppresses VM fallback when all per-widget owned', (
      tester,
    ) async {
      detector.vmConnected = true;
      // VM window: 15 % paint share over 2 s.
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(_windowShare(15));
      // Per-widget data: 10 paints/sec, fully owned (residual=0).
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 10,
          paintCounts: {'CustomPaint': 10},
          animationOwnedPaintCounts: {'CustomPaint': 10},
          totalAnimationOwnedPaintCount: 10,
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(
        detector.issues,
        isEmpty,
        reason:
            'All known per-widget activity is animation-owned, so '
            'the VM aggregate fallback must be suppressed.',
      );
    });

    // Gate B does NOT suppress when paintCounts is empty (no
    // per-widget evidence) — VM gate must still fire.
    testWidgets('Gate B fires VM fallback when paintCounts empty', (
      tester,
    ) async {
      detector.vmConnected = true;
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(_windowShare(15));
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 0,
          paintCounts: {},
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      // paintCounts.isEmpty → falls into the `else if (hasFreshVm)`
      // branch which has no Gate B guard.
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.stableId, 'excessive_repaint');
    });

    // Gate B does NOT suppress when at least one per-widget paint
    // is NOT animation-owned (mixed scene). One typeName fully owned,
    // the other has zero ownership → all-owned check fails → VM fires.
    testWidgets('Gate B fires VM fallback in mixed-owner scene', (
      tester,
    ) async {
      detector.vmConnected = true;
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(_windowShare(15));
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 20,
          paintCounts: {'CustomPaint': 10, 'MyChartWidget': 10},
          animationOwnedPaintCounts: {
            'CustomPaint': 10,
            // MyChartWidget intentionally absent (residual=10 > 0).
          },
          totalAnimationOwnedPaintCount: 10,
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      // Per-widget rates are sub-threshold so Gate A loop emits
      // nothing; Gate B is checked → MyChartWidget breaks the
      // all-owned condition → VM gate fires.
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.stableId, 'excessive_repaint');
    });

    // Gate C residual fires from the aggregate path: total=200,
    // totalOwned=120, residual=80/sec → emits `excessive_repaint_debug`
    // with the residual rate in title and the exclusion suffix in detail.
    //
    // To reach Gate C through the `else if (hasFreshDebug)` branch we
    // need an empty `paintCounts` (so the per-widget branch isn't
    // taken) but a non-zero `totalPaintCount` (so the aggregate branch
    // runs). This represents the runtime case where the coordinator
    // counted paints but `_paintCounts` was empty (e.g. all paints
    // missed the `DebugCreator` cast or were dropped by the 200-type
    // cap), while still attributing some of them to animation owners.
    test('Gate C fires with residual rate when residual > threshold', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 200,
          paintCounts: {},
          totalAnimationOwnedPaintCount: 120,
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.stableId, 'excessive_repaint_debug');
      // Title carries residual rate (80), not raw aggregate (200).
      expect(issue.title, contains('80'));
      expect(issue.title, isNot(contains('200')));
      // Detail records both residual count and exclusion accounting.
      expect(issue.detail, contains('80 paint calls'));
      expect(issue.detail, contains('Excludes 120 animation-owned paints'));
    });

    // Gate C short-circuit when residualCount <= 0 (every paint
    // attributed). Covers the arithmetic edge case where
    // `totalAnimationOwnedPaintCount == totalPaintCount`.
    test('Gate C short-circuits when residualCount is zero', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 200,
          paintCounts: {},
          totalAnimationOwnedPaintCount: 200,
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(detector.issues, isEmpty);
    });

    // Gate C residual subtraction: total=200, totalOwned=180,
    // residual=20/sec which is BELOW the 30/sec threshold → suppressed.
    test('Gate C suppresses when residual rate is below threshold', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 200,
          paintCounts: {},
          totalAnimationOwnedPaintCount: 180,
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(detector.issues, isEmpty);
    });
  });

  group('excessive_repaint time-share axis', () {
    late RepaintDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = RepaintDetector(clock: () => fakeNow);
      detector.vmConnected = true;
    });

    /// Feeds [paintTimeUs] of PAINT scope time, advances the clock by
    /// [windowMs], and closes the window with an empty batch.
    void closeWindow(int paintTimeUs, {int windowMs = 1000}) {
      detector.processTimelineData(paintLoadData(paintTimeUs: paintTimeUs));
      fakeNow = fakeNow.add(Duration(milliseconds: windowMs));
      detector.processTimelineData(emptyTimelineData());
      detector.evaluateNow();
    }

    List<PerformanceIssue> repaint() => detector.issues
        .where((i) => i.stableId == 'excessive_repaint')
        .toList();

    test('defaults: 10 % threshold, per-widget debug knob unchanged', () {
      expect(detector.paintTimePercentThreshold, 10);
      expect(detector.paintFrequencyThreshold, 30);
    });

    test('9.0 % over 1 000 ms stays silent but updates last and peak', () {
      closeWindow(90000);
      expect(repaint(), isEmpty);
      expect(detector.lastObservedPaintPercent, closeTo(9.0, 1e-9));
      expect(detector.peakObservedPaintPercent, closeTo(9.0, 1e-9));
    });

    test('11.0 % over 1 000 ms raises a warning stamped with the share', () {
      closeWindow(110000);
      final issue = repaint().single;
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.extraTraceArgs?['observedPaintPercent'], '11.0');
      expect(issue.title, contains('11.0% of UI time'));
      expect(issue.detail, contains('PAINT scopes'));
      expect(issue.fixHint, contains('11.0% of UI-thread time'));
      expect(issue.dedupIdentityMicros, isNotNull);
    });

    test('31.0 % is critical; exactly 3× stays warning', () {
      closeWindow(300000);
      expect(repaint().single.severity, IssueSeverity.warning);
      closeWindow(310000);
      expect(repaint().single.severity, IssueSeverity.critical);
      expect(repaint().single.extraTraceArgs?['observedPaintPercent'], '31.0');
    });

    test('a 1 400 ms window is normalised by its real length', () {
      closeWindow(140000, windowMs: 1400);
      expect(detector.lastObservedPaintPercent, closeTo(10.0, 1e-9));
      expect(repaint(), isEmpty);
      closeWindow(154000, windowMs: 1400);
      expect(repaint().single.extraTraceArgs?['observedPaintPercent'], '11.0');
    });

    test('custom threshold gates warning and 3× critical', () {
      detector = RepaintDetector(
        paintTimePercentThreshold: 20,
        clock: () => fakeNow,
      )..vmConnected = true;
      closeWindow(150000);
      expect(repaint(), isEmpty);
      closeWindow(250000);
      expect(repaint().single.severity, IssueSeverity.warning);
      closeWindow(610000);
      expect(repaint().single.severity, IssueSeverity.critical);
    });

    test('flushPaintEvaluation after 300 ms updates last only, without '
        'emitting', () {
      closeWindow(120000);
      expect(detector.peakObservedPaintPercent, closeTo(12.0, 1e-9));

      // A 300 ms tail at 50 % share must not become the peak.
      detector.processTimelineData(paintLoadData(paintTimeUs: 150000));
      fakeNow = fakeNow.add(const Duration(milliseconds: 300));
      detector.flushPaintEvaluation();
      expect(detector.lastObservedPaintPercent, closeTo(50.0, 1e-9));
      expect(
        detector.peakObservedPaintPercent,
        closeTo(12.0, 1e-9),
        reason: 'peak stays bound to naturally closed windows',
      );
      expect(
        repaint().single.extraTraceArgs?['observedPaintPercent'],
        '12.0',
        reason: 'flush is an observable refresh only — never emits',
      );
    });

    test('flushPaintEvaluation with no paint time is a no-op', () {
      closeWindow(60000);
      fakeNow = fakeNow.add(const Duration(milliseconds: 300));
      detector.flushPaintEvaluation();
      expect(detector.lastObservedPaintPercent, closeTo(6.0, 1e-9));
    });

    test('a natural window close at 1 100 ms raises the peak and stamps '
        'the same value', () {
      closeWindow(132000, windowMs: 1100);
      expect(detector.peakObservedPaintPercent, closeTo(12.0, 1e-9));
      expect(
        repaint().single.extraTraceArgs?['observedPaintPercent'],
        detector.peakObservedPaintPercent.toStringAsFixed(1),
      );
    });

    test('peak tracks the max across windows; last tracks the latest', () {
      closeWindow(60000);
      closeWindow(225000);
      closeWindow(80000);
      expect(detector.peakObservedPaintPercent, closeTo(22.5, 1e-9));
      expect(detector.lastObservedPaintPercent, closeTo(8.0, 1e-9));
    });

    test('resetCaptureState clears observables, issues and restarts the '
        'window clock', () {
      closeWindow(150000);
      expect(repaint(), isNotEmpty);
      fakeNow = fakeNow.add(const Duration(milliseconds: 700));
      detector.processTimelineData(paintLoadData(paintTimeUs: 400000));

      detector.resetCaptureState();
      expect(detector.lastObservedPaintPercent, 0);
      expect(detector.peakObservedPaintPercent, 0);
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);

      // 600 ms after the reset the window is still open.
      fakeNow = fakeNow.add(const Duration(milliseconds: 600));
      detector.processTimelineData(paintLoadData(paintTimeUs: 60000));
      expect(detector.lastObservedPaintPercent, 0);

      fakeNow = fakeNow.add(const Duration(milliseconds: 400));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.lastObservedPaintPercent, closeTo(6.0, 1e-9));
    });

    test('VM disconnect clears last/peak and the open window', () {
      closeWindow(150000);
      detector.processTimelineData(paintLoadData(paintTimeUs: 900000));
      detector.vmConnected = false;
      expect(detector.lastObservedPaintPercent, 0);
      expect(detector.peakObservedPaintPercent, 0);
      detector.vmConnected = true;
      closeWindow(50000);
      expect(detector.lastObservedPaintPercent, closeTo(5.0, 1e-9));
    });

    test('Gate B still suppresses when every per-widget paint is '
        'animation-owned', () {
      detector.processTimelineData(paintLoadData(paintTimeUs: 400000));
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      detector.processTimelineData(emptyTimelineData());
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 10,
          paintCounts: {'CustomPaint': 10},
          animationOwnedPaintCounts: {'CustomPaint': 10},
          totalAnimationOwnedPaintCount: 10,
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(detector.issues, isEmpty);
    });

    test('debug per-widget gate unchanged at paintFrequencyThreshold', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 31,
          paintCounts: {'MyChart': 31},
          paintOrigins: {'MyChart': PaintOriginStats(maxCount: 31)},
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(detector.issues.single.stableId, 'repaint_debug_MyChart');
      expect(detector.issues.single.severity, IssueSeverity.warning);
    });
  });
}

class _TestPaintWidget extends StatelessWidget {
  const _TestPaintWidget({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 10);
}
