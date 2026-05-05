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

  // ---------------------------------------------------------------
  // Animation-owned paint filter (Gates A/B/C).
  //
  // Hand-rolled fixture coverage of the helper logic. The companion
  // real-widget falsification test lives in
  //   test/detectors/repaint_animation_filter_real_widget_test.dart
  // and pumps an actual `CircularProgressIndicator` through the real
  // `DebugInstrumentationCoordinator` paint pipeline. The two suites
  // together address the Tactic 9 fixture-tautology risk: this group
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

    // T1 — Gate A: every paint of `CustomPaint` is owned (residual=0)
    // → no issue emitted even at 60 paints/sec.
    test('Gate A skips per-widget when fully owned (residual=0)', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 60,
        paintCounts: {'CustomPaint': 60},
        animationOwnedPaintCounts: {'CustomPaint': 60},
        totalAnimationOwnedPaintCount: 60,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();
      expect(detector.issues, isEmpty,
          reason: 'CustomPaint with residual=0 must NOT fire even at '
              '60 paints/sec.');
    });

    // T2 — Gate A default-fire: no owned-counts entry → ownedCount
    // defaults to 0, residual = total → fires. Preserves the
    // "never silently mask a real bug" invariant.
    test('Gate A fires when no owned attribution recorded (default-fire)', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 60,
        paintCounts: {'CustomPaint': 60},
        // animationOwnedPaintCounts intentionally omitted (defaults to
        // const {}). Coordinator never marked any of these as owned.
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();
      expect(detector.issues, hasLength(1),
          reason: 'No owned attribution means no evidence to suppress on; '
              'the detector MUST NOT silently mask a real bug.');
      expect(detector.issues.first.stableId, 'repaint_debug_CustomPaint');
    });

    // T3 — Gate A explicit zero-owned: explicit `{'CustomPaint': 0}`
    // is the same as missing key → fires. (Defends against a future
    // change that decides to write zeros instead of omitting keys.)
    test('Gate A fires when explicit owned count is zero', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 60,
        paintCounts: {'CustomPaint': 60},
        animationOwnedPaintCounts: {'CustomPaint': 0},
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.stableId, 'repaint_debug_CustomPaint');
    });

    // T4 — C1 polymorphic-collision case (the bug the C1+C3 fix exists
    // to solve). Two distinct widgets share `CustomPaint` as their
    // typeName key: half the paints are owned by a CPI's internal
    // CustomPaint, the other half are a chart's bare CustomPaint.
    // Pre-fix, the chain-containment check would either fully fire
    // (cached chain didn't have the owner) or fully suppress (cached
    // chain did) — both wrong. Post-fix, the residual is exactly the
    // unowned half and the issue fires with the residual rate.
    test('Gate A fires with residual rate on partial ownership (C1)', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 60,
        paintCounts: {'CustomPaint': 60},
        animationOwnedPaintCounts: {'CustomPaint': 30},
        totalAnimationOwnedPaintCount: 30,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();
      expect(detector.issues, hasLength(1),
          reason: 'Residual=30/sec is at threshold and must fire even '
              'though the other half of paints are owned.');
      final issue = detector.issues.first;
      expect(issue.stableId, 'repaint_debug_CustomPaint');
      // Title reports the residual rate (30), not the raw 60.
      expect(issue.title, contains('30'));
      expect(issue.title, isNot(contains('60/sec')));
      // Detail discloses the exclusion accounting.
      expect(issue.detail, contains('30 repaints'));
      expect(issue.detail, contains('Excludes 30 animation-owned paint'));
    });

    // T5 — Gate A residual below threshold: 60 total - 35 owned = 25
    // residual which is BELOW the 30/sec threshold → suppressed even
    // though the unowned subset exists.
    test('Gate A suppresses when residual rate is below threshold', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 60,
        paintCounts: {'CustomPaint': 60},
        animationOwnedPaintCounts: {'CustomPaint': 35},
        totalAnimationOwnedPaintCount: 35,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();
      expect(detector.issues, isEmpty);
    });

    // T6 — Gate B: VM aggregate fallback suppressed when *every*
    // per-widget paint is fully owned. The per-widget rate is
    // sub-threshold (skipping Gate A's residual check), but the VM
    // window says >30/sec — without Gate B that VM gate would fire
    // `excessive_repaint`.
    testWidgets('Gate B suppresses VM fallback when all per-widget owned',
        (tester) async {
      detector.vmConnected = true;
      // VM window: 50 paints/sec, will close on next processTimelineData.
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 50));
      // Per-widget data: 10 paints/sec, fully owned (residual=0).
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 10,
        paintCounts: {'CustomPaint': 10},
        animationOwnedPaintCounts: {'CustomPaint': 10},
        totalAnimationOwnedPaintCount: 10,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();
      expect(detector.issues, isEmpty,
          reason: 'All known per-widget activity is animation-owned, so '
              'the VM aggregate fallback must be suppressed.');
    });

    // T7 — Gate B does NOT suppress when paintCounts is empty (no
    // per-widget evidence) — VM gate must still fire.
    testWidgets('Gate B fires VM fallback when paintCounts empty',
        (tester) async {
      detector.vmConnected = true;
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 50));
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 0,
        paintCounts: {},
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();
      // paintCounts.isEmpty → falls into the `else if (hasFreshVm)`
      // branch which has no Gate B guard.
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.stableId, 'excessive_repaint');
    });

    // T8 — Gate B does NOT suppress when at least one per-widget paint
    // is NOT animation-owned (mixed scene). One typeName fully owned,
    // the other has zero ownership → all-owned check fails → VM fires.
    testWidgets('Gate B fires VM fallback in mixed-owner scene',
        (tester) async {
      detector.vmConnected = true;
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 50));
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 20,
        paintCounts: {
          'CustomPaint': 10,
          'MyChartWidget': 10,
        },
        animationOwnedPaintCounts: {
          'CustomPaint': 10,
          // MyChartWidget intentionally absent (residual=10 > 0).
        },
        totalAnimationOwnedPaintCount: 10,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();
      // Per-widget rates are sub-threshold so Gate A loop emits
      // nothing; Gate B is checked → MyChartWidget breaks the
      // all-owned condition → VM gate fires.
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.stableId, 'excessive_repaint');
    });

    // T9 — Gate C residual fires from the aggregate path: total=200,
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
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 200,
        paintCounts: {},
        totalAnimationOwnedPaintCount: 120,
        elapsed: Duration(seconds: 1),
      ));
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

    // T10 — Gate C short-circuit when residualCount <= 0 (every paint
    // attributed). Belt-and-braces for arithmetic edge cases where
    // `totalAnimationOwnedPaintCount == totalPaintCount`.
    test('Gate C short-circuits when residualCount is zero', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 200,
        paintCounts: {},
        totalAnimationOwnedPaintCount: 200,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();
      expect(detector.issues, isEmpty);
    });

    // T11 — Gate C residual subtraction: total=200, totalOwned=180,
    // residual=20/sec which is BELOW the 30/sec threshold → suppressed.
    test('Gate C suppresses when residual rate is below threshold', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 200,
        paintCounts: {},
        totalAnimationOwnedPaintCount: 180,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();
      expect(detector.issues, isEmpty);
    });
  });

  group('excessive_repaint capture-mode plumbing', () {
    late RepaintDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = RepaintDetector(clock: () => fakeNow);
      detector.vmConnected = true;
    });

    test('observedPaintCount stamped on emission equals paintCount', () {
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 35));
      detector.evaluateNow();

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.stableId, 'excessive_repaint');
      expect(issue.extraTraceArgs?['observedPaintCount'], '35');
    });

    test('window-completion stamps lastObservedPaintCount even sub-threshold',
        () {
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 6));
      // 6 paints/sec is below 30 threshold — no issue should fire,
      // but the observable getter must still surface the measurement
      // for capture-mode below-leg export.
      detector.evaluateNow();

      expect(detector.issues, isEmpty);
      expect(detector.lastObservedPaintCount, 6);
    });

    test('flushPaintEvaluation populates observable without emitting issues',
        () {
      detector.processTimelineData(highPaintActivityData(paintCount: 12));
      // No window has elapsed (fakeNow not advanced) — _paintEventCount
      // is staged but _pendingVmWindowCount is null.
      expect(detector.lastObservedPaintCount, 0);

      detector.flushPaintEvaluation();
      expect(detector.lastObservedPaintCount, 12);
      expect(detector.issues, isEmpty,
          reason: 'flush is observable refresh only — never emits');
    });

    test('flushPaintEvaluation does NOT update peakObservedPaintCount', () {
      // Partial-window counts must not leak into peak — peak is the
      // capture-mode magnitude export and must match an in-span
      // emission's observedPaintCount arg under the audit gate's
      // observedAxisReduction: 'max'. flushPaintEvaluation never
      // triggers _evaluate, so the partial-window count never appears
      // as a trace record; updating peak from it would produce an
      // exported magnitude with no matching emission.
      detector.processTimelineData(highPaintActivityData(paintCount: 50));
      expect(detector.peakObservedPaintCount, 0);

      detector.flushPaintEvaluation();
      expect(detector.lastObservedPaintCount, 50,
          reason: 'flush updates the last observable');
      expect(detector.peakObservedPaintCount, 0,
          reason: 'peak stays bound to naturally-closed windows only');
    });

    test('resetCaptureState clears all per-leg accumulator fields', () {
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 35));
      detector.evaluateNow();
      expect(detector.issues, isNotEmpty);
      expect(detector.lastObservedPaintCount, 35);
      expect(detector.peakObservedPaintCount, 35);

      detector.resetCaptureState();

      expect(detector.lastObservedPaintCount, 0);
      expect(detector.peakObservedPaintCount, 0);
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
      // Subsequent processTimelineData on a fresh window should accumulate
      // from zero, not carry over.
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 6));
      detector.evaluateNow();
      expect(detector.lastObservedPaintCount, 6);
      expect(detector.peakObservedPaintCount, 6);
    });

    test('peakObservedPaintCount tracks max across multiple windows', () {
      // Window 1: 12 paints (sub-threshold)
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 12));
      detector.evaluateNow();
      expect(detector.lastObservedPaintCount, 12);
      expect(detector.peakObservedPaintCount, 12);

      // Window 2: 45 paints (above threshold — peak)
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 45));
      detector.evaluateNow();
      expect(detector.lastObservedPaintCount, 45);
      expect(detector.peakObservedPaintCount, 45);

      // Window 3: 8 paints (lower than peak — peak holds)
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 8));
      detector.evaluateNow();
      expect(detector.lastObservedPaintCount, 8);
      expect(detector.peakObservedPaintCount, 45,
          reason: 'peak must hold max across all windows since reset');
    });

    test('dedupIdentityMicros stamped on emission', () {
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highPaintActivityData(paintCount: 35));
      detector.evaluateNow();

      expect(detector.issues, hasLength(1));
      // The detector reads DateTime.now() (not the injected clock) for
      // the dedup stamp, mirroring NetworkMonitor's pattern. We only
      // assert the field is populated; the value itself is wall-clock.
      expect(detector.issues.first.dedupIdentityMicros, isNotNull);
      expect(detector.issues.first.dedupIdentityMicros, greaterThan(0));
    });
  });
}

class _TestPaintWidget extends StatelessWidget {
  const _TestPaintWidget({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 10);
}
