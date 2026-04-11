import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  group('RebuildDetector', () {
    late RebuildDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = RebuildDetector(clock: () => fakeNow);
      detector.vmConnected = true;
    });

    group('VM connected', () {
      test('no issues when disabled', () {
        detector.isEnabled = false;
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 50));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('no issues when build count below threshold', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 5));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('warning when build count exceeds threshold', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity, IssueSeverity.warning);
        expect(detector.issues.first.title, contains('Rebuild Activity'));
      });

      test('critical when build count exceeds 3x threshold', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 35));
        detector.evaluateNow();

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity, IssueSeverity.critical);
      });

      test('issue confidence is confirmed (VM data)', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        detector.evaluateNow();

        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
      });

      test('observationSource is vmTimeline', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        detector.evaluateNow();

        expect(detector.issues.first.observationSource,
            ObservationSource.vmTimeline);
      });

      testWidgets('top widget name included in detail', (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: TestStatefulWidget(),
          ),
        );

        final context = tester.element(find.byType(Directionality));
        detector.scanTree(context);

        // Feed enough builds to trigger evaluation
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        detector.evaluateNow();

        expect(detector.issues, isNotEmpty);
        expect(
          detector.issues.first.detail,
          contains('TestStatefulWidget'),
        );
        expect(detector.issues.first.widgetName, isNull,
            reason:
                'Aggregate VM activity should not attribute a culprit widget');
      });

      test('window resets after 1-second evaluation', () {
        // First window: high activity
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        // Second window: low activity — issues should clear
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 3));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });
    });

    group('unified evaluation model', () {
      test('processTimelineData accumulates but does not write issues', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        // Issues should NOT be populated until evaluateNow/scanTree
        expect(detector.issues, isEmpty);
      });

      testWidgets('scanTree triggers _evaluate which writes issues',
          (tester) async {
        // Stage VM data first
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));

        // scanTree triggers _evaluate
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: TestStatefulWidget(),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
      });

      test('evaluateNow triggers _evaluate without tree walk', () {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));

        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);
      });

      test('debug snapshot takes priority over VM data', () {
        // Stage both VM and debug data
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));

        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'MyWidget': 20},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        detector.evaluateNow();

        // Debug path should win — produces per-type issues
        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.title, contains('MyWidget'));
        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallback);
      });

      testWidgets('VM data takes priority over structural when connected',
          (tester) async {
        // Stage VM data
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));

        // scanTree populates structural data AND triggers _evaluate
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: List.generate(
                15,
                (i) => TestStatefulWidget(key: ValueKey(i)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        // VM path should win (connected + pending VM data)
        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
        expect(detector.issues.first.observationSource,
            ObservationSource.vmTimeline);
      });

      testWidgets('structural fallback used when no VM and no debug',
          (tester) async {
        detector.vmConnected = false;

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: List.generate(
                15,
                (i) => TestStatefulWidget(key: ValueKey(i)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
        expect(detector.issues.first.observationSource,
            ObservationSource.structural);
      });

      test('no-op when no fresh data — keeps existing issues', () {
        // Generate issues
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        // Call evaluateNow again with no new data — issues should persist
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);
      });

      test('fresh VM window with 0 events clears stale issues', () {
        // Generate issues
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        // Fresh window with 0 events
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 0));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('fresh debug snapshot with 0 rebuilds clears stale issues', () {
        // Generate issues
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        // Fresh debug snapshot with 0 rebuilds
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('zero debug snapshot falls back to VM data when both present', () {
        // Stage VM data
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));

        // Stage debug snapshot with zero counts
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        detector.evaluateNow();

        // Should fall back to VM path — produces confirmed issue from VM
        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.observationSource,
            ObservationSource.vmTimeline);
        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
      });

      test('zero debug snapshot with zero VM data produces no issues', () {
        // Stage zero VM data
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 0));

        // Stage debug snapshot with zero counts
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));

        detector.evaluateNow();

        // Both sources empty — no issues
        expect(detector.issues, isEmpty);
      });
    });

    group('debug callback path', () {
      test('produces confirmed issues with per-type rates', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'MyWidget': 20, 'OtherWidget': 5},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        // MyWidget at 20/sec exceeds threshold (10), OtherWidget at 5/sec does not
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.widgetName, 'MyWidget');
        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
      });

      test('normalizes to per-second rate using elapsed microseconds', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'MyWidget': 10},
          totalPaintCount: 0,
          elapsed: Duration(milliseconds: 500),
        ));
        detector.evaluateNow();

        // 10 rebuilds in 0.5s = 20/sec, exceeds threshold
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.title, contains('20/sec'));
      });

      test('per-widget-type attribution in issue detail and widgetName', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'WidgetA': 15, 'WidgetB': 25},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues, hasLength(2));
        final names = detector.issues.map((i) => i.widgetName).toSet();
        expect(names, containsAll(['WidgetA', 'WidgetB']));

        for (final issue in detector.issues) {
          expect(issue.detail, contains(issue.widgetName!));
        }
      });

      test('observationSource set to debugCallback', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'MyWidget': 20},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues.first.observationSource,
            ObservationSource.debugCallback);
      });

      test('critical severity at 3x threshold', () {
        detector.updateDebugSnapshot(const DebugSnapshot(
          rebuildCounts: {'MyWidget': 35},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ));
        detector.evaluateNow();

        expect(detector.issues.first.severity, IssueSeverity.critical);
      });
    });

    group('VM disconnected — structural fallback', () {
      setUp(() {
        detector.vmConnected = false;
      });

      testWidgets('reports high StatefulWidget density as possible',
          (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: List.generate(
                15,
                (i) => TestStatefulWidget(key: ValueKey(i)),
              ),
            ),
          ),
        );

        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
        expect(detector.issues.first.title, contains('StatefulWidget Density'));
      });

      testWidgets('no issues when density below threshold', (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                TestStatefulWidget(),
                TestStatefulWidget(),
              ],
            ),
          ),
        );

        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty);
      });

      testWidgets('includes most common widget in detail', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: List.generate(
                15,
                (i) => TestStatefulWidget(key: ValueKey(i)),
              ),
            ),
          ),
        );

        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
        expect(
          detector.issues.first.detail,
          contains('TestStatefulWidget'),
        );
        expect(detector.issues.first.widgetName, isNull,
            reason:
                'Structural fallback should provide screen context only, not attribution');
      });

      testWidgets('observationSource is structural', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: List.generate(
                15,
                (i) => TestStatefulWidget(key: ValueKey(i)),
              ),
            ),
          ),
        );

        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues.first.observationSource,
            ObservationSource.structural);
      });

      testWidgets('private-named widgets excluded from density count',
          (tester) async {
        // A tree with only private-named StatefulWidgets (starting with '_')
        // should NOT trigger stateful_density, because these are filtered as
        // likely framework internals.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: List.generate(
                15,
                (i) => _PrivateNamedWidget(key: ValueKey(i)),
              ),
            ),
          ),
        );

        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isEmpty,
            reason: 'Private-named widgets should be filtered from '
                'stateful_density count');
      });

      testWidgets('user widgets still counted after framework filter',
          (tester) async {
        // A tree with enough public-named user widgets SHOULD trigger.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: List.generate(
                15,
                (i) => TestStatefulWidget(key: ValueKey(i)),
              ),
            ),
          ),
        );

        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isNotEmpty,
            reason: 'Public-named user widgets should trigger '
                'stateful_density');
      });
    });

    group('vmConnected setter', () {
      test('VM staging cleared on disconnect', () {
        // Stage VM data
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));

        // Disconnect clears staging
        detector.vmConnected = false;

        // evaluateNow should produce nothing (staging was cleared)
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      testWidgets('possible issues survive disconnect', (tester) async {
        // Disconnect first so scanTree produces structural fallback
        detector.vmConnected = false;

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: List.generate(
                15,
                (i) => TestStatefulWidget(key: ValueKey(i)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(
          detector.issues.any((i) => i.confidence == IssueConfidence.possible),
          isTrue,
        );

        // "Disconnect" again — possible issues survive (no fresh data = keep)
        detector.vmConnected = false;
        expect(
          detector.issues.any((i) => i.confidence == IssueConfidence.possible),
          isTrue,
        );
      });

      testWidgets(
          'after disconnect, next scanTree produces structural fallback',
          (tester) async {
        // Start connected with confirmed issues
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        // Disconnect
        detector.vmConnected = false;

        // Next scanTree should produce structural fallback
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: List.generate(
                15,
                (i) => TestStatefulWidget(key: ValueKey(i)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.possible);
        expect(detector.issues.first.detail, contains('VM unavailable'));
      });

      testWidgets('reconnect flushes stale structural issues', (tester) async {
        // Start disconnected with structural issues
        detector.vmConnected = false;

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: List.generate(
                15,
                (i) => TestStatefulWidget(key: ValueKey(i)),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.possible);

        // Reconnect — stages fresh-zero VM window
        detector.vmConnected = true;

        // Next evaluateNow flushes stale structural issues
        detector.evaluateNow();
        expect(detector.issues, isEmpty);
      });

      test('after reconnect + new timeline data, confirmed issues can reappear',
          () {
        // Connected, build up issues
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 15));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);

        // Disconnect
        detector.vmConnected = false;

        // Reconnect
        detector.vmConnected = true;

        // New timeline data triggers confirmed issues again
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(highBuildActivityData(buildCount: 20));
        detector.evaluateNow();
        expect(detector.issues, isNotEmpty);
        expect(detector.issues.first.confidence, IssueConfidence.confirmed);
      });
    });
  });

  group('RebuildDetector enrichment', () {
    late RebuildDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = RebuildDetector(clock: () => fakeNow);
      detector.vmConnected = true;
    });

    test('enriched dirty names appear in VM path issue detail', () {
      detector.processTimelineData(enrichedBuildActivityData(
        buildCount: 50,
        dirtyList: ['MyWidget', 'MyWidget', 'OtherWidget'],
      ));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(enrichedBuildActivityData(
        buildCount: 0,
        dirtyList: null,
      ));
      detector.evaluateNow();

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.detail, contains('timeline enrichment'));
      expect(issue.detail, contains('MyWidget'));
    });

    test('VM path without enrichment uses structural fallback', () {
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highBuildActivityData(buildCount: 50));
      detector.evaluateNow();

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.detail, isNot(contains('timeline enrichment')));
    });

    test('enrichment cleared between evaluation cycles', () {
      // Cycle 1: enriched data
      detector.processTimelineData(enrichedBuildActivityData(
        buildCount: 50,
        dirtyList: ['LeakyWidget'],
      ));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(enrichedBuildActivityData(
        buildCount: 0,
      ));
      detector.evaluateNow();
      expect(detector.issues.first.detail, contains('LeakyWidget'));

      // Cycle 2: no enrichment
      detector.processTimelineData(highBuildActivityData(buildCount: 50));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(highBuildActivityData(buildCount: 0));
      detector.evaluateNow();
      expect(detector.issues.first.detail, isNot(contains('LeakyWidget')));
    });

    test('debug snapshot path ignores enrichment', () {
      detector.processTimelineData(enrichedBuildActivityData(
        buildCount: 50,
        dirtyList: ['ShouldBeIgnored'],
      ));
      fakeNow = fakeNow.add(const Duration(seconds: 2));

      // Deliver debug snapshot — takes priority over VM
      final snapshot = DebugSnapshot(
        rebuildCounts: {'DebugWidget': 100},
        totalPaintCount: 0,
        elapsed: const Duration(seconds: 1),
      );
      detector.updateDebugSnapshot(snapshot);

      detector.processTimelineData(enrichedBuildActivityData(
        buildCount: 0,
      ));
      detector.evaluateNow();

      // Should use debug path, not enriched VM path
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('DebugWidget'));
      expect(
          detector.issues.first.detail, isNot(contains('timeline enrichment')));
    });
  });

  group('rebuild widget highlights', () {
    late RebuildDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      detector = RebuildDetector(clock: () => fakeNow);
      detector.vmConnected = true;
    });

    testWidgets(
        'debug snapshot with high rebuild rate produces highlights for matching widgets',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestStatefulWidget(),
        ),
      );

      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {'TestStatefulWidget': 20},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, isNotEmpty);
      expect(detector.highlights.first.widgetName, 'TestStatefulWidget');
      expect(detector.highlights.first.detectorName, 'Rebuild');
      expect(detector.highlights.first.detail, contains('20 rebuilds/sec'));
    });

    testWidgets(
        'no debug snapshot and no enriched names produces no highlights',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestStatefulWidget(),
        ),
      );

      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isEmpty);
    });

    testWidgets('rate below threshold produces no highlights', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestStatefulWidget(),
        ),
      );

      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {'TestStatefulWidget': 5},
        totalPaintCount: 0,
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
              (i) => TestStatefulWidget(key: ValueKey(i)),
            ),
          ),
        ),
      );

      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {'TestStatefulWidget': 50},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights.length, 3);
    });

    testWidgets('disabled detector produces no highlights', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestStatefulWidget(),
        ),
      );

      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {'TestStatefulWidget': 50},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, isEmpty);
    });

    testWidgets('enriched VM names produce highlights when no debug snapshot',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestStatefulWidget(),
        ),
      );

      // Stage enriched names with enough occurrences to exceed threshold.
      // Build PhaseEvents with dirtyList containing 15 occurrences.
      final dirtyNames = List.generate(15, (_) => 'TestStatefulWidget');
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(ParsedTimelineData(
        buildEventCount: 15,
        phaseEvents: [
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 1000000,
            durationUs: 5000,
            dirtyList: dirtyNames,
          ),
        ],
      ));

      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, isNotEmpty);
      expect(detector.highlights.first.widgetName, 'TestStatefulWidget');
    });

    testWidgets('critical severity at 3x threshold', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestStatefulWidget(),
        ),
      );

      // 35/sec > 10 * 3 = 30 → critical
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {'TestStatefulWidget': 35},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights.first.severity, IssueSeverity.critical);
    });

    testWidgets('dispose clears highlights', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestStatefulWidget(),
        ),
      );

      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {'TestStatefulWidget': 20},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      ));
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isNotEmpty);

      detector.dispose();
      expect(detector.highlights, isEmpty);
    });
  });

  // -- Builder Widget Suppression (v11.14) --

  group('builder widget suppression', () {
    late RebuildDetector detector;

    setUp(() {
      detector = RebuildDetector(clock: () => DateTime(2026, 1, 1));
      detector.vmConnected = true;
    });

    test('StreamBuilder at 15/sec not flagged (below 3x threshold)', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {'StreamBuilder': 15},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();

      expect(detector.issues, isEmpty,
          reason: 'StreamBuilder at 15/sec < 30 (3x threshold of 10)');
    });

    test('StreamBuilder at 35/sec flagged with builder note', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {'StreamBuilder': 35},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.detail, contains('builder widget'));
      expect(detector.issues.first.widgetName, 'StreamBuilder');
    });

    test('FutureBuilder at 25/sec not flagged', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {'FutureBuilder': 25},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();

      expect(detector.issues, isEmpty);
    });

    test('non-builder widget still flagged at normal threshold', () {
      detector.updateDebugSnapshot(const DebugSnapshot(
        rebuildCounts: {'MyWidget': 15, 'StreamBuilder': 15},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      ));
      detector.evaluateNow();

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.widgetName, 'MyWidget');
      expect(detector.issues.first.detail, isNot(contains('builder widget')));
    });

    testWidgets('enriched VM names path also applies builder multiplier',
        (tester) async {
      final fakeNow = DateTime(2026, 1, 1, 0, 0, 0);
      late DateTime now;
      now = fakeNow;
      final det = RebuildDetector(clock: () => now);
      det.vmConnected = true;

      // 20 StreamBuilder dirty names — below 3x threshold (30)
      final dirtyNames = List.generate(20, (_) => 'StreamBuilder');
      det.processTimelineData(ParsedTimelineData(
        buildEventCount: 50,
        phaseEvents: [
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 1000000,
            durationUs: 5000,
            dirtyList: dirtyNames,
          ),
        ],
      ));
      now = fakeNow.add(const Duration(seconds: 2));
      det.processTimelineData(ParsedTimelineData(buildEventCount: 0));
      det.evaluateNow();

      // The aggregate build count (50) exceeds threshold, so VM issue fires.
      // But StreamBuilder should NOT appear in highlights (below 3x threshold).
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TestStatefulWidget(),
        ),
      );
      det.scanTree(tester.element(find.byType(Directionality)));

      final streamHighlights =
          det.highlights.where((h) => h.widgetName == 'StreamBuilder').toList();
      expect(streamHighlights, isEmpty,
          reason:
              'StreamBuilder below 3x threshold should not produce highlights');
    });
  });
}

class TestStatefulWidget extends StatefulWidget {
  const TestStatefulWidget({super.key});

  @override
  State<TestStatefulWidget> createState() => TestStatefulWidgetState();
}

class TestStatefulWidgetState extends State<TestStatefulWidget> {
  @override
  Widget build(BuildContext context) => const SizedBox(height: 10);
}

/// Private-named StatefulWidget for testing that the `_` prefix filter
/// excludes these from the structural density count.
class _PrivateNamedWidget extends StatefulWidget {
  const _PrivateNamedWidget({super.key});

  @override
  State<_PrivateNamedWidget> createState() => _PrivateNamedWidgetState();
}

class _PrivateNamedWidgetState extends State<_PrivateNamedWidget> {
  @override
  Widget build(BuildContext context) => const SizedBox(height: 10);
}
