import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/setstate_scope_detector.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';
import 'package:sleuth/src/ui/sleuth_overlay.dart';

/// Highlights the element keyed `target`, measuring its render object.
class _TargetHighlighter extends BaseDetector {
  _TargetHighlighter()
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.structural,
        name: 'Target',
        description: 'Highlights the target widget.',
      );

  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => const [];
  @override
  List<WidgetHighlight> get highlights => _highlights;
  @override
  bool get isEnabled => _isEnabled;
  @override
  set isEnabled(bool v) => _isEnabled = v;

  @override
  void scanTree(BuildContext context) {
    _highlights.clear();
    void visit(Element e) {
      if (e.widget.key == const ValueKey('target')) {
        final ro = e.renderObject;
        if (ro is RenderBox && ro.hasSize) {
          _highlights.add(
            WidgetHighlight(
              rect: ro.localToGlobal(Offset.zero) & ro.size,
              widgetName: 'Target',
              severity: IssueSeverity.warning,
              detectorName: 'Target',
              renderObject: ro,
            ),
          );
        }
        return;
      }
      e.visitChildren(visit);
    }

    context.visitChildElements(visit);
  }

  @override
  void dispose() => _highlights.clear();
}

void main() {
  group('highlight aggregation', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets(
      'Listview detector highlights flow through to highlightsNotifier',
      (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  55,
                  (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                ),
              ),
            ),
          ),
        );

        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final highlights = controller.highlightsNotifier.value.items;
        expect(
          highlights.isNotEmpty,
          isTrue,
          reason:
              'Listview detector highlights should flow through _collectHighlights',
        );
      },
    );

    testWidgets(
      'GpuPressureDetector highlights flow through to highlightsNotifier',
      (tester) async {
        // Opacity with deep subtree triggers GpuPressureDetector's RenderOpacity detection
        await tester.pumpWidget(
          Directionality(
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
          ),
        );

        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final gpuHighlights = controller.highlightsNotifier.value.items.where(
          (h) => h.detectorName == 'GPU',
        );
        expect(
          gpuHighlights,
          isNotEmpty,
          reason:
              'GPU detector highlights should flow through _collectHighlights',
        );
      },
    );

    testWidgets('highlights cleared and repopulated on each scan cycle', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );
      final firstScan = controller.highlightsNotifier.value.items.length;

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );
      final secondScan = controller.highlightsNotifier.value.items.length;

      // Should be repopulated, not accumulated
      expect(secondScan, firstScan);
    });

    testWidgets(
      'detector with issues but no highlights does not pollute highlightsNotifier',
      (tester) async {
        // Build a tree that triggers a structural detector that doesn't produce highlights
        // (e.g., NestedScrollDetector or FontLoadingDetector)
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(width: 10, height: 10),
          ),
        );

        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        // Simple tree — no highlights expected
        expect(controller.highlightsNotifier.value.items, isEmpty);
      },
    );
  });

  group('highlight dirty-check (Pillar 2a M2)', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('generation unchanged when zero highlights across scans', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 10, height: 10),
        ),
      );

      final context = tester.element(find.byType(Directionality));
      controller.runTreeScanForTest(context);
      final gen1 = controller.highlightsNotifier.value.generation;

      controller.runTreeScanForTest(context);
      final gen2 = controller.highlightsNotifier.value.generation;

      expect(
        gen2,
        gen1,
        reason: 'Generation should not increment when 0→0 highlights',
      );
    });

    testWidgets('generation increments when highlights appear', (tester) async {
      // First scan: clean tree, no highlights
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 10, height: 10),
        ),
      );
      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );
      final genBefore = controller.highlightsNotifier.value.generation;

      // Second scan: tree with Opacity(0.0) → highlights produced
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );
      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );
      final genAfter = controller.highlightsNotifier.value.generation;

      expect(
        genAfter,
        greaterThan(genBefore),
        reason: 'Generation must increment when highlights appear',
      );
      expect(controller.highlightsNotifier.value.items, isNotEmpty);
    });

    testWidgets('generation increments when highlights disappear', (
      tester,
    ) async {
      // First scan: tree with Opacity(0.0) → highlights produced
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );
      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );
      expect(controller.highlightsNotifier.value.items, isNotEmpty);
      final genBefore = controller.highlightsNotifier.value.generation;

      // Second scan: clean tree → highlights gone
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 10, height: 10),
        ),
      );
      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );
      final genAfter = controller.highlightsNotifier.value.generation;

      expect(
        genAfter,
        greaterThan(genBefore),
        reason: 'Generation must increment when highlights disappear',
      );
      expect(controller.highlightsNotifier.value.items, isEmpty);
    });
  });

  group('selectHighlightForIssue', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test('matches highlight by widgetName', () {
      controller.highlightsNotifier.value = (
        generation: 1,
        items: [
          const WidgetHighlight(
            rect: Rect.fromLTWH(0, 0, 100, 100),
            widgetName: 'MyWidget',
            severity: IssueSeverity.warning,
            detectorName: 'Test',
            detail: 'test detail',
          ),
        ],
      );

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'Test',
        fixHint: 'Test',
        widgetName: 'MyWidget',
      );

      final matched = controller.selectHighlightForIssue(issue);
      expect(matched, isTrue);
      expect(
        controller.selectedHighlightNotifier.value?.widgetName,
        'MyWidget',
      );
    });

    test('falls back to detectorName via category mapping', () {
      controller.highlightsNotifier.value = (
        generation: 1,
        items: [
          const WidgetHighlight(
            rect: Rect.fromLTWH(0, 0, 100, 100),
            widgetName: 'SomeWidget',
            severity: IssueSeverity.warning,
            detectorName: 'GPU',
            detail: 'test detail',
          ),
        ],
      );

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.raster,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'Test',
        fixHint: 'Test',
      );

      final matched = controller.selectHighlightForIssue(issue);
      expect(matched, isTrue);
    });

    test('returns false when no highlights available', () {
      controller.highlightsNotifier.value = (generation: 0, items: []);

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'Test',
        fixHint: 'Test',
      );

      final matched = controller.selectHighlightForIssue(issue);
      expect(matched, isFalse);
    });

    test('sets highlightEnabledNotifier to true on match', () {
      controller.highlightEnabledNotifier.value = false;
      controller.highlightsNotifier.value = (
        generation: 1,
        items: [
          const WidgetHighlight(
            rect: Rect.fromLTWH(0, 0, 100, 100),
            widgetName: 'MyWidget',
            severity: IssueSeverity.warning,
            detectorName: 'Test',
            detail: 'test detail',
          ),
        ],
      );

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'Test',
        fixHint: 'Test',
        widgetName: 'MyWidget',
      );

      controller.selectHighlightForIssue(issue);
      expect(controller.highlightEnabledNotifier.value, isTrue);
    });

    test('clearSelectedHighlight resets state', () {
      controller.highlightsNotifier.value = (
        generation: 1,
        items: [
          const WidgetHighlight(
            rect: Rect.fromLTWH(0, 0, 100, 100),
            widgetName: 'MyWidget',
            severity: IssueSeverity.warning,
            detectorName: 'Test',
            detail: 'test detail',
          ),
        ],
      );

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'Test',
        fixHint: 'Test',
        widgetName: 'MyWidget',
      );

      controller.selectHighlightForIssue(issue);
      expect(controller.selectedHighlightNotifier.value, isNotNull);

      controller.clearSelectedHighlight();
      expect(controller.selectedHighlightNotifier.value, isNull);
      expect(controller.pendingIssueSelection, isNull);
    });
  });

  group('detectorNamesForCategory', () {
    test('layout category maps to Layout', () {
      final names = SleuthController.detectorNamesForCategory(
        IssueCategory.layout,
      );
      expect(names, contains('Layout'));
    });

    test('raster category maps to GPU', () {
      final names = SleuthController.detectorNamesForCategory(
        IssueCategory.raster,
      );
      expect(names, contains('GPU'));
    });

    test('build category maps to expected detector names', () {
      final names = SleuthController.detectorNamesForCategory(
        IssueCategory.build,
      );
      expect(names, containsAll(['Non-lazy', 'setState', 'Rebuild']));
    });

    test('paint category maps to expected detector names', () {
      final names = SleuthController.detectorNamesForCategory(
        IssueCategory.paint,
      );
      expect(names, containsAll(['Painter', 'Repaint']));
    });
  });

  group('routeName stamping', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('issues have null routeName when no ModalRoute in context', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Column(
              children: List.generate(
                55,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty, reason: 'Opacity(0.0) should produce issues');
      for (final issue in issues) {
        expect(issue.routeName, isNull);
      }
    });

    testWidgets('issues stamped with route name from MaterialApp named route', (
      tester,
    ) async {
      const pageKey = Key('routeTestPage');
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/home',
          routes: {
            '/home': (_) => Column(
              key: pageKey,
              children: [
                SingleChildScrollView(
                  child: Column(
                    children: List.generate(
                      55,
                      (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                    ),
                  ),
                ),
              ],
            ),
          },
        ),
      );

      // Scan from the keyed Column so Opacity is visited as a child
      controller.runTreeScanForTest(tester.element(find.byKey(pageKey)));

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty, reason: 'Opacity(0.0) should produce issues');
      expect(
        issues.any((i) => i.routeName == '/home'),
        isTrue,
        reason: 'Issues should be stamped with the named route',
      );
    });

    testWidgets('debugModeDisclaimer still stamped alongside routeName', (
      tester,
    ) async {
      const pageKey = Key('routeTestPage2');
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/home',
          routes: {
            '/home': (_) => Column(
              key: pageKey,
              children: [
                SingleChildScrollView(
                  child: Column(
                    children: List.generate(
                      55,
                      (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                    ),
                  ),
                ),
              ],
            ),
          },
        ),
      );

      controller.runTreeScanForTest(tester.element(find.byKey(pageKey)));

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty);
      for (final issue in issues) {
        // In test (debug mode), both should be stamped
        expect(issue.debugModeDisclaimer, isTrue);
        expect(issue.routeName, '/home');
      }
    });

    testWidgets('interactionContext stamped alongside routeName', (
      tester,
    ) async {
      const pageKey = Key('routeTestPage3');
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/home',
          routes: {
            '/home': (_) => Column(
              key: pageKey,
              children: [
                SingleChildScrollView(
                  child: Column(
                    children: List.generate(
                      55,
                      (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                    ),
                  ),
                ),
              ],
            ),
          },
        ),
      );

      controller.runTreeScanForTest(tester.element(find.byKey(pageKey)));

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty);
      for (final issue in issues) {
        expect(issue.routeName, '/home');
        expect(issue.interactionContext, isNotNull);
        expect(issue.interactionContext, InteractionContext.idle);
      }
    });
  });
  group('scroll refreshes highlight rects without rescanning', () {
    late ScrollController scroll;
    late ValueNotifier<bool> showTarget;

    /// Pumps the real overlay around a scrollable app whose item keyed
    /// `target` is highlighted, runs one scan and enables highlights.
    Future<SleuthController> pumpOverlay(WidgetTester tester) async {
      scroll = ScrollController();
      showTarget = ValueNotifier(true);
      addTearDown(scroll.dispose);
      addTearDown(showTarget.dispose);
      final controller = SleuthController(
        config: SleuthConfig(
          treeScanInterval: const Duration(seconds: 30),
          customDetectors: [_TargetHighlighter()],
        ),
      );
      controller.initializeDetectorsForTest();
      controller.markInitializedForTest();
      await tester.pumpWidget(
        SleuthOverlay(
          controller: controller,
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: showTarget,
                builder: (_, show, _) => ListView.builder(
                  controller: scroll,
                  itemExtent: 50,
                  itemCount: 100,
                  itemBuilder: (_, i) => i == 5 && show
                      ? const SizedBox(key: ValueKey('target'), height: 50)
                      : SizedBox(height: 50, child: Text('row $i')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      controller.highlightEnabledNotifier.value = true;
      controller.scanTreeFullPathForTest(
        tester.element(find.byType(MaterialApp)),
      );
      return controller;
    }

    WidgetHighlight target(SleuthController c) => c
        .highlightsNotifier
        .value
        .items
        .firstWhere((h) => h.detectorName == 'Target');

    void dispatchScrollUpdate(WidgetTester tester) {
      final ctx = tester.element(find.byType(ListView));
      ScrollUpdateNotification(
        metrics: FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 4400,
          pixels: 0,
          viewportDimension: 600,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1,
        ),
        context: ctx,
        scrollDelta: 0,
      ).dispatch(ctx);
    }

    testWidgets('scroll updates leave detector scan state untouched', (
      tester,
    ) async {
      final c = await pumpOverlay(tester);
      final setStateScope = c.detectorsForAudit
          .whereType<SetStateScopeDetector>()
          .single;
      final snapshotsBefore = setStateScope.childSnapshotsForTest;
      const staged = DebugSnapshot(
        rebuildCounts: {'Row': 1},
        totalPaintCount: 1,
        elapsed: Duration(milliseconds: 500),
      );
      c.rebuildDetector.updateDebugSnapshot(staged);
      c.repaintDetector!.updateDebugSnapshot(staged);
      final generationBefore = c.highlightsNotifier.value.generation;

      for (var i = 0; i < 10; i++) {
        dispatchScrollUpdate(tester);
        await tester.pump();
      }

      expect(
        identical(setStateScope.childSnapshotsForTest, snapshotsBefore),
        isTrue,
      );
      expect(c.rebuildDetector.pendingDebugSnapshotForTest, same(staged));
      expect(c.repaintDetector!.pendingDebugSnapshotForTest, same(staged));
      // Rect refreshes ran (one per frame) without a scan.
      expect(
        c.highlightsNotifier.value.generation,
        greaterThan(generationBefore),
      );
    });

    testWidgets('rects follow the scroll and selection survives', (
      tester,
    ) async {
      final c = await pumpOverlay(tester);
      final before = target(c);
      c.selectedHighlightNotifier.value = before;
      final generationBefore = c.highlightsNotifier.value.generation;

      scroll.jumpTo(200);
      await tester.pump();

      final after = target(c);
      expect(after.rect.top, before.rect.top - 200);
      expect(after.rect.size, before.rect.size);
      expect(
        c.highlightsNotifier.value.generation,
        greaterThan(generationBefore),
      );
      expect(c.selectedHighlightNotifier.value, same(after));
    });

    testWidgets('a highlight whose widget was removed is dropped', (
      tester,
    ) async {
      final c = await pumpOverlay(tester);
      expect(c.highlightsNotifier.value.items, isNotEmpty);

      showTarget.value = false;
      await tester.pump();
      c.refreshHighlightRects();
      await tester.pump();

      expect(
        c.highlightsNotifier.value.items.where(
          (h) => h.detectorName == 'Target',
        ),
        isEmpty,
      );
    });

    testWidgets('scroll end runs exactly one early scan tick', (tester) async {
      final c = await pumpOverlay(tester);
      var ticks = 0;
      c.scanTickNotifier.addListener(() => ticks++);

      scroll.jumpTo(200);
      await tester.pump();
      expect(ticks, 0);

      await tester.pump(const Duration(milliseconds: 400));
      expect(ticks, 1);
      expect(c.interactionStateForTest, InteractionContext.idle);

      await tester.pump(const Duration(milliseconds: 400));
      expect(ticks, 1);
    });

    testWidgets('refreshHighlights requests an early tick instead of walking', (
      tester,
    ) async {
      final c = await pumpOverlay(tester);
      final setStateScope = c.detectorsForAudit
          .whereType<SetStateScopeDetector>()
          .single;
      final snapshotsBefore = setStateScope.childSnapshotsForTest;
      var ticks = 0;
      c.scanTickNotifier.addListener(() => ticks++);

      c.refreshHighlights();
      expect(
        identical(setStateScope.childSnapshotsForTest, snapshotsBefore),
        isTrue,
      );
      expect(ticks, 0);

      await tester.pump(const Duration(milliseconds: 400));
      expect(ticks, 1);
    });
  });
}
